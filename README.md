# 阿里云 ECS 部署脚本说明

面向阿里云 ECS（及同类 CentOS/Debian/Alibaba Cloud Linux）的 **主机初始化** 与
**Docker LNMP 多站点部署** 工具。

## 快速使用

`init.sh` / `deploy-site.sh` 会按顺序 `source` 仓库内 `**lib/**/*.sh`**（共享逻辑在 `**lib/common.sh**`）。请将入口脚本与同级的 `**lib/**` 目录一并保留（`bootstrap.sh` / `git clone` 即可获得完整 tree）。

若某台机器上**只有入口脚本**、本地缺少个别 `lib` 文件，脚本会尝试用 **curl** 或 **wget** 从 `**_LIB_RAW_BASE`**（默认与同仓库 raw，与 `bootstrap` 同源）按需下载缺失模块后再继续；两台工具都不可用则退出。

可选环境变量（与脚本内默认值一致时可省略）：`**_LIB_RAW_BASE**`、`INSTALL_DIR`、`REPO_URL`、`REPO_BRANCH`。

### 方式 1：bootstrap.sh 一键引导（推荐）

`bootstrap.sh` 会自动安装 `git`，把仓库 clone/更新到 `/opt/alibaba-cloud-ecs-deployment`，再执行目标脚本：

```bash
# 首次环境初始化
curl -fsSL https://gitee.com/sliiu/alibaba-cloud-ecs-deployment/raw/main/bootstrap.sh | sudo bash -s init.sh

# 站点部署（参数原样透传给 deploy-site.sh）
curl -fsSL https://gitee.com/sliiu/alibaba-cloud-ecs-deployment/raw/main/bootstrap.sh \
  | sudo bash -s deploy-site.sh add --domain=example.com --type=laravel --git=git@github.com:user/repo.git
```

可通过环境变量覆盖：

- `**INSTALL_DIR**`：安装目录（默认 `/opt/alibaba-cloud-ecs-deployment`）
- `**REPO_URL**` / `**REPO_BRANCH**`：仓库地址与分支

### 方式 2：git clone 后执行

```bash
sudo git clone --depth=1 https://gitee.com/sliiu/alibaba-cloud-ecs-deployment.git /opt/alibaba-cloud-ecs-deployment
cd /opt/alibaba-cloud-ecs-deployment

sudo bash init.sh
sudo bash deploy-site.sh add --domain=example.com ...
```

### 升级到最新版

```bash
# 方式 1 用户：再次运行 bootstrap.sh 即可，内部 fetch + reset 到最新
# 方式 2 用户：
sudo git -C /opt/alibaba-cloud-ecs-deployment pull --ff-only
```

## 脚本一览

- `**bootstrap.sh**`：克隆/更新仓库到 `**INSTALL_DIR**` 后 `**exec**` 运行 `**init.sh**` 或 `**deploy-site.sh**`（参数透传）。
- `**init.sh**`：以 **root** 安装/配置 BBR、防火墙、Docker、LNMP 容器、SSH、用户与可选等保加固；
写入 `/etc/lnmp-env.conf`；可选安装 **saferm**（见下文「saferm」）。实现按领域拆在 `**lib/init/*.sh`**（如 `**config**`、`**lnmp**`、`**docker**`、`**saferm**` 等），由 `**init.sh**` 统一加载。
- `**deploy-site.sh**`：以 **root** 在已有 LNMP 栈上 **新增/更新/删除/列举/状态/SSL** 站点：Nginx、可选 Git、SSL
（acme.sh）、Laravel（含可选多 PHP 版本、SSE 路径规则）、或静态前端。子命令实现在 `**lib/deploy/*.sh`**，由 `**deploy-site.sh**` 加载 `**lib/common.sh**` 与各 cmd 模块。

