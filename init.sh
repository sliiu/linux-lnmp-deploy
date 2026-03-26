#!/bin/bash
set -euo pipefail

VERSION="2.0.0"
CONF_FILE="/etc/lnmp-env.conf"
DATA_DIR="/data/docker-lnmp"
COMPOSE_FILE="${DATA_DIR}/docker-compose.yml"
CYBERSEC_MARKER="/etc/cybersecurity-init.done"

mkdir -p "${DATA_DIR}/logs" 2>/dev/null || true
LOG_FILE="${DATA_DIR}/logs/init.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') START $0 $* pid=$$ ====="

# ═══════════════════════════════════════════════
#  工具函数
# ═══════════════════════════════════════════════
die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
hr()   { echo "══════════════════════════════════════════════"; }

confirm() {
  local msg="${1:-确认？}" default="${2:-y}"
  local p="[Y/n]"
  if [[ "$default" != "y" ]]; then p="[y/N]"; fi
  local ans
  read -rp "  ${msg} ${p}: " ans
  ans=${ans:-$default}
  [[ "$ans" =~ ^[yY]$ ]]
}

prompt() {
  local msg="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -rp "  ${msg} [${default}]: " var </dev/tty
  else
    read -rp "  ${msg}: " var </dev/tty
  fi
  echo "${var:-$default}"
}

