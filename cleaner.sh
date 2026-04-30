#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2026.04-fixed"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

LOG_FILE="/var/log/debian-deep-clean.log"
LOCK_FILE="/run/debian-deep-clean.lock"

KEEP_KERNELS="${KEEP_KERNELS:-2}"
TMP_DAYS="${TMP_DAYS:-0}"
USER_CACHE_DAYS="${USER_CACHE_DAYS:-14}"
SERVICE_CACHE_DAYS="${SERVICE_CACHE_DAYS:-7}"
JOURNAL_TIME="${JOURNAL_TIME:-7d}"
JOURNAL_SIZE="${JOURNAL_SIZE:-256M}"

APT_OPTS=(
  -y
  -o Dpkg::Options::=--force-confold
  -o APT::Get::Assume-Yes=true
  -o APT::Get::AutomaticRemove=true
  -o APT::Get::Show-Upgraded=true
)

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_BOLD=""
fi

log() {
  local level="$1"
  local msg="$2"
  local color="$C_BLUE"

  case "$level" in
    OK) color="$C_GREEN" ;;
    WARN) color="$C_YELLOW" ;;
    ERROR) color="$C_RED" ;;
    STEP) color="$C_BOLD" ;;
    RUN) color="$C_BLUE" ;;
  esac

  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  printf '%b[%s]%b %s\n' "$color" "$level" "$C_RESET" "$msg"
}

die() {
  log ERROR "$*"
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no="$1"
  log ERROR "第 ${line_no} 行失败，退出码 ${exit_code}：${BASH_COMMAND}"
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

quote_cmd() {
  printf '%q ' "$@"
}

try() {
  log RUN "$(quote_cmd "$@")"
  "$@" >> "$LOG_FILE" 2>&1 || {
    local code=$?
    log WARN "命令失败但已跳过，退出码 ${code}：$(quote_cmd "$@")"
    return 0
  }
}

used_bytes() {
  df -B1 --output=used / | awk 'NR==2 {print $1}'
}

human_size() {
  numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"
}

phase() {
  local name="$1"
  shift

  local before after freed
  before="$(used_bytes)"

  log STEP "$name"
  "$@" || log WARN "${name} 部分步骤失败，已继续执行"

  sync || true
  after="$(used_bytes)"

  freed=$((before - after))
  (( freed < 0 )) && freed=0

  log OK "${name}：释放 $(human_size "$freed")"
}

init_runtime() {
  [[ "${EUID}" -eq 0 ]] || die "必须使用 root 运行"
  [[ -f /etc/debian_version ]] || die "仅支持 Debian 系系统"

  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" || true

  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有一个清理任务正在运行"

  log STEP "Debian Deep Clean ${VERSION}"
  log STEP "一键清理开始"
  log WARN "Docker 数据卷不会被清理"
}

wait_apt_locks() {
  command_exists fuser || return 0

  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
    /var/lib/apt/lists/lock
  )

  local waited=0
  local max_wait=300

  while true; do
    local busy=0

    for lock in "${locks[@]}"; do
      if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
        busy=1
        break
      fi
    done

    (( busy == 0 )) && break
    (( waited >= max_wait )) && die "APT / dpkg 锁等待超时"

    log WARN "检测到 APT / dpkg 锁，等待 3 秒"
    sleep 3
    waited=$((waited + 3))
  done
}

apt_try() {
  wait_apt_locks
  try apt-get "${APT_OPTS[@]}" "$@"
}

repair_package_state() {
  wait_apt_locks
  try dpkg --configure -a
  apt_try -f install
}

update_package_index() {
  apt_try update
}

