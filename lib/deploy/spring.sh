# shellcheck shell=bash

# Spring 站点：构建和运行都在容器里，加入 lnmp-caddy 所在的 Docker 网络。

JAVA_MARKER="${JAVA_MARKER:-/etc/java-init.done}"
JAVA_IMAGE_DEFAULT="${JAVA_IMAGE_DEFAULT:-eclipse-temurin:21-jre}"
JAVA_JDK_IMAGE_DEFAULT="${JAVA_JDK_IMAGE_DEFAULT:-eclipse-temurin:21-jdk}"
MAVEN_IMAGE_DEFAULT="${MAVEN_IMAGE_DEFAULT:-maven:3.9.11-eclipse-temurin-21}"
GRADLE_IMAGE_DEFAULT="${GRADLE_IMAGE_DEFAULT:-gradle:8.14.3-jdk21}"

site_spring_port_file() { printf '%s/%s.spring-port' "$NGINX_CONF" "$1"; }
site_spring_jar_file() { printf '%s/%s.spring-jar' "$NGINX_CONF" "$1"; }
site_spring_build_file() { printf '%s/%s.spring-build' "$NGINX_CONF" "$1"; }
site_spring_profiles_file() { printf '%s/%s.spring-profiles' "$NGINX_CONF" "$1"; }
site_spring_java_opts_file() { printf '%s/%s.spring-java-opts' "$NGINX_CONF" "$1"; }
site_spring_env_file() { printf '%s/%s.spring-env' "$NGINX_CONF" "$1"; }

spring_container_name() {
  printf 'lnmp-spring-%s' "${1//./-}"
}

_spring_image_or_default() {
  local cur="$1" fallback="$2"
  if [[ -n "$cur" ]]; then printf '%s' "$cur"; else printf '%s' "$fallback"; fi
}

spring_run_image() { _spring_image_or_default "${JAVA_IMAGE:-}" "$JAVA_IMAGE_DEFAULT"; }
spring_jdk_image() { _spring_image_or_default "${JAVA_JDK_IMAGE:-}" "$JAVA_JDK_IMAGE_DEFAULT"; }
spring_maven_image() { _spring_image_or_default "${MAVEN_IMAGE:-}" "$MAVEN_IMAGE_DEFAULT"; }
spring_gradle_image() { _spring_image_or_default "${GRADLE_IMAGE:-}" "$GRADLE_IMAGE_DEFAULT"; }

_spring_read_line() {
  local f="$1" v
  [[ -f "$f" ]] || return 1
  v="$(head -n1 "$f" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}

spring_port_for_site() {
  local p
  p="$(_spring_read_line "$(site_spring_port_file "$1")")" || return 1
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$p"
}

spring_listen_port() {
  local p
  p="$(spring_port_for_site "$1" 2>/dev/null || true)"
  [[ "$p" =~ ^[0-9]+$ ]] || p=8080
  printf '%s' "$p"
}

spring_jar_for_site() {
  _spring_read_line "$(site_spring_jar_file "$1")"
}

spring_container_state() {
  local name
  name="$(spring_container_name "$1")"
  docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || printf 'missing'
}

_spring_has_build_file() {
  local site_dir="${WWW_ROOT}/$1"
  [[ -f "${site_dir}/pom.xml" || -f "${site_dir}/build.gradle" || -f "${site_dir}/build.gradle.kts" ]]
}

_spring_write_meta_line() {
  local f="$1" v="$2"
  mkdir -p "${NGINX_CONF}"
  printf '%s\n' "$v" > "$f"
  chmod 644 "$f" 2>/dev/null || true
}

apply_spring_port_cli() {
  local domain="$1" v
  [[ "${SITE_SPRING_PORT_CLI:-0}" -ne 1 ]] && return 0
  v="${SITE_SPRING_PORT// /}"
  if [[ -z "$v" || "$v" = "-" ]]; then
    rm -f "$(site_spring_port_file "$domain")" 2>/dev/null || true
    info "站点 ${domain} Spring 端口：容器内 8080"
    return 0
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || die "无效 --spring-port: ${v}"
  [[ "$v" -ge 1 && "$v" -le 65535 ]] || die "无效 --spring-port: ${v}"
  _spring_write_meta_line "$(site_spring_port_file "$domain")" "$v"
  info "站点 ${domain} Spring 端口（容器内）：${v}"
}

apply_spring_jar_cli() {
  local domain="$1" v
  [[ "${SITE_SPRING_JAR_CLI:-0}" -ne 1 ]] && return 0
  v="${SITE_SPRING_JAR:-}"
  if [[ -z "$v" || "$v" = "-" ]]; then
    rm -f "$(site_spring_jar_file "$domain")" 2>/dev/null || true
    info "站点 ${domain} Spring jar：清除 → 自动选择"
    return 0
  fi
  _spring_validate_jar_rel "${WWW_ROOT}/${domain}" "$v"
  _spring_write_meta_line "$(site_spring_jar_file "$domain")" "$v"
  info "站点 ${domain} Spring jar：${v}"
}

apply_spring_build_cli() {
  local domain="$1" v
  [[ -z "${SPRING_BUILD:-}" ]] && return 0
  v="$SPRING_BUILD"
  case "$v" in
    y|n) ;;
    *) die "无效 --spring-build: ${v}（y|n）" ;;
  esac
  _spring_write_meta_line "$(site_spring_build_file "$domain")" "$v"
}