# printf -v 写入命名变量，避免 stdout 被 tee 记入日志（兼容 bash 3.2）
prompt_secret_confirm_into() {
  local msg="$1" _var="$2" p1 p2
  [[ "$_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "内部错误: 无效变量名"
  while true; do
    read -rsp "  ${msg}: " p1 </dev/tty; echo >/dev/tty
    if [[ -z "$p1" ]]; then echo "  ! 不能为空" >/dev/tty; continue; fi
    read -rsp "  再次确认: " p2 </dev/tty; echo >/dev/tty
    if [[ "$p1" = "$p2" ]]; then printf -v "$_var" '%s' "$p1"; return 0; fi
    echo "  ! 两次输入不一致" >/dev/tty
  done
}

menu_select() {
  local title="$1"; shift
  local -a items=("$@")
  {
    echo ""
    info "$title"
    echo ""
    for i in "${!items[@]}"; do
      printf "    %d) %s\n" $((i + 1)) "${items[$i]}"
    done
    echo ""
  } >/dev/tty
  local choice
  read -rp "  选择 [1-${#items[@]}]: " choice </dev/tty >/dev/tty
  choice=$((choice - 1))
  [[ $choice -ge 0 && $choice -lt ${#items[@]} ]] || choice=0
  echo "$choice"
}

menu_multi() {
  local title="$1"; shift
  local -a items=("$@")
  {
    echo ""
    info "$title (逗号分隔, 如 1,3,5 | all=全选 | 回车=默认全选)"
    echo ""
    for i in "${!items[@]}"; do
      printf "    %d) %s\n" $((i + 1)) "${items[$i]}"
    done
    echo ""
  } >/dev/tty
  local input
  read -rp "  选择: " input </dev/tty >/dev/tty
  input=$(echo "$input" | tr -d ' ')
  if [[ -z "$input" || "$input" = "all" ]]; then
    seq 0 $((${#items[@]} - 1)) | tr '\n' ' '
  else
    local -a result=()
    IFS=',' read -ra parts <<< "$input"
    for p in "${parts[@]}"; do
      local idx=$((p - 1))
      if [[ $idx -ge 0 && $idx -lt ${#items[@]} ]]; then result+=("$idx"); fi
    done
    echo "${result[*]}"
  fi
}

fetch_url() {
  local url="$1" out="${2:--}"
  wget -q --no-check-certificate -O "$out" "$url" 2>/dev/null \
    || (command -v curl &>/dev/null && curl -fsSL -o "$out" "$url") \
    || return 1
}

_git_clone_retry() {
  local url="$1" dir="$2"
  local attempts="${3:-5}" wait="${4:-5}" i
  for ((i = 1; i <= attempts; i++)); do
    /bin/rm -rf "$dir"
    if env GIT_HTTP_LOW_SPEED_LIMIT=500 GIT_HTTP_LOW_SPEED_TIME=600 \
      git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 \
      clone --depth=1 --single-branch "$url" "$dir"; then
      return 0
    fi
    if ((i < attempts)); then
      warn "git clone 失败（${url##*/}），${wait}s 后重试 (${i}/${attempts})..."
      sleep "$wait"
    fi
  done
  return 1
}

run_pkg() {
  if command -v dnf &>/dev/null; then
    dnf "$@"
  elif command -v yum &>/dev/null; then
    yum "$@"
  elif command -v apt-get &>/dev/null; then
    apt-get "$@"
  else
    die "未找到包管理器"
  fi
}

ensure_supervisor_service() {
  command -v systemctl &>/dev/null || return 0
  if systemctl cat supervisord.service &>/dev/null; then
    systemctl enable --now supervisord &>/dev/null && ok "supervisord 已启用并启动" || warn "supervisord 启动失败，请手动: systemctl enable --now supervisord"
    return 0
  fi
  if systemctl cat supervisor.service &>/dev/null; then
    systemctl enable --now supervisor &>/dev/null && ok "supervisor 已启用并启动" || warn "supervisor 启动失败，请手动: systemctl enable --now supervisor"
    return 0
  fi
  return 0
}

check_passwd_strength() {
  local p="$1" n=0
  [[ ${#p} -ge 10 ]] || return 1
  [[ "$p" =~ [a-z] ]] && ((n++)) || true
  [[ "$p" =~ [A-Z] ]] && ((n++)) || true
  [[ "$p" =~ [0-9] ]] && ((n++)) || true
  [[ "$p" =~ [^a-zA-Z0-9] ]] && ((n++)) || true
  [[ $n -ge 3 ]]
}

# ═══════════════════════════════════════════════
#  配置管理
# ═══════════════════════════════════════════════
conf_load() {
  DEVOPS_USER="${DEVOPS_USER:-devops}"
  GH_PROXY="${GH_PROXY:-}"
  DOCKER_MIRRORS_STR="${DOCKER_MIRRORS_STR:-}"
  ALPINE_MIRROR="${ALPINE_MIRROR:-mirrors.aliyun.com}"
  PHP_VERSION="${PHP_VERSION:-8.3}"
  PHP_EXTENSIONS="${PHP_EXTENSIONS:-pdo_mysql,opcache,mysqli,curl,gd,xml,dom,pcntl,bcmath,sockets,mbstring,zip,exif,intl,fileinfo,redis}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  SSH_PORT="${SSH_PORT:-22}"
  ROOT_LOGIN="${ROOT_LOGIN:-prohibit-password}"
  WHEEL_USER="${WHEEL_USER:-}"
  CYBER_ORDINARY="${CYBER_ORDINARY:-}"
  CYBER_AUDIT="${CYBER_AUDIT:-}"
  CYBER_SAFE="${CYBER_SAFE:-}"
  LNMP_SERVICES="${LNMP_SERVICES:-nginx,php,mysql,redis,acme}"
  MYSQL_ROOT_PWD="${MYSQL_ROOT_PWD:-}"
  [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" 2>/dev/null || true
  ACME_SSL_DNS_DEFAULT="${ACME_SSL_DNS_DEFAULT:-webroot}"
  CONTAINER_WWW="${CONTAINER_WWW:-${DATA_DIR}/www}"
}

conf_save() {
  cat > "$CONF_FILE" <<EOF
DEVOPS_USER=${DEVOPS_USER}
GH_PROXY=${GH_PROXY}
DOCKER_MIRRORS_STR=${DOCKER_MIRRORS_STR}
ALPINE_MIRROR=${ALPINE_MIRROR}
PHP_VERSION=${PHP_VERSION}
PHP_EXTENSIONS=${PHP_EXTENSIONS}
ACME_EMAIL=${ACME_EMAIL}
ACME_SSL_DNS_DEFAULT=${ACME_SSL_DNS_DEFAULT}
SSH_PORT=${SSH_PORT}
ROOT_LOGIN=${ROOT_LOGIN}
WHEEL_USER=${WHEEL_USER}
CYBER_ORDINARY=${CYBER_ORDINARY}
CYBER_AUDIT=${CYBER_AUDIT}
CYBER_SAFE=${CYBER_SAFE}
LNMP_SERVICES=${LNMP_SERVICES}
CONTAINER_WWW=${CONTAINER_WWW}
EOF
  chmod 600 "$CONF_FILE"
}

# ═══════════════════════════════════════════════
#  检测函数
# ═══════════════════════════════════════════════
is_bbr_on()       { sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; }
is_firewall_on()  { systemctl is-active firewalld &>/dev/null; }
is_docker_ok()    { command -v docker &>/dev/null && docker info &>/dev/null; }
is_zsh_ok()       { [[ -d /usr/local/share/ohmyzsh ]]; }
is_cybersec_ok()  { [[ -f "$CYBERSEC_MARKER" ]]; }
is_saferm_ok()     { [[ -x /usr/local/bin/saferm ]]; }
container_ok()    { docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^lnmp-${1}$"; }
container_any()   { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^lnmp-${1}$"; }

compose_cmd() {
  if docker compose version &>/dev/null; then
    docker compose "$@"
  elif command -v docker-compose &>/dev/null; then
    docker-compose "$@"
  else
    die "Docker Compose 未安装"
  fi
}

has_service() {
  [[ ",$LNMP_SERVICES," = *",$1,"* ]]
}

# ═══════════════════════════════════════════════
#  BBR
# ═══════════════════════════════════════════════
install_bbr() {
  hr; info "安装 BBR"; echo ""
  if is_bbr_on; then ok "BBR 已启用"; return 0; fi

  local kver
  kver=$(uname -r | cut -d- -f1)
  local major minor
  major=$(echo "$kver" | cut -d. -f1)
  minor=$(echo "$kver" | cut -d. -f2)

  if [[ "$major" -gt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -ge 9 ]]; }; then
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    ok "BBR 已启用"
  else
    die "内核版本 ${kver} < 4.9，不支持 BBR，请升级内核"
  fi
}

uninstall_bbr() {
  hr; info "禁用 BBR"; echo ""
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
  sysctl -p >/dev/null 2>&1
  ok "BBR 已禁用"
}

# ═══════════════════════════════════════════════
#  Firewalld
# ═══════════════════════════════════════════════
install_firewall() {
  hr; info "安装 Firewalld"; echo ""
  run_pkg install -y firewalld
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-port=80/tcp 2>/dev/null || true
  firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true
  if [[ "${SSH_PORT:-22}" != "22" ]]; then firewall-cmd --permanent --add-port="${SSH_PORT}"/tcp 2>/dev/null || true; fi
  firewall-cmd --reload 2>/dev/null || true
  ok "Firewalld 已安装并放行 80/443"
}

uninstall_firewall() {
  hr; info "卸载 Firewalld"; echo ""
  systemctl stop firewalld 2>/dev/null || true
  systemctl disable firewalld 2>/dev/null || true
  run_pkg remove -y firewalld 2>/dev/null || true
  ok "Firewalld 已卸载"
}

# ═══════════════════════════════════════════════
#  Oh-My-Zsh
# ═══════════════════════════════════════════════
install_zsh() {
  hr; info "安装 Oh-My-Zsh"; echo ""
  run_pkg install -y zsh

  local gh_url="${GH_PROXY:+${GH_PROXY}/}https://github.com"
  /bin/rm -rf /usr/local/share/ohmyzsh

  _git_clone_retry "${gh_url}/ohmyzsh/ohmyzsh.git" /usr/local/share/ohmyzsh \
    || die "clone ohmyzsh 失败（可重试或在向导中选择 GitHub 代理）"
  _git_clone_retry "${gh_url}/zsh-users/zsh-autosuggestions" \
    /usr/local/share/ohmyzsh/plugins/zsh-autosuggestions \
    || die "clone zsh-autosuggestions 失败"
  _git_clone_retry "${gh_url}/zsh-users/zsh-syntax-highlighting" \
    /usr/local/share/ohmyzsh/plugins/zsh-syntax-highlighting \
    || die "clone zsh-syntax-highlighting 失败"
  _git_clone_retry "${gh_url}/romkatv/powerlevel10k.git" \
    /usr/local/share/ohmyzsh/themes/powerlevel10k \
    || die "clone powerlevel10k 失败"

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

  _write_p10k_config

  chmod -R 755 /usr/local/share/ohmyzsh
  chmod 644 /etc/zshrc /etc/zshenv /etc/p10k.zsh

  local zsh_bin=""
  for z in /usr/bin/zsh /usr/local/bin/zsh /bin/zsh; do
    if [[ -x "$z" ]]; then zsh_bin="$z"; break; fi
  done
  if [[ -n "$zsh_bin" ]]; then
    grep -qxF "$zsh_bin" /etc/shells 2>/dev/null || echo "$zsh_bin" >> /etc/shells
    for u in root "${WHEEL_USER:-}" "${DEVOPS_USER:-}" "${CYBER_ORDINARY:-}" "${CYBER_AUDIT:-}" "${CYBER_SAFE:-}"; do
      if [[ -n "$u" ]] && id "$u" &>/dev/null; then chsh -s "$zsh_bin" "$u" 2>/dev/null || true; fi
    done
  fi
  ok "Oh-My-Zsh 已安装"
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
  if [[ -f /etc/zshrc.bak ]]; then mv /etc/zshrc.bak /etc/zshrc; fi
  /bin/rm -f /etc/p10k.zsh /etc/zshenv
  local bash_bin="/bin/bash"
  for u in root "${WHEEL_USER:-}" "${DEVOPS_USER:-}" "${CYBER_ORDINARY:-}" "${CYBER_AUDIT:-}" "${CYBER_SAFE:-}"; do
    if [[ -n "$u" ]] && id "$u" &>/dev/null; then chsh -s "$bash_bin" "$u" 2>/dev/null || true; fi
  done
  ok "Oh-My-Zsh 已卸载"
}

# ═══════════════════════════════════════════════
#  Docker
# ═══════════════════════════════════════════════
install_docker() {
  hr; info "安装 Docker"; echo ""

  if is_docker_ok; then
    ok "Docker 已安装 ($(docker -v 2>/dev/null | head -1))"
  else
    if [[ -f /etc/os-release ]] && grep -q "Alibaba Cloud Linux" /etc/os-release 2>/dev/null; then
      _install_docker_alinux
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]]; then
      _install_docker_centos
    elif [[ -f /etc/debian_version ]]; then
      _install_docker_debian
    else
      die "不支持的发行版"
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl start docker 2>/dev/null || true
    docker -v &>/dev/null || die "Docker 安装失败"
  fi

  _ensure_compose
  _configure_docker_daemon
  _docker_add_users

  ok "Docker 就绪"
}

_install_docker_alinux() {
  dnf update dnf -y 2>/dev/null || true
  dnf clean packages 2>/dev/null || true
  /bin/rm -f /etc/yum.repos.d/docker*.repo

  if fetch_url "http://mirrors.cloud.aliyuncs.com/docker-ce/linux/centos/docker-ce.repo" "/tmp/docker-ce.repo"; then
    cp /tmp/docker-ce.repo /etc/yum.repos.d/docker-ce.repo
    sed -i 's|https://mirrors.aliyun.com|http://mirrors.cloud.aliyuncs.com|g' /etc/yum.repos.d/docker-ce.repo
  else
    fetch_url "https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo" "/etc/yum.repos.d/docker-ce.repo"
    sed -i 's|download.docker.com|mirrors.aliyun.com/docker-ce|g' /etc/yum.repos.d/docker-ce.repo
  fi
  /bin/rm -f /tmp/docker-ce.repo

  grep -q "Alibaba Cloud Linux 3" /etc/os-release 2>/dev/null \
    && dnf -y install dnf-plugin-releasever-adapter --repo alinux3-plus 2>/dev/null || true

  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_install_docker_centos() {
  run_pkg clean all 2>/dev/null || true
  run_pkg install -y yum-utils 2>/dev/null || true

  if command -v dnf &>/dev/null; then
    dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
  else
    yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
  fi
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] \
    && sed -i 's+download.docker.com+mirrors.aliyun.com/docker-ce+g' /etc/yum.repos.d/docker-ce.repo

  run_pkg install -y docker-ce docker-ce-cli containerd.io
}

_install_docker_debian() {
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

_ensure_compose() {
  if docker compose version &>/dev/null || command -v docker-compose &>/dev/null; then
    return 0
  fi
  fetch_url "${GH_PROXY:+${GH_PROXY}/}https://github.com/docker/compose/releases/download/v2.29.2/docker-compose-linux-$(uname -m)" \
    "/usr/local/bin/docker-compose" \
    && chmod +x /usr/local/bin/docker-compose
}

_configure_docker_daemon() {
  mkdir -p /etc/docker
  local mirrors_json=""
  if [[ -n "$DOCKER_MIRRORS_STR" ]]; then
    IFS=',' read -ra _ms <<< "$DOCKER_MIRRORS_STR"
    local first=1
    for m in "${_ms[@]}"; do
      if [[ -z "$m" ]]; then continue; fi
      [[ $first -eq 1 ]] && first=0 || mirrors_json+=", "
      mirrors_json+="\"${m}\""
    done
  fi

  if [[ -n "$mirrors_json" ]]; then
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [${mirrors_json}],
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
  else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
EOF
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true
}

_docker_add_users() {
  if [[ -n "${WHEEL_USER:-}" ]] && id "$WHEEL_USER" &>/dev/null; then
    usermod -aG docker "$WHEEL_USER" 2>/dev/null || true
  fi
  if [[ -n "${DEVOPS_USER:-}" ]] && id "$DEVOPS_USER" &>/dev/null; then
    usermod -aG docker "$DEVOPS_USER" 2>/dev/null || true
  fi
}

uninstall_docker() {
  hr; info "卸载 Docker"; echo ""

  if [[ -f "$COMPOSE_FILE" ]]; then
    cd "$DATA_DIR" 2>/dev/null && compose_cmd down 2>/dev/null || true
  fi

  systemctl stop docker 2>/dev/null || true
  systemctl disable docker 2>/dev/null || true

  if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    run_pkg remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  elif command -v apt-get &>/dev/null; then
    apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  fi
  /bin/rm -f /usr/local/bin/docker-compose
  ok "Docker 已卸载"
}

# ═══════════════════════════════════════════════
#  SSH 安全
# ═══════════════════════════════════════════════
_ssh_build_allowusers_list() {
  local allow="${WHEEL_USER:-admin} ${DEVOPS_USER:-devops}"
  [[ -n "${CYBER_ORDINARY:-}" ]] && allow+=" ${CYBER_ORDINARY}"
  [[ -n "${CYBER_AUDIT:-}" ]] && allow+=" ${CYBER_AUDIT}"
  [[ -n "${CYBER_SAFE:-}" ]] && allow+=" ${CYBER_SAFE}"
  if [[ "${ROOT_LOGIN:-prohibit-password}" != "no" ]]; then
    allow="root ${allow}"
  fi
  echo "$allow"
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
  latest_bak=$(ls -t "${sshd_conf}".bak.* 2>/dev/null | head -1)
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
  home=$(getent passwd "$u" | cut -d: -f6)
  [[ -n "$home" && -d "$home" ]] || { warn "跳过 ${u}：家目录无效"; return 0; }

  mkdir -p "${home}/.ssh"
  chmod 700 "${home}/.ssh"

  local ak="${home}/.ssh/authorized_keys"
  if [[ -s "$ak" ]]; then
    chown -R "${u}:${u}" "${home}/.ssh" 2>/dev/null || true
    return 0
  fi

  if [[ "$mode" = "root" ]]; then
    if [[ -s /root/.ssh/authorized_keys ]]; then
      cp /root/.ssh/authorized_keys "$ak" || true
    else
      warn "${u}：root 无 authorized_keys，无法复制"
    fi
  elif [[ "$mode" = "line" && -n "$key_line" ]]; then
    printf '%s\n' "$key_line" >> "$ak"
  else
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

# ═══════════════════════════════════════════════
#  用户管理
# ═══════════════════════════════════════════════
setup_devops_user() {
  hr; info "配置 devops 用户: ${DEVOPS_USER}"; echo ""

  getent group devops >/dev/null 2>&1 || groupadd devops

  if ! id "${DEVOPS_USER}" &>/dev/null; then
    local pwd
    prompt_secret_confirm_into "${DEVOPS_USER} 密码" pwd
    useradd -m -s /bin/bash "${DEVOPS_USER}" || die "创建用户失败"
    echo "${DEVOPS_USER}:${pwd}" | chpasswd || die "设置密码失败"
    chmod 700 /home/"${DEVOPS_USER}"
    ok "${DEVOPS_USER} 创建完成"
  else
    ok "${DEVOPS_USER} 已存在"
  fi

  usermod -aG devops "${DEVOPS_USER}" 2>/dev/null || true

  mkdir -p /usr/local/bin
  echo "%devops ALL=(ALL) NOPASSWD: /usr/local/bin/deploy-site.sh" \
    > /etc/sudoers.d/devops-deploy 2>/dev/null
  chmod 440 /etc/sudoers.d/devops-deploy 2>/dev/null || true

  ensure_user_ssh_access "${DEVOPS_USER}"
}

setup_wheel_user() {
  hr; info "配置 wheel 管理员: ${WHEEL_USER}"; echo ""
  if [[ -z "$WHEEL_USER" ]]; then return 0; fi

  if ! id "${WHEEL_USER}" &>/dev/null; then
    local pwd
    prompt_secret_confirm_into "${WHEEL_USER} 密码" pwd
    adduser "${WHEEL_USER}" || die "创建用户 ${WHEEL_USER} 失败"
    echo "${WHEEL_USER}:${pwd}" | chpasswd || die "设置密码失败"
    ok "${WHEEL_USER} 创建完成"
  elif confirm "${WHEEL_USER} 已存在，是否修改密码？" "n"; then
    local pwd
    prompt_secret_confirm_into "新密码" pwd
    echo "${WHEEL_USER}:${pwd}" | chpasswd || die "设置密码失败"
    ok "${WHEEL_USER} 密码已更新"
  fi

  usermod -aG wheel "${WHEEL_USER}" || die "添加 wheel 组失败"
  usermod -aG devops "${WHEEL_USER}" 2>/dev/null || true
  mkdir -p /home/"${WHEEL_USER}"/.ssh
  chmod 700 /home/"${WHEEL_USER}"/.ssh
  chown -R "${WHEEL_USER}:${WHEEL_USER}" /home/"${WHEEL_USER}"/.ssh

  ensure_user_ssh_access "${WHEEL_USER}"
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
    name=$(prompt "${roles[$role]}用户名" "${defaults[$role]}")
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
    fi
  fi

  chmod 750 /home/* 2>/dev/null || true
  chage --maxdays 90 root 2>/dev/null || true
  chage --mindays 7 root 2>/dev/null || true
  chmod 600 /etc/ssh/sshd_config 2>/dev/null || true
  touch "$CYBERSEC_MARKER"
  ok "等保加固完成"
}

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
  name=$(prompt "登录名 (字母开头)")
  _account_valid_login "$name" || die "登录名格式无效"
  id "$name" &>/dev/null && die "用户已存在"

  shell=$(prompt "Shell" "/bin/bash")
  [[ -x "$shell" ]] || warn "Shell 可能不存在: ${shell}"

  exg=$(prompt "附加组，逗号分隔（如 devops,wheel，留空无）" "")
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
  name=$(prompt "要删除的登录名")
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
  name=$(prompt "登录名")
  id "$name" &>/dev/null || die "用户不存在"
  _account_refuse_system_user "$name"
  prompt_secret_confirm_into "${name} 新密码" pwd
  echo "${name}:${pwd}" | chpasswd || die "chpasswd 失败"
  ok "密码已更新"
}

account_group_add_interactive() {
  hr; info "新建用户组"; echo ""
  local g
  g=$(prompt "组名")
  [[ "$g" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]] || die "组名无效"
  getent group "$g" &>/dev/null && die "组已存在"
  groupadd "$g" || die "groupadd 失败"
  ok "组 ${g} 已创建"
}

account_group_delete_interactive() {
  hr; info "删除用户组"; echo ""
  local g
  g=$(prompt "组名")
  getent group "$g" &>/dev/null || die "组不存在"
  [[ "$g" = "root" || "$g" = "wheel" || "$g" = "devops" ]] && die "拒绝删除系统关键组"
  if ! confirm "确认删除组 ${g}？" "n"; then return 0; fi
  groupdel "$g" || die "groupdel 失败（可能仍有成员或为主组）"
  ok "已删除组 ${g}"
}

account_user_addgroup_interactive() {
  hr; info "将用户加入组"; echo ""
  local u g
  u=$(prompt "用户名")
  g=$(prompt "组名")
  id "$u" &>/dev/null || die "用户不存在"
  getent group "$g" &>/dev/null || die "组不存在"
  usermod -aG "$g" "$u" || die "usermod 失败"
  ok "${u} 已加入 ${g}"
}

account_user_delgroup_interactive() {
  hr; info "将用户移出组"; echo ""
  local u g
  u=$(prompt "用户名")
  g=$(prompt "组名")
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
  name=$(prompt "目标用户名")
  id "$name" &>/dev/null || die "用户不存在"
  local home ak
  home="$(_account_user_home "$name")"
  ak="${home}/.ssh/authorized_keys"

  local act
  act=$(menu_select "操作" "查看 authorized_keys" "追加一行公钥" "用 root 的 authorized_keys 覆盖" "清空 authorized_keys" "返回")
  case "$act" in
    0)
      if [[ -s "$ak" ]]; then nl -ba "$ak"; else info "(空)"; fi
      ;;
    1)
      local pk fp
      fp=$(prompt "或公钥文件路径（留空则手动粘贴）" "")
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
    echo ""
    hr; info "账户管理"; hr; echo ""
    echo "    1) 用户列表"
    echo "    2) 新建用户"
    echo "    3) 删除用户"
    echo "    4) 修改密码"
    echo "    5) SSH 公钥（查看/追加/覆盖/清空）"
    echo "    6) 用户组列表"
    echo "    7) 新建用户组"
    echo "    8) 删除用户组"
    echo "    9) 用户加入组"
    echo "   10) 用户移出组"
    echo "   11) 查看 AllowUsers"
    echo "   12) 按 lnmp-env 重建 AllowUsers"
    echo "    0) 返回主菜单"
    echo ""
    local c
    read -rp "  选择 [0-12]: " c
    case "$c" in
      1)  account_user_list_display ;;
      2)  account_user_add_interactive ;;
      3)  account_user_delete_interactive ;;
      4)  account_user_passwd_interactive ;;
      5)  account_sshkey_menu_interactive ;;
      6)  account_groups_list_display ;;
      7)  account_group_add_interactive ;;
      8)  account_group_delete_interactive ;;
      9)  account_user_addgroup_interactive ;;
      10) account_user_delgroup_interactive ;;
      11) account_allowusers_display ;;
      12) account_allowusers_resync_from_conf ;;
      0)  return 0 ;;
      *)  warn "无效选择" ;;
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

# ═══════════════════════════════════════════════
#  LNMP
# ═══════════════════════════════════════════════
_write_php_laravel_conf() {
  mkdir -p "${DATA_DIR}/php/conf.d"
  cat > "${DATA_DIR}/php/conf.d/99-laravel.ini" <<'PHPINI'
output_buffering = 4096
PHPINI
}

lnmp_gen_compose() {
  mkdir -p "${DATA_DIR}"/{nginx/conf.d,nginx/logs,nginx/cache,mysql,redis,www,ssl,php/conf.d}

  if has_service "php"; then _write_php_laravel_conf; fi

  if [[ ! -f "${DATA_DIR}/nginx/nginx.conf" ]]; then _write_nginx_main_conf; fi
  if [[ ! -f "${DATA_DIR}/nginx/conf.d/default.conf" ]]; then _write_nginx_default_conf; fi

  local yaml="services:"
  local volumes_section=""

  if has_service "nginx"; then
    yaml+="
  nginx:
    image: nginx:stable-alpine
    container_name: lnmp-nginx
    user: \"101:101\"
    security_opt: [\"no-new-privileges:true\"]
    cap_add: [NET_BIND_SERVICE]
    depends_on: [php]
    ports: [\"80:80\", \"443:443\"]
    volumes:
      - ${DATA_DIR}/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${DATA_DIR}/nginx/conf.d:/etc/nginx/conf.d
      - ${DATA_DIR}/nginx/logs:/var/log/nginx
      - ${DATA_DIR}/nginx/cache:/var/cache/nginx
      - ${DATA_DIR}/www:${CONTAINER_WWW}
      - ${DATA_DIR}/ssl:/etc/nginx/ssl
    restart: always
    networks: [lnmp-net]
"
  fi

  if has_service "php"; then
    local php_deps="" php_env=""
    has_service "mysql" && php_deps+="      - mysql
" && php_env+="      - DB_HOST=mysql
"
    has_service "redis" && php_deps+="      - redis
" && php_env+="      - REDIS_HOST=redis
"

    yaml+="
  php:
    image: php:${PHP_VERSION}-fpm-alpine
    container_name: lnmp-php
    user: \"82:82\"
    security_opt: [\"no-new-privileges:true\"]
    volumes:
      - ${DATA_DIR}/www:${CONTAINER_WWW}
      - ${DATA_DIR}/php/conf.d/99-laravel.ini:/usr/local/etc/php/conf.d/99-laravel.ini:ro
      - php-extensions:/usr/local/lib/php/extensions"

    if [[ -n "$php_env" ]]; then yaml+="
    environment:
${php_env}"; fi
    if [[ -n "$php_deps" ]]; then yaml+="
    depends_on:
${php_deps}"; fi

    yaml+="
    restart: always
    networks: [lnmp-net]
"
    volumes_section="
volumes:
  php-extensions:"
  fi

  if has_service "mysql"; then
    yaml+="
  mysql:
    image: mysql:8.0
    container_name: lnmp-mysql
    security_opt: [\"no-new-privileges:true\"]
    volumes:
      - ${DATA_DIR}/mysql:/var/lib/mysql
    restart: always
    networks: [lnmp-net]
    environment:
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD:-changeme}
      - TZ=Asia/Shanghai
"
  fi

  if has_service "redis"; then
    yaml+="
  redis:
    image: redis:alpine
    container_name: lnmp-redis
    user: \"999:999\"
    security_opt: [\"no-new-privileges:true\"]
    command: [\"redis-server\", \"--save\", \"60\", \"1\", \"--save\", \"300\", \"10\", \"--loglevel\", \"warning\"]
    volumes:
      - ${DATA_DIR}/redis:/data
    healthcheck:
      test: [\"CMD\", \"redis-cli\", \"ping\"]
      interval: 10s
      timeout: 3s
      retries: 3
    restart: always
    networks: [lnmp-net]
"
  fi

  if has_service "acme"; then
    yaml+="
  acme:
    image: neilpang/acme.sh:latest
    container_name: lnmp-acme
    security_opt: [\"no-new-privileges:true\"]
    volumes:
      - ${DATA_DIR}/ssl:/acme.sh
      - ${DATA_DIR}/www:/www
      - /var/run/docker.sock:/var/run/docker.sock
      - /usr/bin/docker:/usr/bin/docker:ro
    environment:
      - ACME_EMAIL=${ACME_EMAIL}
    entrypoint: /bin/sh
    command: \"-c \\\"while true; do sleep 86400; done\\\"\"
    restart: always
    networks: [lnmp-net]
"
  fi

  yaml+="
networks:
  lnmp-net:
${volumes_section}"

  echo "$yaml" > "$COMPOSE_FILE"
}

_write_nginx_main_conf() {
  cat > "${DATA_DIR}/nginx/nginx.conf" <<'NGINXMAIN'
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/cache/nginx/nginx.pid;

events {
    worker_connections  1024;
    use epoll;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    server_tokens   off;

    client_max_body_size 64m;
    client_body_timeout  60;
    client_header_timeout 60;

    gzip on;
    gzip_vary on;
    gzip_min_length 1k;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml
               application/xml+rss image/svg+xml;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling        off;
    ssl_stapling_verify off;

    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN
}

_write_nginx_default_conf() {
  cat > "${DATA_DIR}/nginx/conf.d/default.conf" <<'NGINX'
server {
    listen 80 default_server;
    server_name _;
    return 503;
}
NGINX
}

install_lnmp() {
  local component="${1:-all}"
  hr; info "部署 LNMP (${component})"; echo ""

  run_pkg install -y acl 2>/dev/null || true

  is_docker_ok || die "需要先安装 Docker"
  systemctl start docker 2>/dev/null || true

  if [[ "$component" != "all" ]]; then
    if [[ ",$LNMP_SERVICES," != *",$component,"* ]]; then LNMP_SERVICES="${LNMP_SERVICES},${component}"; fi
    if [[ "$component" = "nginx" && ",$LNMP_SERVICES," != *",php,"* ]]; then LNMP_SERVICES="${LNMP_SERVICES},php"; fi
  fi

  lnmp_gen_compose

  if has_service "nginx" && [[ -f "${DATA_DIR}/nginx/nginx.conf" ]]; then
    sed -i 's|/var/run/nginx.pid|/var/cache/nginx/nginx.pid|g' "${DATA_DIR}/nginx/nginx.conf" 2>/dev/null || true
  fi

  local _dg
  _dg=$(id -gn "${DEVOPS_USER}" 2>/dev/null || echo "${DEVOPS_USER}")
  chown -R "${DEVOPS_USER}:${DEVOPS_USER}" "${DATA_DIR}/www" 2>/dev/null || true
  chmod g+s "${DATA_DIR}/www"
  chown -R 101:101 "${DATA_DIR}/nginx/logs" 2>/dev/null || true
  mkdir -p "${DATA_DIR}/nginx/cache"
  chown -R 101:101 "${DATA_DIR}/nginx/cache" 2>/dev/null || true
  chmod -R 755 "${DATA_DIR}/nginx/cache" 2>/dev/null || true
  chmod 755 "${DATA_DIR}/nginx/conf.d" 2>/dev/null || true
  shopt -s nullglob
  for _nf in "${DATA_DIR}/nginx/conf.d"/*.conf; do
    chmod 644 "$_nf" 2>/dev/null || true
    chown 101:101 "$_nf" 2>/dev/null || true
  done
  shopt -u nullglob
  chmod 755 "${DATA_DIR}/ssl" 2>/dev/null || true
  shopt -s nullglob
  for _sd in "${DATA_DIR}/ssl"/*/; do
    [[ -d "$_sd" ]] || continue
    chmod 755 "$_sd" 2>/dev/null || true
    chown 101:101 "$_sd" 2>/dev/null || true
    for _sf in "$_sd"/*; do
      [[ -f "$_sf" ]] || continue
      case "${_sf##*/}" in
        *.key) chmod 640 "$_sf" 2>/dev/null || true ;;
        *)     chmod 644 "$_sf" 2>/dev/null || true ;;
      esac
      chown 101:101 "$_sf" 2>/dev/null || true
    done
  done
  shopt -u nullglob
  if [[ -z "$(ls -A "${DATA_DIR}/redis" 2>/dev/null)" ]]; then chown -R 999:999 "${DATA_DIR}/redis" 2>/dev/null || true; fi
  chmod -R 755 "${DATA_DIR}"
  chown root:"${_dg}" "${DATA_DIR}" 2>/dev/null || true
  chmod 771 "${DATA_DIR}"

  if has_service "mysql" && [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PWD" compose_cmd -f "$COMPOSE_FILE" up -d
  else
    compose_cmd -f "$COMPOSE_FILE" up -d
  fi

  if has_service "php"; then
    _wait_container "php" 30
    _install_php_extensions
  fi

  if has_service "acme"; then
    _setup_acme_cron
  fi

  conf_save
  ok "LNMP 部署完成"
}

_wait_container() {
  local name="$1" max="${2:-30}"
  for _ in $(seq 1 "$max"); do
    container_ok "$name" && docker exec "lnmp-${name}" true &>/dev/null && return 0
    sleep 2
  done
  die "容器 lnmp-${name} 启动超时"
}

_php_ext_exec_with_apk_retry() {
  local inner="$1"
  local attempt=1 max=12 pause=5
  sleep 2
  while ((attempt <= max)); do
    if docker exec -u root -e TERM=dumb lnmp-php sh -c "$inner"; then
      return 0
    fi
    if ((attempt < max)); then
      warn "容器内 apk 可能被占用或暂锁库，${pause}s 后重试 (${attempt}/${max})..."
      sleep "$pause"
    fi
    ((attempt++)) || true
  done
  return 1
}

_install_php_extensions() {
  info "安装 PHP 扩展..."

  IFS=',' read -ra exts <<< "$PHP_EXTENSIONS"
  local need_gd=0 need_intl=0 need_redis=0
  local ext_install=""

  for e in "${exts[@]}"; do
    case "$e" in
      gd)    need_gd=1;    ext_install+=" gd" ;;
      intl)  need_intl=1;  ext_install+=" intl" ;;
      redis) need_redis=1 ;;
      *)     ext_install+=" $e" ;;
    esac
  done
  ext_install=$(echo "$ext_install" | xargs)

  local alpine_sed=""
  [[ -n "$ALPINE_MIRROR" ]] && alpine_sed="sed -i 's|dl-cdn.alpinelinux.org|${ALPINE_MIRROR}|g' /etc/apk/repositories && apk update && "

  local apk_deps="libpng-dev libwebp-dev freetype-dev libjpeg-turbo-dev libxml2-dev curl-dev build-base linux-headers autoconf libzip-dev icu-dev oniguruma-dev"
  local cmd="${alpine_sed}apk add --no-cache ${apk_deps}"

  if [[ $need_gd -eq 1 ]]; then cmd+=" && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp"; fi
  if [[ $need_intl -eq 1 ]]; then cmd+=" && docker-php-ext-configure intl"; fi
  if [[ -n "$ext_install" ]]; then cmd+=" && docker-php-ext-install -j\$(nproc) ${ext_install}"; fi
  if [[ $need_redis -eq 1 ]]; then
    cmd+=" && if ! php -m 2>/dev/null | grep -q '^redis$'; then pecl install redis || true; fi"
    cmd+=" && docker-php-ext-enable redis 2>/dev/null || true"
  fi
  cmd+=" && apk del --no-cache build-base linux-headers autoconf"

  cmd="sleep 2; ${cmd}"
  _php_ext_exec_with_apk_retry "$cmd" || die "PHP 扩展安装失败（apk 多次重试仍失败：请确认无其他进程在 lnmp-php 内执行 apk，或 docker restart lnmp-php 后重试）"
  docker restart lnmp-php
  _wait_container "php" 20

  if [[ $need_redis -eq 1 ]]; then
    docker exec lnmp-php php -m | grep -q redis || die "PHP redis 扩展安装失败"
  fi
  if [[ " $ext_install " = *" pdo_mysql "* ]]; then
    docker exec lnmp-php php -m | grep -q pdo_mysql || die "PHP pdo_mysql 扩展安装失败"
  fi

  ok "PHP 扩展安装完成"
}

_setup_acme_cron() {
  cat > /usr/local/bin/acme-renew.sh <<'SH'
#!/bin/bash
docker exec lnmp-acme acme.sh --renew-all --server letsencrypt 2>/dev/null || true
docker exec lnmp-nginx nginx -s reload 2>/dev/null || true
SH
  chmod +x /usr/local/bin/acme-renew.sh
  local cron_line="0 3 1 * * /usr/local/bin/acme-renew.sh >> /var/log/acme-renew.log 2>&1"
  local existing
  existing=$(crontab -l 2>/dev/null || true)
  existing=$(echo "$existing" | { grep -v "acme-renew" || true; } | { grep -v "^$" || true; })
  if [[ -n "$existing" ]]; then
    printf '%s\n%s\n' "$existing" "$cron_line" | crontab -
  else
    echo "$cron_line" | crontab -
  fi
  ok "ACME 续期 cron 已添加"
}

uninstall_lnmp() {
  local component="${1:-all}"
  hr; info "卸载 LNMP (${component})"; echo ""

  if [[ "$component" = "all" ]]; then
    if [[ -f "$COMPOSE_FILE" ]]; then
      cd "$DATA_DIR" && compose_cmd -f "$COMPOSE_FILE" down -v 2>/dev/null || true
    fi
    LNMP_SERVICES=""
    /bin/rm -f "$COMPOSE_FILE"
    if confirm "是否删除数据目录 ${DATA_DIR}？" "n"; then
      /bin/rm -rf "$DATA_DIR"
    fi
  else
    local new_services=""
    IFS=',' read -ra svcs <<< "$LNMP_SERVICES"
    for s in "${svcs[@]}"; do
      if [[ "$s" = "$component" ]]; then continue; fi
      if [[ -n "$new_services" ]]; then new_services+=","; fi
      new_services+="$s"
    done
    LNMP_SERVICES="$new_services"

    docker stop "lnmp-${component}" 2>/dev/null || true
    docker rm "lnmp-${component}" 2>/dev/null || true

    if [[ -n "$LNMP_SERVICES" ]]; then
      lnmp_gen_compose
      compose_cmd -f "$COMPOSE_FILE" up -d 2>/dev/null || true
    fi
  fi

  conf_save
  ok "LNMP (${component}) 已卸载"
}

# ═══════════════════════════════════════════════
#  状态显示
# ═══════════════════════════════════════════════
show_status() {
  echo ""
  hr
  info "环境状态"
  hr
  echo ""

  local _s
  _s=$(is_bbr_on && echo "已启用" || echo "未启用")
  printf "  %-20s %s\n" "BBR" "$_s"

  _s=$(is_firewall_on && echo "运行中" || echo "未安装")
  printf "  %-20s %s\n" "Firewalld" "$_s"

  _s=$(is_docker_ok && echo "已安装 ($(docker -v 2>/dev/null | awk '{print $3}' | tr -d ','))" || echo "未安装")
  printf "  %-20s %s\n" "Docker" "$_s"

  _s=$(is_zsh_ok && echo "已安装" || echo "未安装")
  printf "  %-20s %s\n" "Oh-My-Zsh" "$_s"

  _s=$(is_saferm_ok && echo "已安装" || echo "未安装")
  printf "  %-20s %s\n" "saferm" "$_s"

  _s=$(is_cybersec_ok && echo "已加固" || echo "未配置")
  printf "  %-20s %s\n" "等保" "$_s"

  printf "  %-20s %s\n" "SSH 端口" "${SSH_PORT:-22}"
  printf "  %-20s %s\n" "SSH Root" "${ROOT_LOGIN:-未配置}"
  printf "  %-20s %s\n" "Devops 用户" "${DEVOPS_USER:-未配置}"
  if [[ -n "${WHEEL_USER:-}" ]]; then printf "  %-20s %s\n" "Wheel 管理员" "$WHEEL_USER"; fi

  echo ""
  info "LNMP 容器"
  echo ""
  for c in nginx php mysql redis acme; do
    if has_service "$c"; then
      _s=$(container_ok "$c" && echo "运行中" || echo "已停止")
    else
      _s="未部署"
    fi
    printf "  %-20s %s\n" "lnmp-${c}" "$_s"
  done

  echo ""
  printf "  %-20s %s\n" "PHP 版本" "${PHP_VERSION:-未配置}"
  printf "  %-20s %s\n" "Alpine 源" "${ALPINE_MIRROR:-官方}"
  printf "  %-20s %s\n" "GitHub 代理" "${GH_PROXY:-无}"
  printf "  %-20s %s\n" "Docker 镜像源" "${DOCKER_MIRRORS_STR:-官方}"
  printf "  %-20s %s\n" "ACME SSL 默认" "${ACME_SSL_DNS_DEFAULT:-webroot}"
  echo ""
}

# ═══════════════════════════════════════════════
#  配置收集（交互模式）
# ═══════════════════════════════════════════════
collect_github_proxy() {
  local idx
  idx=$(menu_select "GitHub 加速代理" "官方源（直连）" "ghfast.top" "自定义")
  case "$idx" in
    0) GH_PROXY="" ;;
    1) GH_PROXY="https://ghfast.top" ;;
    2) GH_PROXY=$(prompt "GitHub 代理地址 (如 https://ghfast.top)"); GH_PROXY="${GH_PROXY%/}" ;;
  esac
}

collect_docker_mirrors() {
  local sel
  sel=$(menu_multi "Docker 镜像源" "官方" "DaoCloud" "阿里云" "腾讯云" "自定义")
  DOCKER_MIRRORS_STR=""
  for idx in $sel; do
    case "$idx" in
      0) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://registry-1.docker.io" ;;
      1) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://docker.m.daocloud.io" ;;
      2) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://1hdd0hae.mirror.aliyuncs.com" ;;
      3) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://ccr.ccs.tencentyun.com" ;;
      4)
        local m
        m=$(prompt "Docker 镜像源地址")
        if [[ -n "$m" ]]; then DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}${m}"; fi
        ;;
    esac
  done
}

collect_alpine_mirror() {
  local idx
  idx=$(menu_select "PHP Alpine 源" "官方" "清华" "阿里云")
  case "$idx" in
    0) ALPINE_MIRROR="" ;;
    1) ALPINE_MIRROR="mirrors.tuna.tsinghua.edu.cn" ;;
    2) ALPINE_MIRROR="mirrors.aliyun.com" ;;
  esac
}

