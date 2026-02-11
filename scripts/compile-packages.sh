#!/usr/bin/env bash
# compile-packages.sh — 按工具链分组编译 PassWall 依赖包
# Compile PassWall packages grouped by toolchain
source "$(dirname "$0")/lib.sh"

cd openwrt-sdk
export FORCE_UNSAFE_CONFIGURE=1
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"
# Rust ≥1.90 bootstrap panics when CI env vars are set
unset CI GITHUB_ACTIONS

# ── 包分组 / Package groups ──
C_PKGS=(dns2socks ipt2socks microsocks shadowsocks-libev shadowsocksr-libev simple-obfs tcping trojan-plus)
GO_PKGS=(geoview hysteria sing-box v2ray-plugin xray-core xray-plugin)
RUST_PKGS=(shadow-tls shadowsocks-rust)
PRE_PKGS=(chinadns-ng naiveproxy tuic-client v2ray-geodata)

TOTAL_OK=0 TOTAL_FAIL=0 FAILED_LIST=""

# ── 编译一组包 / Build a group ──
# Usage: build_group <label> <timeout_minutes> <package1> [package2...]
build_group() {
  local label="$1" timeout_min="$2"; shift 2
  local ok=0 fail=0 t0; t0=$(date +%s)

  group_start "Build $label"
  for pkg in "$@"; do
    local pkg_path=""
    [ -d "package/passwall-packages/$pkg" ] && pkg_path="package/passwall-packages/$pkg"
    [ -z "$pkg_path" ] && [ -d "package/$pkg" ] && pkg_path="package/$pkg"
    if [ -z "$pkg_path" ]; then
      log_warn "Package not found: $pkg"; fail=$((fail + 1)); FAILED_LIST="$FAILED_LIST $pkg"; continue
    fi

    if make_pkg "${pkg_path}/compile" "$pkg" "$timeout_min"; then
      ok=$((ok + 1))
    else
      log_warn "Skipping failed package: $pkg"
      fail=$((fail + 1)); FAILED_LIST="$FAILED_LIST $pkg"
    fi
  done
  log_info "$label done: $ok OK, $fail failed ($(($(date +%s) - t0))s)"
  group_end

  TOTAL_OK=$((TOTAL_OK + ok))
  TOTAL_FAIL=$((TOTAL_FAIL + fail))
}

# ── 开始编译 / Start ──
check_disk_space 10

build_group "C/C++"    30 "${C_PKGS[@]}"
build_group "Go"       30 "${GO_PKGS[@]}"
build_group "Rust"     45 "${RUST_PKGS[@]}"
build_group "Prebuilt" 30 "${PRE_PKGS[@]}"

log_info "Dependencies: $TOTAL_OK OK, $TOTAL_FAIL failed"
[ -n "$FAILED_LIST" ] && log_warn "Failed:$FAILED_LIST"

# 写入摘要 / Write summary
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Build Summary"
    echo "- **Built**: $TOTAL_OK"
    echo "- **Failed**: $TOTAL_FAIL"
    [ -n "$FAILED_LIST" ] && { echo "### Failed"; for p in $FAILED_LIST; do echo "- \`$p\`"; done; }
  } >> "$GITHUB_STEP_SUMMARY"
fi

MIN_REQUIRED=${MIN_REQUIRED_PACKAGES:-15}
MAX_FAILURES=${MAX_ALLOWED_FAILURES:-5}
[ "$TOTAL_FAIL" -gt "$MAX_FAILURES" ] && die "Too many failures: $TOTAL_FAIL > $MAX_FAILURES"
[ "$TOTAL_OK" -lt "$MIN_REQUIRED" ] && log_warn "Only $TOTAL_OK packages built (need $MIN_REQUIRED)"

# ── 编译主包 / Compile main package ──
group_start "Compile luci-app-passwall"
make_pkg "package/luci-app-passwall/compile" "luci-app-passwall" 30 \
  || die "Failed to compile luci-app-passwall"
group_end

log_info "Compilation complete: $TOTAL_OK deps + luci-app-passwall"
