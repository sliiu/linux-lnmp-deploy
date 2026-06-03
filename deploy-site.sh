#!/bin/bash
set -euo pipefail

VERSION="2.0.0"
CONF_FILE="/etc/lnmp-env.conf"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
ACME_SSL_DNS_DEFAULT="${ACME_SSL_DNS_DEFAULT:-webroot}"
DATA_DIR="${LNMP_DATA_DIR:-/data/docker-lnmp}"
CONTAINER_WWW="${CONTAINER_WWW:-${DATA_DIR}/www}"
WWW_ROOT="${DATA_DIR}/www"
NGINX_CONF="${DATA_DIR}/nginx/conf.d"
SSL_DIR="${DATA_DIR}/ssl"
# 无 per-site 文件时的全局默认 SSE 前缀（空格分隔）；每站点可写 ${NGINX_CONF}/<域名>.sse-prefixes 覆盖
LARAVEL_SSE_PREFIXES="${LARAVEL_SSE_PREFIXES:-wave}"

mkdir -p "${DATA_DIR}/logs" 2>/dev/null || true
LOG_FILE="${DATA_DIR}/logs/deploy-site.log"
# 用命名管道替代进程替换，避免 set -euo pipefail 下 tee 子进程退出触发意外 exit
_LOG_PIPE="${DATA_DIR}/logs/.deploy-site-$$.pipe"
mkfifo "$_LOG_PIPE" 2>/dev/null || true
if command -v stdbuf &>/dev/null; then
  stdbuf -oL -eL tee -a "$LOG_FILE" < "$_LOG_PIPE" &
else
  tee -a "$LOG_FILE" < "$_LOG_PIPE" &
fi
_TEE_PID=$!
exec > "$_LOG_PIPE" 2>&1
# 脚本退出时清理管道和 tee 进程
trap 'exec >/dev/null 2>&1; rm -f "$_LOG_PIPE"; wait "$_TEE_PID" 2>/dev/null || true' EXIT
echo "===== $(date '+%Y-%m-%d %H:%M:%S') START $0 $* pid=$$ ====="

# 与 docker-compose 中 lnmp-nginx user 101:101 一致
readonly NGINX_C_UID=101
readonly NGINX_C_GID=101
# PHP-FPM 容器内 uid（与 init.sh docker-compose 中 php 镜像默认 www-data 82 一致）
readonly PHP_C_UID=82
readonly PHP_C_GID=82

# ═══════════════════════════════════════════════
#  lib 加载（本地优先，缺失时从 Gitee 自动下载）
# ═══════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_RAW_BASE="${_LIB_RAW_BASE:-https://gitee.com/qing-u/alibaba-cloud-ecs-deployment/raw/main}"
_LIB_TMPDIR=""

_source_lib() {
  local rel="$1"
  local path="${SCRIPT_DIR}/${rel}"
  if [[ ! -f "$path" ]]; then
    if [[ -z "$_LIB_TMPDIR" ]]; then
      _LIB_TMPDIR="$(mktemp -d)"
      trap 'rm -rf "$_LIB_TMPDIR"' EXIT
    fi
    local fname="${rel##*/}"
    path="${_LIB_TMPDIR}/${fname}"
    local url="${_LIB_RAW_BASE}/${rel}"
    echo "  ↓ 下载依赖 ${rel} ..." >&2
    if command -v curl &>/dev/null; then
      curl -fsSL "$url" -o "$path" || { echo "✗ 下载失败: ${url}" >&2; exit 1; }
    elif command -v wget &>/dev/null; then
      wget -qO "$path" "$url" || { echo "✗ 下载失败: ${url}" >&2; exit 1; }
    else
      echo "✗ 缺少 curl/wget，无法下载依赖: ${rel}" >&2; exit 1
    fi
  fi
  # shellcheck disable=SC1090
  . "$path"
}

_source_lib lib/common.sh
_source_lib lib/deploy/tools.sh
_source_lib lib/deploy/perms.sh
_source_lib lib/deploy/nginx.sh
_source_lib lib/deploy/ssl.sh
_source_lib lib/deploy/git.sh
_source_lib lib/deploy/webhook.sh
_source_lib lib/deploy/cmd-add.sh
_source_lib lib/deploy/cmd-remove.sh
_source_lib lib/deploy/cmd-list.sh
_source_lib lib/deploy/cmd-ssl.sh
_source_lib lib/deploy/cmd-webhook.sh

# ═══════════════════════════════════════════════
#  主入口
# ═══════════════════════════════════════════════
main() {
  local cmd="${1:-}"

  case "$cmd" in
    -h|--help) usage; exit 0 ;;
    add)    shift; parse_args "$@"; cmd_add ;;
    update) shift; parse_args "$@"; cmd_update ;;
    rollback) shift; parse_args "$@"; cmd_rollback ;;
    webhook) shift; cmd_webhook "$@" ;;
    remove) shift; parse_args "$@"; cmd_remove ;;
    list)   cmd_list ;;
    status) shift; parse_args "$@"; cmd_status ;;
    ssl)    shift; parse_args "$@"; cmd_ssl ;;
    "")
      clear 2>/dev/null || true
      while true; do
        hr
        printf "  多站点部署管理 v%s\n" "${VERSION}"
        hr
        local _idx
        _idx=$(menu_select "请选择操作" \
          "查看站点列表（推荐先看一眼）" \
          "部署新站点" \
          "更新站点" \
          "Webhook 自动部署" \
          "回退站点版本" \
          "站点运行状态（含证书 / FPM / nginx 日志）" \
          "SSL 证书签发/续期" \
          "移除站点" \
          "退出")
        echo ""
        case "$_idx" in
          0) cmd_list ;;
          1) cmd_add ;;
          2) cmd_update ;;
          3) cmd_webhook ;;
          4) cmd_rollback ;;
          5) STATUS_ALL=0; DOMAIN=""; cmd_status ;;
          6) cmd_ssl ;;
          7) cmd_remove ;;
          8) ok "再见"; exit 0 ;;
        esac
        echo ""
        if ! confirm "返回主菜单？" "y"; then
          ok "再见"; exit 0
        fi
        clear 2>/dev/null || true
      done
      ;;
    *)
      usage; die "未知命令: $cmd"
      ;;
  esac
}

main "$@"
