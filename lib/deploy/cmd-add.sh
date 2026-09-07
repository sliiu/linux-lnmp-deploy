# shellcheck shell=bash

setup_laravel() {
  local domain="$1"
  local site_dir="${WWW_ROOT}/${domain}"
  local envfile="${site_dir}/.env"

  if [[ ! -f "$envfile" ]]; then
    [[ -f "${site_dir}/.env.example" ]] || die ".env.example 不存在"
    su - "${DEVOPS_USER}" -c "cp '${site_dir}/.env.example' '${envfile}'"
  fi

  local queue_conn="redis" session_drv="redis" cache_drv="redis"
  if ! container_ok "lnmp-redis"; then
    queue_conn="sync"
    session_drv="file"
    cache_drv="file"
    warn "lnmp-redis 未运行，队列 sync、session/cache 使用 file"
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
  env_set "SESSION_DRIVER"   "${session_drv}"   "$envfile"
  if [[ -n "$lv" ]] && _lv_ge "$lv" "10"; then
    env_set "CACHE_STORE"    "${cache_drv}"     "$envfile"
  else
    env_set "CACHE_DRIVER"   "${cache_drv}"     "$envfile"
  fi
  if [[ -n "$lv" ]] && ! _lv_ge "$lv" "6"; then
    env_set "REDIS_CLIENT"   "predis"           "$envfile"
  else
    env_set "REDIS_CLIENT"   "phpredis"         "$envfile"
  fi
  env_set "LOG_CHANNEL"      "daily"            "$envfile"
  env_set "LOG_LEVEL"        "warning"          "$envfile"

  if [[ "${NEED_DB:-y}" = "y" ]]; then
    _write_laravel_db_env "$envfile"
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
  ensure_lnmp_php_laravel_extensions "$cname" "${DB_CONNECTION:-mysql}"
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
  ensure_crontab || die "未安装 crontab（RHEL/Amazon: cronie；Debian/Ubuntu: cron）"
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
NEED_DB="" DB_CONNECTION="" DB_HOST="" DB_NAME="" DB_PWD="" DB_USERNAME="" DB_PORT=""
DB_PWD_FROM_CLI=0
CREATE_DB="" RUN_MIGRATE="" RUN_SEED="" ADD_CRONTAB="" NEED_HORIZON=""
FRONTEND_ROOT=""
SITE_PM2_PORT="" SITE_PM2_PORT_CLI=0 SITE_PM2_CMD="" SITE_PM2_CMD_CLI=0 PM2_BUILD=""
SITE_PROXY_PASS="" SITE_PROXY_PASS_CLI=0
SSL_DNS="" CF_TOKEN="" FORCE_SSL="" SSL_STAGING=0
ALI_KEY="" ALI_SECRET="" DP_ID="" DP_KEY="" GD_KEY="" GD_SECRET=""
AWS_ACCESS_KEY_ID="" AWS_SECRET_ACCESS_KEY="" TENCENT_SECRET_ID="" TENCENT_SECRET_KEY=""
CUSTOM_ENV=()
WEBHOOK_MODE="" WEBHOOK_RELEASE_NAME="" WEBHOOK_SECRET="" WEBHOOK_ENABLE=0
WEBHOOK_SITE_GITHUB_TOKEN="" WEBHOOK_SITE_GITEE_TOKEN="" WEBHOOK_ASSET_NAME="" WEBHOOK_INCREMENTAL=""
ROLLBACK_TO="" ROLLBACK_INDEX=0
WEBHOOK_BODY_FILE="" WEBHOOK_HEADERS_FILE="" WEBHOOK_EVENT=""
WEBHOOK_GH_SIG="" WEBHOOK_GITEE_TOKEN=""
WEBHOOK_ONLY=0
WEBHOOK_BIND=""
WEBHOOK_PORT=""
WEBHOOK_PATH=""
WEBHOOK_PROXY_DOMAIN=""
WEBHOOK_PUBLIC_MODE=""
WEBHOOK_NOTIFY_URL=""
WEBHOOK_NOTIFY_URL_SET=0
WEBHOOK_SETUP_CLI=0
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
  DB_CONNECTION=""
  DB_HOST=""
  DB_NAME=""
  DB_PWD=""
  DB_USERNAME=""
  DB_PORT=""
  DB_PWD_FROM_CLI=0
  CREATE_DB=""
  RUN_MIGRATE=""
  RUN_SEED=""
  ADD_CRONTAB=""
  NEED_HORIZON=""
  FRONTEND_ROOT=""
  SITE_PM2_PORT="" SITE_PM2_PORT_CLI=0 SITE_PM2_CMD="" SITE_PM2_CMD_CLI=0 PM2_BUILD=""
  SITE_PROXY_PASS="" SITE_PROXY_PASS_CLI=0
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
  WEBHOOK_SITE_GITHUB_TOKEN=""
  WEBHOOK_SITE_GITEE_TOKEN=""
  WEBHOOK_ASSET_NAME=""
  WEBHOOK_INCREMENTAL=""
  ROLLBACK_TO=""
  ROLLBACK_INDEX=0
  WEBHOOK_BODY_FILE=""
  WEBHOOK_HEADERS_FILE=""
  WEBHOOK_EVENT=""
  WEBHOOK_GH_SIG=""
  WEBHOOK_GITEE_TOKEN=""
  WEBHOOK_ONLY=0
  WEBHOOK_BIND=""
  WEBHOOK_PORT=""
  WEBHOOK_PATH=""
  WEBHOOK_PROXY_DOMAIN=""
  WEBHOOK_PUBLIC_MODE=""
  WEBHOOK_NOTIFY_URL=""
  WEBHOOK_NOTIFY_URL_SET=0
  WEBHOOK_SETUP_CLI=0
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
      --db-connection=*) DB_CONNECTION="${1#*=}" ;;
      --db-connection) shift; DB_CONNECTION="$1" ;;
      --db-host=*)       DB_HOST="${1#*=}" ;;
      --db-host)         shift; DB_HOST="$1" ;;
      --db-port=*)       DB_PORT="${1#*=}" ;;
      --db-port)         shift; DB_PORT="$1" ;;
      --db-user=*)       DB_USERNAME="${1#*=}" ;;
      --db-user)         shift; DB_USERNAME="$1" ;;
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
      --pm2-port=*)      SITE_PM2_PORT="${1#*=}"; SITE_PM2_PORT_CLI=1 ;;
      --pm2-port)
        SITE_PM2_PORT_CLI=1
        if [[ $# -ge 2 && -n "$2" && "$2" != --* ]]; then
          shift; SITE_PM2_PORT="$1"
        else
          SITE_PM2_PORT=""
        fi
        ;;
      --pm2-cmd=*)       SITE_PM2_CMD="${1#*=}"; SITE_PM2_CMD_CLI=1 ;;
      --pm2-cmd)         shift; SITE_PM2_CMD="$1"; SITE_PM2_CMD_CLI=1 ;;
      --pm2-build=*)     PM2_BUILD="${1#*=}" ;;
      --pm2-build)       shift; PM2_BUILD="$1" ;;
      --proxy-pass=*)    SITE_PROXY_PASS="${1#*=}"; SITE_PROXY_PASS_CLI=1 ;;
      --proxy-pass)      shift; SITE_PROXY_PASS="$1"; SITE_PROXY_PASS_CLI=1 ;;
      --webhook=*)       WEBHOOK_MODE="${1#*=}"; WEBHOOK_ENABLE=1 ;;
      --webhook)         shift; WEBHOOK_MODE="$1"; WEBHOOK_ENABLE=1 ;;
      --webhook-release-name=*) WEBHOOK_RELEASE_NAME="${1#*=}" ;;
      --webhook-release-name)   shift; WEBHOOK_RELEASE_NAME="$1" ;;
      --webhook-secret=*) WEBHOOK_SECRET="${1#*=}" ;;
      --webhook-secret)   shift; WEBHOOK_SECRET="$1" ;;
      --webhook-github-token=*) WEBHOOK_SITE_GITHUB_TOKEN="${1#*=}" ;;
      --webhook-github-token)   shift; WEBHOOK_SITE_GITHUB_TOKEN="$1" ;;
      --webhook-gitee-token=*) WEBHOOK_SITE_GITEE_TOKEN="${1#*=}" ;;
      --webhook-gitee-token)   shift; WEBHOOK_SITE_GITEE_TOKEN="$1" ;;
      --webhook-asset-name=*) WEBHOOK_ASSET_NAME="${1#*=}" ;;
      --webhook-asset-name)   shift; WEBHOOK_ASSET_NAME="$1" ;;
      --webhook-incremental=*) WEBHOOK_INCREMENTAL="${1#*=}" ;;
      --webhook-incremental)   shift; WEBHOOK_INCREMENTAL="$1" ;;
      --webhook-no-incremental) WEBHOOK_INCREMENTAL=0 ;;
      --webhook-only)    WEBHOOK_ONLY=1; WEBHOOK_ENABLE=1 ;;
      --webhook-bind=*)  WEBHOOK_BIND="${1#*=}"; WEBHOOK_PUBLIC_MODE=bind; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-bind)    shift; WEBHOOK_BIND="$1"; WEBHOOK_PUBLIC_MODE=bind; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-port=*)  WEBHOOK_PORT="${1#*=}"; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-port)    shift; WEBHOOK_PORT="$1"; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-path=*)  WEBHOOK_PATH="${1#*=}"; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-path)    shift; WEBHOOK_PATH="$1"; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-proxy-domain=*) WEBHOOK_PROXY_DOMAIN="${1#*=}"; WEBHOOK_PUBLIC_MODE=nginx; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-proxy-domain)   shift; WEBHOOK_PROXY_DOMAIN="$1"; WEBHOOK_PUBLIC_MODE=nginx; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-public-mode=*) WEBHOOK_PUBLIC_MODE="${1#*=}"; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-public-mode)   shift; WEBHOOK_PUBLIC_MODE="$1"; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-notify-url=*) WEBHOOK_NOTIFY_URL="${1#*=}"; WEBHOOK_NOTIFY_URL_SET=1; WEBHOOK_SETUP_CLI=1 ;;
      --webhook-notify-url)   shift; WEBHOOK_NOTIFY_URL="$1"; WEBHOOK_NOTIFY_URL_SET=1; WEBHOOK_SETUP_CLI=1 ;;
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
  deploy_log_bind_domain "${DOMAIN:-}"
}

