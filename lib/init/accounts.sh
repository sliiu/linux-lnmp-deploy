# shellcheck shell=bash
# ═══════════════════════════════════════════════
#  账户管理（增删改查 / 组 / 密码与 SSH 公钥 / AllowUsers）
# ═══════════════════════════════════════════════
_account_valid_login() {
  [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]]
}

_ssh_config_read_allowusers() {
  grep '^AllowUsers ' /etc/ssh/sshd_config 2>/dev/null | tail -1 | sed 's/^AllowUsers[[:space:]]\{1,\}//'
}

_ssh_config_set_allowusers_line() {
  local list="$1"
  local f="/etc/ssh/sshd_config"
  [[ -f "$f" ]] || { warn "无 /etc/ssh/sshd_config"; return 1; }
  sed -i '/^AllowUsers/d' "$f"
  echo "AllowUsers ${list}" >> "$f"
  systemctl try-reload-or-restart sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

_ssh_allowusers_add_user() {
  local u="$1" cur t
  cur="$(_ssh_config_read_allowusers)"
  if [[ -z "$cur" ]]; then
    warn "未找到 AllowUsers（可先执行 install ssh）；未自动加入 ${u}"
    return 0
  fi
  for t in $cur; do [[ "$t" = "$u" ]] && return 0; done
  _ssh_config_set_allowusers_line "${cur} ${u}"
  ok "AllowUsers 已加入 ${u}"
}

_ssh_allowusers_remove_user() {
  local u="$1" cur
  cur="$(_ssh_config_read_allowusers)"
  [[ -z "$cur" ]] && return 0
  read -ra arr <<< "$cur"
  local -a out=()
  local x
  for x in "${arr[@]}"; do [[ "$x" != "$u" ]] && out+=("$x"); done
  if ((${#out[@]} == 0)); then
    warn "AllowUsers 将无用户，已删除该行，请尽快「重建 AllowUsers」或 install ssh"
    sed -i '/^AllowUsers/d' /etc/ssh/sshd_config
    systemctl try-reload-or-restart sshd 2>/dev/null || true
    return 0
  fi
  _ssh_config_set_allowusers_line "${out[*]}"
  ok "AllowUsers 已移除 ${u}"
}

_account_user_home() {
  getent passwd "$1" | cut -d: -f6
}

_account_refuse_system_user() {
  local u="$1"
  [[ "$u" != "root" ]] || die "不允许操作 root"
  local uid
  uid=$(id -u "$u" 2>/dev/null) || die "用户不存在: $u"
  [[ "$uid" -ge 1000 ]] || die "仅允许操作 UID≥1000 的登录用户: $u"
}

account_user_list_display() {
  hr; info "登录用户 (UID≥1000)"; echo ""
  printf "  %-18s %6s  %s\n" "用户" "UID" "补充组"
  while IFS=: read -r name _ uid gid _ home shell; do
    [[ "$uid" -ge 1000 ]] || continue
    [[ "$name" = "nobody" ]] && continue
    local gs
    gs=$(id -Gn "$name" 2>/dev/null | tr ' ' ',')
    printf "  %-18s %6s  %s\n" "$name" "$uid" "$gs"
  done < <(getent passwd | sort -t: -k3 -n)
  echo ""
  info "环境变量: DEVOPS_USER=${DEVOPS_USER:-} WHEEL_USER=${WHEEL_USER:-}"
  [[ -n "${CYBER_ORDINARY:-}" ]] && info "CYBER_ORDINARY=${CYBER_ORDINARY}"
  [[ -n "${CYBER_AUDIT:-}" ]] && info "CYBER_AUDIT=${CYBER_AUDIT}"
  [[ -n "${CYBER_SAFE:-}" ]] && info "CYBER_SAFE=${CYBER_SAFE}"
  echo ""
}

account_groups_list_display() {
  hr; info "用户组 (GID≥100 或 wheel/devops)"; echo ""
  while IFS=: read -r gname _ gid members; do
    [[ "$gid" -ge 100 || "$gname" = "wheel" || "$gname" = "devops" ]] || continue
    printf "  %-24s gid=%-6s %s\n" "$gname" "$gid" "${members:-}"
  done < <(getent group | sort -t: -k3 -n)
  echo ""
}

account_allowusers_display() {
  hr; info "sshd AllowUsers"; echo ""
  local cur
  cur="$(_ssh_config_read_allowusers)"
  if [[ -z "$cur" ]]; then
    info "未配置（或 sshd_config 无 AllowUsers 行）"
  else
    printf "  %s\n" "$cur" | tr ' ' '\n' | sed 's/^/  /'
  fi
  echo ""
  info "按 lnmp-env 重建时将使用: $(_ssh_build_allowusers_list)"
  echo ""
}

account_allowusers_resync_from_conf() {
  local f="/etc/ssh/sshd_config"
  [[ -f "$f" ]] || die "无 sshd_config"
  if ! confirm "用当前配置中的 devops/wheel/等保用户重建 AllowUsers？（会覆盖现有 AllowUsers 列表）" "n"; then
    info "已取消"
    return 0
  fi
  _ssh_config_set_allowusers_line "$(_ssh_build_allowusers_list)"
  ok "AllowUsers 已按配置重建"
}

account_user_add_interactive() {
  hr; info "新建用户"; echo ""
  local name shell exg pwd
  prompt "登录名 (字母开头)"
  name=$PROMPT_RESULT
  _account_valid_login "$name" || die "登录名格式无效"
  id "$name" &>/dev/null && die "用户已存在"

  local _default_shell="/bin/bash"
  if is_zsh_ok 2>/dev/null; then
    for _z in /usr/bin/zsh /usr/local/bin/zsh /bin/zsh; do
      if [[ -x "$_z" ]]; then _default_shell="$_z"; break; fi
    done
  fi
  prompt "Shell" "$_default_shell"
  shell=$PROMPT_RESULT
  [[ -x "$shell" ]] || warn "Shell 可能不存在: ${shell}"

  prompt "附加组，逗号分隔（如 devops,wheel，留空无）" ""
  exg=$PROMPT_RESULT
  exg=$(echo -n "$exg" | tr -d ' ')

  prompt_secret_confirm_into "${name} 登录密码" pwd

  if [[ -n "$exg" ]]; then
    useradd -m -s "$shell" -G "$exg" "$name" || die "useradd 失败"
  else
    useradd -m -s "$shell" "$name" || die "useradd 失败"
  fi
  echo "${name}:${pwd}" | chpasswd || die "chpasswd 失败"
  chmod 750 "/home/${name}" 2>/dev/null || true
  mkdir -p "/home/${name}/.ssh"
  chmod 700 "/home/${name}/.ssh"
  chown -R "${name}:${name}" "/home/${name}/.ssh"
  ok "用户 ${name} 已创建"

  if confirm "配置 SSH 公钥？" "y"; then
    ensure_user_ssh_access "$name"
  fi
  if confirm "加入 sshd AllowUsers（若已启用 AllowUsers）？" "y"; then
    _ssh_allowusers_add_user "$name"
  fi
  if confirm "写入 /etc/lnmp-env.conf 为 DEVOPS_USER（仅当此为部署账号）？" "n"; then
    DEVOPS_USER="$name"
    conf_save
    ok "已更新 DEVOPS_USER=${name}"
  fi
}

account_user_delete_interactive() {
  hr; info "删除用户"; echo ""
  local name rh
  prompt "要删除的登录名"
  name=$PROMPT_RESULT
  id "$name" &>/dev/null || die "用户不存在"
  _account_refuse_system_user "$name"

  if ! confirm "确认删除用户 ${name}？" "n"; then info "已取消"; return 0; fi
  rh=0
  confirm "同时删除家目录？" "y" && rh=1

  _ssh_allowusers_remove_user "$name"
  if [[ $rh -eq 1 ]]; then
    userdel -r "$name" 2>/dev/null || userdel "$name" || die "userdel 失败"
  else
    userdel "$name" || die "userdel 失败"
  fi
  ok "已删除 ${name}"
  if [[ "$name" = "${DEVOPS_USER:-}" ]] || [[ "$name" = "${WHEEL_USER:-}" ]] \
    || [[ "$name" = "${CYBER_ORDINARY:-}" || "$name" = "${CYBER_AUDIT:-}" || "$name" = "${CYBER_SAFE:-}" ]]; then
    warn "该用户曾出现在 lnmp-env 配置中，请执行「重建 AllowUsers」或编辑 /etc/lnmp-env.conf 后 conf_save"
  fi
}

account_user_passwd_interactive() {
  hr; info "修改密码"; echo ""
  local name pwd
  prompt "登录名"
  name=$PROMPT_RESULT
  id "$name" &>/dev/null || die "用户不存在"
  _account_refuse_system_user "$name"
  prompt_secret_confirm_into "${name} 新密码" pwd
  echo "${name}:${pwd}" | chpasswd || die "chpasswd 失败"
  ok "密码已更新"
}

account_group_add_interactive() {
  hr; info "新建用户组"; echo ""
  local g
  prompt "组名"
  g=$PROMPT_RESULT
  [[ "$g" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]] || die "组名无效"
  getent group "$g" &>/dev/null && die "组已存在"
  groupadd "$g" || die "groupadd 失败"
  ok "组 ${g} 已创建"
}

account_group_delete_interactive() {
  hr; info "删除用户组"; echo ""
  local g
  prompt "组名"
  g=$PROMPT_RESULT
  getent group "$g" &>/dev/null || die "组不存在"
  [[ "$g" = "root" || "$g" = "wheel" || "$g" = "devops" ]] && die "拒绝删除系统关键组"
  if ! confirm "确认删除组 ${g}？" "n"; then return 0; fi
  groupdel "$g" || die "groupdel 失败（可能仍有成员或为主组）"
  ok "已删除组 ${g}"
}

account_user_addgroup_interactive() {
  hr; info "将用户加入组"; echo ""
  local u g
  prompt "用户名"
  u=$PROMPT_RESULT
  prompt "组名"
  g=$PROMPT_RESULT
  id "$u" &>/dev/null || die "用户不存在"
  getent group "$g" &>/dev/null || die "组不存在"
  usermod -aG "$g" "$u" || die "usermod 失败"
  ok "${u} 已加入 ${g}"
}

account_user_delgroup_interactive() {
  hr; info "将用户移出组"; echo ""
  local u g
  prompt "用户名"
  u=$PROMPT_RESULT
  prompt "组名"
  g=$PROMPT_RESULT
  id "$u" &>/dev/null || die "用户不存在"
  getent group "$g" &>/dev/null || die "组不存在"
  gpasswd -d "$u" "$g" &>/dev/null || { warn "gpasswd 失败（可能不是附加组成员）"; return 1; }
  ok "${u} 已从 ${g} 移除"
}

_user_ssh_append_pubkey_line() {
  local u="$1"
  local line="$2"
  local home ak
  home="$(_account_user_home "$u")"
  [[ -n "$home" && -d "$home" ]] || die "无效用户或家目录"
  [[ -n "$line" ]] || die "公钥为空"
  mkdir -p "${home}/.ssh"
  chmod 700 "${home}/.ssh"
  ak="${home}/.ssh/authorized_keys"
  touch "$ak" 2>/dev/null || true
  if grep -qFx "$line" "$ak" 2>/dev/null; then
    info "authorized_keys 中已存在相同行"
  else
    printf '%s\n' "$line" >> "$ak"
    ok "已追加公钥"
  fi
  chmod 600 "$ak" 2>/dev/null || true
  chown -R "${u}:${u}" "${home}/.ssh" 2>/dev/null || true
}

account_sshkey_menu_interactive() {
  hr; info "SSH 公钥管理"; echo ""
  local name
  prompt "目标用户名"
  name=$PROMPT_RESULT
  id "$name" &>/dev/null || die "用户不存在"
  local home ak
  home="$(_account_user_home "$name")"
  ak="${home}/.ssh/authorized_keys"

  local act
  menu_select "操作" "查看 authorized_keys" "追加一行公钥" "用 root 的 authorized_keys 覆盖" "清空 authorized_keys" "返回"
  act=$MENU_SELECT_RESULT
  case "$act" in
    0)
      if [[ -s "$ak" ]]; then nl -ba "$ak"; else info "(空)"; fi
      ;;
    1)
      local pk fp
      prompt "或公钥文件路径（留空则手动粘贴）" ""
      fp=$PROMPT_RESULT
      if [[ -n "$fp" && -f "$fp" ]]; then
        while IFS= read -r pk || [[ -n "$pk" ]]; do
          [[ -z "$pk" || "$pk" =~ ^# ]] && continue
          _user_ssh_append_pubkey_line "$name" "$pk"
        done < "$fp"
      else
        read -rp "  粘贴公钥整行: " pk </dev/tty
        _user_ssh_append_pubkey_line "$name" "$pk"
      fi
      ;;
    2)
      [[ -s /root/.ssh/authorized_keys ]] || die "root 无 authorized_keys"
      confirm "覆盖 ${name} 的 authorized_keys？" "n" || return 0
      mkdir -p "${home}/.ssh"
      chmod 700 "${home}/.ssh"
      cp /root/.ssh/authorized_keys "$ak"
      chmod 600 "$ak"
      chown -R "${name}:${name}" "${home}/.ssh"
      ok "已覆盖"
      ;;
    3)
      confirm "清空 ${name} 的 authorized_keys？" "n" || return 0
      : >"$ak"
      chmod 600 "$ak" 2>/dev/null || true
      chown "${name}:${name}" "$ak" 2>/dev/null || true
      ok "已清空"
      ;;
    *) return 0 ;;
  esac
}

_interactive_account_mgmt() {
  while true; do
    local _i
    menu_select "账户管理" \
      "用户列表" \
      "新建用户" \
      "修改密码" \
      "SSH 公钥（查看/追加/覆盖/清空）" \
      "查看 AllowUsers" \
      "按 lnmp-env 重建 AllowUsers" \
      "用户组列表" \
      "新建用户组" \
      "用户加入组" \
      "用户移出组" \
      "删除用户" \
      "删除用户组" \
      "返回主菜单"
    _i=$MENU_SELECT_RESULT
    case "$_i" in
      0)  account_user_list_display ;;
      1)  account_user_add_interactive ;;
      2)  account_user_passwd_interactive ;;
      3)  account_sshkey_menu_interactive ;;
      4)  account_allowusers_display ;;
      5)  account_allowusers_resync_from_conf ;;
      6)  account_groups_list_display ;;
      7)  account_group_add_interactive ;;
      8)  account_user_addgroup_interactive ;;
      9)  account_user_delgroup_interactive ;;
      10) account_user_delete_interactive ;;
      11) account_group_delete_interactive ;;
      12) return 0 ;;
    esac
  done
}

cmd_account_cli() {
  local sub="${1:-help}"
  shift 2>/dev/null || true
  case "$sub" in
    list|users)   account_user_list_display ;;
    groups)       account_groups_list_display ;;
    allowusers)   account_allowusers_display ;;
    resync-allow) account_allowusers_resync_from_conf ;;
    help|-h|--help)
      cat <<'AEOF'
  account users|list     列出 UID≥1000 用户及组
  account groups         列出用户组
  account allowusers     查看 AllowUsers 与配置预览
  account resync-allow   按 lnmp-env 重建 AllowUsers（覆盖）
其他操作请使用交互模式：init.sh → 账户管理
AEOF
      ;;
    *) die "未知 account 子命令: $sub（account help）" ;;
  esac
}

