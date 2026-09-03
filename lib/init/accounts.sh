# shellcheck shell=bash
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
  [[ -n "$cur" ]] || return 0
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

_account_maybe_docker_group() {
  local u="$1"
  getent group docker >/dev/null 2>&1 || return 0
  id "$u" &>/dev/null || return 0
  usermod -aG docker "$u" 2>/dev/null || true
}

_account_refuse_system_user() {
  local u="$1" uid
  if [[ "$u" = "root" ]]; then warn "不允许操作 root"; return 1; fi
  uid=$(id -u "$u" 2>/dev/null) || { warn "用户不存在: $u"; return 1; }
  if [[ "$uid" -lt 1000 ]]; then warn "仅允许操作 UID≥1000 的登录用户: $u"; return 1; fi
  return 0
}

_account_list_login_users() {
  while IFS=: read -r name _ uid _; do
    [[ "$uid" -ge 1000 ]] || continue
    [[ "$name" = "nobody" ]] && continue
    printf '%s\n' "$name"
  done < <(getent passwd | sort -t: -k3 -n)
}

_account_list_groups() {
  while IFS=: read -r gname _ gid _; do
    [[ "$gid" -ge 100 || "$gname" = "wheel" || "$gname" = "devops" ]] || continue
    printf '%s\n' "$gname"
  done < <(getent group | sort -t: -k3 -n)
}

