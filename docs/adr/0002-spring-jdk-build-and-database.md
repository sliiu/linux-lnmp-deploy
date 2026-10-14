# Spring 站点只用 Temurin 21，构建看 wrapper，不为它建库

状态：宿主机上的 JDK / Maven / Gradle 已被 [0003](0003-spring-site-in-container.md) 取代。不建库、不改应用配置仍然有效。

Java 运行时只装 Eclipse Temurin 21，放在 `/opt/java/temurin-21`。不为每个站点选 JDK 版本。构建先用仓库里的 wrapper；没有 wrapper 时，部署这一次再装对应的 Maven 或 Gradle。不为 Spring 站点建库，也不改它的配置文件。

## Considered Options

- 同时提供 Dragonwell 或发行版 OpenJDK，并允许 `--java-version`。一台机器一个 JDK 就够，多版本要在 systemd 和构建工具之间来回切。
- 把 Maven、Gradle 放进 `install java`。多数仓库自带 wrapper，用不到的工具不必装上。
- 像 Laravel 一样建库、改 `application.yml`。MySQL、Postgres、Redis 只在 Docker 网络 `lnmp-net` 里，端口没有映射出来。PHP 能用主机名 `mysql`，是因为它和数据库在同一个网络。宿主机上的 JVM 不能这样连。连接信息留在应用自己的配置里，或者用外部数据库。

## Consequences

`init.sh install java` 只保证 `java -version` 是 21。站点要编译时，有 `gradlew` 就走 Gradle，否则走 Maven；两边的构建文件都在且没有 `gradlew` 时走 Maven。缺 wrapper 才下载固定版本的 Maven 或 Gradle，并把 Maven Central 指到阿里云镜像。卸载 JDK 不停掉已经装好的构建工具，也不删站点代码。