collect_php_version() {
  local idx
  idx=$(menu_select "PHP 版本" "8.2 (Laravel 12 最低要求)" "8.3 (推荐)" "8.4 (最新)")
  case "$idx" in
    0) PHP_VERSION="8.2" ;;
    1) PHP_VERSION="8.3" ;;
    2) PHP_VERSION="8.4" ;;
  esac
}

collect_php_extensions() {
  local -a all_exts=(pdo_mysql opcache mysqli curl gd xml dom pcntl bcmath sockets mbstring zip exif intl fileinfo redis)
  local sel
  sel=$(menu_multi "PHP 扩展" "${all_exts[@]}")
  PHP_EXTENSIONS=""
  for idx in $sel; do
    PHP_EXTENSIONS+="${PHP_EXTENSIONS:+,}${all_exts[$idx]}"
  done
}

collect_mysql_password() {
  prompt_secret_confirm_into "MySQL root 密码" MYSQL_ROOT_PWD
}

collect_acme_email() {
  ACME_EMAIL=$(prompt "ACME 证书邮箱")
  if [[ ! "$ACME_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then die "邮箱格式无效"; fi
}

collect_acme_ssl_dns_default() {
  info "deploy-site.sh 交互时未指定 --dns 的默认值（仅模式名，不含各云密钥）"
  local v
  v=$(prompt "默认 (webroot/dns_cf/dns_ali/dns_dp/dns_gd/dns_aws/dns_tencent)" "${ACME_SSL_DNS_DEFAULT:-webroot}")
  case "$v" in
    webroot|dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) ACME_SSL_DNS_DEFAULT="$v" ;;
    *) die "无效值: $v" ;;
  esac
}

