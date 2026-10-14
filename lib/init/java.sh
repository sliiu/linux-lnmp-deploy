# shellcheck shell=bash

# Java 运行时是四张容器镜像，不是宿主机 JDK。

JAVA_MARKER="/etc/java-init.done"
JAVA_IMAGE_DEFAULT="${JAVA_IMAGE_DEFAULT:-eclipse-temurin:21-jre}"
JAVA_JDK_IMAGE_DEFAULT="${JAVA_JDK_IMAGE_DEFAULT:-eclipse-temurin:21-jdk}"
MAVEN_IMAGE_DEFAULT="${MAVEN_IMAGE_DEFAULT:-maven:3.9.11-eclipse-temurin-21}"
GRADLE_IMAGE_DEFAULT="${GRADLE_IMAGE_DEFAULT:-gradle:8.14.3-jdk21}"

_java_image_or_default() {
  local cur="$1" fallback="$2"
  if [[ -n "$cur" ]]; then
    printf '%s' "$cur"
  else
    printf '%s' "$fallback"
  fi
}

java_image_name() { _java_image_or_default "${JAVA_IMAGE:-}" "$JAVA_IMAGE_DEFAULT"; }
java_jdk_image_name() { _java_image_or_default "${JAVA_JDK_IMAGE:-}" "$JAVA_JDK_IMAGE_DEFAULT"; }
java_maven_image_name() { _java_image_or_default "${MAVEN_IMAGE:-}" "$MAVEN_IMAGE_DEFAULT"; }
java_gradle_image_name() { _java_image_or_default "${GRADLE_IMAGE:-}" "$GRADLE_IMAGE_DEFAULT"; }

java_image_present() {
  local img="$1"
  [[ -n "$img" ]] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  docker image inspect "$img" >/dev/null 2>&1
}

is_java_ok() {
  [[ -f "$JAVA_MARKER" ]] || return 1
  java_image_present "$(java_image_name)" || return 1
  java_image_present "$(java_jdk_image_name)" || return 1
  java_image_present "$(java_maven_image_name)" || return 1
  java_image_present "$(java_gradle_image_name)" || return 1
}

_java_remove_host_tools() {
  local removed=0
  if [[ -e /opt/java || -e /opt/maven || -e /opt/gradle ]]; then
    rm -rf /opt/java /opt/maven /opt/gradle
    removed=1
  fi
  [[ "$removed" -eq 1 ]] && ok "已删除宿主机上的 /opt/java、/opt/maven、/opt/gradle"
}

_java_remove_legacy_units() {
  local f name
  shopt -s nullglob
  for f in /etc/systemd/system/lnmp-*.service; do
    grep -q 'lnmp-spring-site' "$f" 2>/dev/null || continue
    name="$(basename "$f")"
    warn "删除旧的 Spring systemd 单元 ${name}"
    systemctl disable --now "$name" 2>/dev/null || true
    rm -f "$f"
  done
  shopt -u nullglob
  systemctl daemon-reload 2>/dev/null || true
}

_java_remove_spring_containers() {
  local id name
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null || true)"
    name="${name#/}"
    warn "删除 Spring 容器 ${name:-$id}"
    docker rm -f "$id" >/dev/null 2>&1 || warn "删除容器失败: ${id}"
  done < <(docker ps -aq --filter label=lnmp.role=spring 2>/dev/null || true)
  while IFS= read -r name; do
    [[ "$name" == lnmp-spring-* ]] || continue
    warn "删除 Spring 容器 ${name}"
    docker rm -f "$name" >/dev/null 2>&1 || warn "删除容器失败: ${name}"
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
}

_java_apply_image_defaults() {
  JAVA_IMAGE="$(java_image_name)"
  JAVA_JDK_IMAGE="$(java_jdk_image_name)"
  MAVEN_IMAGE="$(java_maven_image_name)"
  GRADLE_IMAGE="$(java_gradle_image_name)"
}

install_java() {
  hr; info "安装 Java 运行时（容器镜像）"; echo ""

  is_docker_ok || die "安装 Java 运行时需要 Docker；请先执行 init.sh install docker"
  _java_apply_image_defaults

  local img
  for img in "$JAVA_IMAGE" "$JAVA_JDK_IMAGE" "$MAVEN_IMAGE" "$GRADLE_IMAGE"; do
    info "拉取 ${img} ..."
    docker pull "$img" || die "拉取镜像失败: ${img}"
    java_image_present "$img" || die "镜像未就绪: ${img}"
    ok "已拉取 ${img}"
  done

  _java_remove_host_tools
  _java_remove_legacy_units
  : > "$JAVA_MARKER"
  ok "Java 运行时就绪（运行 ${JAVA_IMAGE}，构建 JDK ${JAVA_JDK_IMAGE}）"
}

uninstall_java() {
  hr; info "卸载 Java 运行时"; echo ""

  _java_remove_spring_containers
  _java_remove_legacy_units
  _java_remove_host_tools
  rm -f "$JAVA_MARKER"
  JAVA_IMAGE=""
  JAVA_JDK_IMAGE=""
  MAVEN_IMAGE=""
  GRADLE_IMAGE=""
  ok "Java 运行时已卸载（容器已删除，镜像保留，站点代码保留）"
}
