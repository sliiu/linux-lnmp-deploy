# shellcheck shell=bash
install_docker() {
  hr; info "安装 Docker"; echo ""

  if is_docker_ok; then
    ok "Docker 已安装 ($(docker -v 2>/dev/null | head -1))"
  else
    if [[ -f /etc/os-release ]] && grep -q "Alibaba Cloud Linux" /etc/os-release 2>/dev/null; then
      _install_docker_alinux
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
      _install_docker_centos
    elif [[ -f /etc/debian_version ]]; then
      _install_docker_debian
    else
      die "不支持的发行版"
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    docker -v &>/dev/null || die "Docker 安装失败"
  fi

  _ensure_compose
  _configure_docker_daemon
  _docker_add_users

  ok "Docker 就绪"
}

_install_docker_alinux() {
  dnf update dnf -y 2>/dev/null || true
  dnf clean packages 2>/dev/null || true
  /bin/rm -f /etc/yum.repos.d/docker*.repo

  if fetch_url "http://mirrors.cloud.aliyuncs.com/docker-ce/linux/centos/docker-ce.repo" "/tmp/docker-ce.repo"; then
    cp /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
    sed -i 's|https://mirrors.aliyun.com|http://mirrors.cloud.aliyuncs.com|g' /etc/yum.repos.d/docker-ce.repo
  else
    fetch_url "https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo" "/etc/yum.repos.d/docker-ce.repo"
    sed -i 's|download.docker.com|mirrors.aliyun.com/docker-ce|g' /etc/yum.repos.d/docker-ce.repo
  fi
  /bin/rm -f /tmp/docker-ce.repo

  if grep -q "Alibaba Cloud Linux 3" /etc/os-release 2>/dev/null; then
    dnf -y install dnf-plugin-releasever-adapter --repo alinux3-plus 2>/dev/null || true
  elif grep -q "Alibaba Cloud Linux 4" /etc/os-release 2>/dev/null; then
    sed -i 's|\$releasever|9|g' /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
  fi

  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_install_docker_centos() {
  run_pkg clean all 2>/dev/null || true
  run_pkg install -y yum-utils 2>/dev/null || true

  if command -v dnf &>/dev/null; then
    dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
  else
    yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
  fi
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] \
    && sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+g' /etc/yum.repos.d/docker-ce.repo

  run_pkg install -y docker-ce docker-ce-cli containerd.io
}

_install_docker_debian() {
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_ensure_compose() {
  if docker compose version &>/dev/null || command -v docker-compose &>/dev/null; then
    return 0
  fi
  fetch_url "${GH_PROXY:+${GH_PROXY}/}https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-$(uname -m)" \
    "/usr/local/bin/docker-compose" \
    && chmod +x /usr/local/bin/docker-compose
}

_configure_docker_daemon() {
  mkdir -p /etc/docker
  local mirrors_json=""
  if [[ -n "$DOCKER_MIRRORS_STR" ]]; then
    IFS=',' read -ra _ms <<< "$DOCKER_MIRRORS_STR"
    local first=1
    for m in "${_ms[@]}"; do
      if [[ -z "$m" ]]; then continue; fi
      [[ $first -eq 1 ]] && first=0 || mirrors_json+=", "
      mirrors_json+="\"${m}\""
    done
  fi

  if [[ -n "$mirrors_json" ]]; then
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [${mirrors_json}],
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
  else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true
}

_docker_add_users() {
  if [[ -n "${WHEEL_USER:-}" ]] && id "$WHEEL_USER" &>/dev/null; then
    usermod -aG docker "$WHEEL_USER" 2>/dev/null || true
  fi
  if [[ -n "${DEVOPS_USER:-}" ]] && id "$DEVOPS_USER" &>/dev/null; then
    usermod -aG docker "$DEVOPS_USER" 2>/dev/null || true
  fi
}

uninstall_docker() {
  hr; info "卸载 Docker"; echo ""

  if [[ -f "$COMPOSE_FILE" ]]; then
    cd "$DATA_DIR" 2>/dev/null && compose_cmd down 2>/dev/null || true
  fi

  systemctl stop docker 2>/dev/null || true
  systemctl disable docker 2>/dev/null || true

  if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    run_pkg remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  elif command -v apt-get &>/dev/null; then
    apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  fi
  /bin/rm -f /usr/local/bin/docker-compose
  ok "Docker 已卸载"
}

