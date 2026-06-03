# shellcheck shell=bash
# init.sh / deploy-site.sh 共用工具函数
# 此文件由两个入口脚本通过 source 引入，脚本独立运行时请使用 bootstrap.sh

if [[ "${DEPLOY_LOG_TEE:-0}" = "1" && -n "${LOG_FILE:-}" ]]; then
  # deploy-site：不重定向 stdout/stderr（避免 tee 子进程 SIGPIPE + 交互异常），输出函数写日志
  die()  { printf '✗ %s\n' "$*" | tee -a "$LOG_FILE" >&2; exit 1; }
  info() { printf '  %s\n' "$*" | tee -a "$LOG_FILE"; }
  ok()   { printf '  ✓ %s\n' "$*" | tee -a "$LOG_FILE"; }
  warn() { printf '  ! %s\n' "$*" | tee -a "$LOG_FILE"; }
  hr()   { printf '%s\n' "══════════════════════════════════════════════" | tee -a "$LOG_FILE"; }
else
  die()  { echo "✗ $*" >&2; exit 1; }
  info() { echo "  $*"; }
  ok()   { echo "  ✓ $*"; }
  warn() { echo "  ! $*"; }
  hr()   { echo "══════════════════════════════════════════════"; }
fi

interactive_tty_ok() {
  [[ -e /dev/tty ]] && { : >/dev/tty; } 2>/dev/null
}

confirm() {
  local msg="${1:-确认？}" default="${2:-y}" ans=""
  local prompt_str="[Y/n]"; [[ "$default" != "y" ]] && prompt_str="[y/N]"
  if interactive_tty_ok; then
    read -rp "  ${msg} ${prompt_str}: " ans </dev/tty 2>/dev/null || ans=""
  else
    read -rp "  ${msg} ${prompt_str}: " ans || ans=""
  fi
  ans=${ans:-$default}
  [[ "$ans" =~ ^[yY]$ ]]
}

prompt() {
  local msg="$1" default="${2:-}" var=""
  if interactive_tty_ok; then
    if [[ -n "$default" ]]; then
      read -rp "  ${msg} [${default}]: " var </dev/tty 2>/dev/null || var=""
    else
      read -rp "  ${msg}: " var </dev/tty 2>/dev/null || var=""
    fi
  else
    if [[ -n "$default" ]]; then
      read -rp "  ${msg} [${default}]: " var || var=""
    else
      read -rp "  ${msg}: " var || var=""
    fi
  fi
  PROMPT_RESULT="${var:-$default}"
  echo "$PROMPT_RESULT"
}

# 禁止 $(menu_select)；调用后读 MENU_SELECT_RESULT
menu_select() {
  local title="$1"; shift
  local -a items=("$@")
  echo ""
  info "$title"
  echo ""
  local i
  for i in "${!items[@]}"; do
    info "    $((i + 1))) ${items[$i]}"
  done
  echo ""
  info "回车或无效输入 = 第 1 项（推荐默认）"
  echo ""
  local choice raw
  if interactive_tty_ok; then
    read -rp "  选择 [1-${#items[@]}] (回车=第1项): " raw </dev/tty 2>/dev/null || raw=""
  else
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