`**lib/common.sh**`：`die`、菜单、确认等共用函数，供两个入口脚本共用。

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
**id_ed25519** 或 **id_rsa** 能访问远程；`**--git` 留空或省略**则跳过 clone/pull，请事先把代码放到
`www/<域名>/`。`**update`**：有 `.git` 才 pull，无则跳过 Git、仍可做 composer / migrate 等（Laravel）
或 reload Nginx（前端）。
- **域名**：**webroot** 校验需域名指向本机且 **80** 可达；**DNS 校验** 时域名解析可在任意
DNS 商，只需在对应云开通 API 权限（见 deploy-site 一节）。`init.sh` 可将
`**ACME_SSL_DNS_DEFAULT`** 写入 `/etc/lnmp-env.conf`，作为 `deploy-site.sh` 交互时的默认
`--dns`（不含密钥）。

---

## init.sh 操作说明

### 功能概要（init.sh）

- 生成/更新 `**/etc/lnmp-env.conf**`（权限 600），保存 Devops 用户、GitHub 代理、Docker 镜像、
**LNMP 各容器镜像**（`NGINX_IMAGE`、`MYSQL_IMAGE`、`REDIS_IMAGE`、`ACME_IMAGE`）、`**PHP_VERSION`**
与扩展、ACME 邮箱、`**ACME_SSL_DNS_DEFAULT**`（`deploy-site` 交互默认 SSL 模式）、SSH 端口与 root
策略、LNMP 组件列表等。
- 可选模块：**SSH 加固**、**等保三权用户**、**BBR**、**Oh-My-Zsh**、**Firewalld**、
**Docker**、**LNMP（docker-compose）**、**wheel 管理员**、**devops 用户**（将 `DEVOPS_USER`
加入组 `**devops`**，sudoers 为 `%devops NOPASSWD: /usr/local/bin/deploy-site.sh`）、
**saferm**（安全删除脚本，见「saferm」一节）。
- LNMP：`/data/docker-lnmp/docker-compose.yml`，容器名 `lnmp-nginx`、`lnmp-php`、`lnmp-mysql`、
`lnmp-redis`、`lnmp-acme`（按勾选组件）；`**EXTRA_PHP_VERSIONS`**（CSV，如 `7.4,8.2`）会再生成与 compose 一致的容器名 `**lnmp-php74`、`lnmp-php82**`（数字为无点号主版本），供 `**deploy-site.sh` `--php-version**` 选用。

### 推荐用法

1. 按上文「快速使用」用 `bootstrap.sh` 或 `git clone` 把仓库放到 `/opt/alibaba-cloud-ecs-deployment`。下文示例均假设当前目录为该仓库根目录。
2. **交互模式**（无参数，菜单操作）：
  ```bash
   sudo bash init.sh
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
   sudo ./init.sh install saferm   # 可选：安装安全删除到 /usr/local/bin/saferm
  ```
5. **更新 LNMP 容器镜像**（按 `/etc/lnmp-env.conf` 中的镜像名拉取并重建；`update` 会重写
  `docker-compose.yml` 后执行 `pull` + `up --force-recreate`）：

### LNMP 版本与镜像（init.sh）

- **交互向导 / 「安装单个组件」中的 LNMP**：会为已勾选组件提供 **预设镜像/版本**（PHP 主版本、Nginx、
MySQL/MariaDB、Redis、acme.sh 等），每项末档一般为 **自定义**（完整 `镜像:TAG` 或 PHP 主版本号）。
- **非交互**：除原有 `**--php-version=`**、`**--php-ext=**` 外，还可指定
`**--nginx-image=**`、`**--mysql-image=**`、`**--redis-image=**`、`**--acme-image=**`（值须为
Docker Hub 等可拉取的镜像引用，与 `docker-compose` 中 `image:` 一致）。
- `**sudo ./init.sh status**`：在 LNMP 区域会按已启用服务打印当前配置的镜像与 PHP 版本。
- **菜单「4) 更新配置」**：含 **LNMP 组件镜像**；若本机已有 `docker-compose.yml`，改完后会执行与
`**update lnmp`** 相同的拉取与重建流程（未安装 LNMP 时仅写入配置，待后续 `install lnmp` 生效）。

