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
  [[ "$SITE_TYPE" = "frontend" ]] && fe="${FRONTEND_ROOT:-}"
  sec="$(_webhook_write_site_config "$DOMAIN" "$mode" "$GIT_REPO" "${WEBHOOK_RELEASE_NAME:-}" "${WEBHOOK_SECRET:-}" "$fe")"
  ok "Webhook 已配置（mode=${mode}）"
  info "  回调 URL: http://<服务器>:$(_webhook_load_listener_env; echo "${WEBHOOK_BIND}:${WEBHOOK_PORT}${WEBHOOK_PATH}")"
  info "  Secret: ${sec}（写入 $(site_webhook_file "$DOMAIN")）"
  info "  执行 webhook setup 安装 systemd 监听服务"
}

cmd_webhook() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    enable)  shift; parse_args "$@"; cmd_webhook_enable ;;
    disable) shift; parse_args "$@"; cmd_webhook_disable ;;
    setup)   cmd_webhook_setup ;;
    serve)   cmd_webhook_serve ;;
    handle)  shift; parse_args "$@"; cmd_webhook_handle ;;
    list)    shift; parse_args "$@"; cmd_webhook_list ;;
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
  local site_dir="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$site_dir" ]] || die "站点不存在"

  local st="laravel"
  [[ -f "${site_dir}/artisan" ]] || st="frontend"

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
    GIT_REPO="${remote:-$(prompt "Git 仓库地址")}"
  }
  [[ -n "$GIT_REPO" ]] || die "Git 仓库地址不能为空"

  if [[ "$WEBHOOK_MODE" = "release" && -z "$WEBHOOK_RELEASE_NAME" ]]; then
    WEBHOOK_RELEASE_NAME=$(prompt "Release 名称（与 GitHub/Gitee Release name 或 tag 匹配）")
  fi

  local fe=""
  [[ "$st" = "frontend" ]] && fe="${FRONTEND_ROOT:-$(effective_frontend_subdir "$DOMAIN")}"
  local sec
  sec="$(_webhook_write_site_config "$DOMAIN" "$WEBHOOK_MODE" "$GIT_REPO" "${WEBHOOK_RELEASE_NAME:-}" "${WEBHOOK_SECRET:-}" "$fe")"
  ok "Webhook 已启用: ${DOMAIN} (${WEBHOOK_MODE})"
  info "Secret: ${sec}"
  info "请执行: $0 webhook setup"
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
  info "监听: ${WEBHOOK_BIND}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
  systemctl is-active lnmp-deploy-webhook &>/dev/null && ok "systemd: lnmp-deploy-webhook 运行中" \
    || warn "systemd: lnmp-deploy-webhook 未运行（执行 webhook setup）"
  echo ""
}

cmd_webhook_setup() {
  local script_path
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy-site.sh"
  [[ -x "$script_path" ]] || script_path="${SCRIPT_DIR}/deploy-site.sh"
  _webhook_write_listener_env
  _webhook_write_systemd_unit "$script_path"
  systemctl daemon-reload
  systemctl enable lnmp-deploy-webhook
  systemctl restart lnmp-deploy-webhook
  ok "Webhook 监听服务已安装"
  _webhook_load_listener_env
  info "POST ${WEBHOOK_BIND}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
  info "GitHub: 事件 release / 签名 X-Hub-Signature-256"
  info "Gitee:  事件 Release Hook / Push Hook(tag) / Header X-Gitee-Token=secret"
  info "公网访问请在 nginx/firewall 反代或放行端口"
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
