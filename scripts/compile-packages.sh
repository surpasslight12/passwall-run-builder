#!/usr/bin/env bash
# compile-packages.sh — 按工具链分组编译 PassWall 依赖包
# Compile PassWall packages grouped by toolchain
source "$(dirname "$0")/lib.sh"

cd openwrt-sdk
export FORCE_UNSAFE_CONFIGURE=1
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"
# Rust ≥1.90 bootstrap panics when CI env vars are set
unset CI GITHUB_ACTIONS

# Rust 编译优化 / Rust compilation optimizations
# 并行代码生成加速编译。16 是 Rust 推荐的生产环境值（1-16），在编译速度和运行时优化间取得平衡
# Parallel codegen for faster builds. 16 is Rust's recommended production value (1-16), balancing compile time and runtime optimization
# 禁用 LTO 以加速编译，设置基础优化级别 / Disable LTO for faster compilation, set basic optimization level
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C codegen-units=16 -C lto=off -C opt-level=2"
export CARGO_INCREMENTAL=1
export CARGO_NET_GIT_FETCH_WITH_CLI=true
# 减少调试信息以加速编译和链接 / Reduce debug info to speed up compilation and linking
export CARGO_PROFILE_RELEASE_DEBUG=0
# 启用 sccache 加速编译 / Enable sccache for faster compilation
if command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER=sccache
  export SCCACHE_DIR="$HOME/.cache/sccache"
  mkdir -p "$SCCACHE_DIR"
  if ! sccache --start-server 2>/dev/null; then
    log_warn "sccache server failed to start, builds will proceed without caching"
  else
    log_info "sccache enabled for Rust compilation"
  fi
fi


# ── 包分组 / Package groups ──
C_PKGS=(dns2socks ipt2socks microsocks shadowsocks-libev shadowsocksr-libev simple-obfs tcping trojan-plus)
GO_PKGS=(geoview hysteria sing-box v2ray-plugin xray-core xray-plugin)
RUST_PKGS=(shadow-tls shadowsocks-rust)
PRE_PKGS=(chinadns-ng naiveproxy tuic-client v2ray-geodata)

C_TIMEOUT_MIN=${C_TIMEOUT_MIN:-30}
GO_TIMEOUT_MIN=${GO_TIMEOUT_MIN:-30}
RUST_TIMEOUT_MIN=${RUST_TIMEOUT_MIN:-60}
PRE_TIMEOUT_MIN=${PRE_TIMEOUT_MIN:-30}

TOTAL_OK=0 TOTAL_FAIL=0 FAILED_LIST="" PKG_TIMINGS=""

# ── 编译一组包 / Build a group ──
# Usage: build_group <label> <timeout_minutes> <package1> [package2...]
build_group() {
  local label="$1" timeout_min="$2"; shift 2
  local ok=0 fail=0 t0; t0=$(date +%s)

  add_timing() {
    local name="$1" status="$2" duration="$3"
    log_info "$name finished in ${duration}s ($status)"
    PKG_TIMINGS+="${label}|${name}|${status}|${duration}"$'\n'
  }

  group_start "Build $label"
  for pkg in "$@"; do
    local pkg_path="" status="ok" pkg_t0 pkg_dur
    pkg_t0=$(date +%s)
    [ -d "package/passwall-packages/$pkg" ] && pkg_path="package/passwall-packages/$pkg"
    [ -z "$pkg_path" ] && [ -d "package/$pkg" ] && pkg_path="package/$pkg"
    if [ -z "$pkg_path" ]; then
      log_warn "Package not found: $pkg"; fail=$((fail + 1)); FAILED_LIST="$FAILED_LIST $pkg"; status="missing"
    else
      if make_pkg "${pkg_path}/compile" "$pkg" "$timeout_min"; then
        ok=$((ok + 1))
        status="ok"
      else
        log_warn "Skipping failed package: $pkg"
        fail=$((fail + 1)); FAILED_LIST="$FAILED_LIST $pkg"; status="failed"
      fi
    fi
    pkg_dur=$(( $(date +%s) - pkg_t0 ))
    add_timing "$pkg" "$status" "$pkg_dur"
  done
  log_info "$label done: $ok OK, $fail failed ($(($(date +%s) - t0))s)"
  group_end

  TOTAL_OK=$((TOTAL_OK + ok))
  TOTAL_FAIL=$((TOTAL_FAIL + fail))
}

# ── 开始编译 / Start ──
check_disk_space 10

build_group "Rust"     "$RUST_TIMEOUT_MIN" "${RUST_PKGS[@]}"
build_group "Go"       "$GO_TIMEOUT_MIN" "${GO_PKGS[@]}"
build_group "C/C++"    "$C_TIMEOUT_MIN" "${C_PKGS[@]}"
build_group "Prebuilt" "$PRE_TIMEOUT_MIN" "${PRE_PKGS[@]}"

log_info "Dependencies: $TOTAL_OK OK, $TOTAL_FAIL failed"
[ -n "$FAILED_LIST" ] && log_warn "Failed:$FAILED_LIST"

# 写入摘要 / Write summary
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Build Summary"
    echo "- **Built**: $TOTAL_OK"
    echo "- **Failed**: $TOTAL_FAIL"
    [ -n "$FAILED_LIST" ] && { echo "### Failed"; for p in $FAILED_LIST; do echo "- \`$p\`"; done; }
    if [ -n "$PKG_TIMINGS" ]; then
      echo "### Build Durations"
      echo "| Group | Package | Status | Time |"
      echo "| --- | --- | --- | --- |"
      while IFS='|' read -r group pkg status sec; do
        [ -z "$group" ] && continue
        echo "| $group | $pkg | $status | ${sec}s |"
      done <<EOF
$PKG_TIMINGS
EOF
    fi
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

# ── sccache 统计 / sccache statistics ──
if command -v sccache >/dev/null 2>&1 && [ -n "${RUSTC_WRAPPER:-}" ]; then
  group_start "sccache statistics"
  SCCACHE_STATS=$(sccache --show-stats 2>&1 || true)
  printf '%s\n' "$SCCACHE_STATS"
  group_end
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### sccache statistics"
      echo '```'
      printf '%s\n' "$SCCACHE_STATS"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

log_info "Compilation complete: $TOTAL_OK deps + luci-app-passwall"
