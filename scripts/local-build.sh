#!/usr/bin/env bash
# local-build.sh — local smoke/full build entry

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
source "$SCRIPT_DIR/build-lib.sh"

MODE="smoke"
CONFIG_FILE="$REPO_ROOT/config/config.conf"
OUTPUT_DIR="${TMPDIR:-/tmp}/passwall-local-build-output"
TAG_OVERRIDE=""
SDK_ROOT=""
SDK_ARCHIVE_OVERRIDE=""
PASSWALL_LUCI_DIR=""
PASSWALL_PACKAGES_DIR=""
PASSWALL_LUCI_REPO=""
PASSWALL_PACKAGES_REPO=""
KEEP_WORKDIR=0
WORKDIR=""
SUMMARY_FILE=""
RAW_TAG=""
PASSWALL_VERSION_TAG=""
PAYLOAD_DIR=""
RUN_OUTPUT=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--mode smoke|full] [options]

Modes:
  smoke   Validate the installer pipeline with a synthetic payload and mock apk (default)
  full    Run the shared full build pipeline locally

Common options:
  --tag TAG                 Use an explicit PassWall tag
  --output-dir DIR          Directory where the generated .run artifact will be written
  --config FILE             Config file to load (default: config/config.conf)
  --keep-workdir            Keep the temporary workspace for inspection
  --help                    Show this help

Full mode options:
  --sdk-root DIR            Path to an existing OpenWrt SDK tree
  --sdk-archive PATH|URL    Override the SDK archive source used when --sdk-root is not provided
  --passwall-luci-dir DIR   Path to an existing openwrt-passwall checkout
  --passwall-packages-dir DIR
                            Path to an existing openwrt-passwall-packages checkout
  --passwall-luci-repo URL  Override the openwrt-passwall clone source
  --passwall-packages-repo URL
                            Override the openwrt-passwall-packages clone source
USAGE
}

