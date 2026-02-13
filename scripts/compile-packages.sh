#!/usr/bin/env bash
# compile-packages.sh — 按工具链分组编译 PassWall 依赖包
# Compile PassWall packages grouped by toolchain
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib.sh"

step_start "Compile packages"

cd openwrt-sdk || die "Cannot enter openwrt-sdk directory"
export FORCE_UNSAFE_CONFIGURE=1
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"
# Rust ≥1.90 bootstrap panics when CI env vars are set
unset CI GITHUB_ACTIONS

# Rust 编译优化 / Rust compilation optimizations
# 默认偏向运行性能，可通过环境变量覆盖 / Defaults favor runtime performance, overridable via env vars
RUST_CODEGEN_UNITS="${RUST_CODEGEN_UNITS:-8}"
RUST_LTO_MODE="${RUST_LTO_MODE:-thin}"
RUST_OPT_LEVEL="${RUST_OPT_LEVEL:-3}"
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C codegen-units=${RUST_CODEGEN_UNITS} -C lto=${RUST_LTO_MODE} -C opt-level=${RUST_OPT_LEVEL}"
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

log_info "RUSTFLAGS=$RUSTFLAGS"
log_info "CARGO_INCREMENTAL=$CARGO_INCREMENTAL"
log_info "CARGO_PROFILE_RELEASE_DEBUG=$CARGO_PROFILE_RELEASE_DEBUG"
log_info "RUSTC_WRAPPER=${RUSTC_WRAPPER:-<not set>}"
[ "${RUST_ENV_DIAG:-0}" = "1" ] && log_info "Rust env diag: SCCACHE_DIR=${SCCACHE_DIR:-<not set>} CARGO_NET_GIT_FETCH_WITH_CLI=${CARGO_NET_GIT_FETCH_WITH_CLI:-<not set>}"

# ── 包分组 / Package groups ──
C_PKGS=(dns2socks ipt2socks microsocks shadowsocks-libev shadowsocksr-libev simple-obfs tcping trojan-plus)
GO_PKGS=(geoview hysteria sing-box v2ray-plugin xray-core xray-plugin)
RUST_PKGS=(shadow-tls shadowsocks-rust)
PRE_PKGS=(chinadns-ng naiveproxy tuic-client v2ray-geodata)

PKGCONF="$SCRIPT_DIR/../config/packages.conf"
SELECTED_PACKAGES=""
if [ -f "$PKGCONF" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || continue
    SELECTED_PACKAGES+="$line"$'\n'
  done < "$PKGCONF"
fi

is_package_selected() {
  local pkg="$1"
  [ -z "$SELECTED_PACKAGES" ] && return 0
  case "$pkg" in
    shadowsocks-libev)  printf '%s' "$SELECTED_PACKAGES" | grep -Eq '^shadowsocks-libev(-|$)' ;;
    shadowsocks-rust)   printf '%s' "$SELECTED_PACKAGES" | grep -Eq '^shadowsocks-rust(-|$)' ;;
    shadowsocksr-libev) printf '%s' "$SELECTED_PACKAGES" | grep -Eq '^shadowsocksr-libev(-|$)' ;;
    simple-obfs)        printf '%s' "$SELECTED_PACKAGES" | grep -Eq '^simple-obfs(-|$)' ;;
    v2ray-geodata)      printf '%s' "$SELECTED_PACKAGES" | grep -Eq '^v2ray-(geodata|geoip|geosite)$' ;;
    *)                  printf '%s' "$SELECTED_PACKAGES" | grep -qx "$pkg" ;;
  esac
}

TOTAL_OK=0 TOTAL_FAIL=0 FAILED_LIST="" PKG_TIMINGS=""
declare -A FEEDS_CACHE=()
while IFS= read -r -d '' fpath; do
  fname=$(basename "$fpath")
  if [ -n "${FEEDS_CACHE[$fname]+x}" ]; then
    log_warn "Duplicate feed package name detected: $fname (${FEEDS_CACHE[$fname]} vs $fpath)"
    continue
  fi
  FEEDS_CACHE["$fname"]="$fpath"
done < <(find package/feeds -mindepth 2 -maxdepth 2 \( -type l -o -type d \) -print0 2>/dev/null)