apply_spring_profiles_cli() {
  local domain="$1" v
  [[ "${SITE_SPRING_PROFILES_CLI:-0}" -ne 1 ]] && return 0
  v="${SITE_SPRING_PROFILES:-}"
  if [[ -z "$v" || "$v" = "-" ]]; then
    _spring_write_meta_line "$(site_spring_profiles_file "$domain")" "-"
    info "站点 ${domain} Spring profile：不设置 SPRING_PROFILES_ACTIVE"
    return 0
  fi
  [[ "$v" != *$'\n'* ]] || die "--spring-profiles 不能含换行"
  _spring_write_meta_line "$(site_spring_profiles_file "$domain")" "$v"
  info "站点 ${domain} Spring profile：${v}"
}

apply_spring_java_opts_cli() {
  local domain="$1" v
  [[ "${SITE_SPRING_JAVA_OPTS_CLI:-0}" -ne 1 ]] && return 0
  v="${SITE_SPRING_JAVA_OPTS:-}"
  _spring_validate_java_opts "$v"
  _spring_write_meta_line "$(site_spring_java_opts_file "$domain")" "$v"
  if [[ -n "$v" ]]; then
    info "站点 ${domain} JVM 参数：${v}"
  else
    info "站点 ${domain} JVM 参数：空"
  fi
}

_spring_effective_build() {
  local domain="$1" f v
  if [[ -n "${SPRING_BUILD:-}" ]]; then
    case "$SPRING_BUILD" in
      y|n) printf '%s' "$SPRING_BUILD"; return 0 ;;
      *) die "无效 --spring-build: ${SPRING_BUILD}（y|n）" ;;
    esac
  fi
  f="$(site_spring_build_file "$domain")"
  if [[ -f "$f" ]]; then
    v="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
    case "$v" in
      y|n) printf '%s' "$v"; return 0 ;;
    esac
  fi
  if _spring_has_build_file "$domain"; then
    printf 'y'
  else
    printf 'n'
  fi
}

_spring_effective_port() {
  local domain="$1" v
  if [[ "${SITE_SPRING_PORT_CLI:-0}" -eq 1 ]]; then
    v="${SITE_SPRING_PORT// /}"
    if [[ -z "$v" || "$v" = "-" ]]; then
      printf '8080'
      return 0
    fi
    [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 && "$v" -le 65535 ]] || die "无效 --spring-port: ${v}"
    printf '%s' "$v"
    return 0
  fi
  v="$(spring_port_for_site "$domain" 2>/dev/null || true)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=8080
  printf '%s' "$v"
}

_spring_effective_profiles() {
  local domain="$1" f v
  if [[ "${SITE_SPRING_PROFILES_CLI:-0}" -eq 1 ]]; then
    v="${SITE_SPRING_PROFILES:-}"
    [[ "$v" = "-" ]] && v=""
    printf '%s' "$v"
    return 0
  fi
  f="$(site_spring_profiles_file "$domain")"
  if [[ -f "$f" ]]; then
    v="$(head -n1 "$f" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$v" = "-" ]] && v=""
    printf '%s' "$v"
    return 0
  fi
  printf 'prod'
}

