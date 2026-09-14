# shellcheck shell=bash

ensure_placeholder_cert() {
  local domain="$1"
  mkdir -p "${SSL_DIR}/${domain}"
  if [[ ! -f "${SSL_DIR}/${domain}/fullchain.cer" ]]; then
    openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
      -keyout "${SSL_DIR}/${domain}/${domain}.key" \
      -out    "${SSL_DIR}/${domain}/fullchain.cer" \
      -subj   "/CN=placeholder" 2>/dev/null
  fi
  fix_nginx_ssl_domain "$domain"
}

check_cert_expiry() {
  local cert="$1" domain="${2:-unknown}"
  if [[ ! -f "$cert" ]]; then
    echo "missing"
    return 1
  fi
  if ! command -v openssl &>/dev/null; then
    echo "no_openssl"
    return 1
  fi
  local notafter enddate_epoch now_epoch
  notafter="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  enddate_epoch="$(date -d "$notafter" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$notafter" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  if [[ "$enddate_epoch" -le 0 ]]; then
    echo "parse_error"
    return 1
  fi
  if [[ "$now_epoch" -gt "$enddate_epoch" ]]; then
    echo "expired"
    return 2
  fi
  local days_left=$(( (enddate_epoch - now_epoch) / 86400 ))
  if [[ "$days_left" -le 7 ]]; then
    echo "expiring_soon:${days_left}"
    return 3
  fi
  echo "valid:${days_left}"
  return 0
}

_is_dns_mode() {
  case "$1" in dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) return 0 ;; *) return 1 ;; esac
}

_acme_ssl_validate_dns_creds() {
  local m="$1"
  case "$m" in
    dns_cf)      [[ -n "${CF_TOKEN:-}" ]] || die "dns_cf 需要 Cloudflare API Token（--cf-token 或交互）" ;;
    dns_ali)     [[ -n "${ALI_KEY:-}" && -n "${ALI_SECRET:-}" ]] || die "dns_ali 需要 Ali_Key / Ali_Secret（--ali-key / --ali-secret）" ;;
    dns_dp)      [[ -n "${DP_ID:-}" && -n "${DP_KEY:-}" ]] || die "dns_dp 需要 DNSPod API（--dp-id / --dp-key）" ;;
    dns_gd)      [[ -n "${GD_KEY:-}" && -n "${GD_SECRET:-}" ]] || die "dns_gd 需要 GoDaddy API（--gd-key / --gd-secret）" ;;
    dns_aws)     [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "dns_aws 需要 AWS 密钥（--aws-access-key / --aws-secret-key）" ;;
    dns_tencent) [[ -n "${TENCENT_SECRET_ID:-}" && -n "${TENCENT_SECRET_KEY:-}" ]] || die "dns_tencent 需要腾讯云密钥（--tencent-secret-id / --tencent-secret-key）" ;;
    *)           die "未知 DNS 模式: $m（支持 webroot / dns_cf / dns_ali / dns_dp / dns_gd / dns_aws / dns_tencent）" ;;
  esac
}