purge_residual_configs() {
  local pkgs=()

  mapfile -t pkgs < <(
    dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null \
      | awk '$1 ~ /^rc/ {print $2}' \
      | sort -u
  )

  if ((${#pkgs[@]})); then
    apt_try purge "${pkgs[@]}"
  else
    log OK "没有残留配置包"
  fi
}

installed_pkgs() {
  dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' "$@" 2>/dev/null \
    | awk '$1 == "ii" {print $2}' \
    || true
}

is_in_list() {
  local needle="$1"
  shift

  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done

  return 1
}

cleanup_old_kernels() {
  local current_kernel
  current_kernel="$(uname -r)"

  local image_pkgs=()
  local versions=()
  local keep_versions=()
  local remove_versions=()
  local all_kernel_pkgs=()
  local remove_pkgs=()

  mapfile -t image_pkgs < <(
    installed_pkgs \
      'linux-image-[0-9]*' \
      'pve-kernel-[0-9]*' \
      'proxmox-kernel-[0-9]*'
  )

  if ((${#image_pkgs[@]} == 0)); then
    log OK "没有发现可处理的内核包"
    return 0
  fi

  mapfile -t versions < <(
    printf '%s\n' "${image_pkgs[@]}" \
      | sed -E 's/^(linux-image-|pve-kernel-|proxmox-kernel-)//' \
      | grep -E '^[0-9]' \
      | sort -V -u
  )

  mapfile -t keep_versions < <(
    printf '%s\n' "${versions[@]}" | sort -V | tail -n "$KEEP_KERNELS"
  )

  local version
  for version in "${versions[@]}"; do
    if [[ "$version" == "$current_kernel" ]] || is_in_list "$version" "${keep_versions[@]}"; then
      continue
    fi

    remove_versions+=("$version")
  done

  if ((${#remove_versions[@]} == 0)); then
    log OK "没有旧内核需要删除，当前内核：${current_kernel}"
    return 0
  fi

  mapfile -t all_kernel_pkgs < <(
    installed_pkgs \
      'linux-image-[0-9]*' \
      'linux-headers-[0-9]*' \
      'linux-modules-[0-9]*' \
      'linux-modules-extra-[0-9]*' \
      'pve-kernel-[0-9]*' \
      'proxmox-kernel-[0-9]*' \
      'proxmox-headers-[0-9]*'
  )

  local base pkg
  for version in "${remove_versions[@]}"; do
    base="${version%-*}"

    for pkg in "${all_kernel_pkgs[@]}"; do
      [[ "$pkg" == *"$current_kernel"* ]] && continue

      if [[ "$pkg" == *"$version"* || "$pkg" == *"${base}-common"* ]]; then
        remove_pkgs+=("$pkg")
      fi
    done
  done

  mapfile -t remove_pkgs < <(
    printf '%s\n' "${remove_pkgs[@]}" | sort -u
  )

  if ((${#remove_pkgs[@]})); then
    log WARN "当前运行内核：${current_kernel}"
    log WARN "保留最新内核数量：${KEEP_KERNELS}"
    log WARN "即将删除旧内核包：$(printf '%s ' "${remove_pkgs[@]}")"
    apt_try purge "${remove_pkgs[@]}"

    if command_exists update-grub; then
      try update-grub
    elif command_exists grub-mkconfig && [[ -d /boot/grub ]]; then
      try grub-mkconfig -o /boot/grub/grub.cfg
    fi
  else
    log OK "未匹配到需要删除的旧内核包"
  fi
}

cleanup_orphans() {
  if ! command_exists deborphan; then
    apt_try install deborphan
  fi

  command_exists deborphan || {
    log WARN "deborphan 不可用，跳过孤立包清理"
    return 0
  }

  local round
  for round in 1 2 3; do
    local orphans=()

    mapfile -t orphans < <(
      deborphan 2>/dev/null | sort -u || true
    )

    if ((${#orphans[@]} == 0)); then
      log OK "第 ${round} 轮：没有真正孤立库需要清理"
      break
    fi

    log WARN "第 ${round} 轮孤立库清理：$(printf '%s ' "${orphans[@]}")"
    apt_try purge "${orphans[@]}"
  done
}

cleanup_apt() {
  apt_try autoremove --purge
  apt_try autoclean
  apt_try clean

  try rm -f /var/cache/apt/archives/*.deb
  try rm -rf --one-file-system /var/cache/apt/archives/partial/*
  try rm -rf --one-file-system /var/lib/apt/lists/*
  try mkdir -p /var/lib/apt/lists/partial
}

cleanup_journal_and_logs() {
  if command_exists journalctl; then
    try journalctl --rotate
    try journalctl --vacuum-time="$JOURNAL_TIME"
    try journalctl --vacuum-size="$JOURNAL_SIZE"
  fi

  if command_exists logrotate && [[ -f /etc/logrotate.conf ]]; then
    try logrotate -f /etc/logrotate.conf
  fi

  if [[ -d /var/log ]]; then
    try find /var/log \
      -xdev \
      -type f \
      ! -path "$LOG_FILE" \
      \( -name '*.gz' -o -name '*.old' -o -regex '.*/.*\.[0-9]+' -o -name '*.xz' -o -name '*.zst' \) \
      -delete

    try find /var/log \
      -xdev \
      -type f \
      ! -path "$LOG_FILE" \
      \( -name '*.log' -o -name '*.out' -o -name '*.err' \) \
      -mtime +7 \
      -exec truncate -s 0 {} +

    try find /var/log \
      -xdev \
      -type f \
      ! -path "$LOG_FILE" \
      -size +100M \
      -mtime +3 \
      -exec truncate -s 0 {} +
  fi

  try rm -rf --one-file-system /var/crash/*
  try rm -rf --one-file-system /var/lib/systemd/coredump/*
}

cleanup_tmp() {
  if command_exists systemd-tmpfiles; then
    try systemd-tmpfiles --clean
  fi

  local dir
  for dir in /tmp /var/tmp; do
    [[ -d "$dir" ]] || continue

    try find "$dir" \
      -xdev \
      -mindepth 1 \
      -ignore_readdir_race \
      -atime +"$TMP_DAYS" \
      -exec rm -rf --one-file-system -- {} +
  done
}

clean_old_files_in_dir() {
  local dir="$1"
  local days="$2"

  [[ -d "$dir" ]] || return 0

  try find "$dir" \
    -xdev \
    -type f \
    -ignore_readdir_race \
    -atime +"$days" \
    -delete
}

cleanup_user_caches() {
  shopt -s nullglob dotglob

  local homes=(/root /home/*)
  local home

  for home in "${homes[@]}"; do
    [[ -d "$home" ]] || continue

    log WARN "清理用户旧缓存文件：${home}，阈值：${USER_CACHE_DAYS} 天未访问"

    clean_old_files_in_dir "$home/.cache" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.npm/_cacache" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.npm/_logs" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.cache/yarn" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.yarn/cache" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.pnpm-store" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.local/share/pnpm/store" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.cache/pip" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.cache/pypoetry" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.cache/go-build" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/go/pkg/mod/cache" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.composer/cache" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.cargo/registry/cache" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.cargo/git/db" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.gradle/caches" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.m2/repository" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.ivy2/cache" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.nuget/packages" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.local/share/Trash/files" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.local/share/Trash/info" "$USER_CACHE_DAYS"
    clean_old_files_in_dir "$home/.thumbnails" "$USER_CACHE_DAYS"
  done

  shopt -u nullglob dotglob
}

cleanup_language_caches() {
  if command_exists npm; then
    try npm cache clean --force
  fi

  if command_exists yarn; then
    try yarn cache clean --all
    try yarn cache clean
  fi

  if command_exists pnpm; then
    try pnpm store prune
  fi

  if command_exists pip; then
    try pip cache purge
  fi

  if command_exists pip3; then
    try pip3 cache purge
  fi

  if command_exists python3; then
    try python3 -m pip cache purge
  fi

  if command_exists composer; then
    try composer clear-cache
  fi

  if command_exists go; then
    try go clean -cache -testcache
  fi

  log WARN "已保留 Go module cache，避免破坏构建缓存依赖"
}

cleanup_container_stacks() {
  if command_exists docker; then
    if docker info >/dev/null 2>&1; then
      try find /var/lib/docker/containers \
        -type f \
        -name '*-json.log' \
        -exec truncate -s 0 {} +

      try docker container prune -f
      try docker image prune -af
      try docker builder prune -af
      try docker network prune -f

      log OK "Docker 清理完成：已清理停止容器、废弃镜像、构建缓存、未使用网络；数据卷已保留"
    else
      log WARN "Docker daemon 不可用，跳过 Docker 清理"
    fi
  fi

  if command_exists podman; then
    try podman container prune -f
    try podman image prune -af
    try podman system prune -af
    log OK "Podman 清理完成：未执行 volume prune"
  fi

  if command_exists nerdctl; then
    try nerdctl container prune -f
    try nerdctl image prune -af
    try nerdctl builder prune -af
    log OK "nerdctl 清理完成：未清理 volumes"
  fi

  if command_exists crictl; then
    try crictl rmi --prune
  fi
}

cleanup_snap_flatpak() {
  if command_exists snap; then
    try snap set system refresh.retain=2

    while read -r snap_name revision; do
      [[ -n "${snap_name:-}" && -n "${revision:-}" ]] || continue
      try snap remove "$snap_name" --revision="$revision"
    done < <(LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')

    while read -r snapshot_id; do
      [[ -n "${snapshot_id:-}" ]] || continue
      try snap forget "$snapshot_id"
    done < <(snap saved 2>/dev/null | awk 'NR>1 {print $1}')
  fi

  if command_exists flatpak; then
    try flatpak uninstall --unused -y
    try flatpak repair -y
  fi
}

cleanup_service_caches() {
  log WARN "服务级缓存只清理超过 ${SERVICE_CACHE_DAYS} 天未访问的旧文件，不删除目录"

  clean_old_files_in_dir /var/cache/man "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/fontconfig "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/debconf "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/app-info "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/PackageKit "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/snapd "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/fwupd "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/thumbnails "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/nginx "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/apache2 "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/lighttpd "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/bind "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/unbound "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/squid "$SERVICE_CACHE_DAYS"
  clean_old_files_in_dir /var/cache/varnish "$SERVICE_CACHE_DAYS"

  try rm -f /var/cache/ldconfig/aux-cache
}

final_maintenance() {
  try sync

  if command_exists updatedb; then
    try updatedb
  fi

  if command_exists systemctl; then
    try systemctl daemon-reload
    try systemctl reset-failed
  fi
}

main() {
  init_runtime

  local start_space end_space total_freed
  start_space="$(used_bytes)"

  phase "修复 dpkg / APT 状态" repair_package_state
  phase "更新 APT 索引" update_package_index
  phase "清理残留配置包" purge_residual_configs
  phase "清理旧内核" cleanup_old_kernels
  phase "低攻击性清理真正孤立库" cleanup_orphans
  phase "清理 APT 缓存与自动卸载包" cleanup_apt
  phase "清理 journald、系统日志、崩溃转储" cleanup_journal_and_logs
  phase "清理临时目录" cleanup_tmp
  phase "清理用户旧缓存文件" cleanup_user_caches
  phase "清理语言生态缓存" cleanup_language_caches
  phase "清理 Docker / Podman / containerd 资源，但保留数据卷" cleanup_container_stacks
  phase "清理 Snap / Flatpak 资源" cleanup_snap_flatpak
  phase "优雅清理服务级缓存" cleanup_service_caches
  phase "最终维护" final_maintenance

  end_space="$(used_bytes)"
  total_freed=$((start_space - end_space))
  (( total_freed < 0 )) && total_freed=0

  log OK "一键大扫除完成，总共释放：$(human_size "$total_freed")"
  log OK "日志位置：${LOG_FILE}"
  log OK "Docker / Podman / nerdctl 数据卷均未清理"
}

main "$@"
