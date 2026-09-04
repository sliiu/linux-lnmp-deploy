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

_adding_pm2_release_webhook() {
  [[ "${SITE_TYPE:-}" = "pm2" && "${WEBHOOK_MODE:-}" = "release" && "${WEBHOOK_ENABLE:-0}" -eq 1 ]]
}

_adding_webhook_release_site() {
  _adding_frontend_release_webhook || _adding_pm2_release_webhook
}

_webhook_history_file() { printf '%s/%s/history.tsv' "$WEBHOOK_HISTORY_DIR" "$1"; }
_webhook_lock_file()    { printf '%s/%s/.deploy.lock' "$WEBHOOK_HISTORY_DIR" "$1"; }

# 收集站点 webhook secret：CLI --webhook-secret 优先；更新时保留原值；否则交互输入（必填）
_webhook_collect_secret() {
  local old_secret="${1:-}"
  [[ -n "${WEBHOOK_SECRET:-}" ]] && return 0
  if [[ -n "$old_secret" ]]; then
    WEBHOOK_SECRET="$old_secret"
    return 0
  fi
  while [[ -z "${WEBHOOK_SECRET:-}" ]]; do
    prompt_secret "Webhook Secret（GitHub/Gitee 回调校验，必填）"
    WEBHOOK_SECRET="$PROMPT_RESULT"
    if [[ -z "$WEBHOOK_SECRET" ]]; then
      interactive_tty_ok || die "Webhook Secret 不能为空（请指定 --webhook-secret 或在本机终端交互运行）"
      warn "Webhook Secret 不能为空"
    fi
  done
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
  elif [[ "$raw" != *:* && "$raw" =~ ^([^/]+)/([^/]+)$ ]]; then
    host="github.com"
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

# 可比对的 owner/repo（忽略 provider 前缀）
_webhook_repo_slug() {
  local norm="$(_webhook_normalize_repo "$1")"
  [[ "$norm" =~ ^[^:]+:(.+)$ ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
  printf '%s' "$norm"
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

# 1=增量覆盖；0=全量（下载完成后清空站点再写入）
_webhook_normalize_incremental() {
  case "${1,,}" in
    1|y|yes|true|on) printf '1' ;;
    *) printf '0' ;;
  esac
}

_webhook_site_incremental() {
  local wf="$1" v=""
  [[ -n "$wf" && -f "$wf" ]] && v="$(_webhook_read_kv "$wf" incremental)" || true
  _webhook_normalize_incremental "${v:-0}"
}

# 全量部署前清空站点（保留 .well-known 供 ACME）
_webhook_clear_site_dir() {
  local site_dir="$1" name base
  [[ -d "$site_dir" ]] || return 0
  shopt -s dotglob nullglob
  for name in "$site_dir"/*; do
    [[ -e "$name" ]] || continue
    base="$(basename "$name")"
    [[ "$base" = ".well-known" ]] && continue
    rm -rf "$name"
  done
  shopt -u dotglob nullglob
}

# Gateway PM2 部署：保留 env、日志与持久化数据目录
_webhook_clear_gateway_site_dir() {
  local site_dir="$1" name base
  [[ -d "$site_dir" ]] || return 0
  shopt -s dotglob nullglob
  for name in "$site_dir"/*; do
    [[ -e "$name" ]] || continue
    base="$(basename "$name")"
    case "$base" in
      .well-known|.env|.env.production|.env.production.local|logs|data) continue ;;
    esac
    rm -rf "$name"
  done
  shopt -u dotglob nullglob
}

# .env.production + .env.production.local → .env（PM2 env_file / node --env-file 读取）
_webhook_merge_gateway_env() {
  local site_dir="$1" tmp f
  tmp="${site_dir}/.env.merged.$$"
  : > "$tmp"
  for f in .env.production .env.production.local; do
    [[ -f "${site_dir}/${f}" ]] || continue
    cat "${site_dir}/${f}" >> "$tmp"
    printf '\n' >> "$tmp"
  done
  if [[ -s "$tmp" ]]; then
    mv "$tmp" "${site_dir}/.env"
    chown "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}/.env" 2>/dev/null || true
    chmod 640 "${site_dir}/.env" 2>/dev/null || true
    info "已合并 .env.production → .env"
  else
    rm -f "$tmp"
    [[ -f "${site_dir}/.env" ]] || warn "未找到 .env / .env.production，请先在站点目录配置环境变量"
  fi
}

_webhook_write_site_config() {
  local domain="$1" mode="$2" git_repo="$3" release_name="${4:-}" secret="${5:-}"
  local f inc; f="$(site_webhook_file "$domain")"
  mkdir -p "$NGINX_CONF"
  [[ -n "$secret" ]] || die "Webhook Secret 不能为空"
  if [[ "$mode" = "release" ]]; then
    inc="${WEBHOOK_INCREMENTAL:-}"
    if [[ -z "$inc" && -f "$f" ]]; then
      inc="$(_webhook_read_kv "$f" incremental)" || true
    fi
    inc="$(_webhook_normalize_incremental "${inc:-0}")"
    cat > "$f" <<EOF
enabled=1
mode=release
git_repo=${git_repo}
release_name=${release_name}
secret=${secret}
incremental=${inc}
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
  [[ -n "${WEBHOOK_SITE_GITHUB_TOKEN:-}" ]] && printf 'github_token=%s\n' "$WEBHOOK_SITE_GITHUB_TOKEN" >> "$f"
  [[ -n "${WEBHOOK_SITE_GITEE_TOKEN:-}" ]] && printf 'gitee_token=%s\n' "$WEBHOOK_SITE_GITEE_TOKEN" >> "$f"
  [[ -n "${WEBHOOK_ASSET_NAME:-}" ]] && printf 'asset_name=%s\n' "$WEBHOOK_ASSET_NAME" >> "$f"
  [[ -n "${WEBHOOK_ASSET_MIRROR_URL:-}" ]] && printf 'asset_mirror_url=%s\n' "$WEBHOOK_ASSET_MIRROR_URL" >> "$f"
  chmod 600 "$f"
  printf '%s' "$secret"
}

# 站点级 token 优先，其次 listener.env 全局 token
_webhook_trim_token() {
  local t="${1:-}"
  t="${t//$'\r'/}"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}

_webhook_site_download_token() {
  local domain="$1" wf token=""
  wf="$(site_webhook_file "$domain")"
  token="$(_webhook_read_kv "$wf" github_token)" || true
  token="$(_webhook_trim_token "$token")"
  [[ -n "$token" ]] && { printf '%s' "$token"; return 0; }
  token="$(_webhook_read_kv "$wf" gitee_token)" || true
  token="$(_webhook_trim_token "$token")"
  [[ -n "$token" ]] && { printf '%s' "$token"; return 0; }
  _webhook_load_listener_env
  printf '%s' "$(_webhook_trim_token "${WEBHOOK_GITHUB_TOKEN:-${WEBHOOK_GITEE_TOKEN:-}}")"
}

_webhook_load_listener_env() {
  local _pm="${WEBHOOK_PUBLIC_MODE:-}" _bind="${WEBHOOK_BIND:-}" _port="${WEBHOOK_PORT:-}" \
        _path="${WEBHOOK_PATH:-}" _proxy="${WEBHOOK_PROXY_DOMAIN:-}" _notify="${WEBHOOK_NOTIFY_URL:-}"
  WEBHOOK_PORT="${WEBHOOK_PORT:-9080}"
  WEBHOOK_BIND="${WEBHOOK_BIND:-127.0.0.1}"
  WEBHOOK_PATH="${WEBHOOK_PATH:-/hooks}"
  WEBHOOK_PUBLIC_MODE="${WEBHOOK_PUBLIC_MODE:-local}"
  WEBHOOK_PROXY_DOMAIN="${WEBHOOK_PROXY_DOMAIN:-}"
  if [[ -f "${CONF_FILE:-/etc/lnmp-env.conf}" ]]; then
    # shellcheck disable=SC1090
    source "${CONF_FILE:-/etc/lnmp-env.conf}" 2>/dev/null || true
  fi
  if [[ -f "$WEBHOOK_LISTENER_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$WEBHOOK_LISTENER_ENV"
  fi
  [[ -n "$_pm" ]]    && WEBHOOK_PUBLIC_MODE="$_pm"
  [[ -n "$_bind" ]]  && WEBHOOK_BIND="$_bind"
  [[ -n "$_port" ]]  && WEBHOOK_PORT="$_port"
  [[ -n "$_path" ]]  && WEBHOOK_PATH="$_path"
  if [[ -n "$_proxy" ]]; then WEBHOOK_PROXY_DOMAIN="$_proxy"; fi
  if [[ "${WEBHOOK_NOTIFY_URL_SET:-0}" = 1 ]]; then
    WEBHOOK_NOTIFY_URL="$_notify"
    [[ "$WEBHOOK_NOTIFY_URL" = "-" ]] && WEBHOOK_NOTIFY_URL=""
  fi
}

_webhook_acquire_lock() {
  local domain="$1"
  local lf holder
  lf="$(_webhook_lock_file "$domain")"
  mkdir -p "$(dirname "$lf")"
  if ( set -o noclobber; echo "$$" > "$lf" ) 2>/dev/null; then
    return 0
  fi
  holder="$(tr -d '[:space:]' < "$lf" 2>/dev/null || true)"
  if [[ -n "$holder" && "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; then
    warn "站点 ${domain} 陈旧部署锁（pid ${holder} 已退出），已清除并重试"
    rm -f "$lf"
    if ( set -o noclobber; echo "$$" > "$lf" ) 2>/dev/null; then
      return 0
    fi
    holder="$(tr -d '[:space:]' < "$lf" 2>/dev/null || true)"
  fi
  warn "站点 ${domain} 正在部署中（锁 pid=${holder:-?}），跳过"
  return 1
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
    deploy_log_bind_domain "$domain"
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
    _caddy_reload_soft "Caddy 已 reload"
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
  local norm="$1" conf name mode repo want slug
  want="$(_webhook_repo_slug "$norm")"
  for conf in "${NGINX_CONF}"/*.webhook; do
    [[ -f "$conf" ]] || continue
    [[ "$(_webhook_read_kv "$conf" enabled)" = "1" ]] || continue
    repo="$(_webhook_read_kv "$conf" git_repo)"
    [[ -n "$repo" ]] || continue
    slug="$(_webhook_repo_slug "$repo")"
    [[ "$slug" = "$want" ]] || continue
    name=$(basename "$conf" .webhook)
    mode="$(_webhook_read_kv "$conf" mode)"
    printf '%s|%s\n' "$name" "$mode"
  done
}

_webhook_release_name_match() {
  local expected="${1:-}" actual_name="${2:-}" actual_tag="${3:-}" candidate suffix ver_suffix=""
  [[ -n "$expected" ]] || return 0
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  actual_name="$(printf '%s' "$actual_name" | tr '[:upper:]' '[:lower:]')"
  actual_tag="$(printf '%s' "$actual_tag" | tr '[:upper:]' '[:lower:]')"
  [[ "$expected" = "$actual_name" || "$expected" = "$actual_tag" ]] && return 0
  [[ "$actual_name" == "$expected "* || "$actual_name" == "$expected-"* ]] && return 0
  # 前缀匹配：slimppt → slimppt-v1.0.2；slimppt- → slimppt-v1.0.2；official-v → official-v1.0.0
  for candidate in "$actual_tag" "$actual_name"; do
    [[ -z "$candidate" ]] && continue
    [[ "$candidate" = "$expected" || "$candidate" == "$expected-"* ]] && return 0
    if [[ "$candidate" == "$expected"* ]]; then
      suffix="${candidate#"$expected"}"
      ver_suffix="$suffix"
      [[ "$ver_suffix" == v* ]] && ver_suffix="${ver_suffix#v}"
      [[ -z "$suffix" || "$suffix" == -* || "$ver_suffix" == [0-9.]* ]] && return 0
    fi
  done
  return 1
}

_webhook_release_action_ok() {
  local action="${1:-}" event="${2:-}"
  [[ "$event" = "Release Hook" ]] && return 0
  case "$action" in
    published|publish|released|prereleased|"") return 0 ;;
    *) return 1 ;;
  esac
}

# GitHub/Gitee release payload 含嵌套 JSON，grep 不可靠
_webhook_parse_release_payload() {
  local body_file="$1"
  command -v python3 &>/dev/null || return 1
  python3 - "$body_file" <<'PY' 2>/dev/null || return 1
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
rel = d.get("release") or {}
repo = d.get("repository") or {}
assets = rel.get("assets") or []
asset_url = ""
if assets:
    a0 = assets[0]
    # 私有仓须用 API url + token；browser_download_url 对 CLI 常 404
    asset_url = a0.get("url") or a0.get("browser_download_url") or ""
out = {
    "action": d.get("action") or "",
    "rel_tag": rel.get("tag_name") or "",
    "rel_name": rel.get("name") or "",
    "repo_full": repo.get("full_name") or d.get("path_with_namespace") or "",
    "clone_url": repo.get("clone_url") or d.get("git_ssh_url") or "",
    "html_url": repo.get("html_url") or "",
    "asset_url": asset_url,
    "zipball_url": rel.get("zipball_url") or "",
    "tarball_url": rel.get("tarball_url") or "",
}
for k, v in out.items():
    if v:
        print(f"{k}={v}")
PY
}

_webhook_file_size() {
  local f="$1" n=0
  [[ -f "$f" ]] || { printf '0'; return 0; }
  n="$(wc -c <"$f" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$n" && "$n" =~ ^[0-9]+$ ]] || n="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)"
  printf '%s' "${n:-0}"
}

_webhook_download_progress_monitor() {
  local dest="$1" stop_file="$2"
  # stop_file 须为尚不存在的路径（勿用 mktemp 直接创建的文件）
  while [[ ! -f "$stop_file" ]]; do
    info "已下载 $(_webhook_file_size "$dest") 字节"
    sleep 10
    [[ -f "$stop_file" ]] && break
  done
}

_webhook_download_progress_stop() {
  local monitor_pid="$1" stop_file="$2"
  touch "$stop_file" 2>/dev/null || true
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  rm -f "$stop_file"
}

_webhook_expand_mirror_url() {
  local u="$1" tag="${2:-}" asset="${3:-}"
  u="${u//\{tag\}/$tag}"
  u="${u//\{asset\}/$asset}"
  printf '%s' "$u"
}

_webhook_pick_release_asset_name() {
  local body_file="$1" asset_hint="${2:-}"
  command -v python3 &>/dev/null || return 1
  python3 - "$body_file" "$asset_hint" <<'PY' 2>/dev/null || return 1
import json, sys
rel = json.load(open(sys.argv[1], encoding="utf-8")).get("release") or {}
hint = (sys.argv[2] or "").lower()
assets = rel.get("assets") or []
if not assets:
    raise SystemExit(1)
if hint:
    for a in assets:
        if hint in (a.get("name") or "").lower():
            print(a.get("name") or "", end="")
            break
    else:
        raise SystemExit(1)
else:
    print(assets[0].get("name") or "", end="")
PY
}

# 与 init.sh GH_PROXY 相同：https://ghfast.top + / + https://github.com/...
_webhook_gh_proxy_prefix() {
  _webhook_load_listener_env
  local p="${WEBHOOK_GH_PROXY:-${GH_PROXY:-}}"
  p="${p%/}"
  printf '%s' "$p"
}

_webhook_url_is_gh_proxied() {
  local url="$1" prefix
  prefix="$(_webhook_gh_proxy_prefix)"
  [[ -n "$prefix" && "$url" == "$prefix/"* ]]
}

_webhook_with_gh_proxy() {
  local url="$1" prefix
  prefix="$(_webhook_gh_proxy_prefix)"
  [[ -n "$prefix" && -n "$url" ]] || { printf '%s' "$url"; return 0; }
  [[ "$url" == "$prefix/"* ]] && { printf '%s' "$url"; return 0; }
  [[ -n "${WEBHOOK_HTTP_PROXY:-}" ]] && { printf '%s' "$url"; return 0; }
  case "$url" in
    https://github.com/*|http://github.com/*|https://objects.githubusercontent.com/*|https://release-assets.githubusercontent.com/*)
      printf '%s/%s' "$prefix" "$url"
      ;;
    *)
      printf '%s' "$url"
      ;;
  esac
}

_webhook_gh_proxy_release_url() {
  local repo="$1" tag="$2" asset="$3" gh_dl proxied
  [[ -n "$repo" && -n "$tag" && -n "$asset" ]] || return 1
  [[ -n "$(_webhook_gh_proxy_prefix)" ]] || return 1
  [[ -z "${WEBHOOK_HTTP_PROXY:-}" ]] || return 1
  gh_dl="$(_webhook_github_release_asset_download_url "$repo" "$tag" "$asset")" || return 1
  [[ -n "$gh_dl" ]] || return 1
  proxied="$(_webhook_with_gh_proxy "$gh_dl")"
  [[ "$proxied" != "$gh_dl" ]] || return 1
  printf '%s' "$proxied"
}

# GitHub API 302 到 release-assets；国内 ECS 常在 200 后正文卡住
_webhook_curl_proxy_args() {
  _webhook_load_listener_env
  [[ -n "${WEBHOOK_HTTP_PROXY:-}" ]] && printf '%s' "--proxy" "${WEBHOOK_HTTP_PROXY}"
}

_webhook_github_api_curl() {
  local url="$1" token="$2"
  local err_file proxy=() rc=0 out=""
  err_file="$(mktemp "${TMPDIR:-/tmp}/webhook-gh-api.XXXXXX")"
  read -r -a proxy <<< "$(_webhook_curl_proxy_args)"
  out="$(curl -sS --connect-timeout 30 --max-time 60 \
    "${proxy[@]}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: lnmp-deploy-webhook" \
    -w $'\nHTTP_CODE:%{http_code}' \
    "$url" 2>"$err_file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    warn "GitHub API 请求失败: ${url%%\?*}（$(tr '\n' ' ' <"$err_file" | sed 's/  */ /g' | head -c 200)）"
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  printf '%s' "$out"
}

_webhook_resolve_github_release_cdn() {
  local api_url="$1" token="$2" proxy=() out=""
  [[ -n "$token" ]] || return 1
  read -r -a proxy <<< "$(_webhook_curl_proxy_args)"
  out="$(curl -fsS --connect-timeout 30 --max-time 60 \
    "${proxy[@]}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/octet-stream" \
    -o /dev/null -w '%{redirect_url}' "$api_url" 2>/dev/null)" || return 1
  printf '%s' "$out"
}

_webhook_curl_common_opts() {
  local speed_time="${1:-60}" extra=""
  curl --help 2>/dev/null | grep -q -- '--retry-all-errors' && extra="--retry-all-errors"
  printf '%s' "--http1.1 --connect-timeout 30 --max-time 1800 --retry 5 --retry-delay 5 ${extra} --speed-time ${speed_time} --speed-limit 1024 -C -"
}

_webhook_download_url_one() {
  local url="$1" dest="$2" token="${3:-}" speed_time="${4:-60}"
  local hdr=() err rc=0 t0 t1 nbytes monitor_pid=0 stop_file fetch_url cdn_url curl_opts
  _webhook_load_listener_env
  fetch_url="$url"
  if _webhook_url_is_gh_proxied "$url"; then
    hdr=()
    info "GitHub 代理: ${fetch_url%%\?*}"
  elif [[ "$url" == *"api.github.com/"*"/releases/assets/"* ]]; then
    hdr=(-H "Accept: application/octet-stream")
    [[ -n "$token" ]] && hdr+=(-H "Authorization: Bearer ${token}")
    cdn_url="$(_webhook_resolve_github_release_cdn "$url" "$token")" || true
    if [[ -n "$cdn_url" ]]; then
      fetch_url="$cdn_url"
      hdr=()
      info "GitHub API → CDN（HTTP/1.1）"
    fi
  elif [[ -n "$token" && "$url" == *"github.com/"*"/releases/download/"* ]]; then
    hdr=(-H "Authorization: Bearer ${token}")
  fi
  read -r -a curl_opts <<< "$(_webhook_curl_common_opts "$speed_time")"
  stop_file="$(mktemp -u "${TMPDIR:-/tmp}/webhook-dl-stop.XXXXXX")"
  t0=$(date +%s)
  _webhook_download_progress_monitor "$dest" "$stop_file" &
  monitor_pid=$!
  if command -v curl &>/dev/null; then
    if [[ -n "${WEBHOOK_HTTP_PROXY:-}" ]]; then
      err="$(curl -fsSL "${curl_opts[@]}" --proxy "${WEBHOOK_HTTP_PROXY}" "${hdr[@]}" -o "$dest" "$fetch_url" 2>&1)" || rc=$?
    else
      err="$(curl -fsSL "${curl_opts[@]}" "${hdr[@]}" -o "$dest" "$fetch_url" 2>&1)" || rc=$?
    fi
    _webhook_download_progress_stop "$monitor_pid" "$stop_file"
    t1=$(date +%s)
    if [[ "$rc" -ne 0 ]]; then
      warn "${err:-curl 下载失败}"
      return 1
    fi
    nbytes="$(_webhook_file_size "$dest")"
    info "下载完成: ${nbytes} 字节, 耗时 $((t1 - t0)) 秒"
    return 0
  elif command -v wget &>/dev/null; then
    local wget_hdr=()
    [[ -n "$token" && "$url" == *"api.github.com/"* ]] && wget_hdr+=(--header="Authorization: Bearer ${token}")
    [[ "$fetch_url" == *"api.github.com/"*"/releases/assets/"* ]] \
      && wget_hdr+=(--header="Accept: application/octet-stream")
    [[ -n "${WEBHOOK_HTTP_PROXY:-}" ]] && wget_hdr+=(--execute="use_proxy=yes" --execute="https_proxy=${WEBHOOK_HTTP_PROXY}")
    wget -q --timeout=30 --tries=5 --waitretry=5 -c "${wget_hdr[@]}" -O "$dest" "$fetch_url" || rc=$?
    _webhook_download_progress_stop "$monitor_pid" "$stop_file"
    [[ "$rc" -eq 0 ]] || return 1
    t1=$(date +%s)
    nbytes="$(_webhook_file_size "$dest")"
    info "下载完成: ${nbytes} 字节, 耗时 $((t1 - t0)) 秒"
    return 0
  else
    _webhook_download_progress_stop "$monitor_pid" "$stop_file"
    die "缺少 curl/wget"
  fi
}

_webhook_notify() { ops_notify "$1"; }

_webhook_download_try_urls() {
  local dest="$1" token="$2" speed_time="${3:-60}"
  shift 3
  local u n="$#" i=0
  [[ "$n" -gt 0 ]] || return 1
  for u in "$@"; do
    [[ -z "$u" ]] && continue
    i=$((i + 1))
    [[ "$i" -gt 1 ]] && rm -f "$dest"
    info "下载 (${i}/${n}): ${u%%\?*}"
    if _webhook_download_url_one "$u" "$dest" "$token" "$speed_time"; then
      return 0
    fi
    [[ "$i" -lt "$n" ]] && warn "当前地址失败，尝试下一地址"
  done
  warn "全部下载地址均失败；可在 ${NGINX_CONF}/<域名>.webhook 设置 asset_mirror_url（OSS），或 init.sh 配置 GH_PROXY / listener.env 的 WEBHOOK_HTTP_PROXY"
  return 1
}

_webhook_download_url() {
  local url="$1" dest="$2" token="${3:-}"
  _webhook_download_try_urls "$dest" "$token" 60 "$url"
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
  top="$(find "$dest" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1 || true)"
  if [[ -n "$top" && "$(find "$dest" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]]; then
    shopt -s dotglob
    mv "$top"/* "$dest/" 2>/dev/null || true
    rmdir "$top" 2>/dev/null || true
    shopt -u dotglob
  fi
}

_webhook_pick_release_asset_url() {
  local body_file="$1" asset_hint="${2:-}"
  local url name parsed line k v
  parsed="$(_webhook_parse_release_payload "$body_file" 2>/dev/null || true)"
  if [[ -n "$parsed" && -n "$asset_hint" ]]; then
    url="$(python3 - "$body_file" "$asset_hint" <<'PY' 2>/dev/null || true
import json, sys
rel = json.load(open(sys.argv[1], encoding="utf-8")).get("release") or {}
hint = sys.argv[2].lower()
for a in rel.get("assets") or []:
    name = (a.get("name") or "").lower()
    url = a.get("url") or a.get("browser_download_url") or ""
    if url and hint in name:
        print(url, end="")
        break
PY
)"
    [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  fi
  if [[ -n "$parsed" ]]; then
    while IFS= read -r line; do
      [[ "$line" != *=* ]] && continue
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        asset_url) [[ -n "$v" ]] && url="$v" ;;
      esac
    done <<< "$parsed"
    [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  fi
  if [[ -n "$asset_hint" ]]; then
    while IFS= read -r line; do
      name="$(printf '%s' "$line" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
      url="$(printf '%s' "$line" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
      [[ -n "$url" && "$name" = *"$asset_hint"* ]] && { printf '%s' "$url"; return 0; }
    done < <(grep -oE '\{[^{}]*"browser_download_url"[^{}]*\}' "$body_file" 2>/dev/null || true)
  fi
  url="$(_webhook_json_field "$body_file" '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  if [[ -n "$parsed" ]]; then
    while IFS= read -r line; do
      [[ "$line" != *=* ]] && continue
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        zipball_url|tarball_url) [[ -z "$url" && -n "$v" ]] && url="$v" ;;
      esac
    done <<< "$parsed"
    [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  fi
  url="$(_webhook_json_field "$body_file" '"zipball_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -n "$url" ]] && { printf '%s' "$url"; return 0; }
  url="$(_webhook_json_field "$body_file" '"tarball_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  printf '%s' "$url"
}

_webhook_deploy_release() {
  local domain="$1" body_file="$2" release_name="${3:-}" release_tag="${4:-}" download_url="${5:-}"
  local site_dir="${WWW_ROOT}/${domain}" wf asset_hint token tmp arch ver
  local mirror asset_file dl_urls=() proxied
  wf="$(site_webhook_file "$domain")"
  asset_hint="$(_webhook_read_kv "$wf" asset_name)"
  token="$(_webhook_site_download_token "$domain")"
  ver="${release_tag:-$release_name}"
  [[ -n "$ver" ]] || ver="release"

  _webhook_acquire_lock "$domain" || return 1
  trap '_webhook_release_lock "'"$domain"'"' RETURN

  _webhook_backup_site "$domain" "$ver" "release" >/dev/null

  [[ -n "$download_url" ]] || download_url="$(_webhook_pick_release_asset_url "$body_file" "$asset_hint")"
  [[ -n "$download_url" ]] || die "未找到 release 下载地址"

  if [[ -z "$token" && "$download_url" == *"github.com/"*"/releases/download/"* ]]; then
    warn "未配置 github_token，私有仓库 release 附件将 404"
  elif [[ -n "$token" && "$download_url" == *"github.com/"*"/releases/download/"* ]]; then
    info "github_token: ${token:0:8}...（用于拉取 release 附件）"
  fi
  _webhook_resolve_github_download_url download_url "$download_url" "$token"

  mirror="$(_webhook_read_kv "$wf" asset_mirror_url)" || true
  asset_file="$(_webhook_pick_release_asset_name "$body_file" "$asset_hint")" || true
  _webhook_load_listener_env
  if [[ -n "$mirror" ]]; then
    dl_urls+=("$(_webhook_expand_mirror_url "$mirror" "$ver" "$asset_file")")
  fi
  proxied="$(_webhook_gh_proxy_release_url "$(_webhook_read_kv "$wf" git_repo)" "$ver" "$asset_file")" || true
  [[ -z "$token" && -n "$proxied" ]] && dl_urls+=("$proxied")
  dl_urls+=("$download_url")

  tmp="$(mktemp -d)"
  arch="${tmp}/pkg"
  case "$download_url" in
    *.zip|*zipball*) arch="${arch}.zip" ;;
    *) arch="${arch}.tar.gz" ;;
  esac
  _webhook_download_try_urls "$arch" "$token" 60 "${dl_urls[@]}" || die "下载失败"

  local incremental
  incremental="$(_webhook_site_incremental "$wf")"
  _webhook_extract_archive "$arch" "${tmp}/extract"
  mkdir -p "$site_dir"
  if [[ "$incremental" = "1" ]]; then
    info "增量部署：覆盖同名文件，保留站点内其余文件"
    rsync -a "${tmp}/extract/" "$site_dir/" 2>/dev/null \
      || cp -a "${tmp}/extract/." "$site_dir/"
  else
    info "全量部署：下载完成，清空站点目录后替换"
    _webhook_clear_site_dir "$site_dir"
    rsync -a "${tmp}/extract/" "$site_dir/" 2>/dev/null \
      || cp -a "${tmp}/extract/." "$site_dir/"
  fi
  rm -rf "$tmp"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "$site_dir" 2>/dev/null || true

  gen_nginx_frontend "$domain" ""
  fix_site_readable_for_nginx "$domain" "frontend" ""
  _caddy_reload_soft "Caddy 已 reload"
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
  deploy_log_bind_domain "$domain"
  YES=1
  RUN_MIGRATE="${WEBHOOK_RUN_MIGRATE:-y}"
  GIT_REF=""
  SKIP_GIT=1
  cmd_update
  SKIP_GIT=0
  ok "站点 ${domain} 已更新到 tag ${tag}"
}

_webhook_json_release_name() {
  local body_file="$1" name
  name="$(_webhook_parse_release_payload "$body_file" 2>/dev/null | awk -F= '$1=="rel_name"{print substr($0,index($0,"=")+1); exit}')"
  [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
  _webhook_json_field "$body_file" '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"'
}

# GitHub Actions scripts/ci/trigger-deploy-webhook.mjs → event=static-release + Bearer token
_webhook_parse_ci_static_release() {
  local body_file="$1"
  command -v python3 &>/dev/null || return 1
  python3 - "$body_file" <<'PY' 2>/dev/null || return 1
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
if d.get("event") != "static-release":
    raise SystemExit(1)
for k in ("repository", "tag", "release", "artifact", "app", "version"):
    v = d.get(k) or ""
    if v:
        print(f"{k}={v}")
PY
}

_webhook_header_value() {
  local file="$1" want="${2,,}" line k v
  [[ -f "$file" && -n "$want" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" != *:* ]] && continue
    k="${line%%:*}"; v="${line#*:}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    v="${v#"${v%%[![:space:]]*}"}"
    [[ "${k,,}" = "$want" ]] && { printf '%s' "$v"; return 0; }
  done < "$file"
  return 1
}

_webhook_bearer_from_headers() {
  local headers_file="$1" auth=""
  auth="$(_webhook_header_value "$headers_file" "Authorization")" || return 1
  case "$auth" in
    [Bb][Ee][Aa][Rr][Ee][Rr]\ *) auth="${auth#*[Bb][Ee][Aa][Rr][Ee][Rr] }" ;;
  esac
  auth="${auth#"${auth%%[![:space:]]*}"}"
  auth="${auth%"${auth##*[![:space:]]}"}"
  [[ -n "$auth" ]] || return 1
  printf '%s' "$auth"
}

_webhook_verify_bearer_token() {
  local token="${1:-}" secret="${2:-}"
  [[ -n "$token" && -n "$secret" && "$token" = "$secret" ]]
}

_webhook_github_release_asset_download_url() {
  local repo_ref="$1" tag="$2" artifact="$3" slug owner repo
  [[ -n "$repo_ref" && -n "$tag" && -n "$artifact" ]] || return 1
  slug="$(_webhook_repo_slug "$(_webhook_normalize_repo "$repo_ref")")"
  owner="${slug%%/*}"
  repo="${slug#*/}"
  [[ -n "$owner" && -n "$repo" ]] || return 1
  printf 'https://github.com/%s/%s/releases/download/%s/%s' "$owner" "$repo" "$tag" "$artifact"
}

# 私有仓须走 API asset；有 token 时解析为 api.github.com/.../releases/assets/{id}
# 输出变量名作为第 1 参数（勿用 $() 捕获，避免 info/warn 污染 URL）
_webhook_github_api_release_asset_url() {
  local _out="$1" repo_ref="$2" tag="$3" artifact="$4" token="$5"
  local slug owner repo resp http_code json asset_id api_msg avail=""
  printf -v "$_out" '%s' ""
  token="$(_webhook_trim_token "$token")"
  artifact="$(_webhook_trim_token "$artifact")"
  tag="$(_webhook_trim_token "$tag")"
  [[ -n "$repo_ref" && -n "$tag" && -n "$artifact" && -n "$token" ]] || {
    warn "GitHub API 解析附件缺少参数（需 github_token、tag、artifact）"
    return 1
  }
  command -v python3 &>/dev/null || { warn "缺少 python3，无法查询 GitHub Release 附件"; return 1; }
  slug="$(_webhook_repo_slug "$(_webhook_normalize_repo "$repo_ref")")"
  owner="${slug%%/*}"
  repo="${slug#*/}"
  [[ -n "$owner" && -n "$repo" ]] || { warn "无法解析仓库: ${repo_ref}"; return 1; }
  resp="$(_webhook_github_api_curl "https://api.github.com/repos/${owner}/${repo}/releases/tags/${tag}" "$token")" || return 1
  http_code="${resp##*HTTP_CODE:}"
  json="${resp%HTTP_CODE:*}"
  if [[ "$http_code" != "200" ]]; then
    api_msg="$(printf '%s' "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || true)"
    warn "GitHub API HTTP ${http_code}（releases/tags/${tag}）${api_msg:+: ${api_msg}}"
    return 1
  fi
  asset_id="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want = sys.argv[1].strip()
for a in d.get("assets") or []:
    name = (a.get("name") or "").strip()
    if name == want:
        aid = a.get("id")
        if aid is not None:
            print(aid, end="")
        break
' "$artifact" 2>/dev/null)"
  if [[ -z "$asset_id" ]]; then
    avail="$(printf '%s' "$json" | python3 -c "import json,sys; print(', '.join(a.get('name') or '' for a in json.load(sys.stdin).get('assets') or []))" 2>/dev/null || true)"
    warn "GitHub API 未找到附件 ${artifact}（tag=${tag}）${avail:+；可用: ${avail}}"
    return 1
  fi
  printf -v "$_out" '%s' "https://api.github.com/repos/${owner}/${repo}/releases/assets/${asset_id}"
}

_webhook_resolve_github_download_url() {
  local _out="$1" url="$2" token="$3" owner repo tag artifact api_url=""
  [[ -n "$_out" && -n "$url" ]] || return 1
  if [[ "$url" == *"api.github.com/"*"/releases/assets/"* ]]; then
    printf -v "$_out" '%s' "$url"
    return 0
  fi
  if [[ -n "$token" && "$url" == *"github.com/"*"/releases/download/"* ]] \
    && [[ "$url" =~ github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/?]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    tag="${BASH_REMATCH[3]}"
    artifact="${BASH_REMATCH[4]}"
    if _webhook_github_api_release_asset_url api_url "${owner}/${repo}" "$tag" "$artifact" "$token"; then
      info "GitHub API asset: ${artifact}"
      printf -v "$_out" '%s' "$api_url"
      return 0
    fi
    warn "回退 releases/download 直链"
  fi
  printf -v "$_out" '%s' "$url"
}

_webhook_ci_artifact_ok() {
  local artifact="${1:-}" hint="${2:-}"
  [[ -n "$artifact" ]] || return 1
  [[ -z "$hint" ]] && return 0
  [[ "$artifact" == *"$hint"* ]]
}

_webhook_parse_ci_gateway_release() {
  local body_file="$1"
  command -v python3 &>/dev/null || return 1
  python3 - "$body_file" <<'PY' 2>/dev/null || return 1
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
if d.get("event") != "gateway-release":
    raise SystemExit(1)
for k in ("repository", "tag", "release", "artifact", "app", "version", "buildTarget"):
    v = d.get(k) or ""
    if v:
        print(f"{k}={v}")
PY
}

_webhook_deploy_gateway_release() {
  local domain="$1" body_file="$2" release_name="${3:-}" release_tag="${4:-}" download_url="${5:-}"
  local site_dir="${WWW_ROOT}/${domain}" wf asset_hint token tmp arch ver
  local dl_urls=() mirror asset_file proxied
  [[ "$(_site_type_for_domain "$domain")" = "pm2" ]] || die "站点 ${domain} 非 pm2 类型，无法部署 gateway-release"

  wf="$(site_webhook_file "$domain")"
  asset_hint="$(_webhook_read_kv "$wf" asset_name)"
  token="$(_webhook_site_download_token "$domain")"
  ver="${release_tag:-$release_name}"
  [[ -n "$ver" ]] || ver="release"

  _webhook_acquire_lock "$domain" || return 1
  trap '_webhook_release_lock "'"$domain"'"' RETURN

  _webhook_backup_site "$domain" "$ver" "gateway-release" >/dev/null

  [[ -n "$download_url" ]] || download_url="$(_webhook_pick_release_asset_url "$body_file" "$asset_hint")"
  [[ -n "$download_url" ]] || die "未找到 gateway release 下载地址"

  if [[ -z "$token" && "$download_url" == *"github.com/"*"/releases/download/"* ]]; then
    warn "未配置 github_token，私有仓库 release 附件将 404"
  fi
  _webhook_resolve_github_download_url download_url "$download_url" "$token"

  mirror="$(_webhook_read_kv "$wf" asset_mirror_url)" || true
  asset_file="$(_webhook_pick_release_asset_name "$body_file" "$asset_hint")" || true
  _webhook_load_listener_env
  if [[ -n "$mirror" ]]; then
    dl_urls+=("$(_webhook_expand_mirror_url "$mirror" "$ver" "$asset_file")")
  fi
  proxied="$(_webhook_gh_proxy_release_url "$(_webhook_read_kv "$wf" git_repo)" "$ver" "$asset_file")" || true
  [[ -z "$token" && -n "$proxied" ]] && dl_urls+=("$proxied")
  dl_urls+=("$download_url")

  tmp="$(mktemp -d)"
  arch="${tmp}/pkg"
  case "$download_url" in
    *.zip|*zipball*) arch="${arch}.zip" ;;
    *) arch="${arch}.tar.gz" ;;
  esac
  _webhook_download_try_urls "$arch" "$token" 60 "${dl_urls[@]}" || die "下载失败"

  local incremental
  incremental="$(_webhook_site_incremental "$wf")"
  _webhook_extract_archive "$arch" "${tmp}/extract"
  mkdir -p "$site_dir"
  if [[ "$incremental" = "1" ]]; then
    info "增量部署：覆盖同名文件，保留站点内其余文件"
    rsync -a "${tmp}/extract/" "$site_dir/" 2>/dev/null \
      || cp -a "${tmp}/extract/." "$site_dir/"
  else
    info "全量部署：清空站点（保留 .env* / logs / data）后替换"
    _webhook_clear_gateway_site_dir "$site_dir"
    rsync -a "${tmp}/extract/" "$site_dir/" 2>/dev/null \
      || cp -a "${tmp}/extract/." "$site_dir/"
  fi
  rm -rf "$tmp"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "$site_dir" 2>/dev/null || true

  _webhook_merge_gateway_env "$site_dir"

  ensure_pm2_runtime
  apply_site_pm2_port_cli "$domain"
  apply_site_pm2_cmd_cli "$domain"
  local port
  port="$(allocate_pm2_port "$domain" "${SITE_PM2_PORT:-8787}")"
  printf '%s\n' "$port" > "$(site_pm2_port_file "$domain")"
  chmod 644 "$(site_pm2_port_file "$domain")" 2>/dev/null || true

  info "npm install（生产依赖）..."
  _pm2_run_as_devops "$site_dir" "npm ci --omit=dev 2>/dev/null || npm install --omit=dev"
  ok "依赖安装完成"

  PM2_BUILD=n reload_pm2_site "$domain"
  gen_nginx_pm2 "$domain"
  fix_site_readable_for_nginx "$domain" "pm2" ""
  _caddy_reload_soft "Caddy 已 reload"
  ok "站点 ${domain} 已更新到 gateway release ${ver}"
}

_webhook_process_ci_gateway_release() {
  local body_file="$1" headers_file="${2:-}"
  local parsed repository="" tag="" artifact="" app="" release="" build_target="" bearer norm dl_url
  local matched=0 site_count=0 domain mode wf secret expected asset_hint line k v

  parsed="$(_webhook_parse_ci_gateway_release "$body_file")" || { warn "无法解析 CI gateway-release payload"; return 1; }
  while IFS= read -r line; do
    [[ "$line" != *=* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      repository)  repository="$v" ;;
      tag)         tag="$(_webhook_trim_token "$v")" ;;
      release)     release="$(_webhook_trim_token "$v")" ;;
      artifact)    artifact="$(_webhook_trim_token "$v")" ;;
      app)         app="$(_webhook_trim_token "$v")" ;;
      buildTarget) build_target="$(_webhook_trim_token "$v")" ;;
    esac
  done <<< "$parsed"

  bearer="$(_webhook_bearer_from_headers "$headers_file")" || true
  norm="$(_webhook_normalize_repo "$repository")"
  [[ -n "$norm" ]] || { warn "无法解析仓库: ${repository:-}"; return 1; }
  [[ -n "$tag" && -n "$artifact" ]] || { warn "CI payload 缺少 tag 或 artifact"; return 1; }

  info "webhook 解析: event=gateway-release tag=${tag} artifact=${artifact} buildTarget=${build_target:-} repo=${norm}"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    site_count=$((site_count + 1))
    domain="${line%%|*}"
    mode="${line#*|}"
    deploy_log_bind_domain "$domain"
    wf="$(site_webhook_file "$domain")"
    secret="$(_webhook_read_kv "$wf" secret)"
    if ! _webhook_verify_bearer_token "$bearer" "$secret"; then
      warn "站点 ${domain} Bearer token 校验失败，跳过"
      continue
    fi
    [[ "$mode" = "release" ]] || { warn "站点 ${domain} 跳过: mode=${mode}（gateway CI 仅支持 release）"; continue; }
    [[ "$(_site_type_for_domain "$domain")" = "pm2" ]] || {
      warn "站点 ${domain} 跳过: 非 pm2 类型"
      continue
    }

    expected="$(_webhook_read_kv "$wf" release_name)"
    if ! _webhook_release_name_match "$expected" "${release:-$app}" "$tag"; then
      warn "站点 ${domain} 跳过: release 不匹配（期望 ${expected:-任意}，实际 release=${release:-} app=${app:-} tag=${tag}）"
      continue
    fi
    asset_hint="$(_webhook_read_kv "$wf" asset_name)" || true
    if ! _webhook_ci_artifact_ok "$artifact" "$asset_hint"; then
      warn "站点 ${domain} 跳过: artifact 不匹配（期望含 ${asset_hint}，实际 ${artifact}）"
      continue
    fi
    dl_url="$(_webhook_github_release_asset_download_url "$repository" "$tag" "$artifact")" \
      || { warn "站点 ${domain} 跳过: 无法构造 release 下载地址"; continue; }
    if _webhook_deploy_gateway_release "$domain" "$body_file" "${app:-}" "$tag" "$dl_url"; then
      matched=1
    else
      warn "站点 ${domain} gateway release 部署未执行（见上方原因）"
    fi
  done < <(_webhook_sites_for_repo "$norm")

  if [[ "$matched" -eq 1 ]]; then
    info "webhook 处理完成: 已触发 gateway 部署"
    return 0
  fi
  if [[ "$site_count" -eq 0 ]]; then
    info "webhook 处理完成: 无已启用 webhook 站点匹配仓库 ${norm}（slug=$(_webhook_repo_slug "$norm")）"
  else
    info "webhook 处理完成: 仓库 ${norm} 有 ${site_count} 个站点，均未触发 gateway 部署（见上方跳过原因）"
  fi
  return 0
}

