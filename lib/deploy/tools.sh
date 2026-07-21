# shellcheck shell=bash

# printf -v 写入命名变量，避免 stdout 被 tee 记入日志（兼容 bash 3.2）
prompt_secret_into() {
  local msg="$1" _var="$2" val=""
  [[ "$_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "内部错误: 无效变量名"
  read -rsp "  ${msg}: " val </dev/tty; echo >/dev/tty
  printf -v "$_var" '%s' "$val"
}

env_set() {
  local key="$1" val="$2" envfile="$3"
  # key 必须符合 .env 规范，避免 sed 分隔符/元字符注入（CUSTOM_ENV 来源不可信）
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "env_set: 非法 key: ${key}"
  # val 含换行 dotenv 解析不一致；显式拒绝
  [[ "$val" == *$'\n'* ]] && die "env_set: ${key} 值含换行符，不支持"
  local escaped_val
  escaped_val=$(printf '%s' "$val" | sed 's/[\\&|]/\\&/g')
  # 支持 KEY=value、KEY = value、# KEY=value；漏改会导致旧行仍被 dotenv 读入（如 DB_DATABASE = mysql）
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$envfile" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${escaped_val}|" "$envfile"
  elif grep -qE "^[[:space:]]*#+[[:space:]]*${key}[[:space:]]*=" "$envfile" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*#+[[:space:]]*${key}[[:space:]]*=.*|${key}=${escaped_val}|" "$envfile"
  else
    echo "${key}=${val}" >> "$envfile"
  fi
}

container_ok() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"; }

# ─── 站点 PHP 版本：未指定时走默认 lnmp-php / service php ───
_php_ver_no_dot() { printf '%s' "${1//./}"; }

site_php_version_file() { printf '%s/%s.php-version' "$NGINX_CONF" "$1"; }

_php_ver_for_site() {
  local f; f="$(site_php_version_file "$1")"
  [[ -f "$f" ]] || { printf ''; return 0; }
  local v; v="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && printf '%s' "$v" || printf ''
}

# 计算默认 PHP_VERSION（来自 /etc/lnmp-env.conf），缓存到内存避免重复 source
_default_php_ver() {
  if [[ -z "${_DEFAULT_PHP_VER_CACHE:-}" ]]; then
    if [[ -f "$CONF_FILE" ]]; then
      _DEFAULT_PHP_VER_CACHE="$(grep -E '^PHP_VERSION=' "$CONF_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
    fi
    : "${_DEFAULT_PHP_VER_CACHE:=}"
  fi
  printf '%s' "$_DEFAULT_PHP_VER_CACHE"
}

_php_service_for_site() {
  local v; v="$(_php_ver_for_site "$1")"
  local d; d="$(_default_php_ver)"
  [[ -z "$v" || ( -n "$d" && "$v" = "$d" ) ]] && { printf 'php'; return 0; }
  printf 'php%s' "$(_php_ver_no_dot "$v")"
}

_php_container_for_site() {
  local v; v="$(_php_ver_for_site "$1")"
  local d; d="$(_default_php_ver)"
  [[ -z "$v" || ( -n "$d" && "$v" = "$d" ) ]] && { printf 'lnmp-php'; return 0; }
  printf 'lnmp-php%s' "$(_php_ver_no_dot "$v")"
}

_iter_php_containers() {
  # 默认 lnmp-php 在最前；其余 lnmp-phpNN（与 compose container_name 一致）按数值升序
  docker ps --format '{{.Names}}' 2>/dev/null \
    | awk '
      $0 == "lnmp-php" { has_def = 1; next }
      $0 ~ /^lnmp-php[0-9]+$/ {
        n = $0; sub(/^lnmp-php/, "", n); list[++idx] = n + 0; orig[n + 0] = $0
      }
      END {
        if (has_def) print "lnmp-php"
        # 简单插入排序
        for (i = 2; i <= idx; i++) {
          k = list[i]; j = i - 1
          while (j > 0 && list[j] > k) { list[j+1] = list[j]; j-- }
          list[j+1] = k
        }
        for (i = 1; i <= idx; i++) print orig[list[i]]
      }
    ' | awk '!seen[$0]++'
}

# ─── Laravel 版本（从站点 composer.json 提取 laravel/framework 约束的最低 X.Y）───
# 使用 awk 一次性完成解析，规避 set -euo pipefail 下 grep|head 的 SIGPIPE 风险
_site_composer_json() { printf '%s/%s/composer.json' "$WWW_ROOT" "$1"; }
_laravel_min_for_site() {
  local f; f="$(_site_composer_json "$1")"
  [[ -f "$f" ]] || { printf ''; return 0; }
  awk '
    match($0, /"laravel\/framework"[[:space:]]*:[[:space:]]*"[^"]+"/) {
      seg = substr($0, RSTART, RLENGTH)
      sub(/.*:[[:space:]]*"/, "", seg); sub(/".*/, "", seg)
      if (match(seg, /[0-9]+(\.[0-9]+)?/)) {
        printf "%s", substr(seg, RSTART, RLENGTH); exit
      }
    }
  ' "$f" 2>/dev/null || true
}

# 站点解析后的 PHP 版本（默认走 /etc/lnmp-env.conf 的 PHP_VERSION）
_php_ver_resolved_for_site() {
  local v; v="$(_php_ver_for_site "$1")"
  if [[ -z "$v" ]]; then
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
    v="${PHP_VERSION:-8.3}"
  fi
  printf '%s' "$v"
}

# 容器内运行时 PHP 主.次（取自镜像，不依赖 conf）
_php_runtime_ver_in_container() {
  local v
  v="$(docker exec "$1" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] || v=""
  printf '%s' "$v"
}

# 按 Laravel 版本决定健康探测路径（11+ 默认有 /up，否则用 /）
_status_probe_path_for_site() {
  local d="$1" t="$2" lv
  [[ "$t" != "laravel" ]] && { printf '/'; return; }
  lv="$(_laravel_min_for_site "$d")"
  if [[ -n "$lv" ]] && _lv_ge "$lv" "11"; then printf '/up'; else printf '/'; fi
}

# Laravel 版本支持 artisan optimize（5.7+）
_lv_supports_optimize() {
  local lv="$1"
  [[ -z "$lv" ]] && return 0
  _lv_ge "$lv" "5.7"
}
# Horizon 要求 Laravel ≥ 5.7.7 + PHP ≥ 7.2 + Redis（5.7 简化等价）
# 任一参数为空或非法格式时返回 1（保守拒绝），避免误启不兼容环境
_lv_supports_horizon() {
  local lv="${1:-}" php_ver="${2:-}"
  [[ "$php_ver" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
  _lv_ge "$php_ver" "7.2" || return 1
  [[ -z "$lv" ]] && return 0
  [[ "$lv" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  _lv_ge "$lv" "5.7" || return 1
  return 0
}

ensure_php_fpm_slowlog_host_artifacts() {
  [[ -d "${DATA_DIR}/php" ]] || return 0
  mkdir -p "${DATA_DIR}/php/fpm.d" "${DATA_DIR}/php/log"
  if [[ ! -f "${DATA_DIR}/php/fpm.d/zz-slowlog.conf" ]] || \
     ! grep -q 'pm.max_requests' "${DATA_DIR}/php/fpm.d/zz-slowlog.conf" 2>/dev/null; then
    cat > "${DATA_DIR}/php/fpm.d/zz-slowlog.conf" <<'FPMCONF'
; 与官方镜像 [www] 池合并（zz- 保证在 www.conf、zz-docker 之后加载）
; 小内存 VPS 默认上限，可按机器内存调高
[www]
pm.max_children = 12
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 500
slowlog = /var/log/php-fpm/fpm-slow.log
request_slowlog_timeout = 5s
FPMCONF
  fi
  : >>"${DATA_DIR}/php/log/fpm-slow.log" 2>/dev/null || true
  chown -R 82:82 "${DATA_DIR}/php/log" 2>/dev/null || true
  chmod 755 "${DATA_DIR}/php/log" 2>/dev/null || true
  chmod 664 "${DATA_DIR}/php/log/fpm-slow.log" 2>/dev/null || true
}

warn_php_fpm_slowlog_compose_missing() {
  container_ok "lnmp-php" || return 0
  [[ -f "${DATA_DIR}/docker-compose.yml" ]] || return 0
  grep -q 'php/fpm.d/zz-slowlog.conf' "${DATA_DIR}/docker-compose.yml" 2>/dev/null && return 0
  grep -q 'container_name: lnmp-php' "${DATA_DIR}/docker-compose.yml" 2>/dev/null || return 0
  warn "docker-compose 未挂载 php-fpm slowlog；请 init.sh 更新 LNMP 编排后执行: cd ${DATA_DIR} && docker compose up -d --force-recreate php"
}

ensure_php_fpm_wave_pool_host_artifacts() {
  [[ -d "${DATA_DIR}/php" ]] || return 0
  mkdir -p "${DATA_DIR}/php/fpm.d"
  local _wpf="${DATA_DIR}/php/fpm.d/wave-pool.conf"
  [[ -d "$_wpf" ]] && rm -rf "$_wpf"
  if [[ ! -f "$_wpf" ]] || \
     grep -qE '^pm\.max_children = 50$' "$_wpf" 2>/dev/null || \
     grep -qE '^request_terminate_timeout = 0$' "$_wpf" 2>/dev/null; then
    cat > "$_wpf" <<'FPMCONF'
; SSE 专用池；Nginx fastcgi_pass php:9001；须监听 0.0.0.0 以便跨容器访问
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
request_terminate_timeout = 14400
clear_env = no
catch_workers_output = yes
slowlog = /var/log/php-fpm/fpm-slow.log
request_slowlog_timeout = 5s
FPMCONF
  fi
}

warn_php_fpm_wave_pool_compose_missing() {
  container_ok "lnmp-php" || return 0
  [[ -f "${DATA_DIR}/docker-compose.yml" ]] || return 0
  grep -q 'php/fpm.d/wave-pool.conf' "${DATA_DIR}/docker-compose.yml" 2>/dev/null && return 0
  grep -q 'container_name: lnmp-php' "${DATA_DIR}/docker-compose.yml" 2>/dev/null || return 0
  warn "docker-compose 未挂载 Wave FPM 池（wave-pool.conf）；请重新运行 init.sh 生成编排，或手动加入挂载后: cd ${DATA_DIR} && docker compose up -d --force-recreate php"
}

ensure_mysql_low_memory_host_artifacts() {
  [[ -d "${DATA_DIR}" ]] || return 0
  mkdir -p "${DATA_DIR}/mysql-docker/conf.d"
  local _mf="${DATA_DIR}/mysql-docker/conf.d/99-lnmp-low-memory.cnf"
  [[ -f "$_mf" ]] && return 0
  cat > "$_mf" <<'MYCNF'
[mysqld]
innodb_buffer_pool_size = 256M
performance_schema = OFF
max_connections = 100
MYCNF
}

warn_mysql_low_memory_compose_missing() {
  container_ok "lnmp-mysql" || return 0
  [[ -f "${DATA_DIR}/docker-compose.yml" ]] || return 0
  grep -q '99-lnmp-low-memory.cnf' "${DATA_DIR}/docker-compose.yml" 2>/dev/null && return 0
  grep -q 'container_name: lnmp-mysql' "${DATA_DIR}/docker-compose.yml" 2>/dev/null || return 0
  warn "docker-compose 未挂载 MySQL 低内存配置；请 init.sh 重新生成 LNMP 编排后: cd ${DATA_DIR} && docker compose up -d --force-recreate mysql"
}

supervisord_ready() {
  command -v supervisorctl &>/dev/null || return 1
  local s
  for s in /run/supervisor/supervisor.sock /var/run/supervisor/supervisor.sock /var/run/supervisord.sock /tmp/supervisor.sock; do
    [[ -S "$s" ]] && return 0
  done
  supervisorctl status &>/dev/null
}

horizon_supervisor_conf_path() {
  local domain="$1" d f ext
  for d in /etc/supervisord.d /etc/supervisor/conf.d; do
    for ext in conf ini; do
      f="${d}/${domain}-horizon.${ext}"
      [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
  done
  return 1
}

horizon_supervisor_conf_write_path() {
  local domain="$1"
  if [[ -d /etc/supervisord.d ]]; then
    echo "/etc/supervisord.d/${domain}-horizon.ini"
  elif [[ -d /etc/supervisor/conf.d ]]; then
    echo "/etc/supervisor/conf.d/${domain}-horizon.conf"
  else
    mkdir -p /etc/supervisor/conf.d
    echo "/etc/supervisor/conf.d/${domain}-horizon.conf"
  fi
}

# 与 composer install 相同属主、工作目录在站点根目录（root 跑脚本时避免用绝对路径直开 artisan 与卷内路径不一致）
docker_php_artisan() {
  local domain="$1"
  shift
  local cname; cname="$(_php_container_for_site "$domain")"
  docker exec -u "$(id -u "${DEVOPS_USER}")":"$(id -g "${DEVOPS_USER}")" -w "${CONTAINER_WWW}/${domain}" "$cname" \
    php artisan "$@"
}

ensure_composer_in_lnmp_php() {
  local cname="${1:-lnmp-php}"
  container_ok "$cname" || die "${cname} 容器未运行"
  local php_ver want_major cur_major
  php_ver="$(_php_runtime_ver_in_container "$cname")"; : "${php_ver:=8.3}"
  want_major=2
  _lv_ge "$php_ver" "7.2" || want_major=1
  if docker exec "$cname" sh -c 'command -v composer >/dev/null 2>&1'; then
    # 用 awk 取首次出现的版本主号，避免 grep|grep|head SIGPIPE 与解析失败
    cur_major="$(docker exec "$cname" composer --version 2>/dev/null \
      | awk 'match($0, /version[[:space:]]+[0-9]+/) {s=substr($0,RSTART,RLENGTH); sub(/.*[[:space:]]/,"",s); print s; exit}' \
      || true)"
    [[ -z "$cur_major" || "$cur_major" = "$want_major" ]] && return 0
    info "${cname} 现有 Composer ${cur_major}.x 与 PHP ${php_ver} 期望 ${want_major}.x 不符，重装..."
  else
    info "在 ${cname} 内安装 Composer ${want_major}.x（PHP ${php_ver}）..."
  fi
  # 容器内可能既无 curl 也无 wget；优先 wget（alpine 自带 busybox wget），失败则装 curl
  docker exec -u root "$cname" sh -c \
    "( command -v wget >/dev/null 2>&1 && wget -qO- https://getcomposer.org/installer ) \
     || ( command -v curl >/dev/null 2>&1 && curl -fsSL https://getcomposer.org/installer ) \
     || ( apk add --no-cache curl >/dev/null 2>&1 && curl -fsSL https://getcomposer.org/installer ) \
     | php -- --install-dir=/usr/local/bin --filename=composer --${want_major}" \
    || die "${cname} 内安装 Composer 失败"
  docker exec -u root "$cname" chmod 755 /usr/local/bin/composer 2>/dev/null || true
}

_php_ext_apk_retry_exec() {
  local cname="$1" inner="$2"
  local attempt=1 max=12 pause=5
  sleep 2
  while ((attempt <= max)); do
    if docker exec -u root -e TERM=dumb "$cname" sh -c "$inner"; then
      return 0
    fi
    if ((attempt < max)); then
      warn "apk 锁或失败，${pause}s 后重试 (${attempt}/${max})..."
      sleep "$pause"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

ensure_lnmp_php_laravel_extensions() {
  local cname="${1:-lnmp-php}"
  local db_conn="${2:-mysql}"
  local need_pgsql=0
  container_ok "$cname" || die "${cname} 容器未运行"
  [[ "$(_normalize_db_connection "$db_conn")" = "pgsql" ]] && need_pgsql=1
  local _req='foreach (["bcmath","pcntl","gd","zip","pdo_mysql","redis"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);'
  [[ $need_pgsql -eq 1 ]] && _req='foreach (["bcmath","pcntl","gd","zip","pdo_pgsql","redis"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);'
  if docker exec "$cname" php -r "$_req" 2>/dev/null; then
    return 0
  fi
  info "尝试启用已编译的 PHP 扩展 (${cname} → docker-php-ext-enable)..."
  docker exec -u root "$cname" sh -c \
    'for e in bcmath pcntl zip gd pdo_mysql pdo_pgsql mysqli opcache dom mbstring curl xml intl fileinfo exif sockets redis; do docker-php-ext-enable "$e" 2>/dev/null || true; done'
  if docker exec "$cname" php -r "$_req" 2>/dev/null; then
    ok "PHP 扩展已可用（${cname}）"
    docker restart "$cname"
    wait_container_running "$cname" 45
    return 0
  fi
  info "在 ${cname} 内编译安装扩展（与 init.sh 默认一致，含 pdo_mysql + pecl redis）..."
  [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
  local alpine_sed=""
  [[ -n "${ALPINE_MIRROR:-}" ]] && alpine_sed="sed -i 's|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g' /etc/apk/repositories && apk update && "
  local php_ver gd_args redis_pkg
  php_ver="$(_php_runtime_ver_in_container "$cname")"; : "${php_ver:=8.3}"
  gd_args="--with-freetype --with-jpeg --with-webp"
  _lv_ge "$php_ver" "7.4" || gd_args="--with-freetype-dir=/usr --with-jpeg-dir=/usr --with-png-dir=/usr --with-webp-dir=/usr"
  if   ! _lv_ge "$php_ver" "7.2"; then redis_pkg="redis-4.3.0"
  elif ! _lv_ge "$php_ver" "7.4"; then redis_pkg="redis-5.3.7"
  else redis_pkg=""; fi
  local apk_deps="libpng-dev libwebp-dev freetype-dev libjpeg-turbo-dev libxml2-dev curl-dev build-base linux-headers autoconf libzip-dev icu-dev oniguruma-dev"
  [[ $need_pgsql -eq 1 ]] && apk_deps+=" libpq-dev"
  local install_list="pdo_mysql opcache mysqli curl gd xml dom pcntl bcmath sockets mbstring zip exif fileinfo"
  [[ $need_pgsql -eq 1 ]] && install_list="pdo_pgsql ${install_list}"
  local cmd="${alpine_sed}apk add --no-cache ${apk_deps}"
  cmd+=" && docker-php-ext-configure gd ${gd_args}"
  if _lv_ge "$php_ver" "7.2"; then
    install_list+=" intl"
    cmd+=" && docker-php-ext-configure intl"
  else
    warn "PHP ${php_ver} 镜像下 intl 编译可能因 icu 版本不兼容而失败，自动跳过 intl"
  fi
  cmd+=" && docker-php-ext-install -j\$(nproc) ${install_list}"
  cmd+=" && if ! php -m 2>/dev/null | grep -q '^redis$'; then pecl install ${redis_pkg:-redis} || true; fi"
  cmd+=" && docker-php-ext-enable redis 2>/dev/null || true"
  cmd+=" && apk del --no-cache build-base linux-headers autoconf"
  cmd="sleep 2; ${cmd}"
  _php_ext_apk_retry_exec "$cname" "$cmd" \
    || die "PHP 扩展安装失败，请在主机执行 init.sh「更新配置 → PHP 扩展」或 docker restart ${cname} 后重试"
  docker restart "$cname"
  wait_container_running "$cname" 45
  if [[ $need_pgsql -eq 1 ]]; then
    docker exec "$cname" php -m | grep -q pdo_pgsql || die "pdo_pgsql 仍未加载，请 init.sh install postgres 或更新 PHP 扩展后重试"
    docker exec "$cname" php -r 'foreach (["bcmath","pcntl","gd","zip","pdo_pgsql","redis"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null \
      || die "Laravel (PostgreSQL) 所需扩展仍未齐全，请检查 ${cname}"
  else
    docker exec "$cname" php -m | grep -q pdo_mysql || die "pdo_mysql 仍未加载，请检查 ${cname}"
    docker exec "$cname" php -r 'foreach (["bcmath","pcntl","gd","zip","pdo_mysql","redis"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null \
      || die "Laravel 所需扩展仍未齐全，请检查 ${cname} 或重新部署 PHP 容器"
  fi
  docker exec "$cname" php -m | grep -q '^redis$' || die "redis 扩展仍未加载，请检查 ${cname} 或 pecl"
  ok "PHP 扩展就绪（${cname}）"
}

wait_container_running() {
  local name="$1" max="${2:-45}" i st shown=0
  for ((i = 0; i < max; i++)); do
    st=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null) || st="missing"
    if [[ "$st" = "running" ]] && docker exec "$name" true &>/dev/null; then
      return 0
    fi
    if [[ $shown -eq 0 ]]; then
      info "等待容器 ${name} 就绪（当前: ${st}）..."
      shown=1
    fi
    sleep 2
  done
  die "容器 ${name} 未就绪（最后状态: ${st}）。请检查: docker logs --tail 80 ${name}"
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

fix_nginx_conf_d_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  chmod 644 "$f" 2>/dev/null || true
  chown "${NGINX_C_UID}:${NGINX_C_GID}" "$f" 2>/dev/null || true
}

normalize_nginx_conf_d() {
  mkdir -p "${NGINX_CONF}"
  chmod 755 "${DATA_DIR}/nginx" "${NGINX_CONF}" 2>/dev/null || true
  local f
  shopt -s nullglob
  for f in "${NGINX_CONF}"/*.conf; do
    fix_nginx_conf_d_file "$f"
  done
  shopt -u nullglob
}

fix_nginx_ssl_domain() {
  local domain="$1"
  local d="${SSL_DIR}/${domain}"
  mkdir -p "$d" 2>/dev/null || true
  chmod 755 "${SSL_DIR}" "$d" 2>/dev/null || true
  local f bn
  shopt -s nullglob
  for f in "$d"/*; do
    [[ -f "$f" ]] || continue
    bn="${f##*/}"
    case "$bn" in
      *.key) chmod 640 "$f" 2>/dev/null || true ;;
      *)     chmod 644 "$f" 2>/dev/null || true ;;
    esac
    chown "${NGINX_C_UID}:${NGINX_C_GID}" "$f" 2>/dev/null || true
  done
  shopt -u nullglob
  chown "${NGINX_C_UID}:${NGINX_C_GID}" "$d" 2>/dev/null || true
}

normalize_nginx_ssl_trees() {
  [[ -d "${SSL_DIR}" ]] || return 0
  chmod 755 "${SSL_DIR}" 2>/dev/null || true
  local sub
  shopt -s nullglob
  for sub in "${SSL_DIR}"/*/; do
    [[ -d "$sub" ]] || continue
    fix_nginx_ssl_domain "$(basename "${sub%/}")"
  done
  shopt -u nullglob
}

normalize_nginx_cache_dir() {
  mkdir -p "${DATA_DIR}/nginx/cache"
  chown -R "${NGINX_C_UID}:${NGINX_C_GID}" "${DATA_DIR}/nginx/cache" 2>/dev/null || true
  chmod -R 755 "${DATA_DIR}/nginx/cache" 2>/dev/null || true
}

# PHP-FPM 为 PHP_C_UID:PHP_C_GID（82:82），除 public 外还要能读 app/vendor 等；storage/bootstrap/cache 保持与 setup_laravel 一致的 rwX
fix_laravel_readable_for_web() {
  local base="$1"
  local envf="${base}/.env"
  [[ -d "$base" ]] || { info "  [跳过] fix_laravel_readable_for_web：目录不存在 ${base}"; return 0; }
  info "  执行 fix_laravel_readable_for_web（PHP ${PHP_C_UID} / Nginx ${NGINX_C_UID} 可读、storage 可写、.env）…"
  if [[ -d "${base}/public" ]]; then
    chmod a+rx "${base}/public" 2>/dev/null || true
    chmod -R a+rX "${base}/public" 2>/dev/null || true
  fi
  if command -v setfacl &>/dev/null; then
    setfacl -R  -m "u:${PHP_C_UID}:rX"   "${base}" 2>/dev/null || true
    setfacl -dR -m "u:${PHP_C_UID}:rX"   "${base}" 2>/dev/null || true
    setfacl -R  -m "u:${NGINX_C_UID}:rX" "${base}" 2>/dev/null || true
    setfacl -dR -m "u:${NGINX_C_UID}:rX" "${base}" 2>/dev/null || true
    [[ -f "$envf" ]] && { setfacl -b "$envf" 2>/dev/null || true; chmod 640 "$envf" 2>/dev/null || true; }
    if [[ -d "${base}/storage" ]]; then
      chmod -R 775 "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
      chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
      setfacl -R  -m "u:${PHP_C_UID}:rwX" "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
      setfacl -dR -m "u:${PHP_C_UID}:rwX" "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
    fi
  else
    # 无 setfacl：让 PHP-FPM(82) 直接以属主身份读写，避免使用 chmod 777
    chmod -R a+rX "${base}" 2>/dev/null || true
    [[ -f "$envf" ]] && chmod 640 "$envf" 2>/dev/null || true
    if [[ -d "${base}/storage" ]]; then
      chown -R "${PHP_C_UID}:${PHP_C_GID}" "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
      chmod -R 775 "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
    fi
  fi
  ok "  fix_laravel_readable_for_web 已执行"
}

# 容器内 nginx 为 101:101；前端见上；Laravel 整站需同时满足 php-fpm(82) 可读代码
fix_site_readable_for_nginx() {
  local domain="$1" site_type="$2" fe_sub="${3:-}"
  info "执行 fix_site_readable_for_nginx：${domain}（类型: ${site_type}）…"
  chmod a+rx "${WWW_ROOT}" 2>/dev/null || true
  local base="${WWW_ROOT}/${domain}"
  [[ -d "$base" ]] || { info "  [跳过] 站点目录不存在: ${base}"; return 0; }
  chmod a+rx "$base" 2>/dev/null || true

  if [[ "$site_type" = "laravel" ]]; then
    fix_laravel_readable_for_web "$base"
    ok "fix_site_readable_for_nginx 已执行（Laravel: ${domain}）"
    return 0
  fi

  local docroot="$base"
  if [[ -n "$fe_sub" ]]; then
    docroot="${base}/${fe_sub}"
  fi
  [[ -d "$docroot" ]] || { info "  [跳过] 前端文档根不存在: ${docroot}"; return 0; }
  chmod a+rx "$docroot" 2>/dev/null || true

  if [[ "$site_type" = "frontend" && -z "$fe_sub" && -d "${base}/.git" ]]; then
    find "$docroot" \( -name .git -prune \) -o -type d -exec chmod a+rx {} + 2>/dev/null || true
    find "$docroot" \( -name .git -prune \) -o -type f -exec chmod a+r {} + 2>/dev/null || true
  else
    chmod -R a+rX "$docroot" 2>/dev/null || true
  fi
  ok "fix_site_readable_for_nginx 已执行（前端: ${domain}，文档根: ${docroot}）"
}

fix_nginx_main_pid_path() {
  local f="${DATA_DIR}/nginx/nginx.conf"
  [[ -f "$f" ]] || return 0
  if grep -q '/var/run/nginx\.pid' "$f" 2>/dev/null; then
    sed -i 's|/var/run/nginx.pid|/var/cache/nginx/nginx.pid|g' "$f" 2>/dev/null || true
  fi
}