collect_ssh_config() {
  local idx
  idx=$(menu_select "SSH root 登录策略" "禁止 root 登录" "root 仅密钥登录")
  case "$idx" in
    0) ROOT_LOGIN="no" ;;
    1) ROOT_LOGIN="prohibit-password" ;;
  esac

  idx=$(menu_select "SSH 端口" "默认 22" "自定义")
  if [[ "$idx" = "1" ]]; then
    SSH_PORT=$(prompt "SSH 端口 (1024-65535)")
    if ! [[ "$SSH_PORT" -ge 1024 && "$SSH_PORT" -le 65535 ]] 2>/dev/null; then die "端口范围 1024-65535"; fi
  else
    SSH_PORT=22
  fi
}

collect_lnmp_services() {
  local sel
  sel=$(menu_multi "LNMP 组件" "nginx" "php" "mysql" "redis" "acme.sh")
  LNMP_SERVICES=""
  local -a names=(nginx php mysql redis acme)
  for idx in $sel; do
    LNMP_SERVICES+="${LNMP_SERVICES:+,}${names[$idx]}"
  done
  if [[ ",$LNMP_SERVICES," = *",nginx,"* && ",$LNMP_SERVICES," != *",php,"* ]]; then
    LNMP_SERVICES+=",php"
  fi
}

