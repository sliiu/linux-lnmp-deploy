# shellcheck shell=bash
is_bbr_on()       { sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; }
is_firewall_on()  { systemctl is-active firewalld &>/dev/null; }
is_docker_ok()    { command -v docker &>/dev/null && docker info &>/dev/null; }
is_zsh_ok()       { [[ -d /usr/local/share/ohmyzsh ]]; }
is_cybersec_ok()  { [[ -f "$CYBERSEC_MARKER" ]]; }
is_saferm_ok()     { [[ -x /usr/local/bin/saferm ]]; }
container_ok() {
  local n="$1"
  [[ "$n" = lnmp-* ]] || n="lnmp-${n}"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${n}$"
}
container_any() {
  local n="$1"
  [[ "$n" = lnmp-* ]] || n="lnmp-${n}"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${n}$"
}

compose_cmd() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  elif command -v docker-compose &>/dev/null; then
    docker-compose "$@"
  else
    die "Docker Compose 未安装"
  fi
}

has_service() {
  [[ ",$LNMP_SERVICES," = *",$1,"* ]]
}

