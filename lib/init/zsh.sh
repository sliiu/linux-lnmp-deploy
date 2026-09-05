# shellcheck shell=bash
install_zsh() {
  hr; info "安装 Oh-My-Zsh"; echo ""
  run_pkg install -y zsh

  local gh_url="${GH_PROXY:+${GH_PROXY}/}https://github.com"
  /bin/rm -rf /usr/local/share/ohmyzsh
  local -a _omz_repos=(
    "ohmyzsh/ohmyzsh|/usr/local/share/ohmyzsh"
    "zsh-users/zsh-autosuggestions|/usr/local/share/ohmyzsh/plugins/zsh-autosuggestions"
    "zsh-users/zsh-syntax-highlighting|/usr/local/share/ohmyzsh/plugins/zsh-syntax-highlighting"
    "romkatv/powerlevel10k|/usr/local/share/ohmyzsh/themes/powerlevel10k"
  )
  local _entry _repo _dir
  for _entry in "${_omz_repos[@]}"; do
    _repo="${_entry%%|*}"; _dir="${_entry#*|}"
    _git_clone_retry "${gh_url}/${_repo}.git" "$_dir" \
      || die "clone ${_repo##*/} 失败（可重试或在向导中选择 GitHub 代理）"
  done

  mv /etc/zshrc /etc/zshrc.bak 2>/dev/null || true

  cat > /etc/zshrc <<'ZEOF'
export ZSH="/usr/local/share/ohmyzsh"
export ZSH_DISABLE_COMPFIX="true"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
ZSH_THEME="powerlevel10k/powerlevel10k"
source $ZSH/oh-my-zsh.sh
[[ -f /etc/p10k.zsh ]] && source /etc/p10k.zsh
alias ll="ls -l"
alias la="ls -la"
# >>> saferm init.sh >>>
[ -f /etc/profile.d/saferm-rm.sh ] && . /etc/profile.d/saferm-rm.sh
# <<< saferm init.sh <<<
ZEOF

  cat > /etc/zshenv <<'ZEOF'
zsh-newuser-install() { return 0 }
ZEOF
  if declare -F is_fnm_ok &>/dev/null && is_fnm_ok && declare -F _node_shell_block &>/dev/null; then
    {
      printf '\n'
      _node_shell_block zsh
    } >> /etc/zshenv
  fi

  _write_p10k_config

  chmod 755 /usr/local /usr/local/share 2>/dev/null || true
  chown -R root:root /usr/local/share/ohmyzsh
  chmod -R 755 /usr/local/share/ohmyzsh
  chmod 644 /etc/zshrc /etc/zshenv /etc/p10k.zsh

  local zsh_bin=""
  for z in /usr/bin/zsh /usr/local/bin/zsh /bin/zsh; do
    if [[ -x "$z" ]]; then zsh_bin="$z"; break; fi
  done
  if [[ -n "$zsh_bin" ]]; then
    grep -qxF "$zsh_bin" /etc/shells 2>/dev/null || echo "$zsh_bin" >> /etc/shells
    _install_zsh_bash_fallback "$zsh_bin"
    for u in root "${WHEEL_USER:-}" "${DEVOPS_USER:-}" "${CYBER_ORDINARY:-}" "${CYBER_AUDIT:-}" "${CYBER_SAFE:-}"; do
      if [[ -n "$u" ]] && id "$u" &>/dev/null; then
        usermod -s "$zsh_bin" "$u" 2>/dev/null || chsh -s "$zsh_bin" "$u" 2>/dev/null || true
      fi
    done
  fi
  ok "Oh-My-Zsh 已安装"
}

# 交互式 bash 自动切到 zsh：覆盖 su/sudo 未走 login shell、安装后当前会话仍为 bash 等情况
_install_zsh_bash_fallback() {
  local zsh_bin="$1"
  mkdir -p /etc/profile.d
  cat > /etc/profile.d/lnmp-zsh.sh <<ZEOF
# >>> lnmp-zsh init.sh >>>
# 交互式 bash 自动 exec zsh（Oh-My-Zsh 已安装时）
if [ -n "\${BASH_VERSION:-}" ] && [ -z "\${ZSH_VERSION:-}" ] \
   && [ -z "\${LNMP_ZSH_EXEC:-}" ] \
   && [ -z "\${BASH_EXECUTION_STRING:-}" ] \
   && [[ \$- == *i* ]] \
   && [ -d /usr/local/share/ohmyzsh ] \
   && [ -x "${zsh_bin}" ]; then
  export LNMP_ZSH_EXEC=1
  export SHELL=${zsh_bin}
  exec ${zsh_bin}
fi
# <<< lnmp-zsh init.sh <<<
ZEOF
  chmod 644 /etc/profile.d/lnmp-zsh.sh
}

