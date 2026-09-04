# shellcheck shell=bash

PM2_MARKER="/etc/pm2-init.done"
FNM_BIN_DIR="${FNM_BIN_DIR:-/usr/local/fnm}"
FNM_DATA_DIR_REL='${HOME}/.local/share/fnm'

is_pm2_ok() {
  [[ -x "${FNM_BIN_DIR}/fnm" ]] || [[ -x /usr/local/bin/fnm ]] || return 1
  id "${DEVOPS_USER:-devops}" &>/dev/null || return 1
  devops_bash_c 'command -v node &>/dev/null && command -v pm2 &>/dev/null'
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

_pm2_shell_block() {
  local shell="${1:-bash}"
  cat <<EOF
# >>> pm2 init.sh >>>
export FNM_DIR="${FNM_DATA_DIR_REL}"
export FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-https://npmmirror.com/mirrors/node}"
export PATH="${FNM_BIN_DIR}:\${PATH}"
command -v fnm >/dev/null 2>&1 && eval "\$(fnm env --shell ${shell})"
# <<< pm2 init.sh <<<
EOF
}

_pm2_install_fnm_binary() {
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

_pm2_write_devops_shell() {
  local home rc profile zshrc
  home="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6 || true)"
  [[ -n "$home" && -d "$home" ]] || die "devops 家目录不存在: ${DEVOPS_USER}"
  rc="${home}/.bashrc"
  profile="${home}/.bash_profile"
  zshrc="${home}/.zshrc"
  touch "$rc" "$profile" "$zshrc"
  chown "${DEVOPS_USER}:${DEVOPS_USER}" "$rc" "$profile" "$zshrc"
  sed -i '/# >>> pm2 init.sh >>>/,/# <<< pm2 init.sh <<</d' "$rc" "$zshrc" 2>/dev/null || true
  {
    printf '\n'
    _pm2_shell_block bash
  } >> "$rc"
  {
    printf '\n'
    _pm2_shell_block zsh
  } >> "$zshrc"
  if ! grep -q 'source ~/.bashrc' "$profile" 2>/dev/null \
    && ! grep -q '\. ~/.bashrc' "$profile" 2>/dev/null; then
    cat >> "$profile" <<'EOF'

# login shell 加载 .bashrc（fnm / pm2）
[[ -f ~/.bashrc ]] && . ~/.bashrc
EOF
    chown "${DEVOPS_USER}:${DEVOPS_USER}" "$profile"
  fi
  if [[ -f /etc/zshenv ]]; then
    sed -i '/# >>> pm2 init.sh >>>/,/# <<< pm2 init.sh <<</d' /etc/zshenv 2>/dev/null || true
    {
      printf '\n'
      _pm2_shell_block zsh
    } >> /etc/zshenv
  fi
  ok "已写入 ${DEVOPS_USER} shell 配置（fnm env）"
}

_pm2_prepare_devops_fnm_data() {
  local home
  home="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6 || true)"
  [[ -n "$home" && -d "$home" ]] || die "devops 家目录不存在: ${DEVOPS_USER}"
  mkdir -p "${home}/.local/share/fnm"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${home}/.local/share/fnm"
}

_pm2_run_devops() {
  devops_bash_c "$1" || die "devops 命令失败: $1"
}

_pm2_setup_startup() {
  local home line out
  home="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6 || true)"
  out="$(devops_bash_c "pm2 startup systemd -u ${DEVOPS_USER} --hp ${home}" 2>&1 || true)"
  line="$(printf '%s\n' "$out" | awk '/sudo env PATH=.*pm2 startup/ {sub(/^sudo /,""); print; exit}')"
  if [[ -n "$line" ]]; then
    eval "$line" && ok "PM2 systemd 开机自启已配置" || warn "PM2 startup 命令执行失败"
  else
    warn "未能解析 pm2 startup 输出；请手动: su - ${DEVOPS_USER} -c 'pm2 startup systemd -u ${DEVOPS_USER} --hp ${home}'"
  fi
}

install_pm2() {
  hr; info "安装 PM2 环境（fnm + Node.js + pm2）"; echo ""

  NODE_VERSION="${NODE_VERSION:-22}"
  FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-https://npmmirror.com/mirrors/node}"

  if ! id "${DEVOPS_USER}" &>/dev/null; then
    warn "用户 ${DEVOPS_USER} 不存在，先创建 devops 用户"
    setup_devops_user
  fi

  run_pkg install -y curl unzip 2>/dev/null || true

  if [[ ! -x "${FNM_BIN_DIR}/fnm" ]]; then
    _pm2_install_fnm_binary
  else
    ok "fnm 已存在: ${FNM_BIN_DIR}/fnm"
  fi

  _pm2_write_devops_shell
  _pm2_prepare_devops_fnm_data

  info "安装 Node.js ${NODE_VERSION}（用户 ${DEVOPS_USER}）..."
  _pm2_run_devops "fnm install ${NODE_VERSION} && fnm default ${NODE_VERSION}"
  ok "Node.js: $(devops_bash_c 'node -v' 2>/dev/null || echo '?')"

  info "配置 npm 镜像并安装 pm2 ..."
  _pm2_run_devops "npm config set registry https://registry.npmmirror.com 2>/dev/null || true"
  _pm2_run_devops "npm install -g pm2@latest"
  ok "pm2: $(devops_bash_c 'pm2 -v' 2>/dev/null || echo '?')"

  _pm2_setup_startup
  _pm2_run_devops "pm2 save" 2>/dev/null || true

  : > "$PM2_MARKER"
  ok "PM2 环境就绪（deploy-site.sh --type=pm2 可用）"
}

uninstall_pm2() {
  hr; info "卸载 PM2 环境"; echo ""

  if id "${DEVOPS_USER}" &>/dev/null; then
    devops_bash_c "pm2 kill" 2>/dev/null || true
    devops_bash_c "pm2 unstartup systemd" 2>/dev/null || true
    local home rc
    home="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6 || true)"
    rc="${home}/.bashrc"
    [[ -f "$rc" ]] && sed -i '/# >>> pm2 init.sh >>>/,/# <<< pm2 init.sh <<</d' "$rc" 2>/dev/null || true
    [[ -f "${home}/.zshrc" ]] && sed -i '/# >>> pm2 init.sh >>>/,/# <<< pm2 init.sh <<</d' "${home}/.zshrc" 2>/dev/null || true
    [[ -f /etc/zshenv ]] && sed -i '/# >>> pm2 init.sh >>>/,/# <<< pm2 init.sh <<</d' /etc/zshenv 2>/dev/null || true
    rm -rf "${home}/.local/share/fnm" "${home}/.fnm" 2>/dev/null || true
  fi

  systemctl disable pm2-"${DEVOPS_USER}" 2>/dev/null || true
  rm -f "/etc/systemd/system/pm2-${DEVOPS_USER}.service" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  rm -rf "${FNM_BIN_DIR}" /usr/local/bin/fnm "$PM2_MARKER" 2>/dev/null || true
  ok "PM2 / fnm 已卸载"
}
