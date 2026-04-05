#!/usr/bin/env bash
# smoke.sh — local smoke test for PassWall installer pipeline

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
source "$SCRIPT_DIR/lib.sh"

# ── Constants ─────────────────────────────────────────

UPSTREAM_OWNER="Openwrt-Passwall"
UPSTREAM_REPO="openwrt-passwall"

# ── CLI state ─────────────────────────────────────────

CONFIG_FILE="$REPO_ROOT/config/config.conf"
OUTPUT_DIR=""
TAG_OVERRIDE=""
KEEP_WORKDIR=0

# ── Runtime state ─────────────────────────────────────

WORKDIR=""
RAW_TAG=""
TAG=""

usage() {
  cat <<'USAGE'
Usage: smoke.sh [options]

Options:
  --tag TAG           Explicit PassWall tag
  --output-dir DIR    Output directory (default: $TMPDIR/passwall-smoke-output)
  --config FILE       Config file (default: config/config.conf)
  --keep-workdir      Keep temporary workspace
  --help              Show help
USAGE
}

cleanup() {
  [ "$KEEP_WORKDIR" -eq 0 ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR" || :
}

# ══════════════════════════════════════════════════════
#  Validate
# ══════════════════════════════════════════════════════

validate() {
  log_info "=== Validate ==="
  local t
  for t in bash sh makeself file sha256sum; do require_tool "$t"; done
  bash -n "$SCRIPT_DIR/lib.sh"
  bash -n "$SCRIPT_DIR/smoke.sh"
  bash -n "$SCRIPT_DIR/build.sh"
  sh -n "$REPO_ROOT/payload/install.sh"
}

# ══════════════════════════════════════════════════════
#  Build synthetic payload
# ══════════════════════════════════════════════════════

build_synthetic_payload() {
  log_info "=== Build synthetic payload ==="
  local payload="$WORKDIR/payload"
  mkdir -p "$payload/$PAYLOAD_APK_DIR" "$payload/$PAYLOAD_META_DIR"
  cp "$REPO_ROOT/payload/install.sh" "$payload/install.sh"

  # Synthetic APKs
  printf 'synthetic\n' > "$payload/$PAYLOAD_APK_DIR/luci-app-passwall-${TAG}-r1.apk"
  printf 'synthetic\n' > "$payload/$PAYLOAD_APK_DIR/luci-i18n-passwall-zh-cn-${TAG}-r1.apk"
  printf 'synthetic\n' > "$payload/$PAYLOAD_APK_DIR/xray-core-${TAG}-r1.apk"
  printf 'synthetic\n' > "$payload/$PAYLOAD_APK_DIR/hysteria-${TAG}-r1.apk"
  printf 'synthetic\n' > "$payload/$PAYLOAD_APK_DIR/dnsmasq-full-1.0-r1.apk"
  printf 'synthetic\n' > "$payload/$PAYLOAD_APK_DIR/microsocks-1.0.5-r1.apk"
  printf 'synthetic\n' > "$payload/$PAYLOAD_APK_DIR/example-dependency-1.0-r1.apk"

  # Whitelist
  printf '%s\n' luci-app-passwall luci-i18n-passwall-zh-cn xray-core hysteria dnsmasq-full microsocks \
    > "$payload/$PAYLOAD_WHITELIST"

  # Manifest + index + checksums
  write_apk_manifest "$payload"
  printf 'synthetic-index\n' > "$payload/$PAYLOAD_REPO_INDEX"
  generate_sha256sums "$payload"
  [ -s "$payload/SHA256SUMS" ] || die "Checksum manifest missing"
}

# ══════════════════════════════════════════════════════
#  Run smoke test
# ══════════════════════════════════════════════════════

run_smoke_test() {
  log_info "=== Run installer smoke test ==="
  local payload="$WORKDIR/payload"
  local mockbin="$WORKDIR/mockbin"
  local install_log="$WORKDIR/install.log"
  local apk_inv="$WORKDIR/apk-invocations.log"

  run_mock_installer "$payload" "$install_log" "$apk_inv" "$mockbin" || {
    group_start "install.log"; cat "$install_log" 2>/dev/null || true; group_end
    group_start "apk invocations"; cat "$apk_inv" 2>/dev/null || true; group_end
    die "Smoke installer failed"
  }

  # Validate output
  grep -q "installed successfully" "$install_log" \
    || die "Missing success marker"
  grep -q "Install mode: auto" "$install_log" \
    || die "Did not run in auto mode"
  grep -q "Using explicit payload APKs for selected packages" "$install_log" \
    || die "Did not use explicit payload APKs"
  grep -q "Installing .*packages: .*xray-core" "$install_log" \
    || die "xray-core not in install list"
  grep -q "Installing .*packages: .*hysteria" "$install_log" \
    || die "hysteria not in install list"
  grep -q "Installing .*packages: .*microsocks" "$install_log" \
    || die "microsocks not in install list"
  grep -q "Removing conflicting packages: dnsmasq dnsmasq-dhcpv6" "$install_log" \
    || die "dnsmasq conflict removal missing"
  grep -q "del dnsmasq dnsmasq-dhcpv6" "$apk_inv" \
    || die "apk del dnsmasq invocation missing"
  grep -q "add --allow-untrusted .*xray-core-${TAG}-r1.apk" "$apk_inv" \
    || die "apk add xray-core invocation missing"
  grep -q "add --allow-untrusted .*hysteria-${TAG}-r1.apk" "$apk_inv" \
    || die "apk add hysteria invocation missing"
  grep -q "add --allow-untrusted .*microsocks-1.0.5-r1.apk" "$apk_inv" \
    || die "apk add microsocks invocation missing"
}

# ══════════════════════════════════════════════════════
#  Build smoke .run
# ══════════════════════════════════════════════════════

build_smoke_run() {
  log_info "=== Build smoke installer ==="
  local payload="$WORKDIR/payload"
  local build_dir="$WORKDIR/build-smoke"
  local run_name="passwall_smoke_${TAG}.run"
  local run_path="$OUTPUT_DIR/$run_name"

  mkdir -p "$build_dir/payload" "$OUTPUT_DIR"
  cp -r "$payload"/. "$build_dir/payload/"
  chmod +x "$build_dir/payload/install.sh"

  (
    cd "$build_dir"
    makeself --nox11 --sha256 payload "$run_path" "passwall_smoke_${TAG}" ./install.sh >/dev/null
  ) || die "makeself failed"

  sh "$run_path" --check >/dev/null || die "Smoke .run integrity check failed"
  log_info "Smoke installer: $run_path"
}

# ══════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag)         TAG_OVERRIDE="${2:?--tag requires a value}"; shift 2 ;;
      --output-dir)  OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
      --config)      CONFIG_FILE="${2:?--config requires a value}"; shift 2 ;;
      --keep-workdir) KEEP_WORKDIR=1; shift ;;
      --help|-h)     usage; exit 0 ;;
      *)             die "Unknown argument: $1" ;;
    esac
  done

  TMPDIR=$(resolve_tmpdir 65536) || die "No temp directory with enough free space available"
  export TMPDIR
  export TMP="$TMPDIR" TEMP="$TMPDIR"
  [ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$TMPDIR/passwall-smoke-output"

  WORKDIR=$(mktemp -d "$TMPDIR/passwall-smoke.XXXXXX")
  trap cleanup EXIT

  cd "$REPO_ROOT"
  validate

  log_info "=== Load config ==="
  load_config "$CONFIG_FILE"
  [[ "${OPENWRT_SDK_URL:-}" =~ ^https:// ]] || die "OPENWRT_SDK_URL must use https"

  log_info "=== Resolve tag ==="
  if [ -n "$TAG_OVERRIDE" ]; then
    RAW_TAG="$TAG_OVERRIDE"
  else
    RAW_TAG=$(resolve_latest_release_tag "$UPSTREAM_OWNER" "$UPSTREAM_REPO")
    [ -n "$RAW_TAG" ] || die "Failed to resolve upstream tag"
  fi
  TAG=$(trim_tag "$RAW_TAG")
  log_info "Tag: $RAW_TAG → $TAG"

  build_synthetic_payload
  run_smoke_test
  build_smoke_run

  cat <<EOF
Smoke test completed successfully.
  Tag: $RAW_TAG → $TAG
  SDK URL: $OPENWRT_SDK_URL
  Output: $OUTPUT_DIR
  Workdir: $WORKDIR
EOF
}

main "$@"
