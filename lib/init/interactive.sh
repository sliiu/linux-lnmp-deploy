# shellcheck shell=bash
collect_github_proxy() {
  echo ""
  info "当前: ${GH_PROXY:-<官方直连>}"
  local idx
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
    3)
      while true; do
        prompt "GitHub 代理地址 (如 https://ghfast.top；- 清空)"
        GH_PROXY=$PROMPT_RESULT
        if [[ "$GH_PROXY" = "-" ]]; then GH_PROXY=""; return 0; fi
        if [[ "$GH_PROXY" =~ ^https?://[^[:space:]]+$ ]]; then
          GH_PROXY="${GH_PROXY%/}"; return 0
        fi
        warn "无效 URL，请重新输入（http/https 开头）"
      done
      ;;
  esac
}

collect_docker_mirrors() {
  local sel
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
  menu_select "PHP Alpine 源" "官方" "清华" "阿里云"
  idx=$MENU_SELECT_RESULT
  case "$idx" in
    0) ALPINE_MIRROR="" ;;
    1) ALPINE_MIRROR="mirrors.tuna.tsinghua.edu.cn" ;;
    2) ALPINE_MIRROR="mirrors.aliyun.com" ;;
  esac
}

collect_php_version() {
  local idx
  menu_select "PHP 版本（镜像 php:主版本-fpm-alpine）" \
    "8.1" "8.2 (Laravel 12 最低)" "8.3 (推荐)" "8.4" "8.5" \
    "自定义主版本（如 8.3）"
  idx=$MENU_SELECT_RESULT
  case "$idx" in
    0) PHP_VERSION="8.1" ;;
    1) PHP_VERSION="8.2" ;;
    2) PHP_VERSION="8.3" ;;
    3) PHP_VERSION="8.4" ;;
    4) PHP_VERSION="8.5" ;;
    5)
      while true; do
        prompt "主版本号 (X.Y)" "${PHP_VERSION:-8.3}"
        PHP_VERSION=$PROMPT_RESULT
        [[ -z "$PHP_VERSION" ]] && PHP_VERSION="8.3"
        [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] && break
        warn "无效的 PHP 版本格式：${PHP_VERSION}（应为 8.3 / 7.4 形式），请重新输入"
      done
      ;;
  esac
}

collect_extra_php_versions() {
  echo ""
  info "额外 PHP 版本（与默认 ${PHP_VERSION} 共存，每版本独立 fpm 容器：lnmp-phpNN，与 compose 一致）"
  info "当前: ${EXTRA_PHP_VERSIONS:-<无>}"
  local -a _cands=(5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4)
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
  menu_multi "勾选要启用的额外 PHP 版本（同时选「保持当前」会忽略其他勾选）" "${_items[@]}"
  sel=$MENU_MULTI_RESULT

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
        prompt "EXTRA_PHP_VERSIONS（CSV，例 7.4,8.2；- 清空）" "${EXTRA_PHP_VERSIONS:-}"
        v=$PROMPT_RESULT
        if [[ "$v" = "-" ]]; then EXTRA_PHP_VERSIONS=""; return 0; fi
        v="${v//[[:space:]]/}"
        local out="" one bad=0
        IFS=',' read -ra _vs <<< "$v"
        for one in "${_vs[@]}"; do
          [[ -z "$one" ]] && continue
          if ! [[ "$one" =~ ^[0-9]+\.[0-9]+$ ]]; then
            warn "无效 PHP 版本: $one（应为 7.4 / 8.2 形式），请重新输入整行"
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
  local -a all_exts=(pdo_mysql opcache mysqli curl gd xml dom pcntl bcmath sockets mbstring zip exif intl fileinfo redis)
  echo ""
  info "当前已选: ${PHP_EXTENSIONS:-<空，默认全选>}"
  local sel
  menu_multi "PHP 扩展（回车=全选；空选=保留当前不变）" "${all_exts[@]}"
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
  menu_multi "LNMP 组件（推荐 nginx + php + mysql + redis + acme）" "nginx" "php" "mysql" "redis" "acme.sh" "phpMyAdmin"
  sel=$MENU_MULTI_RESULT
  LNMP_SERVICES=""
  local -a names=(nginx php mysql redis acme phpmyadmin)
  for idx in $sel; do
    LNMP_SERVICES+="${LNMP_SERVICES:+,}${names[$idx]}"
  done
  # nginx 选了 → 自动补 php（fastcgi 后端）
  if [[ ",$LNMP_SERVICES," = *",nginx,"* && ",$LNMP_SERVICES," != *",php,"* ]]; then
    LNMP_SERVICES+=",php"
    info "已自动补充 php（nginx fastcgi 后端必需）"
  fi
  # acme webroot 模式需要 nginx 提供 .well-known 端点
  if [[ ",$LNMP_SERVICES," = *",acme,"* && ",$LNMP_SERVICES," != *",nginx,"* ]]; then
    warn "已选 acme 但未选 nginx：webroot 校验将不可用，仅 dns_* 模式可签证书"
  fi
  # phpmyadmin 选了 → 自动补 mysql（数据库后端必需）
  if [[ ",$LNMP_SERVICES," = *",phpmyadmin,"* && ",$LNMP_SERVICES," != *",mysql,"* ]]; then
    LNMP_SERVICES+=",mysql"
    info "已自动补充 mysql（phpMyAdmin 后端必需）"
  fi
}

