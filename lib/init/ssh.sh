# shellcheck shell=bash
_ssh_build_allowusers_list() {
  local -a raw=() out=()
  [[ "${ROOT_LOGIN:-prohibit-password}" != "no" ]] && raw+=(root)
  [[ -n "${WHEEL_USER:-}" ]] && raw+=("$WHEEL_USER")
  [[ -n "${DEVOPS_USER:-}" ]] && raw+=("$DEVOPS_USER")
  [[ -n "${CYBER_ORDINARY:-}" ]] && raw+=("$CYBER_ORDINARY")
  [[ -n "${CYBER_AUDIT:-}" ]] && raw+=("$CYBER_AUDIT")
  [[ -n "${CYBER_SAFE:-}" ]] && raw+=("$CYBER_SAFE")
  local x y seen
  for x in "${raw[@]}"; do
    [[ -n "$x" ]] || continue
    seen=0
    for y in "${out[@]}"; do [[ "$y" = "$x" ]] && { seen=1; break; }; done
    [[ $seen -eq 0 ]] && out+=("$x")
  done
  echo "${out[*]}"
}

install_ssh() {
  hr; info "SSH 安全配置"; echo ""

  local sshd_conf="/etc/ssh/sshd_config"
  [[ -f "$sshd_conf" ]] || die "sshd_config 不存在"

  cp "$sshd_conf" "${sshd_conf}.bak.$(date +%s)" 2>/dev/null || true

  if [[ "$ROOT_LOGIN" = "no" ]]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$sshd_conf"
  else
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_conf"
  fi
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_conf"
  grep -q '^PasswordAuthentication' "$sshd_conf" 2>/dev/null \
    || echo "PasswordAuthentication no" >> "$sshd_conf"
  sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$sshd_conf"
  grep -q '^PubkeyAuthentication' "$sshd_conf" 2>/dev/null \
    || echo "PubkeyAuthentication yes" >> "$sshd_conf"

  sed -i '/^#*Port /d' "$sshd_conf"
  echo "Port ${SSH_PORT}" >> "$sshd_conf"

  sed -i '/^AllowUsers/d' "$sshd_conf"
  echo "AllowUsers $(_ssh_build_allowusers_list)" >> "$sshd_conf"

  if [[ "${SSH_PORT}" != "22" ]] && is_firewall_on; then
    firewall-cmd --permanent --add-port="${SSH_PORT}"/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi

  chmod 600 "$sshd_conf"
  systemctl restart sshd
  systemctl is-active sshd &>/dev/null || die "sshd 重启失败"
  ok "SSH 配置完成 (端口 ${SSH_PORT})"
}

uninstall_ssh() {
  hr; info "恢复 SSH 默认配置"; echo ""
  local sshd_conf="/etc/ssh/sshd_config"
  local latest_bak
  latest_bak=$(ls -t "${sshd_conf}".bak.* 2>/dev/null | head -1 || true)
  if [[ -n "$latest_bak" ]]; then
    cp "$latest_bak" "$sshd_conf"
    systemctl restart sshd
    ok "已恢复 SSH 备份配置"
  else
    warn "未找到备份，请手动恢复"
  fi
}

# $1 用户名；$2 模式 interactive（默认）| root（复制 root）| line；$3 line 模式下一行公钥
ensure_user_ssh_access() {
  local u="$1"
  local mode="${2:-interactive}"
  local key_line="${3:-}"
  local home
  home=$(getent passwd "$u" | cut -d: -f6 || true)
  [[ -n "$home" && -d "$home" ]] || { warn "跳过 ${u}：家目录无效"; return 0; }

  mkdir -p "${home}/.ssh"
  chmod 700 "${home}/.ssh"

  local ak="${home}/.ssh/authorized_keys"
  if [[ -s "$ak" ]]; then
    chown -R "${u}:${u}" "${home}/.ssh" 2>/dev/null || true
    return 0
  fi
  case " ${_SSH_ACCESS_ASKED:-} " in
    *" $u "*) return 0 ;;
  esac

  if [[ "$mode" = "root" ]]; then
    if [[ -s /root/.ssh/authorized_keys ]]; then
      cp /root/.ssh/authorized_keys "$ak" || true
    else
      warn "${u}：root 无 authorized_keys，无法复制"
    fi
  elif [[ "$mode" = "line" && -n "$key_line" ]]; then
    printf '%s\n' "$key_line" >> "$ak"
  elif [[ "$mode" = "skip" ]]; then
    _SSH_ACCESS_ASKED="${_SSH_ACCESS_ASKED:-} $u"
    chown -R "${u}:${u}" "${home}/.ssh" 2>/dev/null || true
    return 0
  else
    _SSH_ACCESS_ASKED="${_SSH_ACCESS_ASKED:-} $u"
    if [[ -s /root/.ssh/authorized_keys ]] && confirm "将 root 的 authorized_keys 复制到 ${u}？" "y"; then
      cp /root/.ssh/authorized_keys "$ak" || true
    fi
    if [[ ! -s "$ak" ]]; then
      local pk=""
      read -rp "  ${u} 的 SSH 公钥一行（留空须控制台手工写入 ~/.ssh/authorized_keys）: " pk </dev/tty
      [[ -n "$pk" ]] && printf '%s\n' "$pk" >> "$ak"
    fi
  fi

  if [[ -s "$ak" ]]; then
    chmod 600 "$ak" 2>/dev/null || true
    ok "${u} 已写入 authorized_keys"
  else
    warn "${u} 未配置 SSH 公钥；仅密钥登录时须从控制台登录后补充"
  fi
  chown -R "${u}:${u}" "${home}/.ssh" 2>/dev/null || true
}

