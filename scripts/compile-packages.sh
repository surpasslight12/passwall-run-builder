#!/usr/bin/env bash
# Compile all PassWall dependency packages and luci-app-passwall.
# Packages are grouped by toolchain (C/C++, Go, Rust, Prebuilt/Data)
# so that failures are easier to diagnose.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd openwrt-sdk
export FORCE_UNSAFE_CONFIGURE=1
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"
unset CI

# ── Package groups by toolchain ─────────────────────────────────────────────
C_PACKAGES=(
  dns2socks ipt2socks microsocks shadowsocks-libev shadowsocksr-libev
  simple-obfs tcping trojan-plus
)

GO_PACKAGES=(
  geoview hysteria sing-box v2ray-plugin xray-core xray-plugin
)

RUST_PACKAGES=(
  shadow-tls shadowsocks-rust
)

PREBUILT_PACKAGES=(
  chinadns-ng naiveproxy tuic-client v2ray-geodata
)

# ── Helpers ─────────────────────────────────────────────────────────────────
package_artifacts_exist() {
  local pkg="$1"
  [ -d bin/packages ] || return 1
  find bin/packages -type f \( -name "${pkg}_*.apk" -o -name "${pkg}-*.apk" \) -print -quit | grep -q .
}

TOTAL_BUILT=0 TOTAL_FAILED=0 TOTAL_FAILED_LIST=""
GROUP_LABELS=() GROUP_BUILT=() GROUP_FAILED=()

# build_group <group_label> <pkg1> <pkg2> …
build_group() {
  local label="$1"; shift
  local pkgs=("$@")
  local built=0 failed=0 failed_list=""

  group_start "Building $label packages"
  log_info "Packages ($label): ${pkgs[*]}"

  for pkg in "${pkgs[@]}"; do
    log_info "Building ($label): $pkg"
    PKG_PATH=""
    [ -d "package/passwall-packages/$pkg" ] && PKG_PATH="package/passwall-packages/$pkg"
    [ -z "$PKG_PATH" ] && [ -d "package/$pkg" ] && PKG_PATH="package/$pkg"

    if [ -z "$PKG_PATH" ]; then
      log_warning "Package not found: $pkg"
      failed=$((failed + 1)); failed_list="$failed_list $pkg"; continue
    fi

    if make_with_retry "$PKG_PATH/compile" "$pkg"; then
      built=$((built + 1))
    elif package_artifacts_exist "$pkg"; then
      log_info "Build returned error for $pkg but cached artifacts found"
      built=$((built + 1))
    else
      log_warning "Failed to compile ($label): $pkg (skipping)"
      failed=$((failed + 1)); failed_list="$failed_list $pkg"
    fi
  done

  log_info "$label summary: $built succeeded, $failed failed"
  [ -n "$failed_list" ] && log_warning "$label failed:$failed_list"
  group_end

  TOTAL_BUILT=$((TOTAL_BUILT + built))
  TOTAL_FAILED=$((TOTAL_FAILED + failed))
  TOTAL_FAILED_LIST="$TOTAL_FAILED_LIST$failed_list"
  GROUP_LABELS+=("$label"); GROUP_BUILT+=("$built"); GROUP_FAILED+=("$failed")
}

# ── Compile dependencies ────────────────────────────────────────────────────
log_info "Parallel jobs: $(nproc)"
log_info "Disk before build: $(df -h / --output=avail | tail -1 | tr -d ' ')"

build_group "C/C++"    "${C_PACKAGES[@]}"
build_group "Go"       "${GO_PACKAGES[@]}"
build_group "Rust"     "${RUST_PACKAGES[@]}"
build_group "Prebuilt" "${PREBUILT_PACKAGES[@]}"

log_info "Overall summary: $TOTAL_BUILT succeeded, $TOTAL_FAILED failed"
[ -n "$TOTAL_FAILED_LIST" ] && log_warning "Failed:$TOTAL_FAILED_LIST"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## PassWall Dependency Build Summary"
    echo "| Group | Built | Failed |"
    echo "|-------|-------|--------|"
    for i in "${!GROUP_LABELS[@]}"; do
      echo "| ${GROUP_LABELS[$i]} | ${GROUP_BUILT[$i]} | ${GROUP_FAILED[$i]} |"
    done
    echo "| **Total** | **$TOTAL_BUILT** | **$TOTAL_FAILED** |"
    if [ -n "$TOTAL_FAILED_LIST" ]; then
      echo "### Failed Packages"
      for p in $TOTAL_FAILED_LIST; do echo "- \`$p\`"; done
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

log_info "Disk after deps: $(df -h / --output=avail | tail -1 | tr -d ' ')"

# ── Compile luci-app-passwall ───────────────────────────────────────────────
group_start "Compiling luci-app-passwall"
make_with_retry "package/luci-app-passwall/compile" "luci-app-passwall" \
  || { log_error "Failed to compile luci-app-passwall"; exit 1; }
group_end