# ═══════════════════════════════════════════════
#  交互模式
# ═══════════════════════════════════════════════
interactive_setup() {
  clear 2>/dev/null || true
  hr
  info "环境部署管理 v${VERSION}"
  hr
  echo ""

  show_status

  while true; do
    echo ""
    hr
    info "操作菜单"
    hr
    echo ""
    echo "    1) 全新安装（完整向导）"
    echo "    2) 安装单个组件"
    echo "    3) 卸载单个组件"
    echo "    4) 更新配置"
    echo "    5) 查看状态"
    echo "    6) 账户管理（用户/组/密码/SSH 公钥/AllowUsers）"
    echo "    0) 退出"
    echo ""

    local choice
    read -rp "  选择 [0-6]: " choice

    case "$choice" in
      1) _interactive_full_install ;;
      2) _interactive_install_one ;;
      3) _interactive_uninstall_one ;;
      4) _interactive_config ;;
      5) show_status ;;
      6) _interactive_account_mgmt ;;
      0) echo ""; ok "退出"; exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

_interactive_full_install() {
  echo ""
  hr; info "完整安装向导"; hr; echo ""

  local sel
  sel=$(menu_multi "选择要安装的模块" "SSH 安全策略" "等保加固" "BBR" "Oh-My-Zsh" "Firewalld" "Docker" "LNMP" "Wheel 管理员" "saferm 安全删除")

  local sel_ssh=0 sel_cyber=0 sel_bbr=0 sel_zsh=0 sel_fire=0 sel_docker=0 sel_lnmp=0 sel_wheel=0 sel_saferm=0
  for idx in $sel; do
    case "$idx" in
      0) sel_ssh=1 ;; 1) sel_cyber=1 ;; 2) sel_bbr=1 ;; 3) sel_zsh=1 ;;
      4) sel_fire=1 ;; 5) sel_docker=1 ;; 6) sel_lnmp=1 ;; 7) sel_wheel=1 ;;
      8) sel_saferm=1 ;;
    esac
  done

  collect_github_proxy

  if [[ $sel_docker -eq 1 ]]; then collect_docker_mirrors; fi
  if [[ $sel_lnmp -eq 1 ]]; then
    collect_lnmp_services
    if has_service "php"; then collect_alpine_mirror; collect_php_version; collect_php_extensions; fi
    if has_service "mysql"; then collect_mysql_password; fi
    if has_service "acme"; then collect_acme_email; fi
  fi
  if [[ $sel_ssh -eq 1 ]]; then collect_ssh_config; fi

  DEVOPS_USER=$(prompt "devops 部署用户名" "${DEVOPS_USER:-devops}")
  if [[ $sel_wheel -eq 1 ]]; then WHEEL_USER=$(prompt "wheel 管理员用户名" "${WHEEL_USER:-admin}"); fi

  echo ""
  hr; info "配置确认"; hr
  printf "  %-20s %s\n" "GitHub 代理" "${GH_PROXY:-无}"
  printf "  %-20s %s\n" "Devops 用户" "$DEVOPS_USER"
  if [[ $sel_docker -eq 1 ]]; then printf "  %-20s %s\n" "Docker 镜像源" "${DOCKER_MIRRORS_STR:-官方}"; fi
  if [[ $sel_lnmp -eq 1 ]]; then
    printf "  %-20s %s\n" "LNMP 组件" "$LNMP_SERVICES"
    if has_service "php"; then
      printf "  %-20s %s\n" "PHP 版本" "$PHP_VERSION"
      printf "  %-20s %s\n" "PHP 扩展" "$PHP_EXTENSIONS"
      printf "  %-20s %s\n" "Alpine 源" "${ALPINE_MIRROR:-官方}"
    fi
    if has_service "mysql"; then printf "  %-20s %s\n" "MySQL" "已设置"; fi
    if has_service "acme"; then printf "  %-20s %s\n" "ACME 邮箱" "$ACME_EMAIL"; fi
  fi
  if [[ $sel_ssh -eq 1 ]]; then printf "  %-20s %s\n" "SSH" "root=${ROOT_LOGIN}, 端口=${SSH_PORT}"; fi
  if [[ $sel_wheel -eq 1 ]]; then printf "  %-20s %s\n" "Wheel 管理员" "$WHEEL_USER"; fi
  if [[ $sel_saferm -eq 1 ]]; then printf "  %-20s %s\n" "saferm" "安装"; fi
  echo ""

  confirm "确认执行？" "y" || { warn "已取消"; return; }

  run_pkg install -y wget git screen supervisor acl 2>/dev/null || true
  ensure_supervisor_service

  if [[ $sel_bbr -eq 1 ]]; then install_bbr; fi
  if [[ $sel_fire -eq 1 ]]; then install_firewall; fi
  if [[ $sel_cyber -eq 1 ]]; then setup_cyber_users; fi

  setup_devops_user
  if [[ $sel_wheel -eq 1 ]]; then setup_wheel_user; fi

  if [[ $sel_docker -eq 1 ]]; then install_docker; fi
  if [[ $sel_lnmp -eq 1 ]]; then install_lnmp; fi
  if [[ $sel_zsh -eq 1 ]]; then install_zsh; fi
  if [[ $sel_ssh -eq 1 ]]; then install_ssh; fi
  if [[ $sel_saferm -eq 1 ]]; then install_saferm; fi

  conf_save

  echo ""
  hr; ok "全部安装完成"; hr
  show_status
}

