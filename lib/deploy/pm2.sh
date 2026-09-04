# shellcheck shell=bash

# ─── 站点类型 / PM2 元数据（存于 conf.d，与 .php-version 同目录）───

site_type_file() { printf '%s/%s.site-type' "$NGINX_CONF" "$1"; }
site_pm2_port_file() { printf '%s/%s.pm2-port' "$NGINX_CONF" "$1"; }
site_pm2_cmd_file() { printf '%s/%s.pm2-cmd' "$NGINX_CONF" "$1"; }
site_proxy_pass_file() { printf '%s/%s.proxy-pass' "$NGINX_CONF" "$1"; }

write_site_proxy_pass() {
  local domain="$1" url="$2"
  mkdir -p "${NGINX_CONF}"
  printf '%s\n' "$url" > "$(site_proxy_pass_file "$domain")"
  chmod 644 "$(site_proxy_pass_file "$domain")" 2>/dev/null || true
}

proxy_pass_for_site() {
  local domain="$1" f t
  f="$(site_proxy_pass_file "$domain")"
  if [[ -f "$f" ]]; then
    t="$(head -n1 "$f" 2>/dev/null)"
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  fi
  printf '%s' "${SITE_PROXY_PASS:-}"
}

apply_site_proxy_pass_cli() {
  local domain="$1" v
  [[ "${SITE_PROXY_PASS_CLI:-0}" -ne 1 ]] && return 0
  v="$(_normalize_proxy_pass "${SITE_PROXY_PASS:-}")" || die "无效 --proxy-pass: ${SITE_PROXY_PASS:-<空>}"
  write_site_proxy_pass "$domain" "$v"
  SITE_PROXY_PASS="$v"
  info "站点 ${domain} 反代上游：${v}"
}

write_site_type_file() {
  local domain="$1" stype="$2"
  mkdir -p "${NGINX_CONF}"
  printf '%s\n' "$stype" > "$(site_type_file "$domain")"
  chmod 644 "$(site_type_file "$domain")" 2>/dev/null || true
}

_site_type_for_domain() {
  local domain="$1" f t
  f="$(site_type_file "$domain")"
  if [[ -f "$f" ]]; then
    t="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
    case "$t" in
      laravel|frontend|pm2|proxy) printf '%s' "$t"; return 0 ;;
    esac
  fi
  [[ -f "${WWW_ROOT}/${domain}/artisan" ]] && { printf 'laravel'; return 0; }
  printf 'frontend'
}

pm2_app_name() {
  local domain="$1"
  printf 'lnmp-%s' "${domain//./-}"
}

# Nginx 容器访问宿主机 PM2 进程用的网关 IP
_docker_host_gateway() {
  local gw="" c
  c="$(_web_container)"
  if container_ok "$c"; then
    gw="$(docker exec "$c" sh -c "ip route 2>/dev/null | awk '/default/ {print \$3; exit}'" 2>/dev/null || true)"
  fi
  [[ -n "$gw" ]] && { printf '%s' "$gw"; return 0; }
  gw="$(ip -4 route show match 0/0 2>/dev/null | awk '{print $3; exit}')"
  [[ -n "$gw" ]] && { printf '%s' "$gw"; return 0; }
  printf '172.17.0.1'
}

_pm2_port_in_use_on_host() {
  local port="$1"
  ss -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}' \
    || netstat -ltn 2>/dev/null | grep -q ":${port} " \
    || return 1
}

