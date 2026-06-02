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
; 生产环境关闭时间戳校验（每次请求不检查文件变化），依赖 deploy 时 kill -USR2 1 刷新缓存
opcache.validate_timestamps = 0
opcache.fast_shutdown = 1
PHPINI
}

_write_php_fpm_slowlog_conf() {
  local sub="${1:-php}"
  mkdir -p "${DATA_DIR}/${sub}/fpm.d"
  cat > "${DATA_DIR}/${sub}/fpm.d/zz-slowlog.conf" <<'FPMCONF'
; 与官方镜像 [www] 池合并（zz- 保证在 www.conf、zz-docker 之后加载）
; 小内存 VPS 默认上限，可按机器内存调高
[www]
pm.max_children = 12
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
; 每个 worker 处理 500 次请求后自动重启，防止 PHP 内存泄漏长期积累
pm.max_requests = 500
slowlog = /var/log/php-fpm/fpm-slow.log
request_slowlog_timeout = 5s
FPMCONF
}

_write_php_fpm_wave_pool_conf() {
  local sub="${1:-php}"
  mkdir -p "${DATA_DIR}/${sub}/fpm.d"
  local _wpf="${DATA_DIR}/${sub}/fpm.d/wave-pool.conf"
  # Docker 在宿主机缺少该文件时 up 可能误建「目录」wave-pool.conf，导致 php-fpm 读配置失败、容器反复退出
  [[ -d "$_wpf" ]] && rm -rf "$_wpf"
  cat > "$_wpf" <<'FPMCONF'
; SSE 专用池；Nginx fastcgi_pass <service>:9001；须监听 0.0.0.0 以便跨容器访问
; 可按内存调整 pm.max_children（每个长连接占 1 worker）
[wave]
user = www-data
group = www-data
listen = 0.0.0.0:9001
pm = dynamic
pm.max_children = 8
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 3
; SSE 连接最长存活 4 小时（防止 graceful reload 后旧 worker 永不退出导致内存泄漏）
; 客户端会自动重连，业务无感知
request_terminate_timeout = 14400
clear_env = no
catch_workers_output = yes
slowlog = /var/log/php-fpm/fpm-slow.log
request_slowlog_timeout = 5s
FPMCONF
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

_ensure_php_fpm_slowlog_host_layout() {
  has_service "php" || return 0
  local sub
  for sub in php $(_php_extra_list | while read -r v; do _php_data_subdir "$v"; done); do
    mkdir -p "${DATA_DIR}/${sub}/log"
    : >>"${DATA_DIR}/${sub}/log/fpm-slow.log" 2>/dev/null || true
    chown -R 82:82 "${DATA_DIR}/${sub}/log" 2>/dev/null || true
    chmod 755 "${DATA_DIR}/${sub}/log" 2>/dev/null || true
    chmod 664 "${DATA_DIR}/${sub}/log/fpm-slow.log" 2>/dev/null || true
  done
}

_php_service_yaml() {
  local ver="$1" php_deps="$2" php_env="$3"
  local sub svc cname volname
  sub="$(_php_data_subdir "$ver")"
  svc="$(_php_service_name "$ver")"
  cname="$(_php_container_name "$ver")"
  if [[ "$ver" = "${PHP_VERSION}" ]]; then volname="php-extensions"; else volname="php-extensions-$(_php_ver_no_dot "$ver")"; fi
  local out="
  ${svc}:
    image: php:${ver}-fpm-alpine
    container_name: ${cname}
    user: \"82:82\"
    security_opt: [\"no-new-privileges:true\"]
    volumes:
      - ${DATA_DIR}/www:${CONTAINER_WWW}
      - ${DATA_DIR}/${sub}/conf.d/99-laravel.ini:/usr/local/etc/php/conf.d/99-laravel.ini:ro
      - ${DATA_DIR}/${sub}/fpm.d/zz-slowlog.conf:/usr/local/etc/php-fpm.d/zz-slowlog.conf:ro
      - ${DATA_DIR}/${sub}/fpm.d/wave-pool.conf:/usr/local/etc/php-fpm.d/wave-pool.conf:ro
      - ${DATA_DIR}/${sub}/log:/var/log/php-fpm
      - ${DATA_DIR}/${sub}/composer-cache:/tmp/composer-cache
      - ${volname}:/usr/local/lib/php/extensions"
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
  mkdir -p "${DATA_DIR}"/{nginx/conf.d,nginx/logs,nginx/cache,mysql,mysql-docker/conf.d,redis,www,ssl,php/conf.d,php/fpm.d,php/log,php/composer-cache}
  chmod 1777 "${DATA_DIR}/php/composer-cache" 2>/dev/null || true

  if has_service "php"; then
    _write_php_laravel_conf "php"
    _write_php_fpm_slowlog_conf "php"
    _write_php_fpm_wave_pool_conf "php"
    local _ev _esub
    while IFS= read -r _ev; do
      [[ -z "$_ev" ]] && continue
      _esub="$(_php_data_subdir "$_ev")"
      mkdir -p "${DATA_DIR}/${_esub}"/{conf.d,fpm.d,log,composer-cache}
      chmod 1777 "${DATA_DIR}/${_esub}/composer-cache" 2>/dev/null || true
      _write_php_laravel_conf "$_esub"
      _write_php_fpm_slowlog_conf "$_esub"
      _write_php_fpm_wave_pool_conf "$_esub"
    done < <(_php_extra_list)
  fi
  _write_mysql_low_memory_conf

  if [[ ! -f "${DATA_DIR}/nginx/nginx.conf" ]]; then _write_nginx_main_conf; fi
  if [[ ! -f "${DATA_DIR}/nginx/conf.d/default.conf" ]]; then _write_nginx_default_conf; fi

  local yaml="services:"
  local volumes_section=""

  if has_service "nginx"; then
    local _nginx_deps="[php"
    local _ev
    while IFS= read -r _ev; do
      [[ -z "$_ev" ]] && continue
      _nginx_deps+=", $(_php_service_name "$_ev")"
    done < <(_php_extra_list)
    _nginx_deps+="]"
    yaml+="
  nginx:
    image: ${NGINX_IMAGE}
    container_name: lnmp-nginx
    user: \"101:101\"
    security_opt: [\"no-new-privileges:true\"]
    cap_add: [NET_BIND_SERVICE]
    depends_on: ${_nginx_deps}
    ports: [\"80:80\", \"443:443\"]
    volumes:
      - ${DATA_DIR}/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${DATA_DIR}/nginx/conf.d:/etc/nginx/conf.d
      - ${DATA_DIR}/nginx/logs:/var/log/nginx
      - ${DATA_DIR}/nginx/cache:/var/cache/nginx
      - ${DATA_DIR}/www:${CONTAINER_WWW}
      - ${DATA_DIR}/ssl:/etc/nginx/ssl
    restart: always
    networks: [lnmp-net]
"
  fi

  if has_service "php"; then
    local php_deps="" php_env=""
    has_service "mysql" && php_deps+="      - mysql
" && php_env+="      - DB_HOST=mysql
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

_write_nginx_main_conf() {
  cat > "${DATA_DIR}/nginx/nginx.conf" <<'NGINXMAIN'
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/cache/nginx/nginx.pid;

events {
    worker_connections  1024;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    server_tokens   off;

    client_max_body_size 64m;
    client_body_timeout  60;
    client_header_timeout 60;

    gzip on;
    gzip_vary on;
    gzip_min_length 1k;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml
               application/xml+rss image/svg+xml;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling        off;
    ssl_stapling_verify off;

    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN
}

_write_nginx_default_conf() {
  cat > "${DATA_DIR}/nginx/conf.d/default.conf" <<'NGINX'
server {
    listen 80 default_server;
    server_name _;
    return 503;
}
NGINX
}

install_lnmp() {
  local component="${1:-all}"
  hr; info "部署 LNMP (${component})"; echo ""

  run_pkg install -y acl 2>/dev/null || true

  is_docker_ok || die "需要先安装 Docker"
  systemctl start docker 2>/dev/null || true

  if [[ "$component" != "all" ]]; then
    if [[ ",$LNMP_SERVICES," != *",$component,"* ]]; then LNMP_SERVICES="${LNMP_SERVICES},${component}"; fi
    if [[ "$component" = "nginx" && ",$LNMP_SERVICES," != *",php,"* ]]; then LNMP_SERVICES="${LNMP_SERVICES},php"; fi
    if [[ "$component" = "phpmyadmin" && ",$LNMP_SERVICES," != *",mysql,"* ]]; then LNMP_SERVICES="${LNMP_SERVICES},mysql"; fi
  fi

  lnmp_gen_compose

  if has_service "nginx" && [[ -f "${DATA_DIR}/nginx/nginx.conf" ]]; then
    sed -i 's|/var/run/nginx.pid|/var/cache/nginx/nginx.pid|g' "${DATA_DIR}/nginx/nginx.conf" 2>/dev/null || true
  fi

  local _dg
  _dg=$(id -gn "${DEVOPS_USER}" 2>/dev/null || echo "${DEVOPS_USER}")
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${DATA_DIR}/www" 2>/dev/null || true
  chmod g+s "${DATA_DIR}/www"
  chown -R 101:101 "${DATA_DIR}/nginx/logs" 2>/dev/null || true
  mkdir -p "${DATA_DIR}/nginx/cache"
  chown -R 101:101 "${DATA_DIR}/nginx/cache" 2>/dev/null || true
  chmod -R 755 "${DATA_DIR}/nginx/cache" 2>/dev/null || true
  chmod 755 "${DATA_DIR}/nginx/conf.d" 2>/dev/null || true
  shopt -s nullglob
  for _nf in "${DATA_DIR}/nginx/conf.d"/*.conf; do
    chmod 644 "$_nf" 2>/dev/null || true
    chown 101:101 "$_nf" 2>/dev/null || true
  done
  shopt -u nullglob
  chmod 755 "${DATA_DIR}/ssl" 2>/dev/null || true
  shopt -s nullglob
  for _sd in "${DATA_DIR}/ssl"/*/; do
    [[ -d "$_sd" ]] || continue
    chmod 755 "$_sd" 2>/dev/null || true
    chown 101:101 "$_sd" 2>/dev/null || true
    for _sf in "$_sd"/*; do
      [[ -f "$_sf" ]] || continue
      case "${_sf##*/}" in
        *.key) chmod 640 "$_sf" 2>/dev/null || true ;;
        *)     chmod 644 "$_sf" 2>/dev/null || true ;;
      esac
      chown 101:101 "$_sf" 2>/dev/null || true
    done
  done
  shopt -u nullglob
  if [[ -z "$(ls -A "${DATA_DIR}/redis" 2>/dev/null)" ]]; then chown -R 999:999 "${DATA_DIR}/redis" 2>/dev/null || true; fi
  chmod -R 755 "${DATA_DIR}"
  chown root:"${_dg}" "${DATA_DIR}" 2>/dev/null || true
  chmod 771 "${DATA_DIR}"

  _ensure_php_fpm_slowlog_host_layout

  _compose_up up -d

  if has_service "php"; then
    _wait_container "php" 30
    _install_php_extensions
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
${DATA_DIR}/logs/*.log
/var/log/acme-renew.log
${DATA_DIR}/nginx/logs/*.log
${DATA_DIR}/php/log/*.log${extra_logs} {
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
  if has_service "mysql" && [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" compose_cmd -f "$COMPOSE_FILE" "$@"
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
  _ensure_php_fpm_slowlog_host_layout
  if [[ -n "$one" ]]; then
    case "$one" in
      nginx|php|mysql|redis|acme|phpmyadmin) ;;
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
      *) die "未知 LNMP 组件: $one（nginx|php|mysql|redis|acme|phpmyadmin|php-<版本>）" ;;
    esac
    has_service "$one" || die "当前编排未包含 lnmp-${one}"
    compose_cmd -f "$COMPOSE_FILE" pull "$one"
    _compose_lnmp_up_recreate "$one"
    if [[ "$one" = "php" ]]; then
      _wait_container "php" 45
      _install_php_extensions_one "lnmp-php"
    fi
  else
    compose_cmd -f "$COMPOSE_FILE" pull
    _compose_lnmp_up_recreate ""
    if has_service "php"; then
      _wait_container "php" 45
      _install_php_extensions
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
  if [[ "$cname" = lnmp-php* ]]; then
    local _sub="php"
    [[ "$cname" != "lnmp-php" ]] && _sub="php-${cname#lnmp-php}"
    warn "${cname} 诊断提示: docker logs ${cname} 2>&1 | tail -n 40"
    warn "若曾缺少 wave-pool.conf 即执行过 compose up，宿主机 ${DATA_DIR}/${_sub}/fpm.d/wave-pool.conf 可能被建成目录；应 rm -rf 后重新 init 写入配置并 force-recreate ${cname#lnmp-}"
  fi
  die "容器 ${cname} 启动超时"
}

_php_ext_exec_with_apk_retry() {
  local cname="$1" inner="$2" logfile="$3"
  local attempt=1 max=12 pause=5 _rc
  sleep 2
  while ((attempt <= max)); do
    docker exec -u root -e TERM=dumb "$cname" sh -c "$inner" 2>&1 | tee -a "$logfile"
    _rc="${PIPESTATUS[0]}"
    [[ "$_rc" -eq 0 ]] && return 0
    [[ "$_rc" -eq 42 ]] && return 42
    if ((attempt < max)); then
      warn "容器内 apk 可能被占用或暂锁库，${pause}s 后重试 (${attempt}/${max})..." | tee -a "$logfile"
      sleep "$pause"
    fi
    ((attempt++)) || true
  done
  return 1
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
  local logfile="${DATA_DIR}/$( \
    svc="${cname#lnmp-}"; \
    if [[ "$svc" = "php" ]]; then printf 'php'; \
    else printf 'php-%s' "${svc#php}"; fi \
  )/log/ext-install.log"
  : > "$logfile" 2>/dev/null || logfile="/tmp/php-ext-install-${cname}.log"; : > "$logfile"
  info "安装 PHP 扩展（${cname}），日志：${logfile}"

  IFS=',' read -ra exts <<< "$PHP_EXTENSIONS"
  local need_gd=0 need_intl=0 need_redis=0
  local ext_install=""

  for e in "${exts[@]}"; do
    case "$e" in
      gd)    need_gd=1;    ext_install+=" gd" ;;
      intl)  need_intl=1;  ext_install+=" intl" ;;
      redis) need_redis=1 ;;
      *)     ext_install+=" $e" ;;
    esac
  done
  ext_install=$(echo "$ext_install" | xargs)

  local alpine_sed=""
  [[ -n "$ALPINE_MIRROR" ]] && alpine_sed="sed -i 's|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g' /etc/apk/repositories && apk update && "

  local php_ver gd_args redis_pkg
  php_ver="$(docker exec "$cname" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  [[ "$php_ver" =~ ^[0-9]+\.[0-9]+$ ]] || php_ver=""
  : "${php_ver:=8.3}"
  gd_args="--with-freetype --with-jpeg --with-webp"
  _lv_ge "$php_ver" "7.4" || gd_args="--with-freetype-dir=/usr --with-jpeg-dir=/usr --with-png-dir=/usr --with-webp-dir=/usr"
  if   ! _lv_ge "$php_ver" "7.2"; then redis_pkg="redis-4.3.0"
  elif ! _lv_ge "$php_ver" "7.4"; then redis_pkg="redis-5.3.7"
  else redis_pkg=""; fi

  _ext_loaded() {
    docker exec "$cname" php -r "exit(extension_loaded('$1')?0:1);" 2>/dev/null
  }
  local _filtered=""
  for e in $ext_install; do
    if _ext_loaded "$e"; then
      info "扩展 ${e} 已加载（${cname}），跳过编译"
    else
      _filtered+=" $e"
    fi
  done
  ext_install="$(echo "$_filtered" | xargs)"
  if [[ $need_gd -eq 1 ]] && _ext_loaded "gd"; then
    info "扩展 gd 已加载（${cname}），跳过"
    need_gd=0
  fi
  if [[ $need_intl -eq 1 ]] && _ext_loaded "intl"; then
    info "扩展 intl 已加载（${cname}），跳过"
    need_intl=0
  fi
  if [[ $need_redis -eq 1 ]] && _ext_loaded "redis"; then
    info "扩展 redis 已加载（${cname}），跳过"
    need_redis=0
  fi

  # PHP 8.5+: opcache 已内置（non-optional，无独立 .so），docker-php-ext-install 必然失败；改为直接启用
  local opcache_85_enable=0
  if [[ " $ext_install " = *" opcache "* ]] && _lv_ge "$php_ver" "8.5"; then
    info "PHP ${php_ver}: opcache 已内置，跳过编译，仅启用（${cname}）"
    ext_install="$(echo " $ext_install " | sed 's/ opcache / /g' | xargs)"
    opcache_85_enable=1
  fi

  local apk_deps="libpng-dev libwebp-dev freetype-dev libjpeg-turbo-dev libxml2-dev curl-dev build-base linux-headers autoconf libzip-dev icu-dev oniguruma-dev"
  local cmd="${alpine_sed}apk add --no-cache ${apk_deps}"

  if [[ $need_gd -eq 1 ]]; then cmd+=" && docker-php-ext-configure gd ${gd_args}"; fi
  if [[ $need_intl -eq 1 ]]; then
    if _lv_ge "$php_ver" "7.2"; then
      cmd+=" && docker-php-ext-configure intl"
    else
      warn "PHP ${php_ver} 镜像下 intl 编译可能因 icu 版本不兼容而失败，自动跳过 intl（${cname}）"
      need_intl=0
      ext_install=$(echo " $ext_install " | sed 's/ intl / /g' | xargs)
    fi
  fi
  if [[ -n "$ext_install" ]]; then
    cmd+=" && for _e in ${ext_install}; do"
    cmd+="   echo \"=== docker-php-ext-install \$_e ===\";"
    cmd+="   if php -r \"exit(extension_loaded('\$_e')?0:1);\" 2>/dev/null; then"
    cmd+="     echo \"-- \$_e already loaded, skip\"; continue;"
    cmd+="   fi;"
    cmd+="   if ! docker-php-ext-install -j\$(nproc) \"\$_e\"; then"
    cmd+="     if [ \"\$_e\" = opcache ]; then"
    cmd+="       echo \"-- opcache install failed, fallback to enable (PHP 8.5+ built-in)\";"
    cmd+="       docker-php-ext-enable opcache 2>/dev/null || printf 'zend_extension=opcache\\n' > /usr/local/etc/php/conf.d/docker-php-ext-opcache.ini;"
    cmd+="       continue;"
    cmd+="     fi;"
    cmd+="     echo \"!! ext \$_e install failed\"; exit 42;"
    cmd+="   fi;"
    cmd+=" done"
  fi
  if [[ $need_redis -eq 1 ]]; then
    local _redis_ipe_ver="" _redis_pecl="${redis_pkg:-redis}"
    [[ -n "$redis_pkg" ]] && _redis_ipe_ver="@${redis_pkg#redis-}"
    cmd+=" && export MAKEFLAGS=''"
    cmd+=" && if ! php -m 2>/dev/null | grep -q '^redis$'; then"
    cmd+="   echo \"=== pecl install ${_redis_pecl} ===\";"
    cmd+="   if printf '\\n' | pecl install ${_redis_pecl}; then"
    cmd+="     echo \"-- redis via pecl ok\";"
    cmd+="   else"
    cmd+="     echo \"-- pecl failed, fallback install-php-extensions (ipe)...\";"
    cmd+="     { command -v curl >/dev/null 2>&1 || apk add --no-cache curl ca-certificates; }"
    cmd+="     && curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o /tmp/ipe https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions"
    cmd+="     && chmod +x /tmp/ipe && /tmp/ipe redis${_redis_ipe_ver} && rm -f /tmp/ipe"
    cmd+="   fi"
    cmd+="   || { echo \"!! ext redis install failed\"; exit 42; };"
    cmd+=" fi"
    cmd+=" && { docker-php-ext-enable redis 2>/dev/null || true; }"
  fi
  if [[ $opcache_85_enable -eq 1 ]]; then
    cmd+=" && (docker-php-ext-enable opcache 2>/dev/null || printf 'zend_extension=opcache\n' > /usr/local/etc/php/conf.d/docker-php-ext-opcache.ini)"
  fi
  cmd+=" && apk del --no-cache build-base linux-headers autoconf"

  cmd="sleep 2; ${cmd}"
  local _ext_rc=0
  _php_ext_exec_with_apk_retry "$cname" "$cmd" "$logfile" || _ext_rc=$?
  if [[ $_ext_rc -eq 42 ]]; then
    local _failed_ext
    _failed_ext="$(grep -oE '!! ext [^ ]+ install failed' "$logfile" | tail -n1 | awk '{print $3}')"
    _php_ext_show_log_tail "$logfile"
    die "PHP 扩展 ${_failed_ext:-?} 安装失败（${cname}）。日志：${logfile}"
  elif [[ $_ext_rc -ne 0 ]]; then
    _php_ext_show_log_tail "$logfile"
    die "PHP 扩展安装失败（apk 多次重试仍失败：请确认无其他进程在 ${cname} 内执行 apk，或 docker restart ${cname} 后重试。日志：${logfile}）"
  fi
  docker restart "$cname"
  local svc="${cname#lnmp-}"
  _wait_container "$svc" 20

  if [[ $need_redis -eq 1 ]]; then
    docker exec "$cname" php -m | grep -q redis || {
      _php_ext_show_log_tail "$logfile"
      die "PHP redis 扩展安装失败（${cname}）。日志：${logfile}"
    }
  fi
  if [[ " $ext_install " = *" pdo_mysql "* ]]; then
    docker exec "$cname" php -m | grep -q pdo_mysql || {
      _php_ext_show_log_tail "$logfile"
      die "PHP pdo_mysql 扩展安装失败（${cname}）。日志：${logfile}"
    }
  fi

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
  cat > /usr/local/bin/acme-renew.sh <<'SH'
#!/bin/bash
docker exec lnmp-acme acme.sh --renew-all --server letsencrypt 2>/dev/null || true
docker exec lnmp-nginx nginx -s reload 2>/dev/null || true
SH
  chmod +x /usr/local/bin/acme-renew.sh
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

