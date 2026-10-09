#!/usr/bin/env bash
# =============================================================================
# lease-bind.sh · kube-lease
# 证书只有「身份」。要能访问 API，还得把身份绑到 ClusterRole。
# 本脚本负责授权：生成 / 应用 / 撤销（--revoke 即时收回权限）。
# 同时绑定 User 与 Group 两个 subject：任一匹配即可放行。
# =============================================================================
set -euo pipefail

LEASE_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/output}"

if [[ -t 2 ]]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_END=$'\033[0m'
else
  C_OK=""; C_ERR=""; C_END=""
fi
info() { printf '%s==>%s %s\n' "$C_OK"  "$C_END" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_END" "$*" >&2; exit 1; }

VALID_ROLES="view edit admin cluster-admin"

usage() {
  cat <<EOF
lease-bind.sh v${LEASE_VERSION} · kube-lease
为证书身份生成 / 应用 / 撤销 RBAC 授权。

必填:
  -u, --user    USER     证书 CN（与 kubeconfig 用户一致）

选项:
  -g, --group   GROUP    证书 O，默认等于 USER
      --role    ROLE     可选: ${VALID_ROLES}（默认 view）
  -o, --output  FILE     输出 YAML，默认 output/<user>-grant.yaml
      --name    NAME     ClusterRoleBinding 名称，默认 <user>-grant
      --apply            生成后立即 kubectl apply
      --revoke           撤销该授权（即时生效，需 kubectl 权限）
  -h, --help             显示帮助
      --version          显示版本
EOF
}

USER=""; GROUP=""; ROLE="view"; OUTPUT=""; NAME=""; APPLY=false; REVOKE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)    USER="$2"; shift 2 ;;
    -g|--group)   GROUP="$2"; shift 2 ;;
    --role)       ROLE="$2"; shift 2 ;;
    -o|--output)  OUTPUT="$2"; shift 2 ;;
    --name)       NAME="$2"; shift 2 ;;
    --apply)      APPLY=true; shift ;;
    --revoke)     REVOKE=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    --version)    echo "$LEASE_VERSION"; exit 0 ;;
    *)            die "未知参数: $1（用 -h 查看帮助）" ;;
  esac
done

[[ -n "$USER" ]] || { usage; die "缺少 -u/--user"; }
GROUP="${GROUP:-$USER}"
NAME="${NAME:-${USER}-grant}"

case " $VALID_ROLES " in
  *" $ROLE "*) : ;;
  *) die "非法 role: $ROLE（可选: ${VALID_ROLES}）" ;;
esac

# ---------- 撤销模式 ----------
if [[ "$REVOKE" == true ]]; then
  command -v kubectl >/dev/null || die "未安装 kubectl"
  info "撤销授权: $NAME"
  kubectl delete clusterrolebinding "$NAME" --ignore-not-found
  info "已撤销（证书本身仍在，但已无任何权限）"
  exit 0
fi

# ---------- 生成 YAML ----------
mkdir -p "$OUT_DIR"
OUTPUT="${OUTPUT:-${OUT_DIR}/${USER}-grant.yaml}"

cat > "$OUTPUT" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAME}
  labels:
    managed-by: kube-lease
subjects:
  - kind: User
    name: ${USER}
    apiGroup: rbac.authorization.k8s.io
  - kind: Group
    name: ${GROUP}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${ROLE}
  apiGroup: rbac.authorization.k8s.io
EOF

info "已生成授权 YAML: $OUTPUT"

if [[ "$APPLY" == true ]]; then
  command -v kubectl >/dev/null || die "未安装 kubectl"
  info "kubectl apply -f $OUTPUT"
  kubectl apply -f "$OUTPUT"
fi
