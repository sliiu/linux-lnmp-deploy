# shellcheck shell=bash
_collect_github_proxy_custom() {
  while true; do
    prompt "GitHub 代理地址 (如 https://ghfast.top；- 清空)"
    GH_PROXY=$PROMPT_RESULT
    if [[ "$GH_PROXY" = "-" ]]; then GH_PROXY=""; return 0; fi
    if [[ "$GH_PROXY" =~ ^https?://[^[:space:]]+$ ]]; then
      GH_PROXY="${GH_PROXY%/}"; return 0
    fi
    warn "无效 URL，请重新输入（http/https 开头）"
  done
}

collect_github_proxy() {
  echo ""
  info "当前: ${GH_PROXY:-<官方直连>}"
  local idx
  if [[ -n "${GH_PROXY:-}" ]]; then
    menu_select "GitHub 加速代理" \
      "保持当前不变" \
      "官方源（直连）" \
      "ghfast.top（推荐国内）" \
      "自定义"
    idx=$MENU_SELECT_RESULT
    case "$idx" in
      0) return 0 ;;
      1) GH_PROXY="" ;;
      2) GH_PROXY="https://ghfast.top" ;;
      3) _collect_github_proxy_custom ;;
    esac
  else
    menu_select "GitHub 加速代理" \
      "ghfast.top（推荐国内）" \
      "官方源（直连）" \
      "自定义"
    idx=$MENU_SELECT_RESULT
    case "$idx" in
      0) GH_PROXY="https://ghfast.top" ;;
      1) GH_PROXY="" ;;
      2) _collect_github_proxy_custom ;;
    esac
  fi
}

collect_docker_mirrors() {
  local sel
  MENU_MULTI_DEFAULT="2,3"
  menu_multi "Docker 镜像源" "官方" "DaoCloud" "阿里云" "腾讯云" "自定义"
  sel=$MENU_MULTI_RESULT
  DOCKER_MIRRORS_STR=""
  for idx in $sel; do
    case "$idx" in
      0) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://registry-1.docker.io" ;;
      1) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://docker.m.daocloud.io" ;;
      2) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://1hdd0hae.mirror.aliyuncs.com" ;;
      3) DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}https://ccr.ccs.tencentyun.com" ;;
      4)
        local m
        prompt "Docker 镜像源地址"
        m=$PROMPT_RESULT
        if [[ -n "$m" ]]; then DOCKER_MIRRORS_STR+="${DOCKER_MIRRORS_STR:+,}${m}"; fi
        ;;
    esac
  done
}

collect_alpine_mirror() {
  local idx
  menu_select "PHP Alpine 源（当前: ${ALPINE_MIRROR:-官方}）" \
    "阿里云（推荐国内）" "清华" "官方"
  idx=$MENU_SELECT_RESULT
  case "$idx" in
    0) ALPINE_MIRROR="mirrors.aliyun.com" ;;
    1) ALPINE_MIRROR="mirrors.tuna.tsinghua.edu.cn" ;;
    2) ALPINE_MIRROR="" ;;
  esac
}

collect_php_version() {
  local idx
  menu_select "PHP 版本（当前: ${PHP_VERSION:-8.3}，FrankenPHP 仅 8.2–8.5）" \
    "8.3 (推荐)" "8.4" "8.5" "8.2" \
    "自定义主版本（如 8.3）"
  idx=$MENU_SELECT_RESULT
  case "$idx" in
    0) PHP_VERSION="8.3" ;;
    1) PHP_VERSION="8.4" ;;
    2) PHP_VERSION="8.5" ;;
    3) PHP_VERSION="8.2" ;;
    4)
      while true; do
        prompt "主版本号 (X.Y)" "${PHP_VERSION:-8.3}"
        PHP_VERSION=$PROMPT_RESULT
        [[ -z "$PHP_VERSION" ]] && PHP_VERSION="8.3"
        if [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] && _php_franken_ok "$PHP_VERSION"; then break; fi
        warn "无效版本：${PHP_VERSION}（FrankenPHP 仅支持 8.2–8.5）"
      done
      ;;
  esac
}

