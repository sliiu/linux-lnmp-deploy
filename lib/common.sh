# shellcheck shell=bash
# init.sh / deploy-site.sh 共用工具函数
# 此文件由两个入口脚本通过 source 引入，脚本独立运行时请使用 bootstrap.sh

die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
hr()   { echo "══════════════════════════════════════════════"; }

# deploy-site 将 stdout/stderr 重定向到日志管道后，[[ -t 0 ]] 常为假。
# 交互优先 /dev/tty；不可用时回退 stdout/stdin，避免 set -e 因 >/dev/tty 失败而静默退出。
interactive_tty_ok() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

_ui_out() {
  if interactive_tty_ok; then
    cat > /dev/tty || cat
  else
    cat
  fi
}

_ui_read() {
  if interactive_tty_ok; then
    read -r "$@" </dev/tty 2>/dev/tty || true
  else
    read -r "$@" || true
  fi
}

confirm() {
  local msg="${1:-确认？}" default="${2:-y}" ans=""
  local prompt_str="[Y/n]"; [[ "$default" != "y" ]] && prompt_str="[y/N]"
  _ui_read -rp "  ${msg} ${prompt_str}: " ans
  ans=${ans:-$default}
  [[ "$ans" =~ ^[yY]$ ]]
}

prompt() {
  local msg="$1" default="${2:-}" var=""
  if [[ -n "$default" ]]; then
    _ui_read -rp "  ${msg} [${default}]: " var
  else
    _ui_read -rp "  ${msg}: " var
  fi
  echo "${var:-$default}"
}

menu_select() {
  local title="$1"; shift
  local -a items=("$@")
  {
    echo ""
    info "$title"
    echo ""
    for i in "${!items[@]}"; do
      printf "    %d) %s\n" $((i + 1)) "${items[$i]}"
    done
    echo ""
    info "回车或无效输入 = 第 1 项（推荐默认）"
    echo ""
  } | _ui_out
  local choice raw
  _ui_read -rp "  选择 [1-${#items[@]}] (回车=第1项): " raw
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    choice=$((raw - 1))
  else
    choice=-1
  fi
  [[ $choice -ge 0 && $choice -lt ${#items[@]} ]] || choice=0
  echo "$choice"
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
