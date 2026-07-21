# shellcheck shell=bash

_build_git_ssh_cmd() {
  local ssh_key="/home/${DEVOPS_USER}/.ssh/id_ed25519"
  [[ ! -f "$ssh_key" ]] && ssh_key="/home/${DEVOPS_USER}/.ssh/id_rsa"
  local cmd="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  [[ -f "$ssh_key" ]] && cmd="ssh -i ${ssh_key} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  printf '%s' "$cmd"
}

_git_fetch_checkout() {
  local site_dir="$1" ref="$2"
  local git_ssh
  git_ssh=$(_build_git_ssh_cmd)
  git config --global --replace-all safe.directory "${site_dir}" 2>/dev/null || true
  export GIT_SSH_COMMAND="$git_ssh"
  info "git fetch 并 checkout ${ref}..."
  su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; cd '${site_dir}' && git fetch --all --tags && git checkout '${ref}'" \
    || die "git fetch/checkout ${ref} 失败"
}

_git_pull_or_clone() {
  local site_dir="$1" git_repo="${2:-}" git_branch="${3:-}"
  local git_ssh
  git_ssh=$(_build_git_ssh_cmd)
  git config --global --replace-all safe.directory "${site_dir}" 2>/dev/null || true
  export GIT_SSH_COMMAND="$git_ssh"

  if [[ -d "${site_dir}/.git" ]]; then
    if [[ -n "$git_branch" ]]; then
      info "已有仓库，切换到分支 ${git_branch} 并拉取"
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; cd '${site_dir}' && git fetch origin && git checkout '${git_branch}' && git pull" \
        || die "git fetch/checkout/pull 失败，请检查分支名与 SSH Key"
    else
      info "已有仓库，执行 git pull"
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; cd '${site_dir}' && git pull" \
        || die "git pull 失败，请检查 SSH Key"
    fi
  elif [[ -n "$git_repo" ]]; then
    if [[ -n "$git_branch" ]]; then
      info "首次 clone（分支: ${git_branch}）..."
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; git clone -b '${git_branch}' --single-branch '${git_repo}' '${site_dir}'" \
        || die "git clone 失败，请检查分支名与 SSH Key"
    else
      info "首次 clone..."
      su - "${DEVOPS_USER}" -c "export GIT_SSH_COMMAND='${git_ssh}'; git clone '${git_repo}' '${site_dir}'" \
        || die "git clone 失败，请检查 SSH Key"
    fi
  else
    return 1
  fi
}

deploy_code() {
  local domain="$1" git_repo="$2" git_branch="${3:-}"
  local site_dir="${WWW_ROOT}/${domain}"

  chmod 755 /data 2>/dev/null || true
  local _dg
  _dg=$(id -gn "${DEVOPS_USER}" 2>/dev/null || echo "${DEVOPS_USER}")
  chown root:"${_dg}" "${DATA_DIR}" 2>/dev/null || true
  chmod 771 "${DATA_DIR}"
  mkdir -p "${WWW_ROOT}"
  chown "${DEVOPS_USER}:${DEVOPS_USER}" "${WWW_ROOT}"
  chmod a+rx "${WWW_ROOT}" 2>/dev/null || true

  if [[ -z "$git_repo" ]]; then
    mkdir -p "${site_dir}"
    info "Git 地址为空，已跳过 clone/pull；请确保代码已在 ${site_dir}"
  else
    _git_pull_or_clone "${site_dir}" "${git_repo}" "${git_branch}"
  fi

  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${site_dir}"
  local _dc_st="${SITE_TYPE:-}"
  if [[ -z "$_dc_st" ]]; then
    _dc_st="$(_site_type_for_domain "$domain")"
  fi
  local _dc_fe=""
  [[ "$_dc_st" = "frontend" ]] && _dc_fe=$(effective_frontend_subdir "$domain")
  if [[ "$_dc_st" != "pm2" ]]; then
    fix_site_readable_for_nginx "$domain" "$_dc_st" "$_dc_fe"
  fi
}

