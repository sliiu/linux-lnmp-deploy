# shellcheck shell=bash
# printf -v 写入命名变量，避免 stdout 被 tee 记入日志（兼容 bash 3.2）
prompt_secret_confirm_into() {
  local msg="$1" _var="$2" p1 p2
  [[ "$_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "内部错误: 无效变量名"
  while true; do
    read -rsp "  ${msg}: " p1 </dev/tty; echo >/dev/tty
    if [[ -z "$p1" ]]; then echo "  ! 不能为空" >/dev/tty; continue; fi
    read -rsp "  再次确认: " p2 </dev/tty; echo >/dev/tty
    if [[ "$p1" = "$p2" ]]; then printf -v "$_var" '%s' "$p1"; return 0; fi
    echo "  ! 两次输入不一致" >/dev/tty
  done
}

# 禁止 $(menu_multi)；调用后读 MENU_MULTI_RESULT（空格分隔的下标）
menu_multi() {
  local title="$1"; shift
  local -a items=("$@")
  local input
  if interactive_tty_ok; then
    _ui_tty ""
    _ui_tty "  ${title} (逗号分隔, 如 1,3,5 | all=全选 | 回车=默认全选)"
    _ui_tty ""
    local i
    for i in "${!items[@]}"; do
      _ui_tty "    $((i + 1))) ${items[$i]}"
    done
    _ui_tty ""
    printf '  选择: ' >/dev/tty
    read -r input </dev/tty 2>/dev/null || input=""
    printf '\n' >/dev/tty
  else
    echo ""
    info "$title (逗号分隔, 如 1,3,5 | all=全选 | 回车=默认全选)"
    echo ""
    local i
    for i in "${!items[@]}"; do
      info "    $((i + 1))) ${items[$i]}"
    done
    echo ""
    read -rp "  选择: " input || input=""
  fi
  input=$(echo "$input" | tr -d ' ')
  if [[ -z "$input" || "$input" = "all" ]]; then
    MENU_MULTI_RESULT=$(seq 0 $((${#items[@]} - 1)) | tr '\n' ' ')
  else
    local -a result=()
    IFS=',' read -ra parts <<< "$input"
    for p in "${parts[@]}"; do
      local idx=$((p - 1))
      if [[ $idx -ge 0 && $idx -lt ${#items[@]} ]]; then result+=("$idx"); fi
    done
    MENU_MULTI_RESULT="${result[*]}"
  fi
}

fetch_url() {
  local url="$1" out="${2:--}"
  wget -q --no-check-certificate -O "$out" "$url" 2>/dev/null \
    || (command -v curl &>/dev/null && curl -fsSL -o "$out" "$url") \
    || return 1
}

_git_clone_retry() {
  local url="$1" dir="$2"
  local attempts="${3:-5}" wait="${4:-5}" i
  for ((i = 1; i <= attempts; i++)); do
    /bin/rm -rf "$dir"
    if env GIT_HTTP_LOW_SPEED_LIMIT=500 GIT_HTTP_LOW_SPEED_TIME=600 \
      git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 \
      clone --depth=1 --single-branch "$url" "$dir"; then
      return 0
    fi
    if ((i < attempts)); then
      warn "git clone 失败（${url##*/}），${wait}s 后重试 (${i}/${attempts})..."
      sleep "$wait"
    fi
  done
  return 1
}

run_pkg() {
  if command -v dnf &>/dev/null; then
    dnf "$@"
  elif command -v yum &>/dev/null; then
    yum "$@"
  elif command -v apt-get &>/dev/null; then
    apt-get "$@"
  else
    die "未找到包管理器"
  fi
}

ensure_supervisor_service() {
  command -v systemctl &>/dev/null || return 0
  if systemctl cat supervisord.service &>/dev/null; then
    systemctl enable --now supervisord &>/dev/null && ok "supervisord 已启用并启动" || warn "supervisord 启动失败，请手动: systemctl enable --now supervisord"
    return 0
  fi
  if systemctl cat supervisor.service &>/dev/null; then
    systemctl enable --now supervisor &>/dev/null && ok "supervisor 已启用并启动" || warn "supervisor 启动失败，请手动: systemctl enable --now supervisor"
    return 0
  fi
  return 0
}

check_passwd_strength() {
  local p="$1" n=0
  [[ ${#p} -ge 10 ]] || return 1
  [[ "$p" =~ [a-z] ]] && ((n++)) || true
  [[ "$p" =~ [A-Z] ]] && ((n++)) || true
  [[ "$p" =~ [0-9] ]] && ((n++)) || true
  [[ "$p" =~ [^a-zA-Z0-9] ]] && ((n++)) || true
  [[ $n -ge 3 ]]
}

