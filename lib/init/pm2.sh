# shellcheck shell=bash

PM2_MARKER="/etc/pm2-init.done"

is_pm2_ok() {
  is_node_ok || return 1
  devops_bash_c 'command -v pm2 &>/dev/null'
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
  hr; info "安装 PM2"; echo ""

  if ! is_node_ok; then
    info "PM2 依赖 Node.js，先安装 Node.js"
    install_node
  fi

  info "安装 pm2 ..."
  _node_run_devops "npm install -g pm2@latest"
  ok "pm2: $(devops_bash_c 'pm2 -v' 2>/dev/null || echo '?')"

  _pm2_setup_startup
  _node_run_devops "pm2 save" 2>/dev/null || true

  : > "$PM2_MARKER"
  ok "PM2 就绪（deploy-site.sh --type=pm2 可用）"
}

uninstall_pm2() {
  hr; info "卸载 PM2"; echo ""

  if id "${DEVOPS_USER}" &>/dev/null; then
    devops_bash_c "pm2 kill" 2>/dev/null || true
    devops_bash_c "pm2 unstartup systemd" 2>/dev/null || true
    devops_bash_c "npm uninstall -g pm2" 2>/dev/null || true
  fi

  systemctl disable pm2-"${DEVOPS_USER}" 2>/dev/null || true
  rm -f "/etc/systemd/system/pm2-${DEVOPS_USER}.service" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  rm -f "$PM2_MARKER" 2>/dev/null || true
  ok "PM2 已卸载（Node.js / fnm 保留）"
}
