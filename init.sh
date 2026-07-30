#!/bin/bash
set -euo pipefail

VERSION="2.0.0"
CONF_FILE="/etc/lnmp-env.conf"
DATA_DIR="/data/docker-lnmp"
COMPOSE_FILE="${DATA_DIR}/docker-compose.yml"
CYBERSEC_MARKER="/etc/cybersecurity-init.done"

mkdir -p "${DATA_DIR}/logs" 2>/dev/null || true
LOG_FILE="${DATA_DIR}/logs/init.log"
# stdout/stderr 进 tee 时变为管道，菜单与 read -p 易不刷到终端；同时写 log 与 /dev/tty
if [[ -e /dev/tty ]] && [[ -w /dev/tty ]]; then
  if command -v stdbuf &>/dev/null; then
    exec > >(stdbuf -oL tee -a "$LOG_FILE" >/dev/tty) 2>&1
  else
    exec > >(tee -a "$LOG_FILE" >/dev/tty) 2>&1
  fi
else
  exec > >(tee -a "$LOG_FILE") 2>&1
fi
echo "===== $(date '+%Y-%m-%d %H:%M:%S') START $0 $* pid=$$ ====="

# ═══════════════════════════════════════════════
#  lib 加载（本地优先，缺失时从 Gitee 自动下载）
# ═══════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB_RAW_BASE="${_LIB_RAW_BASE:-https://gitee.com/sliiu/alibaba-cloud-ecs-deployment/raw/main}"
_LIB_TMPDIR=""

_source_lib() {
  local rel="$1"
  local path="${SCRIPT_DIR}/${rel}"
  if [[ ! -f "$path" ]]; then
    if [[ -z "$_LIB_TMPDIR" ]]; then
      _LIB_TMPDIR="$(mktemp -d)"
      trap 'rm -rf "$_LIB_TMPDIR"' EXIT
    fi
    local fname="${rel##*/}"
    path="${_LIB_TMPDIR}/${fname}"
    local url="${_LIB_RAW_BASE}/${rel}"
    echo "  ↓ 下载依赖 ${rel} ..." >&2
    if command -v curl &>/dev/null; then
      curl -fsSL "$url" -o "$path" || { echo "✗ 下载失败: ${url}" >&2; exit 1; }
    elif command -v wget &>/dev/null; then
      wget -qO "$path" "$url" || { echo "✗ 下载失败: ${url}" >&2; exit 1; }
    else
      echo "✗ 缺少 curl/wget，无法下载依赖: ${rel}" >&2; exit 1
    fi
  fi
  # shellcheck disable=SC1090
  . "$path"
}

_source_lib lib/common.sh
_source_lib lib/init/tools.sh
_source_lib lib/init/config.sh
_source_lib lib/init/detect.sh
_source_lib lib/init/bbr.sh
_source_lib lib/init/firewall.sh
_source_lib lib/init/zsh.sh
_source_lib lib/init/docker.sh
_source_lib lib/init/ssh.sh
_source_lib lib/init/accounts.sh
_source_lib lib/init/lnmp.sh
_source_lib lib/init/pm2.sh
_source_lib lib/init/status.sh
_source_lib lib/init/interactive.sh
_source_lib lib/init/saferm.sh

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
  update lnmp [组件]    拉取镜像并重建容器；省略组件则全部；组件: nginx|php|mysql|postgres|redis|acme|phpmyadmin
  account [子命令]      账户/组/AllowUsers（见 account help）

组件:
  bbr         TCP BBR 加速
  firewall    Firewalld 防火墙
  docker      Docker 引擎
  zsh         Oh-My-Zsh
  ssh         SSH 安全策略
  lnmp        LNMP 全部容器
  nginx       Nginx 容器
  php         PHP 默认容器（lnmp-php；会一并卸掉所有额外 PHP）
  php-X.Y     仅卸载额外 PHP（如 php-7.4 → lnmp-php74）
  mysql       MySQL 容器
  postgres    PostgreSQL 容器
  redis       Redis 容器
  acme        ACME 证书容器
  phpmyadmin  phpMyAdmin 容器
  pm2         Node.js + PM2（devops 用户，供 deploy-site --type=pm2）
  wheel       Wheel 管理员
  cyber       等保加固
  devops      Devops 部署用户
  saferm      安全删除脚本（/var/trash，安装到 /usr/local/bin/saferm）

