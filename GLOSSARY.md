# 阿里云 ECS 部署

这套脚本用来初始化一台 ECS，并在上面按域名部署多个站点。

## Language

**组件**:
`init.sh` 可以单独安装或卸掉的一块主机能力。
_Avoid_: 模块, 基础环境, 环境

**站点**:
`deploy-site.sh` 按域名管理的一份部署，包含该域名的站点目录和 Caddy 站点配置。
_Avoid_: 网站, 项目, 应用

**站点类型**:
站点的分类，决定它如何构建，以及 Caddy 如何把请求转到它。
_Avoid_: 框架, 模板

**Java 运行时**:
用来构建和运行 Spring 站点的容器镜像。
_Avoid_: JRE, Java 环境, 基础环境

**Spring 站点**:
一种站点类型：应用跑在 LNMP Docker 网络里的一个容器中，Caddy 通过反代访问它。
_Avoid_: Java 站点
