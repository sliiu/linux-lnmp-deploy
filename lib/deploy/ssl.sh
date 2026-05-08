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
        ALI_KEY=$(prompt "阿里云 DNS AccessKey Id (Ali_Key)")
      fi
      if [[ -z "${ALI_SECRET:-}" ]]; then
        prompt_secret_into "阿里云 DNS AccessKey Secret (Ali_Secret)" ALI_SECRET
      fi
      ;;
    dns_dp)
      if [[ -z "${DP_ID:-}" ]]; then
        DP_ID=$(prompt "DNSPod API ID (DP_Id)")
      fi
      if [[ -z "${DP_KEY:-}" ]]; then
        prompt_secret_into "DNSPod API Token (DP_Key)" DP_KEY
      fi
      ;;
    dns_gd)
      if [[ -z "${GD_KEY:-}" ]]; then
        GD_KEY=$(prompt "GoDaddy API Key (GD_Key)")
      fi
      if [[ -z "${GD_SECRET:-}" ]]; then
        prompt_secret_into "GoDaddy API Secret (GD_Secret)" GD_SECRET
      fi
      ;;
    dns_aws)
      if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        AWS_ACCESS_KEY_ID=$(prompt "AWS Access Key ID")
      fi
      if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        prompt_secret_into "AWS Secret Access Key" AWS_SECRET_ACCESS_KEY
      fi
      ;;
    dns_tencent)
      if [[ -z "${TENCENT_SECRET_ID:-}" ]]; then
        TENCENT_SECRET_ID=$(prompt "腾讯云 SecretId")
      fi
      if [[ -z "${TENCENT_SECRET_KEY:-}" ]]; then
        prompt_secret_into "腾讯云 SecretKey" TENCENT_SECRET_KEY
      fi
      ;;
  esac
}

issue_ssl() {
  local domain="$1" site_type="$2" ssl_dns="$3" force="${4:-}" frontend_root="${5:-dist}"

  mkdir -p "${SSL_DIR}/${domain}"

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
    docker exec "${dns_env_args[@]}" lnmp-acme \
      acme.sh --issue -d "${domain}" \
      --config-home /acme.sh \
      --dns "$ssl_dns" --keylength ec-256 --server "${acme_ca}" \
      ${force} || acme_exit=$?
  else
    local wk_inner
    if [[ "$site_type" = "laravel" ]]; then
      wk_inner="/www/${domain}/public"
      mkdir -p "${WWW_ROOT}/${domain}/public/.well-known/acme-challenge"
    else
      wk_inner="/www/${domain}"
      mkdir -p "${WWW_ROOT}/${domain}/.well-known/acme-challenge"
    fi
    chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}/${domain}/.well-known" 2>/dev/null || true
    chmod -R 755 "${WWW_ROOT}/${domain}/.well-known" 2>/dev/null || true

    docker exec lnmp-acme \
      acme.sh --issue -d "${domain}" \
      --config-home /acme.sh \
      --webroot "${wk_inner}" --keylength ec-256 --server "${acme_ca}" \
      ${force} || acme_exit=$?
  fi

  if [[ $acme_exit -ne 0 && $acme_exit -ne 2 ]]; then
    die "SSL 签发失败 (exit=${acme_exit})。Let's Encrypt 对同一域名 7 天内正式证书约 5 张上限；遇 429 请等到日志中 retry after 之后再试，或临时加 --ssl-staging 使用测试 CA。https://letsencrypt.org/docs/rate-limits/"
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
    die "acme.sh --install-cert 失败。排查: docker exec lnmp-acme acme.sh --list --config-home /acme.sh"
  fi

  fix_nginx_ssl_domain "$domain"

  wait_container_running "lnmp-nginx" 30
  if ! docker exec lnmp-nginx nginx -s reload; then
    die "nginx reload 失败（请检查证书路径与权限）"
  fi
  ok "SSL 证书已安装"
}

