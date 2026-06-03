# shellcheck shell=bash

WEBHOOK_DIR="${DATA_DIR}/webhook"
WEBHOOK_HISTORY_DIR="${DATA_DIR}/deploy-history"
WEBHOOK_LISTENER_ENV="${WEBHOOK_DIR}/listener.env"
WEBHOOK_SYSTEMD_UNIT="/etc/systemd/system/lnmp-deploy-webhook.service"

site_webhook_file() { printf '%s/%s.webhook' "$NGINX_CONF" "$1"; }

# 静态站点 + webhook release：产物直接解压到站点根，不用 dist/子目录
frontend_release_webhook_site() {
  local domain="$1" mode
  [[ -f "$(site_webhook_file "$domain")" ]] || return 1
  mode="$(_webhook_read_kv "$(site_webhook_file "$domain")" mode)" || return 1
  [[ "$mode" = "release" ]]
}

_adding_frontend_release_webhook() {
  [[ "${SITE_TYPE:-}" = "frontend" && "${WEBHOOK_MODE:-}" = "release" && "${WEBHOOK_ENABLE:-0}" -eq 1 ]]
}

_webhook_history_file() { printf '%s/%s/history.tsv' "$WEBHOOK_HISTORY_DIR" "$1"; }
_webhook_lock_file()    { printf '%s/%s/.deploy.lock' "$WEBHOOK_HISTORY_DIR" "$1"; }

