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

env_set() {
  local key="$1" val="$2" envfile="$3"
  local escaped_val
  escaped_val=$(printf '%s' "$val" | sed 's/[\\&|]/\\&/g')
  if grep -q "^${key}=" "$envfile" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${escaped_val}|" "$envfile"
  else
    echo "${key}=${val}" >> "$envfile"
  fi
}

container_ok() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"; }

ensure_php_fpm_slowlog_host_artifacts() {
  [[ -d "${DATA_DIR}/php" ]] || return 0
  mkdir -p "${DATA_DIR}/php/fpm.d" "${DATA_DIR}/php/log"
  if [[ ! -f "${DATA_DIR}/php/fpm.d/zz-slowlog.conf" ]]; then
    cat > "${DATA_DIR}/php/fpm.d/zz-slowlog.conf" <<'FPMCONF'
; 与官方镜像 [www] 池合并（zz- 保证在 www.conf、zz-docker 之后加载）
[www]
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
  if [[ ! -f "$_wpf" ]]; then
    cat > "$_wpf" <<'FPMCONF'
; SSE 专用池；Nginx fastcgi_pass php:9001；须监听 0.0.0.0 以便跨容器访问
; 可按内存调整 pm.max_children（每个长连接占 1 worker）
[wave]
user = www-data
group = www-data
listen = 0.0.0.0:9001
pm = dynamic
pm.max_children = 50
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 8
request_terminate_timeout = 0
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
  docker exec -u "$(id -u "${DEVOPS_USER}")":"$(id -g "${DEVOPS_USER}")" -w "${CONTAINER_WWW}/${domain}" lnmp-php \
    php artisan "$@"
}

ensure_composer_in_lnmp_php() {
  container_ok "lnmp-php" || die "lnmp-php 容器未运行"
  if docker exec lnmp-php sh -c 'command -v composer >/dev/null 2>&1'; then
    return 0
  fi
  info "在 lnmp-php 内安装 Composer..."
  docker exec -u root lnmp-php sh -c \
    '(curl -fsSL https://getcomposer.org/installer 2>/dev/null || wget -qO- https://getcomposer.org/installer) | php -- --install-dir=/usr/local/bin --filename=composer' \
    || die "lnmp-php 内安装 Composer 失败"
  docker exec -u root lnmp-php chmod 755 /usr/local/bin/composer 2>/dev/null || true
}

