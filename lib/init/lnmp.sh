# shellcheck shell=bash
_php_ver_no_dot() { printf '%s' "${1//./}"; }

# 输出去重、跳过空与主版本（PHP_VERSION）的额外版本列表（一行一个）
_php_extra_list() {
  local seen=" ${PHP_VERSION} "
  local v
  IFS=',' read -ra _vs <<< "${EXTRA_PHP_VERSIONS:-}"
  for v in "${_vs[@]}"; do
    v="${v//[[:space:]]/}"
    [[ -z "$v" ]] && continue
    case "$seen" in *" $v "*) continue ;; esac
    seen+="$v "
    printf '%s\n' "$v"
  done
}

# 默认 PHP（lnmp-php）的数据子目录是 "php"；额外版本是 "php-XX"
_php_data_subdir() {
  local ver="${1:-${PHP_VERSION}}"
  if [[ "$ver" = "${PHP_VERSION}" ]]; then printf 'php'; else printf 'php-%s' "$(_php_ver_no_dot "$ver")"; fi
}
_php_service_name() {
  local ver="${1:-${PHP_VERSION}}"
  if [[ "$ver" = "${PHP_VERSION}" ]]; then printf 'php'; else printf 'php%s' "$(_php_ver_no_dot "$ver")"; fi
}
_php_container_name() { printf 'lnmp-%s' "$(_php_service_name "$1")"; }

_write_php_laravel_conf() {
  local sub="${1:-php}"
  mkdir -p "${DATA_DIR}/${sub}/conf.d"
  cat > "${DATA_DIR}/${sub}/conf.d/99-laravel.ini" <<'PHPINI'
output_buffering = 4096

opcache.enable = 1
opcache.memory_consumption = 96
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.fast_shutdown = 1
PHPINI
}

