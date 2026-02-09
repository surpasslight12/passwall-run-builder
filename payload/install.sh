#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — PassWall 一键安装脚本（OpenWrt APK 包管理器）
# install.sh — PassWall installer for OpenWrt (APK package manager)
# ─────────────────────────────────────────────────────────────────────────────
set -e

# ── 日志函数 / Logging ──────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()    { echo "[$(_ts)] [INFO]    $*"; }
log_warning() { echo "[$(_ts)] [WARNING] $*" >&2; }
log_error()   { echo "[$(_ts)] [ERROR]   $*" >&2; }
log_success() { echo "[$(_ts)] [OK]      $*"; }

# ── 错误处理 / Error handler ───────────────────────────────────────────────
# ERR trap is not available in all POSIX shells (e.g. ash/dash on OpenWrt).
# Fall back to EXIT trap that checks the exit code manually.
handle_error() {
  log_error "Script failed (exit $1) / 脚本失败（退出码 $1）"
  exit "$1"
}
if ! trap 'handle_error $?' ERR 2>/dev/null; then
  trap 'rc=$?; [ "$rc" -ne 0 ] && handle_error "$rc"' EXIT
fi

# ── 重试函数 / Retry helper ────────────────────────────────────────────────
retry() {
  local max="$1" delay="$2" max_delay="$3" label="$4"; shift 4
  local attempt=1
  while [ "$attempt" -le "$max" ]; do
    log_info "[$label] Attempt $attempt/$max…"
    if "$@"; then return 0; fi
    [ "$attempt" -eq "$max" ] && { log_error "$label failed after $max attempts"; return 1; }
    log_warning "Retrying in ${delay}s…"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    [ "$delay" -gt "$max_delay" ] && delay=$max_delay
  done
  return 1
}

# ── 版本提取 / Extract version ─────────────────────────────────────────────
extract_ver() {
  local base
  base=$(basename "$1" | sed -E "s/^$2[-_]//; s/\.apk$//")
  if echo "$base" | grep -q '_'; then
    echo "${base%_*}"
  else
    echo "${base%-all}"
  fi
}

# ── 主流程 / Main ─────────────────────────────────────────────────────────
log_info "Starting PassWall installation… / 开始安装 PassWall…"

# 检测安装包 / Detect packages
pw_pkg=""  pwzh_pkg=""
for f in luci-app-passwall-*.apk luci-app-passwall_*.apk; do
  [ -e "$f" ] && { pw_pkg="$f"; break; }
done
for f in luci-i18n-passwall-zh-cn-*.apk luci-i18n-passwall-zh-cn_*.apk; do
  [ -e "$f" ] && { pwzh_pkg="$f"; break; }
done

pw_ver=""
[ -n "$pw_pkg" ] && pw_ver=$(extract_ver "$pw_pkg" "luci-app-passwall")
if [ -z "$pw_pkg" ] || [ -z "$pw_ver" ]; then
  log_error "Cannot detect luci-app-passwall / 无法检测到 luci-app-passwall"
  exit 1
fi

pwzh_ver=""
if [ -n "$pwzh_pkg" ]; then
  pwzh_ver=$(extract_ver "$pwzh_pkg" "luci-i18n-passwall-zh-cn")
  [ -z "$pwzh_ver" ] && { log_error "Cannot parse i18n version / 无法解析中文语言包版本"; exit 1; }
fi

log_info "PassWall version: $pw_ver"

# 更新软件源 / Update package lists
retry 3 5 30 "apk update" apk update \
  || { log_error "Failed to update package lists / 更新软件源失败"; exit 1; }

# 升级旧依赖 / Upgrade legacy dependencies
if apk list -I libsodium | grep -Eq "[0-9]\.[0-9]\.[0-9][0-9]-[0-9]" \
   || apk list -I boost | grep -Eq "[0-9]\.[0-9][0-9]\.[0-9]-[0-9]"; then
  log_info "Upgrading legacy dependencies… / 更新旧版依赖…"
  apk add libev libsodium libudns boost boost-system boost-program_options \
    libltdl7 liblua5.3-5.3 libcares coreutils-base64 coreutils-nohup \
    || log_warning "Some dependencies failed to update / 部分依赖更新失败"
fi

# 构建安装列表 / Build install list
if [ -n "$pwzh_pkg" ]; then
  set -- "$pw_pkg" "$pwzh_pkg"
else
  log_info "i18n package not found, skipping / 未找到中文语言包"
  set -- "$pw_pkg"
fi

deps=0
if [ -d depends ]; then
  for dep in depends/*.apk; do
    [ -e "$dep" ] && { set -- "$@" "$dep"; deps=$((deps + 1)); }
  done
  log_info "Found $deps dependency packages / 找到 $deps 个依赖包"
fi
[ "$deps" -eq 0 ] && log_warning "No dependency packages / 未找到依赖包"

set -- "$@" haproxy

# 同版本强制重装 / Force reinstall if same version
if apk list -I luci-app-passwall | grep -q "$pw_ver"; then
  log_info "Same version detected, removing first… / 检测到同版本，先卸载…"
  for pkg in luci-app-passwall luci-i18n-passwall-zh-cn; do
    apk info -e "$pkg" >/dev/null 2>&1 && apk del "$pkg" || true
  done
fi

# 安装 / Install
log_info "Installing PassWall $pw_ver… / 正在安装 PassWall $pw_ver…"
apk add --allow-untrusted "$@" \
  || { log_error "Installation failed / 安装失败"; exit 1; }

log_success "PassWall $pw_ver installed / PassWall $pw_ver 安装完成"
log_info "Restart: /etc/init.d/passwall restart"

exit 0
