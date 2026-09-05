# shellcheck shell=bash

NODE_MARKER="/etc/node-init.done"
FNM_BIN_DIR="${FNM_BIN_DIR:-/usr/local/fnm}"
FNM_DATA_DIR_REL='${HOME}/.local/share/fnm'

is_fnm_ok() {
  [[ -x "${FNM_BIN_DIR}/fnm" ]] || [[ -x /usr/local/bin/fnm ]]
}

is_node_ok() {
  is_fnm_ok || return 1
  id "${DEVOPS_USER:-devops}" &>/dev/null || return 1
  devops_bash_c 'command -v node &>/dev/null'
}

collect_node_version() {
  local idx
  menu_select "Node.js 主版本（当前: ${NODE_VERSION:-22}）" \
    "22 (推荐)" "20" "24" "18" "自定义"
  idx=$MENU_SELECT_RESULT
  case "$idx" in
    0) NODE_VERSION="22" ;;
    1) NODE_VERSION="20" ;;
    2) NODE_VERSION="24" ;;
    3) NODE_VERSION="18" ;;
    4)
      while true; do
        prompt "Node.js 主版本 (fnm)" "${NODE_VERSION:-22}"
        NODE_VERSION=$PROMPT_RESULT
        [[ "$NODE_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]] && break
        warn "无效 Node 版本: ${NODE_VERSION}"
        interactive_tty_ok || die "无效 Node 版本: ${NODE_VERSION}"
      done
      ;;
  esac
}

_node_shell_block() {
  local shell="${1:-bash}"
  cat <<EOF
# >>> node init.sh >>>
export FNM_DIR="${FNM_DATA_DIR_REL}"
export FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-https://npmmirror.com/mirrors/node}"
export PATH="${FNM_BIN_DIR}:\${HOME}/.local/share/fnm/aliases/default/bin:\${PATH}"
mkdir -p "\${HOME}/.local/share/fnm" "\${HOME}/.local/state/fnm_multishells" 2>/dev/null || true
command -v fnm >/dev/null 2>&1 && eval "\$(fnm env --shell ${shell})"
# <<< node init.sh <<<
EOF
}

_node_strip_shell_block() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    sed -i '/# >>> node init.sh >>>/,/# <<< node init.sh <<</d' "$f" 2>/dev/null || true
    sed -i '/# >>> pm2 init.sh >>>/,/# <<< pm2 init.sh <<</d' "$f" 2>/dev/null || true
  done
}

_node_install_fnm_binary() {
  local arch fnm_ver="${FNM_VERSION:-v1.39.0}" asset url tmpzip
  arch=$(uname -m)
  case "$arch" in
    x86_64)        asset="fnm-linux.zip" ;;
    aarch64|arm64) asset="fnm-arm64.zip" ;;
    armv7l|armv6l) asset="fnm-arm32.zip" ;;
    *) die "不支持的架构: ${arch}" ;;
  esac
  url="${GH_PROXY:+${GH_PROXY}/}https://github.com/Schniz/fnm/releases/download/${fnm_ver}/${asset}"
  mkdir -p "${FNM_BIN_DIR}"
  tmpzip="$(mktemp)"
  info "下载 fnm ${fnm_ver} ..."
  fetch_url "$url" "$tmpzip" || die "下载 fnm 失败（可配置 --gh-proxy 或 GitHub 代理）"
  run_pkg install -y unzip 2>/dev/null || true
  unzip -oq "$tmpzip" -d "${FNM_BIN_DIR}"
  chmod +x "${FNM_BIN_DIR}/fnm"
  ln -sf "${FNM_BIN_DIR}/fnm" /usr/local/bin/fnm 2>/dev/null || true
  rm -f "$tmpzip"
  ok "fnm 已安装: ${FNM_BIN_DIR}/fnm"
}

_node_write_devops_shell() {
  local home rc profile zshrc
  home="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6 || true)"
  [[ -n "$home" && -d "$home" ]] || die "devops 家目录不存在: ${DEVOPS_USER}"
  rc="${home}/.bashrc"
  profile="${home}/.bash_profile"
  zshrc="${home}/.zshrc"
  touch "$rc" "$profile" "$zshrc"
  chown "${DEVOPS_USER}:${DEVOPS_USER}" "$rc" "$profile" "$zshrc"
  _node_strip_shell_block "$rc" "$zshrc"
  {
    printf '\n'
    _node_shell_block bash
  } >> "$rc"
  {
    printf '\n'
    _node_shell_block zsh
  } >> "$zshrc"
  if ! grep -q 'source ~/.bashrc' "$profile" 2>/dev/null \
    && ! grep -q '\. ~/.bashrc' "$profile" 2>/dev/null; then
    cat >> "$profile" <<'EOF'

[[ -f ~/.bashrc ]] && . ~/.bashrc
EOF
    chown "${DEVOPS_USER}:${DEVOPS_USER}" "$profile"
  fi
  if [[ -f /etc/zshenv ]]; then
    _node_strip_shell_block /etc/zshenv
    {
      printf '\n'
      _node_shell_block zsh
    } >> /etc/zshenv
  fi
  ok "已写入 ${DEVOPS_USER} shell 配置（fnm env）"
}

_node_prepare_devops_fnm_data() {
  local home
  home="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6 || true)"
  [[ -n "$home" && -d "$home" ]] || die "devops 家目录不存在: ${DEVOPS_USER}"
  mkdir -p "${home}/.local/share/fnm" "${home}/.local/state/fnm_multishells"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${home}/.local"
}

_node_run_devops() {
  devops_bash_c "$1" || die "devops 命令失败: $1"
}

install_node() {
  hr; info "安装 Node.js（fnm）"; echo ""

  NODE_VERSION="${NODE_VERSION:-22}"
  FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-https://npmmirror.com/mirrors/node}"

  if ! id "${DEVOPS_USER}" &>/dev/null; then
    warn "用户 ${DEVOPS_USER} 不存在，先创建 devops 用户"
    setup_devops_user
  fi

  run_pkg install -y curl unzip 2>/dev/null || true

  if ! is_fnm_ok; then
    _node_install_fnm_binary
  else
    ok "fnm 已存在: $(command -v fnm 2>/dev/null || echo "${FNM_BIN_DIR}/fnm")"
  fi

  _node_write_devops_shell
  _node_prepare_devops_fnm_data

  info "安装 Node.js ${NODE_VERSION}（用户 ${DEVOPS_USER}）..."
  _node_run_devops "fnm install ${NODE_VERSION} && fnm default ${NODE_VERSION}"
  _node_run_devops "npm config set registry https://registry.npmmirror.com 2>/dev/null || true"
  ok "Node.js: $(devops_bash_c 'node -v' 2>/dev/null || echo '?')"

  : > "$NODE_MARKER"
  ok "Node.js 就绪"
}

uninstall_node() {
  hr; info "卸载 Node.js / fnm"; echo ""

  if is_pm2_ok || [[ -f "${PM2_MARKER:-/etc/pm2-init.done}" ]]; then
    info "PM2 依赖 Node.js，先卸载 PM2"
    uninstall_pm2
  fi

  if id "${DEVOPS_USER}" &>/dev/null; then
    local home
    home="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6 || true)"
    _node_strip_shell_block "${home}/.bashrc" "${home}/.zshrc" /etc/zshenv
    rm -rf "${home}/.local/share/fnm" "${home}/.local/state/fnm_multishells" "${home}/.fnm" 2>/dev/null || true
  fi

  rm -rf "${FNM_BIN_DIR}" /usr/local/bin/fnm "$NODE_MARKER" 2>/dev/null || true
  ok "Node.js / fnm 已卸载"
}