_write_caddy_global() {
  mkdir -p "${DATA_DIR}/caddy/sites" "${DATA_DIR}/caddy/data" "${DATA_DIR}/caddy/config"
  local _email=""
  [[ -n "${ACME_EMAIL:-}" ]] && _email="	email ${ACME_EMAIL}
"
  if has_service "php"; then
    cat > "${DATA_DIR}/caddy/Caddyfile" <<CADDY
{
${_email}	frankenphp
	servers {
		protocols h1 h2 h3
	}
}

import /etc/caddy/sites/*.caddy
CADDY
  else
    cat > "${DATA_DIR}/caddy/Caddyfile" <<CADDY
{
${_email}	servers {
		protocols h1 h2 h3
	}
}

import /etc/caddy/sites/*.caddy
CADDY
  fi
  cat > "${DATA_DIR}/caddy/Caddyfile.internal" <<CADDY
{
	auto_https off
	admin off
	frankenphp
}

:8080 {
	root * ${CONTAINER_WWW}/{host}/public
	encode zstd gzip
	php_server {
		try_files {path} index.php
	}
}
CADDY
  [[ -f "${DATA_DIR}/caddy/sites/000-placeholder.caddy" ]] || printf '# placeholder\n' > "${DATA_DIR}/caddy/sites/000-placeholder.caddy"
}

_chown_caddy_volumes() {
  mkdir -p "${DATA_DIR}/caddy/sites" "${DATA_DIR}/caddy/data" "${DATA_DIR}/caddy/config"
  if has_service "php"; then
    chown -R 33:33 "${DATA_DIR}/caddy/data" "${DATA_DIR}/caddy/config" 2>/dev/null || true
    return 0
  fi
  has_service "caddy" || return 0
  local ids u
  u=$(docker image inspect "${CADDY_IMAGE:-caddy:2-alpine}" --format '{{.Config.User}}' 2>/dev/null || true)
  case "$u" in
    ""|root|0|0:0) return 0 ;;
    [0-9]*:[0-9]*) ids="$u" ;;
    [0-9]*) ids="${u}:${u}" ;;
    *)
      ids=$(docker run --rm --entrypoint sh "${CADDY_IMAGE:-caddy:2-alpine}" -c 'printf %s:%s "$(id -u)" "$(id -g)"' 2>/dev/null || true)
      [[ "$ids" =~ ^[0-9]+:[0-9]+$ ]] || ids="1000:1000"
      ;;
  esac
  chown -R "$ids" "${DATA_DIR}/caddy/data" "${DATA_DIR}/caddy/config" 2>/dev/null || true
}

_write_mysql_low_memory_conf() {
  has_service "mysql" || return 0
  mkdir -p "${DATA_DIR}/mysql-docker/conf.d"
  cat > "${DATA_DIR}/mysql-docker/conf.d/99-lnmp-low-memory.cnf" <<'MYCNF'
[mysqld]
innodb_buffer_pool_size = 256M
performance_schema = OFF
max_connections = 100
MYCNF
}

_ensure_php_pgsql_ext() {
  has_service "postgres" || return 0
  case ",${PHP_EXTENSIONS}," in
    *,pdo_pgsql,*) return 0 ;;
  esac
  PHP_EXTENSIONS="${PHP_EXTENSIONS},pdo_pgsql"
  PHP_EXTENSIONS="${PHP_EXTENSIONS#,}"
}

_php_franken_image() { printf 'dunglas/frankenphp:php%s' "${1:-${PHP_VERSION}}"; }

_php_service_yaml() {
  local ver="$1" php_deps="$2" php_env="$3"
  local sub svc cname volname
  sub="$(_php_data_subdir "$ver")"
  svc="$(_php_service_name "$ver")"
  cname="$(_php_container_name "$ver")"
  if [[ "$ver" = "${PHP_VERSION}" ]]; then volname="php-extensions"; else volname="php-extensions-$(_php_ver_no_dot "$ver")"; fi
  local vol_caddy="" ports="" cap=""
  if [[ "$ver" = "${PHP_VERSION}" ]]; then
    ports="
    ports: [\"80:80\", \"443:443\", \"443:443/udp\"]"
    cap="
    cap_add: [NET_BIND_SERVICE]"
    vol_caddy="      - ${DATA_DIR}/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${DATA_DIR}/caddy/sites:/etc/caddy/sites
      - ${DATA_DIR}/caddy/data:/data
      - ${DATA_DIR}/caddy/config:/config
      - ${DATA_DIR}/ssl:/ssl:ro"
    php_env+="      - ACME_EMAIL=${ACME_EMAIL}
"
  else
    vol_caddy="      - ${DATA_DIR}/caddy/Caddyfile.internal:/etc/caddy/Caddyfile:ro
      - ${DATA_DIR}/${sub}/caddy-data:/data
      - ${DATA_DIR}/${sub}/caddy-config:/config"
  fi
  local out="
  ${svc}:
    image: $(_php_franken_image "$ver")
    container_name: ${cname}
    user: \"33:33\"
    security_opt: [\"no-new-privileges:true\"]${cap}${ports}
    volumes:
      - ${DATA_DIR}/www:${CONTAINER_WWW}
      - ${DATA_DIR}/${sub}/conf.d/99-laravel.ini:/usr/local/etc/php/conf.d/99-laravel.ini:ro
      - ${DATA_DIR}/${sub}/composer-cache:/tmp/composer-cache
      - ${volname}:/usr/local/lib/php/extensions
${vol_caddy}"
  if [[ -n "$php_env" ]]; then out+="
    environment:
${php_env}"; fi
  if [[ -n "$php_deps" ]]; then out+="
    depends_on:
${php_deps}"; fi
  out+="
    restart: always
    networks: [lnmp-net]
"
  printf '%s' "$out"
}

lnmp_gen_compose() {
  mkdir -p "${DATA_DIR}"/{nginx/conf.d,mysql,mysql-docker/conf.d,postgres,redis,www,ssl,php/conf.d,php/composer-cache,caddy/sites,caddy/data,caddy/config}
  chmod 1777 "${DATA_DIR}/php/composer-cache" 2>/dev/null || true
  _write_caddy_global

  if has_service "php"; then
    _php_franken_ok "${PHP_VERSION}" || die "FrankenPHP 仅支持 PHP 8.2–8.5（当前默认: ${PHP_VERSION}）"
    _write_php_laravel_conf "php"
    local _ev _esub
    while IFS= read -r _ev; do
      [[ -z "$_ev" ]] && continue
      _php_franken_ok "$_ev" || die "FrankenPHP 仅支持 PHP 8.2–8.5（额外版本: ${_ev}）"
      _esub="$(_php_data_subdir "$_ev")"
      mkdir -p "${DATA_DIR}/${_esub}"/{conf.d,composer-cache,caddy-data,caddy-config}
      chmod 1777 "${DATA_DIR}/${_esub}/composer-cache" 2>/dev/null || true
      _write_php_laravel_conf "$_esub"
    done < <(_php_extra_list)
  fi
  _write_mysql_low_memory_conf

  local yaml="services:"
  local volumes_section=""

  if has_service "caddy" && ! has_service "php"; then
    yaml+="
  caddy:
    image: ${CADDY_IMAGE}
    container_name: lnmp-caddy
    cap_add: [NET_BIND_SERVICE]
    security_opt: [\"no-new-privileges:true\"]
    ports: [\"80:80\", \"443:443\", \"443:443/udp\"]
    volumes:
      - ${DATA_DIR}/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${DATA_DIR}/caddy/sites:/etc/caddy/sites
      - ${DATA_DIR}/caddy/data:/data
      - ${DATA_DIR}/caddy/config:/config
      - ${DATA_DIR}/www:${CONTAINER_WWW}
      - ${DATA_DIR}/ssl:/ssl:ro
    environment:
      - ACME_EMAIL=${ACME_EMAIL}
    restart: always
    networks: [lnmp-net]
"
  fi

  if has_service "php"; then
    local php_deps="" php_env=""
    has_service "mysql" && php_deps+="      - mysql
" && php_env+="      - DB_HOST=mysql
"
    has_service "postgres" && php_deps+="      - postgres
"
    has_service "redis" && php_deps+="      - redis
" && php_env+="      - REDIS_HOST=redis
"

    yaml+="$(_php_service_yaml "$PHP_VERSION" "$php_deps" "$php_env")"
    volumes_section="
volumes:
  php-extensions:"

    local _ev
    while IFS= read -r _ev; do
      [[ -z "$_ev" ]] && continue
      yaml+="$(_php_service_yaml "$_ev" "$php_deps" "$php_env")"
      volumes_section+="
  php-extensions-$(_php_ver_no_dot "$_ev"):"
    done < <(_php_extra_list)
  fi

  if has_service "mysql"; then
    yaml+="
  mysql:
    image: ${MYSQL_IMAGE}
    container_name: lnmp-mysql
    security_opt: [\"no-new-privileges:true\"]
    volumes:
      - ${DATA_DIR}/mysql:/var/lib/mysql
      - ${DATA_DIR}/mysql-docker/conf.d/99-lnmp-low-memory.cnf:/etc/mysql/conf.d/99-lnmp-low-memory.cnf:ro
    restart: always
    networks: [lnmp-net]
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD:-changeme}
      - TZ=Asia/Shanghai
"
  fi

  if has_service "postgres"; then
    yaml+="
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: lnmp-postgres
    security_opt: [\"no-new-privileges:true\"]
    command: [\"postgres\", \"-c\", \"shared_buffers=256MB\", \"-c\", \"max_connections=100\"]
    volumes:
      - ${DATA_DIR}/postgres:/var/lib/postgresql/data
    restart: always
    networks: [lnmp-net]
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-changeme}
      - TZ=Asia/Shanghai
"
  fi

  if has_service "redis"; then
    yaml+="
  redis:
    image: ${REDIS_IMAGE}
    container_name: lnmp-redis
    user: \"999:999\"
    security_opt: [\"no-new-privileges:true\"]
    command: [\"redis-server\", \"--save\", \"60\", \"1\", \"--save\", \"300\", \"10\", \"--loglevel\", \"warning\"]
    volumes:
      - ${DATA_DIR}/redis:/data
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 10s
      timeout: 3s
      retries: 3
    restart: always
    networks: [lnmp-net]
"
  fi

  if has_service "phpmyadmin"; then
    local pma_deps=""
    has_service "mysql" && pma_deps="
    depends_on: [mysql]"
    yaml+="
  phpmyadmin:
    image: ${PHPMYADMIN_IMAGE}
    container_name: lnmp-phpmyadmin
    security_opt: [\"no-new-privileges:true\"]${pma_deps}
    ports: [\"${PHPMYADMIN_BIND}:${PHPMYADMIN_PORT}:80\"]
    environment:
      - PMA_HOST=mysql
      - PMA_PORT=3306
      - UPLOAD_LIMIT=128M
      - TZ=Asia/Shanghai
    restart: always
    networks: [lnmp-net]
"
  fi

  if has_service "acme"; then
    yaml+="
  acme:
    image: ${ACME_IMAGE}
    container_name: lnmp-acme
    security_opt: [\"no-new-privileges:true\"]
    volumes:
      - ${DATA_DIR}/ssl:/acme.sh
      - ${DATA_DIR}/www:/www
      - /var/run/docker.sock:/var/run/docker.sock
      - /usr/bin/docker:/usr/bin/docker:ro
    environment:
      - ACME_EMAIL=${ACME_EMAIL}
    entrypoint: /bin/sh
    command: \"-c \\\"while true; do sleep 86400; done\\\"\"
    restart: always
    networks: [lnmp-net]
"
  fi

  yaml+="
networks:
  lnmp-net:
${volumes_section}"

  echo "$yaml" > "$COMPOSE_FILE"
}

install_lnmp() {
  local component="${1:-all}"
  hr; info "部署 LNMP (${component})"; echo ""

  run_pkg install -y acl 2>/dev/null || true

  is_docker_ok || die "需要先安装 Docker"
  systemctl start docker 2>/dev/null || true

  if [[ "$component" != "all" ]]; then
    if [[ "$component" = "nginx" ]]; then component="caddy"; fi
    if [[ ",$LNMP_SERVICES," != *",$component,"* ]]; then LNMP_SERVICES="${LNMP_SERVICES},${component}"; fi
    if [[ "$component" = "phpmyadmin" && ",$LNMP_SERVICES," != *",mysql,"* ]]; then LNMP_SERVICES="${LNMP_SERVICES},mysql"; fi
  fi

  lnmp_gen_compose

  docker stop lnmp-nginx 2>/dev/null || true
  docker rm lnmp-nginx 2>/dev/null || true

  local _dg
  _dg=$(id -gn "${DEVOPS_USER}" 2>/dev/null || echo "${DEVOPS_USER}")
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${DATA_DIR}/www" 2>/dev/null || true
  chmod g+s "${DATA_DIR}/www"
  mkdir -p "${DATA_DIR}/caddy/sites" "${DATA_DIR}/caddy/data" "${DATA_DIR}/caddy/config"
  chmod 755 "${DATA_DIR}/caddy/sites" 2>/dev/null || true
  chmod 755 "${DATA_DIR}/ssl" 2>/dev/null || true
  shopt -s nullglob
  for _sd in "${DATA_DIR}/ssl"/*/; do
    [[ -d "$_sd" ]] || continue
    chmod 755 "$_sd" 2>/dev/null || true
    chown 33:33 "$_sd" 2>/dev/null || true
    for _sf in "$_sd"/*; do
      [[ -f "$_sf" ]] || continue
      case "${_sf##*/}" in
        *.key) chmod 640 "$_sf" 2>/dev/null || true ;;
        *)     chmod 644 "$_sf" 2>/dev/null || true ;;
      esac
      chown 33:33 "$_sf" 2>/dev/null || true
    done
  done
  shopt -u nullglob
  if [[ -z "$(ls -A "${DATA_DIR}/redis" 2>/dev/null)" ]]; then chown -R 999:999 "${DATA_DIR}/redis" 2>/dev/null || true; fi
  if has_service "postgres" && [[ -z "$(ls -A "${DATA_DIR}/postgres" 2>/dev/null)" ]]; then
    chown -R 70:70 "${DATA_DIR}/postgres" 2>/dev/null || true
  fi
  chmod -R 755 "${DATA_DIR}"
  chown root:"${_dg}" "${DATA_DIR}" 2>/dev/null || true
  chmod 771 "${DATA_DIR}"

  if has_service "caddy" && ! has_service "php"; then
    _compose_up pull caddy >/dev/null 2>&1 || true
  fi
  _chown_caddy_volumes
  if has_service "php"; then
    local _ev _esub
    chown -R 33:33 "${DATA_DIR}/caddy/data" "${DATA_DIR}/caddy/config" 2>/dev/null || true
    while IFS= read -r _ev; do
      [[ -z "$_ev" ]] && continue
      _esub="$(_php_data_subdir "$_ev")"
      mkdir -p "${DATA_DIR}/${_esub}"/{caddy-data,caddy-config}
      chown -R 33:33 "${DATA_DIR}/${_esub}/caddy-data" "${DATA_DIR}/${_esub}/caddy-config" 2>/dev/null || true
    done < <(_php_extra_list)
  fi

  _ensure_php_pgsql_ext

  _compose_up up -d --remove-orphans

  if has_service "php"; then
    _wait_container "php" 45
    _install_php_extensions
  elif has_service "caddy"; then
    _wait_container "caddy" 45
  fi

  if has_service "acme"; then
    _setup_acme_cron
  fi

  _setup_logrotate

  conf_save
  ok "LNMP 部署完成"
}