collect_extra_php_versions() {
  if [[ -z "${EXTRA_PHP_VERSIONS:-}" ]]; then
    confirm "启用额外 PHP 版本（与默认 ${PHP_VERSION} 共存）？" "n" || return 0
  fi
  echo ""
  info "额外 PHP 版本（与默认 ${PHP_VERSION} 共存，每版本独立 FrankenPHP 容器：lnmp-phpNN）"
  info "当前: ${EXTRA_PHP_VERSIONS:-<无>}"
  local -a _cands=(8.2 8.3 8.4 8.5)
  # 过滤已是默认版的项
  local -a _items=() _idx_ver=()
  local _c
  for _c in "${_cands[@]}"; do
    [[ "$_c" = "$PHP_VERSION" ]] && continue
    _items+=("$_c")
    _idx_ver+=("$_c")
  done
  _items+=("不启用 / 清空" "保持当前不变" "手动输入 CSV...")

  local sel
  MENU_MULTI_DEFAULT=keep
  menu_multi "勾选要启用的额外 PHP 版本（同时选「保持当前」会忽略其他勾选）" "${_items[@]}"
  sel=$MENU_MULTI_RESULT

  if [[ -z "$sel" ]]; then
    info "保持原值不变: ${EXTRA_PHP_VERSIONS:-<无>}"
    return 0
  fi

  local _last1=$(( ${#_items[@]} - 1 ))
  local _last2=$(( ${#_items[@]} - 2 ))
  local _last3=$(( ${#_items[@]} - 3 ))

  # 包含「保持当前」→ 直接返回
  for _i in $sel; do
    if [[ "$_i" -eq "$_last2" ]]; then
      info "保持原值不变: ${EXTRA_PHP_VERSIONS:-<无>}"
      return 0
    fi
  done
  # 包含「不启用」→ 清空
  for _i in $sel; do
    if [[ "$_i" -eq "$_last3" ]]; then
      EXTRA_PHP_VERSIONS=""
      info "已清空"
      return 0
    fi
  done
  # 包含「手动输入」→ 走 CSV，校验失败循环重输
  for _i in $sel; do
    if [[ "$_i" -eq "$_last1" ]]; then
      while true; do
        local v
        prompt "EXTRA_PHP_VERSIONS（CSV，例 8.2,8.4；- 清空）" "${EXTRA_PHP_VERSIONS:-}"
        v=$PROMPT_RESULT
        if [[ "$v" = "-" ]]; then EXTRA_PHP_VERSIONS=""; return 0; fi
        v="${v//[[:space:]]/}"
        local out="" one bad=0
        IFS=',' read -ra _vs <<< "$v"
        for one in "${_vs[@]}"; do
          [[ -z "$one" ]] && continue
          if ! [[ "$one" =~ ^[0-9]+\.[0-9]+$ ]] || ! _php_franken_ok "$one"; then
            warn "无效 PHP 版本: $one（FrankenPHP 仅 8.2–8.5），请重新输入整行"
            bad=1; break
          fi
          [[ "$one" = "$PHP_VERSION" ]] && { warn "已是默认 PHP 版本，跳过: $one"; continue; }
          case ",$out," in *",$one,"*) continue ;; esac
          out+="${out:+,}${one}"
        done
        [[ $bad -eq 1 ]] && continue
        EXTRA_PHP_VERSIONS="$out"
        return 0
      done
    fi
  done
  # 普通勾选合并（去重）
  local out=""
  for _i in $sel; do
    [[ "$_i" -ge "${#_idx_ver[@]}" ]] && continue
    local v="${_idx_ver[$_i]}"
    case ",$out," in *",$v,"*) continue ;; esac
    out+="${out:+,}${v}"
  done
  EXTRA_PHP_VERSIONS="$out"
  info "已启用: ${EXTRA_PHP_VERSIONS:-<无>}"
}

collect_php_extensions() {
  local -a all_exts=(pdo_mysql pdo_pgsql opcache mysqli curl gd xml dom pcntl bcmath sockets mbstring zip exif intl fileinfo redis)
  echo ""
  info "当前已选: ${PHP_EXTENSIONS:-<空，默认全选>}"
  local sel
  if [[ -n "${PHP_EXTENSIONS:-}" ]]; then
    MENU_MULTI_DEFAULT=keep
  fi
  menu_multi "PHP 扩展" "${all_exts[@]}"
  sel=$MENU_MULTI_RESULT
  # menu_multi 返回为空 → 仅可能是 items 全部不可解析；按"全选"语义已在内部默认；
  # 这里再做一次防御：用户若手动输入了非数字（如 -），保留当前值
  local out=""
  for idx in $sel; do
    out+="${out:+,}${all_exts[$idx]}"
  done
  if [[ -z "$out" ]]; then
    if [[ -n "$PHP_EXTENSIONS" ]]; then
      info "保持当前不变"
      return 0
    fi
    # 兜底：合理的 Laravel 默认集
    out="pdo_mysql,opcache,mysqli,curl,gd,xml,dom,pcntl,bcmath,sockets,mbstring,zip,exif,intl,fileinfo,redis"
  fi
  PHP_EXTENSIONS="$out"
}

collect_mysql_password() {
  prompt_secret_confirm_into "MySQL root 密码" MYSQL_ROOT_PWD
}

collect_postgres_password() {
  prompt_secret_confirm_into "PostgreSQL 超级用户密码" POSTGRES_PWD
}

collect_acme_email() {
  while true; do
    prompt "ACME 证书邮箱（用于 Let's Encrypt 注册）" "${ACME_EMAIL:-}"
    ACME_EMAIL=$PROMPT_RESULT
    [[ "$ACME_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
    warn "邮箱格式无效：${ACME_EMAIL:-<空>}，请重新输入"
  done
}

collect_acme_ssl_dns_default() {
  info "deploy-site.sh 交互时未指定 --dns 的默认值（仅模式名，不含各云密钥）"
  local _i
  menu_select "默认 SSL 校验方式" \
    "webroot   (HTTP-01；最常见)" \
    "dns_cf    (Cloudflare API Token)" \
    "dns_ali   (阿里云 DNS Ali_Key/Secret)" \
    "dns_dp    (DNSPod DP_Id/DP_Key)" \
    "dns_gd    (GoDaddy)" \
    "dns_aws   (Route53)" \
    "dns_tencent (腾讯云 DNSPod API)"
  _i=$MENU_SELECT_RESULT
  case "$_i" in
    0) ACME_SSL_DNS_DEFAULT="webroot" ;;
    1) ACME_SSL_DNS_DEFAULT="dns_cf" ;;
    2) ACME_SSL_DNS_DEFAULT="dns_ali" ;;
    3) ACME_SSL_DNS_DEFAULT="dns_dp" ;;
    4) ACME_SSL_DNS_DEFAULT="dns_gd" ;;
    5) ACME_SSL_DNS_DEFAULT="dns_aws" ;;
    6) ACME_SSL_DNS_DEFAULT="dns_tencent" ;;
  esac
}

collect_ssh_config() {
  local idx
  menu_select "SSH root 登录策略" "禁止 root 登录（推荐）" "root 仅密钥登录"
  idx=$MENU_SELECT_RESULT
  case "$idx" in
    0) ROOT_LOGIN="no" ;;
    1) ROOT_LOGIN="prohibit-password" ;;
  esac

  menu_select "SSH 端口" "默认 22" "自定义"
  idx=$MENU_SELECT_RESULT
  if [[ "$idx" = "1" ]]; then
    while true; do
      prompt "SSH 端口 (1024-65535)" "${SSH_PORT:-22022}"
      SSH_PORT=$PROMPT_RESULT
      if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )); then
        break
      fi
      warn "端口范围 1024-65535，请重新输入"
    done
  else
    SSH_PORT=22
  fi
}