_php_ext_apk_retry_exec() {
  local inner="$1"
  local attempt=1 max=12 pause=5
  sleep 2
  while ((attempt <= max)); do
    if docker exec -u root -e TERM=dumb lnmp-php sh -c "$inner"; then
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
  container_ok "lnmp-php" || die "lnmp-php 容器未运行"
  if docker exec lnmp-php php -r 'foreach (["bcmath","pcntl","gd","zip"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null; then
    return 0
  fi
  info "尝试启用已编译的 PHP 扩展 (docker-php-ext-enable)..."
  docker exec -u root lnmp-php sh -c \
    'for e in bcmath pcntl zip gd pdo_mysql mysqli opcache dom mbstring curl xml intl fileinfo exif sockets; do docker-php-ext-enable "$e" 2>/dev/null || true; done'
  if docker exec lnmp-php php -r 'foreach (["bcmath","pcntl","gd","zip"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null; then
    ok "PHP 扩展已可用"
    docker restart lnmp-php
    wait_container_running "lnmp-php" 45
    return 0
  fi
  info "在 lnmp-php 内编译安装扩展（与 init.sh 默认一致，无 redis PECL）..."
  [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
  local alpine_sed=""
  [[ -n "${ALPINE_MIRROR:-}" ]] && alpine_sed="sed -i 's|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g' /etc/apk/repositories && apk update && "
  local apk_deps="libpng-dev libwebp-dev freetype-dev libjpeg-turbo-dev libxml2-dev curl-dev build-base linux-headers autoconf libzip-dev icu-dev oniguruma-dev"
  local cmd="${alpine_sed}apk add --no-cache ${apk_deps}"
  cmd+=" && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp"
  cmd+=" && docker-php-ext-configure intl"
  cmd+=" && docker-php-ext-install -j\$(nproc) pdo_mysql opcache mysqli curl gd xml dom pcntl bcmath sockets mbstring zip exif intl fileinfo"
  cmd+=" && apk del --no-cache build-base linux-headers autoconf"
  cmd="sleep 2; ${cmd}"
  _php_ext_apk_retry_exec "$cmd" \
    || die "PHP 扩展安装失败，请在主机执行 init.sh「更新配置 → PHP 扩展」或 docker restart lnmp-php 后重试"
  docker restart lnmp-php
  wait_container_running "lnmp-php" 45
  docker exec lnmp-php php -r 'foreach (["bcmath","pcntl","gd","zip"] as $e) { if (!extension_loaded($e)) exit(1); } exit(0);' 2>/dev/null \
    || die "bcmath/pcntl/gd/zip 仍未加载，请检查 lnmp-php 或重新部署 PHP 容器"
  ok "PHP 扩展就绪"
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
    [[ "$s" == *'{'*'}"'* ]] || return 1
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

# update：展示当前 SSE 规则并可选修改（未传 --sse-prefixes 且 stdin 为 TTY 时）
interactive_sse_prefixes_maybe_for_update() {
  local domain="$1"
  [[ -t 0 ]] || return 0
  [[ "${SITE_SSE_PREFIXES_CLI:-0}" -eq 1 ]] && return 0

  local f="${NGINX_CONF}/${domain}.sse-prefixes"
  echo ""
  info "SSE（Wave 等长连接）走 php:9001；规则来自 ${f} 或全局 LARAVEL_SSE_PREFIXES"
  if [[ -f "$f" ]]; then
    info "当前：站点专属文件（${f}）"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      echo "      ${line}"
    done < "$f"
  else
    info "当前：无站点专属文件 → 全局 LARAVEL_SSE_PREFIXES=${LARAVEL_SSE_PREFIXES:-wave}"
  fi
  local cur_resolved cur_one
  cur_resolved=$(_laravel_sse_prefixes_resolve "$domain")
  cur_one=$(printf '%s' "$cur_resolved" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  info "合并解析后（单行）: ${cur_one}"

  if ! confirm "是否修改 SSE 路径规则？" "n"; then
    return 0
  fi

  local newv
  newv=$(prompt "新规则（空格/逗号分隔；仅输入 - 表示删站点文件、改用全局）" "$cur_one")
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

  _laravel_sse_append_upstream_block() {
    local _hdr="$1"
    out+="${_hdr}"$'\n'
    out+='        gzip                 off;
        include              fastcgi_params;
        fastcgi_pass         php:9001;
        fastcgi_index        index.php;
        fastcgi_param        SCRIPT_FILENAME \$document_root/index.php;
        fastcgi_param        DOCUMENT_ROOT \$document_root;
        fastcgi_read_timeout 86400;
        fastcgi_buffering    off;
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
    elif [[ "$_tok" == *'{'*'}"'* ]]; then
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

  if [[ "$raw" == *$'\n'* ]]; then
    while IFS= read -r _p || [[ -n "$_p" ]]; do
      _laravel_sse_handle_one_pattern "$_p"
    done <<< "$raw"
  else
    read -ra parts <<< "$(printf '%s' "$raw" | tr ',' ' ')"
    for _p in "${parts[@]}"; do
      _laravel_sse_handle_one_pattern "$_p"
    done
  fi

  printf '%s' "$out"
}

gen_nginx_laravel() {
  local domain="$1"
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

$(_nginx_laravel_sse_location_blocks "$(_laravel_sse_prefixes_resolve "$domain")")
    location ~ \.php\$ {
        fastcgi_pass         php:9000;
        fastcgi_index        index.php;
        fastcgi_param        SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include              fastcgi_params;
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

    location / {
        try_files \$uri \$uri/ /index.html;
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
  if [[ "$ssl_dns" = dns_cf || "$ssl_dns" = dns_ali || "$ssl_dns" = dns_dp || "$ssl_dns" = dns_gd || "$ssl_dns" = dns_aws || "$ssl_dns" = dns_tencent ]]; then
    _acme_ssl_validate_dns_creds "$ssl_dns"
    case "$ssl_dns" in
      dns_cf)
        docker exec -e CF_Token="${CF_TOKEN}" lnmp-acme \
          acme.sh --issue -d "${domain}" \
          --config-home /acme.sh \
          --dns dns_cf --keylength ec-256 --server "${acme_ca}" \
          ${force} || acme_exit=$?
        ;;
      dns_ali)
        docker exec -e Ali_Key="${ALI_KEY}" -e Ali_Secret="${ALI_SECRET}" lnmp-acme \
          acme.sh --issue -d "${domain}" \
          --config-home /acme.sh \
          --dns dns_ali --keylength ec-256 --server "${acme_ca}" \
          ${force} || acme_exit=$?
        ;;
      dns_dp)
        docker exec -e DP_Id="${DP_ID}" -e DP_Key="${DP_KEY}" lnmp-acme \
          acme.sh --issue -d "${domain}" \
          --config-home /acme.sh \
          --dns dns_dp --keylength ec-256 --server "${acme_ca}" \
          ${force} || acme_exit=$?
        ;;
      dns_gd)
        docker exec -e GD_Key="${GD_KEY}" -e GD_Secret="${GD_SECRET}" lnmp-acme \
          acme.sh --issue -d "${domain}" \
          --config-home /acme.sh \
          --dns dns_gd --keylength ec-256 --server "${acme_ca}" \
          ${force} || acme_exit=$?
        ;;
      dns_aws)
        docker exec -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" lnmp-acme \
          acme.sh --issue -d "${domain}" \
          --config-home /acme.sh \
          --dns dns_aws --keylength ec-256 --server "${acme_ca}" \
          ${force} || acme_exit=$?
        ;;
      dns_tencent)
        docker exec -e Tencent_SecretId="${TENCENT_SECRET_ID}" -e Tencent_SecretKey="${TENCENT_SECRET_KEY}" lnmp-acme \
          acme.sh --issue -d "${domain}" \
          --config-home /acme.sh \
          --dns dns_tencent --keylength ec-256 --server "${acme_ca}" \
          ${force} || acme_exit=$?
        ;;
    esac
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
    chown "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}"
    info "Git 地址为空，已跳过 clone/pull；请确保代码已在 ${site_dir}"
    local _dc_st="laravel" _dc_fe=""
    [[ -f "${site_dir}/artisan" ]] || _dc_st="frontend"
    [[ "$_dc_st" = "frontend" ]] && _dc_fe=$(effective_frontend_subdir "$domain")
    fix_site_readable_for_nginx "$domain" "$_dc_st" "$_dc_fe"
    return 0
  fi

  local ssh_key="/home/${DEVOPS_USER}/.ssh/id_ed25519"
  [[ ! -f "$ssh_key" ]] && ssh_key="/home/${DEVOPS_USER}/.ssh/id_rsa"
  local git_ssh="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  [[ -f "$ssh_key" ]] && git_ssh="ssh -i ${ssh_key} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

  git config --global --add safe.directory "${site_dir}" 2>/dev/null || true
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
  else
    if [[ -n "$git_branch" ]]; then
      info "首次 clone（分支: ${git_branch}）..."
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; git clone -b '${git_branch}' --single-branch '${git_repo}' '${site_dir}'" \
        || die "git clone 失败，请检查分支名与 SSH Key"
    else
      info "首次 clone..."
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; git clone '${git_repo}' '${site_dir}'" \
        || die "git clone 失败，请检查 SSH Key"
    fi
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

  env_set "APP_NAME"         "${APP_NAME}"     "$envfile"
  env_set "APP_ENV"          "production"       "$envfile"
  env_set "APP_DEBUG"        "false"            "$envfile"
  env_set "APP_URL"          "https://${domain}" "$envfile"
  env_set "REDIS_HOST"       "${REDIS_HOST}"    "$envfile"
  env_set "REDIS_PORT"       "${REDIS_PORT}"    "$envfile"
  env_set "REDIS_PASSWORD"   "${REDIS_PASSWORD}" "$envfile"
  env_set "QUEUE_CONNECTION" "${queue_conn}"    "$envfile"
  env_set "SESSION_DRIVER"   "redis"            "$envfile"
  env_set "CACHE_STORE"      "redis"            "$envfile"
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

  info "composer install..."
  local uid gid
  uid=$(id -u "${DEVOPS_USER}")
  gid=$(id -g "${DEVOPS_USER}")

  ensure_lnmp_php_laravel_extensions
  ensure_composer_in_lnmp_php
  docker exec -u "${uid}:${gid}" lnmp-php \
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

  info "artisan optimize..."
  docker_php_artisan "$domain" optimize

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
  local uid gid cron_log
  uid=$(id -u "${DEVOPS_USER}")
  gid=$(id -g "${DEVOPS_USER}")
  cron_log="${WWW_ROOT}/${domain}/storage/logs/cron.log"
  local cron_cmd="* * * * * docker exec -u ${uid}:${gid} -w \"${CONTAINER_WWW}/${domain}\" lnmp-php php artisan schedule:run >> ${cron_log} 2>&1"
  local existing filtered
  existing=$(crontab -u "${DEVOPS_USER}" -l 2>/dev/null || true)
  filtered=$(printf '%s\n' "$existing" | grep -vF "${cron_log}" || true)
  filtered=$(printf '%s\n' "$filtered" | grep -vE "docker exec lnmp-php php [^[:space:]]*/${domain}/artisan schedule:run" || true)
  { printf '%s\n' "$filtered" | grep -v '^$' || true; echo "$cron_cmd"; } | crontab -u "${DEVOPS_USER}" -
  ok "schedule:run crontab 已更新"
}

