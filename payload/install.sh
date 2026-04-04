#!/bin/sh
# install.sh — PassWall installer for OpenWrt (APK package manager)
set -eu
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

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
  auto       Use INSTALL_WHITELIST when present, otherwise TOPLEVEL_PACKAGES
  top-level  Install only TOPLEVEL_PACKAGES plus dnsmasq-full when present
  whitelist  Install INSTALL_WHITELIST plus dnsmasq-full when present
  full       Install every package listed by PAYLOAD_APK_MAP
USAGE
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

PAYLOAD_APK_DIR="apks"
PAYLOAD_META_DIR="metadata"
PAYLOAD_MAP_FILE="$PAYLOAD_META_DIR/PAYLOAD_APK_MAP"
TOPLEVEL_FILE="$PAYLOAD_META_DIR/TOPLEVEL_PACKAGES"
WHITELIST_FILE="$PAYLOAD_META_DIR/INSTALL_WHITELIST"
REPO_INDEX_FILE="$PAYLOAD_APK_DIR/packages.adb"

payload_pkg_candidates() {
  pkg_name="$1"
  case "$pkg_name" in
    nftables)
      printf '%s\n' nftables nftables-json nftables-nojson
      ;;
    hysteria|hysteria2|hy2)
      printf '%s\n' hysteria hysteria2 hy2
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
    hysteria2|hy2)
      printf '%s\n' hysteria
      ;;
    *)
      printf '%s\n' "$pkg_name"
      ;;
  esac
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

payload_pkg_file() {
  pkg_name="$1"
  [ -f "$PAYLOAD_MAP_FILE" ] || die "Payload package manifest missing: $PAYLOAD_MAP_FILE"

  for candidate in $(payload_pkg_candidates "$pkg_name"); do
    mapped_path=$(awk -F'|' -v pkg="$candidate" '$1 == pkg { print $2; exit }' "$PAYLOAD_MAP_FILE")
    [ -n "$mapped_path" ] || continue
    [ -e "$mapped_path" ] || die "Payload manifest points to missing file: $mapped_path"
    printf '%s\n' "$mapped_path"
    return 0
  done

  return 1
}

payload_has_pkg() {
  payload_pkg_file "$1" >/dev/null 2>&1
}

append_packages_from_file() {
  list_file="$1"
  [ -f "$list_file" ] || return 0

  while IFS= read -r pkg_name; do
    [ -n "$pkg_name" ] || continue
    pkg_name=$(normalize_payload_pkg_name "$pkg_name")
    case "$pkg_name" in
      luci-app-passwall|luci-i18n-passwall-zh-cn)
        continue
        ;;
    esac
    set -- $INSTALL_PACKAGES
    append_install_pkg "$pkg_name" "$@"
  done < "$list_file"
}

append_packages_from_manifest() {
  [ -f "$PAYLOAD_MAP_FILE" ] || return 0
  while IFS='|' read -r pkg_name _; do
    [ -n "$pkg_name" ] || continue
    pkg_name=$(normalize_payload_pkg_name "$pkg_name")
    case "$pkg_name" in
      luci-app-passwall|luci-i18n-passwall-zh-cn)
        continue
        ;;
    esac
    set -- $INSTALL_PACKAGES
    append_install_pkg "$pkg_name" "$@"
  done < "$PAYLOAD_MAP_FILE"
}

resolve_install_targets() {
  INSTALL_TARGETS=""
  set -- $INSTALL_PACKAGES
  for pkg_name in "$@"; do
    install_target=$(payload_pkg_file "$pkg_name" || true)
    [ -n "$install_target" ] || die "Payload APK missing for requested package: $pkg_name"
    set -- $INSTALL_TARGETS
    append_install_target "$install_target" "$@"
  done
  [ -n "$INSTALL_TARGETS" ] || die "No explicit payload install targets resolved"
}

build_install_package_list() {
  INSTALL_PACKAGES="luci-app-passwall"
  if payload_has_pkg "luci-i18n-passwall-zh-cn"; then
    INSTALL_PACKAGES="$INSTALL_PACKAGES luci-i18n-passwall-zh-cn"
  fi

  case "$INSTALL_MODE" in
    auto)
      if [ -s "$WHITELIST_FILE" ]; then
        INSTALL_MODE_RESOLVED="whitelist"
      else
        INSTALL_MODE_RESOLVED="top-level"
      fi
      ;;
    top-level)
      INSTALL_MODE_RESOLVED="top-level"
      ;;
    whitelist)
      [ -s "$WHITELIST_FILE" ] || die "INSTALL_WHITELIST not found for install mode whitelist"
      INSTALL_MODE_RESOLVED="whitelist"
      ;;
    full)
      INSTALL_MODE_RESOLVED="full"
      ;;
    *)
      die "Unknown install mode: $INSTALL_MODE"
      ;;
  esac

  case "$INSTALL_MODE_RESOLVED" in
    top-level)
      INSTALL_PLAN_LABEL="top-level packages"
      append_packages_from_file "$TOPLEVEL_FILE"
      ;;
    whitelist)
      INSTALL_PLAN_LABEL="whitelisted packages"
      append_packages_from_file "$WHITELIST_FILE"
      ;;
    full)
      INSTALL_PLAN_LABEL="payload packages"
      append_packages_from_manifest
      ;;
  esac

  if payload_has_pkg "dnsmasq-full"; then
    set -- $INSTALL_PACKAGES
    append_install_pkg "dnsmasq-full" "$@"
  fi
}