collect_lnmp_services() {
  local sel
  MENU_MULTI_DEFAULT="1,2,4,5"
  menu_multi "LNMP 组件（Laravel 选 php=FrankenPHP/Caddy；PM2 网关选 caddy + acme，可选 postgres/redis）" "caddy（无 PHP 时的 Web）" "php（FrankenPHP，含 Caddy）" "mysql" "postgresql" "redis" "acme.sh" "phpMyAdmin"
  sel=$MENU_MULTI_RESULT
  LNMP_SERVICES=""
  local -a names=(caddy php mysql postgres redis acme phpmyadmin)
  for idx in $sel; do
    LNMP_SERVICES+="${LNMP_SERVICES:+,}${names[$idx]}"
  done
  if [[ ",$LNMP_SERVICES," = *",php,"* ]]; then
    info "已选 php：对外 Web 为 FrankenPHP（Caddy），无需再选 caddy"
  fi
  if [[ ",$LNMP_SERVICES," != *",php,"* && ",$LNMP_SERVICES," != *",caddy,"* ]]; then
    LNMP_SERVICES="caddy${LNMP_SERVICES:+,${LNMP_SERVICES}}"
    info "未选 php：已自动加入 caddy 作为 Web 入口"
  fi
  if [[ ",$LNMP_SERVICES," = *",phpmyadmin,"* && ",$LNMP_SERVICES," != *",mysql,"* ]]; then
    LNMP_SERVICES+=",mysql"
    info "已自动补充 mysql（phpMyAdmin 后端必需）"
  fi
}

_collect_image() {
  local _varname="$1" _title="$2" _default="$3"; shift 3
  local _cur="${!_varname:-$_default}"
  local -a _options=("保持当前不变（${_cur}）" "$@" "自定义（完整 镜像:TAG）")
  local _last=$(( ${#_options[@]} - 1 ))
  local _idx _val
  menu_select "${_title}（当前: ${_cur}）" "${_options[@]}"
  _idx=$MENU_SELECT_RESULT
  if [[ "$_idx" -eq 0 ]]; then
    return 0
  elif [[ "$_idx" -eq "$_last" ]]; then
    prompt "镜像:TAG" "$_cur"
    _val=$PROMPT_RESULT
    [[ -n "$_val" ]] || _val="$_default"
    printf -v "$_varname" '%s' "$_val"
  else
    _val="${_options[$_idx]}"
    _val="${_val%% (*}"
    _val="${_val%% }"
    printf -v "$_varname" '%s' "$_val"
  fi
}

collect_caddy_image() {
  _collect_image CADDY_IMAGE "Caddy 镜像（无 PHP 时使用）" "${CADDY_IMAGE:-caddy:2-alpine}" \
    "caddy:2-alpine (推荐)" "caddy:2" "caddy:alpine"
}

collect_mysql_image() {
  _collect_image MYSQL_IMAGE "MySQL / MariaDB 镜像" "${MYSQL_IMAGE:-mysql:8.0}" \
    "mysql:8.0 (推荐)" "mysql:8.4" "mysql:lts" "mysql:9" "mysql:9.0" "mariadb:11.4"
}

collect_postgres_image() {
  _collect_image POSTGRES_IMAGE "PostgreSQL 镜像" "${POSTGRES_IMAGE:-postgres:16-alpine}" \
    "postgres:16-alpine (推荐)" "postgres:16" "postgres:15-alpine" "postgres:15" \
    "postgres:14-alpine" "postgres:14" "postgres:17-alpine" "postgres:17"
}

collect_redis_image() {
  _collect_image REDIS_IMAGE "Redis 镜像" "${REDIS_IMAGE:-redis:alpine}" \
    "redis:alpine (推荐)" "redis:7-alpine" "redis:7.4-alpine" "redis:8-alpine" "redis:8.2-alpine"
}

collect_acme_image() {
  _collect_image ACME_IMAGE "acme.sh 镜像" "${ACME_IMAGE:-neilpang/acme.sh:latest}" \
    "neilpang/acme.sh:latest (推荐)" "neilpang/acme.sh:3.0.6" "neilpang/acme.sh:3.0.7"
}

collect_phpmyadmin_image() {
  _collect_image PHPMYADMIN_IMAGE "phpMyAdmin 镜像" "${PHPMYADMIN_IMAGE:-phpmyadmin:latest}" \
    "phpmyadmin:latest (推荐)" "phpmyadmin:apache" "phpmyadmin:fpm-alpine" "phpmyadmin:5.2" "phpmyadmin:5"
}

collect_phpmyadmin_listen() {
  echo ""
  info "当前: ${PHPMYADMIN_BIND:-127.0.0.1}:${PHPMYADMIN_PORT:-8080}"
  local _i
  menu_select "phpMyAdmin 监听地址（建议仅本机+SSH 隧道，避免直接暴露公网）" \
    "保持当前（${PHPMYADMIN_BIND:-127.0.0.1}:${PHPMYADMIN_PORT:-8080}）" \
    "127.0.0.1:8080（仅本机/SSH 隧道，推荐）" \
    "0.0.0.0:8080（公网可达；务必用防火墙限制源 IP）" \
    "自定义"
  _i=$MENU_SELECT_RESULT
  case "$_i" in
    0) return 0 ;;
    1) PHPMYADMIN_BIND="127.0.0.1"; PHPMYADMIN_PORT="8080" ;;
    2) PHPMYADMIN_BIND="0.0.0.0";   PHPMYADMIN_PORT="8080" ;;
    3)
      prompt "监听地址" "${PHPMYADMIN_BIND:-127.0.0.1}"
      PHPMYADMIN_BIND=$PROMPT_RESULT
      while true; do
        prompt "监听端口 (1-65535)" "${PHPMYADMIN_PORT:-8080}"
        PHPMYADMIN_PORT=$PROMPT_RESULT
        if [[ "$PHPMYADMIN_PORT" =~ ^[0-9]+$ ]] && (( PHPMYADMIN_PORT > 0 && PHPMYADMIN_PORT < 65536 )); then break; fi
        warn "无效端口"
      done
      ;;
  esac
}

