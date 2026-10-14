# Spring 站点跑在宿主机 JVM 上

状态：已被 [0003](0003-spring-site-in-container.md) 取代。下面的决定不再执行。

Spring 站点是通用站点类型 `--type=spring`，不绑定某一个仓库。Java 运行时是 init 组件，装在宿主机上。每个站点由 systemd 拉起一个 JVM 进程，Caddy 反代到该进程。这和 PM2 站点同一形状：运行时在宿主机，Web 入口仍是现有 Caddy。

## Considered Options

- 每个站点一个带 JRE 的容器。要另管一套容器生命周期，和「一个 Caddy、多种站点」不一致。
- 只复用 proxy 站点类型，jar 由人自己起。`status` 和 `remove` 管不到进程。

## Consequences

MySQL、Postgres、Redis 只在 Docker 网络 `lnmp-net` 里，3306 / 5432 / 6379 没有映射到宿主机。PHP 能用主机名 `mysql`，是因为它和数据库在同一个网络。宿主机上的 JVM 不能这样连。数据库怎么接是后续决定。