collect_user_ssh_access_into() {
  local u="$1" modevar="$2" linevar="$3"
  local mode="skip" line="" home ak
  home=$(getent passwd "$u" | cut -d: -f6 || true)
  ak="${home}/.ssh/authorized_keys"
  if [[ -n "$home" && -s "$ak" ]]; then
    printf -v "$modevar" '%s' skip
    printf -v "$linevar" '%s' ""
    return 0
  fi
  if [[ -s /root/.ssh/authorized_keys ]] && confirm "将 root 的 authorized_keys 复制到 ${u}？" "y"; then
    mode="root"
  else
    local pk=""
    read -rp "  ${u} 的 SSH 公钥一行（留空须控制台手工写入 ~/.ssh/authorized_keys）: " pk </dev/tty
    printf '\n' >/dev/tty 2>/dev/null || true
    if [[ -n "$pk" ]]; then
      mode="line"
      line="$pk"
    else
      warn "${u} 未配置 SSH 公钥；仅密钥登录时须从控制台登录后补充"
    fi
  fi
  printf -v "$modevar" '%s' "$mode"
  printf -v "$linevar" '%s' "$line"
}

collect_account_password_into() {
  local u="$1" pwdvar="$2" skipvar="$3"
  if id "$u" &>/dev/null; then
    if confirm "${u} 已存在，是否修改密码？" "n"; then
      prompt_secret_confirm_into "新密码" "$pwdvar"
    else
      printf -v "$skipvar" '%s' 1
    fi
  else
    prompt_secret_confirm_into "${u} 密码" "$pwdvar"
  fi
}

# ═══════════════════════════════════════════════
#  用户管理
# ═══════════════════════════════════════════════
setup_devops_user() {
  hr; info "配置 devops 用户: ${DEVOPS_USER}"; echo ""
  [[ -n "${DEVOPS_USER:-}" ]] || { warn "DEVOPS_USER 为空"; return 0; }

  getent group devops >/dev/null 2>&1 || groupadd devops

  if ! id "${DEVOPS_USER}" &>/dev/null; then
    local pwd="${DEVOPS_PWD:-}"
    [[ -n "$pwd" ]] || prompt_secret_confirm_into "${DEVOPS_USER} 密码" pwd
    useradd -m -s /bin/bash "${DEVOPS_USER}" || die "创建用户失败"
    echo "${DEVOPS_USER}:${pwd}" | chpasswd || die "设置密码失败"
    chmod 700 /home/"${DEVOPS_USER}"
    ok "${DEVOPS_USER} 创建完成"
  else
    ok "${DEVOPS_USER} 已存在"
    if [[ -n "${DEVOPS_PWD:-}" ]]; then
      echo "${DEVOPS_USER}:${DEVOPS_PWD}" | chpasswd || die "设置密码失败"
      ok "${DEVOPS_USER} 密码已更新"
    fi
  fi

  usermod -aG devops "${DEVOPS_USER}" 2>/dev/null || true
  _account_maybe_docker_group "${DEVOPS_USER}"
  _ssh_allowusers_add_user "${DEVOPS_USER}"

  mkdir -p /usr/local/bin
  echo "%devops ALL=(ALL) NOPASSWD: /usr/local/bin/deploy-site.sh" \
    > /etc/sudoers.d/devops-deploy 2>/dev/null
  chmod 440 /etc/sudoers.d/devops-deploy 2>/dev/null || true

  ensure_user_ssh_access "${DEVOPS_USER}" "${DEVOPS_SSH_MODE:-interactive}" "${DEVOPS_SSH_LINE:-}"
}