collect_lnmp_stack_images() {
  has_service "caddy" && ! has_service "php" && collect_caddy_image
  has_service "mysql" && collect_mysql_image
  has_service "postgres" && collect_postgres_image
  has_service "redis" && collect_redis_image
  has_service "acme" && collect_acme_image
  if has_service "phpmyadmin"; then collect_phpmyadmin_image; collect_phpmyadmin_listen; fi
}

# PM2 网关（SlimPPT api 等）：反代 + 数据库 + 缓存 + 证书，不含 php/mysql
collect_lnmp_services_pm2_gateway() {
  LNMP_SERVICES="caddy,postgres,redis,acme"
  info "PM2 网关栈：caddy + postgres + redis + acme（无 php / mysql）"
}

_apply_quiet_network_defaults() {
  [[ -n "${GH_PROXY:-}" ]] || GH_PROXY="https://ghfast.top"
  [[ -n "${DOCKER_MIRRORS_STR:-}" ]] || DOCKER_MIRRORS_STR="https://docker.m.daocloud.io,https://1hdd0hae.mirror.aliyuncs.com"
}

_interactive_pm2_gateway_install() {
  echo ""
  hr; info "PM2 网关栈（最小安装）"; hr; echo ""
  info "将安装：Docker → devops 用户 → caddy + postgres + redis + acme → PM2"
  info "不含 PHP / MySQL（deploy-site --type=pm2 反代宿主机 Node 进程）"
  echo ""

  _apply_quiet_network_defaults
  DEVOPS_USER="${DEVOPS_USER:-devops}"
  NODE_VERSION="${NODE_VERSION:-22}"

  prompt "devops 用户名" "${DEVOPS_USER:-devops}"
  DEVOPS_USER=$PROMPT_RESULT
  collect_github_proxy
  collect_docker_mirrors
  collect_node_version
  collect_lnmp_services_pm2_gateway
  collect_lnmp_stack_images
  collect_postgres_password
  collect_acme_email
  collect_acme_ssl_dns_default

  echo ""
  hr; info "配置确认"; hr
  printf "  %-20s %s\n" "GitHub 代理" "${GH_PROXY:-无}"
  printf "  %-20s %s\n" "Devops 用户" "$DEVOPS_USER"
  printf "  %-20s %s\n" "Docker 镜像源" "${DOCKER_MIRRORS_STR:-官方}"
  printf "  %-20s %s\n" "LNMP 组件" "$LNMP_SERVICES"
  printf "  %-20s %s\n" "Caddy 镜像" "$CADDY_IMAGE"
  printf "  %-20s %s\n" "PostgreSQL 镜像" "$POSTGRES_IMAGE"
  printf "  %-20s %s\n" "Redis 镜像" "$REDIS_IMAGE"
  printf "  %-20s %s\n" "ACME 镜像" "$ACME_IMAGE"
  printf "  %-20s %s\n" "Node.js" "${NODE_VERSION:-22}"
  printf "  %-20s %s\n" "ACME 邮箱" "$ACME_EMAIL"
  printf "  %-20s %s\n" "ACME SSL 默认" "${ACME_SSL_DNS_DEFAULT:-webroot}"
  echo ""
  confirm "确认执行？" "y" || { warn "已取消"; return; }

  run_pkg install -y wget git screen supervisor acl 2>/dev/null || true
  ensure_supervisor_service

  setup_devops_user
  if ! is_docker_ok; then install_docker; fi
  install_lnmp
  install_pm2

  conf_save
  echo ""
  hr; ok "PM2 网关栈安装完成"; hr
  show_status
  info "下一步: deploy-site.sh add --type=pm2 --domain=api.example.com ..."
}

