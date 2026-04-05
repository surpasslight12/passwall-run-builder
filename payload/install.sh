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
Usage: ./install.sh [--auto|--full]

  --auto    Install INSTALL_WHITELIST packages (default)
  --full    Install every package in PAYLOAD_APK_MAP
  --help    Show help
USAGE
}

# ── Parse args ────────────────────────────────────────

INSTALL_MODE="auto"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --auto) INSTALL_MODE="auto"; shift ;;
    --full) INSTALL_MODE="full"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ── Layout constants ──────────────────────────────────

APK_DIR="apks"
META_DIR="metadata"
MAP_FILE="$META_DIR/PAYLOAD_APK_MAP"
WHITELIST_FILE="$META_DIR/INSTALL_WHITELIST"
REPO_INDEX="$APK_DIR/packages.adb"

# ── Helpers ───────────────────────────────────────────

pkg_candidates() {
  case "$1" in
    nftables)               printf '%s\n' nftables nftables-json nftables-nojson ;;
    hysteria|hysteria2|hy2) printf '%s\n' hysteria hysteria2 hy2 ;;
    *)                      printf '%s\n' "$1" ;;
  esac
}

normalize_pkg() {
  case "$1" in
    nftables-nojson|nftables-json) printf '%s\n' nftables ;;
    hysteria2|hy2)                 printf '%s\n' hysteria ;;
    *)                             printf '%s\n' "$1" ;;
  esac
}

# Look up APK file path from payload manifest
payload_pkg_file() {
  [ -f "$MAP_FILE" ] || die "Manifest missing: $MAP_FILE"
  for candidate in $(pkg_candidates "$1"); do
    mapped=$(awk -F'|' -v pkg="$candidate" '$1 == pkg { print $2; exit }' "$MAP_FILE")
    [ -n "$mapped" ] || continue
    [ -e "$mapped" ] || die "Manifest points to missing file: $mapped"
    printf '%s\n' "$mapped"
    return 0
  done
  return 1
}

payload_has_pkg() { payload_pkg_file "$1" >/dev/null 2>&1; }

# Space-separated list operations (POSIX sh, no arrays)
list_contains() {
  target="$1"; shift
  for item in "$@"; do [ "$item" = "$target" ] && return 0; done
  return 1
}

list_append_unique() {
  new_item="$1"; shift
  for item in "$@"; do [ "$item" = "$new_item" ] && return 0; done
  INSTALL_PACKAGES="$INSTALL_PACKAGES $new_item"
}

# ── Preflight checks ──────────────────────────────────

log "Starting PassWall installation..."
[ -f "SHA256SUMS" ] || die "SHA256SUMS not found"
[ -f "$MAP_FILE" ] || die "Manifest missing: $MAP_FILE"
[ -f "$REPO_INDEX" ] || die "Repository index missing: $REPO_INDEX"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum required"

log "Verifying payload checksums..."
sha256sum -c SHA256SUMS >/dev/null || die "Checksum verification failed"

pw_pkg=$(payload_pkg_file "luci-app-passwall" || true)
[ -n "$pw_pkg" ] || die "luci-app-passwall not in manifest"
pw_ver=$(basename "$pw_pkg" | sed -E 's/luci-app-passwall[-_]//; s/[-_].*//')
log "PassWall: $pw_ver ($pw_pkg)"

# ── Build package list ────────────────────────────────

INSTALL_PACKAGES="luci-app-passwall"
payload_has_pkg "luci-i18n-passwall-zh-cn" && INSTALL_PACKAGES="$INSTALL_PACKAGES luci-i18n-passwall-zh-cn"

case "$INSTALL_MODE" in
  auto)
    [ -s "$WHITELIST_FILE" ] || die "INSTALL_WHITELIST not found"
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      pkg=$(normalize_pkg "$pkg")
      case "$pkg" in luci-app-passwall|luci-i18n-passwall-zh-cn) continue ;; esac
      set -- $INSTALL_PACKAGES
      list_append_unique "$pkg" "$@"
    done < "$WHITELIST_FILE"
    ;;
  full)
    [ -f "$MAP_FILE" ] || die "Manifest missing: $MAP_FILE"
    while IFS='|' read -r pkg _; do
      [ -n "$pkg" ] || continue
      pkg=$(normalize_pkg "$pkg")
      case "$pkg" in luci-app-passwall|luci-i18n-passwall-zh-cn) continue ;; esac
      set -- $INSTALL_PACKAGES
      list_append_unique "$pkg" "$@"
    done < "$MAP_FILE"
    ;;
  *) die "Unknown mode: $INSTALL_MODE" ;;
esac

payload_has_pkg "dnsmasq-full" && {
  set -- $INSTALL_PACKAGES
  list_append_unique "dnsmasq-full" "$@"
}

# ── Resolve APK targets ──────────────────────────────

INSTALL_TARGETS=""
set -- $INSTALL_PACKAGES
for pkg in "$@"; do
  target=$(payload_pkg_file "$pkg" || true)
  [ -n "$target" ] || die "Payload APK missing for: $pkg"
  # Deduplicate
  case " $INSTALL_TARGETS " in
    *" $target "*) ;;
    *) INSTALL_TARGETS="${INSTALL_TARGETS:+$INSTALL_TARGETS }$target" ;;
  esac
