# shellcheck shell=bash

_normalize_db_connection() {
  local c="${1:-mysql}"
  case "$c" in
    postgres|postgresql|pgsql) printf 'pgsql' ;;
    mysql|mariadb) printf 'mysql' ;;
    *) die "无效 DB 类型: $c（mysql | pgsql）" ;;
  esac
}

_default_db_connection() {
  if container_ok "lnmp-mysql"; then printf 'mysql'; return 0; fi
  if container_ok "lnmp-postgres"; then printf 'pgsql'; return 0; fi
  printf 'mysql'
}

_default_db_host() {
  case "$(_normalize_db_connection "${1:-mysql}")" in
    pgsql) printf 'postgres' ;;
    *) printf 'mysql' ;;
  esac
}

_db_port_for_connection() {
  case "$(_normalize_db_connection "${1:-mysql}")" in
    pgsql) printf '5432' ;;
    *) printf '3306' ;;
  esac
}

_db_user_for_connection() {
  case "$(_normalize_db_connection "${1:-mysql}")" in
    pgsql) printf 'postgres' ;;
    *) printf 'root' ;;
  esac
}

_validate_db_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]] || die "无效库名: ${name}（仅允许字母、数字、下划线）"
}

_validate_laravel_db_config() {
  local conn db_host db_name
  conn="$(_normalize_db_connection "${DB_CONNECTION:-mysql}")"
  db_host="${DB_HOST:-$(_default_db_host "$conn")}"
  db_name="${DB_NAME:-}"
  case "$conn" in
    mysql)
      [[ "$db_name" = "mysql" && "$db_host" = "mysql" ]] \
        && { menu_fail "DB_DATABASE 不能为 mysql（与 DB_HOST=mysql 同时出现时多为填反）。库名请用业务名如 payment" || return 1; }
      ;;
    pgsql)
      [[ "$db_name" = "postgres" && "$db_host" = "postgres" ]] \
        && { menu_fail "DB_DATABASE 不能为 postgres（与 DB_HOST=postgres 同时出现时多为填反）。库名请用业务名如 payment" || return 1; }
      ;;
  esac
}

_write_laravel_db_env() {
  local envfile="$1"
  local conn host port user
  conn="$(_normalize_db_connection "${DB_CONNECTION:-mysql}")"
  host="${DB_HOST:-$(_default_db_host "$conn")}"
  port="${DB_PORT:-$(_db_port_for_connection "$conn")}"
  user="${DB_USERNAME:-$(_db_user_for_connection "$conn")}"

  env_set "DB_CONNECTION" "$conn" "$envfile"
  env_set "DB_HOST"       "$host" "$envfile"
  env_set "DB_PORT"       "$port" "$envfile"
  env_set "DB_DATABASE"   "${DB_NAME}" "$envfile"
  env_set "DB_USERNAME"   "$user" "$envfile"
  env_set "DB_PASSWORD"   "${DB_PWD}" "$envfile"
}

_collect_db_connection_interactive() {
  if [[ -n "${DB_CONNECTION:-}" ]]; then
    DB_CONNECTION="$(_normalize_db_connection "$DB_CONNECTION")"
    return 0
  fi
  local _mysql_ok=0 _pg_ok=0 _i
  container_ok "lnmp-mysql" && _mysql_ok=1
  container_ok "lnmp-postgres" && _pg_ok=1
  if [[ $_mysql_ok -eq 1 && $_pg_ok -eq 1 ]]; then
    menu_select "数据库类型" "MySQL (lnmp-mysql)" "PostgreSQL (lnmp-postgres)"
    _i=$MENU_SELECT_RESULT
    case "$_i" in
      1) DB_CONNECTION=pgsql ;;
      *) DB_CONNECTION=mysql ;;
    esac
  elif [[ $_pg_ok -eq 1 ]]; then
    DB_CONNECTION=pgsql
    info "检测到 lnmp-postgres，使用 PostgreSQL"
  else
    DB_CONNECTION=mysql
  fi
  DB_CONNECTION="$(_normalize_db_connection "$DB_CONNECTION")"
}

create_database() {
  local db_name="$1" db_pwd="$2" db_host="${3:-}" db_conn="${4:-mysql}"
  local conn
  conn="$(_normalize_db_connection "$db_conn")"
  db_host="${db_host:-$(_default_db_host "$conn")}"
  _validate_db_name "$db_name"

  case "$conn" in
    pgsql)
      if [[ "$db_host" = "postgres" ]] && container_ok "lnmp-postgres"; then
        if docker exec -e PGPASSWORD="${db_pwd}" lnmp-postgres \
          psql -U postgres -v ON_ERROR_STOP=1 -tc "SELECT 1 FROM pg_database WHERE datname = '${db_name}'" 2>/dev/null \
          | grep -q 1; then
          ok "数据库 ${db_name} 已存在"
        elif docker exec -e PGPASSWORD="${db_pwd}" lnmp-postgres \
          psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${db_name}\" ENCODING 'UTF8'" 2>/dev/null; then
          ok "数据库 ${db_name} 已就绪"
        else
          warn "PostgreSQL 建库失败（可能已存在或密码错误）"
        fi
      else
        warn "lnmp-postgres 未运行或 DB_HOST=${db_host}，跳过建库"
      fi
      ;;
    mysql)
      if [[ "$db_host" = "mysql" ]] && container_ok "lnmp-mysql"; then
        docker exec lnmp-mysql mysql -uroot -p"${db_pwd}" \
          -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null \
          && ok "数据库 ${db_name} 已就绪" \
          || warn "建库命令返回错误（可能已存在或密码错误）"
      else
        warn "lnmp-mysql 未运行或 DB_HOST=${db_host}，跳过建库"
      fi
      ;;
  esac
}