_collect_image() {
  local _varname="$1" _title="$2" _default="$3"; shift 3
  local -a _options=("$@")
  local _cur="${!_varname:-$_default}"
  _options+=("保持当前不变（${_cur}）" "自定义（完整 镜像:TAG）")
  local _last=$(( ${#_options[@]} - 1 ))
  local _keep=$(( ${#_options[@]} - 2 ))
  local _idx _val
  menu_select "${_title}（当前: ${_cur}）" "${_options[@]}"
  _idx=$MENU_SELECT_RESULT
  if [[ "$_idx" -eq "$_keep" ]]; then
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

collect_nginx_image() {
  _collect_image NGINX_IMAGE "Nginx 镜像" "${NGINX_IMAGE:-nginx:stable-alpine}" \
    "nginx:stable-alpine (推荐)" "nginx:alpine" "nginx:1.28-alpine" "nginx:1.26-alpine" "nginx:1.24-alpine"
}

collect_mysql_image() {
  _collect_image MYSQL_IMAGE "MySQL / MariaDB 镜像" "${MYSQL_IMAGE:-mysql:8.0}" \
    "mysql:8.0 (推荐)" "mysql:8.4" "mysql:lts" "mysql:9" "mysql:9.0" "mariadb:11.4"
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
    "127.0.0.1:8080（仅本机/SSH 隧道，推荐）" \
    "0.0.0.0:8080（公网可达；务必用防火墙限制源 IP）" \
    "保持当前不变" \
    "自定义"
  _i=$MENU_SELECT_RESULT
  case "$_i" in
    0) PHPMYADMIN_BIND="127.0.0.1"; PHPMYADMIN_PORT="8080" ;;
    1) PHPMYADMIN_BIND="0.0.0.0";   PHPMYADMIN_PORT="8080" ;;
    2) return 0 ;;
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
  has_service "nginx" && collect_nginx_image
  has_service "mysql" && collect_mysql_image
  has_service "redis" && collect_redis_image
  has_service "acme" && collect_acme_image
  if has_service "phpmyadmin"; then collect_phpmyadmin_image; collect_phpmyadmin_listen; fi
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

  conf_save
  conf_load

  show_status

  while true; do
    local _i
    menu_select "请选择操作" \
      "查看状态" \
      "全新安装（完整向导）" \
      "一键重装 LNMP（沿用上次配置，跳过所有问询）" \
      "更新配置（含 PHP 多版本、镜像源、SSH 等）" \
      "安装单个组件" \
      "账户管理（用户/组/密码/SSH 公钥/AllowUsers）" \
      "卸载单个组件" \
      "退出"
    _i=$MENU_SELECT_RESULT
    case "$_i" in
      0) show_status ;;
      1) _interactive_full_install ;;
      2) _interactive_oneclick_reinstall ;;
      3) _interactive_config ;;
      4) _interactive_install_one ;;
      5) _interactive_account_mgmt ;;
      6) _interactive_uninstall_one ;;
      7) echo ""; ok "退出"; exit 0 ;;
    esac
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
  if has_service "nginx"; then printf "  %-20s %s\n" "Nginx 镜像" "$NGINX_IMAGE"; fi
  if has_service "mysql"; then printf "  %-20s %s\n" "MySQL 镜像" "$MYSQL_IMAGE"; fi
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
  echo ""
  hr; info "完整安装向导"; hr; echo ""

  local sel
  menu_multi "选择要安装的模块（推荐最少：Docker + LNMP；按高频排序）" \
    "等保加固 (cyber 三权用户)" \
    "Docker (LNMP 前置)" \
    "LNMP (nginx + php + mysql + redis + acme)" \
    "PM2 (Node.js + pm2，deploy-site 用)" \
    "SSH 安全策略 (改端口/禁 root)" \
    "Firewalld (防火墙)" \
    "BBR (TCP 拥塞)" \
    "Oh-My-Zsh" \
    "Wheel 管理员" \
    "saferm 安全删除"
  sel=$MENU_MULTI_RESULT

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
    info "已自动补充 Docker（LNMP 依赖）"
    sel_docker=1
  fi

  # ── 收集顺序：等保加固(cyber) → 账号 → 网络/源 → 基础设施(docker) → 应用(lnmp) → 系统加固(ssh) ──

  # 0) 等保加固前置（cyber 内部含交互+创建账号；ordinary 可作为 devops 默认值）
  if [[ $sel_cyber -eq 1 ]]; then setup_cyber_users; fi

  # 1) 账号优先（LNMP 安装时 chown 需要 DEVOPS_USER 已确定）
  prompt "devops 部署用户名" "${DEVOPS_USER:-devops}"
  DEVOPS_USER=$PROMPT_RESULT
  if [[ $sel_wheel -eq 1 ]]; then
    prompt "wheel 管理员用户名" "${WHEEL_USER:-admin}"
    WHEEL_USER=$PROMPT_RESULT
  fi

  # 2) 仅当真用得到 GitHub 时才问代理（zsh / lnmp / pm2 需要）
  if [[ $sel_zsh -eq 1 || $sel_lnmp -eq 1 || $sel_pm2 -eq 1 || $sel_saferm -eq 1 ]]; then
    collect_github_proxy
  fi

  # 3) Docker 镜像源（先于 LNMP，因为 LNMP 的 image pull 走它）
  if [[ $sel_docker -eq 1 ]]; then collect_docker_mirrors; fi

  # 4) LNMP 套件（components → images → php(默认/额外/扩展/源) → mysql → acme）
  if [[ $sel_lnmp -eq 1 ]]; then
    collect_lnmp_services
    collect_lnmp_stack_images
    if has_service "php"; then collect_alpine_mirror; collect_php_version; collect_extra_php_versions; collect_php_extensions; fi
    if has_service "mysql"; then collect_mysql_password; fi
    if has_service "acme"; then collect_acme_email; fi
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
    if has_service "nginx"; then printf "  %-20s %s\n" "Nginx 镜像" "$NGINX_IMAGE"; fi
    if has_service "mysql"; then printf "  %-20s %s\n" "MySQL 镜像" "$MYSQL_IMAGE"; fi
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
    if has_service "acme"; then printf "  %-20s %s\n" "ACME 邮箱" "$ACME_EMAIL"; fi
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
  local idx
  menu_select "选择要安装的组件（按高频排序）" \
    "LNMP (全部，推荐)" \
    "LNMP - php" \
    "LNMP - mysql" \
    "LNMP - redis" \
    "LNMP - nginx" \
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
    "等保加固"
  idx=$MENU_SELECT_RESULT

  case "$idx" in
    0)
      prompt "devops 部署用户名（LNMP chown 需要）" "${DEVOPS_USER:-devops}"
      DEVOPS_USER=$PROMPT_RESULT
      collect_lnmp_services
      collect_lnmp_stack_images
      if has_service "php"; then collect_alpine_mirror; collect_php_version; collect_extra_php_versions; collect_php_extensions; fi
      if has_service "mysql"; then collect_mysql_password; fi
      if has_service "acme"; then collect_acme_email; fi
      install_lnmp
      ;;
    1)  collect_php_version; collect_extra_php_versions; collect_php_extensions; collect_alpine_mirror
        LNMP_SERVICES="${LNMP_SERVICES},php"; install_lnmp "php" ;;
    2)  collect_mysql_image; collect_mysql_password; LNMP_SERVICES="${LNMP_SERVICES},mysql"; install_lnmp "mysql" ;;
    3)  collect_redis_image; LNMP_SERVICES="${LNMP_SERVICES},redis"; install_lnmp "redis" ;;
    4)  collect_nginx_image; LNMP_SERVICES="${LNMP_SERVICES},nginx"; install_lnmp "nginx" ;;
    5)  collect_acme_image; collect_acme_email; LNMP_SERVICES="${LNMP_SERVICES},acme"; install_lnmp "acme" ;;
    6)  collect_phpmyadmin_image; collect_phpmyadmin_listen; LNMP_SERVICES="${LNMP_SERVICES},phpmyadmin"; install_lnmp "phpmyadmin" ;;
    7)  collect_docker_mirrors; install_docker ;;
    8)  prompt "devops 用户名" "${DEVOPS_USER:-devops}"; DEVOPS_USER=$PROMPT_RESULT; collect_node_version; install_pm2 ;;
    9)  prompt "devops 用户名" "${DEVOPS_USER:-devops}"; DEVOPS_USER=$PROMPT_RESULT; setup_devops_user ;;
    10) prompt "wheel 管理员用户名" "${WHEEL_USER:-admin}"; WHEEL_USER=$PROMPT_RESULT; setup_wheel_user ;;
    11) collect_ssh_config; install_ssh ;;
    12) install_firewall ;;
    13) install_bbr ;;
    14) collect_github_proxy; install_zsh ;;
    15) install_saferm ;;
    16) setup_cyber_users ;;
  esac
  conf_save
}