### saferm（安全删除）

**作用**：在服务器上用「回收站」方式处理删除——默认把路径 **移动到** `**/var/trash/files`**，而不是直接
`rm`，降低误删不可恢复的风险。与桌面环境的 GNOME/KDE 回收站无关，是 **本机固定目录** 的集中暂存区。

**安装 / 卸载**（逻辑在 `**lib/init/saferm.sh`**，安装时写入 `**/usr/local/bin/saferm**`）：

```bash
sudo ./init.sh install saferm      # 写入 /usr/local/bin/saferm 并 chmod +x
sudo ./init.sh uninstall saferm    # 删除 /usr/local/bin/saferm（不自动清空 /var/trash）
```

交互模式：**「安装单个组件」** 中选 **saferm 安全删除**；卸载在 **「卸载单个组件」** 中选 **saferm**。
`sudo ./init.sh status` 中会显示 saferm 是否已安装。

**目录与权限**：`**install saferm`** 时会直接创建 `**/var/trash**`、`**files**`、`**logs**` 并 `**chmod 1777**`；若目录被删，**首次再执行 `saferm`** 时脚本内仍会尝试创建（可能 `sudo`）。


| 路径                            | 用途                                              |
| ----------------------------- | ----------------------------------------------- |
| `/var/trash`                  | 回收站根                                            |
| `/var/trash/files`            | 被删除文件/目录的实际存放处（`mv` 目标）                         |
| `/var/trash/logs/*.trashinfo` | 元数据：原始路径、删除时间（类似 FreeDesktop Trash 的 trashinfo） |


**默认行为概要**：

- **普通文件**：直接 `mv` 进 `/var/trash/files`；若同名已存在，会把已有项改名为带时间戳的后缀，避免覆盖。
- **目录**：须加 `**-r`** 才处理目录，否则报错提示。
- **设备文件等特殊类型**：默认拒绝；加 `**-f`** 才允许（随后若未开 `-u`，仍会尝试进回收站，视权限而定）。
- **跨文件系统**：`mv` 不能跨设备完成「移动」时，脚本用 `**stat` 设备号**判断与回收站是否同盘；不同盘时会 **提示** 是否改为 **永久删除**（`rm`）。若坚持进回收站，需自行先拷贝到同盘再删，或接受提示走 `rm`。
- `**-u`（unsafe）**：绕过回收站，等同 `rm -rf`，请谨慎使用。

**常用选项**（可合并，如 `-rv`；`--` 之后按字面路径处理）：


| 选项          | 含义                    |
| ----------- | --------------------- |
| `-r`        | 递归处理目录                |
| `-f`        | 允许特殊文件等               |
| `-u`        | 永久删除，不进回收站            |
| `-v` / `-q` | 详细输出（默认偏详细）/ 安静       |
| `-n`        | 不写 `.trashinfo`       |
| `-a`        | 本次运行顺带按策略清理回收站        |
| `-c`        | **仅清理回收站**，不删命令行给出的路径 |


**回收站清理**（在已安装的 `**/usr/local/bin/saferm` 脚本开头** 改常量即可，改后即时生效）：

- `cleanup_days`：超过若干天的 **文件** 可被清理（`0` 表示不按天清理）。
- `max_trash_size`：回收站总大小上限（MB，`0` 表示不限制）；超出时按文件时间删最旧的。
- `auto_cleanup`：非空时，**每次**执行 saferm 都会尝试执行上述清理；否则仅在使用 `**-a`** 或 `**-c**` 时清理。

清理实现依赖 **GNU** `find`（如 `-printf`）、`stat -c` 等，适用于常见 **Linux** ECS 环境。

**使用示例**：

```bash
saferm /tmp/foo.txt
saferm -r /path/to/dir
saferm -a /data/tmp/old.log          # 删除并触发清理（若脚本里开启了 auto_cleanup 则不必 -a）
saferm -c                             # 只跑清理逻辑
saferm -- ./-starts-with-dash        # 路径以 - 开头时用 --
```