_interactive_install_one() {
  local idx
  idx=$(menu_select "选择要安装的组件" \
    "BBR" "Firewalld" "Docker" "Oh-My-Zsh" "SSH 安全" "LNMP (全部)" \
    "LNMP - nginx" "LNMP - php" "LNMP - mysql" "LNMP - redis" "LNMP - acme" \
    "Wheel 管理员" "等保加固" "Devops 用户" "saferm 安全删除")

  case "$idx" in
    0)  install_bbr ;;
    1)  install_firewall ;;
    2)  collect_docker_mirrors; install_docker ;;
    3)  collect_github_proxy; install_zsh ;;
    4)  collect_ssh_config; install_ssh ;;
    5)
      collect_lnmp_services
      if has_service "php"; then collect_alpine_mirror; collect_php_version; collect_php_extensions; fi
      if has_service "mysql"; then collect_mysql_password; fi
      if has_service "acme"; then collect_acme_email; fi
      install_lnmp
      ;;
    6)  LNMP_SERVICES="${LNMP_SERVICES},nginx"; install_lnmp "nginx" ;;
    7)  collect_php_version; collect_php_extensions; collect_alpine_mirror
        LNMP_SERVICES="${LNMP_SERVICES},php"; install_lnmp "php" ;;
    8)  collect_mysql_password; LNMP_SERVICES="${LNMP_SERVICES},mysql"; install_lnmp "mysql" ;;
    9)  LNMP_SERVICES="${LNMP_SERVICES},redis"; install_lnmp "redis" ;;
    10) collect_acme_email; LNMP_SERVICES="${LNMP_SERVICES},acme"; install_lnmp "acme" ;;
    11) WHEEL_USER=$(prompt "wheel 管理员用户名" "${WHEEL_USER:-admin}"); setup_wheel_user ;;
    12) setup_cyber_users ;;
    13) DEVOPS_USER=$(prompt "devops 用户名" "${DEVOPS_USER:-devops}"); setup_devops_user ;;
    14) install_saferm ;;
  esac
  conf_save
}

_interactive_uninstall_one() {
  local idx
  idx=$(menu_select "选择要卸载的组件" \
    "BBR" "Firewalld" "Docker" "Oh-My-Zsh" "SSH (恢复默认)" \
    "LNMP (全部)" "LNMP - nginx" "LNMP - php" "LNMP - mysql" "LNMP - redis" "LNMP - acme" \
    "saferm")

  case "$idx" in
    0)  uninstall_bbr ;;
    1)  uninstall_firewall ;;
    2)  uninstall_docker ;;
    3)  uninstall_zsh ;;
    4)  uninstall_ssh ;;
    5)  uninstall_lnmp "all" ;;
    6)  uninstall_lnmp "nginx" ;;
    7)  uninstall_lnmp "php" ;;
    8)  uninstall_lnmp "mysql" ;;
    9)  uninstall_lnmp "redis" ;;
    10) uninstall_lnmp "acme" ;;
    11) uninstall_saferm ;;
  esac
  conf_save
}

_interactive_config() {
  local idx
  idx=$(menu_select "选择要更新的配置" \
    "GitHub 代理" "Docker 镜像源" "Alpine 源" "PHP 版本" "PHP 扩展" \
    "SSH 配置" "ACME 邮箱" "ACME SSL 默认 (deploy-site)" "Devops 用户")

  case "$idx" in
    0) collect_github_proxy ;;
    1) collect_docker_mirrors; _configure_docker_daemon ;;
    2) collect_alpine_mirror ;;
    3) collect_php_version ;;
    4) collect_php_extensions; if has_service "php" && container_ok "php"; then _install_php_extensions; fi ;;
    5) collect_ssh_config; install_ssh ;;
    6) collect_acme_email ;;
    7) collect_acme_ssl_dns_default ;;
    8) DEVOPS_USER=$(prompt "devops 用户名" "${DEVOPS_USER:-devops}"); setup_devops_user ;;
  esac
  conf_save
  ok "配置已更新"
}

# ═══════════════════════════════════════════════
#  saferm（合并自 saferm.sh，安装到 /usr/local/bin/saferm）
# ═══════════════════════════════════════════════
_install_saferm_rm_alias() {
  mkdir -p /etc/profile.d
  cat > /etc/profile.d/saferm-rm.sh <<'EOF'
# init.sh: 交互 shell 中 rm -> saferm
alias rm='/usr/local/bin/saferm'
EOF
  chmod 644 /etc/profile.d/saferm-rm.sh
  local f
  for f in /etc/bash.bashrc /etc/bashrc /etc/zshrc; do
    [[ -f "$f" ]] || continue
    grep -qF 'saferm init.sh' "$f" && continue
    cat >> "$f" <<'EOF'

# >>> saferm init.sh >>>
[ -f /etc/profile.d/saferm-rm.sh ] && . /etc/profile.d/saferm-rm.sh
# <<< saferm init.sh <<<
EOF
  done
}

