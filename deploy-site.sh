#!/bin/bash
set -euo pipefail

VERSION="2.0.0"
CONF_FILE="/etc/lnmp-env.conf"
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
ACME_SSL_DNS_DEFAULT="${ACME_SSL_DNS_DEFAULT:-webroot}"
DATA_DIR="${LNMP_DATA_DIR:-/data/docker-lnmp}"
CONTAINER_WWW="${CONTAINER_WWW:-${DATA_DIR}/www}"
WWW_ROOT="${DATA_DIR}/www"
NGINX_CONF="${DATA_DIR}/nginx/conf.d"
SSL_DIR="${DATA_DIR}/ssl"
# 无 per-site 文件时的全局默认 SSE 前缀（空格分隔）；每站点可写 ${NGINX_CONF}/<域名>.sse-prefixes 覆盖
LARAVEL_SSE_PREFIXES="${LARAVEL_SSE_PREFIXES:-wave}"

mkdir -p "${DATA_DIR}/logs" 2>/dev/null || true
LOG_FILE="${DATA_DIR}/logs/deploy-site.log"
# 用命名管道替代进程替换，避免 set -euo pipefail 下 tee 子进程退出触发意外 exit
_LOG_PIPE="${DATA_DIR}/logs/.deploy-site-$$.pipe"
mkfifo "$_LOG_PIPE" 2>/dev/null || true
if command -v stdbuf &>/dev/null; then
  stdbuf -oL -eL tee -a "$LOG_FILE" < "$_LOG_PIPE" &
else
  tee -a "$LOG_FILE" < "$_LOG_PIPE" &
fi
_TEE_PID=$!
exec > "$_LOG_PIPE" 2>&1
# 脚本退出时清理管道和 tee 进程
trap 'exec >/dev/null 2>&1; rm -f "$_LOG_PIPE"; wait "$_TEE_PID" 2>/dev/null || true' EXIT
echo "===== $(date '+%Y-%m-%d %H:%M:%S') START $0 $* pid=$$ ====="

# 与 docker-compose 中 lnmp-nginx user 101:101 一致
NGINX_C_UID=101
NGINX_C_GID=101

# ═══════════════════════════════════════════════
#  工具函数
# ═══════════════════════════════════════════════
die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
hr()   { echo "══════════════════════════════════════════════"; }

confirm() {
  local msg="${1:-确认？}" default="${2:-y}" ans=""
  local prompt_str="[Y/n]"; [[ "$default" != "y" ]] && prompt_str="[y/N]"
  read -rp "  ${msg} ${prompt_str}: " ans </dev/tty 2>/dev/tty || true
  ans=${ans:-$default}
  [[ "$ans" =~ ^[yY]$ ]]
}

prompt() {
  local msg="$1" default="${2:-}" var=""
  if [[ -n "$default" ]]; then
    read -rp "  ${msg} [${default}]: " var </dev/tty 2>/dev/tty || true
  else
    read -rp "  ${msg}: " var </dev/tty 2>/dev/tty || true
  fi
  echo "${var:-$default}"
}

