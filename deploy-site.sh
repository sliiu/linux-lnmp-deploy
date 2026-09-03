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
export DEPLOY_LOG_TEE=1
export DEPLOY_SESSION_CMD="$0"
export DEPLOY_SESSION_ARGS="$*"
readonly NGINX_C_UID=101
readonly NGINX_C_GID=101
# PHP-FPM 容器内 uid（与 init.sh docker-compose 中 php 镜像默认 www-data 82 一致）
readonly PHP_C_UID=82
readonly PHP_C_GID=82

# ═══════════════════════════════════════════════
#  lib 加载（本地优先，缺失时从 Gitee 自动下载）
# ═══════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_RAW_BASE="${_LIB_RAW_BASE:-https://gitee.com/sliiu/alibaba-cloud-ecs-deployment/raw/main}"
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
_source_lib lib/deploy/db.sh
_source_lib lib/deploy/perms.sh
_source_lib lib/deploy/nginx.sh
_source_lib lib/deploy/pm2.sh
_source_lib lib/deploy/ssl.sh
_source_lib lib/deploy/git.sh
_source_lib lib/deploy/webhook.sh
_source_lib lib/deploy/cmd-add.sh
_source_lib lib/deploy/cmd-remove.sh
_source_lib lib/deploy/cmd-list.sh
_source_lib lib/deploy/cmd-ssl.sh
_source_lib lib/deploy/cmd-webhook.sh

deploy_log_init ""
deploy_log_session_start "$0" "$*"

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
      while true; do
        clear 2>/dev/null || true
        hr
        printf "  多站点部署管理 v%s\n" "${VERSION}"
        hr
        local _idx
        menu_select "请选择操作" \
          "查看站点列表（推荐先看一眼）" \
          "部署新站点" \
          "更新站点" \
          "Webhook 自动部署" \
          "回退站点版本" \
          "站点运行状态（含证书 / FPM / nginx 日志）" \
          "SSL 证书签发/续期" \
          "移除站点" \
          "退出"
        _idx=$MENU_SELECT_RESULT
        echo ""
        case "$_idx" in
          0) cmd_list ;;
          1) reset_menu_deploy_state; cmd_add ;;
          2) reset_menu_deploy_state; cmd_update ;;
          3) reset_menu_deploy_state; cmd_webhook ;;
          4) reset_menu_deploy_state; cmd_rollback ;;
          5) reset_menu_deploy_state; STATUS_ALL=0; cmd_status ;;
          6) reset_menu_deploy_state; cmd_ssl ;;
          7) reset_menu_deploy_state; cmd_remove ;;
          8) ok "再见"; exit 0 ;;
        esac
        echo ""
      done
      ;;
    *)
      usage; die "未知命令: $cmd"
      ;;
  esac
}

main "$@"