# ═══════════════════════════════════════════════
#  交互模式
# ═══════════════════════════════════════════════
interactive_setup() {
  conf_save
  conf_load

  while true; do
    clear 2>/dev/null || true
    hr
    info "环境部署管理 v${VERSION}"
    hr
    local _i
    menu_select "请选择操作" \
      "查看状态" \
      "PM2 网关栈（Docker + caddy + postgres + redis + acme + PM2）" \
      "全新安装（完整向导）" \
      "一键重装 LNMP（沿用上次配置，跳过所有问询）" \
      "更新配置（含 PHP 多版本、镜像源、SSH 等）" \
      "安装单个组件" \
      "账户管理（用户/组/密码/SSH 公钥/AllowUsers）" \
      "卸载单个组件" \
      "退出"
    _i=$MENU_SELECT_RESULT
    echo ""
    case "$_i" in
      0) show_status ;;
      1) _interactive_pm2_gateway_install ;;
      2) _interactive_full_install ;;
      3) _interactive_oneclick_reinstall ;;
      4) _interactive_config ;;
      5) _interactive_install_one ;;
      6) _interactive_account_mgmt ;;
      7) _interactive_uninstall_one ;;
      8) echo ""; ok "退出"; exit 0 ;;
    esac
    echo ""
    _ui_wait_enter
  done
}

_interactive_oneclick_reinstall() {
  echo ""
  hr; info "一键重装 LNMP（沿用上次配置）"; hr; echo ""
  if [[ -z "${LNMP_SERVICES:-}" ]]; then
    warn "未检测到上次 LNMP 配置（${CONF_FILE}），请先走「全新安装」或「安装单个组件」"
    return
  fi
  printf "  %-20s %s\n" "Devops 用户" "$DEVOPS_USER"
  printf "  %-20s %s\n" "LNMP 组件" "$LNMP_SERVICES"
  if has_service "caddy" && ! has_service "php"; then printf "  %-20s %s\n" "Caddy 镜像" "$CADDY_IMAGE"; fi
  if has_service "mysql"; then printf "  %-20s %s\n" "MySQL 镜像" "$MYSQL_IMAGE"; fi
  if has_service "postgres"; then printf "  %-20s %s\n" "PostgreSQL 镜像" "$POSTGRES_IMAGE"; fi
  if has_service "redis"; then printf "  %-20s %s\n" "Redis 镜像" "$REDIS_IMAGE"; fi
  if has_service "acme"; then printf "  %-20s %s\n" "ACME 镜像" "$ACME_IMAGE"
                              printf "  %-20s %s\n" "ACME 邮箱" "${ACME_EMAIL:-<未设置>}"; fi
  if has_service "phpmyadmin"; then printf "  %-20s %s\n" "phpMyAdmin 镜像" "$PHPMYADMIN_IMAGE"
                                    printf "  %-20s %s\n" "phpMyAdmin 监听" "${PHPMYADMIN_BIND}:${PHPMYADMIN_PORT}"; fi
  if has_service "php"; then
    printf "  %-20s %s\n" "PHP 默认版本" "${PHP_VERSION:-<未设置>}"
    printf "  %-20s %s\n" "PHP 额外版本" "${EXTRA_PHP_VERSIONS:-<无>}"
    printf "  %-20s %s\n" "PHP 扩展" "${PHP_EXTENSIONS:-<未设置>}"
    printf "  %-20s %s\n" "Alpine 源" "${ALPINE_MIRROR:-官方}"
  fi
  echo ""
  confirm "确认按上述配置执行 install_lnmp？" "y" || { warn "已取消"; return; }
  install_lnmp
  ok "一键重装完成"
}