_webhook_process_ci_static_release() {
  local body_file="$1" headers_file="${2:-}"
  local parsed repository="" tag="" artifact="" app="" release="" bearer norm dl_url
  local matched=0 site_count=0 domain mode wf secret expected asset_hint line k v

  parsed="$(_webhook_parse_ci_static_release "$body_file")" || { warn "无法解析 CI static-release payload"; return 1; }
  while IFS= read -r line; do
    [[ "$line" != *=* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      repository) repository="$v" ;;
      tag)        tag="$(_webhook_trim_token "$v")" ;;
      release)    release="$(_webhook_trim_token "$v")" ;;
      artifact)   artifact="$(_webhook_trim_token "$v")" ;;
      app)        app="$(_webhook_trim_token "$v")" ;;
    esac
  done <<< "$parsed"

  bearer="$(_webhook_bearer_from_headers "$headers_file")" || true
  norm="$(_webhook_normalize_repo "$repository")"
  [[ -n "$norm" ]] || { warn "无法解析仓库: ${repository:-}"; return 1; }
  [[ -n "$tag" && -n "$artifact" ]] || { warn "CI payload 缺少 tag 或 artifact"; return 1; }

  info "webhook 解析: event=static-release tag=${tag} artifact=${artifact} repo=${norm}"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    site_count=$((site_count + 1))
    domain="${line%%|*}"
    mode="${line#*|}"
    deploy_log_bind_domain "$domain"
    wf="$(site_webhook_file "$domain")"
    secret="$(_webhook_read_kv "$wf" secret)"
    if ! _webhook_verify_bearer_token "$bearer" "$secret"; then
      warn "站点 ${domain} Bearer token 校验失败，跳过"
      continue
    fi
    [[ "$mode" = "release" ]] || { warn "站点 ${domain} 跳过: mode=${mode}（CI 仅支持 release）"; continue; }

    expected="$(_webhook_read_kv "$wf" release_name)"
    if ! _webhook_release_name_match "$expected" "${release:-$app}" "$tag"; then
      warn "站点 ${domain} 跳过: release 不匹配（期望 ${expected:-任意}，实际 release=${release:-} app=${app:-} tag=${tag}）"
      continue
    fi
    asset_hint="$(_webhook_read_kv "$wf" asset_name)" || true
    if ! _webhook_ci_artifact_ok "$artifact" "$asset_hint"; then
      warn "站点 ${domain} 跳过: artifact 不匹配（期望含 ${asset_hint}，实际 ${artifact}）"
      continue
    fi
    dl_url="$(_webhook_github_release_asset_download_url "$repository" "$tag" "$artifact")" \
      || { warn "站点 ${domain} 跳过: 无法构造 release 下载地址"; continue; }
    if _webhook_deploy_release "$domain" "$body_file" "${app:-}" "$tag" "$dl_url"; then
      matched=1
    else
      warn "站点 ${domain} release 部署未执行（见上方原因）"
    fi
  done < <(_webhook_sites_for_repo "$norm")

  if [[ "$matched" -eq 1 ]]; then
    info "webhook 处理完成: 已触发部署"
    return 0
  fi
  if [[ "$site_count" -eq 0 ]]; then
    info "webhook 处理完成: 无已启用 webhook 站点匹配仓库 ${norm}（slug=$(_webhook_repo_slug "$norm")）"
  else
    info "webhook 处理完成: 仓库 ${norm} 有 ${site_count} 个站点，均未触发部署（见上方跳过原因）"
  fi
  return 0
}

