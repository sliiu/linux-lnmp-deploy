# shellcheck shell=bash

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
    setfacl -R  -m "u:${PHP_C_UID}:rwX" "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    setfacl -dR -m "u:${PHP_C_UID}:rwX" "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
  else
    # 无 setfacl：让 PHP-FPM(82) 直接为属主，避免 chmod 777
    chown -R "${PHP_C_UID}:${PHP_C_GID}" "${site_dir}/storage" "${site_dir}/bootstrap/cache"
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
  filtered=$(printf '%s\n' "$filtered" | grep -vE "docker exec (-u [^ ]+ )?(-w \"[^\"]+\" )?lnmp-php[0-9]* php artisan schedule:run.*${dom_esc}(\b|$)" || true)
  filtered=$(printf '%s\n' "$filtered" | grep -vE "docker exec lnmp-php[0-9]* php [^[:space:]]*/${dom_esc}/artisan schedule:run" || true)
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
DOMAIN="" GIT_REPO="" GIT_BRANCH="" GIT_REF="" SITE_TYPE="" SITE_TYPE_CLI=0
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
WEBHOOK_MODE="" WEBHOOK_RELEASE_NAME="" WEBHOOK_SECRET="" WEBHOOK_ENABLE=0
ROLLBACK_TO="" ROLLBACK_INDEX=0
WEBHOOK_BODY_FILE="" WEBHOOK_HEADERS_FILE="" WEBHOOK_EVENT=""
WEBHOOK_GH_SIG="" WEBHOOK_GITEE_TOKEN=""
YES=0
STATUS_ALL=0
SKIP_GIT=0

# 主菜单每次操作前调用，避免 DOMAIN / SITE_TYPE 等残留导致跳过交互
reset_menu_deploy_state() {
  DOMAIN=""
  GIT_REPO=""
  GIT_BRANCH=""
  GIT_REF=""
  SITE_TYPE=""
  SITE_TYPE_CLI=0
  SITE_PHP_VERSION=""
  SITE_PHP_VERSION_CLI=0
  SITE_SSE_PREFIXES=""
  SITE_SSE_PREFIXES_CLI=0
  APP_NAME=""
  REDIS_HOST=""
  REDIS_PORT=""
  REDIS_PASSWORD=""
  REDIS_PASSWORD_FROM_CLI=0
  NEED_DB=""
  DB_HOST=""
  DB_NAME=""
  DB_PWD=""
  DB_PWD_FROM_CLI=0
  CREATE_DB=""
  RUN_MIGRATE=""
  RUN_SEED=""
  ADD_CRONTAB=""
  NEED_HORIZON=""
  FRONTEND_ROOT=""
  SSL_DNS=""
  CF_TOKEN=""
  FORCE_SSL=""
  SSL_STAGING=0
  ALI_KEY=""
  ALI_SECRET=""
  DP_ID=""
  DP_KEY=""
  GD_KEY=""
  GD_SECRET=""
  AWS_ACCESS_KEY_ID=""
  AWS_SECRET_ACCESS_KEY=""
  TENCENT_SECRET_ID=""
  TENCENT_SECRET_KEY=""
  CUSTOM_ENV=()
  WEBHOOK_MODE=""
  WEBHOOK_RELEASE_NAME=""
  WEBHOOK_SECRET=""
  WEBHOOK_ENABLE=0
  ROLLBACK_TO=""
  ROLLBACK_INDEX=0
  WEBHOOK_BODY_FILE=""
  WEBHOOK_HEADERS_FILE=""
  WEBHOOK_EVENT=""
  WEBHOOK_GH_SIG=""
  WEBHOOK_GITEE_TOKEN=""
  YES=0
  STATUS_ALL=0
  SKIP_GIT=0
}

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
      --git-ref=*)       GIT_REF="${1#*=}" ;;
      --git-ref)         shift; GIT_REF="$1" ;;
      --git-tag=*)       GIT_REF="${1#*=}" ;;
      --git-tag)         shift; GIT_REF="$1" ;;
      --type=*)          SITE_TYPE="${1#*=}"; SITE_TYPE_CLI=1 ;;
      --type)            shift; SITE_TYPE="$1"; SITE_TYPE_CLI=1 ;;
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
      --webhook=*)       WEBHOOK_MODE="${1#*=}"; WEBHOOK_ENABLE=1 ;;
      --webhook)         shift; WEBHOOK_MODE="$1"; WEBHOOK_ENABLE=1 ;;
      --webhook-release-name=*) WEBHOOK_RELEASE_NAME="${1#*=}" ;;
      --webhook-release-name)   shift; WEBHOOK_RELEASE_NAME="$1" ;;
      --webhook-secret=*) WEBHOOK_SECRET="${1#*=}" ;;
      --webhook-secret)   shift; WEBHOOK_SECRET="$1" ;;
      --rollback-to=*)   ROLLBACK_TO="${1#*=}" ;;
      --rollback-to)     shift; ROLLBACK_TO="$1" ;;
      --rollback-index=*) ROLLBACK_INDEX="${1#*=}" ;;
      --rollback-index)  shift; ROLLBACK_INDEX="$1" ;;
      --body-file=*)     WEBHOOK_BODY_FILE="${1#*=}" ;;
      --body-file)       shift; WEBHOOK_BODY_FILE="$1" ;;
      --headers-file=*)  WEBHOOK_HEADERS_FILE="${1#*=}" ;;
      --headers-file)    shift; WEBHOOK_HEADERS_FILE="$1" ;;
      --event=*)         WEBHOOK_EVENT="${1#*=}" ;;
      --event)           shift; WEBHOOK_EVENT="$1" ;;
      --github-signature=*) WEBHOOK_GH_SIG="${1#*=}" ;;
      --github-signature) shift; WEBHOOK_GH_SIG="$1" ;;
      --gitee-token=*)   WEBHOOK_GITEE_TOKEN="${1#*=}" ;;
      --gitee-token)     shift; WEBHOOK_GITEE_TOKEN="$1" ;;
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

