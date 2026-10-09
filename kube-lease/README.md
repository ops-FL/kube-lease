# kube-lease

> 给 kubeconfig 一个「租期」：按天数签发，到期自动失效，提前收回一条命令。

`kube-lease` 不做别的，只解决一件事 —— **给外部人员/临时账号发的 kubeconfig 能自己过期、能一键收回**。

原理很朴素：用集群 CA 签一张自带 `NotBefore / NotAfter` 的客户端证书，嵌进 kubeconfig。
时间一到，TLS 握手直接失败，凭证自动作废，不需要任何后台任务。

## 原理

```
用户 CN + 集群 CA 签发客户端证书
        ↓
写入 kubeconfig（内嵌证书）
        ↓
apply 授权（RBAC ClusterRoleBinding）
        ↓
到期后 TLS 握手失败，kubeconfig 自动作废
```

kubeconfig 自身没有有效期字段，会过期的是里面的**凭证**：

| 凭证类型 | 能指定生效时间 | 能指定过期 | 是否采用 |
|---|---|---|---|
| 客户端证书 | NotBefore ✅ | NotAfter ✅ | **采用** |
| ServiceAccount Token | 签发即生效 | ❌ | 否 |
| OIDC JWT | nbf ✅ | exp ✅ | 否（依赖外部 IdP） |

## 设计要点

- **认证/授权分离**：`lease-issue.sh` 只签身份（证书 + kubeconfig），`lease-bind.sh` 只管权限（RBAC）。
- **门面入口**：`lease.sh` 把 `30d` 转成 `-d 30` 再转交主脚本，日常只记这一个。
- **环境自适应**：兼容 OpenSSL 1.1 / 3.x、GNU / BSD `date`，无需 python、无需 cfssl。
- **默认最小权限**：`--bind` 默认 `view`（只读），要写权限得显式 `--role edit`。
- **即时收回**：`lease-bind.sh --revoke` 一条命令撤销权限，比手删 YAML 省事。
- **干净安全**：私钥 / CSR / 证书只存在临时目录，退出自动清理；`output/` 全程 gitignore。

## 目录结构

```
kube-lease/
├── README.md
├── .gitignore
└── scripts/
    ├── lease.sh          # 门面：Nd → -d N
    ├── lease-issue.sh    # 主流程：时间 → 证书 → kubeconfig
    └── lease-bind.sh     # 授权：生成 / apply / revoke
```

## 前置条件

- 能读集群 CA：默认 `/etc/kubernetes/pki/{ca.crt,ca.key}`（通常需要 `sudo`）
- 已安装 `openssl`（1.1.1 或 3.x）、`kubectl`
- **不需要** python3，**不需要** cfssl

## 快速开始

```bash
git clone <你的仓库地址>
cd kube-lease

# 30 天只读账号
sudo bash scripts/lease.sh 30d -u dev -s https://10.0.0.1:6443 --bind

# 在集群里放行权限
kubectl apply -f output/dev-grant.yaml

# 使用
kubectl --kubeconfig=output/dev-30d.kubeconfig get ns
```

## 常用场景

```bash
# 任意天数 + 权限分级
sudo bash scripts/lease.sh 7d   -u ops    -s https://10.0.0.1:6443 --bind --role edit
sudo bash scripts/lease.sh 365d -u vendor -s https://10.0.0.1:6443 --bind

# 延迟生效：文件可以先发出去，时间不到用不了
sudo bash scripts/lease-issue.sh -u temp -d 30 -s https://10.0.0.1:6443 \
  --start "+1d" --bind

# 不在 master 上签发（拷出 CA，用完即删）
bash scripts/lease-issue.sh -u dev -d 30 -s https://10.0.0.1:6443 \
  --ca-cert ./ca.crt --ca-key ./ca.key

# 提前收回权限（证书还在，但已无权限）
bash scripts/lease-bind.sh -u dev --revoke
```

## 产物与命名规则

所有产物都落在 `output/`，命名有固定规律：

| 触发 | 产物 | 说明 |
|---|---|---|
| `lease.sh 30d -u dev ...` | `output/dev-30d.kubeconfig` | 凭证，30 天有效 |
| 追加 `--bind` | `output/dev-grant.yaml` | 授权；ClusterRoleBinding 名 `dev-grant`，默认 `view` |
| `lease-bind.sh -u dev --role edit` | `output/dev-grant.yaml` | 同样文件名，role 变为 `edit` |

- kubeconfig 文件名：`<用户>-<天数>d.kubeconfig`
- 授权文件名：`<用户>-grant.yaml`，绑定名：`<用户>-grant`
- 两者都可用 `-o` 自定义路径；绑定名可用 `--name` 覆盖

> 注意：`--bind` 只额外产出授权 YAML；`output/<用户>-<天数>d.kubeconfig` 由签发步骤产出，没有 `--bind` 就不会有 grant 文件。

## 验证

```bash
# 看证书起止时间
openssl x509 -in <(kubectl config view --raw \
  --kubeconfig=output/dev-30d.kubeconfig \
  -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d) \
  -noout -subject -dates
```

## 安全须知

- CA 私钥只在 master 或受控跳板使用，**不要提交 git、不要发到聊天工具**。
- `output/*.kubeconfig` 内含用户私钥，等同集群入场券，按密钥保管。
- 外包 / 临时账号请用 `view`，不要默认 `cluster-admin`。
- 续期 = 重新签发新证书（旧文件不会自动延长）。
- 节点时钟要准，否则 NotBefore / NotAfter 判断会偏。

## License

MIT
