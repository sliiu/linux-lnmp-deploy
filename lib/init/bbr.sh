# shellcheck shell=bash
install_bbr() {
  hr; info "安装 BBR"; echo ""
  if is_bbr_on; then ok "BBR 已启用"; return 0; fi

  local kver
  kver=$(uname -r | cut -d- -f1)
  local major minor
  major=$(echo "$kver" | cut -d. -f1)
  minor=$(echo "$kver" | cut -d. -f2)

  if [[ "$major" -gt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -ge 9 ]]; }; then
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    ok "BBR 已启用"
  else
    die "内核版本 ${kver} < 4.9，不支持 BBR，请升级内核"
  fi
}

uninstall_bbr() {
  hr; info "禁用 BBR"; echo ""
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
  sysctl -p >/dev/null 2>&1
  ok "BBR 已禁用"
}

