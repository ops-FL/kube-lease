#!/usr/bin/env bash
# =============================================================================
# lease-issue.sh · kube-lease
# 签发「带起止时间」的客户端证书，并组装成内嵌证书的 kubeconfig。
#
#   证书 CN = 用户, O = 组；时间由 NotBefore / NotAfter 控制。
#   授权另走 lease-bind.sh（认证与授权分离）。
#
# 用法:
#   sudo bash scripts/lease-issue.sh -u 用户 -d 天数 -s apiserver [选项]
# =============================================================================
set -euo pipefail

LEASE_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/output}"

# ---------- 终端配色 ----------
if [[ -t 2 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_END=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_END=""
fi
info() { printf '%s==>%s %s\n' "$C_OK"   "$C_END" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_END" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR"  "$C_END" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
lease-issue.sh v${LEASE_VERSION} · kube-lease
签发带起止时间的客户端证书，并生成 kubeconfig。

必填:
  -u, --user    USER       证书 CN，也是授权时的 User 名
  -d, --days    DAYS       有效天数（正整数）
  -s, --server  SERVER     apiserver 地址，如 https://10.0.0.1:6443

CA:
      --ca-dir   DIR       证书目录，默认 /etc/kubernetes/pki
      --ca-cert  FILE      直接指定 CA 证书（默认 <ca-dir>/ca.crt）
      --ca-key   FILE      直接指定 CA 私钥（默认 <ca-dir>/ca.key）

身份 / 输出:
  -g, --group   GROUP      证书 O，默认等于 USER
  -o, --output  FILE       默认 output/<user>-<days>d.kubeconfig
      --start    TIME      生效时间，默认立即；支持 +1d/+24h/+30m/"YYYY-MM-DD HH:MM:SS"
      --cluster  NAME      kubeconfig 集群名，默认 kubernetes
      --context  NAME      默认 <user>@<cluster>
      --force              输出已存在时覆盖

授权:
      --bind               同时生成 RBAC YAML
      --role     ROLE      配合 --bind；view/edit/admin/cluster-admin，默认 view

其它:
  -h, --help               显示帮助
      --version            显示版本
EOF
}

USER=""; DAYS=""; SERVER=""
CA_DIR="/etc/kubernetes/pki"; CA_CERT=""; CA_KEY=""
GROUP=""; OUTPUT=""; START=""; CLUSTER="kubernetes"; CONTEXT=""
DO_BIND=false; ROLE="view"; FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)     USER="$2"; shift 2 ;;
    -d|--days)     DAYS="$2"; shift 2 ;;
    -s|--server)   SERVER="$2"; shift 2 ;;
    --ca-dir)      CA_DIR="$2"; shift 2 ;;
    --ca-cert)     CA_CERT="$2"; shift 2 ;;
    --ca-key)      CA_KEY="$2"; shift 2 ;;
    -g|--group)    GROUP="$2"; shift 2 ;;
    -o|--output)   OUTPUT="$2"; shift 2 ;;
    --start)       START="$2"; shift 2 ;;
    --cluster)     CLUSTER="$2"; shift 2 ;;
    --context)     CONTEXT="$2"; shift 2 ;;
    --bind)        DO_BIND=true; shift ;;
    --role)        ROLE="$2"; shift 2 ;;
    --force)       FORCE=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    --version)     echo "$LEASE_VERSION"; exit 0 ;;
    *)             die "未知参数: $1（用 -h 查看帮助）" ;;
  esac
done

[[ -n "$USER"   ]] || { usage; die "缺少 -u/--user"; }
[[ -n "$DAYS"   ]] || { usage; die "缺少 -d/--days"; }
[[ -n "$SERVER" ]] || { usage; die "缺少 -s/--server"; }
[[ "$DAYS" =~ ^[1-9][0-9]*$ ]] || die "天数必须是正整数: $DAYS"
[[ "$SERVER" == https://* || "$SERVER" == http://* ]] || warn "server 建议以 https:// 开头: $SERVER"

GROUP="${GROUP:-$USER}"
CONTEXT="${CONTEXT:-${USER}@${CLUSTER}}"
[[ -n "$CA_CERT" ]] || CA_CERT="${CA_DIR}/ca.crt"
[[ -n "$CA_KEY"  ]] || CA_KEY="${CA_DIR}/ca.key"
mkdir -p "$OUT_DIR"
OUTPUT="${OUTPUT:-${OUT_DIR}/${USER}-${DAYS}d.kubeconfig}"

[[ -f "$CA_CERT" ]] || die "找不到 CA 证书: $CA_CERT"
[[ -f "$CA_KEY"  ]] || die "找不到 CA 私钥: $CA_KEY（通常在 master 上且需要 sudo）"
command -v openssl >/dev/null || die "未安装 openssl"
command -v kubectl >/dev/null || die "未安装 kubectl"

if [[ -e "$OUTPUT" && "$FORCE" != true ]]; then
  die "输出已存在: $OUTPUT（加 --force 覆盖）"
fi

# ---------- 时间计算（GNU / BSD date 自适应） ----------
have_gnu_date() { date -u -d "@0" +%s >/dev/null 2>&1; }
epoch_to_asn1() {
  local e="$1"
  if have_gnu_date; then date -u -d "@${e}" +%Y%m%d%H%M%SZ
  else                   date -u -r "${e}" +%Y%m%d%H%M%SZ; fi
}
parse_start_epoch() {
  local arg="${1:-}"
  [[ -z "$arg" ]] && { date -u +%s; return; }
  if [[ "$arg" == +* ]]; then
    local s="${arg:1}" n unit
    n="${s%%[a-zA-Z]*}"; unit="${s#"$n"}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "无效 --start: $arg"
    case "$unit" in h|d|m|"") : ;; *) die "无效 --start 单位: $arg（支持 +N d/h/m）" ;; esac
    if have_gnu_date; then
      case "$unit" in ""|h) date -u -d "+${n} hours" +%s ;; d) date -u -d "+${n} days" +%s ;; m) date -u -d "+${n} minutes" +%s ;; esac
    else
      case "$unit" in ""|h) date -u -v+"${n}"H +%s ;; d) date -u -v+"${n}"d +%s ;; m) date -u -v+"${n}"M +%s ;; esac
    fi
    return
  fi
  if have_gnu_date; then date -d "$arg" +%s
  else                   date -j -f "%Y-%m-%d %H:%M:%S" "$arg" +%s; fi
}