queue_conflict_removal() {
  remove_pkg="$1"
  apk info -e "$remove_pkg" >/dev/null 2>&1 || return 0
  CONFLICT_REMOVALS="${CONFLICT_REMOVALS:+$CONFLICT_REMOVALS }$remove_pkg"
}

queue_nftables_provider_conflict_removal() {
  selected_nft_provider=""
  set -- $INSTALL_TARGETS
  for install_target in "$@"; do
    case "$(basename "$install_target")" in
      nftables-json-*.apk|nftables-json_*.apk)
        selected_nft_provider="nftables-json"
        ;;
      nftables-nojson-*.apk|nftables-nojson_*.apk)
        selected_nft_provider="nftables-nojson"
        ;;
    esac
  done

  case "$selected_nft_provider" in
    nftables-json)
      queue_conflict_removal "nftables-nojson"
      ;;
    nftables-nojson)
      queue_conflict_removal "nftables-json"
      ;;
  esac
}

log "Starting PassWall installation..."
[ -f "SHA256SUMS" ] || die "SHA256SUMS not found"
[ -f "$PAYLOAD_MAP_FILE" ] || die "Payload package manifest missing: $PAYLOAD_MAP_FILE"
[ -f "$REPO_INDEX_FILE" ] || die "Payload repository index missing: $REPO_INDEX_FILE"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required to verify payload integrity"

log "Verifying payload checksums..."
sha256sum -c SHA256SUMS >/dev/null || die "Payload checksum verification failed"

pw_pkg=$(payload_pkg_file "luci-app-passwall" || true)
[ -n "$pw_pkg" ] || die "luci-app-passwall package not found in payload manifest"
pw_ver=$(basename "$pw_pkg" | sed -E 's/luci-app-passwall[-_]//; s/[-_].*//')
log "PassWall: $pw_ver ($pw_pkg)"

build_install_package_list
resolve_install_targets

REPO_FILE="${TMPDIR:-/tmp}/passwall-apk-repositories.$$"
cleanup() {
  rm -f "$REPO_FILE"
}
trap cleanup EXIT HUP INT TERM
printf 'file://%s/%s\n' "$PWD" "$REPO_INDEX_FILE" > "$REPO_FILE"

CONFLICT_REMOVALS=""
HAS_DNSMASQ_FULL=0
for pkg_name in $INSTALL_PACKAGES; do
  if [ "$pkg_name" = "dnsmasq-full" ]; then
    HAS_DNSMASQ_FULL=1
    break
  fi
done

if [ "$HAS_DNSMASQ_FULL" -eq 1 ]; then
  queue_conflict_removal "dnsmasq"
  queue_conflict_removal "dnsmasq-dhcpv6"
fi

queue_nftables_provider_conflict_removal

if [ -n "$CONFLICT_REMOVALS" ]; then
  log "Removing conflicting packages: $CONFLICT_REMOVALS"
  apk del $CONFLICT_REMOVALS || die "Failed to remove conflicting packages: $CONFLICT_REMOVALS"
fi

payload_apk_count=$(find "$PAYLOAD_APK_DIR" -maxdepth 1 -type f -name '*.apk' 2>/dev/null | wc -l | tr -d ' ')
log "Payload APK count: ${payload_apk_count:-0}"
log "Install mode: $INSTALL_MODE_RESOLVED"
log "Installing $INSTALL_PLAN_LABEL: $INSTALL_PACKAGES"
log "Using payload package manifest: $PAYLOAD_MAP_FILE"
log "Using explicit payload APKs for selected packages"

if apk list -I luci-app-passwall 2>/dev/null | grep -q "luci-app-passwall"; then
  INSTALLED_VER=$(apk list -I luci-app-passwall 2>/dev/null | sed -E 's/.*-([0-9][^ ]*).*/\1/' | head -1)
  log "Installed version: ${INSTALLED_VER:-unknown}, new version: $pw_ver"
  log "Removing existing PassWall before install"
  apk del luci-app-passwall luci-i18n-passwall-zh-cn 2>/dev/null || true
fi

log "Installing $pw_ver..."
# shellcheck disable=SC2086
apk add --allow-untrusted --force-reinstall \
  --repositories-file "$REPO_FILE" \
  --no-cache \
  --force-refresh \
  $INSTALL_TARGETS \
  || die "Installation failed"

log "PassWall $pw_ver installed successfully"
log "Restart: /etc/init.d/passwall restart"
