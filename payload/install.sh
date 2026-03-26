#!/bin/sh
# install.sh — PassWall 一键安装脚本 (OpenWrt APK)
# PassWall installer for OpenWrt (APK package manager)
set -eu
set -o pipefail 2>/dev/null || true

log()      { printf '[INFO]  %s\n' "$*"; }
log_warn() { printf '[WARN]  %s\n' "$*"; }
err()      { printf '[ERROR] %s\n' "$*" >&2; }
die()      { err "$@"; exit 1; }

retry() {
  retry_max="$1"
  retry_delay="$2"
  shift 2
  retry_i=1
  while [ "$retry_i" -le "$retry_max" ]; do
    log "Attempt $retry_i/$retry_max: $*"
    "$@" && return 0
    [ "$retry_i" -eq "$retry_max" ] && { err "Failed after $retry_max attempts: $*"; return 1; }
    log_warn "Attempt $retry_i failed, retrying in ${retry_delay}s…"
    sleep "$retry_delay"
    retry_i=$((retry_i + 1))
  done
}

# ── 检测安装包 / Detect packages ──
log "Starting PassWall installation…"

[ -f SHA256SUMS ] || die "SHA256SUMS not found"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to verify payload integrity"
log "Verifying payload checksums…"
sha256sum -c SHA256SUMS >/dev/null || die "Payload checksum verification failed"

pw_pkg=""
for f in luci-app-passwall-*.apk luci-app-passwall_*.apk; do
  [ -e "$f" ] && { pw_pkg="$f"; break; }
done
[ -n "$pw_pkg" ] || die "luci-app-passwall package not found"

pw_ver=$(echo "$pw_pkg" | sed -E 's/luci-app-passwall[-_]//; s/[-_].*//')
log "PassWall: $pw_ver ($pw_pkg)"

zh_pkg=""
for f in luci-i18n-passwall-zh-cn-*.apk luci-i18n-passwall-zh-cn_*.apk; do
  [ -e "$f" ] && { zh_pkg="$f"; break; }
done

payload_has_pkg() {
  pkg_name="$1"
  for f in \
    "${pkg_name}"-*.apk "${pkg_name}"_*.apk \
    "depends/${pkg_name}"-*.apk "depends/${pkg_name}"_*.apk; do
    [ -e "$f" ] && return 0
  done
  return 1
}

append_install_pkg() {
  pkg_name="$1"
  shift
  [ -n "$pkg_name" ] || return 0
  for existing_pkg in "$@"; do
    [ "$existing_pkg" = "$pkg_name" ] && return 0
  done
  set -- "$@" "$pkg_name"
  INSTALL_PACKAGES="$*"
}

build_install_package_list() {
  INSTALL_PACKAGES="luci-app-passwall"
  [ -n "$zh_pkg" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES luci-i18n-passwall-zh-cn"

  if [ -f TOPLEVEL_PACKAGES ]; then
    while IFS= read -r pkg_name; do
      [ -n "$pkg_name" ] || continue
      case "$pkg_name" in
        luci-app-passwall|luci-i18n-passwall-zh-cn)
          continue
          ;;
      esac
      set -- $INSTALL_PACKAGES
      append_install_pkg "$pkg_name" "$@"
    done < TOPLEVEL_PACKAGES
  fi

  if payload_has_pkg dnsmasq-full; then
    set -- $INSTALL_PACKAGES
    append_install_pkg dnsmasq-full "$@"
  fi
}

queue_conflict_removal() {
  remove_pkg="$1"
  apk info -e "$remove_pkg" >/dev/null 2>&1 || return 0
  CONFLICT_REMOVALS="${CONFLICT_REMOVALS:+$CONFLICT_REMOVALS }$remove_pkg"
}

REPO_FILE=""
cleanup() {
  if [ -n "$REPO_FILE" ]; then
    rm -f "$REPO_FILE"
  fi
}
trap cleanup EXIT HUP INT TERM

# ── 构建安装列表 / Build install list ──
USE_EMBEDDED_REPO=0
[ -f packages.adb ] && USE_EMBEDDED_REPO=1

if [ "$USE_EMBEDDED_REPO" -eq 1 ]; then
  REPO_FILE="${TMPDIR:-/tmp}/passwall-apk-repositories.$$"
  : > "$REPO_FILE"
  printf 'file://%s/packages.adb\n' "$PWD" >> "$REPO_FILE"
  [ -f depends/packages.adb ] && printf 'file://%s/depends/packages.adb\n' "$PWD" >> "$REPO_FILE"

  build_install_package_list
  # shellcheck disable=SC2086
  set -- $INSTALL_PACKAGES

  CONFLICT_REMOVALS=""
  if payload_has_pkg dnsmasq-full; then
    queue_conflict_removal dnsmasq
    queue_conflict_removal dnsmasq-dhcpv6
  fi

  if [ -n "$CONFLICT_REMOVALS" ]; then
    log "Removing conflicting packages: $CONFLICT_REMOVALS"
    apk del $CONFLICT_REMOVALS || die "Failed to remove conflicting packages: $CONFLICT_REMOVALS"
  fi

  if [ -d depends ]; then
    log "Found $(find depends -maxdepth 1 -name '*.apk' 2>/dev/null | wc -l) dependency packages"
  fi
  log "Installing top-level packages: $*"
  log "Using embedded APK repositories"
  APK_ADD_EXTRA_ARGS="--repositories-file $REPO_FILE --no-cache --force-refresh"
else
  set -- "$pw_pkg"
  [ -n "$zh_pkg" ] && set -- "$@" "$zh_pkg"

  if [ -d depends ]; then
    for dep in depends/*.apk; do
      [ -e "$dep" ] && set -- "$@" "$dep"
    done
    log "Found $(find depends -maxdepth 1 -name '*.apk' 2>/dev/null | wc -l) dependency packages"
  fi
  APK_ADD_EXTRA_ARGS=""
fi

# ── 卸载旧版本 / Remove old version ──
if apk list -I luci-app-passwall 2>/dev/null | grep -q "luci-app-passwall"; then
  INSTALLED_VER=$(apk list -I luci-app-passwall 2>/dev/null | sed -E 's/.*-([0-9][^ ]*).*/\1/' | head -1)
  log "Installed version: ${INSTALLED_VER:-unknown}, new version: $pw_ver"
  log "Removing existing PassWall before install"
  apk del luci-app-passwall luci-i18n-passwall-zh-cn 2>/dev/null || true
fi

# ── 安装 / Install ──
log "Installing $pw_ver…"
if [ -n "$APK_ADD_EXTRA_ARGS" ]; then
  # shellcheck disable=SC2086
  apk add --allow-untrusted $APK_ADD_EXTRA_ARGS "$@" || die "Installation failed"
else
  apk add --allow-untrusted "$@" || die "Installation failed"
fi

log "PassWall $pw_ver installed successfully"
log "Restart: /etc/init.d/passwall restart"