done
[ -n "$INSTALL_TARGETS" ] || die "No install targets resolved"

# ── Version protection ────────────────────────────────

installed_pkg_version() {
  apk list -I "$1" 2>/dev/null \
    | awk -v pkg="$1" '{
        t=$1
        if (index(t, pkg "-") == 1 || index(t, pkg "_") == 1) {
          print substr(t, length(pkg) + 2); exit
        }
      }'
}

payload_version() {
  base=$(basename "$2"); base=${base%.apk}
  case "$base" in
    "${1}-"*) printf '%s\n' "${base#"${1}"-}" ;;
    "${1}_"*) printf '%s\n' "${base#"${1}"_}" ;;
  esac
}

FILTERED_TARGETS="" FILTERED_PACKAGES=""
set -- $INSTALL_PACKAGES
for pkg in "$@"; do
  target=$(payload_pkg_file "$pkg" || true)
  [ -n "$target" ] || continue

  inst_ver=$(installed_pkg_version "$pkg" || true)
  pay_ver=$(payload_version "$pkg" "$target" || true)

  if [ -n "$inst_ver" ] && [ -n "$pay_ver" ]; then
    cmp=$(apk version -t "$pay_ver" "$inst_ver" 2>/dev/null || printf '?\n')
    case "$cmp" in
      '<') log_warn "Skip $pkg: installed $inst_ver > payload $pay_ver"; continue ;;
      '=') log "Skip $pkg: same version $inst_ver"; continue ;;
      '?') log_warn "Skip $pkg: cannot compare $pay_ver vs $inst_ver"; continue ;;
    esac
  fi

  case " $FILTERED_TARGETS " in
    *" $target "*) ;;
    *) FILTERED_TARGETS="${FILTERED_TARGETS:+$FILTERED_TARGETS }$target" ;;
  esac
  case " $FILTERED_PACKAGES " in
    *" $pkg "*) ;;
    *) FILTERED_PACKAGES="${FILTERED_PACKAGES:+$FILTERED_PACKAGES }$pkg" ;;
  esac
done

INSTALL_TARGETS="$FILTERED_TARGETS"
INSTALL_PACKAGES="$FILTERED_PACKAGES"

if [ -z "$INSTALL_TARGETS" ]; then
  log "All packages are up-to-date on device"
  log "Nothing to install"
  exit 0
fi

# ── Remove conflicts ─────────────────────────────────

REPO_FILE="${TMPDIR:-/tmp}/passwall-repos.$$"
trap 'rm -f "$REPO_FILE"' EXIT HUP INT TERM

# Include system repos so shared dependencies (luci-lib-*, ucode, etc.)
# are resolved from the device's repos at their current (usually newer)
# versions, preventing regression to the SDK-era versions in our payload.
# The local payload repo is appended last as a fallback for passwall-only
# packages that don't exist in the system repos.
for _rf in /etc/apk/repositories /etc/apk/repositories.d/*; do
  [ -f "$_rf" ] && grep -v '^[[:space:]]*#' "$_rf" | grep -v '^[[:space:]]*$'
done > "$REPO_FILE" 2>/dev/null || :
printf 'file://%s/%s\n' "$PWD" "$REPO_INDEX" >> "$REPO_FILE"

CONFLICTS=""
set -- $INSTALL_PACKAGES
if list_contains "dnsmasq-full" "$@"; then
  apk info -e dnsmasq >/dev/null 2>&1 && CONFLICTS="$CONFLICTS dnsmasq"
  apk info -e dnsmasq-dhcpv6 >/dev/null 2>&1 && CONFLICTS="$CONFLICTS dnsmasq-dhcpv6"
fi

# nftables provider conflict
for t in $INSTALL_TARGETS; do
  case "$(basename "$t")" in
    nftables-json[-_]*.apk)  apk info -e nftables-nojson >/dev/null 2>&1 && CONFLICTS="$CONFLICTS nftables-nojson" ;;
    nftables-nojson[-_]*.apk) apk info -e nftables-json >/dev/null 2>&1 && CONFLICTS="$CONFLICTS nftables-json" ;;
  esac
done

CONFLICTS="${CONFLICTS# }"
if [ -n "$CONFLICTS" ]; then
  log "Removing conflicting packages: $CONFLICTS"
  apk del $CONFLICTS || die "Failed to remove conflicts: $CONFLICTS"
fi

# ── Install ───────────────────────────────────────────

apk_count=$(find "$APK_DIR" -maxdepth 1 -type f -name '*.apk' 2>/dev/null | wc -l | tr -d ' ')
log "Payload APK count: ${apk_count:-0}"
log "Install mode: $INSTALL_MODE"
log "Installing $INSTALL_MODE packages: $INSTALL_PACKAGES"
log "Using payload package manifest: $MAP_FILE"
log "Using explicit payload APKs for selected packages"
log "Safe install enabled; installer skips payload packages that are same/newer on device"

log "Installing $pw_ver..."
# shellcheck disable=SC2086
apk add --allow-untrusted \
  --repositories-file "$REPO_FILE" \
  $INSTALL_TARGETS \
  || die "Installation failed"

log "PassWall $pw_ver installed successfully"
log "Restart: /etc/init.d/passwall restart"
