# PM2 进程名以 ecosystem 为准

状态：**已定并已实现**

## 结论

| 项 | 决定 |
|---|------|
| 现象 | 部署日志写 `PM2 进程 lnmp-api-slimppt-com 不存在，重新 setup`，随后再跑一遍 `npm install`。机器上的进程名是 `slimppt-gateway` |
| 原因 | `pm2_app_name` 只用域名推导 `lnmp-<点换成横线>`。`pm2 start ecosystem.config.cjs --name` 不会覆盖文件里的 `apps[].name` |
| 进程名 | 站点目录有 `ecosystem.config.cjs` 或 `.js`，且第一个字符串字面量 `name` 能读出来时，用这个名字做 `describe` / `reload` / `delete` |
| 启动命令 | ecosystem 已有 `name` 时不再附加 `--name`。没有这个字段时仍用 `lnmp-<域名>` |
| 回退 | 没有 ecosystem，或 `name` 不是普通字面量时，仍用 `lnmp-<域名>`（`pm2 start npm --name`） |

## 过程

部署日志里的查找名是 `lnmp-api-slimppt-com`（`api.slimppt.com` 按旧规则生成）。同一台机器上 `pm2` 列表里的名字是 `slimppt-gateway`，与 gateway 的 ecosystem 一致。

因此每次 `reload_pm2_site` 的 `pm2 describe` 失败，走进 `setup_pm2`，依赖安装执行两次，也碰不到已经在跑的进程。

名字以 ecosystem 为准：那是 PM2 实际注册、也是之后要 `reload` 的进程。域名推导名只留给没有 ecosystem 名字的 `npm start`。