# 列出 ${NGINX_CONF}/*.conf 已部署站点（去掉 default）
_list_deployed_domains() {
  local f name seen=" "
  local dir="${CADDY_SITES:-${DATA_DIR}/caddy/sites}"
  shopt -s nullglob
  for f in "$dir"/*.caddy "${NGINX_CONF}"/*.conf; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f")
    name="${name%.caddy}"
    name="${name%.conf}"
    [[ "$name" = "default" || "$name" = "000-placeholder" ]] && continue
    case "$seen" in *" $name "*) continue ;; esac
    seen+=" $name "
    printf '%s\n' "$name"
  done
  shopt -u nullglob
}

# DOMAIN 为空 + TTY 时弹菜单选择已部署站点；prefer_action=update/remove/ssl/status 仅用于标题
prompt_pick_domain() {
  [[ -n "$DOMAIN" ]] && return 0
  local -a doms=()
  while IFS= read -r d; do doms+=("$d"); done < <(_list_deployed_domains)
  if [[ ${#doms[@]} -eq 0 ]]; then
    prompt "站点域名（当前无已部署站点）"
    DOMAIN=$PROMPT_RESULT
    return 0
  fi
  local _items=("${doms[@]}" "手动输入...")
  local _i; menu_select "${1:-选择站点}" "${_items[@]}"
  _i=$MENU_SELECT_RESULT
  if [[ "$_i" -lt ${#doms[@]} ]]; then
    DOMAIN="${doms[$_i]}"
  else
    prompt "站点域名"
    DOMAIN=$PROMPT_RESULT
  fi
  deploy_log_bind_domain "${DOMAIN:-}"
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
  local _i; menu_select "选择 PHP 版本" "${vers[@]}"
  _i=$MENU_SELECT_RESULT
  if [[ "$_i" -eq 0 ]]; then
    SITE_PHP_VERSION=""; SITE_PHP_VERSION_CLI=1
  elif [[ "$_i" -eq $((${#vers[@]} - 1)) ]]; then
    prompt "PHP 主版本 (X.Y)" "$dv"
    SITE_PHP_VERSION=$PROMPT_RESULT
    SITE_PHP_VERSION_CLI=1
  else
    local pick="${vers[$_i]}"
    SITE_PHP_VERSION="${pick%%（*}"
    SITE_PHP_VERSION_CLI=1
  fi
}

# SSL 校验方式：add 先问是否用默认；ssl 命令传 full 列出全部
_collect_ssl_dns_interactive() {
  local mode="${1:-short}" _i def="${ACME_SSL_DNS_DEFAULT:-webroot}"
  [[ -n "$SSL_DNS" ]] && return 0
  if [[ "$mode" != "full" ]]; then
    menu_select "SSL 证书校验方式" \
      "${def}（默认）" \
      "其他方式（DNS API，可签泛域名）"
    _i=$MENU_SELECT_RESULT
    [[ "$_i" -eq 0 ]] && { SSL_DNS="$def"; return 0; }
  fi
  menu_select "选择 SSL 校验方式" \
    "webroot   (HTTP-01；最常见，需域名解析到本机)" \
    "dns_cf    (Cloudflare API Token)" \
    "dns_ali   (阿里云 DNS Ali_Key/Secret)" \
    "dns_dp    (DNSPod DP_Id/DP_Key)" \
    "dns_gd    (GoDaddy)" \
    "dns_aws   (Route53)" \
    "dns_tencent (腾讯云 DNSPod API)"
  _i=$MENU_SELECT_RESULT
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
  local _i; menu_select "数据库自动化（建库 / migrate / seed）" \
    "建库 + migrate + seed（全自动，推荐）" \
    "建库 + migrate（不跑 seed）" \
    "仅建库（不 migrate、不 seed）" \
    "什么都不做（仅写 .env，留待手动）" \
    "自定义（逐项询问）"
  _i=$MENU_SELECT_RESULT
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
  local _i; menu_select "队列后台 / 定时任务${_hint}" \
    "cron + Horizon（推荐：调度 + Redis 队列守护）" \
    "仅 cron（无队列守护，sync/database 队列）" \
    "仅 Horizon（无 schedule:run）" \
    "都不要"
  _i=$MENU_SELECT_RESULT
  case "$_i" in
    0) ADD_CRONTAB=y; NEED_HORIZON=y ;;
    1) ADD_CRONTAB=y; NEED_HORIZON=n ;;
    2) ADD_CRONTAB=n; NEED_HORIZON=y ;;
    3) ADD_CRONTAB=n; NEED_HORIZON=n ;;
  esac
}

# 前端：Git clone 构建产物 vs Webhook Release 直部署
_collect_frontend_source_interactive() {
  [[ "${WEBHOOK_ENABLE:-0}" -eq 1 || -n "${WEBHOOK_MODE:-}" ]] && return 0
  local _i
  menu_select "前端部署方式" \
    "Git 仓库（clone 后使用 dist 等构建目录）" \
    "Webhook Release（监听 Release 下载，不 clone 仓库）"
  _i=$MENU_SELECT_RESULT
  if [[ "$_i" -eq 1 ]]; then
    WEBHOOK_ENABLE=1
    WEBHOOK_MODE=release
    FRONTEND_ROOT=""
    GIT_BRANCH=""
  fi
}

# PM2：Git clone vs Webhook Gateway Release（CI 推送产物，不 clone）
_collect_pm2_source_interactive() {
  [[ "${WEBHOOK_ENABLE:-0}" -eq 1 || -n "${WEBHOOK_MODE:-}" ]] && return 0
  local _i
  menu_select "PM2 部署方式" \
    "Git 仓库（clone 后在服务器 build + PM2 启动）" \
    "Webhook Gateway Release（CI 推送产物，不 clone 仓库）"
  _i=$MENU_SELECT_RESULT
  if [[ "$_i" -eq 1 ]]; then
    WEBHOOK_ENABLE=1
    WEBHOOK_MODE=release
    GIT_BRANCH=""
  fi
}

# PM2 站点目录尚无可启动产物时跳过 setup_pm2（Webhook / 待首次推送场景）
_pm2_site_has_launchable_code() {
  local domain="$1"
  local site_dir="${WWW_ROOT}/${domain}"
  [[ -f "${site_dir}/package.json" || -f "${site_dir}/ecosystem.config.js" || -f "${site_dir}/ecosystem.config.cjs" ]]
}

_nginx_reload_or_die() {
  wait_container_running "$(_web_container)" 45
  caddy_validate || die "Caddy 配置校验失败"
  caddy_reload
}

# Webhook Release 首次部署：无代码也应完整注册站点（.webhook / 类型 / 端口），打破「无代码→无法 webhook」死循环
_cmd_add_webhook_release_site() {
  local domain="$DOMAIN" port="" _fe_sub=""
  WEBHOOK_RELEASE_ADD_DONE=1

  write_site_type_file "$domain" "$SITE_TYPE"

  if [[ "$SITE_TYPE" = "pm2" ]]; then
    mkdir -p "${WWW_ROOT}/${domain}/.well-known/acme-challenge"
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${domain}/.well-known" 2>/dev/null || true
    apply_site_pm2_port_cli "$domain"
    apply_site_pm2_cmd_cli "$domain"
    port="$(allocate_pm2_port "$domain" "${SITE_PM2_PORT:-8787}")"
    printf '%s\n' "$port" > "$(site_pm2_port_file "$domain")"
    chmod 644 "$(site_pm2_port_file "$domain")" 2>/dev/null || true
    if _pm2_site_has_launchable_code "$domain"; then
      setup_pm2 "$domain"
    else
      warn "待 gateway-release webhook 推送产物后再启动 PM2（端口已预留: ${port}）"
      warn "可先配置 ${WWW_ROOT}/${domain}/.env.production 与 .env.production.local"
    fi
  else
    _fe_sub=""
    fix_site_readable_for_nginx "$domain" "frontend" ""
  fi

  _webhook_save_on_add
  WEBHOOK_SAVED_ON_ADD=1
  ok "Webhook 站点已注册: $(site_webhook_file "$domain")"

  echo ""
  hr; info "[1/6] Caddy 配置（Webhook Release）"; echo ""
  if [[ "$SITE_TYPE" = "pm2" ]]; then
    gen_nginx_pm2 "$domain"
    _nginx_reload_or_die
    ok "Caddy 反代已生成（→ $(_docker_host_gateway):$(pm2_port_for_site "$domain")）"
  else
    gen_nginx_frontend "$domain" ""
    _nginx_reload_or_die
    ok "Caddy 配置已生成（站点根待 Release 写入）"
  fi

  echo ""
  hr; info "[3/6] SSL 证书"; echo ""
  if _is_dns_mode "${SSL_DNS:-webroot}"; then
    if container_ok "lnmp-acme"; then
      SSL_SOFT_FAIL=1
      issue_ssl "$domain" "$SITE_TYPE" "${SSL_DNS:-webroot}" "${FORCE_SSL:-}" "" || true
      unset SSL_SOFT_FAIL
    else
      warn "lnmp-acme 未运行，跳过 DNS-01 签发"
    fi
  else
    SSL_SOFT_FAIL=1
    issue_ssl "$domain" "$SITE_TYPE" "${SSL_DNS:-webroot}" "${FORCE_SSL:-}" "" || true
    unset SSL_SOFT_FAIL
  fi

  echo ""
  hr; info "[4/6] 跳过（Webhook Release 无数据库）"
  hr; info "[5/6] 跳过（Webhook Release 无 PHP）"
  hr; info "[6/6] 跳过（Webhook Release 无 crontab）"
  echo ""
  hr
  if [[ "$SITE_TYPE" = "pm2" ]]; then
    ok "PM2 Webhook Release 站点已注册"
    info "目录: ${WWW_ROOT}/${domain}"
    info "PM2 端口: $(pm2_port_for_site "$domain")（待 webhook 推送后启动）"
    info "下一步: 配置 .env.production → $0 webhook setup → CI 推送 gateway-release"
  else
    ok "前端 Webhook Release 站点已注册"
    info "目录: ${WWW_ROOT}/${domain}"
    info "下一步: $0 webhook setup → 发布匹配的 Release 触发部署"
  fi
  info "回调: $(_webhook_public_callback_url)"
  hr
}

collect_interactive() {
  if [[ -z "$DOMAIN" ]]; then
    prompt_required "站点域名 (如 app.com)"
    DOMAIN=$PROMPT_RESULT
  fi
  [[ -n "$DOMAIN" ]] || { menu_fail "域名不能为空" || return 1; }
  deploy_log_bind_domain "$DOMAIN"

  if [[ "${SITE_TYPE_CLI:-0}" -ne 1 ]]; then
    SITE_TYPE=""
    local _st_i
    menu_select "站点类型" \
      "laravel (PHP 后端)" \
      "frontend (静态/SPA)" \
      "pm2 (Node.js 应用)" \
      "proxy (Caddy 反代)"
    _st_i=$MENU_SELECT_RESULT
    case "$_st_i" in
      1) SITE_TYPE="frontend" ;;
      2) SITE_TYPE="pm2" ;;
      3) SITE_TYPE="proxy" ;;
      *) SITE_TYPE="laravel" ;;
    esac
  fi
  SITE_TYPE=${SITE_TYPE:-laravel}
  case "$SITE_TYPE" in
    laravel|frontend|pm2|proxy) ;;
    *) SITE_TYPE="laravel" ;;
  esac

  if [[ "$SITE_TYPE" = "frontend" ]]; then
    _collect_frontend_source_interactive
  elif [[ "$SITE_TYPE" = "pm2" ]]; then
    _collect_pm2_source_interactive
  fi

  if [[ "$SITE_TYPE" = "proxy" ]]; then
    GIT_REPO=""
    GIT_BRANCH=""
  elif [[ "$SITE_TYPE" = "frontend" && "${WEBHOOK_MODE:-}" = "release" ]]; then
    if [[ -z "$GIT_REPO" ]]; then
      prompt_required "Git 仓库地址（仅 Webhook 匹配用，不会在服务器 clone）"
      GIT_REPO=$PROMPT_RESULT
    fi
    [[ -n "$GIT_REPO" ]] || { menu_fail "Webhook Release 需填写仓库地址（用于匹配推送来源）" || return 1; }
    [[ -z "$WEBHOOK_RELEASE_NAME" ]] && {
      prompt_required "Release 名称（前缀匹配，如 slimppt 匹配 slimppt-v0.1.0）"
      WEBHOOK_RELEASE_NAME=$PROMPT_RESULT
    }
    [[ -n "$WEBHOOK_RELEASE_NAME" ]] || { menu_fail "Release 名称不能为空" || return 1; }
    _webhook_collect_site_release_opts ""
    _webhook_collect_secret ""
    GIT_BRANCH=""
    FRONTEND_ROOT=""
  elif [[ "$SITE_TYPE" = "pm2" && "${WEBHOOK_MODE:-}" = "release" ]]; then
    if [[ -z "$GIT_REPO" ]]; then
      prompt_required "Git 仓库地址（仅 Webhook 匹配用，不会在服务器 clone）"
      GIT_REPO=$PROMPT_RESULT
    fi
    [[ -n "$GIT_REPO" ]] || { menu_fail "Webhook Gateway Release 需填写仓库地址（用于匹配 CI 推送来源）" || return 1; }
    [[ -z "$WEBHOOK_RELEASE_NAME" ]] && {
      prompt_required "Release 名称（前缀匹配 CI 的 release/app/tag，如 gateway 匹配 gateway-v1.0.0）"
      WEBHOOK_RELEASE_NAME=$PROMPT_RESULT
    }
    [[ -n "$WEBHOOK_RELEASE_NAME" ]] || { menu_fail "Release 名称不能为空" || return 1; }
    _webhook_collect_site_release_opts ""
    _webhook_collect_secret ""
    GIT_BRANCH=""
  else
    if [[ -z "$GIT_REPO" ]]; then
      prompt "Git 仓库地址（留空=跳过 clone，使用 ${WWW_ROOT}/${DOMAIN} 现有代码）" ""
      GIT_REPO=$PROMPT_RESULT
    fi
    _offer_skip_git_if_code_present
    if [[ -n "$GIT_REPO" && -z "$GIT_BRANCH" ]]; then
      prompt "Git 分支（回车=仓库默认分支）" ""
      GIT_BRANCH=$PROMPT_RESULT
    fi
    [[ -n "$GIT_REPO" ]] || GIT_BRANCH=""
  fi

  if [[ "$SITE_TYPE" = "laravel" ]]; then
    _collect_site_php_version_interactive

    if [[ -z "$NEED_DB" ]]; then
      confirm "配置数据库？" "y" && NEED_DB=y || NEED_DB=n
    fi
    if [[ "$NEED_DB" = "y" ]]; then
      _collect_db_connection_interactive
      DB_HOST="${DB_HOST:-$(_default_db_host "${DB_CONNECTION:-mysql}")}"
      if [[ -z "$DB_NAME" ]]; then
        prompt_required "DB_DATABASE（业务库名，勿填数据库服务名）"
        DB_NAME=$PROMPT_RESULT
      fi
      [[ -n "$DB_NAME" ]] || { menu_fail "DB_DATABASE 不能为空" || return 1; }
      [[ "$DB_PWD_FROM_CLI" != "1" && -z "$DB_PWD" ]] && prompt_secret_into "DB_PASSWORD" DB_PWD
      [[ -n "$DB_PWD" ]] || { menu_fail "DB_PASSWORD 不能为空" || return 1; }
      _collect_db_actions_interactive
    fi

    REDIS_HOST="${REDIS_HOST:-redis}"
    REDIS_PORT="${REDIS_PORT:-6379}"
    _collect_queue_supervisor_interactive
    if [[ -z "$APP_NAME" ]]; then
      prompt "APP_NAME" "Laravel"
      APP_NAME=$PROMPT_RESULT
    fi
  elif [[ "$SITE_TYPE" = "proxy" ]]; then
    if [[ -z "$SITE_PROXY_PASS" ]]; then
      while true; do
        prompt_required "反代上游（如 http://127.0.0.1:8080）"
        SITE_PROXY_PASS="$(_normalize_proxy_pass "${PROMPT_RESULT}")" && break
        warn "反代上游不能为空（如 http://127.0.0.1:8080）"
        interactive_tty_ok || die "反代上游不能为空（如 http://127.0.0.1:8080）"
      done
    else
      SITE_PROXY_PASS="$(_normalize_proxy_pass "${SITE_PROXY_PASS}")" \
        || { menu_fail "反代上游不能为空（如 http://127.0.0.1:8080）" || return 1; }
    fi
    SITE_PROXY_PASS_CLI=1
  else
    if [[ "$SITE_TYPE" = "pm2" ]]; then
      [[ "$SITE_PM2_PORT" = "auto" || "$SITE_PM2_PORT" = "-" ]] && SITE_PM2_PORT=""
      if [[ -z "$SITE_PM2_PORT" ]]; then
        prompt "PM2 端口（回车=自动分配）" ""
        SITE_PM2_PORT=$PROMPT_RESULT
      fi
      [[ -n "$SITE_PM2_PORT" ]] && SITE_PM2_PORT_CLI=1
      if [[ -z "$SITE_PM2_CMD" ]]; then
        prompt "PM2 启动命令（回车=自动检测）" ""
        SITE_PM2_CMD=$PROMPT_RESULT
      fi
      [[ -n "$SITE_PM2_CMD" ]] && SITE_PM2_CMD_CLI=1
      if [[ -z "$PM2_BUILD" ]]; then
        confirm "部署时执行构建（npm/pnpm/yarn build）？" "y" && PM2_BUILD=y || PM2_BUILD=n
      fi
    elif [[ "$SITE_TYPE" = "frontend" && "${WEBHOOK_MODE:-}" != "release" && -z "$FRONTEND_ROOT" ]]; then
      prompt "前端子目录（回车=自动 dist 优先）" ""
      FRONTEND_ROOT=$PROMPT_RESULT
    fi
  fi

  _collect_ssl_dns_interactive
  SSL_DNS="${SSL_DNS:-${ACME_SSL_DNS_DEFAULT:-webroot}}"
  case "$SSL_DNS" in
    webroot|dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) ;;
    *) menu_fail "无效 SSL 模式: ${SSL_DNS}（webroot / dns_cf / dns_ali / dns_dp / dns_gd / dns_aws / dns_tencent）" || return 1 ;;
  esac
  _collect_ssl_dns_creds_interactive
  if _is_dns_mode "$SSL_DNS"; then
    _acme_ssl_validate_dns_creds "$SSL_DNS"
  fi
}

_require_deploy_containers() {
  local site_type="${1:-${SITE_TYPE:-laravel}}"
  container_ok "$(_web_container)" || menu_fail "Web 容器 $(_web_container) 未运行，请先执行: init.sh install php 或 init.sh install caddy" || return 1
  if [[ "$site_type" = "laravel" ]]; then
    container_ok "lnmp-php" || menu_fail "容器 lnmp-php 未运行，请先执行: init.sh install php" || return 1
    ensure_php_fpm_slowlog_host_artifacts
    warn_php_fpm_slowlog_compose_missing
    ensure_php_fpm_wave_pool_host_artifacts
    warn_php_fpm_wave_pool_compose_missing
    ensure_mysql_low_memory_host_artifacts
    warn_mysql_low_memory_compose_missing
  fi
  if _is_dns_mode "${SSL_DNS:-${ACME_SSL_DNS_DEFAULT:-webroot}}"; then
    container_ok "lnmp-acme" || warn "lnmp-acme 未运行，DNS-01 签发将失败"
  fi
}

cmd_add() {
  collect_interactive || return 0

  _require_deploy_containers "$SITE_TYPE" || return 0

  if [[ "$SITE_TYPE" = "laravel" && "${NEED_DB:-y}" = "y" ]]; then
    [[ -z "${DB_CONNECTION:-}" ]] && DB_CONNECTION="$(_default_db_connection)"
    DB_CONNECTION="$(_normalize_db_connection "$DB_CONNECTION")"
    [[ -z "${DB_NAME:-}" ]] && { menu_fail "Laravel 默认启用数据库，请指定 --db-name 或在交互中填写 DB_DATABASE" || return 0; }
    _validate_laravel_db_config || return 0
  fi

  # 执行前的「配置确认」（仅 TTY 且未 --yes 时弹出，顺序与提问顺序一致）
  if [[ "${YES:-0}" -ne 1 ]]; then
    echo ""
    hr; info "配置确认"; hr
    printf "  %-18s %s\n" "域名"   "$DOMAIN"
    printf "  %-18s %s\n" "类型"   "$SITE_TYPE"
    if [[ "$SITE_TYPE" = "proxy" ]]; then
      printf "  %-18s %s\n" "部署" "Caddy 反代（不 clone）"
      printf "  %-18s %s\n" "反代上游" "${SITE_PROXY_PASS}"
    elif [[ "$SITE_TYPE" = "frontend" && "${WEBHOOK_MODE:-}" = "release" ]]; then
      printf "  %-18s %s\n" "部署"   "Webhook Release（不 clone）"
      printf "  %-18s %s\n" "仓库(匹配)" "${GIT_REPO}"
      printf "  %-18s %s\n" "Release" "${WEBHOOK_RELEASE_NAME}"
      printf "  %-18s %s\n" "增量部署" \
        "$([[ "$(_webhook_normalize_incremental "${WEBHOOK_INCREMENTAL:-0}")" = 1 ]] && echo 是 || echo 否)"
    elif [[ "$SITE_TYPE" = "pm2" && "${WEBHOOK_MODE:-}" = "release" ]]; then
      printf "  %-18s %s\n" "部署"   "Webhook Gateway Release（不 clone）"
      printf "  %-18s %s\n" "仓库(匹配)" "${GIT_REPO}"
      printf "  %-18s %s\n" "Release" "${WEBHOOK_RELEASE_NAME}"
      printf "  %-18s %s\n" "附件关键字" "${WEBHOOK_ASSET_NAME:-自动}"
    elif [[ -n "$GIT_REPO" ]]; then
      printf "  %-18s %s\n" "Git" "${GIT_REPO}${GIT_BRANCH:+ (${GIT_BRANCH})}"
    else
      printf "  %-18s %s\n" "Git" "跳过（使用 ${WWW_ROOT}/${DOMAIN} 现有代码）"
    fi
    if [[ "$SITE_TYPE" = "laravel" ]]; then
      printf "  %-18s %s\n" "PHP 容器" "$(_php_container_for_site "$DOMAIN")"
      if [[ "${NEED_DB:-y}" = "y" ]]; then
        printf "  %-18s %s\n" "数据库" "${DB_CONNECTION:-$(_default_db_connection)} @ ${DB_HOST:-$(_default_db_host "${DB_CONNECTION:-mysql}")} / ${DB_NAME:-?}"
        printf "  %-18s %s\n" "建库 / migrate / seed" "${CREATE_DB:-y} / ${RUN_MIGRATE:-y} / ${RUN_SEED:-y}"
      else
        printf "  %-18s %s\n" "数据库" "不配置（n）"
      fi
      printf "  %-18s %s\n" "Redis"   "${REDIS_HOST:-redis}:${REDIS_PORT:-6379}${REDIS_PASSWORD:+ (有密码)}"
      printf "  %-18s %s\n" "cron / Horizon" "${ADD_CRONTAB:-y} / ${NEED_HORIZON:-y}"
      printf "  %-18s %s\n" "APP_NAME" "${APP_NAME:-Laravel}"
      [[ ${#CUSTOM_ENV[@]} -gt 0 ]] && printf "  %-18s %s\n" "自定义 ENV" "${#CUSTOM_ENV[@]} 项"
    elif [[ "$SITE_TYPE" = "pm2" ]]; then
      printf "  %-18s %s\n" "PM2 端口" "${SITE_PM2_PORT:-自动分配}"
      printf "  %-18s %s\n" "PM2 命令" "${SITE_PM2_CMD:-自动检测}"
      printf "  %-18s %s\n" "构建" "${PM2_BUILD:-y}"
    elif [[ "$SITE_TYPE" = "proxy" ]]; then
      :
    else
      if [[ "${WEBHOOK_MODE:-}" = "release" ]]; then
        printf "  %-18s %s\n" "静态根" "${WWW_ROOT}/${DOMAIN}/（Release 产物直出）"
      else
        printf "  %-18s %s\n" "前端子目录" "${FRONTEND_ROOT:-自动 (dist 优先)}"
      fi
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
  hr; info "[1/6] Caddy 配置"; echo ""
  if [[ "$SITE_TYPE" = "laravel" ]]; then
    apply_site_php_version_cli "$DOMAIN"
    ensure_site_php_container "$DOMAIN"
    apply_site_sse_prefixes_cli "$DOMAIN"
    gen_nginx_laravel "$DOMAIN"
    _nginx_reload_or_die
    ok "Caddy 配置已生成"
    write_site_type_file "$DOMAIN" "laravel"
  elif [[ "$SITE_TYPE" = "pm2" ]]; then
    info "PM2 站点：Caddy 反代在代码部署与 PM2 启动后生成"
    write_site_type_file "$DOMAIN" "pm2"
  elif [[ "$SITE_TYPE" = "proxy" ]]; then
    mkdir -p "${WWW_ROOT}/${DOMAIN}/.well-known/acme-challenge"
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${DOMAIN}" 2>/dev/null || true
    chmod a+rx "${WWW_ROOT}/${DOMAIN}" 2>/dev/null || true
    apply_site_proxy_pass_cli "$DOMAIN"
    [[ -n "$(proxy_pass_for_site "$DOMAIN")" ]] || {
      SITE_PROXY_PASS="$(_normalize_proxy_pass "${SITE_PROXY_PASS}")" \
        || { menu_fail "反代上游不能为空" || return 0; }
      write_site_proxy_pass "$DOMAIN" "$SITE_PROXY_PASS"
    }
    gen_nginx_proxy "$DOMAIN"
    _nginx_reload_or_die
    ok "Caddy 反代已生成（→ $(proxy_pass_for_site "$DOMAIN")）"
    write_site_type_file "$DOMAIN" "proxy"
  else
    if _adding_frontend_release_webhook; then
      info "前端站点：Webhook Release，Caddy 根目录 = 站点目录（待 Release 推送后写入产物）"
    else
      info "前端站点：Caddy 在代码部署后生成（未指定子目录时：有 dist 用 dist，否则站点根）"
    fi
  fi

  echo ""
  hr; info "[2/6] 部署代码"; echo ""
  local _fe_sub="" _release_wh=0
  if [[ "$SITE_TYPE" = "proxy" ]]; then
    info "反代站点：跳过代码部署"
  elif _adding_frontend_release_webhook; then
    _release_wh=1
    _fe_sub=""
    mkdir -p "${WWW_ROOT}/${DOMAIN}"
    chown "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${DOMAIN}" 2>/dev/null || true
    chmod a+rx "${WWW_ROOT}/${DOMAIN}" 2>/dev/null || true
    fix_site_readable_for_nginx "$DOMAIN" "frontend" ""
    info "Webhook Release：跳过 git clone"
    warn "请发布匹配的 Release 触发 webhook，或手动上传静态文件到 ${WWW_ROOT}/${DOMAIN}/"
  elif _adding_pm2_release_webhook; then
    mkdir -p "${WWW_ROOT}/${DOMAIN}/.well-known/acme-challenge" "${WWW_ROOT}/${DOMAIN}/logs" "${WWW_ROOT}/${DOMAIN}/data"
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${DOMAIN}" 2>/dev/null || true
    info "Webhook Gateway Release：跳过 git clone"
    warn "请先在 ${WWW_ROOT}/${DOMAIN}/ 配置 .env.production 与 .env.production.local，再推送 gateway tag 触发 CI"
  else
    deploy_code "$DOMAIN" "$GIT_REPO" "$GIT_BRANCH"
    ok "代码部署完成"
  fi

  if _adding_webhook_release_site; then
    _cmd_add_webhook_release_site
  elif [[ "$SITE_TYPE" = "frontend" ]]; then
    [[ "$_release_wh" -eq 0 ]] && _fe_sub=$(effective_frontend_subdir "$DOMAIN")
    gen_nginx_frontend "$DOMAIN" "$_fe_sub"
    _nginx_reload_or_die
    ok "Caddy 配置已生成"
    write_site_type_file "$DOMAIN" "frontend"
  elif [[ "$SITE_TYPE" = "pm2" ]]; then
    mkdir -p "${WWW_ROOT}/${DOMAIN}/.well-known/acme-challenge"
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${DOMAIN}/.well-known" 2>/dev/null || true
    apply_site_pm2_port_cli "$DOMAIN"
    apply_site_pm2_cmd_cli "$DOMAIN"
    local port
    port="$(allocate_pm2_port "$DOMAIN" "${SITE_PM2_PORT:-8787}")"
    printf '%s\n' "$port" > "$(site_pm2_port_file "$DOMAIN")"
    chmod 644 "$(site_pm2_port_file "$DOMAIN")" 2>/dev/null || true
    if ! _pm2_site_has_launchable_code "$DOMAIN"; then
      warn "站点目录尚无 package.json / ecosystem 配置，跳过 PM2 启动"
      warn "代码就绪后执行: deploy-site.sh update --domain=${DOMAIN}"
    else
      setup_pm2 "$DOMAIN"
    fi
    gen_nginx_pm2 "$DOMAIN"
    _nginx_reload_or_die
    ok "Caddy 反代已生成（→ $(_docker_host_gateway):$(pm2_port_for_site "$DOMAIN")）"
  fi

  if [[ "${WEBHOOK_RELEASE_ADD_DONE:-0}" -ne 1 ]]; then
    echo ""
    hr; info "[3/6] SSL 证书"; echo ""
    local _ssl_fe=""
    [[ "$SITE_TYPE" = "frontend" ]] && _ssl_fe="${_fe_sub}"
    [[ "$SITE_TYPE" = "laravel" ]] && _ssl_fe="dist"
    if _is_dns_mode "${SSL_DNS:-webroot}"; then
      if container_ok "lnmp-acme"; then
        issue_ssl "$DOMAIN" "$SITE_TYPE" "${SSL_DNS:-webroot}" "${FORCE_SSL:-}" "$_ssl_fe"
      else
        warn "lnmp-acme 未运行，跳过 DNS-01 签发"
      fi
    else
      issue_ssl "$DOMAIN" "$SITE_TYPE" "${SSL_DNS:-webroot}" "${FORCE_SSL:-}" "$_ssl_fe"
    fi
  fi

  if [[ "${WEBHOOK_RELEASE_ADD_DONE:-0}" -eq 1 ]]; then
    :
  elif [[ "$SITE_TYPE" = "laravel" ]]; then
    echo ""
    hr; info "[4/6] 数据库"; echo ""
    if [[ "${NEED_DB:-y}" = "y" && "${CREATE_DB:-y}" = "y" && -n "${DB_NAME:-}" ]]; then
      create_database "$DB_NAME" "$DB_PWD" "${DB_HOST:-}" "${DB_CONNECTION:-$(_default_db_connection)}"
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
  elif [[ "$SITE_TYPE" = "pm2" ]]; then
    echo ""
    hr; info "[4/6] 跳过（PM2 无数据库）"
    hr; info "[5/6] 跳过（PM2 无 PHP）"
    hr; info "[6/6] 跳过（PM2 无 crontab）"
    echo ""
    hr
    ok "PM2 站点部署完成"
    info "访问: https://${DOMAIN}"
    info "目录: ${WWW_ROOT}/${DOMAIN}"
    info "PM2: $(pm2_app_name "$DOMAIN")  端口: $(pm2_port_for_site "$DOMAIN")"
    info "日志: su - ${DEVOPS_USER} -c 'pm2 logs $(pm2_app_name "$DOMAIN")'"
    if [[ "${WEBHOOK_ENABLE:-0}" -eq 1 || -n "${WEBHOOK_MODE:-}" ]]; then
      info "请执行: $0 webhook setup（若尚未安装监听）"
    fi
    hr
  elif [[ "$SITE_TYPE" = "proxy" ]]; then
    echo ""
    hr; info "[4/6] 跳过（反代无数据库）"
    hr; info "[5/6] 跳过（反代无 PHP）"
    hr; info "[6/6] 跳过（反代无 crontab）"
    echo ""
    hr
    ok "反代站点部署完成"
    info "访问: https://${DOMAIN}"
    info "上游: $(proxy_pass_for_site "$DOMAIN")"
    hr
  else
    echo ""
    hr; info "[4/6] 跳过（前端无数据库）"
    hr; info "[5/6] 跳过（前端无 PHP）"
    hr; info "[6/6] 跳过（前端无 crontab）"
    echo ""

    local _fe_add _dist_add="${WWW_ROOT}/${DOMAIN}"
    if _adding_frontend_release_webhook || frontend_release_webhook_site "$DOMAIN" 2>/dev/null; then
      warn "静态文件待 Release 推送后由 Webhook 写入 ${WWW_ROOT}/${DOMAIN}/"
      info "请执行: $0 webhook setup（若尚未安装监听）"
    else
      _fe_add=$(effective_frontend_subdir "$DOMAIN")
      [[ -n "$_fe_add" ]] && _dist_add="${_dist_add}/${_fe_add}"
      if [[ ! -d "$_dist_add" ]] || [[ -z "$(ls -A "$_dist_add" 2>/dev/null)" ]]; then
        warn "构建目录 ${_dist_add} 不存在或为空"
        info "请本地构建后推送或在服务器执行 npm run build"
      else
        ok "构建产物已就绪"
      fi
    fi

    echo ""
    hr
    ok "前端站点部署完成"
    info "访问: https://${DOMAIN}"
    info "目录: ${WWW_ROOT}/${DOMAIN}"
    hr
  fi

  [[ "${WEBHOOK_SAVED_ON_ADD:-0}" -eq 1 || "$SITE_TYPE" = "proxy" ]] || _webhook_save_on_add
}

# ═══════════════════════════════════════════════
#  子命令: update
# ═══════════════════════════════════════════════
cmd_update() {
  prompt_pick_domain "选择要更新的站点"
  [[ -n "$DOMAIN" ]] || { menu_fail "域名不能为空" || return 0; }

  local site_dir="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$site_dir" ]] || { menu_fail "站点 ${DOMAIN} 不存在（${site_dir}）" || return 0; }

  local site_type
  site_type="$(_site_type_for_domain "$DOMAIN")"

  echo ""
  hr; info "更新站点: ${DOMAIN} (${site_type})"; echo ""

  if [[ "$site_type" != "proxy" ]]; then
    if [[ "${WEBHOOK_ENABLE:-0}" -eq 1 || -n "${WEBHOOK_MODE:-}" ]]; then
      _webhook_configure_site || return 0
      [[ "${WEBHOOK_ONLY:-0}" -eq 1 ]] && { ok "Webhook 配置完成（未执行代码更新）"; return 0; }
    fi
  fi

  if [[ "$site_type" = "laravel" ]]; then
    ensure_php_fpm_slowlog_host_artifacts
    warn_php_fpm_slowlog_compose_missing
    ensure_php_fpm_wave_pool_host_artifacts
    warn_php_fpm_wave_pool_compose_missing
    ensure_mysql_low_memory_host_artifacts
    warn_mysql_low_memory_compose_missing
  fi

  if [[ "$site_type" = "proxy" ]]; then
    :
  elif frontend_release_webhook_site "$DOMAIN" 2>/dev/null; then
    warn "Webhook Release 站点：跳过 git 操作"
  elif [[ "${SKIP_GIT:-0}" -ne 1 && -d "${site_dir}/.git" ]]; then
    if [[ -n "${GIT_REF:-}" ]]; then
      _git_fetch_checkout "${site_dir}" "${GIT_REF}"
    else
      if [[ -z "${GIT_BRANCH:-}" ]]; then
        prompt "Git 分支（回车=当前分支 pull）" ""
        GIT_BRANCH=$PROMPT_RESULT
      fi
      _git_pull_or_clone "${site_dir}" "" "${GIT_BRANCH:-}"
    fi
    ok "代码已更新"
  else
    warn "未检测到 .git，跳过 git pull（请事先将新版本同步到 ${site_dir}）"
  fi

  if [[ "$site_type" = "laravel" ]]; then
    _collect_site_php_version_interactive
    apply_site_php_version_cli "$DOMAIN"
    ensure_site_php_container "$DOMAIN"

    info "composer install..."
    local uid gid
    uid=$(id -u "${DEVOPS_USER}")
    gid=$(id -g "${DEVOPS_USER}")
    local cname; cname="$(_php_container_for_site "$DOMAIN")"
    local _db_conn="mysql"
    if [[ -f "${site_dir}/.env" ]]; then
      _db_conn="$(grep -E '^DB_CONNECTION=' "${site_dir}/.env" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '[:space:]"'"'"'' || true)"
      [[ -z "$_db_conn" ]] && _db_conn="mysql"
    fi
    ensure_lnmp_php_laravel_extensions "$cname" "$_db_conn"
    ensure_composer_in_lnmp_php "$cname"
    docker exec -u "${uid}:${gid}" -e COMPOSER_CACHE_DIR=/tmp/composer-cache "$cname" \
      composer install \
      --working-dir="${CONTAINER_WWW}/${DOMAIN}" \
      --no-dev --no-interaction --optimize-autoloader --no-progress --prefer-dist

    chmod -R 775 "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    if command -v setfacl &>/dev/null; then
      setfacl -R  -m "u:${PHP_C_UID}:rwX" "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
      setfacl -dR -m "u:${PHP_C_UID}:rwX" "${site_dir}/storage" "${site_dir}/bootstrap/cache" 2>/dev/null || true
    fi

    if [[ -z "${RUN_MIGRATE}" ]]; then
      confirm "执行 migrate？" "y" && RUN_MIGRATE=y || RUN_MIGRATE=n
    fi
    if [[ "$RUN_MIGRATE" = "y" ]]; then
      info "artisan migrate..."
      docker_php_artisan "$DOMAIN" migrate --force
    else
      info "跳过 migrate（--run-migrate=n）"
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

    info "FrankenPHP reload（${cname}）..."
    docker exec "$cname" "$(_web_bin "$cname")" reload --config /etc/caddy/Caddyfile 2>/dev/null \
      && ok "FrankenPHP 已 reload（${cname}）" \
      || warn "FrankenPHP reload 失败；可手动: docker restart ${cname}"

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
    _caddy_reload_soft "Caddy 已 reload（与模板同步）"
  elif [[ "$site_type" = "pm2" ]]; then
    apply_site_pm2_port_cli "$DOMAIN"
    apply_site_pm2_cmd_cli "$DOMAIN"
    reload_pm2_site "$DOMAIN"
    gen_nginx_pm2 "$DOMAIN"
    _caddy_reload_soft "Caddy 已 reload"
  elif [[ "$site_type" = "proxy" ]]; then
    if [[ "${SITE_PROXY_PASS_CLI:-0}" -ne 1 && "${YES:-0}" -ne 1 ]]; then
      prompt "反代上游" "$(proxy_pass_for_site "$DOMAIN")"
      SITE_PROXY_PASS=$PROMPT_RESULT
      SITE_PROXY_PASS_CLI=1
    fi
    apply_site_proxy_pass_cli "$DOMAIN"
    gen_nginx_proxy "$DOMAIN"
    _caddy_reload_soft "Caddy 已 reload（→ $(proxy_pass_for_site "$DOMAIN")）"
  else
    if frontend_release_webhook_site "$DOMAIN" 2>/dev/null; then
      warn "Webhook Release 站点：请通过 Release 推送更新（update 不拉代码）"
      local _feu=""
      gen_nginx_frontend "$DOMAIN" ""
      fix_site_readable_for_nginx "$DOMAIN" "frontend" ""
    else
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
    fi
    _caddy_reload_soft "Caddy 已 reload"
  fi

  info "清理 Docker 悬空镜像..."
  docker image prune -f >/dev/null 2>&1 && ok "Docker 悬空镜像已清理" || true

  echo ""
  ok "站点 ${DOMAIN} 更新完成"
}

