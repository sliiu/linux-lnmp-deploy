# shellcheck shell=bash

cmd_ssl() {
  prompt_pick_domain "选择要签发/续期的站点"
  [[ -z "$DOMAIN" ]] && die "域名不能为空"

  local site_dir="${WWW_ROOT}/${DOMAIN}"
  [[ -d "$site_dir" ]] || die "站点 ${DOMAIN} 不存在"

  local site_type="laravel"
  [[ -f "${site_dir}/artisan" ]] || site_type="frontend"

  container_ok "lnmp-acme" || die "lnmp-acme 未运行"

  _collect_ssl_dns_interactive
  SSL_DNS="${SSL_DNS:-${ACME_SSL_DNS_DEFAULT:-webroot}}"
  case "$SSL_DNS" in
    webroot|dns_cf|dns_ali|dns_dp|dns_gd|dns_aws|dns_tencent) ;;
    *) die "无效 SSL 模式: ${SSL_DNS}" ;;
  esac
  _collect_ssl_dns_creds_interactive
  if _is_dns_mode "$SSL_DNS"; then
    _acme_ssl_validate_dns_creds "$SSL_DNS"
  fi

  echo ""
  hr; info "SSL 续期/签发: ${DOMAIN}"; echo ""
  local _fe_ssl="dist"
  [[ "$site_type" = "frontend" ]] && _fe_ssl=$(effective_frontend_subdir "$DOMAIN")
  issue_ssl "$DOMAIN" "$site_type" "${SSL_DNS}" "${FORCE_SSL:-}" "$_fe_ssl"
}

# ═══════════════════════════════════════════════
#  用法说明
# ═══════════════════════════════════════════════
usage() {
  cat <<EOF
用法: $0 <命令> [选项]

命令:
  add       部署新站点（无参数进入交互模式）
  update    更新已有站点（有 .git 则 pull；Laravel：composer、migrate、optimize、Horizon）
            已有站点可 --webhook=release|tag 恢复/更新 Webhook 配置；--webhook-only 仅写配置
  rollback  回退到历史部署版本（webhook/自动部署前会保留快照）
  webhook   Webhook 自动部署（enable | disable | setup | serve | list）
  remove    移除站点（Nginx、SSL、crontab、Horizon、代码）
  list      列出已部署站点
  status    站点运行状态（本机 curl、容器、证书、日志；可加 --all）
  ssl       SSL 证书签发/续期

选项:
  --domain=域名         站点域名
  --sse-prefixes=列表   Laravel SSE：写入 ${NGINX_CONF}/<域名>.sse-prefixes（与 update 同用时跳过交互提示）。路径可含 {id} 自动生成正则；或 wave、~^/… 等。留空=删站点文件用全局
  环境变量 LARAVEL_SSE_PREFIXES  无 per-site 文件时的默认（空格/逗号分隔，规则同上）[默认: wave]
  --git=地址            Git 仓库地址（留空或省略=跳过 clone/pull）
  --git-branch=名称     clone/pull 使用的分支或标签（留空=默认分支；无 --git 时忽略）
  --git-ref=名称        update 时 checkout 指定 tag/commit（不 pull）
  --webhook=release|tag  add/update 启用或恢复 webhook（静态=release，Laravel=tag）
  --webhook-only        与 update --webhook 联用：仅写 webhook 配置，不 pull/composer
  --webhook-release-name=  release 模式：匹配的 Release 名称或 tag
  --webhook-secret=     webhook 密钥（留空自动生成）
  --rollback-to=版本|序号  rollback 目标（版本号或 history 序号）
  --rollback-index=N    rollback 序号（同 --rollback-to 数字形式）
  --type=laravel|frontend  站点类型 [默认: laravel]
  --php-version=主版本   站点 PHP 版本（如 8.2 / 7.4），需在 init.sh 的 EXTRA_PHP_VERSIONS 中已声明；留空或 - = 走默认 lnmp-php
                       写入 ${NGINX_CONF}/<域名>.php-version；nginx fastcgi 与 composer/artisan/cron/horizon 自动路由到对应容器
  --app-name=名称       APP_NAME [Laravel]
  --redis-host=         REDIS_HOST [redis]
  --redis-port=         REDIS_PORT [6379]
  --redis-password=     REDIS_PASSWORD；留空: --redis-password= 或 --redis-password 下一参数为另一选项
  --need-db=y|n         是否配置数据库 [y]
  --db-host=            DB_HOST [mysql]
  --db-name=            DB_DATABASE
  --db-password=        DB_PASSWORD
  --create-db=y|n       自动建库 [y]
  --run-migrate=y|n     执行 migrate [y]；update 时指定则可不交互（建议自动化加 --run-migrate=y 或 n）
  --run-seed=y|n        执行 db:seed [y]
  --add-crontab=y|n     添加定时任务 [y]
  --need-horizon=y|n    使用 Horizon [y]
  --frontend-root=      前端子目录（相对站点目录；留空则：存在 dist/→dist，否则→站点根）
  --env=KEY=VALUE       自定义 ENV（可多次）
  --dns=MODE            SSL: webroot | dns_cf | dns_ali | dns_dp | dns_gd | dns_aws | dns_tencent [webroot]
  --cf-token=           dns_cf: Cloudflare API Token
  --ali-key= --ali-secret=   dns_ali: 阿里云 DNS (acme.sh Ali_Key / Ali_Secret)
  --dp-id= --dp-key=         dns_dp: DNSPod (DP_Id / DP_Key)
  --gd-key= --gd-secret=     dns_gd: GoDaddy
  --aws-access-key= --aws-secret-key=  dns_aws: Route53
  --tencent-secret-id= --tencent-secret-key=  dns_tencent: 腾讯云 DNSPod API
  --force-ssl           强制重新签发证书
  --ssl-staging         使用 LE 测试 CA（规避正式限流/调试，浏览器不信任）
  --yes                 跳过确认（remove 时）
  --all                 status：检查 conf.d 中全部站点（简略；详单用 --domain）

示例:
  $0 add --domain=api.example.com --git=git@gitee.com:user/repo.git --git-branch=develop --need-db=y --db-name=app --db-password=secret
  $0 update --domain=api.example.com
  $0 update --domain=api.example.com --git-ref=v1.2.0
  $0 update --domain=www.example.com --webhook=release --webhook-release-name=production --git=git@github.com:org/repo.git --webhook-only
  $0 webhook enable --domain=www.example.com --webhook=release --webhook-release-name=production --git=git@github.com:org/repo.git
  $0 webhook setup
  $0 rollback --domain=www.example.com --rollback-to=1
  $0 remove --domain=api.example.com
  $0 list
  $0 status --domain=api.example.com
  $0 status --all
  $0 ssl --domain=api.example.com --force-ssl
  $0 add --domain=test.example.com --git=... --ssl-staging   # 测试证书
  $0 add --domain=x.com --git=... --dns=dns_ali --ali-key=AK --ali-secret=SK
  $0 add --domain=x.com --git=   # 或省略 --git，配合事先放入 ${DATA_DIR:-/data/docker-lnmp}/www/x.com
  $0 add --domain=legacy.com --git=... --php-version=7.4   # 该站使用 lnmp-php74
  $0 update --domain=api.example.com --php-version=8.2     # 切到 lnmp-php82
EOF
}

