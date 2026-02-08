#!/usr/bin/env bash
# Compile all PassWall dependency packages and luci-app-passwall.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd openwrt-sdk
export FORCE_UNSAFE_CONFIGURE=1
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"
unset CI

# ── Compile dependencies ────────────────────────────────────────────────────
group_start "Building PassWall dependencies"

log_info "Parallel jobs: $(nproc)"
log_info "Disk before build: $(df -h / --output=avail | tail -1 | tr -d ' ')"

PASSWALL_DEPS=(
  chinadns-ng dns2socks geoview hysteria ipt2socks microsocks naiveproxy
  shadow-tls shadowsocks-libev shadowsocks-rust shadowsocksr-libev simple-obfs
  sing-box tcping trojan-plus tuic-client v2ray-geodata v2ray-plugin
  xray-core xray-plugin
)

package_artifacts_exist() {
  local pkg="$1"
  [ -d bin/packages ] || return 1
  find bin/packages -type f \( -name "${pkg}_*.apk" -o -name "${pkg}-*.apk" \) -print -quit | grep -q .
}

BUILT=0 FAILED=0 FAILED_LIST=""

for pkg in "${PASSWALL_DEPS[@]}"; do
  log_info "Building: $pkg"
  PKG_PATH=""
  [ -d "package/passwall-packages/$pkg" ] && PKG_PATH="package/passwall-packages/$pkg"
  [ -z "$PKG_PATH" ] && [ -d "package/$pkg" ] && PKG_PATH="package/$pkg"

  if [ -z "$PKG_PATH" ]; then
    log_warning "Package not found: $pkg"
    FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $pkg"; continue
  fi

  if make_with_retry "$PKG_PATH/compile" "$pkg"; then
    BUILT=$((BUILT + 1))
  elif package_artifacts_exist "$pkg"; then
    log_info "Build returned error for $pkg but cached artifacts found"
    BUILT=$((BUILT + 1))
  else
    log_warning "Failed to compile: $pkg (skipping)"
    FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $pkg"
  fi
done

log_info "Build summary: $BUILT succeeded, $FAILED failed"
[ -n "$FAILED_LIST" ] && log_warning "Failed:$FAILED_LIST"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## PassWall Dependency Build Summary"
    echo "- **Built**: $BUILT packages"
    echo "- **Failed**: $FAILED packages"
    if [ -n "$FAILED_LIST" ]; then
      echo "### Failed Packages"
      for p in $FAILED_LIST; do echo "- \`$p\`"; done
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

log_info "Disk after deps: $(df -h / --output=avail | tail -1 | tr -d ' ')"
group_end

# ── Compile luci-app-passwall ───────────────────────────────────────────────
group_start "Compiling luci-app-passwall"
make_with_retry "package/luci-app-passwall/compile" "luci-app-passwall" \
  || { log_error "Failed to compile luci-app-passwall"; exit 1; }
group_end
