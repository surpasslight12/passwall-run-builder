#!/bin/sh
# install.sh — PassWall 一键安装脚本 (OpenWrt APK)
# PassWall installer for OpenWrt (APK package manager)
set -eu
set -o pipefail 2>/dev/null || true

log()      { printf '[INFO]  %s\n' "$*"; }
log_warn() { printf '[WARN]  %s\n' "$*"; }
err()      { printf '[ERROR] %s\n' "$*" >&2; }
die()      { err "$@"; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--install-mode auto|top-level|whitelist|full]

Options:
  --install-mode MODE  auto (default), top-level, whitelist, or full
  --help               Show this help

Modes:
  auto       Use INSTALL_WHITELIST when present, otherwise fall back to TOPLEVEL_PACKAGES
  top-level  Install only TOPLEVEL_PACKAGES plus dnsmasq-full when bundled
  whitelist  Install INSTALL_WHITELIST plus dnsmasq-full when bundled
  full       Install every package present in the payload
USAGE
}

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

INSTALL_MODE="${PASSWALL_INSTALL_MODE:-auto}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-mode)
      INSTALL_MODE="${2:-}"
      [ -n "$INSTALL_MODE" ] || die "--install-mode requires a value"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

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

payload_pkg_candidates() {
  pkg_name="$1"
  case "$pkg_name" in
    nftables)
      printf '%s\n' nftables nftables-nojson nftables-json
      ;;
    *)
      printf '%s\n' "$pkg_name"
      ;;
  esac
}

normalize_payload_pkg_name() {
  pkg_name="$1"
  case "$pkg_name" in
    nftables-nojson|nftables-json)
      printf '%s\n' nftables
      ;;
    *)
      printf '%s\n' "$pkg_name"
      ;;
  esac
}

apk_package_name_from_file() {
  apk_file="${1##*/}"
  printf '%s\n' "$apk_file" | sed -E 's/[-_][0-9].*\.apk$//'
}

payload_has_pkg() {
  pkg_name="$1"
  for candidate in $(payload_pkg_candidates "$pkg_name"); do
    for f in \
      "${candidate}"-*.apk "${candidate}"_*.apk \
      "depends/${candidate}"-*.apk "depends/${candidate}"_*.apk; do
      [ -e "$f" ] && return 0
    done
  done
  return 1
}

payload_pkg_file() {
  pkg_name="$1"
  for candidate in $(payload_pkg_candidates "$pkg_name"); do
    for f in \
      "${candidate}"-*.apk "${candidate}"_*.apk \
      "depends/${candidate}"-*.apk "depends/${candidate}"_*.apk; do
      [ -e "$f" ] && {
        printf '%s\n' "$f"
        return 0
      }
    done
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

append_install_pkg_file() {
  list_file="$1"
  [ -f "$list_file" ] || return 0

  while IFS= read -r pkg_name; do
    [ -n "$pkg_name" ] || continue
    pkg_name=$(normalize_payload_pkg_name "$pkg_name")
    set -- $INSTALL_PACKAGES
    append_install_pkg "$pkg_name" "$@"
  done < "$list_file"
}

append_install_pkg_dir() {
  search_dir="$1"
  [ -d "$search_dir" ] || return 0

  for apk_file in "$search_dir"/*.apk; do
    [ -e "$apk_file" ] || continue
    pkg_name=$(apk_package_name_from_file "$apk_file")
    [ -n "$pkg_name" ] || continue
    pkg_name=$(normalize_payload_pkg_name "$pkg_name")
    set -- $INSTALL_PACKAGES
    append_install_pkg "$pkg_name" "$@"
  done
}

append_install_target() {
  install_target="$1"
  shift
  [ -n "$install_target" ] || return 0
  for existing_target in "$@"; do
    [ "$existing_target" = "$install_target" ] && return 0
  done
  set -- "$@" "$install_target"
  INSTALL_TARGETS="$*"
}

resolve_install_targets() {
  INSTALL_TARGETS=""
  set -- $INSTALL_PACKAGES
  for pkg_name in "$@"; do
    install_target=$(payload_pkg_file "$pkg_name" || true)
    [ -n "$install_target" ] || install_target="$pkg_name"
    set -- $INSTALL_TARGETS
    append_install_target "$install_target" "$@"
  done
}

build_install_package_list() {
  INSTALL_PACKAGES="luci-app-passwall"
  [ -n "$zh_pkg" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES luci-i18n-passwall-zh-cn"

  case "$INSTALL_MODE" in
    auto)
      if [ -s INSTALL_WHITELIST ]; then
        INSTALL_MODE_RESOLVED="whitelist"
      else
        INSTALL_MODE_RESOLVED="top-level"
      fi
      ;;
    top-level|toplevel)
      INSTALL_MODE_RESOLVED="top-level"
      ;;
    whitelist)
      [ -s INSTALL_WHITELIST ] || die "INSTALL_WHITELIST not found for install mode whitelist"
      INSTALL_MODE_RESOLVED="whitelist"
      ;;
    full|payload)
      INSTALL_MODE_RESOLVED="full"
      ;;
    *)
      die "Unknown install mode: $INSTALL_MODE"
      ;;
  esac

  case "$INSTALL_MODE_RESOLVED" in
    top-level)
      INSTALL_PLAN_LABEL="top-level packages"
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
      ;;
    whitelist)
      INSTALL_PLAN_LABEL="whitelisted packages"
      append_install_pkg_file INSTALL_WHITELIST
      ;;
    full)
      INSTALL_PLAN_LABEL="payload packages"
      append_install_pkg_dir .
      append_install_pkg_dir depends
      ;;
  esac

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

  INSTALL_MODE_RESOLVED=""
  INSTALL_PLAN_LABEL="packages"
  build_install_package_list
  resolve_install_targets
  # shellcheck disable=SC2086
  set -- $INSTALL_TARGETS

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
  log "Install mode: $INSTALL_MODE_RESOLVED"
  log "Installing $INSTALL_PLAN_LABEL: $INSTALL_PACKAGES"
  log "Using embedded APK repositories"
  log "Using explicit payload APKs for selected packages"
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
  apk add --allow-untrusted --force-reinstall $APK_ADD_EXTRA_ARGS "$@" || die "Installation failed"
else
  apk add --allow-untrusted "$@" || die "Installation failed"
fi

log "PassWall $pw_ver installed successfully"
log "Restart: /etc/init.d/passwall restart"
