# shellcheck shell=bash
# init.sh / deploy-site.sh 共用工具函数
# 此文件由两个入口脚本通过 source 引入，脚本独立运行时请使用 bootstrap.sh

_deploy_log_bound_domain=""

_deploy_log_safe_slug() {
  local s="$1"
  s="${s//\//_}"
  s="${s// /_}"
  printf '%s' "$s"
}

# 日志：${DATA_DIR}/logs/<域名>/YYYY-MM-DD.log；无域名时用 _global/YYYY-MM-DD.log
deploy_log_init() {
  local domain="${1:-}" slug base="${DATA_DIR:-/data/docker-lnmp}/logs" day
  day="$(date '+%Y-%m-%d')"
  if [[ -n "$domain" ]]; then
    slug="$(_deploy_log_safe_slug "$domain")"
    mkdir -p "${base}/${slug}"
    LOG_FILE="${base}/${slug}/${day}.log"
    _deploy_log_bound_domain="$domain"
  else
    mkdir -p "${base}/_global"
    LOG_FILE="${base}/_global/${day}.log"
    _deploy_log_bound_domain=""
  fi
  export LOG_FILE
}

deploy_log_bind_domain() {
  local d="${1:-}"
  [[ -z "$d" ]] && return 0
  [[ "$d" = "${_deploy_log_bound_domain:-}" ]] && return 0
  deploy_log_init "$d"
  deploy_log_session_start "${DEPLOY_SESSION_CMD:-deploy-site}" "${DEPLOY_SESSION_ARGS:-}"
}

deploy_log_session_start() {
  local cmd="${1:-deploy-site}" args="${2:-}"
  info "===== $(date '+%Y-%m-%d %H:%M:%S') START ${cmd} ${args} pid=$$ log=${LOG_FILE} ====="
}

_deploy_log_out() {
  if [[ "${DEPLOY_LOG_TEE:-0}" = "1" && -n "${LOG_FILE:-}" ]]; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
  fi
  printf '%s\n' "$1"
}

ops_notify() {
  local content="$1" url payload envf
  envf="${DATA_DIR:-/data/docker-lnmp}/webhook/listener.env"
  [[ -f "${CONF_FILE:-/etc/lnmp-env.conf}" ]] && source "${CONF_FILE:-/etc/lnmp-env.conf}" 2>/dev/null || true
  [[ -f "$envf" ]] && source "$envf" 2>/dev/null || true
  url="${WEBHOOK_NOTIFY_URL:-}"
  [[ -n "$url" ]] || return 0
  command -v python3 &>/dev/null && command -v curl &>/dev/null || return 0
  payload="$(python3 -c 'import json,sys; print(json.dumps({"msgtype":"text","text":{"content":sys.argv[1]}},ensure_ascii=False))' "$content")" || return 0
  curl -fsS --connect-timeout 8 --max-time 15 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1 || true
}

die() {
  if [[ "${DEPLOY_LOG_TEE:-0}" = "1" && -n "${LOG_FILE:-}" ]]; then
    printf '[%s] ✗ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
  fi
  printf '✗ %s\n' "$*" >&2
  if ! interactive_tty_ok; then
    ops_notify "$(printf '部署异常\n主机: %s\n站点: %s\n错误: %s\n时间: %s\n日志: %s' \
      "$(hostname -s 2>/dev/null || hostname || echo unknown)" \
      "${_deploy_log_bound_domain:-${DOMAIN:-?}}" "$*" \
      "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_FILE:-}")"
  fi
  exit 1
}
info() { _deploy_log_out "  $*"; }
ok()   { _deploy_log_out "  ✓ $*"; }
warn() { _deploy_log_out "  ! $*"; }
hr()   { _deploy_log_out "══════════════════════════════════════════════"; }

interactive_tty_ok() {
  [[ -e /dev/tty ]] && { : >/dev/tty; } 2>/dev/null
}

# init.sh 等将 stdout 重定向到 tee 管道时，交互菜单须直接写终端
_ui_tty() {
  if interactive_tty_ok; then
    printf '%s\n' "$@" >/dev/tty
  else
    printf '%s\n' "$@"
  fi
}

confirm() {
  local msg="${1:-确认？}" default="${2:-y}" ans=""
  local prompt_str="[Y/n]"; [[ "$default" != "y" ]] && prompt_str="[y/N]"
  if interactive_tty_ok; then
    printf '  %s %s: ' "${msg}" "${prompt_str}" >/dev/tty
    read -r ans </dev/tty 2>/dev/null || ans=""
    printf '\n' >/dev/tty
  else
    read -rp "  ${msg} ${prompt_str}: " ans || ans=""
  fi
  ans=${ans:-$default}
  [[ "$ans" =~ ^[yY]$ ]]
}

