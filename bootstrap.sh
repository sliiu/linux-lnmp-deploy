#!/bin/bash
# 一键引导：克隆/更新仓库后执行 init.sh 或 deploy-site.sh
# 使用：
#   curl -fsSL https://gitee.com/qing-u/alibaba-cloud-ecs-deployment/raw/main/bootstrap.sh | bash -s init.sh
#   curl -fsSL https://gitee.com/qing-u/alibaba-cloud-ecs-deployment/raw/main/bootstrap.sh | bash -s deploy-site.sh add --domain=example.com ...
set -euo pipefail

REPO_URL="${REPO_URL:-https://gitee.com/qing-u/alibaba-cloud-ecs-deployment.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/alibaba-cloud-ecs-deployment}"

TARGET="${1:-init.sh}"; shift || true
case "$TARGET" in
  init.sh|deploy-site.sh) ;;
  *) echo "✗ 未知目标脚本: ${TARGET}（仅支持 init.sh / deploy-site.sh）" >&2; exit 1 ;;
esac

if ! command -v git >/dev/null 2>&1; then
  if   command -v dnf      >/dev/null 2>&1; then dnf install -y git
  elif command -v yum      >/dev/null 2>&1; then yum install -y git
  elif command -v apt-get  >/dev/null 2>&1; then apt-get update -y && apt-get install -y git
  else echo "✗ 请先安装 git" >&2; exit 1
  fi
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" fetch --depth=1 origin "$REPO_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/${REPO_BRANCH}"
else
  rm -rf "$INSTALL_DIR"
  git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/${TARGET}" 2>/dev/null || true
exec bash "$INSTALL_DIR/${TARGET}" "$@"
