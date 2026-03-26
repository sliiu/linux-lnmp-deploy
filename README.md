# 阿里云 ECS 部署脚本说明

面向阿里云 ECS（及同类 CentOS/Debian/Alibaba Cloud Linux）的 **主机初始化** 与
**Docker LNMP 多站点部署** 工具。

## 下载方式

```bash
# init.sh 环境部署
curl -fsSL -o init.sh https://gitee.com/qing-u/alibaba-cloud-ecs-deployment/raw/main/init.sh

# deploy-site 站点部署
curl -fsSL -o deploy.sh https://gitee.com/qing-u/alibaba-cloud-ecs-deployment/raw/main/deploy-site.sh
```

`deploy.sh` 与仓库中的 **`deploy-site.sh`** 为同一文件；下载后请 `chmod +x init.sh deploy.sh`，部署到系统路径时建议仍命名为 **`/usr/local/bin/deploy-site.sh`**（与 `init.sh` 里 sudoers 一致）。

## 脚本一览

- **`init.sh`**：以 **root** 安装/配置 BBR、防火墙、Docker、LNMP 容器、SSH、用户与可选等保加固；
  写入 `/etc/lnmp-env.conf`。
- **`deploy-site.sh`**：以 **root** 在已有 LNMP 栈上 **新增/更新/删除** 站点：Nginx、可选 Git、SSL
  （acme.sh）、Laravel 或静态前端。

---

## 环境与前提

- **执行用户**：两个脚本均须 **root**。
- **顺序**：先在本机完成 `init.sh`（至少 Docker + LNMP 相关容器、devops 用户），再执行
  `deploy-site.sh`。
- **数据目录**：默认 `/data/docker-lnmp`（站点代码在 `www/<域名>/`）。`deploy-site.sh` 会
  source `/etc/lnmp-env.conf`：`CONTAINER_WWW` 由 `init.sh` 写入该文件；若需改主机上的数据根目录，
  须**自行**在配置中加入 `LNMP_DATA_DIR=...`（`init.sh` 当前不会写入该项），并保证与现有
  `docker-compose` 卷路径一致。
- **Git**：使用仓库时由 `DEVOPS_USER`（默认 `devops`）执行 clone/pull，需 `~/.ssh/` 下
  **id_ed25519** 或 **id_rsa** 能访问远程；**`--git` 留空或省略**则跳过 clone/pull，请事先把代码放到
  `www/<域名>/`。**`update`**：有 `.git` 才 pull，无则跳过 Git、仍可做 composer / migrate 等（Laravel）
  或 reload Nginx（前端）。
- **域名**：**webroot** 校验需域名指向本机且 **80** 可达；**DNS 校验** 时域名解析可在任意
  DNS 商，只需在对应云开通 API 权限（见 deploy-site 一节）。`init.sh` 可将
  **`ACME_SSL_DNS_DEFAULT`** 写入 `/etc/lnmp-env.conf`，作为 `deploy-site.sh` 交互时的默认
  `--dns`（不含密钥）。

---

## init.sh 操作说明

### 功能概要（init.sh）

- 生成/更新 **`/etc/lnmp-env.conf`**（权限 600），保存 Devops 用户、GitHub 代理、Docker 镜像、
  PHP 版本与扩展、ACME 邮箱、**`ACME_SSL_DNS_DEFAULT`**（`deploy-site` 交互默认 SSL 模式）、
  SSH 端口与 root 策略、LNMP 组件列表等。
- 可选模块：**SSH 加固**、**等保三权用户**、**BBR**、**Oh-My-Zsh**、**Firewalld**、
  **Docker**、**LNMP（docker-compose）**、**wheel 管理员**、**devops 用户**（将 `DEVOPS_USER`
  加入组 **`devops`**，sudoers 为 `%devops NOPASSWD: /usr/local/bin/deploy-site.sh`）。
- LNMP：`/data/docker-lnmp/docker-compose.yml`，容器名 `lnmp-nginx`、`lnmp-php`、`lnmp-mysql`、
  `lnmp-redis`、`lnmp-acme`（按勾选组件）。

### 推荐用法

1. 上传脚本到服务器，赋予执行权限：`chmod +x init.sh`。
2. **交互模式**（无参数，菜单操作）：

   ```bash
   sudo ./init.sh
   ```

   首次建议选 **「1) 全新安装（完整向导）」**，按提示勾选模块并填写密码、邮箱、镜像源等。

3. **查看状态**：

   ```bash
   sudo ./init.sh status
   ```

4. **非交互安装示例**（需自行保证参数完整，避免漏配）：

   ```bash
   sudo ./init.sh install docker --docker-mirrors=https://docker.m.daocloud.io
   sudo ./init.sh install lnmp --php-version=8.3 --mysql-pwd='你的root密码' --acme-email=you@example.com
   sudo ./init.sh install ssh --ssh-port=22 --root-login=key
   ```