_pm2_port_claimed_by_site() {
  local port="$1" exclude="${2:-}" f d p
  for f in "${NGINX_CONF}"/*.pm2-port; do
    [[ -f "$f" ]] || continue
    d="$(basename "$f" .pm2-port)"
    [[ "$d" = "$exclude" ]] && continue
    p="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
    [[ "$p" = "$port" ]] && return 0
  done
  return 1
}

allocate_pm2_port() {
  local domain="$1" start port cur
  start="${2:-3000}"
  port="$start"
  cur="$(pm2_port_for_site "$domain" 2>/dev/null || true)"
  if [[ -n "$cur" && "$cur" =~ ^[0-9]+$ ]]; then
    printf '%s' "$cur"
    return 0
  fi
  while [[ "$port" -le 65535 ]]; do
    _pm2_port_claimed_by_site "$port" "$domain" && { port=$((port + 1)); continue; }
    _pm2_port_in_use_on_host "$port" && { port=$((port + 1)); continue; }
    printf '%s' "$port"
    return 0
  done
  die "无法分配 PM2 端口（${start}+ 均被占用）"
}

pm2_port_for_site() {
  local domain="$1" f p
  f="$(site_pm2_port_file "$domain")"
  [[ -f "$f" ]] || return 1
  p="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$p"
}

pm2_start_cmd_for_site() {
  local domain="$1" site_dir="${WWW_ROOT}/${domain}" f cmd
  f="$(site_pm2_cmd_file "$domain")"
  if [[ -f "$f" ]]; then
    cmd="$(head -n1 "$f" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$cmd" ]] && { printf '%s' "$cmd"; return 0; }
  fi
  if [[ -f "${site_dir}/ecosystem.config.cjs" ]]; then
    printf 'pm2 start ecosystem.config.cjs --env production --name %s' "$(pm2_app_name "$domain")"
    return 0
  fi
  if [[ -f "${site_dir}/ecosystem.config.js" ]]; then
    printf 'pm2 start ecosystem.config.js --env production --name %s' "$(pm2_app_name "$domain")"
    return 0
  fi
  if [[ -f "${site_dir}/package.json" ]] && grep -q '"start"' "${site_dir}/package.json" 2>/dev/null; then
    printf 'pm2 start npm --name %s -- start' "$(pm2_app_name "$domain")"
    return 0
  fi
  return 1
}

apply_site_pm2_port_cli() {
  local domain="$1"
  [[ "${SITE_PM2_PORT_CLI:-0}" -ne 1 ]] && return 0
  mkdir -p "${NGINX_CONF}"
  local v="${SITE_PM2_PORT// /}"
  if [[ -z "$v" || "$v" = "-" ]]; then
    rm -f "$(site_pm2_port_file "$domain")" 2>/dev/null || true
    info "站点 ${domain} PM2 端口：清除 → 自动分配"
    return 0
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || die "无效 --pm2-port: $v"
  printf '%s\n' "$v" > "$(site_pm2_port_file "$domain")"
  chmod 644 "$(site_pm2_port_file "$domain")" 2>/dev/null || true
  info "站点 ${domain} PM2 端口：${v}"
}

apply_site_pm2_cmd_cli() {
  local domain="$1"
  [[ "${SITE_PM2_CMD_CLI:-0}" -ne 1 ]] && return 0
  mkdir -p "${NGINX_CONF}"
  if [[ -z "${SITE_PM2_CMD}" ]]; then
    rm -f "$(site_pm2_cmd_file "$domain")" 2>/dev/null || true
    info "站点 ${domain} PM2 启动命令：清除 → 自动检测"
    return 0
  fi
  printf '%s\n' "$SITE_PM2_CMD" > "$(site_pm2_cmd_file "$domain")"
  chmod 644 "$(site_pm2_cmd_file "$domain")" 2>/dev/null || true
  info "站点 ${domain} PM2 启动命令：${SITE_PM2_CMD}"
}

_pm2_run_as_devops() {
  local site_dir="$1" cmd="$2"
  devops_bash_c "cd '${site_dir}' && ${cmd}" \
    || die "PM2/Node 命令失败: ${cmd}"
}

ensure_pm2_runtime() {
  local node_v pm2_v
  node_v="$(devops_bash_c 'command -v node' 2>/dev/null || true)"
  [[ -n "$node_v" ]] || die "未找到 node（用户 ${DEVOPS_USER}）；请先执行 init.sh install pm2"
  pm2_v="$(devops_bash_c 'command -v pm2' 2>/dev/null || true)"
  [[ -n "$pm2_v" ]] || die "未找到 pm2（用户 ${DEVOPS_USER}）；请先执行 init.sh install pm2"
  ok "Node: $(devops_bash_c 'node -v' 2>/dev/null || echo '?')  PM2: $(devops_bash_c 'pm2 -v' 2>/dev/null || echo '?')"
}

_pm2_detect_pkg_manager() {
  local site_dir="$1"
  [[ -f "${site_dir}/pnpm-lock.yaml" ]] && { printf 'pnpm'; return 0; }
  [[ -f "${site_dir}/yarn.lock" ]] && { printf 'yarn'; return 0; }
  [[ -f "${site_dir}/package-lock.json" ]] && { printf 'npm'; return 0; }
  [[ -f "${site_dir}/package.json" ]] && { printf 'npm'; return 0; }
  return 1
}

_pm2_install_deps() {
  local domain="$1" site_dir="${WWW_ROOT}/${domain}" pm
  [[ -f "${site_dir}/package.json" ]] || die "未找到 ${site_dir}/package.json"
  pm="$(_pm2_detect_pkg_manager "$site_dir")" || die "无法检测包管理器"
  info "${pm} install..."
  case "$pm" in
    pnpm) _pm2_run_as_devops "$site_dir" "pnpm install --frozen-lockfile 2>/dev/null || pnpm install" ;;
    yarn) _pm2_run_as_devops "$site_dir" "yarn install --frozen-lockfile 2>/dev/null || yarn install" ;;
    npm)  _pm2_run_as_devops "$site_dir" "npm ci 2>/dev/null || npm install" ;;
  esac
  ok "依赖安装完成"
}

_pm2_run_build() {
  local domain="$1" site_dir="${WWW_ROOT}/${domain}" pm
  [[ "${PM2_BUILD:-y}" != "y" ]] && { info "跳过构建（PM2_BUILD=n）"; return 0; }
  [[ -f "${site_dir}/package.json" ]] || return 0
  grep -q '"build"' "${site_dir}/package.json" 2>/dev/null || { info "package.json 无 build 脚本，跳过"; return 0; }
  pm="$(_pm2_detect_pkg_manager "$site_dir")"
  info "${pm} run build..."
  case "$pm" in
    pnpm) _pm2_run_as_devops "$site_dir" "pnpm run build" ;;
    yarn) _pm2_run_as_devops "$site_dir" "yarn run build" ;;
    npm)  _pm2_run_as_devops "$site_dir" "npm run build" ;;
  esac
  ok "构建完成"
}

setup_pm2() {
  local domain="$1" site_dir="${WWW_ROOT}/${domain}" port app cmd env_prefix
  ensure_pm2_runtime
  apply_site_pm2_port_cli "$domain"
  apply_site_pm2_cmd_cli "$domain"

  port="$(allocate_pm2_port "$domain" "${SITE_PM2_PORT:-3000}")"
  printf '%s\n' "$port" > "$(site_pm2_port_file "$domain")"
  chmod 644 "$(site_pm2_port_file "$domain")" 2>/dev/null || true

  cmd="$(pm2_start_cmd_for_site "$domain")" || die "无法推断 PM2 启动命令；请提供 ecosystem.config.js 或 package.json scripts.start，或使用 --pm2-cmd"
  app="$(pm2_app_name "$domain")"
  env_prefix="PORT=${port} HOST=0.0.0.0 NODE_ENV=production"

  _pm2_install_deps "$domain"
  _pm2_run_build "$domain"

  info "PM2 启动（端口 ${port}）..."
  if devops_bash_c "pm2 describe '${app}' &>/dev/null"; then
    devops_bash_c "cd '${site_dir}' && ${env_prefix} pm2 reload '${app}' --update-env" \
      || devops_bash_c "cd '${site_dir}' && ${env_prefix} ${cmd}"
    ok "PM2 已 reload: ${app}"
  else
    devops_bash_c "cd '${site_dir}' && ${env_prefix} ${cmd}" \
      || die "PM2 启动失败"
    devops_bash_c "pm2 save" 2>/dev/null || true
    ok "PM2 已启动: ${app}（监听 0.0.0.0:${port}）"
  fi
}

reload_pm2_site() {
  local domain="$1" site_dir="${WWW_ROOT}/${domain}" port app env_prefix
  [[ "$(_site_type_for_domain "$domain")" = "pm2" ]] || return 0
  ensure_pm2_runtime
  port="$(pm2_port_for_site "$domain")"
  [[ -n "$port" ]] || die "缺少 ${NGINX_CONF}/${domain}.pm2-port"
  app="$(pm2_app_name "$domain")"
  env_prefix="PORT=${port} HOST=0.0.0.0 NODE_ENV=production"

  _pm2_install_deps "$domain"
  _pm2_run_build "$domain"

  if devops_bash_c "pm2 describe '${app}' &>/dev/null"; then
    info "PM2 reload ${app}..."
    devops_bash_c "cd '${site_dir}' && ${env_prefix} pm2 reload '${app}' --update-env" \
      || devops_bash_c "cd '${site_dir}' && ${env_prefix} $(pm2_start_cmd_for_site "$domain")"
    devops_bash_c "pm2 save" 2>/dev/null || true
    ok "PM2 已 reload"
  else
    warn "PM2 进程 ${app} 不存在，重新 setup..."
    setup_pm2 "$domain"
  fi
}

stop_pm2_site() {
  local domain="$1" app
  [[ "$(_site_type_for_domain "$domain")" = "pm2" ]] || return 0
  app="$(pm2_app_name "$domain")"
  if devops_bash_c "pm2 describe '${app}' &>/dev/null"; then
    devops_bash_c "pm2 delete '${app}'" 2>/dev/null || true
    devops_bash_c "pm2 save" 2>/dev/null || true
    ok "PM2 进程已删除: ${app}"
  fi
}
