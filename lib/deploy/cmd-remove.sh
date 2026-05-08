# shellcheck shell=bash

cmd_remove() {
  prompt_pick_domain "选择要移除的站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  echo ""
  hr; info "移除站点: ${DOMAIN}"; echo ""

  [[ "${YES:-0}" -eq 0 ]] && ! confirm "确认删除 ${DOMAIN}？所有配置和数据将被移除" "n" && { info "已取消"; return; }

  rm -f "${NGINX_CONF}/${DOMAIN}.sse-prefixes" 2>/dev/null || true
  rm -f "${NGINX_CONF}/${DOMAIN}.php-version" 2>/dev/null || true
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