# printf -v 写入命名变量，避免 stdout 被 tee 记入日志（兼容 bash 3.2）
prompt_secret_into() {
  local msg="$1" _var="$2" val=""
  [[ "$_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "内部错误: 无效变量名"
  read -rsp "  ${msg}: " val </dev/tty; echo >/dev/tty
  printf -v "$_var" '%s' "$val"
}

# 菜单（与 init.sh 同样语义）：所有 UI 输出走 /dev/tty，避免被 tee 落盘
menu_select() {
  local title="$1"; shift
  local -a items=("$@")
  {
    echo ""
    info "$title"
    echo ""
    for i in "${!items[@]}"; do
      printf "    %d) %s\n" $((i + 1)) "${items[$i]}"
    done
    echo ""
    info "回车或无效输入 = 第 1 项（推荐默认）"
    echo ""
  } >/dev/tty
  local choice raw
  read -rp "  选择 [1-${#items[@]}] (回车=第1项): " raw </dev/tty >/dev/tty || raw=""
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    choice=$((raw - 1))
  else
    choice=-1
  fi
  [[ $choice -ge 0 && $choice -lt ${#items[@]} ]] || choice=0
  echo "$choice"
}

env_set() {
  local key="$1" val="$2" envfile="$3"
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
  printf 'lnmp-php-%s' "$(_php_ver_no_dot "$v")"
}

_iter_php_containers() {
  # 默认 lnmp-php 在最前；其余 lnmp-php-XX 按数值升序（避免字符串排序导致 100 < 74）
  docker ps --format '{{.Names}}' 2>/dev/null \
    | awk '
      $0 == "lnmp-php" { has_def = 1; next }
      $0 ~ /^lnmp-php-[0-9]+$/ {
        n = $0; sub(/^lnmp-php-/, "", n); list[++idx] = n + 0; orig[n + 0] = $0
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

# ─── 版本比较：_lv_ge "5.7" "5.6" → 0；只看主.次 ───
_lv_ge() {
  local a="$1" b="$2" a1 a2 b1 b2
  a1="${a%%.*}"; a2="${a#*.}"; [[ "$a2" = "$a" ]] && a2=0
  b1="${b%%.*}"; b2="${b#*.}"; [[ "$b2" = "$b" ]] && b2=0
  a1="${a1//[^0-9]/}"; a2="${a2%%.*}"; a2="${a2//[^0-9]/}"
  b1="${b1//[^0-9]/}"; b2="${b2%%.*}"; b2="${b2//[^0-9]/}"
  : "${a1:=0}"; : "${a2:=0}"; : "${b1:=0}"; : "${b2:=0}"
  if [[ $a1 -ne $b1 ]]; then [[ $a1 -gt $b1 ]]; return $?; fi
  [[ $a2 -ge $b2 ]]
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
  container_ok "$cname" || die "${cname} 容器未运行"
  if docker exec "$cname" php -r 'foreach (["bcmath","pcntl","gd","zip","pdo_mysql","redis"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null; then
    return 0
  fi
  info "尝试启用已编译的 PHP 扩展 (${cname} → docker-php-ext-enable)..."
  docker exec -u root "$cname" sh -c \
    'for e in bcmath pcntl zip gd pdo_mysql mysqli opcache dom mbstring curl xml intl fileinfo exif sockets redis; do docker-php-ext-enable "$e" 2>/dev/null || true; done'
  if docker exec "$cname" php -r 'foreach (["bcmath","pcntl","gd","zip","pdo_mysql","redis"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null; then
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
  local install_list="pdo_mysql opcache mysqli curl gd xml dom pcntl bcmath sockets mbstring zip exif fileinfo"
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
  docker exec "$cname" php -m | grep -q pdo_mysql || die "pdo_mysql 仍未加载，请检查 ${cname}"
  docker exec "$cname" php -m | grep -q '^redis$' || die "redis 扩展仍未加载，请检查 ${cname} 或 pecl"
  docker exec "$cname" php -r 'foreach (["bcmath","pcntl","gd","zip","pdo_mysql","redis"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null \
    || die "Laravel 所需扩展仍未齐全，请检查 ${cname} 或重新部署 PHP 容器"
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

# PHP-FPM 为 82:82，除 public 外还要能读 app/vendor 等；storage/bootstrap/cache 保持与 setup_laravel 一致的 rwX
fix_laravel_readable_for_web() {
  local base="$1"
  local envf="${base}/.env"
  [[ -d "$base" ]] || { info "  [跳过] fix_laravel_readable_for_web：目录不存在 ${base}"; return 0; }
  info "  执行 fix_laravel_readable_for_web（PHP 82 / Nginx 101 可读、storage 可写、.env）…"
  if [[ -d "${base}/public" ]]; then
    chmod a+rx "${base}/public" 2>/dev/null || true
    chmod -R a+rX "${base}/public" 2>/dev/null || true
  fi
  if command -v setfacl &>/dev/null; then
    setfacl -R  -m u:82:rX  "${base}" 2>/dev/null || true
    setfacl -dR -m u:82:rX  "${base}" 2>/dev/null || true
    setfacl -R  -m u:101:rX "${base}" 2>/dev/null || true
    setfacl -dR -m u:101:rX "${base}" 2>/dev/null || true
    [[ -f "$envf" ]] && { setfacl -b "$envf" 2>/dev/null || true; chmod 640 "$envf" 2>/dev/null || true; }
    if [[ -d "${base}/storage" ]]; then
      chmod -R 775 "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
      chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
      setfacl -R  -m u:82:rwX "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
      setfacl -dR -m u:82:rwX "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
    fi
  else
    chmod -R a+rX "${base}" 2>/dev/null || true
    [[ -f "$envf" ]] && chmod 640 "$envf" 2>/dev/null || true
    chmod -R 775 "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
    chmod -R 777 "${base}/storage" "${base}/bootstrap/cache" 2>/dev/null || true
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

# ═══════════════════════════════════════════════
#  权限与环境检查
# ═══════════════════════════════════════════════
[[ "$(id -u)" -ne 0 ]] && die "请用 root 执行"

DEVOPS_USER=${DEVOPS_USER:-devops}
id "${DEVOPS_USER}" &>/dev/null || die "用户 ${DEVOPS_USER} 不存在，请先运行 init.sh"

# ═══════════════════════════════════════════════
#  Nginx 配置生成
# ═══════════════════════════════════════════════
_laravel_sse_prefixes_resolve() {
  local domain="$1"
  local f="${NGINX_CONF}/${domain}.sse-prefixes"
  local line acc=""
  if [[ -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      acc+="${line}"$'\n'
    done < "$f"
    [[ -n "$acc" ]] && printf '%s' "$acc" && return
  fi
  printf '%s' "${LARAVEL_SSE_PREFIXES:-wave}"
}

# 将 Laravel 风格路径 /a/{b}/c 转为 nginx 正则 ^/a/[^/]+/c$（每一段 {name} → [^/]+）
_laravel_sse_escape_static_for_nginx_re() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      .|\^|\$|\*|\+|\?|\(|\)|\{|\}|\||\[|\]|\\) out+="\\${c}" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

_laravel_sse_brace_path_to_nginx_regex() {
  local s="$1" out="" post inner
  [[ "$s" == /* ]] || s="/$s"
  s="${s#/}"
  while [[ "$s" == *'{'* ]]; do
    [[ "$s" == *'{'*'}'* ]] || return 1
    post="${s#*\{}"
    inner="${post%%\}*}"
    [[ -n "$inner" ]] || return 1
    [[ "$inner" == *'{'* ]] && return 1
    post="${post#"$inner"\}}"
    out+="$(_laravel_sse_escape_static_for_nginx_re "${s%%\{*}")"
    out+='[^/]+'
    s="$post"
  done
  out+="$(_laravel_sse_escape_static_for_nginx_re "$s")"
  printf '^/%s$' "$out"
}

apply_site_php_version_cli() {
  local domain="$1"
  [[ "${SITE_PHP_VERSION_CLI:-0}" -ne 1 ]] && return 0
  mkdir -p "${NGINX_CONF}"
  local f; f="$(site_php_version_file "$domain")"
  local v="${SITE_PHP_VERSION// /}"
  if [[ -z "$v" || "$v" = "-" ]]; then
    rm -f "$f" 2>/dev/null || true
    info "站点 ${domain} PHP 版本：清除 → 走默认 lnmp-php"
    return 0
  fi
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] || die "无效 --php-version: $v（应为 8.2 / 7.4）"
  # 与 /etc/lnmp-env.conf 中 PHP_VERSION（默认 lnmp-php 容器）相同时短路：避免去找 lnmp-php-XX
  local _default_ver; _default_ver="$(_default_php_ver)"
  if [[ -n "$_default_ver" && "$v" = "$_default_ver" ]]; then
    rm -f "$f" 2>/dev/null || true
    container_ok "lnmp-php" || die "默认 lnmp-php 未运行"
    info "站点 ${domain} PHP 版本：${v}（=默认）→ 使用 lnmp-php"
    return 0
  fi
  local cname="lnmp-php-$(_php_ver_no_dot "$v")"
  container_ok "$cname" || die "未发现容器 ${cname}；请先在 init.sh「更新配置 → PHP 版本（额外，多版本共存）」加入 ${v} 并重建"
  printf '%s\n' "$v" > "$f"
  chmod 644 "$f" 2>/dev/null || true
  info "站点 ${domain} PHP 版本：${v} → ${cname}"
}

ensure_site_php_container() {
  local domain="$1" v cname
  v="$(_php_ver_for_site "$domain")"
  cname="$(_php_container_for_site "$domain")"
  if container_ok "$cname"; then return 0; fi
  if [[ -z "$v" ]]; then
    die "${cname} 未运行；请先执行 init.sh 部署 LNMP"
  fi
  # 站点声明的版本若与默认版本一致（历史遗留 .php-version 文件），自动清理回退默认
  local _default_ver; _default_ver="$(_default_php_ver)"
  if [[ -n "$_default_ver" && "$v" = "$_default_ver" ]]; then
    warn "站点 ${domain} 声明 PHP ${v} = 当前默认；清理 .php-version 改用 lnmp-php"
    rm -f "$(site_php_version_file "$domain")" 2>/dev/null || true
    container_ok "lnmp-php" || die "lnmp-php 未运行"
    return 0
  fi
  die "站点 ${domain} 声明 PHP ${v} 但容器 ${cname} 未运行；请检查 init.sh EXTRA_PHP_VERSIONS 与 docker compose"
}

apply_site_sse_prefixes_cli() {
  local domain="$1"
  [[ "${SITE_SSE_PREFIXES_CLI:-0}" -ne 1 ]] && return 0
  mkdir -p "${NGINX_CONF}"
  local f="${NGINX_CONF}/${domain}.sse-prefixes"
  if [[ -n "${SITE_SSE_PREFIXES}" ]]; then
    local norm
    norm=$(printf '%s' "$SITE_SSE_PREFIXES" | tr ',' ' ' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    printf '%s\n' "$norm" > "$f"
    fix_nginx_conf_d_file "$f"
  else
    rm -f "$f"
  fi
}

# update：展示当前 SSE 规则并可选修改（未传 --sse-prefixes 且 stdin 为 TTY 且未 --yes 时）
interactive_sse_prefixes_maybe_for_update() {
  local domain="$1"
  [[ -t 0 ]] || return 0
  [[ "${YES:-0}" -eq 1 ]] && return 0
  [[ "${SITE_SSE_PREFIXES_CLI:-0}" -eq 1 ]] && return 0

  local f="${NGINX_CONF}/${domain}.sse-prefixes"
  local cur_resolved cur_one src
  if [[ -f "$f" ]]; then
    src="站点文件"
  else
    src="全局 LARAVEL_SSE_PREFIXES"
  fi
  cur_resolved=$(_laravel_sse_prefixes_resolve "$domain")
  cur_one=$(printf '%s' "$cur_resolved" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo ""
  info "SSE（fastcgi → php:9001） 来源:${src}  当前规则: ${cur_one:-<空>}"

  if ! confirm "修改 SSE 路径规则？" "n"; then
    return 0
  fi

  local newv
  newv=$(prompt "新规则（空格/逗号分隔；- 表示删站点文件、改用全局）" "$cur_one")
  if [[ "$newv" == "-" ]]; then
    SITE_SSE_PREFIXES=""
    SITE_SSE_PREFIXES_CLI=1
    info "将删除站点专属 .sse-prefixes，改用全局默认"
  elif [[ "$newv" == "$cur_one" ]]; then
    info "与当前相同，跳过写入"
  else
    SITE_SSE_PREFIXES="$newv"
    SITE_SSE_PREFIXES_CLI=1
  fi
}

_nginx_laravel_sse_location_blocks() {
  local out="" _p raw _seen=" "
  local _svc="${2:-php}"

  _laravel_sse_append_upstream_block() {
    local _hdr="$1"
    out+="${_hdr}"$'\n'
    # 须用单引号且勿写 \$document_root：否则会把反斜杠写入 conf，SCRIPT_FILENAME 错误
    out+='        gzip                 off;
        include              fastcgi_params;
        fastcgi_pass         '"${_svc}"':9001;
        fastcgi_index        index.php;
        fastcgi_param        SCRIPT_FILENAME $document_root/index.php;
        fastcgi_param        DOCUMENT_ROOT $document_root;
        fastcgi_param        REQUEST_URI $request_uri;
        fastcgi_param        QUERY_STRING $query_string;
        fastcgi_buffering    off;
        fastcgi_read_timeout 86400s;
        fastcgi_send_timeout 86400s;
        fastcgi_buffer_size  32k;
        fastcgi_buffers      8 16k;
    }

'$'\n'
  }

  _laravel_sse_handle_one_pattern() {
    local _tok="$1"
    _tok="${_tok#"${_tok%%[![:space:]]*}"}"
    _tok="${_tok%"${_tok##*[![:space:]]}"}"
    [[ -z "$_tok" ]] && return 0
    case "${_seen}" in *"|${_tok}|"*) return 0 ;; esac
    _seen+="|${_tok}| "

    if [[ "$_tok" =~ ^~\*(.+)$ ]]; then
      _laravel_sse_append_upstream_block "    location ~* ${BASH_REMATCH[1]} {"
    elif [[ "$_tok" =~ ^~(.+)$ ]]; then
      _laravel_sse_append_upstream_block "    location ~ ${BASH_REMATCH[1]} {"
    elif [[ "$_tok" == *'{'*'}'* ]]; then
      local _rx _hdr
      _tok="${_tok#/}"
      [[ "$_tok" == /* ]] || _tok="/$_tok"
      if _rx=$(_laravel_sse_brace_path_to_nginx_regex "$_tok") 2>/dev/null; then
        printf -v _hdr '    location ~ %s {' "$_rx"
        _laravel_sse_append_upstream_block "$_hdr"
      fi
    else
      _tok="${_tok#/}"
      _tok="${_tok%/}"
      [[ -z "$_tok" || "$_tok" == '~' ]] && return 0
      _laravel_sse_append_upstream_block "    location ^~ /${_tok} {"
    fi
  }

  raw="${1:-}"
  [[ -z "$raw" ]] && raw="${LARAVEL_SSE_PREFIXES:-wave}"
  # 每行可多条（空格/逗号）；禁止用「是否含换行」分支：单行文件末尾也有 \n，会把整行当一条 token 导致 {param} 路径未拆开
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    read -ra parts <<< "$(printf '%s' "$line" | tr ',' ' ')"
    for _p in "${parts[@]}"; do
      _laravel_sse_handle_one_pattern "$_p"
    done
  done < <(printf '%s\n' "$raw")

  printf '%s' "$out"
}

gen_nginx_laravel() {
  local domain="$1"
  local svc; svc="$(_php_service_for_site "$domain")"
  cat > "${NGINX_CONF}/${domain}.conf" <<NGINX
server {
    listen 80;
    server_name ${domain};
    if (\$host != "${domain}") { return 444; }
    root ${CONTAINER_WWW}/${domain}/public;

    location ^~ /.well-known/acme-challenge/ {
        root ${CONTAINER_WWW}/${domain}/public;
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${domain};
    if (\$host != "${domain}") { return 444; }
    root ${CONTAINER_WWW}/${domain}/public;
    index index.php;

    ssl_certificate     /etc/nginx/ssl/${domain}/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/${domain}/${domain}.key;

    add_header X-Frame-Options            "SAMEORIGIN"                        always;
    add_header X-Content-Type-Options     "nosniff"                           always;
    add_header X-XSS-Protection           "1; mode=block"                    always;
    add_header Referrer-Policy            "strict-origin-when-cross-origin"  always;

    location ^~ /.well-known/acme-challenge/ {
        root ${CONTAINER_WWW}/${domain}/public;
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

$(_nginx_laravel_sse_location_blocks "$(_laravel_sse_prefixes_resolve "$domain")" "$svc")
    location ~ \.php\$ {
        include              fastcgi_params;
        fastcgi_pass         ${svc}:9000;
        fastcgi_index        index.php;
        fastcgi_param        SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param        REQUEST_URI \$request_uri;
        fastcgi_param        QUERY_STRING \$query_string;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size  32k;
        fastcgi_buffers      8 16k;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location ~ /\.(?!well-known) { deny all; }
}
NGINX
  fix_nginx_conf_d_file "${NGINX_CONF}/${domain}.conf"
}

gen_nginx_frontend() {
  local domain="$1" sub="$2"
  local root_path="${CONTAINER_WWW}/${domain}"
  [[ -n "$sub" ]] && root_path="${CONTAINER_WWW}/${domain}/${sub}"

  cat > "${NGINX_CONF}/${domain}.conf" <<NGINX
server {
    listen 80;
    server_name ${domain};
    if (\$host != "${domain}") { return 444; }
    root ${root_path};

    location ^~ /.well-known/acme-challenge/ {
        root ${CONTAINER_WWW}/${domain};
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${domain};
    if (\$host != "${domain}") { return 444; }
    root ${root_path};
    index index.html;

    ssl_certificate     /etc/nginx/ssl/${domain}/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/${domain}/${domain}.key;

    add_header X-Frame-Options            "SAMEORIGIN"                        always;
    add_header X-Content-Type-Options     "nosniff"                           always;
    add_header X-XSS-Protection           "1; mode=block"                    always;
    add_header Referrer-Policy            "strict-origin-when-cross-origin"  always;

    location ^~ /.well-known/acme-challenge/ {
        root ${CONTAINER_WWW}/${domain};
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }

    # HEAD / 或同源检查更新：依赖静态文件的 Last-Modified / ETag；CDN 勿对 HTML 长缓存以免边缘 ETag 长期不变
    etag on;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location = /index.html {
        add_header Cache-Control "no-cache";
    }

    location ~* \.(js|css|woff2?|png|jpg|jpeg|gif|ico|svg|woff|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location ~ /\.(?!well-known) { deny all; }
}
NGINX
  fix_nginx_conf_d_file "${NGINX_CONF}/${domain}.conf"
}

# 前端静态根相对 ${WWW_ROOT}/<domain>：按「index.html 所在目录」推断，避免仅有空 dist/ 时 root 指错导致 /js/* 全 404
effective_frontend_subdir() {
  local domain="$1"
  local site="${WWW_ROOT}/${domain}"
  local fe="${FRONTEND_ROOT:-}"
  [[ "$fe" = "." ]] && fe=""
  if [[ -n "$fe" ]]; then
    printf '%s\n' "$fe"
    return
  fi
  local d
  for d in dist .output/public build output; do
    [[ -f "${site}/${d}/index.html" ]] || continue
    printf '%s\n' "$d"
    return
  done
  if [[ -f "${site}/index.html" ]]; then
    printf '%s\n' ""
    return
  fi
  if [[ -d "${site}/dist" ]]; then
    printf '%s\n' "dist"
    return
  fi
  printf '%s\n' ""
}

# ═══════════════════════════════════════════════
#  SSL 证书管理
# ═══════════════════════════════════════════════
ensure_placeholder_cert() {
  local domain="$1"
  mkdir -p "${SSL_DIR}/${domain}"
  if [[ ! -f "${SSL_DIR}/${domain}/fullchain.cer" ]]; then
    openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
      -keyout "${SSL_DIR}/${domain}/${domain}.key" \
      -out    "${SSL_DIR}/${domain}/fullchain.cer" \
      -subj   "/CN=placeholder" 2>/dev/null
  fi
  fix_nginx_ssl_domain "$domain"
}

_is_dns_mode() {
  case "$1" in dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) return 0 ;; *) return 1 ;; esac
}

_acme_ssl_validate_dns_creds() {
  local m="$1"
  case "$m" in
    dns_cf)      [[ -n "${CF_TOKEN:-}" ]] || die "dns_cf 需要 Cloudflare API Token（--cf-token 或交互）" ;;
    dns_ali)     [[ -n "${ALI_KEY:-}" && -n "${ALI_SECRET:-}" ]] || die "dns_ali 需要 Ali_Key / Ali_Secret（--ali-key / --ali-secret）" ;;
    dns_dp)      [[ -n "${DP_ID:-}" && -n "${DP_KEY:-}" ]] || die "dns_dp 需要 DNSPod API（--dp-id / --dp-key）" ;;
    dns_gd)      [[ -n "${GD_KEY:-}" && -n "${GD_SECRET:-}" ]] || die "dns_gd 需要 GoDaddy API（--gd-key / --gd-secret）" ;;
    dns_aws)     [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "dns_aws 需要 AWS 密钥（--aws-access-key / --aws-secret-key）" ;;
    dns_tencent) [[ -n "${TENCENT_SECRET_ID:-}" && -n "${TENCENT_SECRET_KEY:-}" ]] || die "dns_tencent 需要腾讯云密钥（--tencent-secret-id / --tencent-secret-key）" ;;
    *)           die "未知 DNS 模式: $m（支持 webroot / dns_cf / dns_ali / dns_dp / dns_gd / dns_aws / dns_tencent）" ;;
  esac
}

_collect_ssl_dns_creds_interactive() {
  case "${SSL_DNS}" in
    dns_cf)
      if [[ -z "${CF_TOKEN:-}" ]]; then
        prompt_secret_into "Cloudflare API Token" CF_TOKEN
      fi
      ;;
    dns_ali)
      if [[ -z "${ALI_KEY:-}" ]]; then
        ALI_KEY=$(prompt "阿里云 DNS AccessKey Id (Ali_Key)")
      fi
      if [[ -z "${ALI_SECRET:-}" ]]; then
        prompt_secret_into "阿里云 DNS AccessKey Secret (Ali_Secret)" ALI_SECRET
      fi
      ;;
    dns_dp)
      if [[ -z "${DP_ID:-}" ]]; then
        DP_ID=$(prompt "DNSPod API ID (DP_Id)")
      fi
      if [[ -z "${DP_KEY:-}" ]]; then
        prompt_secret_into "DNSPod API Token (DP_Key)" DP_KEY
      fi
      ;;
    dns_gd)
      if [[ -z "${GD_KEY:-}" ]]; then
        GD_KEY=$(prompt "GoDaddy API Key (GD_Key)")
      fi
      if [[ -z "${GD_SECRET:-}" ]]; then
        prompt_secret_into "GoDaddy API Secret (GD_Secret)" GD_SECRET
      fi
      ;;
    dns_aws)
      if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        AWS_ACCESS_KEY_ID=$(prompt "AWS Access Key ID")
      fi
      if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        prompt_secret_into "AWS Secret Access Key" AWS_SECRET_ACCESS_KEY
      fi
      ;;
    dns_tencent)
      if [[ -z "${TENCENT_SECRET_ID:-}" ]]; then
        TENCENT_SECRET_ID=$(prompt "腾讯云 SecretId")
      fi
      if [[ -z "${TENCENT_SECRET_KEY:-}" ]]; then
        prompt_secret_into "腾讯云 SecretKey" TENCENT_SECRET_KEY
      fi
      ;;
  esac
}

issue_ssl() {
  local domain="$1" site_type="$2" ssl_dns="$3" force="${4:-}" frontend_root="${5:-dist}"

  mkdir -p "${SSL_DIR}/${domain}"

  local acme_ca="letsencrypt"
  if [[ "${SSL_STAGING:-0}" = "1" ]]; then
    acme_ca="letsencrypt_test"
    warn "使用 Let's Encrypt 测试 CA（浏览器不信任），仅用于调试或规避正式环境限流"
  fi

  local acme_exit=0
  if _is_dns_mode "$ssl_dns"; then
    _acme_ssl_validate_dns_creds "$ssl_dns"
    local dns_env_args=()
    case "$ssl_dns" in
      dns_cf)      dns_env_args=(-e "CF_Token=${CF_TOKEN}") ;;
      dns_ali)     dns_env_args=(-e "Ali_Key=${ALI_KEY}" -e "Ali_Secret=${ALI_SECRET}") ;;
      dns_dp)      dns_env_args=(-e "DP_Id=${DP_ID}" -e "DP_Key=${DP_KEY}") ;;
      dns_gd)      dns_env_args=(-e "GD_Key=${GD_KEY}" -e "GD_Secret=${GD_SECRET}") ;;
      dns_aws)     dns_env_args=(-e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}") ;;
      dns_tencent) dns_env_args=(-e "Tencent_SecretId=${TENCENT_SECRET_ID}" -e "Tencent_SecretKey=${TENCENT_SECRET_KEY}") ;;
    esac
    docker exec "${dns_env_args[@]}" lnmp-acme \
      acme.sh --issue -d "${domain}" \
      --config-home /acme.sh \
      --dns "$ssl_dns" --keylength ec-256 --server "${acme_ca}" \
      ${force} || acme_exit=$?
  else
    local wk_inner
    if [[ "$site_type" = "laravel" ]]; then
      wk_inner="/www/${domain}/public"
      mkdir -p "${WWW_ROOT}/${domain}/public/.well-known/acme-challenge"
    else
      wk_inner="/www/${domain}"
      mkdir -p "${WWW_ROOT}/${domain}/.well-known/acme-challenge"
    fi
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${domain}/.well-known" 2>/dev/null || true
    chmod -R 755 "${WWW_ROOT}/${domain}/.well-known" 2>/dev/null || true

    docker exec lnmp-acme \
      acme.sh --issue -d "${domain}" \
      --config-home /acme.sh \
      --webroot "${wk_inner}" --keylength ec-256 --server "${acme_ca}" \
      ${force} || acme_exit=$?
  fi

  if [[ $acme_exit -ne 0 && $acme_exit -ne 2 ]]; then
    die "SSL 签发失败 (exit=${acme_exit})。Let's Encrypt 对同一域名 7 天内正式证书约 5 张上限；遇 429 请等到日志中 retry after 之后再试，或临时加 --ssl-staging 使用测试 CA。https://letsencrypt.org/docs/rate-limits/"
  fi
  if [[ $acme_exit -eq 2 ]]; then
    info "证书已存在且未过期，跳过签发 (使用 --force-ssl 强制)"
  fi

  if ! docker exec lnmp-acme \
    acme.sh --install-cert -d "${domain}" \
    --config-home /acme.sh \
    --server "${acme_ca}" \
    --ecc \
    --key-file       "/acme.sh/${domain}/${domain}.key" \
    --fullchain-file "/acme.sh/${domain}/fullchain.cer" \
    --reloadcmd "true"; then
    die "acme.sh --install-cert 失败。排查: docker exec lnmp-acme acme.sh --list --config-home /acme.sh"
  fi

  fix_nginx_ssl_domain "$domain"

  wait_container_running "lnmp-nginx" 30
  if ! docker exec lnmp-nginx nginx -s reload; then
    die "nginx reload 失败（请检查证书路径与权限）"
  fi
  ok "SSL 证书已安装"
}

# ═══════════════════════════════════════════════
#  Git 操作
# ═══════════════════════════════════════════════
_build_git_ssh_cmd() {
  local ssh_key="/home/${DEVOPS_USER}/.ssh/id_ed25519"
  [[ ! -f "$ssh_key" ]] && ssh_key="/home/${DEVOPS_USER}/.ssh/id_rsa"
  local cmd="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  [[ -f "$ssh_key" ]] && cmd="ssh -i ${ssh_key} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  printf '%s' "$cmd"
}

_git_pull_or_clone() {
  local site_dir="$1" git_repo="${2:-}" git_branch="${3:-}"
  local git_ssh
  git_ssh=$(_build_git_ssh_cmd)
  git config --global --replace-all safe.directory "${site_dir}" 2>/dev/null || true
  export GIT_SSH_COMMAND="$git_ssh"

  if [[ -d "${site_dir}/.git" ]]; then
    if [[ -n "$git_branch" ]]; then
      info "已有仓库，切换到分支 ${git_branch} 并拉取"
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; cd '${site_dir}' && git fetch origin && git checkout '${git_branch}' && git pull" \
        || die "git fetch/checkout/pull 失败，请检查分支名与 SSH Key"
    else
      info "已有仓库，执行 git pull"
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; cd '${site_dir}' && git pull" \
        || die "git pull 失败，请检查 SSH Key"
    fi
  elif [[ -n "$git_repo" ]]; then
    if [[ -n "$git_branch" ]]; then
      info "首次 clone（分支: ${git_branch}）..."
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; git clone -b '${git_branch}' --single-branch '${git_repo}' '${site_dir}'" \
        || die "git clone 失败，请检查分支名与 SSH Key"
    else
      info "首次 clone..."
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; git clone '${git_repo}' '${site_dir}'" \
        || die "git clone 失败，请检查 SSH Key"
    fi
  else
    return 1
  fi
}

deploy_code() {
  local domain="$1" git_repo="$2" git_branch="${3:-}"
  local site_dir="${WWW_ROOT}/${domain}"

  chmod 755 /data 2>/dev/null || true
  local _dg
  _dg=$(id -gn "${DEVOPS_USER}" 2>/dev/null || echo "${DEVOPS_USER}")
  chown root:"${_dg}" "${DATA_DIR}" 2>/dev/null || true
  chmod 771 "${DATA_DIR}"
  mkdir -p "${WWW_ROOT}"
  chown "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}"
  chmod a+rx "${WWW_ROOT}" 2>/dev/null || true

  if [[ -z "$git_repo" ]]; then
    mkdir -p "${site_dir}"
    info "Git 地址为空，已跳过 clone/pull；请确保代码已在 ${site_dir}"
  else
    _git_pull_or_clone "${site_dir}" "${git_repo}" "${git_branch}"
  fi

  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}"
  local _dc_st="laravel" _dc_fe=""
  [[ -f "${site_dir}/artisan" ]] || _dc_st="frontend"
  [[ "$_dc_st" = "frontend" ]] && _dc_fe=$(effective_frontend_subdir "$domain")
  fix_site_readable_for_nginx "$domain" "$_dc_st" "$_dc_fe"
}

# ═══════════════════════════════════════════════
#  Laravel 配置
# ═══════════════════════════════════════════════
setup_laravel() {
  local domain="$1"
  local site_dir="${WWW_ROOT}/${domain}"
  local envfile="${site_dir}/.env"

  if [[ ! -f "$envfile" ]]; then
    [[ -f "${site_dir}/.env.example" ]] || die ".env.example 不存在"
    su - "${DEVOPS_USER}" -c "cp '${site_dir}/.env.example' '${envfile}'"
  fi

  local queue_conn="redis"
  if ! container_ok "lnmp-redis"; then
    queue_conn="sync"
    warn "lnmp-redis 未运行，队列使用 sync"
  fi

  local lv; lv="$(_laravel_min_for_site "$domain")"

  env_set "APP_NAME"         "${APP_NAME}"     "$envfile"
  env_set "APP_ENV"          "production"       "$envfile"
  env_set "APP_DEBUG"        "false"            "$envfile"
  env_set "APP_URL"          "https://${domain}" "$envfile"
  env_set "REDIS_HOST"       "${REDIS_HOST}"    "$envfile"
  env_set "REDIS_PORT"       "${REDIS_PORT}"    "$envfile"
  env_set "REDIS_PASSWORD"   "${REDIS_PASSWORD}" "$envfile"
  env_set "QUEUE_CONNECTION" "${queue_conn}"    "$envfile"
  env_set "SESSION_DRIVER"   "redis"            "$envfile"
  if [[ -n "$lv" ]] && _lv_ge "$lv" "10"; then
    env_set "CACHE_STORE"    "redis"            "$envfile"
  else
    env_set "CACHE_DRIVER"   "redis"            "$envfile"
  fi
  if [[ -n "$lv" ]] && ! _lv_ge "$lv" "6"; then
    env_set "REDIS_CLIENT"   "predis"           "$envfile"
  else
    env_set "REDIS_CLIENT"   "phpredis"         "$envfile"
  fi
  env_set "LOG_CHANNEL"      "daily"            "$envfile"
  env_set "LOG_LEVEL"        "warning"          "$envfile"

  if [[ "${NEED_DB:-y}" = "y" ]]; then
    env_set "DB_CONNECTION" "mysql"      "$envfile"
    env_set "DB_HOST"       "${DB_HOST}" "$envfile"
    env_set "DB_PORT"       "3306"       "$envfile"
    env_set "DB_DATABASE"   "${DB_NAME}" "$envfile"
    env_set "DB_USERNAME"   "root"       "$envfile"
    env_set "DB_PASSWORD"   "${DB_PWD}"  "$envfile"
  fi

  for kv in "${CUSTOM_ENV[@]}"; do
    local k="${kv%%=*}" v="${kv#*=}"
    env_set "$k" "$v" "$envfile"
  done

  chown "${DEVOPS_USER}:${DEVOPS_USER}" "$envfile"
  chmod 640 "$envfile"

  [[ -f "${site_dir}/artisan" ]] || die "未找到 ${site_dir}/artisan，请确认仓库为 Laravel 且 Git 已拉取成功"

  # Laravel 5.x 部分仓库未提交 storage 子目录的 .gitkeep，提前补齐避免 view/session/cache 写入失败
  local _s
  for _s in sessions views cache testing; do
    mkdir -p "${site_dir}/storage/framework/${_s}"
  done
  mkdir -p "${site_dir}/storage/logs" "${site_dir}/storage/app/public" "${site_dir}/bootstrap/cache"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}/storage" "${site_dir}/bootstrap/cache"

  info "composer install..."
  local uid gid
  uid=$(id -u "${DEVOPS_USER}")
  gid=$(id -g "${DEVOPS_USER}")

  local cname; cname="$(_php_container_for_site "$domain")"
  ensure_lnmp_php_laravel_extensions "$cname"
  ensure_composer_in_lnmp_php "$cname"
  docker exec -u "${uid}:${gid}" -e COMPOSER_CACHE_DIR=/tmp/composer-cache "$cname" \
    composer install \
    --working-dir="${CONTAINER_WWW}/${domain}" \
    --no-dev --no-interaction --optimize-autoloader --no-progress --prefer-dist

  chmod -R 775 "${site_dir}/storage" "${site_dir}/bootstrap/cache"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}/storage" "${site_dir}/bootstrap/cache"
  if command -v setfacl &>/dev/null; then
    setfacl -R  -m u:82:rwX "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    setfacl -dR -m u:82:rwX "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
  else
    chmod -R 777 "${site_dir}/storage" "${site_dir}/bootstrap/cache"
  fi

  info "artisan key:generate..."
  docker_php_artisan "$domain" key:generate --force

  info "artisan storage:link..."
  docker_php_artisan "$domain" storage:link --force 2>/dev/null \
    || docker_php_artisan "$domain" storage:link 2>/dev/null || true

  if _lv_supports_optimize "$lv"; then
    info "artisan optimize..."
    docker_php_artisan "$domain" optimize || warn "artisan optimize 失败（已忽略，请检查 .env / 数据库）"
  else
    info "跳过 artisan optimize（Laravel ${lv:-未知} < 5.7 不支持，仅做 config:cache + route:cache 兼容尝试）"
    docker_php_artisan "$domain" config:cache 2>/dev/null || true
    docker_php_artisan "$domain" route:cache 2>/dev/null || true
  fi

  # 通过全局变量返回，避免调用方用 $() 捕获时吞掉所有 info/ok/warn 输出
  _QUEUE_CONN="$queue_conn"
}

create_database() {
  local db_name="$1" db_pwd="$2" db_host="${3:-mysql}"
  if [[ "$db_host" = "mysql" ]] && container_ok "lnmp-mysql"; then
    docker exec lnmp-mysql mysql -uroot -p"${db_pwd}" \
      -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null \
      && ok "数据库 ${db_name} 已就绪" \
      || warn "建库命令返回错误（可能已存在或密码错误）"
  else
    warn "lnmp-mysql 未运行，跳过建库"
  fi
}

run_migrations() {
  local domain="$1"
  info "artisan migrate..."
  docker_php_artisan "$domain" migrate --force
}

run_seed() {
  local domain="$1"
  info "artisan db:seed..."
  docker_php_artisan "$domain" db:seed --force
}

setup_crontab() {
  local domain="$1"
  local uid gid cron_log cname
  uid=$(id -u "${DEVOPS_USER}")
  gid=$(id -g "${DEVOPS_USER}")
  cname="$(_php_container_for_site "$domain")"
  cron_log="${WWW_ROOT}/${domain}/storage/logs/cron.log"
  local cron_cmd="* * * * * docker exec -u ${uid}:${gid} -w \"${CONTAINER_WWW}/${domain}\" ${cname} php artisan schedule:run >> ${cron_log} 2>&1"
  local existing filtered dom_esc
  dom_esc="${domain//./\\.}"
  existing=$(crontab -u "${DEVOPS_USER}" -l 2>/dev/null || true)
  filtered=$(printf '%s\n' "$existing" | grep -vF "${cron_log}" || true)
  filtered=$(printf '%s\n' "$filtered" | grep -vE "docker exec (-u [^ ]+ )?(-w \"[^\"]+\" )?lnmp-php(-[0-9]+)? php artisan schedule:run.*${dom_esc}(\b|$)" || true)
  filtered=$(printf '%s\n' "$filtered" | grep -vE "docker exec lnmp-php(-[0-9]+)? php [^[:space:]]*/${dom_esc}/artisan schedule:run" || true)
  { printf '%s\n' "$filtered" | grep -v '^$' || true; echo "$cron_cmd"; } | crontab -u "${DEVOPS_USER}" -
  ok "schedule:run crontab 已更新（${cname}）"
}

setup_horizon() {
  local domain="$1"
  local _hlv _hphp
  _hlv="$(_laravel_min_for_site "$domain")"
  _hphp="$(_php_ver_resolved_for_site "$domain")"
  if ! _lv_supports_horizon "$_hlv" "$_hphp"; then
    warn "Horizon 跳过：要求 Laravel ≥ 5.7.7（当前 ${_hlv:-未知}）+ PHP ≥ 7.2（当前 ${_hphp}）；老站请改用 supervisor + queue:work"
    return 0
  fi
  local sup_path
  if ! sup_path=$(horizon_supervisor_conf_path "$domain"); then
    sup_path=$(horizon_supervisor_conf_write_path "$domain")
  fi
  mkdir -p "$(dirname "$sup_path")"

  local _hu _hg _hc
  _hu=$(id -u "${DEVOPS_USER}")
  _hg=$(id -g "${DEVOPS_USER}")
  _hc="$(_php_container_for_site "$domain")"
  cat > "$sup_path" <<HORIZON
[program:laravel-horizon-${domain}]
command=docker exec -u ${_hu}:${_hg} -w "${CONTAINER_WWW}/${domain}" ${_hc} php artisan horizon
process_name=%(program_name)s
autostart=true
autorestart=true
user=root
numprocs=1
redirect_stderr=true
stdout_logfile=${WWW_ROOT}/${domain}/storage/logs/horizon.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stopwaitsecs=60
stopsignal=TERM
HORIZON

  if supervisord_ready; then
    supervisorctl reread &>/dev/null || true
    supervisorctl update &>/dev/null || true
    supervisorctl start "laravel-horizon-${domain}" &>/dev/null \
      || supervisorctl restart "laravel-horizon-${domain}" &>/dev/null || true
    ok "Horizon 已启动"
  elif command -v supervisorctl &>/dev/null; then
    warn "supervisord 未运行（无监听 socket），已写入配置；请 systemctl start supervisord 或 supervisor 后执行: supervisorctl reread && supervisorctl update"
  else
    warn "supervisorctl 不可用，请手动 reread && update"
  fi
}

# ═══════════════════════════════════════════════
#  子命令: add
# ═══════════════════════════════════════════════
DOMAIN="" GIT_REPO="" GIT_BRANCH="" SITE_TYPE=""
SITE_PHP_VERSION="" SITE_PHP_VERSION_CLI=0
SITE_SSE_PREFIXES="" SITE_SSE_PREFIXES_CLI=0
APP_NAME="" REDIS_HOST="" REDIS_PORT="" REDIS_PASSWORD=""
REDIS_PASSWORD_FROM_CLI=0
NEED_DB="" DB_HOST="" DB_NAME="" DB_PWD=""
DB_PWD_FROM_CLI=0
CREATE_DB="" RUN_MIGRATE="" RUN_SEED="" ADD_CRONTAB="" NEED_HORIZON=""
FRONTEND_ROOT=""
SSL_DNS="" CF_TOKEN="" FORCE_SSL="" SSL_STAGING=0
ALI_KEY="" ALI_SECRET="" DP_ID="" DP_KEY="" GD_KEY="" GD_SECRET=""
AWS_ACCESS_KEY_ID="" AWS_SECRET_ACCESS_KEY="" TENCENT_SECRET_ID="" TENCENT_SECRET_KEY=""
CUSTOM_ENV=()
YES=0
STATUS_ALL=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain=*)        DOMAIN="${1#*=}" ;;
      --domain)          shift; DOMAIN="$1" ;;
      --sse-prefixes=*)  SITE_SSE_PREFIXES="${1#*=}"; SITE_SSE_PREFIXES_CLI=1 ;;
      --sse-prefixes)
        SITE_SSE_PREFIXES_CLI=1
        shift
        if [[ $# -ge 1 && "$1" != --* ]]; then
          SITE_SSE_PREFIXES="$1"
        else
          SITE_SSE_PREFIXES=""
        fi
        ;;
      --git=*)           GIT_REPO="${1#*=}" ;;
      --git)             shift; GIT_REPO="$1" ;;
      --git-branch=*)    GIT_BRANCH="${1#*=}" ;;
      --git-branch)      shift; GIT_BRANCH="$1" ;;
      --type=*)          SITE_TYPE="${1#*=}" ;;
      --type)            shift; SITE_TYPE="$1" ;;
      --php-version=*)   SITE_PHP_VERSION="${1#*=}"; SITE_PHP_VERSION_CLI=1 ;;
      --php-version)
        SITE_PHP_VERSION_CLI=1
        if [[ $# -ge 2 && -n "$2" && "$2" != --* ]]; then
          shift; SITE_PHP_VERSION="$1"
        else
          SITE_PHP_VERSION=""
        fi
        ;;
      --app-name=*)      APP_NAME="${1#*=}" ;;
      --app-name)        shift; APP_NAME="$1" ;;
      --redis-host=*)    REDIS_HOST="${1#*=}" ;;
      --redis-host)      shift; REDIS_HOST="$1" ;;
      --redis-port=*)    REDIS_PORT="${1#*=}" ;;
      --redis-port)      shift; REDIS_PORT="$1" ;;
      --redis-password=*)
        REDIS_PASSWORD="${1#*=}"
        REDIS_PASSWORD_FROM_CLI=1
        ;;
      --redis-password)
        REDIS_PASSWORD_FROM_CLI=1
        if [[ $# -ge 2 && -n "$2" && "$2" != --* ]]; then
          shift
          REDIS_PASSWORD="$1"
        else
          REDIS_PASSWORD=""
        fi
        ;;
      --need-db=*)       NEED_DB="${1#*=}" ;;
      --need-db)         shift; NEED_DB="$1" ;;
      --db-host=*)       DB_HOST="${1#*=}" ;;
      --db-host)         shift; DB_HOST="$1" ;;
      --db-name=*)       DB_NAME="${1#*=}" ;;
      --db-name)         shift; DB_NAME="$1" ;;
      --db-password=*)
        DB_PWD="${1#*=}"
        DB_PWD_FROM_CLI=1
        ;;
      --db-password)
        DB_PWD_FROM_CLI=1
        if [[ $# -ge 2 && -n "$2" && "$2" != --* ]]; then
          shift
          DB_PWD="$1"
        else
          DB_PWD=""
        fi
        ;;
      --create-db=*)     CREATE_DB="${1#*=}" ;;
      --create-db)       shift; CREATE_DB="$1" ;;
      --run-migrate=*)   RUN_MIGRATE="${1#*=}" ;;
      --run-migrate)     shift; RUN_MIGRATE="$1" ;;
      --run-seed=*)      RUN_SEED="${1#*=}" ;;
      --run-seed)        shift; RUN_SEED="$1" ;;
      --add-crontab=*)   ADD_CRONTAB="${1#*=}" ;;
      --add-crontab)     shift; ADD_CRONTAB="$1" ;;
      --need-horizon=*)  NEED_HORIZON="${1#*=}" ;;
      --need-horizon)    shift; NEED_HORIZON="$1" ;;
      --frontend-root=*) FRONTEND_ROOT="${1#*=}" ;;
      --frontend-root)   shift; FRONTEND_ROOT="$1" ;;
      --env=*)           CUSTOM_ENV+=("${1#*=}") ;;
      --env)             shift; CUSTOM_ENV+=("$1") ;;
      --dns=*)           SSL_DNS="${1#*=}" ;;
      --dns)             shift; SSL_DNS="$1" ;;
      --cf-token=*)      CF_TOKEN="${1#*=}" ;;
      --cf-token)        shift; CF_TOKEN="$1" ;;
      --ali-key=*)       ALI_KEY="${1#*=}" ;;
      --ali-key)         shift; ALI_KEY="$1" ;;
      --ali-secret=*)    ALI_SECRET="${1#*=}" ;;
      --ali-secret)      shift; ALI_SECRET="$1" ;;
      --dp-id=*)         DP_ID="${1#*=}" ;;
      --dp-id)           shift; DP_ID="$1" ;;
      --dp-key=*)        DP_KEY="${1#*=}" ;;
      --dp-key)          shift; DP_KEY="$1" ;;
      --gd-key=*)        GD_KEY="${1#*=}" ;;
      --gd-key)          shift; GD_KEY="$1" ;;
      --gd-secret=*)     GD_SECRET="${1#*=}" ;;
      --gd-secret)       shift; GD_SECRET="$1" ;;
      --aws-access-key=*) AWS_ACCESS_KEY_ID="${1#*=}" ;;
      --aws-access-key)  shift; AWS_ACCESS_KEY_ID="$1" ;;
      --aws-secret-key=*) AWS_SECRET_ACCESS_KEY="${1#*=}" ;;
      --aws-secret-key)  shift; AWS_SECRET_ACCESS_KEY="$1" ;;
      --tencent-secret-id=*)  TENCENT_SECRET_ID="${1#*=}" ;;
      --tencent-secret-id)    shift; TENCENT_SECRET_ID="$1" ;;
      --tencent-secret-key=*) TENCENT_SECRET_KEY="${1#*=}" ;;
      --tencent-secret-key)   shift; TENCENT_SECRET_KEY="$1" ;;
      --force-ssl)       FORCE_SSL="--force" ;;
      --ssl-staging)     SSL_STAGING=1 ;;
      --yes)             YES=1 ;;
      --all)             STATUS_ALL=1 ;;
      *)                 ;; # ignore unknown in subcommand context
    esac
    shift
  done
}