# ── 编译一组包 / Build a group ──
# Usage: build_group <label> <package1> [package2...]
build_group() {
  local label="$1"; shift
  local ok=0 fail=0 t0 total_pkgs=0
  t0=$(date +%s)
  for pkg in "$@"; do
    is_package_selected "$pkg" && total_pkgs=$((total_pkgs + 1))
  done
  if [ "$total_pkgs" -eq 0 ]; then
    log_info "No selected packages in $label, skipping"
    return
  fi

  add_timing() {
    local group_label="$1" name="$2" status="$3" duration="$4"
    local display_time="$duration"
    [[ "$duration" =~ ^[0-9]+$ ]] && display_time="${duration}s"
    log_info "$name finished in ${display_time} ($status)"
    PKG_TIMINGS+="${group_label}|${name}|${status}|${display_time}"$'\n'
  }

  group_start "Build $label (${total_pkgs} packages)"

  local idx=0
  for pkg in "$@"; do
    is_package_selected "$pkg" || continue
    idx=$((idx + 1))
    local pkg_path="" status="ok" pkg_t0 pkg_dur
    [ -d "package/passwall-packages/$pkg" ] && pkg_path="package/passwall-packages/$pkg"
    [ -z "$pkg_path" ] && [ -d "package/$pkg" ] && pkg_path="package/$pkg"
    [ -z "$pkg_path" ] && [ -n "${FEEDS_CACHE[$pkg]+x}" ] && pkg_path="${FEEDS_CACHE[$pkg]}"
    if [ -z "$pkg_path" ]; then
      log_warn "[$label ${idx}/${total_pkgs}] Package not found: $pkg"
      fail=$((fail + 1))
      FAILED_LIST="$FAILED_LIST $pkg"
      status="missing"
      add_timing "$label" "$pkg" "$status" "N/A"
      continue
    fi
    log_info "[$label ${idx}/${total_pkgs}] Building $pkg …"
    pkg_t0=$(date +%s)
    if make_pkg "${pkg_path}/compile" "$pkg"; then
      ok=$((ok + 1))
      status="ok"
    else
      log_warn "[$label ${idx}/${total_pkgs}] Skipping failed package: $pkg"
      fail=$((fail + 1))
      FAILED_LIST="$FAILED_LIST $pkg"
      status="failed"
    fi
    pkg_dur=$(( $(date +%s) - pkg_t0 ))
    add_timing "$label" "$pkg" "$status" "$pkg_dur"
  done
  log_info "$label complete: $ok OK, $fail failed, total $(($(date +%s) - t0))s"
  group_end

  TOTAL_OK=$((TOTAL_OK + ok))
  TOTAL_FAIL=$((TOTAL_FAIL + fail))
}

# ── 开始编译 / Start ──
check_disk_space 10

build_group "Rust"     "${RUST_PKGS[@]}"
build_group "Go"       "${GO_PKGS[@]}"
build_group "C/C++"    "${C_PKGS[@]}"
build_group "Prebuilt" "${PRE_PKGS[@]}"

log_info "Dependencies: $TOTAL_OK OK, $TOTAL_FAIL failed"
[ -n "$FAILED_LIST" ] && log_warn "Failed:$FAILED_LIST"

# 写入摘要 / Write summary
{
  SUMMARY="## Build Summary"$'\n'
  SUMMARY+="- **Built**: $TOTAL_OK"$'\n'
  SUMMARY+="- **Failed**: $TOTAL_FAIL"$'\n'
  if [ -n "$FAILED_LIST" ]; then
    SUMMARY+="### Failed"$'\n'
    for p in $FAILED_LIST; do SUMMARY+="- \`$p\`"$'\n'; done
  fi
  if [ -n "$PKG_TIMINGS" ]; then
    SUMMARY+="### Build Durations"$'\n'
    SUMMARY+="| Group | Package | Status | Time |"$'\n'
    SUMMARY+="| --- | --- | --- | --- |"$'\n'
    while IFS='|' read -r group pkg status sec; do
      [ -z "$group" ] && continue
      SUMMARY+="| $group | $pkg | $status | $sec |"$'\n'
    done <<EOF
$PKG_TIMINGS
EOF
  fi
  gh_summary "$SUMMARY"
}

MIN_REQUIRED=${MIN_REQUIRED_PACKAGES:-15}
MAX_FAILURES=${MAX_ALLOWED_FAILURES:-5}
[ "$TOTAL_FAIL" -gt "$MAX_FAILURES" ] && die "Too many failures: $TOTAL_FAIL > $MAX_FAILURES"
[ "$TOTAL_OK" -lt "$MIN_REQUIRED" ] && log_warn "Only $TOTAL_OK packages built (need $MIN_REQUIRED)"

# ── 编译主包 / Compile main package ──
group_start "Compile luci-app-passwall"
make_pkg "package/luci-app-passwall/compile" "luci-app-passwall" \
  || die "Failed to compile luci-app-passwall"
group_end

# ── sccache 统计 / sccache statistics ──
if command -v sccache >/dev/null 2>&1 && [ -n "${RUSTC_WRAPPER:-}" ]; then
  group_start "sccache statistics"
  SCCACHE_STATS=$(sccache --show-stats 2>&1 || true)
  log_info "sccache stats:"
  printf '%s\n' "$SCCACHE_STATS"
  group_end
  gh_summary "### sccache statistics"$'\n'"\`\`\`text"$'\n'"$SCCACHE_STATS"$'\n'"\`\`\`"
fi

log_info "Compilation complete: $TOTAL_OK deps + luci-app-passwall"

step_end