# 安装 saferm 后在本 bash 进程内启用 rm 别名（须配合全脚本使用 /bin/rm，避免误走 saferm）
_saferm_apply_to_current_shell() {
  [[ -f /etc/profile.d/saferm-rm.sh ]] || return 0
  shopt -s expand_aliases 2>/dev/null || true
  # shellcheck disable=SC1091
  source /etc/profile.d/saferm-rm.sh
}

_saferm_drop_current_shell_alias() {
  unalias rm 2>/dev/null || true
  shopt -u expand_aliases 2>/dev/null || true
}

install_saferm() {
  hr; info "安装 saferm（/var/trash 安全删除 + 全局 rm 别名）"; echo ""
  cat > /usr/local/bin/saferm <<'SAFEEOF'
#!/bin/bash
##
## saferm.sh
## A script to safely remove files by moving them to GNOME/KDE trash instead of direct deletion.
## Created by Lucas Zhang
## Contact: <lucas@qing-u.com>
##
## Created on  Mon Feb 17 10:10:18 2025 Lucas Zhang
## Last modified Mon Feb 17 12:49:26 2025 Lucas Zhang
##
## Original author: Eemil Lagerspetz
##

version="1.1"

## Configuration
cleanup_days=60     # Remove files from trash after specified days (0 to disable)
auto_cleanup=""     # Enable automatic cleanup on each run (empty to disable)
max_trash_size=1024 # Maximum trash size in MB (0 for unlimited)

## trashbin definitions
trash_dir="/var/trash"

## flags (change these to change default behaviour)
recursive=""    # Recursive directory deletion (disabled by default)
verbose="true"  # Verbose output for better user experience
force=""        # Special file deletion protection (disabled by default)
unsafe=""       # Safe deletion mode by default
no_log=""       # Enable logging by default
cleanup_only="" # Normal operation mode by default

## possible flags (recursive, verbose, force, unsafe)
# don't touch this unless you want to create/destroy flags
flaglist="r v f u q n c"

# Colors
blue='\e[1;34m'
red='\e[1;31m'
norm='\e[0m'

trash_dev() { stat -c '%d' "$1" 2>/dev/null || echo ""; }

if [ ! -d "${trash_dir}" ]; then
	sudo mkdir -p "${trash_dir}"
	sudo chmod 1777 "${trash_dir}"
fi
if [ ! -d "${trash_dir}/files" ]; then
	sudo mkdir -p "${trash_dir}/files"
	sudo chmod 1777 "${trash_dir}/files"
fi
if [ ! -d "${trash_dir}/logs" ]; then
	sudo mkdir -p "${trash_dir}/logs"
	sudo chmod 1777 "${trash_dir}/logs"
fi
trash="${trash_dir}/files"


usagemessage() {
	echo -e "This is ${blue}saferm.sh$norm $version with LXDE and Gnome3 detection.
    Features:
    - Prompts for unsafe deletion when cross-filesystem moves are required
    - Supports unsafe deletion mode (regular rm) that bypasses trash
    - Automatically creates trash and trashinfo directories if they don't exist
    - Handles symbolic link deletion
    - Improved user permission handling\n"
	echo -e "Usage: ${blue}/path/to/saferm.sh$norm [${blue}OPTIONS$norm] [$blue--$norm] ${blue}files and directories to remove safely$norm"
	echo -e "${blue}OPTIONS$norm:"
	echo -e "$blue-r$norm      Enable recursive directory removal"
	echo -e "$blue-f$norm      Enable deletion of special files (devices, etc.)"
	echo -e "$blue-u$norm      Enable unsafe mode (bypass trash and delete permanently)"
	echo -e "$blue-v$norm      Enable verbose mode (default in this version)"
	echo -e "$blue-q$norm      Enable quiet mode (opposite of verbose)"
	echo -e "$blue-n$norm      Disable logging to trashinfo"
	echo -e "$blue-a$norm      Enable automatic trash cleanup"
	echo -e "$blue-c$norm      Run trash cleanup only (no file deletion)"
}

trashinfo() {
	bname=$(basename -- "$2")
	fname="${trash_dir}/logs/${bname}.trashinfo"
	cat <<EOF >"${fname}"
[Trash Info]
Path=$1
DeletionDate=$(date +%Y-%m-%dT%H:%M:%S)
EOF
}

setflags() {
	flags_set=""
	for k in $flaglist; do
		if [[ "$1" =~ $k ]]; then
			flags_set="$flags_set $k"
		fi
	done

	for k in $flags_set; do
		if [ "$k" == "v" ]; then
			verbose="true"
		elif [ "$k" == "r" ]; then
			recursive="true"
		elif [ "$k" == "f" ]; then
			force="true"
		elif [ "$k" == "u" ]; then
			unsafe="true"
		elif [ "$k" == "q" ]; then
			unset verbose
		elif [ "$k" == "n" ]; then
			no_log="true"
		elif [ "$k" == "c" ]; then
			cleanup_only="true"
			auto_cleanup="true"
		elif [ "$k" == "a" ]; then
			auto_cleanup="true"
		fi
	done
}

performdelete() {
	# "delete" = move to trash
	if [ -n "$unsafe" ]; then
		if [ -n "$verbose" ]; then echo -e "Deleting $red$1$norm"; fi
		#UNSAFE: permanently remove files.
		rm -rf -- "$1"
	else
		if [ -n "$verbose" ]; then echo -e "Moving $blue$1$norm to $red${trash}$norm"; fi
		# Check if target file exists
		filename=$(basename -- "$1")
		if [ -e "${trash}/${filename}" ]; then
			# If exists, rename target file to filename_timestamp
			timestamp=$(date +%Y%m%d_%H%M%S)
			# Also update original file's trashinfo
			if [ -f "${trash_dir}/logs/${filename}.trashinfo" ]; then
				mv "${trash_dir}/logs/${filename}.trashinfo" "${trash_dir}/logs/${filename}_${timestamp}.trashinfo"
			fi
			mv "${trash}/${filename}" "${trash}/${filename}_${timestamp}"
		fi
		mv -- "$1" "${trash}" # Move new file to trash
	fi
}

askfs() {
	[ ! -e "$1" ] && [ ! -L "$1" ] && return
	if [ "$(trash_dev "$1")" != "$(trash_dev "${trash}")" ]; then
		unset answer
		while true; do
			echo -e "Warning: $blue$1$norm is on a different device than trash. Proceed with unsafe deletion (y/n)?"
			read -r -n 1 answer
			echo
			case $answer in
			[Yy]*)
				unsafe="yes"
				break
				;;
			[Nn]*)
				return
				;;
			*)
				echo "Please enter 'y' for yes or 'n' for no."
				;;
			esac
		done
	fi
}

complain() {
	msg=""
	if [ ! -e "$1" -a ! -L "$1" ]; then # does not exist
		msg="File does not exist:"
	elif [ ! -w "$1" -a ! -L "$1" ]; then # not writable
		msg="File is not writable:"
	elif [ ! -f "$1" -a ! -d "$1" -a -z "$force" ]; then # Special or sth else.
		msg="Is not a regular file or directory (and -f not specified):"
	elif [ -f "$1" ]; then # is a file
		act="true" # operate on files by default
	elif [ -d "$1" -a -n "$recursive" ]; then # is a directory and recursive is enabled
		act="true"
	elif [ -d "$1" -a -z "${recursive}" ]; then
		msg="Is a directory (and -r not specified):"
	else
		# not file or dir. This branch should not be reached.
		msg="No such file or directory:"
	fi
}

asknobackup() {
	unset answer
	while true; do
		echo -e "Error: Unable to move $blue$1$norm to trash. Proceed with unsafe deletion (y/n)?"
		read -r -n 1 answer
		echo
		case $answer in
		[Yy]*)
			unsafe="yes"
			performdelete "$1"
			ret=$?
			break
			;;
		[Nn]*)
			break
			;;
		*)
			echo "Please enter 'y' for yes or 'n' for no."
			;;
		esac
	done
	# Reset temporary unsafe flag
	unset unsafe
}

deletefiles() {
	for k in "$@"; do
		fdesc="$blue$k$norm"
		complain "${k}"
		if [ -n "$msg" ]; then
			echo -e "$msg $fdesc."
		else
			orig_path=$(readlink -f -- "$k" 2>/dev/null || realpath -- "$k" 2>/dev/null || echo "${PWD}/${k#./}")
			if [ -z "$unsafe" ]; then
				askfs "${k}"
			fi
			do_unsafe=""
			[ -n "$unsafe" ] && do_unsafe=1
			performdelete "${k}"
			ret=$?
			if [[ "$answer" == [yY] ]]; then
				unset unsafe
				unset answer
			fi
			if [ ! "$ret" -eq 0 ]; then
				asknobackup "${k}"
			fi
			if [ -z "$no_log" ] && [ "$ret" -eq 0 ] && [ -z "$do_unsafe" ]; then
				trashinfo "${orig_path}" "${k}"
			fi
		fi
	done
}

# Add function to get folder size (in MB)
get_folder_size() {
	local folder="$1"
	local size=$(du -sm "$folder" | cut -f1)
	echo "$size"
}