_collect_ssl_dns_creds_interactive() {
  case "${SSL_DNS}" in
    dns_cf)
      if [[ -z "${CF_TOKEN:-}" ]]; then
        prompt_secret_into "Cloudflare API Token" CF_TOKEN
      fi
      ;;
    dns_ali)
      if [[ -z "${ALI_KEY:-}" ]]; then
        prompt_required "阿里云 DNS AccessKey Id (Ali_Key)"
        ALI_KEY=$PROMPT_RESULT
      fi
      if [[ -z "${ALI_SECRET:-}" ]]; then
        prompt_secret_into "阿里云 DNS AccessKey Secret (Ali_Secret)" ALI_SECRET
      fi
      ;;
    dns_dp)
      if [[ -z "${DP_ID:-}" ]]; then
        prompt_required "DNSPod API ID (DP_Id)"
        DP_ID=$PROMPT_RESULT
      fi
      if [[ -z "${DP_KEY:-}" ]]; then
        prompt_secret_into "DNSPod API Token (DP_Key)" DP_KEY
      fi
      ;;
    dns_gd)
      if [[ -z "${GD_KEY:-}" ]]; then
        prompt_required "GoDaddy API Key (GD_Key)"
        GD_KEY=$PROMPT_RESULT
      fi
      if [[ -z "${GD_SECRET:-}" ]]; then
        prompt_secret_into "GoDaddy API Secret (GD_Secret)" GD_SECRET
      fi
      ;;
    dns_aws)
      if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        prompt_required "AWS Access Key ID"
        AWS_ACCESS_KEY_ID=$PROMPT_RESULT
      fi
      if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        prompt_secret_into "AWS Secret Access Key" AWS_SECRET_ACCESS_KEY
      fi
      ;;
    dns_tencent)
      if [[ -z "${TENCENT_SECRET_ID:-}" ]]; then
        prompt_required "腾讯云 SecretId"
        TENCENT_SECRET_ID=$PROMPT_RESULT
      fi
      if [[ -z "${TENCENT_SECRET_KEY:-}" ]]; then
        prompt_secret_into "腾讯云 SecretKey" TENCENT_SECRET_KEY
      fi
      ;;
  esac
}

_ssl_validate_dns_ready() {
  local domain="$1" mode="$2"
  if [[ "$mode" = "webroot" ]]; then
    return 0
  fi
  info "检查域名 ${domain} 的 DNS 解析..."
  local resolved
  resolved="$(dig +short "$domain" A 2>/dev/null | head -n1 || nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -v '#' | head -n1 || true)"
  if [[ -z "$resolved" ]]; then
    die "DNS 解析失败（NXDOMAIN）：域名 ${domain} 未解析或 DNS 尚未生效。DNS-01 模式需要域名正确解析。请等待 DNS 传播后重试，或改用 --dns=webroot（需本机 80 可达）"
  fi
  ok "域名 ${domain} 解析正常: ${resolved}"
}

