# shellcheck shell=bash

_webhook_save_on_add() {
  [[ "${WEBHOOK_ENABLE:-0}" -ne 1 && -z "${WEBHOOK_MODE:-}" ]] && return 0
  local mode="${WEBHOOK_MODE:-}"
  if [[ -z "$mode" && "${WEBHOOK_ENABLE:-0}" -eq 1 ]]; then
    mode="$([[ "$SITE_TYPE" = "frontend" ]] && echo release || echo tag)"
  fi
  [[ -n "$mode" ]] || return 0
  [[ -n "$GIT_REPO" ]] || die "启用 webhook 需指定 --git="
  case "$mode" in
    release|tag) ;;
    *) die "无效 --webhook=${mode}（release | tag）" ;;
  esac
  [[ "$mode" != "release" || -n "$WEBHOOK_RELEASE_NAME" ]] \
    || die "静态站点 release 模式需 --webhook-release-name="
  local fe="" sec
  sec="$(_webhook_write_site_config "$DOMAIN" "$mode" "$GIT_REPO" "${WEBHOOK_RELEASE_NAME:-}" "${WEBHOOK_SECRET:-}")"
  ok "Webhook 已配置（mode=${mode}）"
  if [[ "$mode" = "release" ]]; then
    info "  静态产物将解压到 ${WWW_ROOT}/${DOMAIN}/（站点根，不用 dist）"
  fi
  info "  回调 URL: $(_webhook_public_callback_url)"
  info "  Secret: ${sec}（写入 $(site_webhook_file "$DOMAIN")）"
  info "  执行 webhook setup 安装 systemd 监听服务"
}

# 为已有站点写入/恢复 ${NGINX_CONF}/<域名>.webhook（update / webhook enable 共用）
_webhook_configure_site() {
  local site_dir="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$site_dir" ]] || die "站点 ${DOMAIN} 不存在"

  local st="laravel"
  [[ -f "${site_dir}/artisan" ]] || st="frontend"

  local wf_old="" old_secret old_rel
  wf_old="$(site_webhook_file "$DOMAIN")"
  if [[ -f "$wf_old" ]]; then
    old_secret="$(_webhook_read_kv "$wf_old" secret)" || true
    old_rel="$(_webhook_read_kv "$wf_old" release_name)" || true
    info "检测到已有 Webhook 配置，将更新（未指定 --webhook-secret 时保留原 Secret）"
  fi

  if [[ -z "$WEBHOOK_MODE" ]]; then
    if [[ "$st" = "frontend" ]]; then
      WEBHOOK_MODE="release"
    else
      local _i; _i=$(menu_select "Webhook 模式" "tag（监听 Git tag 推送）" "release（监听 Release 发版）")
      [[ "$_i" -eq 1 ]] && WEBHOOK_MODE="release" || WEBHOOK_MODE="tag"
    fi
  fi

  [[ -n "$GIT_REPO" ]] || {
    local remote=""
    if [[ -d "${site_dir}/.git" ]]; then
      remote="$(su - "${DEVOPS_USER}" -c "cd '${site_dir}' && git remote get-url origin 2>/dev/null" || true)"
    fi
    if [[ -n "$remote" ]]; then
      GIT_REPO="$remote"
    elif [[ -f "$wf_old" ]]; then
      GIT_REPO="$(_webhook_read_kv "$wf_old" git_repo)"
    else
      GIT_REPO=$(prompt "Git 仓库地址（release 仅匹配用；tag 模式需可 pull）")
    fi
  }
  [[ -n "$GIT_REPO" ]] || die "Git 仓库地址不能为空"

  if [[ "$WEBHOOK_MODE" = "release" && -z "$WEBHOOK_RELEASE_NAME" ]]; then
    WEBHOOK_RELEASE_NAME=$(prompt "Release 名称（与 Release name 或 tag 匹配）" "${old_rel:-}")
  fi
  [[ "$WEBHOOK_MODE" != "release" || -n "$WEBHOOK_RELEASE_NAME" ]] \
    || die "release 模式需 --webhook-release-name="

  local sec="${WEBHOOK_SECRET:-${old_secret:-}}"
  sec="$(_webhook_write_site_config "$DOMAIN" "$WEBHOOK_MODE" "$GIT_REPO" "${WEBHOOK_RELEASE_NAME:-}" "$sec")"
  WEBHOOK_ENABLE=1
  ok "Webhook 已配置: ${DOMAIN} (${WEBHOOK_MODE})"
  if [[ "$WEBHOOK_MODE" = "release" ]]; then
    info "静态产物将解压到 ${WWW_ROOT}/${DOMAIN}/（站点根，不用 dist）"
    if [[ "$st" = "frontend" ]] && container_ok "lnmp-nginx"; then
      gen_nginx_frontend "$DOMAIN" ""
      fix_site_readable_for_nginx "$DOMAIN" "frontend" ""
      if docker exec lnmp-nginx nginx -t 2>&1; then
        docker exec lnmp-nginx nginx -s reload 2>/dev/null && ok "Nginx 已切换为站点根目录"
      fi
    fi
  fi
  info "Secret: ${sec}"
  info "回调 URL: $(_webhook_public_callback_url)"
  info "请执行: $0 webhook setup（若尚未安装监听）"
}