# Modify cleanup function with space limit cleanup
cleanup_trash() {
	# Skip cleanup if disabled and not explicitly requested
	if { [ "$cleanup_days" -eq 0 ] && [ "$max_trash_size" -eq 0 ]; } || [ -z "$auto_cleanup" ]; then
		return 0
	fi
	if [ -n "$verbose" ]; then
		echo -e "Starting trash cleanup..."
	fi
	# Time-based cleanup
	if [ "$cleanup_days" -gt 0 ]; then
		current_time=$(date +%s)
		expire_time=$((current_time - cleanup_days * 86400))

		find "${trash}" -type f -print0 | while IFS= read -r -d '' file; do
			filename=$(basename "$file")
			trashinfo_file="${trash_dir}/logs/${filename}.trashinfo"

			file_time=$(stat -c %Y "$file")

			if [ $file_time -lt $expire_time ]; then
				if [ -n "$verbose" ]; then
					echo -e "Deleting expired file: ${blue}${filename}${norm}"
				fi
				rm -f "$file"
				[ -f "$trashinfo_file" ] && rm -f "$trashinfo_file"
			fi
		done
	fi

	# Size-based cleanup
	if [ "$max_trash_size" -gt 0 ]; then
		current_size=$(get_folder_size "${trash}")
		if [ "$current_size" -gt "$max_trash_size" ]; then
			if [ -n "$verbose" ]; then
				echo -e "Current trash size: ${blue}${current_size}MB${norm} exceeds limit of ${blue}${max_trash_size}MB${norm}"
				echo -e "Removing oldest files to free up space..."
			fi

			# Get all files sorted by time (oldest first)
			find "${trash}" -type f -printf '%T@ %p\n' | sort -n | while read -r timestamp filepath; do
				filename=$(basename "$filepath")
				trashinfo_file="${trash_dir}/logs/${filename}.trashinfo"

				if [ -n "$verbose" ]; then
					echo -e "Deleting old file: ${blue}${filename}${norm}"
				fi

				rm -f "$filepath"
				[ -f "$trashinfo_file" ] && rm -f "$trashinfo_file"

				# Recheck size
				current_size=$(get_folder_size "${trash}")
				if [ "$current_size" -le "$max_trash_size" ]; then
					if [ -n "$verbose" ]; then
						echo -e "Cleanup complete: Current size ${blue}${current_size}MB${norm} is within limit"
					fi
					break
				fi
			done
		fi
	fi
	if [ -n "$verbose" ]; then
		echo -e "Cleanup process completed"
	fi
}

# find out which flags were given
afteropts="" # boolean for end-of-options reached
for k in "$@"; do
	# if starts with dash and before end of options marker (--)
	if [ "${k:0:1}" == "-" -a -z "$afteropts" ]; then
		if [ "${k:1:2}" == "-" ]; then # if end of options marker
			afteropts="true"
		else # option(s)
			setflags "$k" # set flags
		fi
	else # not starting with dash, or after end-of-opts
		files[++i]="$k"
	fi
done

# Cleanup trash
cleanup_trash

# If cleanup only mode, exit after cleanup
if [ -n "$cleanup_only" ]; then
	exit 0
fi

if [ -z "${files[1]}" ]; then # no parameters?
	usagemessage # tell them how to use this
	exit 0
fi

# do the work
deletefiles "${files[@]}"
SAFEEOF
  chmod 755 /usr/local/bin/saferm
  mkdir -p /var/trash/files /var/trash/logs
  chmod 1777 /var/trash /var/trash/files /var/trash/logs
  _install_saferm_rm_alias
  _saferm_apply_to_current_shell
  ok "已写入 /usr/local/bin/saferm，已创建 /var/trash，并已配置 alias rm -> saferm（本会话已 source）"
}

uninstall_saferm() {
  hr; info "卸载 saferm"; echo ""
  _saferm_drop_current_shell_alias
  /bin/rm -f /usr/local/bin/saferm
  /bin/rm -f /etc/profile.d/saferm-rm.sh
  local f
  for f in /etc/zshrc /etc/bash.bashrc /etc/bashrc; do
    [[ -f "$f" ]] || continue
    sed -i '/# >>> saferm init.sh >>>/,/# <<< saferm init.sh <<</d' "$f"
  done
  ok "已移除 /usr/local/bin/saferm 与 rm 别名配置"
}

# ═══════════════════════════════════════════════
#  CLI 用法
# ═══════════════════════════════════════════════
usage() {
  cat <<EOF
用法: $0 [命令] [选项]

命令:
  (无参数)              交互模式
  status                查看当前状态
  install <组件>        安装指定组件
  uninstall <组件>      卸载指定组件
  account [子命令]      账户/组/AllowUsers（见 account help）

组件:
  bbr         TCP BBR 加速
  firewall    Firewalld 防火墙
  docker      Docker 引擎
  zsh         Oh-My-Zsh
  ssh         SSH 安全策略
  lnmp        LNMP 全部容器
  nginx       Nginx 容器
  php         PHP 容器
  mysql       MySQL 容器
  redis       Redis 容器
  acme        ACME 证书容器
  wheel       Wheel 管理员
  cyber       等保加固
  devops      Devops 部署用户
  saferm      安全删除脚本（/var/trash，安装到 /usr/local/bin/saferm）

安装选项:
  --gh-proxy=URL          GitHub 代理
  --docker-mirrors=URL,.. Docker 镜像源（逗号分隔）
  --alpine-mirror=HOST    Alpine 源
  --php-version=VER       PHP 版本 (8.2|8.3|8.4)
  --php-ext=EXT,...       PHP 扩展（逗号分隔）
  --mysql-pwd=PWD         MySQL root 密码
  --acme-email=EMAIL      ACME 邮箱
  --ssh-port=PORT         SSH 端口
  --root-login=no|key     SSH root 策略
  --devops-user=NAME      Devops 用户名
  --wheel-user=NAME       Wheel 管理员用户名

示例:
  $0                                    # 交互模式
  $0 status                             # 查看状态
  $0 install docker --docker-mirrors=https://docker.m.daocloud.io
  $0 install lnmp --php-version=8.3 --mysql-pwd=secret --acme-email=a@b.com
  $0 install ssh --ssh-port=2222 --root-login=no
  $0 uninstall redis
  $0 account list
  $0 account resync-allow
EOF
}

# ═══════════════════════════════════════════════
#  主函数
# ═══════════════════════════════════════════════
main() {
  if [[ "$(id -u)" -ne 0 ]]; then die "请使用 root 执行"; fi

  conf_load

  local cmd="${1:-}"
  if [[ "$cmd" = "-h" || "$cmd" = "--help" ]]; then usage; exit 0; fi

  if [[ -z "$cmd" ]]; then
    interactive_setup
    exit 0
  fi

  shift

  for arg in "$@"; do
    case "$arg" in
      --gh-proxy=*)       GH_PROXY="${arg#*=}" ;;
      --docker-mirrors=*) DOCKER_MIRRORS_STR="${arg#*=}" ;;
      --alpine-mirror=*)  ALPINE_MIRROR="${arg#*=}" ;;
      --php-version=*)    PHP_VERSION="${arg#*=}" ;;
      --php-ext=*)        PHP_EXTENSIONS="${arg#*=}" ;;
      --mysql-pwd=*)      MYSQL_ROOT_PWD="${arg#*=}" ;;
      --acme-email=*)     ACME_EMAIL="${arg#*=}" ;;
      --ssh-port=*)       SSH_PORT="${arg#*=}" ;;
      --root-login=*)
        local v="${arg#*=}"
        [[ "$v" = "no" ]] && ROOT_LOGIN="no" || ROOT_LOGIN="prohibit-password"
        ;;
      --devops-user=*)    DEVOPS_USER="${arg#*=}" ;;
      --wheel-user=*)     WHEEL_USER="${arg#*=}" ;;
    esac
  done

  case "$cmd" in
    status)
      show_status
      ;;
    install)
      local target="${1:-}"
      if [[ -z "$target" ]]; then usage; die "请指定要安装的组件"; fi
      shift 2>/dev/null || true

      case "$target" in
        bbr)      install_bbr ;;
        firewall) install_firewall ;;
        docker)   install_docker ;;
        zsh)      install_zsh ;;
        ssh)      install_ssh ;;
        lnmp)     install_lnmp ;;
        nginx)    LNMP_SERVICES="${LNMP_SERVICES},nginx"; install_lnmp "nginx" ;;
        php)      LNMP_SERVICES="${LNMP_SERVICES},php";   install_lnmp "php" ;;
        mysql)    LNMP_SERVICES="${LNMP_SERVICES},mysql";  install_lnmp "mysql" ;;
        redis)    LNMP_SERVICES="${LNMP_SERVICES},redis";  install_lnmp "redis" ;;
        acme)     LNMP_SERVICES="${LNMP_SERVICES},acme";   install_lnmp "acme" ;;
        wheel)    setup_wheel_user ;;
        cyber)    setup_cyber_users ;;
        devops)   setup_devops_user ;;
        saferm)   install_saferm ;;
        *)        die "未知组件: $target" ;;
      esac
      conf_save
      ;;
    uninstall)
      local target="${1:-}"
      if [[ -z "$target" ]]; then usage; die "请指定要卸载的组件"; fi

      case "$target" in
        bbr)      uninstall_bbr ;;
        firewall) uninstall_firewall ;;
        docker)   uninstall_docker ;;
        zsh)      uninstall_zsh ;;
        ssh)      uninstall_ssh ;;
        lnmp)     uninstall_lnmp "all" ;;
        nginx)    uninstall_lnmp "nginx" ;;
        php)      uninstall_lnmp "php" ;;
        mysql)    uninstall_lnmp "mysql" ;;
        redis)    uninstall_lnmp "redis" ;;
        acme)     uninstall_lnmp "acme" ;;
        saferm)   uninstall_saferm ;;
        *)        die "未知组件: $target" ;;
      esac
      conf_save
      ;;
    account)
      cmd_account_cli "$@"
      ;;
    *)
      usage
      die "未知命令: $cmd"
      ;;
  esac
}

main "$@"
