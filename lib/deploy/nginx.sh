# shellcheck shell=bash

site_caddy_file() {
  printf '%s/%s.caddy' "${CADDY_SITES:-${DATA_DIR}/caddy/sites}" "$1"
}

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
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] || die "无效 --php-version: $v（应为 8.2 / 8.3）"
  _php_franken_ok "$v" || die "FrankenPHP 仅支持 PHP 8.2–8.5（当前: ${v}）"
  local _default_ver; _default_ver="$(_default_php_ver)"
  if [[ -n "$_default_ver" && "$v" = "$_default_ver" ]]; then
    rm -f "$f" 2>/dev/null || true
    container_ok "lnmp-php" || die "默认 lnmp-php 未运行"
    info "站点 ${domain} PHP 版本：${v}（=默认）→ 使用 lnmp-php"
    return 0
  fi
  local cname="lnmp-php$(_php_ver_no_dot "$v")"
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

interactive_sse_prefixes_maybe_for_update() {
  local domain="$1"
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
  info "SSE 来源:${src}  当前规则: ${cur_one:-<空>}（FrankenPHP 直出，改用 --sse-prefixes）"
}

_caddy_security_headers() {
  cat <<'CADDY'
	header X-Frame-Options SAMEORIGIN
	header X-Content-Type-Options nosniff
	header Referrer-Policy strict-origin-when-cross-origin
CADDY
}

_caddy_tls_block() {
  local domain="$1"
  local modef="${NGINX_CONF}/${domain}.tls-mode"
  local mode=""
  [[ -f "$modef" ]] && mode="$(head -n1 "$modef" | tr -d '[:space:]')"
  if [[ "$mode" = "file" ]]; then
    ensure_placeholder_cert "$domain"
    printf '\ttls /ssl/%s/fullchain.cer /ssl/%s/%s.key\n' "$domain" "$domain" "$domain"
  elif [[ "${SSL_STAGING:-0}" = "1" ]]; then
    printf '\ttls {\n\t\tca https://acme-staging-v02.api.letsencrypt.org/directory\n\t}\n'
  fi
}

_caddy_write_site() {
  local domain="$1" body="$2"
  local dir="${CADDY_SITES:-${DATA_DIR}/caddy/sites}"
  mkdir -p "$dir"
  local tls headers
  tls="$(_caddy_tls_block "$domain")"
  headers="$(_caddy_security_headers)"
  cat > "$(site_caddy_file "$domain")" <<CADDY
${domain} {
${tls}
${headers}
${body}
}
CADDY
  chmod 644 "$(site_caddy_file "$domain")" 2>/dev/null || true
  if declare -F _caddy_restore_webhook_proxy >/dev/null 2>&1; then
    _caddy_restore_webhook_proxy "$domain"
  fi
}

gen_caddy_laravel() {
  local domain="$1"
  local svc; svc="$(_php_service_for_site "$domain")"
  local body
  if [[ "$svc" = "php" ]]; then
    body=$(cat <<CADDY
	root * ${CONTAINER_WWW}/${domain}/public
	encode zstd gzip
	php_server {
		try_files {path} index.php
	}
	@static path *.js *.css *.png *.jpg *.jpeg *.gif *.ico *.svg *.woff *.woff2 *.ttf *.eot
	header @static Cache-Control "public, immutable"
	request_body {
		max_size 64MB
	}
CADDY
)
  else
    body=$(cat <<CADDY
	encode zstd gzip
	reverse_proxy ${svc}:8080 {
		flush_interval -1
		header_up Host {host}
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-Host {host}
	}
	request_body {
		max_size 64MB
	}
CADDY
)
  fi
  _caddy_write_site "$domain" "$body"
}

gen_nginx_laravel() { gen_caddy_laravel "$@"; }