_interactive_full_install() {
  _ui_tty ""
  _ui_tty "══════════════════════════════════════════════"
  _ui_tty "  完整安装向导"
  _ui_tty "══════════════════════════════════════════════"
  _ui_tty ""

  local sel
  MENU_MULTI_DEFAULT="2,3"
  menu_multi "选择要安装的模块（回车=Docker + FrankenPHP 栈）" \
    "等保加固 (cyber 三权用户)" \
    "Docker (FrankenPHP 栈前置)" \
    "FrankenPHP 栈 (Caddy + php + mysql + redis + acme)" \
    "PM2 (Node.js + pm2，deploy-site 用)" \
    "SSH 安全策略 (改端口/禁 root)" \
    "Firewalld (防火墙)" \
    "BBR (TCP 拥塞)" \
    "Oh-My-Zsh" \
    "Wheel 管理员" \
    "saferm 安全删除"
  sel=$MENU_MULTI_RESULT
  if [[ -z "$sel" ]]; then
    warn "未选择任何模块"
    return
  fi

  local sel_ssh=0 sel_cyber=0 sel_bbr=0 sel_zsh=0 sel_fire=0 sel_docker=0 sel_lnmp=0 sel_pm2=0 sel_wheel=0 sel_saferm=0
  for idx in $sel; do
    case "$idx" in
      0) sel_cyber=1 ;; 1) sel_docker=1 ;; 2) sel_lnmp=1 ;; 3) sel_pm2=1 ;;
      4) sel_ssh=1 ;;  5) sel_fire=1 ;;  6) sel_bbr=1 ;;  7) sel_zsh=1 ;;
      8) sel_wheel=1 ;; 9) sel_saferm=1 ;;
    esac
  done

  # LNMP 选了但 Docker 没勾 → 自动补，避免 install_lnmp 时 docker 不在
  if [[ $sel_lnmp -eq 1 && $sel_docker -eq 0 ]] && ! is_docker_ok; then
    info "已自动补充 Docker（FrankenPHP 栈依赖）"
    sel_docker=1
  fi

  # ── 收集顺序：等保加固(cyber) → 账号 → 网络/源 → 基础设施(docker) → 应用(lnmp) → 系统加固(ssh) ──
  _apply_quiet_network_defaults
  DEVOPS_USER="${DEVOPS_USER:-devops}"
  PHP_VERSION="${PHP_VERSION:-8.3}"
  NODE_VERSION="${NODE_VERSION:-22}"

  # 0) 等保加固前置（cyber 内部含交互+创建账号；ordinary 可作为 devops 默认值）
  if [[ $sel_cyber -eq 1 ]]; then setup_cyber_users skip-devops; fi

  if [[ $sel_cyber -eq 0 ]]; then
    prompt "devops 用户名" "${DEVOPS_USER:-devops}"
    DEVOPS_USER=$PROMPT_RESULT
  fi

  if [[ $sel_wheel -eq 1 ]]; then
    prompt "wheel 管理员用户名" "${WHEEL_USER:-admin}"
    WHEEL_USER=$PROMPT_RESULT
  fi

  if [[ $sel_docker -eq 1 || $sel_pm2 -eq 1 || $sel_zsh -eq 1 ]]; then
    collect_github_proxy
  fi
  if [[ $sel_docker -eq 1 ]]; then collect_docker_mirrors; fi

  if [[ $sel_lnmp -eq 1 ]]; then
    collect_lnmp_services
    if has_service "php"; then
      collect_php_version
      collect_extra_php_versions
      collect_php_extensions
      collect_alpine_mirror
    fi
    collect_lnmp_stack_images
    if has_service "mysql"; then collect_mysql_password; fi
    if has_service "postgres"; then collect_postgres_password; fi
    if has_service "acme"; then
      collect_acme_email
      collect_acme_ssl_dns_default
    fi
  fi

  if [[ $sel_pm2 -eq 1 ]]; then collect_node_version; fi

  # 5) SSH 安全策略（最后问：会改 sshd 配置，留给末尾减少变更冲突）
  if [[ $sel_ssh -eq 1 ]]; then collect_ssh_config; fi

  echo ""
  hr; info "配置确认"; hr
  printf "  %-20s %s\n" "GitHub 代理" "${GH_PROXY:-无}"
  printf "  %-20s %s\n" "Devops 用户" "$DEVOPS_USER"
  if [[ $sel_docker -eq 1 ]]; then printf "  %-20s %s\n" "Docker 镜像源" "${DOCKER_MIRRORS_STR:-官方}"; fi
  if [[ $sel_lnmp -eq 1 ]]; then
    printf "  %-20s %s\n" "LNMP 组件" "$LNMP_SERVICES"
    if has_service "caddy" && ! has_service "php"; then printf "  %-20s %s\n" "Caddy 镜像" "$CADDY_IMAGE"; fi
    if has_service "mysql"; then printf "  %-20s %s\n" "MySQL 镜像" "$MYSQL_IMAGE"; fi
    if has_service "postgres"; then printf "  %-20s %s\n" "PostgreSQL 镜像" "$POSTGRES_IMAGE"; fi
    if has_service "redis"; then printf "  %-20s %s\n" "Redis 镜像" "$REDIS_IMAGE"; fi
    if has_service "acme"; then printf "  %-20s %s\n" "ACME 镜像" "$ACME_IMAGE"; fi
    if has_service "phpmyadmin"; then
      printf "  %-20s %s\n" "phpMyAdmin 镜像" "$PHPMYADMIN_IMAGE"
      printf "  %-20s %s\n" "phpMyAdmin 监听" "${PHPMYADMIN_BIND}:${PHPMYADMIN_PORT}"
    fi
    if has_service "php"; then
      printf "  %-20s %s\n" "PHP 版本（默认）" "$PHP_VERSION"
      printf "  %-20s %s\n" "PHP 版本（额外）" "${EXTRA_PHP_VERSIONS:-无}"
      printf "  %-20s %s\n" "PHP 扩展" "$PHP_EXTENSIONS"
      printf "  %-20s %s\n" "Alpine 源" "${ALPINE_MIRROR:-官方}"
    fi
    if has_service "mysql"; then printf "  %-20s %s\n" "MySQL" "已设置"; fi
    if has_service "postgres"; then printf "  %-20s %s\n" "PostgreSQL" "已设置"; fi
    if has_service "acme"; then
      printf "  %-20s %s\n" "ACME 邮箱" "$ACME_EMAIL"
      printf "  %-20s %s\n" "ACME SSL 默认" "${ACME_SSL_DNS_DEFAULT:-webroot}"
    fi
  fi
  if [[ $sel_ssh -eq 1 ]]; then printf "  %-20s %s\n" "SSH" "root=${ROOT_LOGIN}, 端口=${SSH_PORT}"; fi
  if [[ $sel_wheel -eq 1 ]]; then printf "  %-20s %s\n" "Wheel 管理员" "$WHEEL_USER"; fi
  if [[ $sel_pm2 -eq 1 ]]; then printf "  %-20s %s\n" "Node.js" "${NODE_VERSION:-22}"; fi
  if [[ $sel_saferm -eq 1 ]]; then printf "  %-20s %s\n" "saferm" "安装"; fi
  echo ""

  confirm "确认执行？" "y" || { warn "已取消"; return; }

  run_pkg install -y wget git screen supervisor acl 2>/dev/null || true
  ensure_supervisor_service

  if [[ $sel_bbr -eq 1 ]]; then install_bbr; fi
  if [[ $sel_fire -eq 1 ]]; then install_firewall; fi

  setup_devops_user
  if [[ $sel_wheel -eq 1 ]]; then setup_wheel_user; fi

  if [[ $sel_docker -eq 1 ]]; then install_docker; fi
  if [[ $sel_lnmp -eq 1 ]]; then install_lnmp; fi
  if [[ $sel_pm2 -eq 1 ]]; then install_pm2; fi
  if [[ $sel_zsh -eq 1 ]]; then install_zsh; fi
  if [[ $sel_ssh -eq 1 ]]; then install_ssh; fi
  if [[ $sel_saferm -eq 1 ]]; then install_saferm; fi

  conf_save

  echo ""
  hr; ok "全部安装完成"; hr
  show_status
}