_webhook_process_payload() {
  local body_file="$1" event="${2:-}" gh_sig="${3:-}" gitee_token="${4:-}" headers_file="${5:-}"

  if _webhook_parse_ci_gateway_release "$body_file" &>/dev/null; then
    _webhook_process_ci_gateway_release "$body_file" "$headers_file"
    return $?
  fi

  if _webhook_parse_ci_static_release "$body_file" &>/dev/null; then
    _webhook_process_ci_static_release "$body_file" "$headers_file"
    return $?
  fi

  local action ref repo_full clone_url html_url norm provider parsed line k v
  action="$(_webhook_json_field "$body_file" '"action"[[:space:]]*:[[:space:]]*"[^"]+"')"
  ref="$(_webhook_json_field "$body_file" '"ref"[[:space:]]*:[[:space:]]*"[^"]+"')"
  repo_full="$(_webhook_json_field "$body_file" '"full_name"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -z "$repo_full" ]] && repo_full="$(_webhook_json_field "$body_file" '"path_with_namespace"[[:space:]]*:[[:space:]]*"[^"]+"')"
  clone_url="$(_webhook_json_field "$body_file" '"clone_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -z "$clone_url" ]] && clone_url="$(_webhook_json_field "$body_file" '"git_ssh_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  html_url="$(_webhook_json_field "$body_file" '"html_url"[[:space:]]*:[[:space:]]*"[^"]+"')"
  [[ -z "$html_url" ]] && html_url="$(_webhook_json_field "$body_file" '"url"[[:space:]]*:[[:space:]]*"https://gitee\.com[^"]+"')"

  parsed="$(_webhook_parse_release_payload "$body_file" 2>/dev/null || true)"
  if [[ -n "$parsed" ]]; then
    while IFS= read -r line; do
      [[ "$line" != *=* ]] && continue
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        action)    [[ -n "$v" ]] && action="$v" ;;
        repo_full) [[ -n "$v" ]] && repo_full="$v" ;;
        clone_url) [[ -n "$v" ]] && clone_url="$v" ;;
        html_url)  [[ -n "$v" ]] && html_url="$v" ;;
      esac
    done <<< "$parsed"
  fi

  norm=""
  [[ -n "$clone_url" ]] && norm="$(_webhook_normalize_repo "$clone_url")"
  [[ -z "$norm" && -n "$html_url" ]] && norm="$(_webhook_normalize_repo "$html_url")"
  [[ -z "$norm" && -n "$repo_full" ]] && norm="$(_webhook_normalize_repo "$repo_full")"
  [[ -n "$norm" ]] || { warn "无法解析仓库"; return 1; }
  provider="${norm%%:*}"

  local rel_name rel_tag tag_name matched=0 domain mode wf secret ok_verify=0 site_count=0
  rel_tag="$(_webhook_json_field "$body_file" '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"')"
  rel_name="$(_webhook_json_release_name "$body_file")"
  if [[ -n "$parsed" ]]; then
    while IFS= read -r line; do
      [[ "$line" != *=* ]] && continue
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        rel_tag)  [[ -n "$v" ]] && rel_tag="$v" ;;
        rel_name) [[ -n "$v" ]] && rel_name="$v" ;;
      esac
    done <<< "$parsed"
  fi
  tag_name="${rel_tag:-}"

  info "webhook 解析: event=${event} action=${action} tag=${rel_tag:-} name=${rel_name:-} repo=${norm}"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    site_count=$((site_count + 1))
    domain="${line%%|*}"
    mode="${line#*|}"
    deploy_log_bind_domain "$domain"
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
      if [[ "$event" != "release" && "$event" != "Release Hook" && -z "$rel_tag" ]]; then
        warn "站点 ${domain} 跳过: event=${event} 非 release"
        continue
      fi
      if ! _webhook_release_action_ok "$action" "$event"; then
        warn "站点 ${domain} 跳过: action=${action} 非发布事件"
        continue
      fi
      local expected="$(_webhook_read_kv "$wf" release_name)"
      if ! _webhook_release_name_match "$expected" "$rel_name" "$rel_tag"; then
        warn "站点 ${domain} 跳过: release 不匹配（期望 ${expected:-任意}，实际 name=${rel_name:-} tag=${rel_tag:-}）"
        continue
      fi
      if _webhook_deploy_release "$domain" "$body_file" "$rel_name" "$rel_tag" ""; then
        matched=1
      else
        warn "站点 ${domain} release 部署未执行（见上方原因）"
      fi
    elif [[ "$mode" = "tag" ]]; then
      local tag="${ref#refs/tags/}"
      [[ -n "$tag" && "$ref" == refs/tags/* ]] || { warn "站点 ${domain} 跳过: 无 tag ref"; continue; }
      [[ "$event" = "push" || "$event" = "Push Hook" || "$event" = "Tag Push Hook" ]] || { warn "站点 ${domain} 跳过: event=${event}"; continue; }
      if _webhook_deploy_tag "$domain" "$tag"; then
        matched=1
      else
        warn "站点 ${domain} tag 部署未执行（见上方原因）"
      fi
    fi
  done < <(_webhook_sites_for_repo "$norm")

  if [[ "$matched" -eq 1 ]]; then
    info "webhook 处理完成: 已触发部署"
    return 0
  fi
  if [[ "$site_count" -eq 0 ]]; then
    info "webhook 处理完成: 无已启用 webhook 站点匹配仓库 ${norm}（slug=$(_webhook_repo_slug "$norm")）"
  else
    info "webhook 处理完成: 仓库 ${norm} 有 ${site_count} 个站点，均未触发部署（见上方跳过原因）"
  fi
  return 0
}

_webhook_write_listener_env() {
  local _http_proxy _gh_proxy _notify _gh_token _ge_token
  _webhook_load_listener_env
  _http_proxy="${WEBHOOK_HTTP_PROXY:-}"
  _gh_proxy="${WEBHOOK_GH_PROXY:-}"
  _notify="${WEBHOOK_NOTIFY_URL:-}"
  _gh_token="${WEBHOOK_GITHUB_TOKEN:-}"
  _ge_token="${WEBHOOK_GITEE_TOKEN:-}"
  mkdir -p "$WEBHOOK_DIR"
  cat > "$WEBHOOK_LISTENER_ENV" <<EOF
WEBHOOK_PORT=${WEBHOOK_PORT:-9080}
WEBHOOK_BIND=${WEBHOOK_BIND:-127.0.0.1}
WEBHOOK_PATH=${WEBHOOK_PATH:-/hooks}
WEBHOOK_PUBLIC_MODE=${WEBHOOK_PUBLIC_MODE:-local}
WEBHOOK_PROXY_DOMAIN=${WEBHOOK_PROXY_DOMAIN:-}
EOF
  [[ -n "$_http_proxy" ]] && printf 'WEBHOOK_HTTP_PROXY=%s\n' "$_http_proxy" >> "$WEBHOOK_LISTENER_ENV"
  [[ -n "$_gh_proxy" ]] && printf 'WEBHOOK_GH_PROXY=%s\n' "$_gh_proxy" >> "$WEBHOOK_LISTENER_ENV"
  [[ -n "$_notify" ]] && printf 'WEBHOOK_NOTIFY_URL=%s\n' "$_notify" >> "$WEBHOOK_LISTENER_ENV"
  [[ -n "$_gh_token" ]] && printf 'WEBHOOK_GITHUB_TOKEN=%s\n' "$_gh_token" >> "$WEBHOOK_LISTENER_ENV"
  [[ -n "$_ge_token" ]] && printf 'WEBHOOK_GITEE_TOKEN=%s\n' "$_ge_token" >> "$WEBHOOK_LISTENER_ENV"
  chmod 600 "$WEBHOOK_LISTENER_ENV"
}

_webhook_public_callback_url() {
  _webhook_load_listener_env
  local path="${WEBHOOK_PATH:-/hooks}"
  case "${WEBHOOK_PUBLIC_MODE:-local}" in
    nginx)
      if [[ -n "${WEBHOOK_PROXY_DOMAIN:-}" ]]; then
        printf 'https://%s%s' "${WEBHOOK_PROXY_DOMAIN}" "$path"
      fi
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
  return 0
}

_caddy_strip_webhook_proxy() {
  local conf="$1"
  [[ -f "$conf" ]] || return 0
  sed -i '/# deploy-site webhook-proxy BEGIN/,/# deploy-site webhook-proxy END/d' "$conf"
}

_caddy_webhook_proxy_block() {
  local hook_path="$1" port="$2" host
  host="$(_docker_host_gateway)"
  cat <<CADDY
	# deploy-site webhook-proxy BEGIN
	handle ${hook_path}* {
		reverse_proxy ${host}:${port}
	}
	# deploy-site webhook-proxy END
CADDY
}

_caddy_merge_webhook_proxy() {
  local conf="$1" hook_path="$2" port="$3"
  local block tmp
  _caddy_strip_webhook_proxy "$conf"
  block="$(_caddy_webhook_proxy_block "$hook_path" "$port")"
  tmp="$(mktemp)"
  if awk -v blk="$block" '
    BEGIN { inserted=0 }
    /^[^{\n]+ \{/ && !inserted {
      print
      printf "%s", blk
      inserted=1
      next
    }
    { print }
    END { if (!inserted) printf "%s", blk }
  ' "$conf" > "$tmp"; then
    mv "$tmp" "$conf"
  else
    rm -f "$tmp"
    printf '%s\n' "$block" >> "$conf"
  fi
  fix_nginx_conf_d_file "$conf"
}

_webhook_gen_standalone_caddy() {
  local domain="$1" hook_path="$2" port="$3"
  mkdir -p "${CADDY_SITES:-${DATA_DIR}/caddy/sites}"
  local body
  body="$(_caddy_webhook_proxy_block "$hook_path" "$port")
	respond 404
"
  _caddy_write_site "$domain" "$body"
}

_webhook_apply_nginx_proxy() {
  local domain="$1"
  local hook_path="${WEBHOOK_PATH:-/hooks}"
  local port="${WEBHOOK_PORT:-9080}"
  local conf
  conf="$(site_caddy_file "$domain")"
  mkdir -p "${WWW_ROOT}/${domain}"
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${domain}" 2>/dev/null || true
  if [[ -f "$conf" ]]; then
    info "在已有 Caddy 配置 ${conf} 中注入 Webhook 反代"
    _caddy_merge_webhook_proxy "$conf" "$hook_path" "$port"
  else
    info "生成 Webhook 专用 Caddy 配置 ${conf}"
    _webhook_gen_standalone_caddy "$domain" "$hook_path" "$port"
    warn "新域名请执行: $0 ssl --domain=${domain} 签发证书"
  fi
  if container_ok "$(_web_container)"; then
    caddy_validate || die "Caddy 配置校验失败"
    caddy_reload 2>/dev/null && ok "Caddy 已 reload"
  fi
}

_webhook_remove_nginx_proxy() {
  local domain="${WEBHOOK_PROXY_DOMAIN:-}"
  [[ -n "$domain" ]] || return 0
  local conf
  conf="$(site_caddy_file "$domain")"
  [[ -f "$conf" ]] || return 0
  _caddy_strip_webhook_proxy "$conf"
  fix_nginx_conf_d_file "$conf"
  container_ok "$(_web_container)" && caddy_reload 2>/dev/null || true
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
from socketserver import ThreadingMixIn

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

SCRIPT = os.environ["WEBHOOK_SCRIPT"]
PORT = int(os.environ.get("WEBHOOK_PORT", "9080"))
BIND = os.environ.get("WEBHOOK_BIND", "127.0.0.1")
PATH = os.environ.get("WEBHOOK_PATH", "/hooks")
HANDLE_TIMEOUT = 2400

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
            r = subprocess.run(
                [SCRIPT, "webhook", "handle",
                 "--body-file", body_path,
                 "--headers-file", hdr_path,
                 "--event", event,
                 "--github-signature", gh_sig,
                 "--gitee-token", gitee_token],
                timeout=HANDLE_TIMEOUT,
            )
            body_path = hdr_path = None
            if r.returncode == 0:
                self.send_response(200)
                msg = b"deployed\n"
            else:
                self.send_response(500)
                msg = b"deploy failed\n"
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(msg)
        except subprocess.TimeoutExpired:
            sys.stderr.write("webhook handle timed out\n")
            self.send_response(504)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"deploy timed out\n")
        except Exception as exc:
            sys.stderr.write("webhook handle failed: %s\n" % exc)
            self.send_response(500)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"spawn failed\n")
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

ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
PY
}