_interactive_uninstall_one() {
  local idx
  menu_select "选择要卸载的组件（高危操作前会二次确认）" \
    "LNMP - php"   "LNMP - mysql" "LNMP - redis" "LNMP - nginx" "LNMP - acme" "LNMP - phpMyAdmin" \
    "LNMP (全部)" "Docker" \
    "PM2 (Node.js)" \
    "SSH (恢复默认)" "Firewalld" "BBR" "Oh-My-Zsh" "saferm"
  idx=$MENU_SELECT_RESULT

  # 高危项：标题→需要二次确认
  local _danger_msg=""
  case "$idx" in
    0) _danger_msg="将停止 lnmp-php 与所有 lnmp-phpNN 额外容器" ;;
    1) _danger_msg="将停止并移除 lnmp-mysql 容器（数据卷可保留）" ;;
    2) _danger_msg="将停止并移除 lnmp-redis 容器" ;;
    3) _danger_msg="将停止并移除 lnmp-nginx 容器" ;;
    4) _danger_msg="将停止并移除 lnmp-acme 容器" ;;
    5) _danger_msg="将停止并移除 lnmp-phpmyadmin 容器" ;;
    6) _danger_msg="将停止 LNMP 全部容器、删除 compose 文件、可选删除 ${DATA_DIR}" ;;
    7) _danger_msg="将卸载 Docker（不删除 /var/lib/docker，请按提示确认）" ;;
    8) _danger_msg="将卸载 PM2 / fnm / Node.js（devops 用户）" ;;
    9) _danger_msg="将恢复 sshd 默认（root/22 端口）" ;;
  esac
  if [[ -n "$_danger_msg" ]]; then
    warn "$_danger_msg"
    confirm "确认继续？" "n" || { info "已取消"; return 0; }
  fi

  case "$idx" in
    0)  uninstall_lnmp "php" ;;
    1)  uninstall_lnmp "mysql" ;;
    2)  uninstall_lnmp "redis" ;;
    3)  uninstall_lnmp "nginx" ;;
    4)  uninstall_lnmp "acme" ;;
    5)  uninstall_lnmp "phpmyadmin" ;;
    6)  uninstall_lnmp "all" ;;
    7)  uninstall_docker ;;
    8)  uninstall_pm2 ;;
    9)  uninstall_ssh ;;
    10) uninstall_firewall ;;
    11) uninstall_bbr ;;
    12) uninstall_zsh ;;
    13) uninstall_saferm ;;
  esac
  conf_save
}

_interactive_config() {
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
    "Devops 用户"
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
  esac
  conf_save
  ok "配置已更新"
}