_interactive_install_one() {
  while true; do
    local idx
    menu_select "选择要安装的组件（按高频排序）" \
      "LNMP (全部，推荐)" \
      "LNMP - php" \
      "LNMP - mysql" \
      "LNMP - postgresql" \
      "LNMP - redis" \
      "LNMP - caddy" \
      "LNMP - acme" \
      "LNMP - phpMyAdmin" \
      "Docker" \
      "PM2 (Node.js)" \
      "Devops 用户" \
      "Wheel 管理员" \
      "SSH 安全策略" \
      "Firewalld" \
      "BBR" \
      "Oh-My-Zsh" \
      "saferm 安全删除" \
      "等保加固" \
      "返回主菜单"
    idx=$MENU_SELECT_RESULT

    case "$idx" in
      0)
        DEVOPS_USER="${DEVOPS_USER:-devops}"
        collect_lnmp_services
        PHP_VERSION="${PHP_VERSION:-8.3}"
        if has_service "php"; then
          collect_php_version
          collect_extra_php_versions
          collect_php_extensions
          collect_alpine_mirror
        fi
        collect_lnmp_stack_images
        if has_service "mysql"; then collect_mysql_password; fi
        if has_service "postgres"; then collect_postgres_password; fi
        if has_service "acme"; then
          collect_acme_email
          collect_acme_ssl_dns_default
        fi
        install_lnmp
        ;;
      1)  collect_php_version; collect_extra_php_versions; collect_php_extensions; collect_alpine_mirror
          LNMP_SERVICES="${LNMP_SERVICES},php"; install_lnmp "php" ;;
      2)  collect_mysql_image; collect_mysql_password; LNMP_SERVICES="${LNMP_SERVICES},mysql"; install_lnmp "mysql" ;;
      3)  collect_postgres_image; collect_postgres_password; LNMP_SERVICES="${LNMP_SERVICES},postgres"; install_lnmp "postgres" ;;
      4)  collect_redis_image; LNMP_SERVICES="${LNMP_SERVICES},redis"; install_lnmp "redis" ;;
      5)  collect_caddy_image; LNMP_SERVICES="${LNMP_SERVICES},caddy"; install_lnmp "caddy" ;;
      6)  collect_acme_image; collect_acme_email; collect_acme_ssl_dns_default; LNMP_SERVICES="${LNMP_SERVICES},acme"; install_lnmp "acme" ;;
      7)  collect_phpmyadmin_image; collect_phpmyadmin_listen; LNMP_SERVICES="${LNMP_SERVICES},phpmyadmin"; install_lnmp "phpmyadmin" ;;
      8)  collect_github_proxy; collect_docker_mirrors; install_docker ;;
      9)  prompt "devops 用户名" "${DEVOPS_USER:-devops}"; DEVOPS_USER=$PROMPT_RESULT; collect_github_proxy; collect_node_version; install_pm2 ;;
      10) prompt "devops 用户名" "${DEVOPS_USER:-devops}"; DEVOPS_USER=$PROMPT_RESULT; setup_devops_user ;;
      11) prompt "wheel 管理员用户名" "${WHEEL_USER:-admin}"; WHEEL_USER=$PROMPT_RESULT; setup_wheel_user ;;
      12) collect_ssh_config; install_ssh ;;
      13) install_firewall ;;
      14) install_bbr ;;
      15) collect_github_proxy; install_zsh ;;
      16) install_saferm ;;
      17) setup_cyber_users ;;
      18) return 0 ;;
    esac
    conf_save
    echo ""
  done
}

