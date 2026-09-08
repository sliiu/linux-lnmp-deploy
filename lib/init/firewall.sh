# shellcheck shell=bash
_firewall_active_zones() {
  firewall-cmd --get-active-zones 2>/dev/null | awk 'NF==1 && $1 !~ /^[[:space:]]/' || true
  echo public
}

_firewall_bind_public_nic() {
  command -v firewall-cmd >/dev/null 2>&1 || return 0
  systemctl is-active firewalld >/dev/null 2>&1 || return 0
  local iface
  iface=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$iface" && "$iface" != docker0 && "$iface" != lo ]] || return 0
  firewall-cmd --permanent --zone=public --change-interface="$iface" 2>/dev/null || true
  firewall-cmd --zone=public --change-interface="$iface" 2>/dev/null || true
}

_firewall_allow_port() {
  local port="$1" z
  [[ -n "$port" ]] || return 0
  command -v firewall-cmd >/dev/null 2>&1 || return 0
  for z in $(_firewall_active_zones) docker; do
    [[ -n "$z" ]] || continue
    firewall-cmd --permanent --zone="$z" --add-port="${port}/tcp" 2>/dev/null || true
    firewall-cmd --zone="$z" --add-port="${port}/tcp" 2>/dev/null || true
  done
}

_firewall_apply_host_ports() {
  command -v firewall-cmd >/dev/null 2>&1 || return 0
  systemctl is-active firewalld >/dev/null 2>&1 || return 0
  _firewall_bind_public_nic
  _firewall_allow_port 80
  _firewall_allow_port 443
  _firewall_allow_port "${SSH_PORT:-22}"
  firewall-cmd --reload 2>/dev/null || true
}

install_firewall() {
  hr; info "安装 Firewalld"; echo ""
  run_pkg install -y firewalld
  systemctl enable --now firewalld
  _firewall_apply_host_ports
  ok "Firewalld 已安装并放行 80/443/${SSH_PORT:-22}"
}

uninstall_firewall() {
  hr; info "卸载 Firewalld"; echo ""
  systemctl stop firewalld 2>/dev/null || true
  systemctl disable firewalld 2>/dev/null || true
  run_pkg remove -y firewalld 2>/dev/null || true
  ok "Firewalld 已卸载"
}

