# npm registry 可配置化

状态：**已定并已实现**

## 结论

| 项 | 决定 |
|---|------|
| 要做 | npm registry 可配，不再写死 |
| 暴露面 | CLI `--npm-registry=` + `/etc/lnmp-env.conf` 的 `NPM_REGISTRY` + 交互菜单 + `status` |
| 出厂默认 | `https://registry.npmmirror.com`，写在 `init.sh` 顶部 `NPM_REGISTRY_DEFAULT` |
| 官方 | 空字符串：`npm config delete registry`；CLI 传空或 `-` |
| 作用范围 | 只对 devops 做 `npm config set/delete`（`~/.npmrc`）。不单独配 pnpm/yarn |
| 何时生效 | `install_node` 时应用；交互「更新配置 → npm registry」立刻再执行，不重装 Node |
| 与 Node 镜像 | 解耦。`FNM_NODE_DIST_MIRROR_DEFAULT` 同样提到 `init.sh` 顶部 |

覆盖顺序：`init.sh` 出厂默认 → 已保存的 `/etc/lnmp-env.conf` → CLI / 交互。

## 过程

Round 1 同意：暴露面对齐 Docker/Alpine；默认 npmmirror；空 = 官方；只写 `~/.npmrc`；改配置立刻生效。

Round 2 确认 **C**：出厂 URL 放 `init.sh` 顶部，运行时再用 CLI/菜单覆盖。

## 实现要点

- 改出厂默认：编辑 `init.sh` 里 `NPM_REGISTRY_DEFAULT` / `FNM_NODE_DIST_MIRROR_DEFAULT`。
- `conf_load` 仅在 `NPM_REGISTRY` **未设置**时套用出厂默认，以便 conf 里的空值（官方）能保住。
- 交互预设：npmmirror / 官方 / 自定义。自定义输入 `-` 也是官方。
- 部署侧 pnpm / Yarn 1 会读 devops 的 `~/.npmrc`；Yarn Berry 未覆盖。