# 列出 ${NGINX_CONF}/*.conf 已部署站点（去掉 default）
_list_deployed_domains() {
  local conf name
  for conf in "${NGINX_CONF}"/*.conf; do
    [[ -f "$conf" ]] || continue
    name=$(basename "$conf" .conf)
    [[ "$name" = "default" ]] && continue
    printf '%s\n' "$name"
  done
}

# DOMAIN 为空 + TTY 时弹菜单选择已部署站点；prefer_action=update/remove/ssl/status 仅用于标题
prompt_pick_domain() {
  [[ -n "$DOMAIN" ]] && return 0
  [[ -t 0 ]] || die "缺少 --domain"
  local -a doms=()
  while IFS= read -r d; do doms+=("$d"); done < <(_list_deployed_domains)
  if [[ ${#doms[@]} -eq 0 ]]; then
    DOMAIN=$(prompt "站点域名（当前无已部署站点）")
    return 0
  fi
  local _items=("${doms[@]}" "手动输入...")
  local _i; _i=$(menu_select "${1:-选择站点}" "${_items[@]}")
  if [[ "$_i" -lt ${#doms[@]} ]]; then
    DOMAIN="${doms[$_i]}"
  else
    DOMAIN=$(prompt "站点域名")
  fi
}

# PHP 版本菜单：基于在线 lnmp-php / lnmp-php-XX 容器
_collect_site_php_version_interactive() {
  [[ "${SITE_PHP_VERSION_CLI:-0}" -eq 1 ]] && return 0
  [[ -t 0 ]] || return 0
  local -a vers=("默认（lnmp-php = ${PHP_VERSION:-未知}）")
  local cur n v dv; dv="$(_default_php_ver)"
  while IFS= read -r n; do
    [[ "$n" = "lnmp-php" ]] && continue
    v="${n#lnmp-php-}"
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    cur="${v:0:1}.${v:1}"
    vers+=("$cur（$n）")
  done < <(_iter_php_containers)
  # 仅 1 项即只有默认容器，无需打扰
  if [[ ${#vers[@]} -le 1 ]]; then return 0; fi
  vers+=("自定义...")
  local _i; _i=$(menu_select "选择 PHP 版本" "${vers[@]}")
  if [[ "$_i" -eq 0 ]]; then
    SITE_PHP_VERSION=""; SITE_PHP_VERSION_CLI=1
  elif [[ "$_i" -eq $((${#vers[@]} - 1)) ]]; then
    SITE_PHP_VERSION="$(prompt "PHP 主版本 (X.Y)" "$dv")"
    SITE_PHP_VERSION_CLI=1
  else
    local pick="${vers[$_i]}"
    SITE_PHP_VERSION="${pick%%（*}"
    SITE_PHP_VERSION_CLI=1
  fi
}

# SSL 校验方式菜单
_collect_ssl_dns_interactive() {
  [[ -n "$SSL_DNS" ]] && return 0
  [[ -t 0 ]] || { SSL_DNS="${ACME_SSL_DNS_DEFAULT:-webroot}"; return 0; }
  local _i; _i=$(menu_select "SSL 证书校验方式（默认 webroot；DNS 模式可签泛域名）" \
    "webroot   (HTTP-01；最常见，需域名解析到本机)" \
    "dns_cf    (Cloudflare API Token)" \
    "dns_ali   (阿里云 DNS Ali_Key/Secret)" \
    "dns_dp    (DNSPod DP_Id/DP_Key)" \
    "dns_gd    (GoDaddy)" \
    "dns_aws   (Route53)" \
    "dns_tencent (腾讯云 DNSPod API)")
  case "$_i" in
    0) SSL_DNS="webroot" ;;
    1) SSL_DNS="dns_cf" ;;
    2) SSL_DNS="dns_ali" ;;
    3) SSL_DNS="dns_dp" ;;
    4) SSL_DNS="dns_gd" ;;
    5) SSL_DNS="dns_aws" ;;
    6) SSL_DNS="dns_tencent" ;;
  esac
}

# 站点目录已存在且非空（且没有 .git）→ 提示是否仍 clone（默认否，避免误覆盖）
_offer_skip_git_if_code_present() {
  [[ -z "$GIT_REPO" ]] && return 0
  [[ -t 0 ]] || return 0
  local d="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$d/.git" ]] && return 0
  [[ -d "$d" ]] || return 0
  [[ -n "$(ls -A "$d" 2>/dev/null)" ]] || return 0
  warn "已检测到 ${d} 含代码（无 .git）；继续 clone 会失败"
  if confirm "跳过 Git，使用现有代码？" "y"; then
    GIT_REPO=""; GIT_BRANCH=""
  fi
}

# DB 三件事（建库/迁移/seed）合并为一次决策
_collect_db_actions_interactive() {
  [[ "$NEED_DB" != "y" ]] && return 0
  [[ -t 0 ]] || return 0
  # CLI 任一已显式给值 → 用 CLI 决策，跳过菜单
  if [[ -n "${CREATE_DB}${RUN_MIGRATE}${RUN_SEED}" ]]; then
    CREATE_DB="${CREATE_DB:-y}"
    RUN_MIGRATE="${RUN_MIGRATE:-y}"
    RUN_SEED="${RUN_SEED:-y}"
    return 0
  fi
  local _i; _i=$(menu_select "数据库自动化（建库 / migrate / seed）" \
    "建库 + migrate + seed（全自动，推荐）" \
    "建库 + migrate（不跑 seed）" \
    "仅建库（不 migrate、不 seed）" \
    "什么都不做（仅写 .env，留待手动）" \
    "自定义（逐项询问）")
  case "$_i" in
    0) CREATE_DB=y; RUN_MIGRATE=y; RUN_SEED=y ;;
    1) CREATE_DB=y; RUN_MIGRATE=y; RUN_SEED=n ;;
    2) CREATE_DB=y; RUN_MIGRATE=n; RUN_SEED=n ;;
    3) CREATE_DB=n; RUN_MIGRATE=n; RUN_SEED=n ;;
    4)
      confirm "自动创建数据库？" "y" && CREATE_DB=y || CREATE_DB=n
      confirm "执行 migrate？"   "y" && RUN_MIGRATE=y || RUN_MIGRATE=n
      if [[ "$RUN_MIGRATE" = "y" ]]; then
        confirm "执行 db:seed？" "y" && RUN_SEED=y || RUN_SEED=n
      else
        RUN_SEED=n
      fi
      ;;
  esac
}

# 队列后台（cron / Horizon）合并为一次决策；据 PHP 版本作可行性提示
_collect_queue_supervisor_interactive() {
  [[ -t 0 ]] || return 0
  if [[ -n "${ADD_CRONTAB}${NEED_HORIZON}" ]]; then
    ADD_CRONTAB="${ADD_CRONTAB:-y}"
    NEED_HORIZON="${NEED_HORIZON:-y}"
    return 0
  fi
  local _phpv _hint=""
  _phpv="${SITE_PHP_VERSION:-$(_default_php_ver)}"
  if [[ -n "$_phpv" ]] && ! _lv_ge "$_phpv" "7.2"; then
    _hint="（注：当前 PHP ${_phpv} < 7.2，Horizon 不可用，将自动禁用）"
  fi
  local _i; _i=$(menu_select "队列后台 / 定时任务${_hint}" \
    "cron + Horizon（推荐：调度 + Redis 队列守护）" \
    "仅 cron（无队列守护，sync/database 队列）" \
    "仅 Horizon（无 schedule:run）" \
    "都不要")
  case "$_i" in
    0) ADD_CRONTAB=y; NEED_HORIZON=y ;;
    1) ADD_CRONTAB=y; NEED_HORIZON=n ;;
    2) ADD_CRONTAB=n; NEED_HORIZON=y ;;
    3) ADD_CRONTAB=n; NEED_HORIZON=n ;;
  esac
}

collect_interactive() {
  # 1) 域名（决策性，最早问）
  [[ -z "$DOMAIN" ]] && DOMAIN=$(prompt "站点域名 (如 app.com)")
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  # 2) 站点类型（决定后续走 laravel/frontend 分叉）
  if [[ -z "$SITE_TYPE" ]]; then
    if [[ -t 0 ]]; then
      local _i; _i=$(menu_select "站点类型" "laravel (PHP 后端)" "frontend (静态/SPA)")
      [[ "$_i" -eq 1 ]] && SITE_TYPE="frontend" || SITE_TYPE="laravel"
    else
      SITE_TYPE="laravel"
    fi
  fi
  SITE_TYPE=${SITE_TYPE:-laravel}
  [[ "$SITE_TYPE" != "laravel" && "$SITE_TYPE" != "frontend" ]] && SITE_TYPE="laravel"

  # 3) Git（已存在代码时智能提示跳过）
  [[ -z "$GIT_REPO" ]] && GIT_REPO=$(prompt "Git 仓库地址（留空=跳过 clone，使用 ${WWW_ROOT}/${DOMAIN} 现有代码）" "")
  _offer_skip_git_if_code_present
  if [[ -n "$GIT_REPO" ]]; then
    [[ -z "$GIT_BRANCH" ]] && GIT_BRANCH=$(prompt "Git 分支（留空=仓库默认）" "")
  else
    GIT_BRANCH=""
  fi

  if [[ "$SITE_TYPE" = "laravel" ]]; then
    # 4) PHP 版本（影响后续 Horizon 可行性）
    _collect_site_php_version_interactive

    # 5) 数据库块：先决定是否需要 DB，再凭证，再动作预设
    [[ -z "$NEED_DB" ]] && { confirm "配置数据库？" "y" && NEED_DB="y" || NEED_DB="n"; }
    if [[ "$NEED_DB" = "y" ]]; then
      DB_HOST=${DB_HOST:-$(prompt "DB_HOST（MySQL 主机/容器名）" "mysql")}
      [[ -z "$DB_NAME" ]] && DB_NAME=$(prompt "DB_DATABASE（业务库名，勿填 mysql 主机名）")
      [[ -z "$DB_NAME" ]] && die "DB_DATABASE 不能为空"
      [[ "$DB_PWD_FROM_CLI" != "1" && -z "$DB_PWD" ]] && prompt_secret_into "DB_PASSWORD" DB_PWD
      [[ -z "$DB_PWD" ]]  && die "DB_PASSWORD 不能为空"
      _collect_db_actions_interactive
    fi

    # 6) Redis（基础依赖）
    REDIS_HOST=${REDIS_HOST:-$(prompt "REDIS_HOST" "redis")}
    REDIS_PORT=${REDIS_PORT:-$(prompt "REDIS_PORT" "6379")}
    if [[ "$REDIS_PASSWORD_FROM_CLI" != "1" && -z "${REDIS_PASSWORD:-}" ]]; then
      prompt_secret_into "REDIS_PASSWORD (留空=无)" REDIS_PASSWORD
    fi

    # 7) 队列后台 / 定时任务
    _collect_queue_supervisor_interactive

    # 8) 应用名 + 自定义 ENV（最低优先级，放最后；轻打扰）
    APP_NAME=${APP_NAME:-$(prompt "APP_NAME" "Laravel")}

    if [[ ${#CUSTOM_ENV[@]} -eq 0 && -t 0 ]]; then
      echo ""
      info "自定义 ENV（一行 CSV：KEY=V[,KEY2=V2]，留空跳过；含逗号/空格的值改用 --env 多次传入）"
      local _envline
      _envline=$(prompt "ENV" "")
      if [[ -n "$_envline" ]]; then
        local IFS=','
        local _kv
        for _kv in $_envline; do
          _kv="${_kv#"${_kv%%[![:space:]]*}"}"; _kv="${_kv%"${_kv##*[![:space:]]}"}"
          [[ -z "$_kv" ]] && continue
          [[ "$_kv" == *=* ]] || { warn "忽略无效项: $_kv（应为 KEY=VALUE）"; continue; }
          CUSTOM_ENV+=("$_kv")
        done
      fi
    fi
  else
    # frontend 分支：仅子目录
    [[ -z "$FRONTEND_ROOT" ]] && FRONTEND_ROOT=$(prompt "前端子目录（相对站点目录，留空则：有 dist 目录→dist，否则→站点根）" "")
  fi

  # 9) SSL（最末尾，凭证一并校验）
  _collect_ssl_dns_interactive
  SSL_DNS="${SSL_DNS:-${ACME_SSL_DNS_DEFAULT:-webroot}}"
  case "$SSL_DNS" in
    webroot|dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) ;;
    *) die "无效 SSL 模式: ${SSL_DNS}（webroot / dns_cf / dns_ali / dns_dp / dns_gd / dns_aws / dns_tencent）" ;;
  esac
  _collect_ssl_dns_creds_interactive
  if _is_dns_mode "$SSL_DNS"; then
    _acme_ssl_validate_dns_creds "$SSL_DNS"
  fi
}

cmd_add() {
  for c in lnmp-nginx lnmp-php; do
    container_ok "$c" || die "容器 ${c} 未运行，请先执行 init.sh"
  done
  container_ok "lnmp-acme" || warn "lnmp-acme 未运行，SSL 签发可能失败"

  ensure_php_fpm_slowlog_host_artifacts
  warn_php_fpm_slowlog_compose_missing
  ensure_php_fpm_wave_pool_host_artifacts
  warn_php_fpm_wave_pool_compose_missing
  ensure_mysql_low_memory_host_artifacts
  warn_mysql_low_memory_compose_missing

  collect_interactive

  if [[ "$SITE_TYPE" = "laravel" && "${NEED_DB:-y}" = "y" ]]; then
    [[ -z "${DB_NAME:-}" ]] && die "Laravel 默认启用数据库，请指定 --db-name 或在交互中填写 DB_DATABASE"
    [[ "$DB_NAME" = "mysql" && "${DB_HOST:-mysql}" = "mysql" ]] \
      && die "DB_DATABASE 不能为 mysql（与 DB_HOST=mysql 同时出现时多为填反）。库名请用业务名如 payment"
  fi

  # 执行前的「配置确认」（仅 TTY 且未 --yes 时弹出，顺序与提问顺序一致）
  if [[ "${YES:-0}" -ne 1 && -t 0 ]]; then
    echo ""
    hr; info "配置确认"; hr
    printf "  %-18s %s\n" "域名"   "$DOMAIN"
    printf "  %-18s %s\n" "类型"   "$SITE_TYPE"
    if [[ -n "$GIT_REPO" ]]; then
      printf "  %-18s %s\n" "Git" "${GIT_REPO}${GIT_BRANCH:+ (${GIT_BRANCH})}"
    else
      printf "  %-18s %s\n" "Git" "跳过（使用 ${WWW_ROOT}/${DOMAIN} 现有代码）"
    fi
    if [[ "$SITE_TYPE" = "laravel" ]]; then
      printf "  %-18s %s\n" "PHP 容器" "$(_php_container_for_site "$DOMAIN")"
      if [[ "${NEED_DB:-y}" = "y" ]]; then
        printf "  %-18s %s\n" "数据库" "${DB_HOST:-mysql} / ${DB_NAME:-?}"
        printf "  %-18s %s\n" "建库 / migrate / seed" "${CREATE_DB:-y} / ${RUN_MIGRATE:-y} / ${RUN_SEED:-y}"
      else
        printf "  %-18s %s\n" "数据库" "不配置（n）"
      fi
      printf "  %-18s %s\n" "Redis"   "${REDIS_HOST:-redis}:${REDIS_PORT:-6379}${REDIS_PASSWORD:+ (有密码)}"
      printf "  %-18s %s\n" "cron / Horizon" "${ADD_CRONTAB:-y} / ${NEED_HORIZON:-y}"
      printf "  %-18s %s\n" "APP_NAME" "${APP_NAME:-Laravel}"
      [[ ${#CUSTOM_ENV[@]} -gt 0 ]] && printf "  %-18s %s\n" "自定义 ENV" "${#CUSTOM_ENV[@]} 项"
    else
      printf "  %-18s %s\n" "前端子目录" "${FRONTEND_ROOT:-自动 (dist 优先)}"
    fi
    printf "  %-18s %s\n" "SSL" "${SSL_DNS:-webroot}${SSL_STAGING:+ (staging)}${FORCE_SSL:+ +force}"
    echo ""
    confirm "确认执行？" "y" || { warn "已取消"; return 0; }
  fi

  ensure_placeholder_cert "$DOMAIN"
  normalize_nginx_cache_dir
  fix_nginx_main_pid_path
  normalize_nginx_conf_d
  normalize_nginx_ssl_trees

  echo ""
  hr; info "[1/6] Nginx 配置"; echo ""
  if [[ "$SITE_TYPE" = "laravel" ]]; then
    apply_site_php_version_cli "$DOMAIN"
    ensure_site_php_container "$DOMAIN"
    apply_site_sse_prefixes_cli "$DOMAIN"
    gen_nginx_laravel "$DOMAIN"
    wait_container_running "lnmp-nginx" 45
    docker exec lnmp-nginx nginx -t 2>&1 || die "Nginx 配置校验失败"
    docker exec lnmp-nginx nginx -s reload
    ok "Nginx 配置已生成"
  else
    info "前端站点：Nginx 在代码部署后生成（未指定子目录时：有 dist 用 dist，否则站点根）"
  fi

  echo ""
  hr; info "[2/6] 部署代码"; echo ""
  deploy_code "$DOMAIN" "$GIT_REPO" "$GIT_BRANCH"
  ok "代码部署完成"

  local _fe_sub=""
  if [[ "$SITE_TYPE" = "frontend" ]]; then
    _fe_sub=$(effective_frontend_subdir "$DOMAIN")
    gen_nginx_frontend "$DOMAIN" "$_fe_sub"
    wait_container_running "lnmp-nginx" 45
    docker exec lnmp-nginx nginx -t 2>&1 || die "Nginx 配置校验失败"
    docker exec lnmp-nginx nginx -s reload
    ok "Nginx 配置已生成"
  fi

  echo ""
  hr; info "[3/6] SSL 证书"; echo ""
  if container_ok "lnmp-acme"; then
    if [[ "$SITE_TYPE" = "frontend" ]]; then
      issue_ssl "$DOMAIN" "$SITE_TYPE" "${SSL_DNS:-webroot}" "${FORCE_SSL:-}" "${_fe_sub}"
    else
      issue_ssl "$DOMAIN" "$SITE_TYPE" "${SSL_DNS:-webroot}" "${FORCE_SSL:-}" "dist"
    fi
  else
    warn "lnmp-acme 未运行，跳过 SSL 签发"
  fi

  if [[ "$SITE_TYPE" = "laravel" ]]; then
    echo ""
    hr; info "[4/6] 数据库"; echo ""
    if [[ "${NEED_DB:-y}" = "y" && "${CREATE_DB:-y}" = "y" && -n "${DB_NAME:-}" ]]; then
      create_database "$DB_NAME" "$DB_PWD" "${DB_HOST:-mysql}"
    else
      info "跳过"
    fi

    echo ""
    hr; info "[5/6] Laravel 配置"; echo ""
    _QUEUE_CONN=""
    setup_laravel "$DOMAIN"
    local queue_conn="${_QUEUE_CONN:-sync}"

    if [[ "${NEED_DB:-y}" = "y" && "${RUN_MIGRATE:-y}" = "y" ]]; then
      run_migrations "$DOMAIN"
      [[ "${RUN_SEED:-y}" = "y" ]] && run_seed "$DOMAIN"
    fi

    echo ""
    hr; info "[6/6] 定时任务与 Horizon"; echo ""
    [[ "${ADD_CRONTAB:-y}" = "y" ]] && setup_crontab "$DOMAIN"
    [[ "${NEED_HORIZON:-y}" = "y" && "$queue_conn" = "redis" ]] && setup_horizon "$DOMAIN"
    [[ "${NEED_HORIZON:-y}" = "y" && "$queue_conn" != "redis" ]] && warn "Horizon 需要 Redis，当前: ${queue_conn}"

    echo ""
    hr
    ok "Laravel 部署完成"
    info "访问: https://${DOMAIN}"
    info "目录: ${WWW_ROOT}/${DOMAIN}"
    hr
  else
    echo ""
    hr; info "[4/6] 跳过（前端无数据库）"
    hr; info "[5/6] 跳过（前端无 PHP）"
    hr; info "[6/6] 跳过（前端无 crontab）"
    echo ""

    local _fe_add _dist_add="${WWW_ROOT}/${DOMAIN}"
    _fe_add=$(effective_frontend_subdir "$DOMAIN")
    [[ -n "$_fe_add" ]] && _dist_add="${_dist_add}/${_fe_add}"
    if [[ ! -d "$_dist_add" ]] || [[ -z "$(ls -A "$_dist_add" 2>/dev/null)" ]]; then
      warn "构建目录 ${_dist_add} 不存在或为空"
      info "请本地构建后推送或在服务器执行 npm run build"
    else
      ok "构建产物已就绪"
    fi

    echo ""
    hr
    ok "前端站点部署完成"
    info "访问: https://${DOMAIN}"
    info "目录: ${WWW_ROOT}/${DOMAIN}"
    hr
  fi
}

# ═══════════════════════════════════════════════
#  子命令: update
# ═══════════════════════════════════════════════
cmd_update() {
  prompt_pick_domain "选择要更新的站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  local site_dir="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$site_dir" ]] || die "站点 ${DOMAIN} 不存在（${site_dir}）"

  local site_type="laravel"
  [[ -f "${site_dir}/artisan" ]] || site_type="frontend"

  echo ""
  hr; info "更新站点: ${DOMAIN} (${site_type})"; echo ""

  ensure_php_fpm_slowlog_host_artifacts
  warn_php_fpm_slowlog_compose_missing
  ensure_php_fpm_wave_pool_host_artifacts
  warn_php_fpm_wave_pool_compose_missing
  ensure_mysql_low_memory_host_artifacts
  warn_mysql_low_memory_compose_missing

  if [[ -d "${site_dir}/.git" ]]; then
    _git_pull_or_clone "${site_dir}" "" "${GIT_BRANCH:-}"
    ok "代码已更新"
  else
    warn "未检测到 .git，跳过 git pull（请事先将新版本同步到 ${site_dir}）"
  fi

  if [[ "$site_type" = "laravel" ]]; then
    apply_site_php_version_cli "$DOMAIN"
    ensure_site_php_container "$DOMAIN"

    info "composer install..."
    local uid gid
    uid=$(id -u "${DEVOPS_USER}")
    gid=$(id -g "${DEVOPS_USER}")
    local cname; cname="$(_php_container_for_site "$DOMAIN")"
    ensure_lnmp_php_laravel_extensions "$cname"
    ensure_composer_in_lnmp_php "$cname"
    docker exec -u "${uid}:${gid}" -e COMPOSER_CACHE_DIR=/tmp/composer-cache "$cname" \
      composer install \
      --working-dir="${CONTAINER_WWW}/${DOMAIN}" \
      --no-dev --no-interaction --optimize-autoloader --no-progress --prefer-dist

    chmod -R 775 "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    if command -v setfacl &>/dev/null; then
      setfacl -R  -m u:82:rwX "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
      setfacl -dR -m u:82:rwX "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    fi

    if [[ -n "${RUN_MIGRATE:-}" ]]; then
      if [[ "$RUN_MIGRATE" = "y" ]]; then
        info "artisan migrate..."
        docker_php_artisan "$DOMAIN" migrate --force
      else
        info "跳过 migrate（--run-migrate=n）"
      fi
    elif confirm "执行 migrate？" "y"; then
      info "artisan migrate..."
      docker_php_artisan "$DOMAIN" migrate --force
    fi

    local _lv; _lv="$(_laravel_min_for_site "$DOMAIN")"
    if _lv_supports_optimize "$_lv"; then
      info "artisan optimize..."
      docker_php_artisan "$DOMAIN" optimize:clear 2>/dev/null || true
      docker_php_artisan "$DOMAIN" optimize || warn "artisan optimize 失败（已忽略）"
    else
      info "跳过 artisan optimize（Laravel ${_lv:-未知} < 5.7 不支持）"
      docker_php_artisan "$DOMAIN" cache:clear 2>/dev/null || true
      docker_php_artisan "$DOMAIN" config:cache 2>/dev/null || true
      docker_php_artisan "$DOMAIN" route:cache 2>/dev/null || true
    fi

    info "php-fpm graceful reload（清空 OPCache，${cname}）..."
    docker exec "$cname" sh -c 'kill -USR2 1' 2>/dev/null \
      && ok "PHP-FPM 已 graceful reload（${cname}，OPCache 已清空）" \
      || warn "PHP-FPM reload 失败，OPCache 未清空；如内存持续偏高请手动: docker restart ${cname}"

    # 切换 PHP 版本时 cron 里的 docker exec 仍指向旧容器，若已注册过则重写
    local _cron_log="${WWW_ROOT}/${DOMAIN}/storage/logs/cron.log"
    local _cron_existing _cron_dom_esc
    _cron_existing=$(crontab -u "${DEVOPS_USER}" -l 2>/dev/null || true)
    # 域名内的 . 在 ERE 下是任意字符，转义后再 -F 严格匹配避免误中其他子域名
    _cron_dom_esc="${DOMAIN//./\\.}"
    if printf '%s\n' "$_cron_existing" | grep -qF "${_cron_log}" \
      || printf '%s\n' "$_cron_existing" | grep -qE "docker exec[^|;&]*lnmp-php(-[0-9]+)?[[:space:]].*artisan[[:space:]]+schedule:run[^|;&]*${_cron_dom_esc}(\b|$)"; then
      setup_crontab "$DOMAIN"
    fi

    local sup_conf=""
    sup_conf=$(horizon_supervisor_conf_path "$DOMAIN") || true
    if [[ -n "$sup_conf" ]]; then
      # 站点已配 Horizon：可能切换了 PHP 版本，重写 supervisor conf 并重启
      setup_horizon "$DOMAIN"
    fi

    interactive_sse_prefixes_maybe_for_update "$DOMAIN"
    apply_site_sse_prefixes_cli "$DOMAIN"
    gen_nginx_laravel "$DOMAIN"
    if container_ok "lnmp-nginx"; then
      if docker exec lnmp-nginx nginx -t 2>&1; then
        docker exec lnmp-nginx nginx -s reload 2>/dev/null && ok "Nginx 已 reload（与模板同步）" || warn "Nginx reload 失败"
      else
        warn "Nginx 配置校验失败，未 reload"
      fi
    fi
  else
    # 前端站点：检查构建产物并 reload nginx
    local _feu _dist_u="${WWW_ROOT}/${DOMAIN}"
    _feu=$(effective_frontend_subdir "$DOMAIN")
    [[ -n "$_feu" ]] && _dist_u="${_dist_u}/${_feu}"
    if [[ -d "$_dist_u" ]] && [[ -n "$(ls -A "$_dist_u" 2>/dev/null)" ]]; then
      ok "构建产物就绪: ${_dist_u}"
    else
      warn "构建目录 ${_dist_u} 不存在或为空，请手动执行构建后 reload"
    fi
    gen_nginx_frontend "$DOMAIN" "$_feu"
    fix_site_readable_for_nginx "$DOMAIN" "frontend" "$_feu"
    if container_ok "lnmp-nginx"; then
      if docker exec lnmp-nginx nginx -t 2>&1; then
        docker exec lnmp-nginx nginx -s reload 2>/dev/null && ok "Nginx 已 reload" || warn "Nginx reload 失败"
      else
        warn "Nginx 配置校验失败，未 reload"
      fi
    fi
  fi

  info "清理 Docker 悬空镜像..."
  docker image prune -f >/dev/null 2>&1 && ok "Docker 悬空镜像已清理" || true

  echo ""
  ok "站点 ${DOMAIN} 更新完成"
}

# ═══════════════════════════════════════════════
#  子命令: remove
# ═══════════════════════════════════════════════
cmd_remove() {
  prompt_pick_domain "选择要移除的站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  echo ""
  hr; info "移除站点: ${DOMAIN}"; echo ""

  [[ "${YES:-0}" -eq 0 ]] && ! confirm "确认删除 ${DOMAIN}？所有配置和数据将被移除" "n" && { info "已取消"; return; }

  rm -f "${NGINX_CONF}/${DOMAIN}.sse-prefixes" 2>/dev/null || true
  rm -f "${NGINX_CONF}/${DOMAIN}.php-version" 2>/dev/null || true
  if [[ -f "${NGINX_CONF}/${DOMAIN}.conf" ]]; then
    rm -f "${NGINX_CONF}/${DOMAIN}.conf"
    normalize_nginx_conf_d
    docker exec lnmp-nginx nginx -s reload 2>/dev/null || true
    ok "Nginx 配置已删除"
  fi

  if [[ -d "${SSL_DIR}/${DOMAIN}" ]]; then
    rm -rf "${SSL_DIR}/${DOMAIN}"
    ok "SSL 证书已删除"
  fi

  local existing _cron_log _art filtered
  existing=$(crontab -u "${DEVOPS_USER}" -l 2>/dev/null || true)
  _cron_log="${WWW_ROOT}/${DOMAIN}/storage/logs/cron.log"
  _art="${CONTAINER_WWW}/${DOMAIN}/artisan"
  if echo "$existing" | grep -qF "${_cron_log}" || echo "$existing" | grep -qF "${_art}"; then
    filtered=$(printf '%s\n' "$existing" | grep -vF "${_cron_log}" || true)
    filtered=$(printf '%s\n' "$filtered" | grep -vF "${_art}" || true)
    { printf '%s\n' "$filtered" | grep -v '^$' || true; } | crontab -u "${DEVOPS_USER}" -
    ok "Crontab 已清理"
  fi

  local _hz=0
  for d in /etc/supervisord.d /etc/supervisor/conf.d; do
    for ext in conf ini; do
      [[ -f "${d}/${DOMAIN}-horizon.${ext}" ]] && _hz=1 && break 2
    done
  done
  if [[ $_hz -eq 1 ]]; then
    supervisord_ready && {
      supervisorctl stop "laravel-horizon-${DOMAIN}" &>/dev/null || true
      supervisorctl remove "laravel-horizon-${DOMAIN}" &>/dev/null || true
    }
    for d in /etc/supervisord.d /etc/supervisor/conf.d; do
      rm -f "${d}/${DOMAIN}-horizon.conf" "${d}/${DOMAIN}-horizon.ini"
    done
    ok "Horizon 配置已删除"
  fi

  if [[ -d "${WWW_ROOT}/${DOMAIN}" ]]; then
    if [[ "${YES:-0}" -eq 1 ]] || confirm "删除代码目录 ${WWW_ROOT}/${DOMAIN}？" "n"; then
      rm -rf "${WWW_ROOT}/${DOMAIN}"
      ok "代码目录已删除"
    else
      info "保留代码目录"
    fi
  fi

  echo ""
  ok "站点 ${DOMAIN} 已移除"
}

# ═══════════════════════════════════════════════
#  子命令: status（运行状态与常见故障线索）
# ═══════════════════════════════════════════════
# 仅保留 3 位状态码（避免终端/旧 curl 异常拼接）
_status_http_code_normalize() {
  local c="${1:-}"
  c="${c//[^0-9]/}"
  [[ ${#c} -ge 3 ]] && printf '%s' "${c:0:3}" || printf '000'
}

# Laravel 11+ 用 /up 探活；老 Laravel 与前端用 /；可由调用方传入 path 覆盖
_status_http_code() {
  local host="$1" use_https="$2" site_type="${3:-frontend}" probe_path="${4:-}"
  local path raw=""
  if [[ -n "$probe_path" ]]; then
    path="$probe_path"
  else
    path="/"; [[ "$site_type" = "laravel" ]] && path="/up"
  fi
  if [[ "$use_https" = 1 ]]; then
    raw=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 25 \
      --resolve "${host}:443:127.0.0.1" \
      "https://${host}${path}" 2>/dev/null) || raw=""
    _status_http_code_normalize "${raw:-000}"
  else
    raw=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 25 \
      --resolve "${host}:80:127.0.0.1" \
      "http://${host}${path}" 2>/dev/null) || raw=""
    _status_http_code_normalize "${raw:-000}"
  fi
}

# Laravel 且 HTTPS 异常时：本站 Nginx error + 宿主机 fpm-slow.log 尾部
_status_laravel_fpm_tail_hints() {
  local dom="$1"
  echo ""
  info "本站相关 Nginx error.log（含 server_name / Host）:"
  docker exec lnmp-nginx sh -c "grep -F '${dom}' /var/log/nginx/error.log 2>/dev/null | tail -n 20" 2>/dev/null | sed 's/^/  /' || true
  local _scn _ssub
  _scn="$(_php_container_for_site "$dom")"
  if [[ "$_scn" = "lnmp-php" ]]; then _ssub="php"; else _ssub="php-${_scn#lnmp-php-}"; fi
  [[ ! -s "${DATA_DIR}/${_ssub}/log/fpm-slow.log" ]] && return 0
  echo ""
  info "php-fpm 慢日志尾部（${DATA_DIR}/${_ssub}/log/fpm-slow.log）:"
  tail -n 30 "${DATA_DIR}/${_ssub}/log/fpm-slow.log" 2>/dev/null | sed 's/^/  /' || true
}

_status_print_hints() {
  local d="$1" code_http="$2" code_https="$3" site_type="$4" fe_sub="$5"
  local issues=()
  container_ok "lnmp-nginx" || issues+=("lnmp-nginx 未运行，本机 80/443 无服务")
  if [[ "$site_type" = "laravel" ]]; then
    local _spc; _spc="$(_php_container_for_site "$d")"
    container_ok "$_spc" || issues+=("${_spc} 未运行，Laravel 将出现 502（FastCGI 不可达）")
  fi
  [[ ! -f "${NGINX_CONF}/${d}.conf" ]] && issues+=("无 Nginx 配置 ${NGINX_CONF}/${d}.conf，请求可能落到默认站点")
  [[ "$code_http" = "000" ]] && issues+=("HTTP 无响应：检查 docker 端口映射、本机防火墙、阿里云安全组是否放行 80")
  [[ "$code_https" = "000" ]] && container_ok "lnmp-nginx" && [[ "$site_type" = "laravel" ]] \
    && issues+=("HTTPS 无响应或超时：Laravel 探测为 GET /up（已放宽至 25s）；多为 php-fpm 卡住或池占满，见上方本站 error 与 fpm-slow.log；另查 storage/logs/laravel.log、MySQL/Redis")
  [[ "$code_https" = "000" ]] && container_ok "lnmp-nginx" && [[ "$site_type" != "laravel" ]] \
    && issues+=("HTTPS 无响应：检查 443、证书路径及 lnmp-nginx 内 /etc/nginx/ssl/${d}/")
  [[ "$code_https" = "502" ]] && [[ "$site_type" = "laravel" ]] && issues+=("502：多为 php-fpm 异常，查看下方 Nginx error.log 中 upstream/fastcgi 报错")
  [[ "$code_https" = "404" ]] && [[ "$site_type" = "frontend" ]] && issues+=("404：确认构建产物在 ${WWW_ROOT}/${d}${fe_sub:+/}${fe_sub} 且含 index.html")
  [[ "$code_https" = "404" ]] && [[ "$site_type" = "laravel" ]] && issues+=("404：确认 ${WWW_ROOT}/${d}/public 存在且含 index.php")
  if [[ ${#issues[@]} -gt 0 ]]; then
    echo ""
    info "可能原因（按项排查）:"
    local x
    for x in "${issues[@]}"; do
      echo "    - $x"
    done
  fi
}

cmd_status() {
  if [[ "${STATUS_ALL:-0}" -ne 1 && -z "${DOMAIN:-}" && -t 0 ]]; then
    local -a _doms=()
    while IFS= read -r d; do _doms+=("$d"); done < <(_list_deployed_domains)
    if [[ ${#_doms[@]} -eq 0 ]]; then
      STATUS_ALL=1
    else
      local _items=("全部站点（简略概览）" "${_doms[@]}")
      local _i; _i=$(menu_select "选择要查看状态的站点" "${_items[@]}")
      if [[ "$_i" -eq 0 ]]; then
        STATUS_ALL=1; DOMAIN=""
      else
        DOMAIN="${_doms[$((_i - 1))]}"
      fi
    fi
  fi
  [[ "${STATUS_ALL:-0}" -ne 1 && -z "$DOMAIN" ]] && STATUS_ALL=1

  echo ""
  hr; info "运行环境（Docker）"; echo ""
  local c _st
  local _stack=(lnmp-nginx lnmp-php lnmp-redis lnmp-mysql)
  while IFS= read -r c; do
    [[ -z "$c" || "$c" = "lnmp-php" ]] && continue
    _stack+=("$c")
  done < <(_iter_php_containers)
  for c in "${_stack[@]}"; do
    if container_ok "$c"; then
      _st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "?")
      ok "${c}: ${_st}"
    else
      warn "${c}: 未运行"
    fi
  done

  if ! container_ok "lnmp-nginx"; then
    echo ""
    warn "lnmp-nginx 未运行，无法在本机 curl 检测站点；请先启动 LNMP 栈"
    echo ""
    return 0
  fi

  echo ""
  info "Nginx 配置校验:"
  docker exec lnmp-nginx nginx -t 2>&1 | sed 's/^/  /' || true

  local _domains=()
  if [[ "${STATUS_ALL:-0}" -eq 1 ]]; then
    local conf
    for conf in "${NGINX_CONF}"/*.conf; do
      [[ -f "$conf" ]] || continue
      local bn
      bn=$(basename "$conf" .conf)
      [[ "$bn" = "default" ]] && continue
      _domains+=("$bn")
    done
    [[ ${#_domains[@]} -eq 0 ]] && die "未在 ${NGINX_CONF} 发现站点配置"
  else
    _domains=("$DOMAIN")
  fi

  local dom
  for dom in "${_domains[@]}"; do
    echo ""
    hr; info "站点: ${dom}"; echo ""

    local site_dir="${WWW_ROOT}/${dom}"
    local site_type="laravel"
    [[ -f "${site_dir}/artisan" ]] || site_type="frontend"
    local fe_sub="" doc_host code_http code_https
    if [[ "$site_type" = "frontend" ]]; then
      fe_sub=$(effective_frontend_subdir "$dom")
      doc_host="${site_dir}${fe_sub:+/}${fe_sub}"
    else
      doc_host="${site_dir}/public"
    fi

    if [[ -f "${NGINX_CONF}/${dom}.conf" ]]; then
      ok "Nginx 配置: ${NGINX_CONF}/${dom}.conf"
    else
      warn "缺少 Nginx 配置: ${NGINX_CONF}/${dom}.conf"
    fi

    if [[ -d "$site_dir" ]]; then
      ok "代码目录: ${site_dir}（类型: ${site_type}）"
    else
      warn "代码目录不存在: ${site_dir}"
    fi

    if [[ "$site_type" = "laravel" ]]; then
      [[ -f "${site_dir}/public/index.php" ]] && ok "Laravel public/index.php 存在" || warn "缺少 public/index.php"
    else
      [[ -f "${doc_host}/index.html" ]] && ok "前端 index.html: ${doc_host}/index.html" || warn "缺少 index.html（文档根: ${doc_host}）"
    fi

    local cert="${SSL_DIR}/${dom}/fullchain.cer"
    if [[ -f "$cert" ]] && command -v openssl &>/dev/null; then
      info "证书 notAfter: $(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
    elif [[ -f "$cert" ]]; then
      ok "证书文件存在: ${cert}"
    else
      warn "未找到证书: ${cert}"
    fi

    local _probe_path
    _probe_path="$(_status_probe_path_for_site "$dom" "$site_type")"
    code_http=$(_status_http_code "$dom" 0 "$site_type" "$_probe_path")
    code_https=$(_status_http_code "$dom" 1 "$site_type" "$_probe_path")
    info "本机探测（127.0.0.1 + --resolve，路径: ${_probe_path}） HTTP=${code_http}  HTTPS=${code_https}"
    [[ "$code_http" =~ ^(301|302|307|308|200)$ ]] || [[ "$code_http" = "000" ]] || warn "HTTP 状态非预期（常见为 301 跳转 HTTPS）"
    [[ "$code_https" =~ ^(200|301|302|304|403|404|500|502|503)$ ]] || warn "HTTPS 状态: ${code_https}"

    if [[ "${STATUS_ALL:-0}" -ne 1 ]] && [[ "$site_type" = "laravel" ]] \
      && { [[ "$code_https" = "000" ]] || [[ "$code_https" = "502" ]] || [[ "$code_https" = "504" ]]; }; then
      _status_laravel_fpm_tail_hints "$dom"
    fi

    if container_ok "lnmp-nginx"; then
      echo ""
      info "容器内可读性（uid 101 = nginx）:"
      if [[ "$site_type" = "laravel" ]]; then
        docker exec lnmp-nginx sh -c "test -r '${CONTAINER_WWW}/${dom}/public/index.php'" 2>/dev/null && ok "可读 public/index.php" || warn "不可读 public/index.php（权限/属主，可执行: $0 update --domain=${dom}）"
      else
        docker exec lnmp-nginx sh -c "test -r '${CONTAINER_WWW}/${dom}${fe_sub:+/}${fe_sub}/index.html'" 2>/dev/null && ok "可读 index.html" || warn "不可读 index.html（文档根同上，可 update 修复权限）"
      fi
    fi

    if [[ "$site_type" = "laravel" ]]; then
      local _scn _sver _ssub
      _scn="$(_php_container_for_site "$dom")"
      _sver="$(_php_ver_for_site "$dom")"
      if container_ok "$_scn"; then
        echo ""
        info "Laravel / PHP（容器: ${_scn}${_sver:+，版本声明 ${_sver}}）:"
        if docker exec -u "$(id -u "${DEVOPS_USER}")":"$(id -g "${DEVOPS_USER}")" -w "${CONTAINER_WWW}/${dom}" "$_scn" php artisan --version &>/dev/null; then
          docker exec -u "$(id -u "${DEVOPS_USER}")":"$(id -g "${DEVOPS_USER}")" -w "${CONTAINER_WWW}/${dom}" "$_scn" php artisan --version 2>&1 | sed 's/^/  /'
        else
          warn "artisan 执行失败（依赖、.env、权限等，查看完整错误请手动: docker exec -u ... ${_scn} ... php artisan --version）"
        fi
        if [[ "$_scn" = "lnmp-php" ]]; then _ssub="php"; else _ssub="php-${_scn#lnmp-php-}"; fi
        [[ -d "${DATA_DIR}/${_ssub}/log" ]] && info "php-fpm 慢日志（宿主机）: ${DATA_DIR}/${_ssub}/log/fpm-slow.log"
      else
        warn "${_scn} 未运行（站点声明 PHP ${_sver:-默认}），FastCGI 不可达将 502"
      fi
    fi

    echo ""
    info "lnmp-nginx 最近错误日志（全局，不仅本站）:"
    docker exec lnmp-nginx sh -c 'tail -n 25 /var/log/nginx/error.log 2>/dev/null' 2>/dev/null | sed 's/^/  /' || warn "无法读取容器内 error.log"

    if [[ "${STATUS_ALL:-0}" -ne 1 ]]; then
      _status_print_hints "$dom" "$code_http" "$code_https" "$site_type" "$fe_sub"
    fi
  done

  if [[ "${STATUS_ALL:-0}" -eq 1 ]]; then
    echo ""
    info "单站详细诊断与「可能原因」说明请执行: $0 status --domain=<域名>"
  fi
  echo ""
}

# ═══════════════════════════════════════════════
#  子命令: list
# ═══════════════════════════════════════════════
cmd_list() {
  echo ""
  hr; info "已部署站点"; hr; echo ""

  local found=0
  for conf in "${NGINX_CONF}"/*.conf; do
    [[ -f "$conf" ]] || continue
    local name
    name=$(basename "$conf" .conf)
    [[ "$name" = "default" ]] && continue

    found=1
    local type="unknown" status="无代码"
    local site_dir="${WWW_ROOT}/${name}"

    if [[ -f "${site_dir}/artisan" ]]; then
      type="laravel"
    elif [[ -d "${site_dir}" ]]; then
      type="frontend"
    fi

    if [[ -d "${site_dir}/.git" ]] || [[ -f "${site_dir}/artisan" ]] \
      || { [[ -d "${site_dir}" ]] && [[ -n "$(ls -A "${site_dir}" 2>/dev/null)" ]]; }; then
      status="已部署"
    fi

    local ssl="无"
    [[ -f "${SSL_DIR}/${name}/fullchain.cer" ]] && ssl="有"

    local cron="无" _cr_out
    _cr_out=$(crontab -u "${DEVOPS_USER}" -l 2>/dev/null || true)
    if echo "$_cr_out" | grep -qF "${WWW_ROOT}/${name}/storage/logs/cron.log" \
      || echo "$_cr_out" | grep -qF "${CONTAINER_WWW}/${name}/artisan"; then
      cron="有"
    fi

    local php_v="default" _vv lv_v="-"
    _vv="$(_php_ver_for_site "$name")"
    [[ -n "$_vv" ]] && php_v="$_vv"
    if [[ "$type" = "laravel" ]]; then
      local _lvv; _lvv="$(_laravel_min_for_site "$name")"
      [[ -n "$_lvv" ]] && lv_v="$_lvv"
    fi
    printf "  %-30s 类型:%-10s Laravel:%-6s PHP:%-8s 状态:%-8s SSL:%-4s Cron:%-4s\n" \
      "$name" "$type" "$lv_v" "$php_v" "$status" "$ssl" "$cron"
  done

  [[ $found -eq 0 ]] && info "暂无站点"
  echo ""
}

# ═══════════════════════════════════════════════
#  子命令: ssl
# ═══════════════════════════════════════════════
cmd_ssl() {
  prompt_pick_domain "选择要签发/续期的站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  local site_dir="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$site_dir" ]] || die "站点 ${DOMAIN} 不存在"

  local site_type="laravel"
  [[ -f "${site_dir}/artisan" ]] || site_type="frontend"

  container_ok "lnmp-acme" || die "lnmp-acme 未运行"

  _collect_ssl_dns_interactive
  SSL_DNS="${SSL_DNS:-${ACME_SSL_DNS_DEFAULT:-webroot}}"
  case "$SSL_DNS" in
    webroot|dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) ;;
    *) die "无效 SSL 模式: ${SSL_DNS}" ;;
  esac
  _collect_ssl_dns_creds_interactive
  if _is_dns_mode "$SSL_DNS"; then
    _acme_ssl_validate_dns_creds "$SSL_DNS"
  fi

  echo ""
  hr; info "SSL 续期/签发: ${DOMAIN}"; echo ""
  local _fe_ssl="dist"
  [[ "$site_type" = "frontend" ]] && _fe_ssl=$(effective_frontend_subdir "$DOMAIN")
  issue_ssl "$DOMAIN" "$site_type" "${SSL_DNS}" "${FORCE_SSL:-}" "$_fe_ssl"
}

# ═══════════════════════════════════════════════
#  用法说明
# ═══════════════════════════════════════════════
usage() {
  cat <<EOF
用法: $0 <命令> [选项]

命令:
  add       部署新站点（无参数进入交互模式）
  update    更新已有站点（有 .git 则 pull；Laravel：composer、migrate、optimize、Horizon）
  remove    移除站点（Nginx、SSL、crontab、Horizon、代码）
  list      列出已部署站点
  status    站点运行状态（本机 curl、容器、证书、日志；可加 --all）
  ssl       SSL 证书签发/续期

选项:
  --domain=域名         站点域名
  --sse-prefixes=列表   Laravel SSE：写入 ${NGINX_CONF}/<域名>.sse-prefixes（与 update 同用时跳过交互提示）。路径可含 {id} 自动生成正则；或 wave、~^/… 等。留空=删站点文件用全局
  环境变量 LARAVEL_SSE_PREFIXES  无 per-site 文件时的默认（空格/逗号分隔，规则同上）[默认: wave]
  --git=地址            Git 仓库地址（留空或省略=跳过 clone/pull）
  --git-branch=名称     clone/pull 使用的分支或标签（留空=默认分支；无 --git 时忽略）
  --type=laravel|frontend  站点类型 [默认: laravel]
  --php-version=主版本   站点 PHP 版本（如 8.2 / 7.4），需在 init.sh 的 EXTRA_PHP_VERSIONS 中已声明；留空或 - = 走默认 lnmp-php
                       写入 ${NGINX_CONF}/<域名>.php-version；nginx fastcgi 与 composer/artisan/cron/horizon 自动路由到对应容器
  --app-name=名称       APP_NAME [Laravel]
  --redis-host=         REDIS_HOST [redis]
  --redis-port=         REDIS_PORT [6379]
  --redis-password=     REDIS_PASSWORD；留空: --redis-password= 或 --redis-password 下一参数为另一选项
  --need-db=y|n         是否配置数据库 [y]
  --db-host=            DB_HOST [mysql]
  --db-name=            DB_DATABASE
  --db-password=        DB_PASSWORD
  --create-db=y|n       自动建库 [y]
  --run-migrate=y|n     执行 migrate [y]；update 时指定则可不交互（建议自动化加 --run-migrate=y 或 n）
  --run-seed=y|n        执行 db:seed [y]
  --add-crontab=y|n     添加定时任务 [y]
  --need-horizon=y|n    使用 Horizon [y]
  --frontend-root=      前端子目录（相对站点目录；留空则：存在 dist/→dist，否则→站点根）
  --env=KEY=VALUE       自定义 ENV（可多次）
  --dns=MODE            SSL: webroot | dns_cf | dns_ali | dns_dp | dns_gd | dns_aws | dns_tencent [webroot]
  --cf-token=           dns_cf: Cloudflare API Token
  --ali-key= --ali-secret=   dns_ali: 阿里云 DNS (acme.sh Ali_Key / Ali_Secret)
  --dp-id= --dp-key=         dns_dp: DNSPod (DP_Id / DP_Key)
  --gd-key= --gd-secret=     dns_gd: GoDaddy
  --aws-access-key= --aws-secret-key=  dns_aws: Route53
  --tencent-secret-id= --tencent-secret-key=  dns_tencent: 腾讯云 DNSPod API
  --force-ssl           强制重新签发证书
  --ssl-staging         使用 LE 测试 CA（规避正式限流/调试，浏览器不信任）
  --yes                 跳过确认（remove 时）
  --all                 status：检查 conf.d 中全部站点（简略；详单用 --domain）

示例:
  $0 add --domain=api.example.com --git=git@gitee.com:user/repo.git --git-branch=develop --need-db=y --db-name=app --db-password=secret
  $0 update --domain=api.example.com
  $0 update --domain=api.example.com --run-migrate=n   # 不询问、不执行 migrate
  $0 remove --domain=api.example.com
  $0 list
  $0 status --domain=api.example.com
  $0 status --all
  $0 ssl --domain=api.example.com --force-ssl
  $0 add --domain=test.example.com --git=... --ssl-staging   # 测试证书
  $0 add --domain=x.com --git=... --dns=dns_ali --ali-key=AK --ali-secret=SK
  $0 add --domain=x.com --git=   # 或省略 --git，配合事先放入 ${DATA_DIR:-/data/docker-lnmp}/www/x.com
  $0 add --domain=legacy.com --git=... --php-version=7.4   # 该站使用 lnmp-php-74
  $0 update --domain=api.example.com --php-version=8.2     # 切到 lnmp-php-82
EOF
}

# ═══════════════════════════════════════════════
#  主入口
# ═══════════════════════════════════════════════
main() {
  local cmd="${1:-}"

  case "$cmd" in
    -h|--help) usage; exit 0 ;;
    add)    shift; parse_args "$@"; cmd_add ;;
    update) shift; parse_args "$@"; cmd_update ;;
    remove) shift; parse_args "$@"; cmd_remove ;;
    list)   cmd_list ;;
    status) shift; parse_args "$@"; cmd_status ;;
    ssl)    shift; parse_args "$@"; cmd_ssl ;;
    "")
      clear 2>/dev/null || true
      while true; do
        hr
        printf "  多站点部署管理 v%s\n" "${VERSION}"
        hr
        local _idx
        _idx=$(menu_select "请选择操作" \
          "查看站点列表（推荐先看一眼）" \
          "部署新站点" \
          "更新站点" \
          "站点运行状态（含证书 / FPM / nginx 日志）" \
          "SSL 证书签发/续期" \
          "移除站点" \
          "退出")
        echo ""
        case "$_idx" in
          0) cmd_list ;;
          1) cmd_add ;;
          2) cmd_update ;;
          3) STATUS_ALL=0; DOMAIN=""; cmd_status ;;
          4) cmd_ssl ;;
          5) cmd_remove ;;
          6) ok "再见"; exit 0 ;;
        esac
        echo ""
        if ! confirm "返回主菜单？" "y"; then
          ok "再见"; exit 0
        fi
        clear 2>/dev/null || true
      done
      ;;
    *)
      usage; die "未知命令: $cmd"
      ;;
  esac
}

main "$@"