cleanup() {
  if [ "$KEEP_WORKDIR" -eq 0 ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}

prepare_workspace() {
  local cache_root="${XDG_CACHE_HOME:-${HOME:-$REPO_ROOT}/.cache}/passwall-run"
  WORKDIR=$(make_managed_tempdir "passwall-local-build" \
    "${PASSWALL_TMPDIR:-}" \
    "${TMPDIR:-}" \
    /var/tmp \
    "$cache_root" \
    "$REPO_ROOT/.tmp")
  SUMMARY_FILE="$WORKDIR/summary.txt"
  PAYLOAD_DIR="$WORKDIR/payload"
  trap cleanup EXIT

  mkdir -p "$OUTPUT_DIR"
}

load_config() {
  step_start "Load local config"
  load_env_config "$CONFIG_FILE"
  config_default "PASSWALL_UPSTREAM_OWNER" "Openwrt-Passwall"
  config_default "PASSWALL_UPSTREAM_REPO" "openwrt-passwall"
  config_default "PASSWALL_LUCI_REPO" "https://github.com/Openwrt-Passwall/openwrt-passwall"
  config_default "PASSWALL_PACKAGES_REPO" "https://github.com/Openwrt-Passwall/openwrt-passwall-packages"
  [[ "${OPENWRT_SDK_URL:-}" =~ ^https:// ]] || die "OPENWRT_SDK_URL must use https"
  log_info "Using SDK URL: $OPENWRT_SDK_URL"
  step_end
}

resolve_tag() {
  step_start "Resolve PassWall tag"
  if [ -n "$TAG_OVERRIDE" ]; then
    RAW_TAG="$TAG_OVERRIDE"
    log_info "Using explicit tag $RAW_TAG"
  else
    RAW_TAG=$(resolve_latest_github_release_tag "$PASSWALL_UPSTREAM_OWNER" "$PASSWALL_UPSTREAM_REPO")
    [ -n "$RAW_TAG" ] || die "Failed to resolve latest upstream stable tag"
    log_info "Resolved latest upstream stable tag $RAW_TAG"
  fi
  PASSWALL_VERSION_TAG=$(trim_tag "$RAW_TAG")
  log_info "Normalized local tag: $PASSWALL_VERSION_TAG"
  step_end
}

validate_common_inputs() {
  step_start "Validate repository inputs"
  require_tool bash
  require_tool sh
  require_tool python3
  require_tool makeself
  require_tool file
  require_tool sha256sum
  [ -f "$REPO_ROOT/.github/workflows/passwall.yml" ] || die "Workflow file not found: .github/workflows/passwall.yml"
  bash -n "$REPO_ROOT/scripts/build-lib.sh"
  bash -n "$REPO_ROOT/scripts/local-build.sh"
  bash -n "$REPO_ROOT/scripts/full-build.sh"
  sh -n "$REPO_ROOT/payload/install.sh"
  step_end
}

prepare_synthetic_payload() {
  step_start "Prepare synthetic payload"
  mkdir -p "$PAYLOAD_DIR/depends"
  if [ "$(realpath "$REPO_ROOT/payload/install.sh")" != "$(realpath -m "$PAYLOAD_DIR/install.sh")" ]; then
    cp "$REPO_ROOT/payload/install.sh" "$PAYLOAD_DIR/install.sh"
  fi
  printf 'synthetic-main-%s\n' "$PASSWALL_VERSION_TAG" > "$PAYLOAD_DIR/luci-app-passwall-${PASSWALL_VERSION_TAG}-r1.apk"
  printf 'synthetic-zh-%s\n' "$PASSWALL_VERSION_TAG" > "$PAYLOAD_DIR/luci-i18n-passwall-zh-cn-${PASSWALL_VERSION_TAG}-r1.apk"
  printf 'synthetic-xray-%s\n' "$PASSWALL_VERSION_TAG" > "$PAYLOAD_DIR/xray-core-${PASSWALL_VERSION_TAG}-r1.apk"
  printf 'synthetic-dnsmasq-full\n' > "$PAYLOAD_DIR/dnsmasq-full-1.0-r1.apk"
  printf 'synthetic-microsocks\n' > "$PAYLOAD_DIR/depends/microsocks-1.0.5-r1.apk"
  printf 'synthetic-dependency\n' > "$PAYLOAD_DIR/depends/example-dependency-1.0-r1.apk"
  printf 'luci-app-passwall\nluci-i18n-passwall-zh-cn\nxray-core\ndnsmasq-full\n' > "$PAYLOAD_DIR/TOPLEVEL_PACKAGES"
  printf 'luci-app-passwall\nluci-i18n-passwall-zh-cn\nxray-core\ndnsmasq-full\nmicrosocks\n' > "$PAYLOAD_DIR/INSTALL_WHITELIST"
  write_payload_package_manifest "$PAYLOAD_DIR"
  printf 'synthetic-root-index\n' > "$PAYLOAD_DIR/packages.adb"
  printf 'synthetic-dep-index\n' > "$PAYLOAD_DIR/depends/packages.adb"
  generate_sha256_manifest "$PAYLOAD_DIR"
  [ -s "$PAYLOAD_DIR/SHA256SUMS" ] || die "Synthetic payload checksum manifest missing"
  step_end
}

run_payload_summary_regression() {
  step_start "Run payload summary regression"
  local whitelist_file summary_file
  whitelist_file="$WORKDIR/payload-summary-whitelist.txt"
  summary_file="$WORKDIR/payload-summary.txt"

  printf 'luci-app-passwall\nxray-core\nmicrosocks\n' > "$whitelist_file"
  build_payload_dependency_summary 19 87 64 "$whitelist_file" 0 2 > "$summary_file"

  grep -qx -- '## Payload Dependency Closure' "$summary_file" \
    || die "Payload summary header missing"
  grep -qx -- '- Installer whitelist packages: 3' "$summary_file" \
    || die "Payload summary whitelist count regression detected"
  grep -qx -- '- Official fallback roots: 2' "$summary_file" \
    || die "Payload summary fallback count missing"
  step_end
}

run_install_smoke_test() {
  step_start "Run installer smoke test"
  local mockbin install_log apk_invocations
  mockbin="$WORKDIR/mockbin"
  install_log="$WORKDIR/install.log"
  apk_invocations="$WORKDIR/apk-invocations.log"

  run_mocked_installer "$PAYLOAD_DIR" "$install_log" "$apk_invocations" "$mockbin" || {
    if [ -f "$install_log" ]; then
      group_start "Local installer smoke install.log"
      cat "$install_log" || true
      group_end
    fi
    if [ -f "$apk_invocations" ]; then
      group_start "Local installer smoke apk invocations"
      cat "$apk_invocations" || true
      group_end
    fi
    die "Local installer smoke test failed"
  }
  grep -q "installed successfully" "$install_log" || die "Smoke installer output missing success marker"
  grep -q "Install mode: whitelist" "$install_log" \
    || die "Smoke installer did not resolve INSTALL_WHITELIST in auto mode"
  [ -s "$PAYLOAD_DIR/$(payload_package_manifest_name)" ] \
    || die "Smoke payload package manifest missing"
  grep -q "Using explicit payload APKs for selected packages" "$install_log" \
    || die "Smoke installer did not switch to explicit payload APK targets"
  grep -q "Installing .*packages: .*xray-core" "$install_log" \
    || die "Smoke installer did not include xray-core in embedded repo install list"
  grep -q "Installing .*packages: .*microsocks" "$install_log" \
    || die "Smoke installer did not include microsocks from INSTALL_WHITELIST"
  grep -q "Removing conflicting packages: dnsmasq dnsmasq-dhcpv6" "$install_log" \
    || die "Smoke installer did not exercise dnsmasq-full conflict removal"
  grep -q "add --allow-untrusted --force-reinstall .*xray-core-${PASSWALL_VERSION_TAG}-r1.apk" "$apk_invocations" \
    || die "Smoke installer apk add invocation missing xray-core payload APK"
  grep -q "add --allow-untrusted --force-reinstall .*depends/microsocks-1.0.5-r1.apk" "$apk_invocations" \
    || die "Smoke installer apk add invocation missing microsocks payload APK"
  grep -q "del dnsmasq dnsmasq-dhcpv6" "$apk_invocations" \
    || die "Smoke installer apk del invocation missing dnsmasq conflict removal"
  step_end
}

build_smoke_installer() {
  step_start "Build smoke installer"
  local build_dir run_name label run_path
  build_dir="$WORKDIR/build-smoke"
  run_name="passwall_smoke_${PASSWALL_VERSION_TAG}.run"
  label="passwall_smoke_${PASSWALL_VERSION_TAG}"
  run_path="$OUTPUT_DIR/$run_name"

  mkdir -p "$build_dir/payload"
  cp -r "$PAYLOAD_DIR"/. "$build_dir/payload/"
  chmod +x "$build_dir/payload/install.sh"

  (
    cd "$build_dir"
    makeself --nox11 --sha256 payload "$run_path" "$label" ./install.sh >/dev/null
  ) || die "makeself failed during local smoke build"

  sh "$run_path" --check >/dev/null || die "smoke .run integrity check failed"
  RUN_OUTPUT="$run_path"
  log_info "Smoke installer created: $run_path"
  step_end
}

write_smoke_summary() {
  cat > "$SUMMARY_FILE" <<EOF
Local smoke build completed successfully.
PassWall tag: $RAW_TAG
Normalized tag: $PASSWALL_VERSION_TAG
SDK URL: $OPENWRT_SDK_URL
Output directory: $OUTPUT_DIR
Artifact: $RUN_OUTPUT
Workdir: $WORKDIR
EOF
  cat "$SUMMARY_FILE"
}

run_full_mode() {
  local -a cmd
  cmd=(
    "$SCRIPT_DIR/full-build.sh"
    --repo-root "$REPO_ROOT"
    --config "$CONFIG_FILE"
    --output-dir "$OUTPUT_DIR"
  )

  [ -n "$TAG_OVERRIDE" ] && cmd+=(--tag "$TAG_OVERRIDE")
  [ -n "$SDK_ROOT" ] && cmd+=(--sdk-root "$SDK_ROOT")
  [ -n "$SDK_ARCHIVE_OVERRIDE" ] && cmd+=(--sdk-archive "$SDK_ARCHIVE_OVERRIDE")
  [ -n "$PASSWALL_LUCI_DIR" ] && cmd+=(--passwall-luci-dir "$PASSWALL_LUCI_DIR")
  [ -n "$PASSWALL_PACKAGES_DIR" ] && cmd+=(--passwall-packages-dir "$PASSWALL_PACKAGES_DIR")
  [ -n "$PASSWALL_LUCI_REPO" ] && cmd+=(--passwall-luci-repo "$PASSWALL_LUCI_REPO")
  [ -n "$PASSWALL_PACKAGES_REPO" ] && cmd+=(--passwall-packages-repo "$PASSWALL_PACKAGES_REPO")
  [ "$KEEP_WORKDIR" -eq 1 ] && cmd+=(--keep-workdir)

  bash "${cmd[@]}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      [ -n "$MODE" ] || die "--mode requires a value"
      shift 2
      ;;
    --tag)
      TAG_OVERRIDE="${2:-}"
      [ -n "$TAG_OVERRIDE" ] || die "--tag requires a value"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      [ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value"
      shift 2
      ;;
    --config)
      CONFIG_FILE="${2:-}"
      [ -n "$CONFIG_FILE" ] || die "--config requires a value"
      shift 2
      ;;
    --sdk-root)
      SDK_ROOT="${2:-}"
      [ -n "$SDK_ROOT" ] || die "--sdk-root requires a value"
      shift 2
      ;;
    --sdk-archive)
      SDK_ARCHIVE_OVERRIDE="${2:-}"
      [ -n "$SDK_ARCHIVE_OVERRIDE" ] || die "--sdk-archive requires a value"
      shift 2
      ;;
    --passwall-luci-dir)
      PASSWALL_LUCI_DIR="${2:-}"
      [ -n "$PASSWALL_LUCI_DIR" ] || die "--passwall-luci-dir requires a value"
      shift 2
      ;;
    --passwall-packages-dir)
      PASSWALL_PACKAGES_DIR="${2:-}"
      [ -n "$PASSWALL_PACKAGES_DIR" ] || die "--passwall-packages-dir requires a value"
      shift 2
      ;;
    --passwall-luci-repo)
      PASSWALL_LUCI_REPO="${2:-}"
      [ -n "$PASSWALL_LUCI_REPO" ] || die "--passwall-luci-repo requires a value"
      shift 2
      ;;
    --passwall-packages-repo)
      PASSWALL_PACKAGES_REPO="${2:-}"
      [ -n "$PASSWALL_PACKAGES_REPO" ] || die "--passwall-packages-repo requires a value"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=1
      shift
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

cd "$REPO_ROOT"
validate_common_inputs

case "$MODE" in
  smoke)
    prepare_workspace
    load_config
    resolve_tag
    prepare_synthetic_payload
    run_payload_summary_regression
    run_install_smoke_test
    build_smoke_installer
    write_smoke_summary
    ;;
  full)
    run_full_mode
    ;;
  *)
    die "Unsupported mode: $MODE"
    ;;
esac