_setup_logrotate() {
  command -v logrotate &>/dev/null || { info "logrotate 未安装，跳过日志轮转配置"; return 0; }
  local extra_logs="" _ev _esub
  while IFS= read -r _ev; do
    [[ -z "$_ev" ]] && continue
    _esub="$(_php_data_subdir "$_ev")"
    extra_logs+="
${DATA_DIR}/${_esub}/log/*.log"
  done < <(_php_extra_list)
  cat > /etc/logrotate.d/lnmp <<LOGROTATE
${DATA_DIR}/logs/*/*.log
${DATA_DIR}/logs/_global/*.log
/var/log/acme-renew.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d
}
LOGROTATE
  ok "logrotate 已配置（/etc/logrotate.d/lnmp，每日轮转保留 14 天）"
}

_compose_up() {
  local env_args=()
  if has_service "mysql" && [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    env_args+=(MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD")
  fi
  if has_service "postgres" && [[ -n "${POSTGRES_PWD:-}" ]]; then
    env_args+=(POSTGRES_PASSWORD="$POSTGRES_PWD")
  fi
  if [[ ${#env_args[@]} -gt 0 ]]; then
    env "${env_args[@]}" compose_cmd -f "$COMPOSE_FILE" "$@"
  else
    compose_cmd -f "$COMPOSE_FILE" "$@"
  fi
}

_compose_lnmp_up_recreate() {
  local svc="${1:-}"
  if [[ -n "$svc" ]]; then
    _compose_up up -d --force-recreate --no-deps "$svc"
  else
    _compose_up up -d --force-recreate
  fi
}

update_lnmp() {
  local one="${1:-}"
  hr
  if [[ -n "$one" ]]; then info "更新 LNMP 容器: ${one}"; else info "更新 LNMP 镜像并重拉容器"; fi
  echo ""
  is_docker_ok || die "需要先安装 Docker"
  [[ -f "$COMPOSE_FILE" ]] || die "未找到 LNMP 编排，请先安装 LNMP"
  lnmp_gen_compose
  docker stop lnmp-nginx 2>/dev/null || true
  docker rm lnmp-nginx 2>/dev/null || true
  if [[ -n "$one" ]]; then
    [[ "$one" = "nginx" ]] && one="caddy"
    if [[ "$one" = "caddy" ]] && has_service "php"; then one="php"; fi
    case "$one" in
      caddy|php|mysql|postgres|redis|acme|phpmyadmin) ;;
      php-*)
        local _ev="${one#php-}"
        _php_extra_list | grep -qx "$_ev" || die "未知 LNMP 组件: $one（请确认 EXTRA_PHP_VERSIONS 含此版本）"
        local _esvc; _esvc="$(_php_service_name "$_ev")"
        compose_cmd -f "$COMPOSE_FILE" pull "$_esvc"
        _compose_lnmp_up_recreate "$_esvc"
        _wait_container "$(_php_container_name "$_ev")" 45
        _install_php_extensions_one "$(_php_container_name "$_ev")"
        conf_save; ok "LNMP 已更新"; return 0
        ;;
      *) die "未知 LNMP 组件: $one（caddy|php|mysql|postgres|redis|acme|phpmyadmin|php-<版本>）" ;;
    esac
    has_service "$one" || die "当前编排未包含 lnmp-${one}"
    compose_cmd -f "$COMPOSE_FILE" pull "$one"
    _compose_lnmp_up_recreate "$one"
    if [[ "$one" = "php" ]]; then
      _wait_container "php" 45
      _install_php_extensions_one "lnmp-php"
    elif [[ "$one" = "caddy" ]]; then
      _wait_container "caddy" 45
    fi
  else
    compose_cmd -f "$COMPOSE_FILE" pull
    _compose_lnmp_up_recreate ""
    if has_service "php"; then
      _wait_container "php" 45
      _install_php_extensions
    elif has_service "caddy"; then
      _wait_container "caddy" 45
    fi
  fi
  conf_save
  ok "LNMP 已更新"
}

_wait_container() {
  local name="$1" max="${2:-30}"
  local cname="lnmp-${name}"
  [[ "$name" = lnmp-* ]] && cname="$name"
  for _ in $(seq 1 "$max"); do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$" \
      && docker exec "$cname" true &>/dev/null && return 0
    sleep 2
  done
  docker logs --tail 40 "$cname" 2>&1 | sed 's/^/  /' || true
  die "容器 ${cname} 启动超时"
}

_php_ext_show_log_tail() {
  local logfile="$1"
  [[ -f "$logfile" ]] || return 0
  warn "=== 扩展安装日志（末尾 60 行）: ${logfile} ==="
  tail -n 60 "$logfile" >&2
  warn "=== 日志结束 ==="
}

_install_php_extensions_one() {
  local cname="$1"
  local logfile="${DATA_DIR}/php/log/ext-install-${cname}.log"
  mkdir -p "${DATA_DIR}/php/log"
  : > "$logfile" 2>/dev/null || logfile="/tmp/php-ext-install-${cname}.log"; : > "$logfile"
  info "安装 PHP 扩展（${cname}），日志：${logfile}"

  IFS=',' read -ra exts <<< "$PHP_EXTENSIONS"
  local want="" e
  for e in "${exts[@]}"; do
    e="${e//[[:space:]]/}"
    [[ -z "$e" ]] && continue
    want+="${want:+ }$e"
  done
  [[ -n "$want" ]] || { ok "未配置 PHP 扩展（${cname}）"; return 0; }

  docker exec -u root "$cname" install-php-extensions $want 2>&1 | tee -a "$logfile"
  [[ "${PIPESTATUS[0]}" -eq 0 ]] || { _php_ext_show_log_tail "$logfile"; die "PHP 扩展安装失败（${cname}）。日志：${logfile}"; }

  docker restart "$cname"
  local svc="${cname#lnmp-}"
  _wait_container "$svc" 20
  ok "PHP 扩展安装完成（${cname}）"
}


_install_php_extensions() {
  _install_php_extensions_one "lnmp-php"
  local _ev _ec
  while IFS= read -r _ev; do
    [[ -z "$_ev" ]] && continue
    _ec="$(_php_container_name "$_ev")"
    _wait_container "$_ec" 45
    _install_php_extensions_one "$_ec"
  done < <(_php_extra_list)
}

_setup_acme_cron() {
  local common_sh="${SCRIPT_DIR}/lib/common.sh"
  cat > /usr/local/bin/acme-renew.sh <<SH
#!/bin/bash
DATA_DIR="${DATA_DIR}"
CONF_FILE="${CONF_FILE:-/etc/lnmp-env.conf}"
DEPLOY_LOG_TEE=1
# shellcheck disable=SC1091
[[ -f "${common_sh}" ]] && . "${common_sh}"
deploy_log_init ""
rc=0
docker exec lnmp-acme acme.sh --renew-all --server letsencrypt || rc=\$?
if [[ "\$rc" -ne 0 && "\$rc" -ne 2 ]]; then
  ops_notify_exception "ACME 续期失败" "acme.sh --renew-all exit=\${rc}"
fi
if ! caddy_reload; then
  ops_notify_exception "ACME 续期后 Caddy reload 失败" "caddy_reload"
fi
SH
  chmod +x /usr/local/bin/acme-renew.sh
  if ! ensure_crontab; then
    warn "未安装 crontab，已跳过 ACME 续期 cron。可稍后: dnf install -y cronie && systemctl enable --now crond"
    warn "然后执行: echo '0 3 1 * * /usr/local/bin/acme-renew.sh >> /var/log/acme-renew.log 2>&1' | crontab -"
    return 0
  fi
  local cron_line="0 3 1 * * /usr/local/bin/acme-renew.sh >> /var/log/acme-renew.log 2>&1"
  local existing
  existing=$(crontab -l 2>/dev/null || true)
  existing=$(echo "$existing" | { grep -v "acme-renew" || true; } | { grep -v "^$" || true; })
  if [[ -n "$existing" ]]; then
    printf '%s\n%s\n' "$existing" "$cron_line" | crontab -
  else
    echo "$cron_line" | crontab -
  fi
  ok "ACME 续期 cron 已添加"
}

uninstall_lnmp() {
  local component="${1:-all}"
  [[ "$component" = "nginx" ]] && component="caddy"
  hr; info "卸载 LNMP (${component})"; echo ""

  if [[ "$component" = "all" ]]; then
    if [[ -f "$COMPOSE_FILE" ]]; then
      cd "$DATA_DIR" && compose_cmd -f "$COMPOSE_FILE" down -v 2>/dev/null || true
    fi
    LNMP_SERVICES=""
    EXTRA_PHP_VERSIONS=""
    /bin/rm -f "$COMPOSE_FILE"
    if confirm "是否删除数据目录 ${DATA_DIR}？" "n"; then
      /bin/rm -rf "$DATA_DIR"
    fi
  elif [[ "$component" = php-* ]]; then
    local _ev="${component#php-}"
    local _esvc; _esvc="$(_php_service_name "$_ev")"
    local _ec;   _ec="$(_php_container_name "$_ev")"
    local _esub; _esub="$(_php_data_subdir "$_ev")"
    docker stop "$_ec" 2>/dev/null || true
    docker rm "$_ec" 2>/dev/null || true
    # compose project 名取决于 cwd basename / -p 参数；用模糊匹配兜底防漏删
    local _vsfx="php-extensions-$(_php_ver_no_dot "$_ev")"
    docker volume rm "$(basename "$DATA_DIR")_${_vsfx}" 2>/dev/null || true
    docker volume ls -q 2>/dev/null | awk -v p="_${_vsfx}\$" '$0 ~ p' \
      | xargs -r docker volume rm 2>/dev/null || true
    local newv="" v
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      [[ "$v" = "$_ev" ]] && continue
      newv+="${newv:+,}${v}"
    done < <(_php_extra_list)
    EXTRA_PHP_VERSIONS="$newv"
    if [[ -d "${DATA_DIR}/${_esub}" ]] && confirm "是否删除 ${DATA_DIR}/${_esub} 数据目录（含日志/扩展缓存）？" "n"; then
      /bin/rm -rf "${DATA_DIR}/${_esub}"
    fi
    if has_service "php"; then
      lnmp_gen_compose
      compose_cmd -f "$COMPOSE_FILE" up -d 2>/dev/null || true
    fi
  else
    local new_services=""
    IFS=',' read -ra svcs <<< "$LNMP_SERVICES"
    for s in "${svcs[@]}"; do
      if [[ "$s" = "$component" ]]; then continue; fi
      if [[ -n "$new_services" ]]; then new_services+=","; fi
      new_services+="$s"
    done
    LNMP_SERVICES="$new_services"

    docker stop "lnmp-${component}" 2>/dev/null || true
    docker rm "lnmp-${component}" 2>/dev/null || true

    if [[ "$component" = "php" ]]; then
      local _ev _ec
      while IFS= read -r _ev; do
        [[ -z "$_ev" ]] && continue
        _ec="$(_php_container_name "$_ev")"
        docker stop "$_ec" 2>/dev/null || true
        docker rm "$_ec" 2>/dev/null || true
      done < <(_php_extra_list)
      EXTRA_PHP_VERSIONS=""
    fi

    if [[ -n "$LNMP_SERVICES" ]]; then
      lnmp_gen_compose
      compose_cmd -f "$COMPOSE_FILE" up -d 2>/dev/null || true
    fi
  fi

  conf_save
  ok "LNMP (${component}) 已卸载"
}

