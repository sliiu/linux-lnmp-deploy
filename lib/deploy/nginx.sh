# shellcheck shell=bash

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
  # 与 /etc/lnmp-env.conf 中 PHP_VERSION（默认 lnmp-php 容器）相同时短路：避免去找 lnmp-phpNN
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

# 输出一个 SSE location 块到 stdout；调用方负责拼接
# $document_root / $request_uri 等保持 nginx 原变量字面量，不可被 shell 展开
_laravel_sse_emit_upstream_block() {
  local hdr="$1" svc="$2"
  cat <<NGINX
${hdr}
        gzip                 off;
        include              fastcgi_params;
        fastcgi_pass         ${svc}:9001;
        fastcgi_index        index.php;
        fastcgi_param        SCRIPT_FILENAME \$document_root/index.php;
        fastcgi_param        DOCUMENT_ROOT \$document_root;
        fastcgi_param        REQUEST_URI \$request_uri;
        fastcgi_param        QUERY_STRING \$query_string;
        fastcgi_buffering    off;
        fastcgi_read_timeout 86400s;
        fastcgi_send_timeout 86400s;
        fastcgi_buffer_size  32k;
        fastcgi_buffers      8 16k;
    }

NGINX
}

# 把单个 token（已 trim、已去重）渲染为对应的 location 块到 stdout
_laravel_sse_emit_one_pattern() {
  local tok="$1" svc="$2" hdr rx
  if [[ "$tok" =~ ^~\*(.+)$ ]]; then
    _laravel_sse_emit_upstream_block "    location ~* ${BASH_REMATCH[1]} {" "$svc"
  elif [[ "$tok" =~ ^~(.+)$ ]]; then
    _laravel_sse_emit_upstream_block "    location ~ ${BASH_REMATCH[1]} {" "$svc"
  elif [[ "$tok" == *'{'*'}'* ]]; then
    tok="${tok#/}"
    [[ "$tok" == /* ]] || tok="/$tok"
    if rx=$(_laravel_sse_brace_path_to_nginx_regex "$tok") 2>/dev/null; then
      printf -v hdr '    location ~ %s {' "$rx"
      _laravel_sse_emit_upstream_block "$hdr" "$svc"
    fi
  else
    tok="${tok#/}"
    tok="${tok%/}"
    [[ -z "$tok" || "$tok" == '~' ]] && return 0
    _laravel_sse_emit_upstream_block "    location ^~ /${tok} {" "$svc"
  fi
}

_nginx_laravel_sse_location_blocks() {
  local raw="${1:-}" svc="${2:-php}"
  local line tok seen=" "
  local -a parts
  [[ -z "$raw" ]] && raw="${LARAVEL_SSE_PREFIXES:-wave}"
  # 每行可多条（空格/逗号）；禁止用「是否含换行」分支：单行文件末尾也有 \n，会把整行当一条 token 导致 {param} 路径未拆开
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    read -ra parts <<< "$(printf '%s' "$line" | tr ',' ' ')"
    for tok in "${parts[@]}"; do
      tok="${tok#"${tok%%[![:space:]]*}"}"
      tok="${tok%"${tok##*[![:space:]]}"}"
      [[ -z "$tok" ]] && continue
      case "${seen}" in *"|${tok}|"*) continue ;; esac
      seen+="|${tok}| "
      _laravel_sse_emit_one_pattern "$tok" "$svc"
    done
  done < <(printf '%s\n' "$raw")
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