执行 `**install saferm**` 后会写入 `**/etc/profile.d/saferm-rm.sh**`（`alias rm='/usr/local/bin/saferm'`），并在 `**/etc/bash.bashrc**`、`**/etc/bashrc**`（若存在）、`**/etc/zshrc**`（若已存在且尚无标记块）末尾追加一行 **source** 该文件；`**install zsh`** 生成的 `**/etc/zshrc**` 模板内也含同一段。新开会话后交互式 `**rm**` 即走 saferm；`**uninstall saferm**` 会删掉 profile 片段并 **sed** 去掉上述标记块。`init.sh` 在安装 saferm 成功后会 **在本脚本进程内 `source` 该文件并开启 `expand_aliases`**，便于同一会话里继续用菜单时 `rm` 即 saferm；脚本内真实删除已统一为 `**/bin/rm**`，避免误进回收站。卸载 saferm 时会 `**unalias rm**` 并关闭 `expand_aliases`。你本地 SSH 外层 shell 仍须 **重新登录** 或自行 `source /etc/profile.d/saferm-rm.sh` 才生效（子进程无法改父 shell 环境）。

### 菜单项对照

- **1 全新安装**：多选模块（含可选 **saferm**）后一次性执行。
- **2 安装单个组件**：BBR / 防火墙 / Docker / Zsh / SSH / LNMP 全量或单容器 / **saferm** 等。
- **3 卸载单个组件**：与上对应卸载；LNMP 全量卸载可选是否删数据目录；可卸载 **saferm**。
- **4 更新配置**：代理、Docker/Alpine 源、PHP 版本/扩展、**LNMP 各组件镜像**（可触发单栈更新）、
SSH、ACME 邮箱、**ACME SSL 默认方式**、devops 用户等。
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
- `deploy-site.sh` 需存在于 `**/usr/local/bin/deploy-site.sh`** 且 devops 的 sudoers 才生效
（脚本里写的是该路径）。

---

## deploy-site.sh 操作说明

### 功能概要（deploy-site.sh）

- 依赖 `**lnmp-nginx`、`lnmp-php**`（及按站点选用的 `**lnmp-phpNN**`，`NN` = 无主版本点小写，与 init 生成的 `container_name` 一致）已运行；`**lnmp-acme**` 未运行时 `add` 会跳过 SSL 签发并告警，
`**ssl**` 子命令要求 acme 运行。
- **Laravel**：`public` 为 Web 根目录；Nginx、占位证书、Let's Encrypt（acme.sh）、`.env` 合并、
**composer**（容器内与站点目录属主一致）、**artisan**（`docker exec` 以 devops 身份、项目目录下
`php artisan`）。**默认**：`NEED_DB` / `RUN_SEED` / `NEED_HORIZON` 为 **y**；默认连库时需
`**--db-name`**（或交互填写），否则脚本会报错退出；不需要数据库时用 `**--need-db=n**`。
- **PHP 版本（每站点）**：`**--php-version=`**（如 `8.2`、`7.4`）须在 `**init.sh**` 所写配置里的 `**EXTRA_PHP_VERSIONS**` 中已声明；会写入 `**conf.d/<域名>.php-version**`，Nginx **fastcgi** 与 **composer / artisan / cron / Horizon** 路由到对应 `**lnmp-php`** + **无点号主版本** 容器（如 **7.4 → `lnmp-php74`**）。`**update**` 时可改该项以切换站点所用 PHP 镜像。
- **Laravel SSE（长连接）**：环境变量 `**LARAVEL_SSE_PREFIXES`** 为全局默认前缀列表（空格或逗号分隔，默认 `**wave**`）；`**--sse-prefixes=**` 或与 `**update**` 联用写入 `**conf.d/<域名>.sse-prefixes**`；亦可事后编辑该文件。细节以 `**deploy-site.sh --help**` 为准。
- **frontend**：Nginx 在 **代码就绪后**生成。未指定 `**--frontend-root`** 时：若站点目录下存在
`**dist/**` 则用 `dist`，否则 **站点根目录**即静态根。可用 `**--frontend-root`** 显式指定子目录。
- **Git**：`**--git=` 留空或省略**跳过 clone/pull；`**--git-branch`** 指定分支/标签（clone 使用
`--single-branch`；已有仓库时 fetch + checkout + pull）。`**list**`：有 `.git`、或有 `artisan`、
或站点目录非空则状态为「已部署」。