setup_wheel_user() {
  hr; info "配置 wheel 管理员: ${WHEEL_USER}"; echo ""
  if [[ -z "$WHEEL_USER" ]]; then return 0; fi

  getent group wheel >/dev/null 2>&1 || groupadd wheel

  if ! id "${WHEEL_USER}" &>/dev/null; then
    local pwd="${WHEEL_PWD:-}"
    [[ -n "$pwd" ]] || prompt_secret_confirm_into "${WHEEL_USER} 密码" pwd
    useradd -m -s /bin/bash "${WHEEL_USER}" || die "创建用户 ${WHEEL_USER} 失败"
    echo "${WHEEL_USER}:${pwd}" | chpasswd || die "设置密码失败"
    ok "${WHEEL_USER} 创建完成"
  elif [[ -n "${WHEEL_PWD:-}" ]]; then
    echo "${WHEEL_USER}:${WHEEL_PWD}" | chpasswd || die "设置密码失败"
    ok "${WHEEL_USER} 密码已更新"
  elif [[ "${WHEEL_SKIP_PASSWD_PROMPT:-0}" != 1 ]] && confirm "${WHEEL_USER} 已存在，是否修改密码？" "n"; then
    local pwd
    prompt_secret_confirm_into "新密码" pwd
    echo "${WHEEL_USER}:${pwd}" | chpasswd || die "设置密码失败"
    ok "${WHEEL_USER} 密码已更新"
  fi

  usermod -aG wheel "${WHEEL_USER}" || die "添加 wheel 组失败"
  usermod -aG devops "${WHEEL_USER}" 2>/dev/null || true
  _account_maybe_docker_group "${WHEEL_USER}"
  _ssh_allowusers_add_user "${WHEEL_USER}"
  mkdir -p /home/"${WHEEL_USER}"/.ssh
  chmod 700 /home/"${WHEEL_USER}"/.ssh
  chown -R "${WHEEL_USER}:${WHEEL_USER}" /home/"${WHEEL_USER}"/.ssh

  ensure_user_ssh_access "${WHEEL_USER}" "${WHEEL_SSH_MODE:-interactive}" "${WHEEL_SSH_LINE:-}"
}

setup_cyber_users() {
  hr; info "等保加固 - 三权分立用户"; echo ""

  local -A roles=([ordinary]="普通用户" [audit]="审计员" [safe]="安全员")
  local -A defaults=([ordinary]="user" [audit]="audit" [safe]="safe")
  local -A vars=([ordinary]="CYBER_ORDINARY" [audit]="CYBER_AUDIT" [safe]="CYBER_SAFE")

  local cyber_ssh_mode="skip" cyber_ssh_line=""
  if confirm "为三权账户配置 SSH 公钥（禁用口令登录后远程必需）？" "y"; then
    if [[ -s /root/.ssh/authorized_keys ]] && confirm "各账户从 root 复制 authorized_keys？" "y"; then
      cyber_ssh_mode="root"
    else
      read -rp "  统一公钥一行（写入全部三权账户；留空则每个账户分别询问）: " cyber_ssh_line </dev/tty
      if [[ -n "$cyber_ssh_line" ]]; then
        cyber_ssh_mode="line"
      else
        cyber_ssh_mode="each"
      fi
    fi
  fi

  for role in ordinary audit safe; do
    local name
    prompt "${roles[$role]}用户名" "${defaults[$role]}"
    name=$PROMPT_RESULT
    name=$(echo -n "$name" | tr -cd '[:alnum:]_')
    if [[ -z "$name" ]]; then name="${defaults[$role]}"; fi
    [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,31}$ ]] || { warn "用户名无效: $name"; continue; }

    if id "$name" &>/dev/null; then
      info "${name} 已存在"
      if confirm "是否修改密码？" "n"; then
        local pw
        while true; do
          prompt_secret_confirm_into "新密码 (>=10位，大小写/数字/特殊符至少3类)" pw
          check_passwd_strength "$pw" && break
          warn "复杂度不足"
        done
        echo "${name}:${pw}" | chpasswd || die "设置密码失败"
        ok "${name} 密码已更新"
      fi
    else
      useradd "$name" -m -s /bin/bash 2>/dev/null || { warn "创建 ${name} 失败"; continue; }
      local pw
      while true; do
        prompt_secret_confirm_into "${name} 密码 (>=10位，大小写/数字/特殊符至少3类)" pw
        check_passwd_strength "$pw" && break
        warn "复杂度不足"
      done
      echo "${name}:${pw}" | chpasswd || die "设置密码失败"
      ok "${name} 创建完成"
    fi

    eval "${vars[$role]}='$name'"

    _ssh_allowusers_add_user "$name"

    if [[ "$cyber_ssh_mode" = "root" ]]; then
      ensure_user_ssh_access "$name" root
    elif [[ "$cyber_ssh_mode" = "line" ]]; then
      ensure_user_ssh_access "$name" line "$cyber_ssh_line"
    elif [[ "$cyber_ssh_mode" = "each" ]]; then
      ensure_user_ssh_access "$name"
    fi
  done

  if [[ "$cyber_ssh_mode" = "skip" ]]; then
    warn "三权账户未配置公钥；若 SSH 已仅允许密钥登录，请从控制台为各账号写入 authorized_keys"
  fi

  if [[ -n "${CYBER_ORDINARY:-}" ]]; then
    if confirm "将 ${CYBER_ORDINARY} 设为 devops 部署用户？" "y"; then
      DEVOPS_USER="$CYBER_ORDINARY"
      [[ "${1:-}" = "skip-devops" ]] || setup_devops_user
    fi
  fi

  chmod 750 /home/* 2>/dev/null || true
  chage --maxdays 90 root 2>/dev/null || true
  chage --mindays 7 root 2>/dev/null || true
  chmod 600 /etc/ssh/sshd_config 2>/dev/null || true
  touch "$CYBERSEC_MARKER"
  ok "等保加固完成"
}