_webhook_gen_secret() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 24
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# 统一为 provider:owner/repo（小写 host/path）
_webhook_normalize_repo() {
  local raw="${1:-}" u host path provider owner repo
  raw="${raw%/}"
  raw="${raw%.git}"
  if [[ "$raw" =~ ^git@([^:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^https?://([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^([^/]+)/([^/]+)$ ]]; then
    host=""
    path="${raw}"
  else
    printf '%s' "$raw"
    return 0
  fi
  host="${host#www.}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
  case "$host" in
    github.com) provider=github ;;
    gitee.com)  provider=gitee ;;
    *) provider="${host:-unknown}" ;;
  esac
  owner="${path%%/*}"
  repo="${path#*/}"
  repo="${repo%%/*}"
  printf '%s:%s/%s' "$provider" "$owner" "$repo"
}

_webhook_read_kv() {
  local file="$1" key="$2" line k v
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" != *=* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    [[ "$k" = "$key" ]] && { printf '%s' "$v"; return 0; }
  done < "$file"
  return 1
}

_webhook_write_site_config() {
  local domain="$1" mode="$2" git_repo="$3" release_name="${4:-}" secret="${5:-}"
  local f; f="$(site_webhook_file "$domain")"
  mkdir -p "$NGINX_CONF"
  [[ -n "$secret" ]] || secret="$(_webhook_gen_secret)"
  if [[ "$mode" = "release" ]]; then
    cat > "$f" <<EOF
enabled=1
mode=release
git_repo=${git_repo}
release_name=${release_name}
secret=${secret}
EOF
  else
    cat > "$f" <<EOF
enabled=1
mode=${mode}
git_repo=${git_repo}
release_name=${release_name}
secret=${secret}
EOF
  fi
  chmod 600 "$f"
  printf '%s' "$secret"
}

_webhook_load_listener_env() {
  local _pm="${WEBHOOK_PUBLIC_MODE:-}" _bind="${WEBHOOK_BIND:-}" _port="${WEBHOOK_PORT:-}" \
        _path="${WEBHOOK_PATH:-}" _proxy="${WEBHOOK_PROXY_DOMAIN:-}"
  WEBHOOK_PORT="${WEBHOOK_PORT:-9080}"
  WEBHOOK_BIND="${WEBHOOK_BIND:-127.0.0.1}"
  WEBHOOK_PATH="${WEBHOOK_PATH:-/hooks}"
  WEBHOOK_PUBLIC_MODE="${WEBHOOK_PUBLIC_MODE:-local}"
  WEBHOOK_PROXY_DOMAIN="${WEBHOOK_PROXY_DOMAIN:-}"
  if [[ -f "$WEBHOOK_LISTENER_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$WEBHOOK_LISTENER_ENV"
  fi
  [[ -n "$_pm" ]]    && WEBHOOK_PUBLIC_MODE="$_pm"
  [[ -n "$_bind" ]]  && WEBHOOK_BIND="$_bind"
  [[ -n "$_port" ]]  && WEBHOOK_PORT="$_port"
  [[ -n "$_path" ]]  && WEBHOOK_PATH="$_path"
  if [[ -n "$_proxy" ]]; then WEBHOOK_PROXY_DOMAIN="$_proxy"; fi
}

_webhook_acquire_lock() {
  local domain="$1"
  local lf; lf="$(_webhook_lock_file "$domain")"
  mkdir -p "$(dirname "$lf")"
  if ! ( set -o noclobber; echo "$$" > "$lf" ) 2>/dev/null; then
    warn "站点 ${domain} 正在部署中，跳过"
    return 1
  fi
  return 0
}

_webhook_release_lock() {
  local domain="$1"
  rm -f "$(_webhook_lock_file "$domain")" 2>/dev/null || true
}

_webhook_backup_site() {
  local domain="$1" version="$2" mode="$3"
  local site_dir="${WWW_ROOT}/${domain}"
  local ts bid hf meta
  ts="$(date '+%Y%m%d%H%M%S')"
  bid="${WEBHOOK_HISTORY_DIR}/${domain}/${ts}_${version//\//_}"
  hf="$(_webhook_history_file "$domain")"
  mkdir -p "$bid" "$(dirname "$hf")"

  if [[ -f "${site_dir}/artisan" ]]; then
    local ref=""
    if [[ -d "${site_dir}/.git" ]]; then
      ref="$(su - "${DEVOPS_USER}" -c "cd '${site_dir}' && git rev-parse HEAD 2>/dev/null" || true)"
    fi
    meta="${bid}/meta.conf"
    cat > "$meta" <<EOF
mode=${mode}
version=${version}
git_ref=${ref}
site_type=laravel
EOF
  else
    meta="${bid}/meta.conf"
    cat > "$meta" <<EOF
mode=${mode}
version=${version}
site_type=frontend
EOF
    if [[ -d "$site_dir" ]]; then
      rsync -a --delete "${site_dir}/" "${bid}/snapshot/" 2>/dev/null \
        || cp -a "${site_dir}/." "${bid}/snapshot/" 2>/dev/null || true
    fi
  fi

  printf '%s|%s|%s|%s\n' "$ts" "$version" "$mode" "$bid" >> "$hf"
  tail -n 20 "$hf" > "${hf}.tmp" 2>/dev/null && mv "${hf}.tmp" "$hf" || true
  printf '%s' "$bid"
}

_webhook_list_history() {
  local domain="$1" hf
  hf="$(_webhook_history_file "$domain")"
  [[ -f "$hf" ]] || return 0
  local n=1 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%3d) %s\n' "$n" "$line"
    n=$((n + 1))
  done < "$hf"
}

_webhook_history_entry() {
  local domain="$1" idx="$2" hf line n=1
  hf="$(_webhook_history_file "$domain")"
  [[ -f "$hf" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$n" -eq "$idx" ]] && { printf '%s' "$line"; return 0; }
    n=$((n + 1))
  done < "$hf"
  return 1
}

_webhook_restore_backup() {
  local domain="$1" backup_dir="$2"
  local site_dir="${WWW_ROOT}/${domain}" meta st
  [[ -d "$backup_dir" ]] || die "备份不存在: ${backup_dir}"
  meta="${backup_dir}/meta.conf"
  [[ -f "$meta" ]] || die "缺少 meta.conf"

  st="$(_webhook_read_kv "$meta" site_type)"
  if [[ "$st" = "laravel" ]]; then
    local ref; ref="$(_webhook_read_kv "$meta" git_ref)"
    [[ -n "$ref" ]] || die "Laravel 备份无 git_ref"
    [[ -d "${site_dir}/.git" ]] || die "站点无 .git，无法回退 git ref"
    _git_fetch_checkout "$site_dir" "$ref"
    DOMAIN="$domain"
    YES=1
    RUN_MIGRATE=n
    SKIP_GIT=1
    cmd_update
    SKIP_GIT=0
  else
    [[ -d "${backup_dir}/snapshot" ]] || die "前端备份 snapshot 不存在"
    rsync -a --delete "${backup_dir}/snapshot/" "${site_dir}/" 2>/dev/null \
      || { rm -rf "${site_dir:?}/"* 2>/dev/null; cp -a "${backup_dir}/snapshot/." "${site_dir}/"; }
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "$site_dir" 2>/dev/null || true
    local fe=""
    gen_nginx_frontend "$domain" ""
    fix_site_readable_for_nginx "$domain" "frontend" ""
    if container_ok "lnmp-nginx"; then
      docker exec lnmp-nginx nginx -t 2>&1 && docker exec lnmp-nginx nginx -s reload 2>/dev/null && ok "Nginx 已 reload"
    fi
  fi
}

_webhook_verify_github_sig() {
  local body_file="$1" sig="${2:-}" secret="${3:-}"
  [[ -n "$secret" ]] || return 1
  local body expected digest
  body="$(cat "$body_file")"
  if [[ "$sig" =~ ^sha256=([a-f0-9]+)$ ]]; then
    expected="${BASH_REMATCH[1]}"
    digest="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" 2>/dev/null | awk '{print $NF}')"
    [[ "$digest" = "$expected" ]]
    return $?
  fi
  if [[ "$sig" =~ ^sha1=([a-f0-9]+)$ ]]; then
    expected="${BASH_REMATCH[1]}"
    digest="$(printf '%s' "$body" | openssl dgst -sha1 -hmac "$secret" 2>/dev/null | awk '{print $NF}')"
    [[ "$digest" = "$expected" ]]
    return $?
  fi
  return 1
}

_webhook_verify_gitee_token() {
  local token="${1:-}" secret="${2:-}"
  [[ -n "$secret" && "$token" = "$secret" ]]
}

_webhook_json_field() {
  local file="$1" pattern="$2"
  { grep -oE "$pattern" "$file" 2>/dev/null | head -n1 | sed 's/^[^:]*://; s/^"//; s/"$//; s/\\"/"/g'; } || true
}

_webhook_sites_for_repo() {
  local norm="$1" conf name mode repo
  for conf in "${NGINX_CONF}"/*.webhook; do
    [[ -f "$conf" ]] || continue
    [[ "$(_webhook_read_kv "$conf" enabled)" = "1" ]] || continue
    repo="$(_webhook_read_kv "$conf" git_repo)"
    [[ -n "$repo" ]] || continue
    [[ "$(_webhook_normalize_repo "$repo")" = "$norm" ]] || continue
    name=$(basename "$conf" .webhook)
    mode="$(_webhook_read_kv "$conf" mode)"
    printf '%s|%s\n' "$name" "$mode"
  done
}

_webhook_release_name_match() {
  local expected="${1:-}" actual_name="${2:-}" actual_tag="${3:-}"
  [[ -n "$expected" ]] || return 0
  [[ "$expected" = "$actual_name" || "$expected" = "$actual_tag" ]] && return 0
  return 1
}

_webhook_download_url() {
  local url="$1" dest="$2" token="${3:-}"
  local auth=()
  [[ -n "$token" ]] && auth=(-H "Authorization: Bearer ${token}")
  if command -v curl &>/dev/null; then
    curl -fsSL "${auth[@]}" -o "$dest" "$url" || return 1
  elif command -v wget &>/dev/null; then
    [[ -n "$token" ]] && wget -q --header="Authorization: Bearer ${token}" -O "$dest" "$url" || wget -q -O "$dest" "$url" || return 1
  else
    die "缺少 curl/wget"
  fi
}

_webhook_extract_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.zip)
      command -v unzip &>/dev/null || die "缺少 unzip"
      unzip -oq "$archive" -d "$dest"
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "$archive" -C "$dest"
      ;;
    *.tar)
      tar -xf "$archive" -C "$dest"
      ;;
    *) die "不支持的压缩包: ${archive}" ;;
  esac
  local top
  top="$(find "$dest" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)"
  if [[ -n "$top" && "$(find "$dest" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]]; then
    shopt -s dotglob
    mv "$top"/* "$dest/" 2>/dev/null || true
    rmdir "$top" 2>/dev/null || true
    shopt -u dotglob
  fi
}

_webhook_pick_release_asset_url() {
  local body_file="$1" asset_hint="${2:-}"
  local url name
  if [[ -n "$asset_hint" ]]; then
    while IFS= read -r line; do
      name="$(printf '%s' "$line" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
      url="$(printf '%s' "$line" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')"
      [[ -n "$url" && "$name" = *"$asset_hint"* ]] && { printf '%s' "$url"; return 0; }
    done < <(grep -oE '\{[^{}]*"browser_download_url"[^{}]*\}' "$body_file" 2>/dev/null || true)
  fi
  url="$(_webhook_json_field "$body_file" '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  url="$(_webhook_json_field "$body_file" '"zipball_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  url="$(_webhook_json_field "$body_file" '"tarball_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  printf '%s' "$url"
}

_webhook_deploy_release() {
  local domain="$1" body_file="$2" release_name="${3:-}" release_tag="${4:-}" download_url="${5:-}"
  local site_dir="${WWW_ROOT}/${domain}" wf asset_hint token tmp arch ver
  wf="$(site_webhook_file "$domain")"
  asset_hint="$(_webhook_read_kv "$wf" asset_name)"
  token="${WEBHOOK_GITHUB_TOKEN:-${WEBHOOK_GITEE_TOKEN:-}}"
  ver="${release_tag:-$release_name}"
  [[ -n "$ver" ]] || ver="release"

  _webhook_acquire_lock "$domain" || return 1
  trap '_webhook_release_lock "'"$domain"'"' RETURN

  _webhook_backup_site "$domain" "$ver" "release" >/dev/null

  [[ -n "$download_url" ]] || download_url="$(_webhook_pick_release_asset_url "$body_file" "$asset_hint")"
  [[ -n "$download_url" ]] || die "未找到 release 下载地址"

  tmp="$(mktemp -d)"
  arch="${tmp}/pkg"
  case "$download_url" in
    *.zip|*zipball*) arch="${arch}.zip" ;;
    *) arch="${arch}.tar.gz" ;;
  esac
  info "下载 release: ${download_url}"
  _webhook_download_url "$download_url" "$arch" "$token" || die "下载失败"

  mkdir -p "$site_dir"
  _webhook_extract_archive "$arch" "${tmp}/extract"
  rsync -a --delete "${tmp}/extract/" "$site_dir/" 2>/dev/null \
    || cp -a "${tmp}/extract/." "$site_dir/"
  rm -rf "$tmp"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "$site_dir" 2>/dev/null || true

  gen_nginx_frontend "$domain" ""
  fix_site_readable_for_nginx "$domain" "frontend" ""
  if container_ok "lnmp-nginx"; then
    docker exec lnmp-nginx nginx -t 2>&1 && docker exec lnmp-nginx nginx -s reload 2>/dev/null && ok "Nginx 已 reload"
  fi
  ok "站点 ${domain} 已更新到 release ${ver}"
}

_webhook_deploy_tag() {
  local domain="$1" tag="$2"
  local site_dir="${WWW_ROOT}/${domain}"
  [[ -d "${site_dir}/.git" ]] || die "站点 ${domain} 无 .git，无法按 tag 更新"

  _webhook_acquire_lock "$domain" || return 1
  trap '_webhook_release_lock "'"$domain"'"' RETURN

  _webhook_backup_site "$domain" "$tag" "tag" >/dev/null
  _git_fetch_checkout "$site_dir" "$tag"
  DOMAIN="$domain"
  YES=1
  RUN_MIGRATE="${WEBHOOK_RUN_MIGRATE:-y}"
  GIT_REF=""
  SKIP_GIT=1
  cmd_update
  SKIP_GIT=0
  ok "站点 ${domain} 已更新到 tag ${tag}"
}

_webhook_json_release_name() {
  local body_file="$1"
  local block name
  block="$(grep -oE '"release"[[:space:]]*:[[:space:]]*\{[^}]+\}' "$body_file" 2>/dev/null | head -n1 || true)"
  if [[ -n "$block" ]]; then
    name="$(grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$block" 2>/dev/null | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
  fi
  _webhook_json_field "$body_file" '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"'
}

_webhook_process_payload() {
  local body_file="$1" event="${2:-}" gh_sig="${3:-}" gitee_token="${4:-}"

  local action ref repo_full clone_url html_url norm provider
  action="$(_webhook_json_field "$body_file" '"action"[[:space:]]*:[[:space:]]*"[^"]+"')"
  ref="$(_webhook_json_field "$body_file" '"ref"[[:space:]]*:[[:space:]]*"[^"]+"')"
  repo_full="$(_webhook_json_field "$body_file" '"full_name"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -z "$repo_full" ]] && repo_full="$(_webhook_json_field "$body_file" '"path_with_namespace"[[:space:]]*:[[:space:]]*"[^"]+"')"
  clone_url="$(_webhook_json_field "$body_file" '"clone_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -z "$clone_url" ]] && clone_url="$(_webhook_json_field "$body_file" '"git_ssh_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  html_url="$(_webhook_json_field "$body_file" '"html_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -z "$html_url" ]] && html_url="$(_webhook_json_field "$body_file" '"url"[[:space:]]*:[[:space:]]*"https://gitee\.com[^"]+"')"
  [[ -n "$repo_full" ]] && norm="$(_webhook_normalize_repo "$repo_full")"
  [[ -z "$norm" && -n "$clone_url" ]] && norm="$(_webhook_normalize_repo "$clone_url")"
  [[ -z "$norm" && -n "$html_url" ]] && norm="$(_webhook_normalize_repo "$html_url")"
  [[ -n "$norm" ]] || { warn "无法解析仓库"; return 1; }
  provider="${norm%%:*}"

  local rel_name rel_tag dl_url tag_name
  rel_tag="$(_webhook_json_field "$body_file" '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"')"
  rel_name="$(_webhook_json_release_name "$body_file")"
  tag_name="${rel_tag:-}"

  local matched=0 line domain mode wf secret ok_verify=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    domain="${line%%|*}"
    mode="${line#*|}"
    wf="$(site_webhook_file "$domain")"
    secret="$(_webhook_read_kv "$wf" secret)"
    ok_verify=0
    if [[ "$provider" = "github" && -n "$gh_sig" ]]; then
      _webhook_verify_github_sig "$body_file" "$gh_sig" "$secret" && ok_verify=1
    elif [[ "$provider" = "gitee" && -n "$gitee_token" ]]; then
      _webhook_verify_gitee_token "$gitee_token" "$secret" && ok_verify=1
    elif [[ -n "$gh_sig" ]]; then
      _webhook_verify_github_sig "$body_file" "$gh_sig" "$secret" && ok_verify=1
    elif [[ -n "$gitee_token" ]]; then
      _webhook_verify_gitee_token "$gitee_token" "$secret" && ok_verify=1
    fi
    [[ "$ok_verify" -eq 1 ]] || { warn "站点 ${domain} webhook 签名校验失败，跳过"; continue; }

    if [[ "$mode" = "release" ]]; then
      [[ "$event" = "release" || "$event" = "Release Hook" || -n "$rel_tag" ]] || continue
      [[ "$action" = "published" || "$action" = "publish" || -z "$action" || "$event" = "Release Hook" ]] || continue
      local expected="$(_webhook_read_kv "$wf" release_name)"
      _webhook_release_name_match "$expected" "$rel_name" "$rel_tag" || continue
      _webhook_deploy_release "$domain" "$body_file" "$rel_name" "$rel_tag" "$dl_url"
      matched=1
    elif [[ "$mode" = "tag" ]]; then
      local tag="${ref#refs/tags/}"
      [[ -n "$tag" && "$ref" == refs/tags/* ]] || continue
      [[ "$event" = "push" || "$event" = "Push Hook" || "$event" = "Tag Push Hook" ]] || continue
      _webhook_deploy_tag "$domain" "$tag"
      matched=1
    fi
  done < <(_webhook_sites_for_repo "$norm")

  if [[ "$matched" -eq 1 ]]; then
    return 0
  fi
  info "无匹配站点（仓库 ${norm}）"
  return 0
}

_webhook_write_listener_env() {
  mkdir -p "$WEBHOOK_DIR"
  cat > "$WEBHOOK_LISTENER_ENV" <<EOF
WEBHOOK_PORT=${WEBHOOK_PORT:-9080}
WEBHOOK_BIND=${WEBHOOK_BIND:-127.0.0.1}
WEBHOOK_PATH=${WEBHOOK_PATH:-/hooks}
WEBHOOK_PUBLIC_MODE=${WEBHOOK_PUBLIC_MODE:-local}
WEBHOOK_PROXY_DOMAIN=${WEBHOOK_PROXY_DOMAIN:-}
# 私有仓库 release 下载（可选）
# WEBHOOK_GITHUB_TOKEN=
# WEBHOOK_GITEE_TOKEN=
EOF
  chmod 600 "$WEBHOOK_LISTENER_ENV"
}

_webhook_public_callback_url() {
  _webhook_load_listener_env
  local path="${WEBHOOK_PATH:-/hooks}"
  case "${WEBHOOK_PUBLIC_MODE:-local}" in
    nginx)
      [[ -n "${WEBHOOK_PROXY_DOMAIN:-}" ]] && printf 'https://%s%s' "${WEBHOOK_PROXY_DOMAIN}" "$path"
      ;;
    bind)
      if [[ "${WEBHOOK_BIND:-127.0.0.1}" = "0.0.0.0" || "${WEBHOOK_BIND}" = "::" ]]; then
        printf 'http://<服务器公网IP>:%s%s' "${WEBHOOK_PORT:-9080}" "$path"
      else
        printf 'http://%s:%s%s' "${WEBHOOK_BIND}" "${WEBHOOK_PORT:-9080}" "$path"
      fi
      ;;
    *)
      printf 'http://127.0.0.1:%s%s（仅本机）' "${WEBHOOK_PORT:-9080}" "$path"
      ;;
  esac
}

_nginx_strip_webhook_proxy() {
  local conf="$1"
  [[ -f "$conf" ]] || return 0
  sed -i '/# deploy-site webhook-proxy BEGIN/,/# deploy-site webhook-proxy END/d' "$conf"
}

_nginx_webhook_proxy_block() {
  local hook_path="$1" port="$2"
  cat <<NGX
    # deploy-site webhook-proxy BEGIN
    location ^~ ${hook_path} {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 5m;
    }
    # deploy-site webhook-proxy END
NGX
}

_nginx_merge_webhook_proxy() {
  local conf="$1" hook_path="$2" port="$3"
  local block_file tmp line inserted=0
  _nginx_strip_webhook_proxy "$conf"
  block_file="$(mktemp)"
  tmp="$(mktemp)"
  _nginx_webhook_proxy_block "$hook_path" "$port" > "$block_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$inserted" -eq 0 && "$line" =~ location\ ~\ /\. ]]; then
      cat "$block_file"
      inserted=1
    fi
    printf '%s\n' "$line"
  done < "$conf" > "$tmp"
  [[ "$inserted" -eq 1 ]] || cat "$block_file" >> "$tmp"
  mv "$tmp" "$conf"
  rm -f "$block_file"
  fix_nginx_conf_d_file "$conf"
}

_webhook_gen_standalone_nginx() {
  local domain="$1" hook_path="$2" port="$3"
  local conf="${NGINX_CONF}/${domain}.conf"
  local block
  block="$(_nginx_webhook_proxy_block "$hook_path" "$port")"
  ensure_placeholder_cert "$domain"
  cat > "$conf" <<NGINX
server {
    listen 80;
    server_name ${domain};
    if (\$host != "${domain}") { return 444; }

    location ^~ /.well-known/acme-challenge/ {
        root ${CONTAINER_WWW}/${domain};
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }

${block}

    location / { return 404; }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${domain};
    if (\$host != "${domain}") { return 444; }

    ssl_certificate     /etc/nginx/ssl/${domain}/fullchain.cer;
    ssl_certificate_key /etc/nginx/ssl/${domain}/${domain}.key;

    location ^~ /.well-known/acme-challenge/ {
        root ${CONTAINER_WWW}/${domain};
        allow all;
        default_type "text/plain";
        try_files \$uri =404;
    }

${block}

    location / { return 404; }
}
NGINX
  fix_nginx_conf_d_file "$conf"
}

_webhook_apply_nginx_proxy() {
  local domain="$1"
  local hook_path="${WEBHOOK_PATH:-/hooks}"
  local port="${WEBHOOK_PORT:-9080}"
  local conf="${NGINX_CONF}/${domain}.conf"
  mkdir -p "${WWW_ROOT}/${domain}/.well-known/acme-challenge"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${domain}" 2>/dev/null || true
  if [[ -f "$conf" ]]; then
    info "在已有 Nginx 配置 ${conf} 中注入 Webhook 反代"
    _nginx_merge_webhook_proxy "$conf" "$hook_path" "$port"
  else
    info "生成 Webhook 专用 Nginx 配置 ${conf}"
    _webhook_gen_standalone_nginx "$domain" "$hook_path" "$port"
    warn "新域名请执行: $0 ssl --domain=${domain} 签发证书"
  fi
  normalize_nginx_conf_d
  if container_ok "lnmp-nginx"; then
    docker exec lnmp-nginx nginx -t 2>&1 || die "Nginx 配置校验失败"
    docker exec lnmp-nginx nginx -s reload 2>/dev/null && ok "Nginx 已 reload"
  fi
}

_webhook_remove_nginx_proxy() {
  local domain="${WEBHOOK_PROXY_DOMAIN:-}"
  [[ -n "$domain" ]] || return 0
  local conf="${NGINX_CONF}/${domain}.conf"
  [[ -f "$conf" ]] || return 0
  _nginx_strip_webhook_proxy "$conf"
  fix_nginx_conf_d_file "$conf"
  normalize_nginx_conf_d
  container_ok "lnmp-nginx" && docker exec lnmp-nginx nginx -s reload 2>/dev/null || true
}

_webhook_write_systemd_unit() {
  local script_path="$1"
  cat > "$WEBHOOK_SYSTEMD_UNIT" <<EOF
[Unit]
Description=LNMP deploy-site webhook listener
After=network.target docker.service

[Service]
Type=simple
ExecStart=${script_path} webhook serve
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

_webhook_run_python_server() {
  local script_path="$1"
  _webhook_load_listener_env
  command -v python3 &>/dev/null || die "需要 python3 运行 webhook 监听"
  WEBHOOK_SCRIPT="$script_path" WEBHOOK_PORT="$WEBHOOK_PORT" WEBHOOK_BIND="$WEBHOOK_BIND" WEBHOOK_PATH="$WEBHOOK_PATH" \
    python3 - <<'PY'
import os, subprocess, tempfile, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPT = os.environ["WEBHOOK_SCRIPT"]
PORT = int(os.environ.get("WEBHOOK_PORT", "9080"))
BIND = os.environ.get("WEBHOOK_BIND", "127.0.0.1")
PATH = os.environ.get("WEBHOOK_PATH", "/hooks")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_POST(self):
        if self.path.split("?", 1)[0] != PATH:
            self.send_response(404); self.end_headers(); return
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        hdr_path = body_path = None
        try:
            tf = tempfile.NamedTemporaryFile(delete=False, mode="wb")
            tf.write(body); tf.close(); body_path = tf.name
            hf = tempfile.NamedTemporaryFile(delete=False, mode="w", encoding="utf-8")
            for k, v in self.headers.items():
                hf.write(f"{k}: {v}\n")
            hf.close(); hdr_path = hf.name
            event = self.headers.get("X-GitHub-Event") or self.headers.get("X-Gitee-Event") or ""
            gh_sig = self.headers.get("X-Hub-Signature-256") or self.headers.get("X-Hub-Signature") or ""
            gitee_token = self.headers.get("X-Gitee-Token") or ""
            proc = subprocess.run(
                [SCRIPT, "webhook", "handle",
                 "--body-file", body_path,
                 "--headers-file", hdr_path,
                 "--event", event,
                 "--github-signature", gh_sig,
                 "--gitee-token", gitee_token],
                capture_output=True, text=True
            )
            out = (proc.stdout or "") + (proc.stderr or "")
            code = 200 if proc.returncode == 0 else 500
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(out.encode("utf-8", errors="replace") or b"ok")
        finally:
            for p in (body_path, hdr_path):
                if p:
                    try: os.unlink(p)
                    except OSError: pass

    def do_GET(self):
        if self.path.split("?", 1)[0] in (PATH, PATH + "/"):
            self.send_response(200); self.end_headers()
            self.wfile.write(b"lnmp deploy webhook ok\n")
        else:
            self.send_response(404); self.end_headers()

HTTPServer((BIND, PORT), Handler).serve_forever()
PY
}
