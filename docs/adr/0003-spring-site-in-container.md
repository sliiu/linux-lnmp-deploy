# Spring 站点跑在容器里

状态：取代 [0001](0001-spring-site-on-host-jvm.md)。

Spring 站点是通用站点类型 `--type=spring`。Java 运行时是 `init.sh install java` 拉下来的容器镜像。每个站点是一个容器，和 `lnmp-caddy` 在同一个 Docker 网络上。Caddy 反代到容器名和容器内端口。

宿主机 JVM 进不了 `lnmp-net`。改成容器之后，不再需要宿主机 JDK、宿主机 Maven/Gradle，也不再需要 systemd 单元。

## Considered Options

- 保留宿主机进程，Caddy 通过网关 IP 反代。用户要求尽量容器化，这条不做。

## Consequences

Spring 端口只在容器内监听，默认 8080，不映射到宿主机，防火墙也不放行。Caddy 使用容器名，不用宿主机网关。应用容器和 MySQL、Postgres、Redis 在同一网络上，配置里如果写了主机名 `mysql`、`postgres`、`redis`，可以连过去。脚本仍然不建库，也不改 `application.yml` / `application.properties`。
