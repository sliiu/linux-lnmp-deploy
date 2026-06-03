# shellcheck shell=bash

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
  if [[ "$_scn" = "lnmp-php" ]]; then _ssub="php"; else _ssub="php-${_scn#lnmp-php}"; fi
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
  if [[ "${STATUS_ALL:-0}" -ne 1 && -z "${DOMAIN:-}" ]]; then
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
        if [[ "$_scn" = "lnmp-php" ]]; then _ssub="php"; else _ssub="php-${_scn#lnmp-php}"; fi
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