安装选项:
  --gh-proxy=URL          GitHub 代理
  --docker-mirrors=URL,.. Docker 镜像源（逗号分隔）
  --alpine-mirror=HOST    Alpine 源
  --node-version=VER     Node.js 主版本（fnm，默认 22）
  --node-mirror=URL      Node 二进制镜像 [https://npmmirror.com/mirrors/node]
  --php-version=VER       PHP 主版本，对应 php:VER-fpm-alpine（如 8.3）
  --php-ext=EXT,...       PHP 扩展（逗号分隔）
  --nginx-image=IMG       Nginx 镜像 (如 nginx:stable-alpine)
  --mysql-image=IMG       MySQL 镜像 (如 mysql:8.0)
  --postgres-image=IMG    PostgreSQL 镜像 (如 postgres:16-alpine)
  --redis-image=IMG       Redis 镜像 (如 redis:alpine)
  --acme-image=IMG        acme.sh 镜像 (如 neilpang/acme.sh:latest)
  --phpmyadmin-image=IMG  phpMyAdmin 镜像 (如 phpmyadmin:latest)
  --phpmyadmin-bind=ADDR  phpMyAdmin 绑定地址（默认 127.0.0.1）
  --phpmyadmin-port=PORT  phpMyAdmin 端口（默认 8080）
  --mysql-pwd=PWD         MySQL root 密码
  --postgres-pwd=PWD      PostgreSQL 超级用户密码
  --acme-email=EMAIL      ACME 邮箱
  --ssh-port=PORT         SSH 端口
  --root-login=no|key     SSH root 策略
  --devops-user=NAME      Devops 用户名
  --wheel-user=NAME       Wheel 管理员用户名

示例:
  $0                                    # 交互模式
  $0 status                             # 查看状态
  $0 install docker --docker-mirrors=https://docker.m.daocloud.io
  $0 install pm2 --node-version=22
  # PM2 网关栈（无 php）：nginx 反代 + postgres + redis + acme + 宿主机 PM2
  $0 install docker --docker-mirrors=https://docker.m.daocloud.io
  $0 install devops
  $0 install nginx
  $0 install postgres --postgres-pwd=secret
  $0 install redis
  $0 install acme --acme-email=a@b.com
  $0 install pm2 --node-version=20
  $0 install lnmp --php-version=8.3 --mysql-pwd=secret --postgres-pwd=secret --acme-email=a@b.com
  $0 install postgres --postgres-image=postgres:16-alpine --postgres-pwd=secret
  $0 update lnmp
  $0 update lnmp nginx
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
  _fix_alinux4_docker_repo

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
      --node-version=*)   NODE_VERSION="${arg#*=}" ;;
      --node-mirror=*)    FNM_NODE_DIST_MIRROR="${arg#*=}" ;;
      --php-ext=*)        PHP_EXTENSIONS="${arg#*=}" ;;
      --nginx-image=*)    NGINX_IMAGE="${arg#*=}" ;;
      --mysql-image=*)    MYSQL_IMAGE="${arg#*=}" ;;
      --postgres-image=*) POSTGRES_IMAGE="${arg#*=}" ;;
      --redis-image=*)    REDIS_IMAGE="${arg#*=}" ;;
      --acme-image=*)     ACME_IMAGE="${arg#*=}" ;;
      --phpmyadmin-image=*) PHPMYADMIN_IMAGE="${arg#*=}" ;;
      --phpmyadmin-bind=*)  PHPMYADMIN_BIND="${arg#*=}" ;;
      --phpmyadmin-port=*)  PHPMYADMIN_PORT="${arg#*=}" ;;
      --mysql-pwd=*)      MYSQL_ROOT_PWD="${arg#*=}" ;;
      --postgres-pwd=*)   POSTGRES_PWD="${arg#*=}" ;;
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
        postgres) LNMP_SERVICES="${LNMP_SERVICES},postgres"; install_lnmp "postgres" ;;
        redis)    LNMP_SERVICES="${LNMP_SERVICES},redis";  install_lnmp "redis" ;;
        acme)     LNMP_SERVICES="${LNMP_SERVICES},acme";   install_lnmp "acme" ;;
        phpmyadmin) LNMP_SERVICES="${LNMP_SERVICES},phpmyadmin"; install_lnmp "phpmyadmin" ;;
        pm2)      install_pm2 ;;
        wheel)    setup_wheel_user ;;
        cyber)    setup_cyber_users ;;
        devops)   setup_devops_user ;;
        saferm)   install_saferm ;;
        *)        die "未知组件: $target" ;;
      esac
      conf_save
      ;;
    update)
      local u_target="${1:-}"
      [[ -z "$u_target" ]] && { usage; die "请指定 update 目标: lnmp"; }
      shift 2>/dev/null || true
      case "$u_target" in
        lnmp)
          local sub="${1:-}"
          if [[ -n "$sub" && "${sub:0:1}" != "-" ]]; then
            shift 2>/dev/null || true
            update_lnmp "$sub"
          else
            update_lnmp
          fi
          ;;
        *) die "未知 update 目标: $u_target（仅支持 lnmp）" ;;
      esac
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
        php-*)    uninstall_lnmp "$target" ;;
        mysql)    uninstall_lnmp "mysql" ;;
        postgres) uninstall_lnmp "postgres" ;;
        redis)    uninstall_lnmp "redis" ;;
        acme)     uninstall_lnmp "acme" ;;
        phpmyadmin) uninstall_lnmp "phpmyadmin" ;;
        pm2)      uninstall_pm2 ;;
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