setup_horizon() {
  local domain="$1"
  local sup_path
  if ! sup_path=$(horizon_supervisor_conf_path "$domain"); then
    sup_path=$(horizon_supervisor_conf_write_path "$domain")
  fi
  mkdir -p "$(dirname "$sup_path")"

  local _hu _hg
  _hu=$(id -u "${DEVOPS_USER}")
  _hg=$(id -g "${DEVOPS_USER}")
  cat > "$sup_path" <<HORIZON
[program:laravel-horizon-${domain}]
command=docker exec -u ${_hu}:${_hg} -w "${CONTAINER_WWW}/${domain}" lnmp-php php artisan horizon
process_name=%(program_name)s
autostart=true
autorestart=true
user=root
numprocs=1
redirect_stderr=true
stdout_logfile=${WWW_ROOT}/${domain}/storage/logs/horizon.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stopwaitsecs=3600
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

collect_interactive() {
  [[ -z "$DOMAIN" ]]   && DOMAIN=$(prompt "站点域名 (如 app.com)")
  [[ -z "$GIT_REPO" ]] && GIT_REPO=$(prompt "Git 仓库地址（留空=跳过 Git）" "")
  if [[ -n "$GIT_REPO" ]]; then
    [[ -z "$GIT_BRANCH" ]] && GIT_BRANCH=$(prompt "Git 分支（留空=仓库默认）" "")
  else
    GIT_BRANCH=""
  fi
  if [[ -z "$SITE_TYPE" ]]; then
    SITE_TYPE=$(prompt "站点类型 (laravel/frontend)" "laravel")
  fi
  SITE_TYPE=${SITE_TYPE:-laravel}
  [[ "$SITE_TYPE" != "laravel" && "$SITE_TYPE" != "frontend" ]] && SITE_TYPE="laravel"

  [[ -z "$DOMAIN" ]]   && die "域名不能为空"

  if [[ "$SITE_TYPE" = "laravel" ]]; then
    APP_NAME=${APP_NAME:-$(prompt "APP_NAME" "Laravel")}
    REDIS_HOST=${REDIS_HOST:-$(prompt "REDIS_HOST" "redis")}
    REDIS_PORT=${REDIS_PORT:-$(prompt "REDIS_PORT" "6379")}
    if [[ "$REDIS_PASSWORD_FROM_CLI" != "1" && -z "${REDIS_PASSWORD:-}" ]]; then
      prompt_secret_into "REDIS_PASSWORD (留空=无)" REDIS_PASSWORD
    fi

    [[ -z "$NEED_DB" ]] && { confirm "配置数据库？" "y" && NEED_DB="y" || NEED_DB="n"; }
    if [[ "$NEED_DB" = "y" ]]; then
      DB_HOST=${DB_HOST:-$(prompt "DB_HOST" "mysql")}
      [[ -z "$DB_NAME" ]] && DB_NAME=$(prompt "DB_DATABASE")
      [[ -z "$DB_NAME" ]] && die "DB_DATABASE 不能为空"
      [[ "$DB_PWD_FROM_CLI" != "1" && -z "$DB_PWD" ]] && prompt_secret_into "DB_PASSWORD" DB_PWD
      [[ -z "$DB_PWD" ]]  && die "DB_PASSWORD 不能为空"
      [[ -z "$CREATE_DB" ]]   && { confirm "自动创建数据库？" "y" && CREATE_DB="y" || CREATE_DB="n"; }
      [[ -z "$RUN_MIGRATE" ]] && { confirm "执行 migrate？" "y" && RUN_MIGRATE="y" || RUN_MIGRATE="n"; }
      [[ "$RUN_MIGRATE" = "y" && -z "$RUN_SEED" ]] && { confirm "执行 db:seed？" "y" && RUN_SEED="y" || RUN_SEED="n"; }
      RUN_SEED=${RUN_SEED:-y}
    fi

    if [[ ${#CUSTOM_ENV[@]} -eq 0 ]]; then
      echo ""
      info "自定义 ENV（KEY 留空结束）"
      while true; do
        local key val
        key=$(prompt "KEY")
        [[ -z "$key" ]] && break
        val=$(prompt "VALUE")
        CUSTOM_ENV+=("${key}=${val}")
      done
    fi

    [[ -z "$ADD_CRONTAB" ]]  && { confirm "添加定时任务？" "y" && ADD_CRONTAB="y" || ADD_CRONTAB="n"; }
    [[ -z "$NEED_HORIZON" ]] && { confirm "使用 Horizon？" "y" && NEED_HORIZON="y" || NEED_HORIZON="n"; }
  else
    FRONTEND_ROOT=$(prompt "前端子目录（相对站点目录，留空则：有 dist 目录→dist，否则→站点根）" "${FRONTEND_ROOT:-}")
  fi

  [[ -z "$SSL_DNS" ]] && SSL_DNS=$(prompt "SSL 校验方式 (webroot/dns_cf/dns_ali/dns_dp/dns_gd/dns_aws/dns_tencent)" "${ACME_SSL_DNS_DEFAULT:-webroot}")
  SSL_DNS="${SSL_DNS:-webroot}"
  case "$SSL_DNS" in
    webroot|dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) ;;
    *) die "无效 SSL 模式: ${SSL_DNS}（webroot / dns_cf / dns_ali / dns_dp / dns_gd / dns_aws / dns_tencent）" ;;
  esac
  _collect_ssl_dns_creds_interactive
  if [[ "$SSL_DNS" = dns_cf || "$SSL_DNS" = dns_ali || "$SSL_DNS" = dns_dp || "$SSL_DNS" = dns_gd || "$SSL_DNS" = dns_aws || "$SSL_DNS" = dns_tencent ]]; then
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

  collect_interactive

  if [[ "$SITE_TYPE" = "laravel" && "${NEED_DB:-y}" = "y" && -z "${DB_NAME:-}" ]]; then
    die "Laravel 默认启用数据库，请指定 --db-name 或在交互中填写 DB_DATABASE"
  fi

  ensure_placeholder_cert "$DOMAIN"
  normalize_nginx_cache_dir
  fix_nginx_main_pid_path
  normalize_nginx_conf_d
  normalize_nginx_ssl_trees

  echo ""
  hr; info "[1/6] Nginx 配置"; echo ""
  if [[ "$SITE_TYPE" = "laravel" ]]; then
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
  [[ -z "$DOMAIN" ]] && DOMAIN=$(prompt "站点域名")
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

  if [[ -d "${site_dir}/.git" ]]; then
    if [[ -n "${GIT_BRANCH:-}" ]]; then
      info "git 拉取（分支: ${GIT_BRANCH}）..."
    else
      info "git pull..."
    fi
    local ssh_key="/home/${DEVOPS_USER}/.ssh/id_ed25519"
    [[ ! -f "$ssh_key" ]] && ssh_key="/home/${DEVOPS_USER}/.ssh/id_rsa"
    local git_ssh="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    [[ -f "$ssh_key" ]] && git_ssh="ssh -i ${ssh_key} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    export GIT_SSH_COMMAND="$git_ssh"

    if [[ -n "${GIT_BRANCH:-}" ]]; then
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; cd '${site_dir}' && git fetch origin && git checkout '${GIT_BRANCH}' && git pull" \
        || die "git 更新失败（分支: ${GIT_BRANCH}）"
    else
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; cd '${site_dir}' && git pull" \
        || die "git pull 失败"
    fi
    ok "代码已更新"
  else
    warn "未检测到 .git，跳过 git pull（请事先将新版本同步到 ${site_dir}）"
  fi

  if [[ "$site_type" = "laravel" ]]; then
    info "composer install..."
    local uid gid
    uid=$(id -u "${DEVOPS_USER}")
    gid=$(id -g "${DEVOPS_USER}")
    ensure_lnmp_php_laravel_extensions
    ensure_composer_in_lnmp_php
    docker exec -u "${uid}:${gid}" lnmp-php \
      composer install \
      --working-dir="${CONTAINER_WWW}/${DOMAIN}" \
      --no-dev --no-interaction --optimize-autoloader --no-progress --prefer-dist

    chmod -R 775 "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    fix_site_readable_for_nginx "$DOMAIN" "laravel" ""

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

    info "artisan optimize..."
    docker_php_artisan "$DOMAIN" optimize

    local sup_conf=""
    sup_conf=$(horizon_supervisor_conf_path "$DOMAIN") || true
    if [[ -n "$sup_conf" ]] && supervisord_ready; then
      info "重启 Horizon..."
      supervisorctl restart "laravel-horizon-${DOMAIN}" &>/dev/null || true
    elif [[ -n "$sup_conf" ]] && command -v supervisorctl &>/dev/null; then
      warn "supervisord 未运行，跳过 Horizon 重启；启动后执行: supervisorctl restart laravel-horizon-${DOMAIN}"
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

  echo ""
  ok "站点 ${DOMAIN} 更新完成"
}

# ═══════════════════════════════════════════════
#  子命令: remove
# ═══════════════════════════════════════════════
cmd_remove() {
  [[ -z "$DOMAIN" ]] && DOMAIN=$(prompt "站点域名")
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  echo ""
  hr; info "移除站点: ${DOMAIN}"; echo ""

  [[ "${YES:-0}" -eq 0 ]] && ! confirm "确认删除 ${DOMAIN}？所有配置和数据将被移除" "n" && { info "已取消"; return; }

  rm -f "${NGINX_CONF}/${DOMAIN}.sse-prefixes" 2>/dev/null || true
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

# Laravel 用 /up 探活（避免纯 API 根路径 / 无路由或 FPM 长时间无响应导致误判）；前端用 /
_status_http_code() {
  local host="$1" use_https="$2" site_type="${3:-frontend}"
  local path="/" raw=""
  [[ "$site_type" = "laravel" ]] && path="/up"
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
  [[ ! -s "${DATA_DIR}/php/log/fpm-slow.log" ]] && return 0
  echo ""
  info "php-fpm 慢日志尾部（${DATA_DIR}/php/log/fpm-slow.log）:"
  tail -n 30 "${DATA_DIR}/php/log/fpm-slow.log" 2>/dev/null | sed 's/^/  /' || true
}

_status_print_hints() {
  local d="$1" code_http="$2" code_https="$3" site_type="$4" fe_sub="$5"
  local issues=()
  container_ok "lnmp-nginx" || issues+=("lnmp-nginx 未运行，本机 80/443 无服务")
  [[ "$site_type" = "laravel" ]] && ! container_ok "lnmp-php" && issues+=("lnmp-php 未运行，Laravel 将出现 502（FastCGI 不可达）")
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
  if [[ "${STATUS_ALL:-0}" -ne 1 ]]; then
    [[ -z "${DOMAIN:-}" ]] && DOMAIN=$(prompt "站点域名（留空=检查 conf.d 中全部站点）" "")
    [[ -z "$DOMAIN" ]] && STATUS_ALL=1
  fi

  echo ""
  hr; info "运行环境（Docker）"; echo ""
  local c _st
  for c in lnmp-nginx lnmp-php lnmp-redis lnmp-mysql; do
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

    local _probe_path="/"
    [[ "$site_type" = "laravel" ]] && _probe_path="/up"
    code_http=$(_status_http_code "$dom" 0 "$site_type")
    code_https=$(_status_http_code "$dom" 1 "$site_type")
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

    if [[ "$site_type" = "laravel" ]] && container_ok "lnmp-php"; then
      echo ""
      info "Laravel / PHP:"
      if docker exec -u "$(id -u "${DEVOPS_USER}")":"$(id -g "${DEVOPS_USER}")" -w "${CONTAINER_WWW}/${dom}" lnmp-php php artisan --version &>/dev/null; then
        docker exec -u "$(id -u "${DEVOPS_USER}")":"$(id -g "${DEVOPS_USER}")" -w "${CONTAINER_WWW}/${dom}" lnmp-php php artisan --version 2>&1 | sed 's/^/  /'
      else
        warn "artisan 执行失败（依赖、.env、权限等，查看完整错误请手动: docker exec -u ... lnmp-php ... php artisan --version）"
      fi
      [[ -d "${DATA_DIR}/php/log" ]] && info "php-fpm 慢日志（宿主机）: ${DATA_DIR}/php/log/fpm-slow.log"
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

    printf "  %-30s 类型:%-10s 状态:%-8s SSL:%-4s Cron:%-4s\n" \
      "$name" "$type" "$status" "$ssl" "$cron"
  done

  [[ $found -eq 0 ]] && info "暂无站点"
  echo ""
}

# ═══════════════════════════════════════════════
#  子命令: ssl
# ═══════════════════════════════════════════════
cmd_ssl() {
  [[ -z "$DOMAIN" ]] && DOMAIN=$(prompt "站点域名")
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  local site_dir="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$site_dir" ]] || die "站点 ${DOMAIN} 不存在"

  local site_type="laravel"
  [[ -f "${site_dir}/artisan" ]] || site_type="frontend"

  container_ok "lnmp-acme" || die "lnmp-acme 未运行"

  [[ -z "$SSL_DNS" ]] && SSL_DNS=$(prompt "SSL 校验方式 (webroot/dns_cf/dns_ali/dns_dp/dns_gd/dns_aws/dns_tencent)" "${ACME_SSL_DNS_DEFAULT:-webroot}")
  SSL_DNS="${SSL_DNS:-webroot}"
  case "$SSL_DNS" in
    webroot|dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) ;;
    *) die "无效 SSL 模式: ${SSL_DNS}" ;;
  esac
  _collect_ssl_dns_creds_interactive
  if [[ "$SSL_DNS" = dns_cf || "$SSL_DNS" = dns_ali || "$SSL_DNS" = dns_dp || "$SSL_DNS" = dns_gd || "$SSL_DNS" = dns_aws || "$SSL_DNS" = dns_tencent ]]; then
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
        echo ""
        echo "    1) 部署新站点"
        echo "    2) 更新站点"
        echo "    3) 移除站点"
        echo "    4) 查看站点列表"
        echo "    5) SSL 证书管理"
        echo "    6) 站点运行状态"
        echo "    0) 退出"
        echo ""
        local action=""
        read -rp "  请选择 [0-6]: " action </dev/tty 2>/dev/tty || action=""
        echo ""
        case "$action" in
          1) cmd_add ;;
          2) cmd_update ;;
          3) cmd_remove ;;
          4) cmd_list ;;
          5) cmd_ssl ;;
          6) STATUS_ALL=0; DOMAIN=""; cmd_status ;;
          0) ok "再见"; exit 0 ;;
          *) warn "无效选择，请输入 0-6" ;;
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