prompt_pick_login_user() {
  local title="${1:-选择用户}"
  local -a users=()
  ACCOUNT_PICK_RESULT=""
  while IFS= read -r u; do [[ -n "$u" ]] && users+=("$u"); done < <(_account_list_login_users)
  if [[ ${#users[@]} -eq 0 ]]; then
    warn "无登录用户（UID≥1000）"
    return 1
  fi
  local _items=("${users[@]}" "手动输入...")
  local _i
  menu_select "$title" "${_items[@]}"
  _i=$MENU_SELECT_RESULT
  if [[ "$_i" -lt ${#users[@]} ]]; then
    ACCOUNT_PICK_RESULT="${users[$_i]}"
  else
    prompt "登录名"
    ACCOUNT_PICK_RESULT=$PROMPT_RESULT
  fi
  [[ -n "$ACCOUNT_PICK_RESULT" ]] || return 1
}

prompt_pick_group() {
  local title="${1:-选择用户组}"
  local -a gs=()
  ACCOUNT_PICK_RESULT=""
  while IFS= read -r g; do [[ -n "$g" ]] && gs+=("$g"); done < <(_account_list_groups)
  if [[ ${#gs[@]} -eq 0 ]]; then
    warn "无可用用户组"
    return 1
  fi
  local _items=("${gs[@]}" "手动输入...")
  local _i
  menu_select "$title" "${_items[@]}"
  _i=$MENU_SELECT_RESULT
  if [[ "$_i" -lt ${#gs[@]} ]]; then
    ACCOUNT_PICK_RESULT="${gs[$_i]}"
  else
    prompt "组名"
    ACCOUNT_PICK_RESULT=$PROMPT_RESULT
  fi
  [[ -n "$ACCOUNT_PICK_RESULT" ]] || return 1
}

_account_clear_role_if_match() {
  local name="$1"
  local changed=0
  if [[ "$name" = "${DEVOPS_USER:-}" ]]; then DEVOPS_USER=""; changed=1; fi
  if [[ "$name" = "${WHEEL_USER:-}" ]]; then WHEEL_USER=""; changed=1; fi
  if [[ "$name" = "${CYBER_ORDINARY:-}" ]]; then CYBER_ORDINARY=""; changed=1; fi
  if [[ "$name" = "${CYBER_AUDIT:-}" ]]; then CYBER_AUDIT=""; changed=1; fi
  if [[ "$name" = "${CYBER_SAFE:-}" ]]; then CYBER_SAFE=""; changed=1; fi
  [[ "$changed" -eq 1 ]] && conf_save
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
  if [[ ! -f "$f" ]]; then warn "无 sshd_config"; return 0; fi
  if ! confirm "用当前配置中的 devops/wheel/等保用户重建 AllowUsers？（会覆盖现有 AllowUsers 列表）" "n"; then
    info "已取消"
    return 0
  fi
  _ssh_config_set_allowusers_line "$(_ssh_build_allowusers_list)"
  ok "AllowUsers 已按配置重建"
}

account_user_add_interactive() {
  hr; info "新建用户"; echo ""
  local name shell pwd
  while true; do
    prompt "登录名 (字母开头，留空取消)"
    name=$PROMPT_RESULT
    [[ -z "$name" ]] && return 0
    _account_valid_login "$name" || { warn "登录名格式无效"; continue; }
    id "$name" &>/dev/null && { warn "用户已存在"; continue; }
    break
  done

  local _default_shell="/bin/bash"
  if is_zsh_ok 2>/dev/null; then
    for _z in /usr/bin/zsh /usr/local/bin/zsh /bin/zsh; do
      if [[ -x "$_z" ]]; then _default_shell="$_z"; break; fi
    done
  fi
  shell="$_default_shell"

  prompt_secret_confirm_into "${name} 登录密码" pwd

  useradd -m -s "$shell" "$name" || { warn "useradd 失败"; return 0; }
  echo "${name}:${pwd}" | chpasswd || { warn "chpasswd 失败"; return 0; }
  chmod 750 "/home/${name}" 2>/dev/null || true
  mkdir -p "/home/${name}/.ssh"
  chmod 700 "/home/${name}/.ssh"
  chown -R "${name}:${name}" "/home/${name}/.ssh"
  ok "用户 ${name} 已创建"

  _ssh_allowusers_add_user "$name"
  if confirm "配置 SSH 公钥？" "y"; then
    ensure_user_ssh_access "$name"
  fi
}

account_user_delete_interactive() {
  hr; info "删除用户"; echo ""
  prompt_pick_login_user "选择要删除的用户" || return 0
  local name="$ACCOUNT_PICK_RESULT" rh
  _account_refuse_system_user "$name" || return 0

  if [[ "$name" = "${DEVOPS_USER:-}" || "$name" = "${WHEEL_USER:-}" \
    || "$name" = "${CYBER_ORDINARY:-}" || "$name" = "${CYBER_AUDIT:-}" || "$name" = "${CYBER_SAFE:-}" ]]; then
    warn "这是配置中的角色账户（devops/wheel/等保），删除会影响部署与 SSH"
    confirm "仍要删除 ${name}？" "n" || return 0
  else
    confirm "确认删除用户 ${name}？" "n" || { info "已取消"; return 0; }
  fi
  rh=0
  confirm "同时删除家目录？" "y" && rh=1

  _ssh_allowusers_remove_user "$name"
  if [[ $rh -eq 1 ]]; then
    userdel -r "$name" 2>/dev/null || userdel "$name" || { warn "userdel 失败"; return 0; }
  else
    userdel "$name" || { warn "userdel 失败"; return 0; }
  fi
  ok "已删除 ${name}"
  _account_clear_role_if_match "$name"
}

account_user_passwd_interactive() {
  hr; info "修改密码"; echo ""
  prompt_pick_login_user "选择用户" || return 0
  local name="$ACCOUNT_PICK_RESULT" pwd
  _account_refuse_system_user "$name" || return 0
  prompt_secret_confirm_into "${name} 新密码" pwd
  echo "${name}:${pwd}" | chpasswd || { warn "chpasswd 失败"; return 0; }
  ok "密码已更新"
}

account_group_add_interactive() {
  hr; info "新建用户组"; echo ""
  local g
  prompt "组名（留空取消）"
  g=$PROMPT_RESULT
  [[ -z "$g" ]] && return 0
  [[ "$g" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]] || { warn "组名无效"; return 0; }
  getent group "$g" &>/dev/null && { warn "组已存在"; return 0; }
  groupadd "$g" || { warn "groupadd 失败"; return 0; }
  ok "组 ${g} 已创建"
}

account_group_delete_interactive() {
  hr; info "删除用户组"; echo ""
  prompt_pick_group "选择要删除的组" || return 0
  local g="$ACCOUNT_PICK_RESULT"
  getent group "$g" &>/dev/null || { warn "组不存在"; return 0; }
  [[ "$g" = "root" || "$g" = "wheel" || "$g" = "devops" ]] && { warn "拒绝删除系统关键组"; return 0; }
  confirm "确认删除组 ${g}？" "n" || return 0
  groupdel "$g" || { warn "groupdel 失败（可能仍有成员或为主组）"; return 0; }
  ok "已删除组 ${g}"
}

account_user_addgroup_interactive() {
  hr; info "将用户加入组"; echo ""
  prompt_pick_login_user "选择用户" || return 0
  local u="$ACCOUNT_PICK_RESULT" g
  prompt_pick_group "选择组" || return 0
  g=$ACCOUNT_PICK_RESULT
  id "$u" &>/dev/null || { warn "用户不存在"; return 0; }
  getent group "$g" &>/dev/null || { warn "组不存在"; return 0; }
  usermod -aG "$g" "$u" || { warn "usermod 失败"; return 0; }
  ok "${u} 已加入 ${g}"
}

account_user_delgroup_interactive() {
  hr; info "将用户移出组"; echo ""
  prompt_pick_login_user "选择用户" || return 0
  local u="$ACCOUNT_PICK_RESULT" g
  prompt_pick_group "选择组" || return 0
  g=$ACCOUNT_PICK_RESULT
  id "$u" &>/dev/null || { warn "用户不存在"; return 0; }
  getent group "$g" &>/dev/null || { warn "组不存在"; return 0; }
  gpasswd -d "$u" "$g" &>/dev/null || { warn "gpasswd 失败（可能不是附加组成员）"; return 0; }
  ok "${u} 已从 ${g} 移除"
}

_user_ssh_append_pubkey_line() {
  local u="$1"
  local line="$2"
  local home ak
  home="$(_account_user_home "$u")"
  [[ -n "$home" && -d "$home" ]] || { warn "无效用户或家目录"; return 0; }
  [[ -n "$line" ]] || { warn "公钥为空"; return 0; }
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
  prompt_pick_login_user "选择用户" || return 0
  local name="$ACCOUNT_PICK_RESULT"
  _account_refuse_system_user "$name" || return 0
  local home ak
  home="$(_account_user_home "$name")"
  ak="${home}/.ssh/authorized_keys"

  while true; do
    local act
    menu_select "SSH 公钥: ${name}" \
      "查看 authorized_keys" \
      "追加一行公钥" \
      "用 root 的 authorized_keys 覆盖" \
      "清空 authorized_keys" \
      "返回"
    act=$MENU_SELECT_RESULT
    case "$act" in
      0)
        if [[ -s "$ak" ]]; then nl -ba "$ak"; else info "(空)"; fi
        ;;
      1)
        local pk fp
        prompt "公钥文件路径（留空则手动粘贴）" ""
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
        [[ -s /root/.ssh/authorized_keys ]] || { warn "root 无 authorized_keys"; continue; }
        confirm "覆盖 ${name} 的 authorized_keys？" "n" || continue
        mkdir -p "${home}/.ssh"
        chmod 700 "${home}/.ssh"
        cp /root/.ssh/authorized_keys "$ak"
        chmod 600 "$ak"
        chown -R "${name}:${name}" "${home}/.ssh"
        ok "已覆盖"
        ;;
      3)
        confirm "清空 ${name} 的 authorized_keys？" "n" || continue
        : >"$ak"
        chmod 600 "$ak" 2>/dev/null || true
        chown "${name}:${name}" "$ak" 2>/dev/null || true
        ok "已清空"
        ;;
      *) return 0 ;;
    esac
    echo ""
  done
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
    echo ""
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
    echo ""
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