gen_caddy_pm2() {
  local domain="$1" port="${2:-}"
  [[ -n "$port" ]] || port="$(pm2_port_for_site "$domain")"
  [[ "$port" =~ ^[0-9]+$ ]] || die "gen_caddy_pm2: 无效端口（${domain}）"
  local upstream_host
  upstream_host="$(_docker_host_gateway)"
  local body
  body=$(cat <<CADDY
	request_body {
		max_size 110MB
	}
	reverse_proxy ${upstream_host}:${port} {
		flush_interval -1
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}
CADDY
)
  _caddy_write_site "$domain" "$body"
}

gen_nginx_pm2() { gen_caddy_pm2 "$@"; }

_normalize_proxy_pass() {
  local u="${1:-}"
  u="${u#"${u%%[![:space:]]*}"}"
  u="${u%"${u##*[![:space:]]}"}"
  [[ -n "$u" ]] || return 1
  [[ "$u" != *://* ]] && u="http://${u}"
  case "$u" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  printf '%s' "$u"
}

_proxy_pass_for_caddy() {
  local u="$1" scheme rest hostport path host port
  scheme="${u%%://*}"
  rest="${u#*://}"
  if [[ "$rest" == */* ]]; then
    hostport="${rest%%/*}"
    path="/${rest#*/}"
  else
    hostport="$rest"
    path=""
  fi
  if [[ "$hostport" == \[* ]]; then
    printf '%s' "$u"
    return 0
  fi
  host="${hostport%%:*}"
  if [[ "$hostport" == *:* ]]; then
    port="${hostport#*:}"
  else
    port=""
  fi
  if [[ "$host" = "127.0.0.1" || "$host" = "localhost" ]]; then
    host="$(_docker_host_gateway)"
  fi
  if [[ -n "$port" ]]; then
    printf '%s://%s:%s%s' "$scheme" "$host" "$port" "$path"
  else
    printf '%s://%s%s' "$scheme" "$host" "$path"
  fi
}

gen_caddy_proxy() {
  local domain="$1" raw="${2:-}" nginx_url
  [[ -n "$raw" ]] || raw="$(proxy_pass_for_site "$domain")"
  raw="$(_normalize_proxy_pass "$raw")" || die "gen_caddy_proxy: 无效上游（${domain}）"
  nginx_url="$(_proxy_pass_for_caddy "$raw")"
  local body
  body=$(cat <<CADDY
	request_body {
		max_size 100MB
	}
	reverse_proxy ${nginx_url} {
		flush_interval -1
		header_up X-Real-IP {remote_host}
		header_up X-Forwarded-For {remote_host}
		header_up X-Forwarded-Proto {scheme}
	}
CADDY
)
  _caddy_write_site "$domain" "$body"
}

gen_nginx_proxy() { gen_caddy_proxy "$@"; }

gen_caddy_frontend() {
  local domain="$1" sub="$2"
  local root_path="${CONTAINER_WWW}/${domain}"
  [[ -n "$sub" ]] && root_path="${CONTAINER_WWW}/${domain}/${sub}"
  local body
  body=$(cat <<CADDY
	root * ${root_path}
	encode zstd gzip
	try_files {path} {path}.html {path}/index.html /index.html
	file_server
	@html path /index.html
	header @html Cache-Control "no-cache"
	@assets path *.js *.css *.woff2 *.png *.jpg *.jpeg *.gif *.ico *.svg *.woff *.ttf *.eot
	header @assets Cache-Control "public, immutable"
CADDY
)
  _caddy_write_site "$domain" "$body"
}

gen_nginx_frontend() { gen_caddy_frontend "$@"; }

effective_frontend_subdir() {
  local domain="$1"
  local site="${WWW_ROOT}/${domain}"
  local fe="${FRONTEND_ROOT:-}"
  [[ "$fe" = "." ]] && fe=""
  if [[ -n "$fe" ]]; then
    printf '%s\n' "$fe"
    return
  fi
  [[ -f "${site}/index.html" ]] && { printf '%s\n' ""; return; }
  local d
  for d in dist out .output/public build output; do
    [[ -f "${site}/${d}/index.html" ]] || continue
    printf '%s\n' "$d"
    return
  done
  if [[ -d "${site}/dist" ]]; then
    printf '%s\n' "dist"
    return
  fi
  printf '%s\n' ""
}