### 菜单项对照

- **1 全新安装**：多选模块后一次性执行。
- **2 安装单个组件**：BBR / 防火墙 / Docker / Zsh / SSH / LNMP 全量或单容器等。
- **3 卸载单个组件**：与上对应卸载；LNMP 全量卸载可选是否删数据目录。
- **4 更新配置**：代理、镜像、Alpine 源、PHP 版本/扩展、SSH、ACME 邮箱、**ACME SSL 默认方式**、
  devops 用户等。
- **5 查看状态**：BBR、Docker、容器、SSH、等保标记等。
- **6 账户管理**：用户/组、密码、authorized_keys、AllowUsers 与 `resync-allow`。

### 账户相关 CLI

```bash
sudo ./init.sh account list          # 用户列表
sudo ./init.sh account groups
sudo ./init.sh account allowusers
sudo ./init.sh account resync-allow  # 按 lnmp-env 重建 AllowUsers（覆盖）
```

### 日志路径（init.sh）

- `/data/docker-lnmp/logs/init.log`（stdout/stderr 经 tee 追加）

### 注意事项（init.sh）

- 修改 **SSH 端口** 前确认防火墙/安全组已放行新端口，避免锁死。
- **install ssh** 会关闭密码登录、启用密钥；务必先保证 **AllowUsers** 中用户能密钥登录。
- **等保**流程会创建三权账户并可选择将普通用户设为 `DEVOPS_USER`。
- `deploy-site.sh` 需存在于 **`/usr/local/bin/deploy-site.sh`** 且 devops 的 sudoers 才生效
  （脚本里写的是该路径）。

---

## deploy-site.sh 操作说明

### 功能概要（deploy-site.sh）

- 依赖 **`lnmp-nginx`、`lnmp-php`** 已运行；**`lnmp-acme`** 未运行时 `add` 会跳过 SSL 签发并告警，
  **`ssl`** 子命令要求 acme 运行。
- **Laravel**：`public` 为 Web 根目录；Nginx、占位证书、Let's Encrypt（acme.sh）、`.env` 合并、
  **composer**（容器内与站点目录属主一致）、**artisan**（`docker exec` 以 devops 身份、项目目录下
  `php artisan`）。**默认**：`NEED_DB` / `RUN_SEED` / `NEED_HORIZON` 为 **y**；默认连库时需
  **`--db-name`**（或交互填写），否则脚本会报错退出；不需要数据库时用 **`--need-db=n`**。
- **frontend**：Nginx 在 **代码就绪后**生成。未指定 **`--frontend-root`** 时：若站点目录下存在
  **`dist/`** 则用 `dist`，否则 **站点根目录**即静态根。可用 **`--frontend-root`** 显式指定子目录。
- **Git**：**`--git=` 留空或省略**跳过 clone/pull；**`--git-branch`** 指定分支/标签（clone 使用
  `--single-branch`；已有仓库时 fetch + checkout + pull）。**`list`**：有 `.git`、或有 `artisan`、
  或站点目录非空则状态为「已部署」。

#### SSL：`--dns` 与主流 DNS（acme.sh）

- **`webroot`**：HTTP-01，需本机 80；无额外密钥参数（默认）。
- **`dns_cf`**（Cloudflare）：`--cf-token` → `CF_Token`。
- **`dns_ali`**（阿里云解析）：`--ali-key` / `--ali-secret` → `Ali_Key` / `Ali_Secret`。
- **`dns_dp`**（DNSPod 国际版 API）：`--dp-id` / `--dp-key` → `DP_Id` / `DP_Key`。
- **`dns_gd`**（GoDaddy）：`--gd-key` / `--gd-secret` → `GD_Key` / `GD_Secret`。
- **`dns_aws`**（AWS Route53）：`--aws-access-key` / `--aws-secret-key` →
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`。
- **`dns_tencent`**（腾讯云 DNS / DNSPod API）：`--tencent-secret-id` /
  `--tencent-secret-key` → `Tencent_SecretId` / `Tencent_SecretKey`。

更多 DNS 插件见 [acme.sh DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)。未内置的供应商可在
`lnmp-acme` 容器内按官方文档自行调用 `acme.sh --dns dns_xxx`。

### 安装到系统路径（与 init 中 sudoers 一致）

```bash
sudo cp deploy-site.sh /usr/local/bin/deploy-site.sh
sudo chmod +x /usr/local/bin/deploy-site.sh
```

### 子命令

- **`add`**：新站点；无参数时进入交互。
- **`update`**：要求 **`www/<域名>/` 目录已存在**。若存在 **`.git`**：`git pull`（可选
  **`--git-branch`**）；若无 `.git`：跳过 Git 并提示。Laravel：**composer install**、可选 **migrate**、
  **optimize**、有 Horizon 配置则重启；前端：检查静态目录、**nginx reload**。
- **`remove`**：删除 Nginx 配置、SSL 目录、crontab/Horizon、可选删除代码目录。
- **`list`**：列出 `conf.d` 下站点及类型、SSL、Cron、部署状态等。
- **`ssl`**：对已有站点重新签发/续期证书。
- **（无参数）**：数字菜单，等价于选择上述功能。

### 常用示例

```bash
sudo /usr/local/bin/deploy-site.sh add \
  --domain=api.example.com \
  --git=git@github.com:org/repo.git \
  --git-branch=main \
  --type=laravel \
  --db-name=myapp \
  --db-password='数据库密码' \
  --redis-password='redis密码或留空'