_spring_effective_java_opts() {
  local domain="$1" f v
  if [[ "${SITE_SPRING_JAVA_OPTS_CLI:-0}" -eq 1 ]]; then
    printf '%s' "${SITE_SPRING_JAVA_OPTS:-}"
    return 0
  fi
  f="$(site_spring_java_opts_file "$domain")"
  if [[ -f "$f" ]]; then
    v="$(head -n1 "$f" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    printf '%s' "$v"
    return 0
  fi
  printf ''
}

_spring_validate_java_opts() {
  local v="$1"
  [[ "$v" != *$'\n'* && "$v" != *$'\r'* ]] || die "--spring-java-opts 不能含换行"
  [[ "$v" != *\"* ]] || die "--spring-java-opts 不能含双引号"
}

_spring_jar_excluded() {
  case "$(basename "$1")" in
    *-plain.jar|*-sources.jar|*-javadoc.jar|*-tests.jar) return 0 ;;
  esac
  return 1
}

_spring_validate_jar_rel() {
  local site_dir="$1" rel="$2"
  [[ -n "$rel" && "$rel" != "-" ]] || die "--spring-jar 为空"
  case "$rel" in
    /*|*..*) die "--spring-jar 须为站点目录内的相对路径: ${rel}" ;;
  esac
  [[ "$rel" != *[[:space:]]* ]] || die "--spring-jar 不能含空格: ${rel}"
  [[ -f "${site_dir}/${rel}" ]] || die "找不到 jar: ${site_dir}/${rel}"
}

_spring_discover_jar() {
  local site_dir="$1"
  local -a found=()
  local f rel
  for f in "${site_dir}/target/"*.jar "${site_dir}/build/libs/"*.jar "${site_dir}/"*.jar; do
    [[ -f "$f" ]] || continue
    _spring_jar_excluded "$f" && continue
    found+=("$f")
  done
  if [[ ${#found[@]} -eq 1 ]]; then
    rel="${found[0]#"${site_dir}/"}"
    printf '%s' "$rel"
    return 0
  fi
  if [[ ${#found[@]} -eq 0 ]]; then
    die "未找到可执行 jar（已看 target/*.jar、build/libs/*.jar、站点根 *.jar；已排除 *-plain.jar、*-sources.jar、*-javadoc.jar、*-tests.jar）。请传 --spring-jar=（相对站点目录）"
  fi
  local -a rels=()
  for f in "${found[@]}"; do
    rels+=("${f#"${site_dir}/"}")
  done
  die "找到多个 jar，请传 --spring-jar=（相对站点目录）: ${rels[*]}"
}

_spring_resolve_jar() {
  local site_dir="${WWW_ROOT}/$1" req=""
  if [[ "${SITE_SPRING_JAR_CLI:-0}" -eq 1 ]]; then
    req="${SITE_SPRING_JAR:-}"
    if [[ -n "$req" && "$req" != "-" ]]; then
      _spring_validate_jar_rel "$site_dir" "$req"
      printf '%s' "$req"
      return 0
    fi
  fi
  _spring_discover_jar "$site_dir"
}

_spring_select_build_tool() {
  local site_dir="$1" gradle=0 pom=0
  [[ -f "${site_dir}/build.gradle" || -f "${site_dir}/build.gradle.kts" ]] && gradle=1
  [[ -f "${site_dir}/pom.xml" ]] && pom=1
  if [[ -f "${site_dir}/gradlew" && "$gradle" -eq 1 ]]; then
    printf 'gradlew'
  elif [[ -f "${site_dir}/mvnw" || "$pom" -eq 1 ]]; then
    if [[ -f "${site_dir}/mvnw" ]]; then
      printf 'mvnw'
    else
      printf 'maven'
    fi
  elif [[ "$gradle" -eq 1 ]]; then
    printf 'gradle'
  else
    printf 'none'
  fi
}

_spring_env_quote() {
  local v="$1"
  v="${v//$'\n'/}"
  v="${v//$'\r'/}"
  if [[ "$v" =~ ^[A-Za-z0-9_./:@+-]*$ ]]; then
    printf '%s' "$v"
    return 0
  fi
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

_spring_write_env_file() {
  local domain="$1" port="$2" profiles="$3"
  local file tmp line k
  local -a extras=()
  file="$(site_spring_env_file "$domain")"
  mkdir -p "${NGINX_CONF}"
  if [[ ${#CUSTOM_ENV[@]} -eq 0 && -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      k="${line%%=*}"
      case "$k" in
        SERVER_PORT|SERVER_ADDRESS|SPRING_PROFILES_ACTIVE) continue ;;
      esac
      extras+=("$line")
    done < "$file"
  else
    local kv v
    for kv in "${CUSTOM_ENV[@]}"; do
      k="${kv%%=*}"
      v="${kv#*=}"
      [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "无效 --env: ${kv}"
      case "$k" in
        SERVER_PORT|SERVER_ADDRESS)
          warn "忽略 --env=${k}（由站点端口与 SERVER_ADDRESS=0.0.0.0 写入）"
          continue
          ;;
        SPRING_PROFILES_ACTIVE)
          [[ -n "$profiles" ]] && continue
          ;;
      esac
      extras+=("${k}=$(_spring_env_quote "$v")")
    done
  fi
  tmp="$(mktemp)"
  {
    if [[ ${#extras[@]} -gt 0 ]]; then
      local extra
      for extra in "${extras[@]}"; do
        printf '%s\n' "$extra"
      done
    fi
    if [[ -n "$profiles" ]]; then
      printf 'SPRING_PROFILES_ACTIVE=%s\n' "$(_spring_env_quote "$profiles")"
    fi
    printf 'SERVER_PORT=%s\n' "$port"
    printf 'SERVER_ADDRESS=0.0.0.0\n'
  } > "$tmp"
  mv "$tmp" "$file"
  if ! chown root:root "$file" 2>/dev/null; then
    chown root "$file" 2>/dev/null || true
  fi
  chmod 600 "$file"
}

# 从正在提供 Caddy 的容器上读网络名，不写死 docker-lnmp_lnmp-net。
# 无 PHP 时是 lnmp-caddy；FrankenPHP 时 Caddy 在 lnmp-php 里。多网卡时优先名称里带 lnmp-net 的那个。
_spring_docker_network() {
  local src="" line="" name=""
  if docker inspect lnmp-caddy >/dev/null 2>&1; then
    src="lnmp-caddy"
  elif docker inspect lnmp-php >/dev/null 2>&1; then
    src="lnmp-php"
  else
    die "未找到 lnmp-caddy 或 lnmp-php，无法确定 Spring 容器要加入的 Docker 网络"
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *lnmp-net* ]]; then
      name="$line"
      break
    fi
    [[ -z "$name" ]] && name="$line"
  done < <(docker inspect "$src" --format '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}')
  [[ -n "$name" ]] || die "容器 ${src} 未加入任何 Docker 网络"
  printf '%s' "$name"
}

_spring_remove_legacy_unit() {
  local domain="$1" unit file
  unit="lnmp-${domain//./-}"
  file="/etc/systemd/system/${unit}.service"
  [[ -f "$file" ]] || return 0
  grep -q 'lnmp-spring-site' "$file" 2>/dev/null || return 0
  warn "删除旧的 Spring systemd 单元 ${unit}.service"
  systemctl disable --now "${unit}.service" 2>/dev/null || true
  rm -f "$file"
  systemctl daemon-reload 2>/dev/null || true
}

_spring_cache_prepare() {
  local root uid gid
  root="${DATA_DIR:-/data/docker-lnmp}/cache"
  uid="$(id -u "${DEVOPS_USER}")"
  gid="$(id -g "${DEVOPS_USER}")"
  mkdir -p "${root}/maven/repo" "${root}/gradle/home" "${root}/home"
  cat > "${root}/maven/settings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<settings>
  <localRepository>/cache/maven/repo</localRepository>
  <mirrors>
    <mirror>
      <id>aliyun-central</id>
      <mirrorOf>central</mirrorOf>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
EOF
  cat > "${root}/gradle/aliyun-init.gradle" <<'EOF'
allprojects { project ->
    project.buildscript.repositories {
        maven { url 'https://maven.aliyun.com/repository/public' }
    }
    project.repositories {
        maven { url 'https://maven.aliyun.com/repository/public' }
    }
}
EOF
  chown -R "${uid}:${gid}" "$root"
  chmod 644 "${root}/maven/settings.xml" "${root}/gradle/aliyun-init.gradle"
  printf '%s' "$root"
}

_spring_docker_build() {
  local image="$1" shell_cmd="$2" site_dir="$3" cache uid gid
  cache="$(_spring_cache_prepare)"
  uid="$(id -u "${DEVOPS_USER}")"
  gid="$(id -g "${DEVOPS_USER}")"
  docker image inspect "$image" >/dev/null 2>&1 || die "缺少镜像 ${image}；请先执行 init.sh install java"
  info "构建容器 ${image}：${shell_cmd}"
  docker run --rm \
    --user "${uid}:${gid}" \
    --entrypoint /bin/sh \
    -e HOME=/cache/home \
    -e GRADLE_USER_HOME=/cache/gradle/home \
    -v "${cache}/home:/cache/home" \
    -v "${cache}/maven:/cache/maven" \
    -v "${cache}/gradle:/cache/gradle" \
    -v "${site_dir}:/work" \
    -w /work \
    "$image" \
    -c "$shell_cmd" \
    || die "Spring 构建失败: ${shell_cmd}"
}

_spring_build_site() {
  local domain="$1" site_dir="${WWW_ROOT}/$1" build tool
  build="$(_spring_effective_build "$domain")"
  _spring_write_meta_line "$(site_spring_build_file "$domain")" "$build"
  [[ "$build" = "y" ]] || { info "跳过构建（spring-build=n）"; return 0; }
  tool="$(_spring_select_build_tool "$site_dir")"
  case "$tool" in
    gradlew)
      chmod +x "${site_dir}/gradlew"
      _spring_docker_build "$(spring_jdk_image)" \
        "./gradlew -I /cache/gradle/aliyun-init.gradle bootJar -x test" \
        "$site_dir"
      ;;
    mvnw)
      chmod +x "${site_dir}/mvnw"
      _spring_docker_build "$(spring_jdk_image)" \
        "./mvnw -B -s /cache/maven/settings.xml package -DskipTests" \
        "$site_dir"
      ;;
    maven)
      _spring_docker_build "$(spring_maven_image)" \
        "mvn -B -s /cache/maven/settings.xml package -DskipTests" \
        "$site_dir"
      ;;
    gradle)
      _spring_docker_build "$(spring_gradle_image)" \
        "gradle --no-daemon -I /cache/gradle/aliyun-init.gradle bootJar -x test" \
        "$site_dir"
      ;;
    none)
      info "无 pom.xml / build.gradle，跳过构建"
      ;;
  esac
  [[ "$tool" = "none" ]] || ok "构建完成"
}

_spring_start_container() {
  local domain="$1" jar_rel="$2" opts="$3"
  local cname site_dir image net uid gid envfile running tok
  local -a args=()
  cname="$(spring_container_name "$domain")"
  site_dir="${WWW_ROOT}/${domain}"
  image="$(spring_run_image)"
  net="$(_spring_docker_network)"
  uid="$(id -u "${DEVOPS_USER}")"
  gid="$(id -g "${DEVOPS_USER}")"
  envfile="$(site_spring_env_file "$domain")"
  docker image inspect "$image" >/dev/null 2>&1 || die "缺少镜像 ${image}；请先执行 init.sh install java"
  [[ -f "$envfile" ]] || die "缺少环境文件 ${envfile}"

  if [[ -n "$opts" ]]; then
    # shellcheck disable=SC2086
    for tok in $opts; do
      args+=("$tok")
    done
  fi
  args+=(-jar "/app/${jar_rel}")

  if docker inspect "$cname" >/dev/null 2>&1; then
    info "重建容器 ${cname}"
    docker rm -f "$cname" >/dev/null
  fi
  info "启动 ${cname}（网络 ${net}，不映射端口）"
  docker run -d \
    --name "$cname" \
    --restart unless-stopped \
    --network "$net" \
    --label "lnmp.site=${domain}" \
    --label "lnmp.role=spring" \
    --env-file "$envfile" \
    --user "${uid}:${gid}" \
    --entrypoint java \
    -v "${site_dir}:/app:ro" \
    "$image" \
    "${args[@]}" \
    >/dev/null || die "启动 Spring 容器失败: ${cname}。查看: docker logs ${cname}"
  sleep 1
  running="$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null || echo false)"
  if [[ "$running" != "true" ]]; then
    docker logs "$cname" 2>&1 | tail -n 40 || true
    die "Spring 容器 ${cname} 未在运行。查看: docker logs ${cname}"
  fi
  ok "Spring 容器已启动: ${cname}"
}

ensure_java_runtime() {
  local marker="${JAVA_MARKER:-/etc/java-init.done}" img
  [[ -f "$marker" ]] || die "未安装 Java 运行时（缺少 ${marker}）；请先执行 init.sh install java"
  command -v docker >/dev/null 2>&1 || die "未找到 docker；请先执行 init.sh install docker"
  docker info >/dev/null 2>&1 || die "Docker 未运行；请先执行 init.sh install docker"
  for img in "$(spring_run_image)" "$(spring_jdk_image)" "$(spring_maven_image)" "$(spring_gradle_image)"; do
    docker image inspect "$img" >/dev/null 2>&1 || die "缺少镜像 ${img}；请先执行 init.sh install java"
  done
  ok "Java 镜像: $(spring_run_image)"
}

setup_spring() {
  local domain="$1"
  local site_dir="${WWW_ROOT}/${domain}" port jar_rel profiles opts
  [[ -d "$site_dir" ]] || die "站点目录不存在: ${site_dir}"
  ensure_java_runtime
  id "${DEVOPS_USER}" &>/dev/null || die "用户 ${DEVOPS_USER} 不存在；请先执行 init.sh install devops"
  mkdir -p "${NGINX_CONF}"
  _spring_remove_legacy_unit "$domain"

  apply_spring_port_cli "$domain"
  apply_spring_build_cli "$domain"
  apply_spring_profiles_cli "$domain"
  apply_spring_java_opts_cli "$domain"

  port="$(_spring_effective_port "$domain")"
  _spring_write_meta_line "$(site_spring_port_file "$domain")" "$port"

  _spring_build_site "$domain"

  apply_spring_jar_cli "$domain"
  jar_rel="$(_spring_resolve_jar "$domain")"
  _spring_write_meta_line "$(site_spring_jar_file "$domain")" "$jar_rel"

  profiles="$(_spring_effective_profiles "$domain")"
  opts="$(_spring_effective_java_opts "$domain")"
  _spring_validate_java_opts "$opts"
  if [[ -z "$profiles" ]]; then
    _spring_write_meta_line "$(site_spring_profiles_file "$domain")" "-"
  else
    _spring_write_meta_line "$(site_spring_profiles_file "$domain")" "$profiles"
  fi
  _spring_write_meta_line "$(site_spring_java_opts_file "$domain")" "$opts"
  _spring_write_meta_line "$(site_spring_build_file "$domain")" "$(_spring_effective_build "$domain")"
  _spring_write_env_file "$domain" "$port" "$profiles"
  _spring_start_container "$domain" "$jar_rel" "$opts"
  ok "Spring 在容器内监听 0.0.0.0:${port}（不映射到宿主机）"
}

reload_spring_site() {
  local domain="$1"
  [[ "$(_site_type_for_domain "$domain")" = "spring" ]] || return 0
  setup_spring "$domain"
}

stop_spring_site() {
  local domain="$1" cname
  cname="$(spring_container_name "$domain")"
  if docker inspect "$cname" >/dev/null 2>&1; then
    docker rm -f "$cname" >/dev/null 2>&1 || true
    ok "已删除容器 ${cname}"
  fi
  _spring_remove_legacy_unit "$domain"
}
