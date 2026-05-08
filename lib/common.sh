# shellcheck shell=bash
# init.sh / deploy-site.sh 共用工具函数
# 此文件由两个入口脚本通过 source 引入，脚本独立运行时请使用 bootstrap.sh

die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
hr()   { echo "══════════════════════════════════════════════"; }

confirm() {
  local msg="${1:-确认？}" default="${2:-y}" ans=""
  local prompt_str="[Y/n]"; [[ "$default" != "y" ]] && prompt_str="[y/N]"
  read -rp "  ${msg} ${prompt_str}: " ans </dev/tty 2>/dev/tty || true
  ans=${ans:-$default}
  [[ "$ans" =~ ^[yY]$ ]]
}

prompt() {
  local msg="$1" default="${2:-}" var=""
  if [[ -n "$default" ]]; then
    read -rp "  ${msg} [${default}]: " var </dev/tty 2>/dev/tty || true
  else
    read -rp "  ${msg}: " var </dev/tty 2>/dev/tty || true
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
  } >/dev/tty
  local choice raw
  read -rp "  选择 [1-${#items[@]}] (回车=第1项): " raw </dev/tty >/dev/tty || raw=""
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
