# shellcheck shell=bash
install_firewall() {
  hr; info "安装 Firewalld"; echo ""
  run_pkg install -y firewalld
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-port=80/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
  if [[ "${SSH_PORT:-22}" != "22" ]]; then firewall-cmd --permanent --add-port="${SSH_PORT}"/tcp 2>/dev/null || true; fi
  firewall-cmd --reload 2>/dev/null || true
  ok "Firewalld 已安装并放行 80/443"
}

uninstall_firewall() {
  hr; info "卸载 Firewalld"; echo ""
  systemctl stop firewalld 2>/dev/null || true
  systemctl disable firewalld 2>/dev/null || true
  run_pkg remove -y firewalld 2>/dev/null || true
  ok "Firewalld 已卸载"
}