_interactive_uninstall_one() {
  while true; do
    local -a _labels=() _actions=()
    local _ev idx component _danger_msg=""

    _labels+=("LNMP - php（默认 lnmp-php；会一并停止所有额外 PHP）")
    _actions+=(php)
    while IFS= read -r _ev; do
      [[ -z "$_ev" ]] && continue
      _labels+=("LNMP - php ${_ev}（仅 lnmp-php$(_php_ver_no_dot "$_ev")）")
      _actions+=("php-${_ev}")
    done < <(_php_extra_list)

    _labels+=(
      "LNMP - mysql" "LNMP - postgresql" "LNMP - redis" "LNMP - caddy" "LNMP - acme" "LNMP - phpMyAdmin"
      "LNMP (全部)" "Docker" "PM2 (Node.js)" "SSH (恢复默认)" "Firewalld" "BBR" "Oh-My-Zsh" "saferm"
      "返回主菜单"
    )
    _actions+=(mysql postgres redis caddy acme phpmyadmin all docker pm2 ssh firewall bbr zsh saferm back)

    menu_select "选择要卸载的组件（高危操作前会二次确认）" "${_labels[@]}"
    idx=$MENU_SELECT_RESULT
    component="${_actions[$idx]}"
    [[ "$component" = "back" ]] && return 0

    case "$component" in
      php) _danger_msg="将停止 lnmp-php 与所有 lnmp-phpNN 额外容器，并清空 EXTRA_PHP_VERSIONS" ;;
      php-*)
        _ev="${component#php-}"
        _danger_msg="将停止 lnmp-php$(_php_ver_no_dot "$_ev")，从 EXTRA_PHP_VERSIONS 移除 ${_ev}，并重建 compose"
        ;;
      mysql)      _danger_msg="将停止并移除 lnmp-mysql 容器（数据卷可保留）" ;;
      postgres)   _danger_msg="将停止并移除 lnmp-postgres 容器（数据卷可保留）" ;;
      redis)      _danger_msg="将停止并移除 lnmp-redis 容器" ;;
      caddy)      _danger_msg="将停止并移除 lnmp-caddy 容器" ;;
      acme)       _danger_msg="将停止并移除 lnmp-acme 容器" ;;
      phpmyadmin) _danger_msg="将停止并移除 lnmp-phpmyadmin 容器" ;;
      all)        _danger_msg="将停止 LNMP 全部容器、删除 compose 文件、可选删除 ${DATA_DIR}" ;;
      docker)     _danger_msg="将卸载 Docker（不删除 /var/lib/docker，请按提示确认）" ;;
      pm2)        _danger_msg="将卸载 PM2 / fnm / Node.js（devops 用户）" ;;
      ssh)        _danger_msg="将恢复 sshd 默认（root/22 端口）" ;;
      firewall)   _danger_msg="将停止并禁用 firewalld" ;;
      bbr)        _danger_msg="将关闭 BBR" ;;
      zsh)        _danger_msg="将卸载 Oh-My-Zsh" ;;
      saferm)     _danger_msg="将卸载 saferm" ;;
    esac
    if [[ -n "$_danger_msg" ]]; then
      warn "$_danger_msg"
      confirm "确认继续？" "n" || { info "已取消"; echo ""; continue; }
    fi

    case "$component" in
      php|php-*|mysql|postgres|redis|caddy|acme|phpmyadmin|all) uninstall_lnmp "$component" ;;
      docker)   uninstall_docker ;;
      pm2)      uninstall_pm2 ;;
      ssh)      uninstall_ssh ;;
      firewall) uninstall_firewall ;;
      bbr)      uninstall_bbr ;;
      zsh)      uninstall_zsh ;;
      saferm)   uninstall_saferm ;;
    esac
    conf_save
    echo ""
  done
}

_interactive_config() {
  while true; do
    local idx
    menu_select "选择要更新的配置（按高频排序）" \
      "PHP 版本（额外，多版本共存）" \
      "PHP 扩展" \
      "PHP 版本（默认）" \
      "LNMP 组件镜像" \
      "Docker 镜像源" \
      "Alpine 源" \
      "GitHub 代理" \
      "SSH 配置" \
      "ACME 邮箱" \
      "ACME SSL 默认 (deploy-site)" \
      "Node.js 版本 (PM2)" \
      "Devops 用户" \
      "返回主菜单"
    idx=$MENU_SELECT_RESULT

    case "$idx" in
      0) collect_extra_php_versions
         if [[ -f "$COMPOSE_FILE" ]] && is_docker_ok && has_service "php"; then
           update_lnmp
         else
           ok "已写入配置（安装 LNMP 后生效；可在主菜单 → 安装单个组件 → LNMP - php 重建）"
         fi
         ;;
      1) collect_php_extensions
         if has_service "php" && container_ok "lnmp-php"; then
           _install_php_extensions
         else
           ok "已写入配置（lnmp-php 未运行，下次启动后通过此菜单或 LNMP - php 重建生效）"
         fi
         ;;
      2) collect_php_version
         if [[ -f "$COMPOSE_FILE" ]] && is_docker_ok && has_service "php"; then
           warn "默认 PHP 版本变更需重建 lnmp-php 容器（用同一菜单 → LNMP - php 单组件安装）"
         fi
         ;;
      3) collect_lnmp_stack_images; if [[ -f "$COMPOSE_FILE" ]] && is_docker_ok; then update_lnmp; else ok "已写入配置，安装 LNMP 后生效"; fi ;;
      4) collect_docker_mirrors
         if is_docker_ok; then _configure_docker_daemon; else ok "已写入配置（Docker 未安装，安装后自动应用）"; fi
         ;;
      5) collect_alpine_mirror; ok "已写入配置（PHP 扩展安装时生效）" ;;
      6) collect_github_proxy ;;
      7) collect_ssh_config; install_ssh ;;
      8) collect_acme_email
         if container_ok "lnmp-acme"; then
           info "更新 acme.sh 注册账户邮箱..."
           docker exec lnmp-acme acme.sh --register-account -m "$ACME_EMAIL" 2>/dev/null \
             && ok "邮箱已更新" || warn "更新失败（首次签证书时也会自动注册）"
         fi
         ;;
      9) collect_acme_ssl_dns_default ;;
      10) collect_node_version; if is_pm2_ok; then install_pm2; else ok "已写入配置（执行「安装单个组件 → PM2」后生效）"; fi ;;
      11) prompt "devops 用户名" "${DEVOPS_USER:-devops}"; DEVOPS_USER=$PROMPT_RESULT; setup_devops_user ;;
      12) return 0 ;;
    esac
    conf_save
    ok "配置已更新"
    echo ""
  done
}