#### SSL：`--dns` 与主流 DNS（acme.sh）

- `**webroot**`：HTTP-01，需本机 80；无额外密钥参数（默认）。
- `**dns_cf**`（Cloudflare）：`--cf-token` → `CF_Token`。
- `**dns_ali**`（阿里云解析）：`--ali-key` / `--ali-secret` → `Ali_Key` / `Ali_Secret`。
- `**dns_dp**`（DNSPod 国际版 API）：`--dp-id` / `--dp-key` → `DP_Id` / `DP_Key`。
- `**dns_gd**`（GoDaddy）：`--gd-key` / `--gd-secret` → `GD_Key` / `GD_Secret`。
- `**dns_aws**`（AWS Route53）：`--aws-access-key` / `--aws-secret-key` →
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`。
- `**dns_tencent**`（腾讯云 DNS / DNSPod API）：`--tencent-secret-id` /
`--tencent-secret-key` → `Tencent_SecretId` / `Tencent_SecretKey`。

更多 DNS 插件见 [acme.sh DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)。未内置的供应商可在
`lnmp-acme` 容器内按官方文档自行调用 `acme.sh --dns dns_xxx`。

### 安装到系统路径（与 init 中 sudoers 一致）

脚本以自身所在目录查找 `**lib/**`；复制到 `**/usr/local/bin**` 时须**同时复制同级的 `lib` 目录**，否则会按 `**_LIB_RAW_BASE`** 在线拉取（需出站网络可用）。

```bash
sudo cp deploy-site.sh /usr/local/bin/deploy-site.sh
sudo cp -r lib /usr/local/bin/lib
sudo chmod +x /usr/local/bin/deploy-site.sh
```

### 子命令

- `**add**`：新站点；无参数时进入交互。
- `**update**`：要求 `**www/<域名>/` 目录已存在**。若存在 `**.git`**：`git pull`（可选
`**--git-branch**`）；若无 `.git`：跳过 Git 并提示。Laravel：**composer install**、可选 **migrate**、
**optimize**、有 Horizon 配置则重启；前端：检查静态目录、**nginx reload**。自动化可加 `**--run-migrate=y|n`**（及同类 y/n）避免交互。
- `**remove**`：删除 Nginx 配置、SSL 目录、**.sse-prefixes**、crontab/Horizon、可选删除代码目录。
- `**list`**：列出 `conf.d` 下站点及类型、SSL、Cron、部署状态等。
- `**status**`：`**--domain=<域名>**` 检查该站证书、容器、日志等；`**--all**` 遍历 `conf.d` 全部站点（概要）。
- `**ssl**`：对已有站点重新签发/续期证书。
- **（无参数）**：数字菜单（含站点运行状态一项），等价于选择上述功能。

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

sudo /usr/local/bin/deploy-site.sh status --domain=api.example.com
# sudo ... status --all

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

- `**--domain**`、`**--git**`（可空=跳过 Git）、`**--git-branch**`、`--type=laravel|frontend`
- `**--php-version**`：仅当 init 已为该主版本配置 `**EXTRA_PHP_VERSIONS**`（或该版本即为默认 `**lnmp-php**`）时有效（见上文）。
- **SSE**：`**--sse-prefixes=**`、环境变量 `**LARAVEL_SSE_PREFIXES**`
- `**status**`：`**--all**` 或 `**--domain**`
- Laravel：`**--app-name**`、`**--redis-host**`、`**--redis-port**`、`**--redis-password**`、
`**--need-db**`（默认 y）、`**--db-host**`、`**--db-name**`、`**--db-password**`、
`**--create-db**`、`**--run-migrate**`、`**--run-seed**`（默认 y）、`**--add-crontab**`、
`**--need-horizon**`（默认 y）
- `**--frontend-root**`：相对站点目录；留空则按是否存在 `**dist/**` 自动选择（见上文）
- 自定义环境：`**--env=KEY=VALUE**`（可多次）
- SSL：`**--dns**`（见上文 DNS 列表）、各云密钥、`**--force-ssl**`、`**--ssl-staging**`
- `**remove**`：`**--yes**` 跳过部分确认

完整列表见：`sudo /usr/local/bin/deploy-site.sh --help`（未安装到该路径时改为
`sudo ./deploy-site.sh --help`）

### 日志路径（deploy-site.sh）

- `/data/docker-lnmp/logs/deploy-site.log`

### 注意事项（deploy-site.sh）

- Let's Encrypt **速率限制**：同一域名 7 天内正式证书约 5 张；遇 429 可等待重试或临时
`--ssl-staging`。
- **非 root** 执行会失败；**devops**：`init.sh` 写入 `/etc/sudoers.d/devops-deploy`，对 **组
`devops**` 授予 `NOPASSWD: /usr/local/bin/deploy-site.sh`；`DEVOPS_USER` 会加入该组，故可用
`sudo /usr/local/bin/deploy-site.sh ...`（勿改组名，否则须同步改 sudoers）。
- 默认 `**NEED_DB=y**` 的 Laravel 部署必须提供 `**--db-name**`（或交互输入）；`**update**` 对无
`**.git**` 的目录不会执行 pull，请在主机上先同步好代码再执行。

---

## 典型流程

1. 控制台用 root 或密钥登录 ECS，按「快速使用」一节执行 `bootstrap.sh` 或 `git clone` 仓库到
  `/opt/alibaba-cloud-ecs-deployment`。
2. `cd /opt/alibaba-cloud-ecs-deployment && sudo bash init.sh`（若已是 root 可省略 `sudo`），完成
  Docker、LNMP、devops、SSH、防火墙、ACME 邮箱等。
3. 若使用 Git：为 devops 配置 SSH 公钥，保证能 clone/pull 私有仓库。
4. `sudo bash deploy-site.sh add`（或带全参数）添加站点；浏览器访问 `https://域名` 验证。
  `**deploy-site.sh` 移到其它目录执行时须有同级 `**lib/**`（或与「安装到系统路径」一节相同做法）；否则依赖 curl/wget 从 `**_LIB_RAW_BASE**` 拉取缺失文件。

---

## 配置文件与版本

- **全局配置**：`/etc/lnmp-env.conf`（由 `init.sh` 维护；`deploy-site.sh` 会 source 以统一数据目录等
变量）。与 LNMP 相关的常见键包括：`LNMP_SERVICES`、`PHP_VERSION`、`PHP_EXTENSIONS`、
`**EXTRA_PHP_VERSIONS`**、
`NGINX_IMAGE`、`MYSQL_IMAGE`、`REDIS_IMAGE`、`ACME_IMAGE`、`ACME_EMAIL`、`ACME_SSL_DNS_DEFAULT`、
`CONTAINER_WWW`、`LNMP_DATA_DIR` 等（完整列表以生成文件或 `sudo ./init.sh --help` 为准）。
- **仅限 `deploy-site` 进程**：环境变量 `**LARAVEL_SSE_PREFIXES`** 可写入 shell 配置文件或在调用前导出，不写则走脚本内默认值；与 `/etc/lnmp-env.conf` 无必填关联。
- 脚本内版本号均为 **2.0.0**（以脚本内 `VERSION=` 为准）。

