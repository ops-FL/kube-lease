#!/usr/bin/env bash
# =============================================================================
# lease.sh · kube-lease 快捷入口
# 把 30d / 7d / 365d 解析成天数，转交 lease-issue.sh。日常只用这一个。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="${SCRIPT_DIR}/lease-issue.sh"

usage() {
  cat <<EOF
lease.sh · kube-lease 快捷入口

用法:
  bash scripts/lease.sh Nd -u 用户 -s apiserver [lease-issue.sh 的其它参数]

说明:
  Nd      任意正整数天数，如 1d / 7d / 30d / 365d
  其余    原样传给 lease-issue.sh（注意不要再写 -d）

示例:
  sudo bash scripts/lease.sh 30d -u dev -s https://10.0.0.1:6443 --bind
  sudo bash scripts/lease.sh 40d -u contractor -s https://10.0.0.1:6443 --bind --role view
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in -h|--help) usage; exit 0 ;; esac

ARG="$1"; shift
if [[ ! "$ARG" =~ ^([1-9][0-9]*)d$ ]]; then
  usage
  echo "错误: 第一个参数需形如 Nd（如 30d）" >&2
  exit 1
fi
DAYS="${BASH_REMATCH[1]}"

exec bash "$MAIN" -d "$DAYS" "$@"