issue_ssl() {
  local domain="$1" site_type="$2" ssl_dns="$3" force="${4:-}" frontend_root="${5:-dist}"

  mkdir -p "${SSL_DIR}/${domain}"

  _ssl_validate_dns_ready "$domain" "$ssl_dns"

  local acme_ca="letsencrypt"
  if [[ "${SSL_STAGING:-0}" = "1" ]]; then
    acme_ca="letsencrypt_test"
    warn "使用 Let's Encrypt 测试 CA（浏览器不信任），仅用于调试或规避正式环境限流"
  fi

  local acme_exit=0
  if _is_dns_mode "$ssl_dns"; then
    _acme_ssl_validate_dns_creds "$ssl_dns"
    local dns_env_args=()
    case "$ssl_dns" in
      dns_cf)      dns_env_args=(-e "CF_Token=${CF_TOKEN}") ;;
      dns_ali)     dns_env_args=(-e "Ali_Key=${ALI_KEY}" -e "Ali_Secret=${ALI_SECRET}") ;;
      dns_dp)      dns_env_args=(-e "DP_Id=${DP_ID}" -e "DP_Key=${DP_KEY}") ;;
      dns_gd)      dns_env_args=(-e "GD_Key=${GD_KEY}" -e "GD_Secret=${GD_SECRET}") ;;
      dns_aws)     dns_env_args=(-e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}") ;;
      dns_tencent) dns_env_args=(-e "Tencent_SecretId=${TENCENT_SECRET_ID}" -e "Tencent_SecretKey=${TENCENT_SECRET_KEY}") ;;
    esac
    local acme_output acme_tmpfile
    acme_tmpfile="$(mktemp)"
    docker exec "${dns_env_args[@]}" lnmp-acme \
      acme.sh --issue -d "${domain}" \
      --config-home /acme.sh \
      --dns "$ssl_dns" --keylength ec-256 --server "${acme_ca}" \
      ${force} 2>&1 | tee "$acme_tmpfile" || acme_exit=$?
    acme_output="$(cat "$acme_tmpfile")"
    rm -f "$acme_tmpfile"
    
    if [[ $acme_exit -ne 0 && $acme_exit -ne 2 ]]; then
      local err_hint=""
      if echo "$acme_output" | grep -qi "NXDOMAIN"; then
        err_hint="域名 DNS 未解析或未生效（NXDOMAIN）。请确认域名指向本机 IP，并等待 DNS 传播（通常 5-30 分钟）后重试。检查: dig ${domain}"
      elif echo "$acme_output" | grep -qi "rate limit\|too many\|429"; then
        err_hint="触发 Let's Encrypt 速率限制（同一域名 7 天内正式证书约 5 张上限）。请等到日志中 'retry after' 时间后再试，或临时使用 --ssl-staging 测试。https://letsencrypt.org/docs/rate-limits/"
      elif echo "$acme_output" | grep -qi "timeout\|timed out"; then
        err_hint="ACME 验证超时。DNS-01 需确保 DNS API 凭证正确且域名托管在对应服务商。webroot 需确保本机 80 端口可从公网访问"
      elif echo "$acme_output" | grep -qi "invalid.*credentials\|authentication.*failed\|unauthorized"; then
        err_hint="DNS API 凭证无效或权限不足（${ssl_dns}）。请检查 API key/token 是否正确且有 DNS 修改权限"
      fi
      local fail_msg="SSL 签发失败 (exit=${acme_exit})${err_hint:+。${err_hint}}"
      [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]] && printf '%s\n' "$acme_output" >> "$LOG_FILE"
      ops_notify_exception "SSL 签发失败" "$fail_msg"
      if [[ "${SSL_SOFT_FAIL:-0}" = "1" ]]; then
        warn "SSL 签发失败 (exit=${acme_exit})${err_hint:+: ${err_hint}}，站点 webhook 已注册，可稍后 deploy-site update 或手动签发"
        return 1
      fi
      die "$fail_msg"
    fi
    if [[ $acme_exit -eq 2 ]]; then
      info "证书已存在且未过期，跳过签发 (使用 --force-ssl 强制)"
    fi
    if ! docker exec lnmp-acme \
      acme.sh --install-cert -d "${domain}" \
      --config-home /acme.sh \
      --server "${acme_ca}" \
      --ecc \
      --key-file       "/acme.sh/${domain}/${domain}.key" \
      --fullchain-file "/acme.sh/${domain}/fullchain.cer" \
      --reloadcmd "true"; then
      ops_notify_exception "acme.sh --install-cert 失败" "acme.sh --install-cert 失败"
      if [[ "${SSL_SOFT_FAIL:-0}" = "1" ]]; then
        warn "acme.sh --install-cert 失败，站点 webhook 已注册，可稍后重试 SSL"
        return 1
      fi
      die "acme.sh --install-cert 失败。排查: docker exec lnmp-acme acme.sh --list --config-home /acme.sh"
    fi
    printf 'file\n' > "${NGINX_CONF}/${domain}.tls-mode"
    fix_nginx_ssl_domain "$domain"
  else
    info "Caddy 自动 HTTPS（HTTP-01）"
    printf 'auto\n' > "${NGINX_CONF}/${domain}.tls-mode"
  fi
  case "${site_type:-$(_site_type_for_domain "$domain")}" in
    laravel) gen_caddy_laravel "$domain" ;;
    pm2) gen_caddy_pm2 "$domain" ;;
    proxy) gen_caddy_proxy "$domain" ;;
    *) gen_caddy_frontend "$domain" "${frontend_root:-}" ;;
  esac

  wait_container_running "$(_web_container)" 30
  if ! caddy_reload; then
    if [[ "${SSL_SOFT_FAIL:-0}" = "1" ]]; then
      warn "Caddy reload 失败（证书可能未就绪），站点 webhook 已注册"
      return 1
    fi
    die "Caddy reload 失败（请检查证书路径与权限）"
  fi
  ok "SSL 证书已安装"
}