# PHP 版本菜单：基于在线 lnmp-php / lnmp-phpNN 容器
_collect_site_php_version_interactive() {
  [[ "${SITE_PHP_VERSION_CLI:-0}" -eq 1 ]] && return 0
  local -a vers=("默认（lnmp-php = ${PHP_VERSION:-未知}）")
  local cur n v dv; dv="$(_default_php_ver)"
  while IFS= read -r n; do
    [[ "$n" = "lnmp-php" ]] && continue
    v="${n#lnmp-php}"
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

  # 2) 站点类型（与主菜单相同：直接 menu_select，勿预判 tty；误判时会静默默认 laravel）
  if [[ "${SITE_TYPE_CLI:-0}" -ne 1 ]]; then
    SITE_TYPE=""
    local _st_i
    _st_i=$(menu_select "站点类型" "laravel (PHP 后端)" "frontend (静态/SPA)")
    [[ "$_st_i" -eq 1 ]] && SITE_TYPE="frontend" || SITE_TYPE="laravel"
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

    if [[ ${#CUSTOM_ENV[@]} -eq 0 ]]; then
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
  if [[ "${YES:-0}" -ne 1 ]]; then
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

  _webhook_save_on_add
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

  if [[ "${SKIP_GIT:-0}" -ne 1 && -d "${site_dir}/.git" ]]; then
    if [[ -n "${GIT_REF:-}" ]]; then
      _git_fetch_checkout "${site_dir}" "${GIT_REF}"
    else
      _git_pull_or_clone "${site_dir}" "" "${GIT_BRANCH:-}"
    fi
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
      || printf '%s\n' "$_cron_existing" | grep -qE "docker exec[^|;&]*lnmp-php[0-9]*[[:space:]].*artisan[[:space:]]+schedule:run[^|;&]*${_cron_dom_esc}(\b|$)"; then
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