_collect_webhook_setup_interactive() {
  local cli_only="${1:-0}"
  _webhook_load_listener_env

  if [[ "$cli_only" -eq 1 ]]; then
    local need_mode=0 need_domain=0
    [[ -z "${WEBHOOK_PUBLIC_MODE:-}" ]] && need_mode=1
    [[ "${WEBHOOK_PUBLIC_MODE:-}" = "nginx" && -z "${WEBHOOK_PROXY_DOMAIN:-}" ]] && need_domain=1
    [[ "$need_mode" -eq 0 && "$need_domain" -eq 0 ]] && return 0
  fi

  local _i
  _i=$(menu_select "Webhook 公网访问方式" \
    "Nginx 反代（推荐：HTTPS 域名 → 本机 127.0.0.1）" \
    "直接绑定 0.0.0.0（外网直连端口）" \
    "仅本机 127.0.0.1（默认）")
  case "$_i" in
    0) WEBHOOK_PUBLIC_MODE=nginx; WEBHOOK_BIND=127.0.0.1 ;;
    1) WEBHOOK_PUBLIC_MODE=bind; WEBHOOK_BIND=0.0.0.0 ;;
    2) WEBHOOK_PUBLIC_MODE=local; WEBHOOK_BIND=127.0.0.1 ;;
  esac

  WEBHOOK_PATH=$(prompt "Webhook 路径" "${WEBHOOK_PATH:-/hooks}")
  [[ "$WEBHOOK_PATH" == /* ]] || die "WEBHOOK_PATH 须以 / 开头"

  if [[ "$WEBHOOK_PUBLIC_MODE" = "nginx" ]]; then
    local -a doms=()
    while IFS= read -r d; do doms+=("$d"); done < <(_list_deployed_domains)
    if [[ ${#doms[@]} -gt 0 ]]; then
      local _items=("${doms[@]}" "手动输入域名...")
      _i=$(menu_select "反代到哪个域名" "${_items[@]}")
      if [[ "$_i" -lt ${#doms[@]} ]]; then
        WEBHOOK_PROXY_DOMAIN="${doms[$_i]}"
      else
        WEBHOOK_PROXY_DOMAIN=$(prompt "Webhook 回调域名" "${WEBHOOK_PROXY_DOMAIN:-}")
      fi
    else
      WEBHOOK_PROXY_DOMAIN=$(prompt "Webhook 回调域名" "${WEBHOOK_PROXY_DOMAIN:-}")
    fi
    [[ -n "$WEBHOOK_PROXY_DOMAIN" ]] || die "反代域名不能为空"
  elif [[ "$WEBHOOK_PUBLIC_MODE" = "bind" ]]; then
    WEBHOOK_BIND=$(prompt "监听地址（0.0.0.0 = 全部网卡）" "${WEBHOOK_BIND:-0.0.0.0}")
    WEBHOOK_PORT=$(prompt "监听端口" "${WEBHOOK_PORT:-9080}")
  fi
}

cmd_webhook() {
  local sub="${1:-}"
  (( $# > 0 )) && shift
  case "$sub" in
    enable)  parse_args "$@"; cmd_webhook_enable ;;
    disable) parse_args "$@"; cmd_webhook_disable ;;
    setup)   parse_args "$@"; cmd_webhook_setup ;;
    serve)   cmd_webhook_serve ;;
    handle)  parse_args "$@"; cmd_webhook_handle ;;
    list)    parse_args "$@"; cmd_webhook_list ;;
    "")
      while true; do
        hr
        info "Webhook 管理"
        hr
        local _i
        _i=$(menu_select "请选择" \
          "为站点启用 webhook" \
          "禁用站点 webhook" \
          "安装/更新监听服务 (systemd)" \
          "查看已启用 webhook 的站点" \
          "返回")
        echo ""
        case "$_i" in
          0) DOMAIN=""; cmd_webhook_enable ;;
          1) DOMAIN=""; cmd_webhook_disable ;;
          2) cmd_webhook_setup ;;
          3) cmd_webhook_list ;;
          4) return 0 ;;
        esac
        echo ""
        confirm "继续？" "y" || return 0
      done
      ;;
    *) die "未知 webhook 子命令: ${sub}（enable | disable | setup | serve | handle | list）" ;;
  esac
}

cmd_webhook_enable() {
  prompt_pick_domain "选择站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"
  _webhook_configure_site
}

cmd_webhook_disable() {
  prompt_pick_domain "选择站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"
  rm -f "$(site_webhook_file "$DOMAIN")" 2>/dev/null || true
  ok "已禁用 ${DOMAIN} 的 webhook"
}

cmd_webhook_list() {
  echo ""
  hr; info "Webhook 站点"; hr; echo ""
  local conf found=0 domain mode repo rel secret
  for conf in "${NGINX_CONF}"/*.webhook; do
    [[ -f "$conf" ]] || continue
    found=1
    domain=$(basename "$conf" .webhook)
    mode="$(_webhook_read_kv "$conf" mode)"
    repo="$(_webhook_read_kv "$conf" git_repo)"
    rel="$(_webhook_read_kv "$conf" release_name)"
    secret="$(_webhook_read_kv "$conf" secret)"
    printf "  %-28s mode:%-8s release:%-16s\n" "$domain" "$mode" "${rel:--}"
    printf "    repo: %s\n" "$repo"
    printf "    secret: %s...\n" "${secret:0:8}"
  done
  [[ "$found" -eq 0 ]] && info "暂无"
  _webhook_load_listener_env
  echo ""
  info "监听: ${WEBHOOK_BIND}:${WEBHOOK_PORT}${WEBHOOK_PATH}（mode=${WEBHOOK_PUBLIC_MODE:-local}）"
  info "回调 URL: $(_webhook_public_callback_url)"
  systemctl is-active lnmp-deploy-webhook &>/dev/null && ok "systemd: lnmp-deploy-webhook 运行中" \
    || warn "systemd: lnmp-deploy-webhook 未运行（执行 webhook setup）"
  echo ""
}

cmd_webhook_setup() {
  local script_path old_mode old_domain new_proxy cli_reconfig=0
  info "配置 Webhook 监听服务..."
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy-site.sh"
  [[ -x "$script_path" ]] || script_path="${SCRIPT_DIR}/deploy-site.sh"

  [[ -n "${WEBHOOK_PUBLIC_MODE:-}" || -n "${WEBHOOK_PROXY_DOMAIN:-}" \
     || -n "${WEBHOOK_BIND:-}" || -n "${WEBHOOK_PORT:-}" || -n "${WEBHOOK_PATH:-}" ]] && cli_reconfig=1

  if [[ "$cli_reconfig" -eq 0 ]] && ! interactive_tty_ok && ! [[ -t 0 ]]; then
    die "webhook setup 需交互终端。请 SSH 登录后直接执行（勿用 curl 管道）:
  sudo ${script_path} webhook setup
或指定参数非交互安装:
  sudo ${script_path} webhook setup --webhook-proxy-domain=hook.example.com
  sudo ${script_path} webhook setup --webhook-bind=0.0.0.0 --webhook-port=9080"
  fi

  _webhook_load_listener_env
  old_mode="${WEBHOOK_PUBLIC_MODE:-local}"
  old_domain="${WEBHOOK_PROXY_DOMAIN:-}"

  _collect_webhook_setup_interactive "$cli_reconfig"

  case "${WEBHOOK_PUBLIC_MODE:-local}" in
    nginx|bind|local) ;;
    *) die "无效 WEBHOOK_PUBLIC_MODE: ${WEBHOOK_PUBLIC_MODE}（nginx | bind | local）" ;;
  esac

  new_proxy="${WEBHOOK_PROXY_DOMAIN:-}"

  if [[ "$WEBHOOK_PUBLIC_MODE" = "nginx" ]]; then
    WEBHOOK_BIND=127.0.0.1
    [[ -n "$new_proxy" ]] || die "Nginx 反代需指定 --webhook-proxy-domain="
    if [[ "$old_mode" = "nginx" && -n "$old_domain" && "$old_domain" != "$new_proxy" ]]; then
      WEBHOOK_PROXY_DOMAIN="$old_domain"
      _webhook_remove_nginx_proxy
    fi
    WEBHOOK_PROXY_DOMAIN="$new_proxy"
  else
    if [[ "$old_mode" = "nginx" && -n "$old_domain" ]]; then
      WEBHOOK_PROXY_DOMAIN="$old_domain"
      _webhook_remove_nginx_proxy
    fi
    WEBHOOK_PROXY_DOMAIN=""
    if [[ "$WEBHOOK_PUBLIC_MODE" = "local" ]]; then
      WEBHOOK_BIND=127.0.0.1
    fi
    [[ -n "$WEBHOOK_BIND" ]] || WEBHOOK_BIND=127.0.0.1
  fi

  _webhook_write_listener_env
  _webhook_write_systemd_unit "$script_path"

  if [[ "$WEBHOOK_PUBLIC_MODE" = "nginx" ]]; then
    _webhook_apply_nginx_proxy "$WEBHOOK_PROXY_DOMAIN"
  fi

  systemctl daemon-reload
  systemctl enable lnmp-deploy-webhook
  systemctl restart lnmp-deploy-webhook
  ok "Webhook 监听服务已安装"
  _webhook_load_listener_env
  info "本机监听: ${WEBHOOK_BIND}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
  info "回调 URL: $(_webhook_public_callback_url)"
  info "GitHub: 事件 release / 签名 X-Hub-Signature-256"
  info "Gitee:  事件 Release Hook / Push Hook(tag) / Header X-Gitee-Token=secret"
  [[ "$WEBHOOK_PUBLIC_MODE" = "bind" ]] && info "请确保防火墙/安全组已放行 ${WEBHOOK_PORT}/tcp"
}

cmd_webhook_serve() {
  local script_path="${SCRIPT_DIR}/deploy-site.sh"
  _webhook_run_python_server "$script_path"
}

cmd_webhook_handle() {
  [[ -n "$WEBHOOK_BODY_FILE" && -f "$WEBHOOK_BODY_FILE" ]] || die "缺少 --body-file"
  _webhook_process_payload "$WEBHOOK_BODY_FILE" "${WEBHOOK_EVENT:-}" "${WEBHOOK_GH_SIG:-}" "${WEBHOOK_GITEE_TOKEN:-}"
}

cmd_rollback() {
  prompt_pick_domain "选择要回退的站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"
  local hf entry backup_dir idx ver
  hf="$(_webhook_history_file "$DOMAIN")"
  [[ -f "$hf" ]] || die "无部署历史（${hf}）"

  echo ""
  hr; info "部署历史: ${DOMAIN}"; hr
  _webhook_list_history "$DOMAIN"
  echo ""

  if [[ -n "$ROLLBACK_TO" ]]; then
    if [[ "$ROLLBACK_TO" =~ ^[0-9]+$ ]]; then
      entry="$(_webhook_history_entry "$DOMAIN" "$ROLLBACK_TO")" || die "无效序号"
    else
      while IFS= read -r entry; do
        [[ "$entry" = *"|${ROLLBACK_TO}|"* || "$entry" = *"|${ROLLBACK_TO}" ]] && break
        entry=""
      done < "$hf"
      [[ -n "$entry" ]] || die "未找到版本: ${ROLLBACK_TO}"
    fi
  elif [[ "$ROLLBACK_INDEX" -gt 0 ]]; then
    entry="$(_webhook_history_entry "$DOMAIN" "$ROLLBACK_INDEX")" || die "无效序号"
  elif [[ "${YES:-0}" -ne 1 ]]; then
    idx=$(prompt "回退到序号（见上表）" "1")
    entry="$(_webhook_history_entry "$DOMAIN" "$idx")" || die "无效序号"
  else
    entry="$(_webhook_history_entry "$DOMAIN" "1")" || die "无历史记录"
  fi

  backup_dir="${entry##*|}"
  ver="${entry#*|}"; ver="${ver%%|*}"
  [[ "${YES:-0}" -eq 1 ]] || ! confirm "确认回退到 ${ver}？" "n" || { warn "已取消"; return 0; }

  hr; info "回退 ${DOMAIN} → ${ver}"; echo ""
  _webhook_restore_backup "$DOMAIN" "$backup_dir"
  ok "回退完成"
}