prompt() {
  local msg="$1" default="${2:-}" var=""
  if interactive_tty_ok; then
    _ui_tty ""
    if [[ -n "$default" ]]; then
      _ui_tty "  ${msg}（回车 = ${default}）"
    else
      _ui_tty "  ${msg}"
    fi
    _ui_tty ""
    printf '  请输入: ' >/dev/tty
    read -r var </dev/tty || var=""
    printf '\n' >/dev/tty
  else
    echo ""
    if [[ -n "$default" ]]; then
      info "${msg}（回车 = ${default}）"
    else
      info "${msg}"
    fi
    echo ""
    read -rp "  请输入: " var || var=""
  fi
  PROMPT_RESULT="${var:-$default}"
  echo "$PROMPT_RESULT"
}

# 敏感输入：不回显到 stdout（禁止 $(prompt_secret)）
prompt_secret() {
  local msg="$1" var=""
  echo ""
  info "${msg}"
  echo ""
  if interactive_tty_ok; then
    read -rsp "  请输入: " var </dev/tty || var=""
    echo "" >/dev/tty 2>/dev/null || echo ""
  else
    read -rsp "  请输入: " var || var=""
    echo ""
  fi
  PROMPT_RESULT="$var"
}

# 禁止 $(prompt)；调用后读 PROMPT_RESULT

# 禁止 $(menu_select)；调用后读 MENU_SELECT_RESULT
menu_select() {
  local title="$1"; shift
  local -a items=("$@")
  local choice raw i
  if interactive_tty_ok; then
    _ui_tty ""
    _ui_tty "  ${title}"
    _ui_tty ""
    for i in "${!items[@]}"; do
      _ui_tty "    $((i + 1))) ${items[$i]}"
    done
    _ui_tty ""
    _ui_tty "  回车或无效输入 = 第 1 项（推荐默认）"
    _ui_tty ""
    printf '  选择 [1-%s] (回车=第1项): ' "${#items[@]}" >/dev/tty
    read -r raw </dev/tty 2>/dev/null || raw=""
    printf '\n' >/dev/tty
  else
    echo ""
    info "$title"
    echo ""
    for i in "${!items[@]}"; do
      info "    $((i + 1))) ${items[$i]}"
    done
    echo ""
    info "回车或无效输入 = 第 1 项（推荐默认）"
    echo ""
    read -rp "  选择 [1-${#items[@]}] (回车=第1项): " raw || raw=""
  fi
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    choice=$((raw - 1))
  else
    choice=-1
  fi
  [[ $choice -ge 0 && $choice -lt ${#items[@]} ]] || choice=0
  MENU_SELECT_RESULT=$choice
}

# 主.次版本号比较：_lv_ge "5.7" "5.6" → 0
_lv_ge() {
  local a="$1" b="$2" a1 a2 b1 b2
  a1="${a%%.*}"; a2="${a#*.}"; [[ "$a2" = "$a" ]] && a2=0
  b1="${b%%.*}"; b2="${b#*.}"; [[ "$b2" = "$b" ]] && b2=0
  a1="${a1//[^0-9]/}"; a2="${a2%%.*}"; a2="${a2//[^0-9]/}"
  b1="${b1//[^0-9]/}"; b2="${b2%%.*}"; b2="${b2//[^0-9]/}"
  : "${a1:=0}"; : "${a2:=0}"; : "${b1:=0}"; : "${b2:=0}"
  if [[ $a1 -ne $b1 ]]; then [[ $a1 -gt $b1 ]]; return $?; fi
  [[ $a2 -ge $b2 ]]
}

# RHEL/Amazon Linux: cronie；Debian/Ubuntu: cron
ensure_crontab() {
  command -v crontab &>/dev/null && return 0
  info "安装 cron（未找到 crontab）..."
  if command -v dnf &>/dev/null; then
    dnf install -y cronie 2>/dev/null || return 1
    systemctl enable --now crond 2>/dev/null || true
  elif command -v yum &>/dev/null; then
    yum install -y cronie 2>/dev/null || return 1
    systemctl enable --now crond 2>/dev/null || true
  elif command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y cron 2>/dev/null || return 1
    systemctl enable --now cron 2>/dev/null || true
  else
    return 1
  fi
  command -v crontab &>/dev/null
}