# 不使用数据库时
# sudo ... add --domain=api.example.com --git=... --need-db=n ...

# 不通过 Git，事先把代码放到 /data/docker-lnmp/www/api.example.com/
# sudo ... add --domain=api.example.com --git=

sudo /usr/local/bin/deploy-site.sh update --domain=api.example.com
# sudo ... update --domain=api.example.com --git-branch=develop

sudo /usr/local/bin/deploy-site.sh list

sudo /usr/local/bin/deploy-site.sh ssl --domain=api.example.com --force-ssl

sudo /usr/local/bin/deploy-site.sh remove --domain=api.example.com --yes
```

前端站点示例：

```bash
sudo /usr/local/bin/deploy-site.sh add \
  --domain=www.example.com \
  --git=git@github.com:org/spa.git \
  --type=frontend
# 未写 --frontend-root 时：有 dist/ 用 dist，否则站点根为静态根
# sudo ... add --domain=www.example.com --type=frontend --frontend-root=build
```

### 主要参数（add/ssl 等）

- **`--domain`**、**`--git`**（可空=跳过 Git）、**`--git-branch`**、`--type=laravel|frontend`
- Laravel：**`--app-name`**、**`--redis-host`**、**`--redis-port`**、**`--redis-password`**、
  **`--need-db`**（默认 y）、**`--db-host`**、**`--db-name`**、**`--db-password`**、
  **`--create-db`**、**`--run-migrate`**、**`--run-seed`**（默认 y）、**`--add-crontab`**、
  **`--need-horizon`**（默认 y）
- **`--frontend-root`**：相对站点目录；留空则按是否存在 **`dist/`** 自动选择（见上文）
- 自定义环境：**`--env=KEY=VALUE`**（可多次）
- SSL：**`--dns`**（见上文 DNS 列表）、各云密钥、**`--force-ssl`**、**`--ssl-staging`**
- **`remove`**：**`--yes`** 跳过部分确认

完整列表见：`sudo /usr/local/bin/deploy-site.sh --help`（未安装到该路径时改为
`sudo ./deploy-site.sh --help`）

### 日志路径（deploy-site.sh）

- `/data/docker-lnmp/logs/deploy-site.log`

### 注意事项（deploy-site.sh）

- Let's Encrypt **速率限制**：同一域名 7 天内正式证书约 5 张；遇 429 可等待重试或临时
  `--ssl-staging`。
- **非 root** 执行会失败；**devops**：`init.sh` 写入 `/etc/sudoers.d/devops-deploy`，对 **组
  `devops`** 授予 `NOPASSWD: /usr/local/bin/deploy-site.sh`；`DEVOPS_USER` 会加入该组，故可用
  `sudo /usr/local/bin/deploy-site.sh ...`（勿改组名，否则须同步改 sudoers）。
- 默认 **`NEED_DB=y`** 的 Laravel 部署必须提供 **`--db-name`**（或交互输入）；**`update`** 对无
  **`.git`** 的目录不会执行 pull，请在主机上先同步好代码再执行。

---

## 典型流程

1. 控制台用 root 或密钥登录 ECS，上传 `init.sh`。
2. `chmod +x init.sh && sudo ./init.sh`（若已是 root 可省略 `sudo`），完成 Docker、LNMP、devops、
   SSH、防火墙、ACME 邮箱等。
3. 将 `deploy-site.sh` 安装到 `/usr/local/bin/` 并 `chmod +x`。
4. 若使用 Git：为 devops 配置 SSH 公钥，保证能 clone/pull 私有仓库。
5. `sudo /usr/local/bin/deploy-site.sh add`（或带全参数）添加站点；浏览器访问 `https://域名` 验证。

---

## 配置文件与版本

- **全局配置**：`/etc/lnmp-env.conf`（由 `init.sh` 维护；`deploy-site.sh` 会 source 以统一数据目录等
  变量）。
- 脚本内版本号均为 **2.0.0**（以脚本内 `VERSION=` 为准）。
