# shellcheck shell=bash

[[ "$(id -u)" -ne 0 ]] && die "请用 root 执行"

DEVOPS_USER=${DEVOPS_USER:-devops}
id "${DEVOPS_USER}" &>/dev/null || die "用户 ${DEVOPS_USER} 不存在，请先运行 init.sh"

