# shellcheck shell=bash
conf_load() {
  DEVOPS_USER="${DEVOPS_USER:-devops}"
  GH_PROXY="${GH_PROXY:-}"
  DOCKER_MIRRORS_STR="${DOCKER_MIRRORS_STR:-}"
  ALPINE_MIRROR="${ALPINE_MIRROR:-mirrors.aliyun.com}"
  NODE_VERSION="${NODE_VERSION:-22}"
  FNM_NODE_DIST_MIRROR="${FNM_NODE_DIST_MIRROR:-https://npmmirror.com/mirrors/node}"
  PHP_VERSION="${PHP_VERSION:-8.3}"
  EXTRA_PHP_VERSIONS="${EXTRA_PHP_VERSIONS:-}"
  PHP_EXTENSIONS="${PHP_EXTENSIONS:-pdo_mysql,opcache,mysqli,curl,gd,xml,dom,pcntl,bcmath,sockets,mbstring,zip,exif,intl,fileinfo,redis}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  SSH_PORT="${SSH_PORT:-22}"
  ROOT_LOGIN="${ROOT_LOGIN:-prohibit-password}"
  WHEEL_USER="${WHEEL_USER:-}"
  CYBER_ORDINARY="${CYBER_ORDINARY:-}"
  CYBER_AUDIT="${CYBER_AUDIT:-}"
  CYBER_SAFE="${CYBER_SAFE:-}"
  LNMP_SERVICES="${LNMP_SERVICES:-php,mysql,redis,acme}"
  CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
  NGINX_IMAGE="${NGINX_IMAGE:-nginx:stable-alpine}"
  MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0}"
  POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
  REDIS_IMAGE="${REDIS_IMAGE:-redis:alpine}"
  ACME_IMAGE="${ACME_IMAGE:-neilpang/acme.sh:latest}"
  PHPMYADMIN_IMAGE="${PHPMYADMIN_IMAGE:-phpmyadmin:latest}"
  PHPMYADMIN_BIND="${PHPMYADMIN_BIND:-127.0.0.1}"
  PHPMYADMIN_PORT="${PHPMYADMIN_PORT:-8080}"
  MYSQL_ROOT_PWD="${MYSQL_ROOT_PWD:-}"
  POSTGRES_PWD="${POSTGRES_PWD:-}"
  [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
  ACME_SSL_DNS_DEFAULT="${ACME_SSL_DNS_DEFAULT:-webroot}"
  CONTAINER_WWW="${CONTAINER_WWW:-${DATA_DIR}/www}"
  CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
  _normalize_lnmp_web_services
}

_normalize_lnmp_web_services() {
  local s=",${LNMP_SERVICES}," had_nginx=0 had_php=0
  [[ "$s" = *",nginx,"* ]] && had_nginx=1
  [[ "$s" = *",php,"* ]] && had_php=1
  [[ $had_nginx -eq 0 ]] && return 0
  s="${s//,nginx,/,}"
  if [[ $had_php -eq 0 && "$s" != *",caddy,"* ]]; then
    s=",caddy${s}"
  fi
  s="${s//,,/,}"
  s="${s#,}"
  s="${s%,}"
  LNMP_SERVICES="$s"
}

conf_save() {
  cat > "$CONF_FILE" <<EOF
DEVOPS_USER=${DEVOPS_USER}
NODE_VERSION=${NODE_VERSION}
FNM_NODE_DIST_MIRROR=${FNM_NODE_DIST_MIRROR}
GH_PROXY=${GH_PROXY}
DOCKER_MIRRORS_STR=${DOCKER_MIRRORS_STR}
ALPINE_MIRROR=${ALPINE_MIRROR}
PHP_VERSION=${PHP_VERSION}
EXTRA_PHP_VERSIONS=${EXTRA_PHP_VERSIONS}
PHP_EXTENSIONS=${PHP_EXTENSIONS}
ACME_EMAIL=${ACME_EMAIL}
ACME_SSL_DNS_DEFAULT=${ACME_SSL_DNS_DEFAULT}
SSH_PORT=${SSH_PORT}
ROOT_LOGIN=${ROOT_LOGIN}
WHEEL_USER=${WHEEL_USER}
CYBER_ORDINARY=${CYBER_ORDINARY}
CYBER_AUDIT=${CYBER_AUDIT}
CYBER_SAFE=${CYBER_SAFE}
LNMP_SERVICES=${LNMP_SERVICES}
CADDY_IMAGE=${CADDY_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
MYSQL_IMAGE=${MYSQL_IMAGE}
POSTGRES_IMAGE=${POSTGRES_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
ACME_IMAGE=${ACME_IMAGE}
PHPMYADMIN_IMAGE=${PHPMYADMIN_IMAGE}
PHPMYADMIN_BIND=${PHPMYADMIN_BIND}
PHPMYADMIN_PORT=${PHPMYADMIN_PORT}
CONTAINER_WWW=${CONTAINER_WWW}
EOF
  chmod 600 "$CONF_FILE"
}

