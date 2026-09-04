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
  payload="$(NOTIFY_URL="$url" python3 -c '
import json, os, sys
content = sys.argv[1]
url = os.environ.get("NOTIFY_URL", "")
if "dingtalk.com" in url:
    body = {"msgtype": "markdown", "markdown": {"title": content.splitlines()[0][:80] if content else "部署异常", "text": content}}
else:
    body = {"msgtype": "markdown", "markdown": {"content": content}}
print(json.dumps(body, ensure_ascii=False))
' "$content")" || return 0
  curl -fsS --connect-timeout 8 --max-time 15 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1 || true
}

ops_notify_exception() {
  local title="$1" err="$2" host site cmd args logtail md
  host="$(hostname -s 2>/dev/null || hostname || echo unknown)"
  site="${_deploy_log_bound_domain:-${DOMAIN:-—}}"
  cmd="${DEPLOY_SESSION_CMD:-}"
  args="${DEPLOY_SESSION_ARGS:-}"
  logtail=""
  if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    logtail="$(tail -n 20 "$LOG_FILE" 2>/dev/null | sed 's/`/'"'"'/g')"
  fi
  md="$(printf '**%s**\n> <font color="warning">%s</font>\n\n- 主机: `%s`\n- 站点: `%s`\n- 时间: `%s`\n- pid: `%s`' \
    "$title" "$err" "$host" "$site" "$(date '+%Y-%m-%d %H:%M:%S')" "$$")"
  [[ -n "$cmd" ]] && md+=$(printf '\n- 命令: `%s %s`' "$cmd" "$args")
  [[ -n "${LOG_FILE:-}" ]] && md+=$(printf '\n- 日志: `%s`' "$LOG_FILE")
  [[ -n "$logtail" ]] && md+=$(printf '\n\n**日志尾部**\n<pre>%s</pre>' "$logtail")
  ops_notify "$md"
}

die() {
  if [[ "${DEPLOY_LOG_TEE:-0}" = "1" && -n "${LOG_FILE:-}" ]]; then
    printf '[%s] ✗ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
  fi
  printf '✗ %s\n' "$*" >&2
  if ! interactive_tty_ok; then
    ops_notify_exception "部署异常" "$*"
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

# 交互：warn 并 return 1（回到菜单）；非 TTY：die
menu_fail() {
  if interactive_tty_ok; then
    warn "$1"
    return 1
  fi
  die "$1"
}

# 循环直到非空；非 TTY 空输入则 die
prompt_required() {
  local msg="$1" default="${2:-}"
  while true; do
    prompt "$msg" "$default"
    [[ -n "$PROMPT_RESULT" ]] && return 0
    if interactive_tty_ok; then
      warn "不能为空"
    else
      die "${msg} 不能为空"
    fi
  done
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
  local choice raw i n="${#items[@]}"
  if interactive_tty_ok; then
    _ui_tty ""
    _ui_tty "  ${title}"
    _ui_tty ""
    for i in "${!items[@]}"; do
      _ui_tty "    $((i + 1))) ${items[$i]}"
    done
    _ui_tty ""
  else
    echo ""
    info "$title"
    echo ""
    for i in "${!items[@]}"; do
      info "    $((i + 1))) ${items[$i]}"
    done
    echo ""
  fi
  while true; do
    if interactive_tty_ok; then
      printf '  选择 [1-%s] (回车=第1项): ' "$n" >/dev/tty
      read -r raw </dev/tty 2>/dev/null || raw=""
      printf '\n' >/dev/tty
    else
      read -rp "  选择 [1-${n}] (回车=第1项): " raw || raw=""
    fi
    if [[ -z "$raw" ]]; then
      choice=0
      break
    fi
    if [[ "$raw" =~ ^[1-9][0-9]*$ ]]; then
      choice=$((raw - 1))
      [[ $choice -ge 0 && $choice -lt $n ]] && break
    fi
    if interactive_tty_ok; then
      _ui_tty "  无效输入，请输入 1-${n}"
    else
      warn "无效输入，请输入 1-${n}"
    fi
  done
  MENU_SELECT_RESULT=$choice
}

_web_container() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^lnmp-php$'; then
    printf 'lnmp-php'
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^lnmp-caddy$'; then
    printf 'lnmp-caddy'
  else
    printf 'lnmp-php'
  fi
}

_web_bin() {
  local c="${1:-$(_web_container)}"
  if docker exec "$c" command -v frankenphp >/dev/null 2>&1; then
    printf 'frankenphp'
  else
    printf 'caddy'
  fi
}

caddy_validate() {
  local c="${1:-$(_web_container)}"
  docker exec "$c" "$(_web_bin "$c")" validate --config /etc/caddy/Caddyfile
}

caddy_reload() {
  local c="${1:-$(_web_container)}"
  docker exec "$c" "$(_web_bin "$c")" reload --config /etc/caddy/Caddyfile
}

_caddy_reload_soft() {
  local msg="${1:-Caddy 已 reload}"
  local c; c="$(_web_container)"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$"; then
    if caddy_validate "$c"; then
      caddy_reload "$c" 2>/dev/null && ok "$msg" || warn "Caddy reload 失败"
    else
      warn "Caddy 配置校验失败，未 reload"
    fi
  fi
}

_php_franken_ok() {
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
  _lv_ge "$v" "8.2" && _lv_ge "8.5" "$v"
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