_write_p10k_config() {
  cat > /etc/p10k.zsh <<'PEOF'
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'
  [[ $ZSH_VERSION == (5.<1->*|<6->.*) ]] || return

  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir vcs newline prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status command_execution_time background_jobs direnv asdf virtualenv anaconda pyenv goenv nodenv nvm nodeenv rbenv rvm fvm luaenv jenv plenv perlbrew phpenv scalaenv haskell_stack kubecontext terraform aws aws_eb_env azure gcloud google_app_cred toolbox context nordvpn ranger yazi nnn lf xplr vim_shell midnight_commander nix_shell chezmoi_shell todo timewarrior taskwarrior per_directory_history newline)

  typeset -g POWERLEVEL9K_MODE=ascii
  typeset -g POWERLEVEL9K_ICON_PADDING=none
  typeset -g POWERLEVEL9K_BACKGROUND=
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_{LEFT,RIGHT}_WHITESPACE=
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SUBSEGMENT_SEPARATOR=' '
  typeset -g POWERLEVEL9K_{LEFT,RIGHT}_SEGMENT_SEPARATOR=
  typeset -g POWERLEVEL9K_ICON_BEFORE_CONTENT=true
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=76
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=196
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='>'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='<'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIVIS_CONTENT_EXPANSION='V'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIOWR_CONTENT_EXPANSION='^'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OVERWRITE_STATE=true

  typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_unique
  typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=103
  typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=39
  typeset -g POWERLEVEL9K_DIR_ANCHOR_BOLD=true
  typeset -g POWERLEVEL9K_SHORTEN_FOLDER_MARKER='(.bzr|.citc|.git|.hg|.node-version|.python-version|.go-version|.ruby-version|.lua-version|.java-version|.perl-version|.php-version|.tool-versions|.mise.toml|.shorten_folder_marker|.svn|.terraform|CVS|Cargo.toml|composer.json|go.mod|package.json|stack.yaml)'
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=1
  typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS=40
  typeset -g POWERLEVEL9K_DIR_MIN_COMMAND_COLUMNS_PCT=50
  typeset -g POWERLEVEL9K_DIR_SHOW_WRITABLE=v3

  typeset -g POWERLEVEL9K_VCS_BRANCH_ICON=
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_ICON='?'

  function my_git_formatter() {
    emulate -L zsh
    [[ -n $P9K_CONTENT ]] && { typeset -g my_git_format=$P9K_CONTENT; return }
    local meta clean modified untracked conflicted
    if (( $1 )); then
      meta='%f' clean='%76F' modified='%178F' untracked='%39F' conflicted='%196F'
    else
      meta='%244F' clean='%244F' modified='%244F' untracked='%244F' conflicted='%196F'
    fi
    local res branch tag
    [[ -n $VCS_STATUS_LOCAL_BRANCH ]] && {
      branch=${(V)VCS_STATUS_LOCAL_BRANCH}
      (( $#branch > 32 )) && branch[13,-13]=".."
      res+=${clean}${branch//\%/%%}
    }
    [[ -n $VCS_STATUS_TAG && -z $VCS_STATUS_LOCAL_BRANCH ]] && {
      tag=${(V)VCS_STATUS_TAG}
      (( $#tag > 32 )) && tag[13,-13]=".."
      res+=${meta}#${clean}${tag//\%/%%}
    }
    [[ -z $VCS_STATUS_LOCAL_BRANCH && -z $VCS_STATUS_TAG ]] && res+=${meta}@${clean}${VCS_STATUS_COMMIT[1,8]}
    [[ -n ${VCS_STATUS_REMOTE_BRANCH:#$VCS_STATUS_LOCAL_BRANCH} ]] && res+=${meta}:${clean}${(V)VCS_STATUS_REMOTE_BRANCH//\%/%%}
    [[ $VCS_STATUS_COMMIT_SUMMARY == (|*[^[:alnum:]])(wip|WIP)(|[^[:alnum:]]*) ]] && res+=" ${modified}wip"
    (( VCS_STATUS_COMMITS_BEHIND )) && res+=" ${clean}<${VCS_STATUS_COMMITS_BEHIND}"
    (( VCS_STATUS_COMMITS_AHEAD )) && res+="${clean}>${VCS_STATUS_COMMITS_AHEAD}"
    (( VCS_STATUS_PUSH_COMMITS_BEHIND )) && res+=" ${clean}<-${VCS_STATUS_PUSH_COMMITS_BEHIND}"
    (( VCS_STATUS_PUSH_COMMITS_AHEAD )) && res+="${clean}->${VCS_STATUS_PUSH_COMMITS_AHEAD}"
    (( VCS_STATUS_STASHES )) && res+=" ${clean}*${VCS_STATUS_STASHES}"
    [[ -n $VCS_STATUS_ACTION ]] && res+=" ${conflicted}${VCS_STATUS_ACTION}"
    (( VCS_STATUS_NUM_CONFLICTED )) && res+=" ${conflicted}~${VCS_STATUS_NUM_CONFLICTED}"
    (( VCS_STATUS_NUM_STAGED )) && res+=" ${modified}+${VCS_STATUS_NUM_STAGED}"
    (( VCS_STATUS_NUM_UNSTAGED )) && res+=" ${modified}!${VCS_STATUS_NUM_UNSTAGED}"
    (( VCS_STATUS_NUM_UNTRACKED )) && res+=" ${untracked}?${VCS_STATUS_NUM_UNTRACKED}"
    (( VCS_STATUS_HAS_UNSTAGED == -1 )) && res+=" ${modified}-"
    typeset -g my_git_format=$res
  }
  functions -M my_git_formatter 2>/dev/null

  typeset -g POWERLEVEL9K_VCS_MAX_INDEX_SIZE_DIRTY=-1
  typeset -g POWERLEVEL9K_VCS_DISABLED_WORKDIR_PATTERN='~'
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true
  typeset -g POWERLEVEL9K_VCS_CONTENT_EXPANSION='${$((my_git_formatter(1)))+${my_git_format}}'
  typeset -g POWERLEVEL9K_VCS_LOADING_CONTENT_EXPANSION='${$((my_git_formatter(0)))+${my_git_format}}'
  typeset -g POWERLEVEL9K_VCS_{STAGED,UNSTAGED,UNTRACKED,CONFLICTED,COMMITS_AHEAD,COMMITS_BEHIND}_MAX_NUM=-1
  typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_COLOR=76
  typeset -g POWERLEVEL9K_VCS_PREFIX='%fon '
  typeset -g POWERLEVEL9K_VCS_BACKENDS=(git)
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=76
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=76
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=178

  typeset -g POWERLEVEL9K_STATUS_EXTENDED_STATES=true
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_OK_FOREGROUND=70
  typeset -g POWERLEVEL9K_STATUS_OK_VISUAL_IDENTIFIER_EXPANSION='ok'
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE=true
  typeset -g POWERLEVEL9K_STATUS_OK_PIPE_FOREGROUND=70
  typeset -g POWERLEVEL9K_STATUS_ERROR=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=160
  typeset -g POWERLEVEL9K_STATUS_ERROR_VISUAL_IDENTIFIER_EXPANSION='err'
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_SIGNAL_FOREGROUND=160
  typeset -g POWERLEVEL9K_STATUS_VERBOSE_SIGNAME=false
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_PIPE_FOREGROUND=160

  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PRECISION=0
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=101
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_PREFIX='%ftook '

  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VERBOSE=false
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_FOREGROUND=70
  typeset -g POWERLEVEL9K_DIRENV_FOREGROUND=178

  typeset -g POWERLEVEL9K_CONTEXT_ROOT_FOREGROUND=178
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_FOREGROUND=180
  typeset -g POWERLEVEL9K_CONTEXT_FOREGROUND=180
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_TEMPLATE='%B%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_PREFIX='%fwith '

  typeset -g POWERLEVEL9K_VIRTUALENV_FOREGROUND=37
  typeset -g POWERLEVEL9K_VIRTUALENV_SHOW_PYTHON_VERSION=false
  typeset -g POWERLEVEL9K_PYENV_FOREGROUND=37
  typeset -g POWERLEVEL9K_NODENV_FOREGROUND=70
  typeset -g POWERLEVEL9K_NVM_FOREGROUND=70
  typeset -g POWERLEVEL9K_KUBECONTEXT_SHOW_ON_COMMAND='kubectl|helm|kubens|kubectx|oc|istioctl|k9s'
  typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_FOREGROUND=134
  typeset -g POWERLEVEL9K_KUBECONTEXT_PREFIX='%fat '

  typeset -g POWERLEVEL9K_TIME_FOREGROUND=66
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M:%S}'
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose
  typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true

  (( ! $+functions[p10k] )) || p10k reload
}

typeset -g POWERLEVEL9K_CONFIG_FILE=${${(%):-%x}:a}
(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
PEOF
}

uninstall_zsh() {
  hr; info "卸载 Oh-My-Zsh"; echo ""
  /bin/rm -rf /usr/local/share/ohmyzsh
  /bin/rm -f /etc/profile.d/lnmp-zsh.sh
  if [[ -f /etc/zshrc.bak ]]; then mv /etc/zshrc.bak /etc/zshrc; fi
  /bin/rm -f /etc/p10k.zsh /etc/zshenv
  if declare -F is_fnm_ok &>/dev/null && is_fnm_ok && declare -F _node_write_devops_shell &>/dev/null; then
    touch /etc/zshenv
    _node_write_devops_shell
  fi
  local bash_bin="/bin/bash"
  for u in root "${WHEEL_USER:-}" "${DEVOPS_USER:-}" "${CYBER_ORDINARY:-}" "${CYBER_AUDIT:-}" "${CYBER_SAFE:-}"; do
    if [[ -n "$u" ]] && id "$u" &>/dev/null; then chsh -s "$bash_bin" "$u" 2>/dev/null || true; fi
  done
  ok "Oh-My-Zsh 已卸载"
}

