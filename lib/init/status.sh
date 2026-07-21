# shellcheck shell=bash
show_status() {
  echo ""
  hr
  info "环境状态"
  hr
  echo ""

  local _s
  _s=$(is_bbr_on && echo "已启用" || echo "未启用")
  printf "  %-20s %s\n" "BBR" "$_s"

  _s=$(is_firewall_on && echo "运行中" || echo "未安装")
  printf "  %-20s %s\n" "Firewalld" "$_s"

  _s=$(is_docker_ok && echo "已安装 ($(docker -v 2>/dev/null | awk '{print $3}' | tr -d ','))" || echo "未安装")
  printf "  %-20s %s\n" "Docker" "$_s"

  _s=$(is_zsh_ok && echo "已安装" || echo "未安装")
  printf "  %-20s %s\n" "Oh-My-Zsh" "$_s"

  _s=$(is_saferm_ok && echo "已安装" || echo "未安装")
  printf "  %-20s %s\n" "saferm" "$_s"

  if is_pm2_ok; then
    _s="已安装 (Node $(su - "${DEVOPS_USER}" -c 'node -v' 2>/dev/null || echo '?'), pm2 $(su - "${DEVOPS_USER}" -c 'pm2 -v' 2>/dev/null || echo '?'))"
  else
    _s="未安装"
  fi
  printf "  %-20s %s\n" "PM2 / Node.js" "$_s"

  _s=$(is_cybersec_ok && echo "已加固" || echo "未配置")
  printf "  %-20s %s\n" "等保" "$_s"

  printf "  %-20s %s\n" "SSH 端口" "${SSH_PORT:-22}"
  printf "  %-20s %s\n" "SSH Root" "${ROOT_LOGIN:-未配置}"
  printf "  %-20s %s\n" "Devops 用户" "${DEVOPS_USER:-未配置}"
  if [[ -n "${WHEEL_USER:-}" ]]; then printf "  %-20s %s\n" "Wheel 管理员" "$WHEEL_USER"; fi

  echo ""
  info "LNMP 容器"
  echo ""
  for c in nginx php mysql redis acme phpmyadmin; do
    if container_ok "$c"; then
      _s="运行中"
      if ! has_service "$c"; then
        _s+="（LNMP_SERVICES 未含 ${c}；请编辑 /etc/lnmp-env.conf 或通过 init「更新配置 → LNMP 组件」保存）"
      fi
    elif has_service "$c"; then
      _s="已停止"
    else
      _s="未部署"
    fi
    printf "  %-20s %s\n" "lnmp-${c}" "$_s"
  done
  local _ev _ec
  while IFS= read -r _ev; do
    [[ -z "$_ev" ]] && continue
    _ec="$(_php_container_name "$_ev")"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_ec}$"; then _s="运行中 (PHP ${_ev})"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${_ec}$"; then _s="已停止 (PHP ${_ev})"
    else _s="未部署 (PHP ${_ev})"; fi
    printf "  %-20s %s\n" "${_ec}" "$_s"
  done < <(_php_extra_list)

  echo ""
  has_service "nginx" && printf "  %-20s %s\n" "Nginx 镜像" "${NGINX_IMAGE:-}"
  has_service "mysql" && printf "  %-20s %s\n" "MySQL 镜像" "${MYSQL_IMAGE:-}"
  has_service "redis" && printf "  %-20s %s\n" "Redis 镜像" "${REDIS_IMAGE:-}"
  has_service "acme" && printf "  %-20s %s\n" "ACME 镜像" "${ACME_IMAGE:-}"
  if has_service "phpmyadmin"; then
    printf "  %-20s %s\n" "phpMyAdmin 镜像" "${PHPMYADMIN_IMAGE:-}"
    printf "  %-20s %s\n" "phpMyAdmin 监听" "${PHPMYADMIN_BIND:-127.0.0.1}:${PHPMYADMIN_PORT:-8080}"
  fi
  printf "  %-20s %s\n" "PHP 版本（默认）" "${PHP_VERSION:-未配置}"
  printf "  %-20s %s\n" "PHP 版本（额外）" "${EXTRA_PHP_VERSIONS:-无}"
  printf "  %-20s %s\n" "Alpine 源" "${ALPINE_MIRROR:-官方}"
  printf "  %-20s %s\n" "GitHub 代理" "${GH_PROXY:-无}"
  printf "  %-20s %s\n" "Docker 镜像源" "${DOCKER_MIRRORS_STR:-官方}"
  printf "  %-20s %s\n" "Node.js 版本" "${NODE_VERSION:-22}"
  printf "  %-20s %s\n" "Node 镜像源" "${FNM_NODE_DIST_MIRROR:-https://npmmirror.com/mirrors/node}"
  printf "  %-20s %s\n" "ACME SSL 默认" "${ACME_SSL_DNS_DEFAULT:-webroot}"
  echo ""
}