START_EPOCH="$(parse_start_epoch "$START")" || die "解析 --start 失败: $START"
END_EPOCH=$(( START_EPOCH + DAYS * 86400 ))
NOT_BEFORE="$(epoch_to_asn1 "$START_EPOCH")"
NOT_AFTER="$(epoch_to_asn1 "$END_EPOCH")"

# ---------- 临时工作区（退出自动清理） ----------
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
KEY="${WORK}/user.key"; CSR="${WORK}/user.csr"; CRT="${WORK}/user.crt"

# ---------- 1. 私钥 + CSR ----------
info "生成密钥与 CSR（CN=${USER}, O=${GROUP}）"
openssl genrsa -out "$KEY" 2048 2>/dev/null
openssl req -new -key "$KEY" -out "$CSR" -subj "/O=${GROUP}/CN=${USER}"

# ---------- 2. 集群 CA 签发（限定起止 + clientAuth） ----------
info "签发客户端证书（${NOT_BEFORE} ~ ${NOT_AFTER}）"
mkdir -p "${WORK}/newcerts"
: > "${WORK}/index.txt"
echo "unique_subject = no" > "${WORK}/index.txt.attr"
openssl rand -hex 8 > "${WORK}/serial"
cat > "${WORK}/ca.conf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${WORK}
database          = ${WORK}/index.txt
serial            = ${WORK}/serial
new_certs_dir     = ${WORK}/newcerts
certificate       = ${CA_CERT}
private_key       = ${CA_KEY}
default_md        = sha256
default_days      = ${DAYS}
rand_serial       = yes
unique_subject    = no
email_in_dn       = no
policy            = policy_match
x509_extensions   = usr_cert

[ policy_match ]
organizationName  = optional
commonName        = supplied

[ usr_cert ]
basicConstraints       = CA:FALSE
keyUsage               = digitalSignature, keyEncipherment
extendedKeyUsage       = clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl ca -batch -notext \
  -config "${WORK}/ca.conf" \
  -in  "$CSR" \
  -out "$CRT" \
  -startdate "$NOT_BEFORE" \
  -enddate   "$NOT_AFTER" >/dev/null

# ---------- 3. 组装 kubeconfig（内嵌证书） ----------
info "写入 kubeconfig: $OUTPUT"
KUBECONFIG="$OUTPUT" kubectl config set-cluster "$CLUSTER" \
  --server="$SERVER" --certificate-authority="$CA_CERT" --embed-certs=true >/dev/null
KUBECONFIG="$OUTPUT" kubectl config set-credentials "$USER" \
  --client-certificate="$CRT" --client-key="$KEY" --embed-certs=true >/dev/null
KUBECONFIG="$OUTPUT" kubectl config set-context "$CONTEXT" \
  --cluster="$CLUSTER" --user="$USER" >/dev/null
KUBECONFIG="$OUTPUT" kubectl config use-context "$CONTEXT" >/dev/null
chmod 600 "$OUTPUT"

# ---------- 4. 可选授权 ----------
if [[ "$DO_BIND" == true ]]; then
  info "生成授权 YAML（role=${ROLE}）"
  bash "${SCRIPT_DIR}/lease-bind.sh" -u "$USER" -g "$GROUP" --role "$ROLE" \
    -o "${OUT_DIR}/${USER}-grant.yaml"
fi

# ---------- 汇总 ----------
echo >&2
info "完成 ✔"
printf '  用户 / 组 : %s / %s\n' "$USER" "$GROUP" >&2
printf '  生效时间  : %s\n' "$NOT_BEFORE" >&2
printf '  失效时间  : %s\n' "$NOT_AFTER" >&2
printf '  kubeconfig: %s\n' "$OUTPUT" >&2
[[ "$DO_BIND" == true ]] && printf '  授权 YAML : %s\n' "${OUT_DIR}/${USER}-grant.yaml" >&2
printf '%s提示: 请在有权限的机器上 apply 授权文件，否则会报 Forbidden。%s\n' "$C_DIM" "$C_END" >&2
