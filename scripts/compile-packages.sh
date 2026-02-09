#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# compile-packages.sh — 按工具链分组编译 PassWall 依赖包与主包
# compile-packages.sh — Compile PassWall dependencies (grouped by toolchain)
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd openwrt-sdk
export FORCE_UNSAFE_CONFIGURE=1
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"

# Rust ≥1.90 bootstrap 检测 CI 环境会 panic，必须取消这些变量
# Rust ≥1.90 bootstrap panics when CI env vars are set
unset CI GITHUB_ACTIONS

# ── 构建配置 / Build configuration ────────────────────────────────────────
# 最少成功包数（允许部分包失败）
# Minimum successful packages to consider build successful
MIN_REQUIRED_PACKAGES=${MIN_REQUIRED_PACKAGES:-15}
# 最大允许失败包数
# Maximum allowed failed packages before build fails
MAX_ALLOWED_FAILURES=${MAX_ALLOWED_FAILURES:-5}

# ── 包分组 / Package groups ────────────────────────────────────────────────
C_PACKAGES=(dns2socks ipt2socks microsocks shadowsocks-libev shadowsocksr-libev simple-obfs tcping trojan-plus)
GO_PACKAGES=(geoview hysteria sing-box v2ray-plugin xray-core xray-plugin)
RUST_PACKAGES=(shadow-tls shadowsocks-rust)
PREBUILT_PACKAGES=(chinadns-ng naiveproxy tuic-client v2ray-geodata)

ARTIFACT_FRESHNESS_MINUTES=${ARTIFACT_FRESHNESS_MINUTES:-5}

# ── 辅助函数 / Helpers ─────────────────────────────────────────────────────
pkg_artifacts_exist() {
  [ -d bin/packages ] || return 1
  find bin/packages -type f \( -name "${1}_*.apk" -o -name "${1}-*.apk" \) -print -quit | grep -q .
}

pkg_artifacts_fresh() {
  [ -d bin/packages ] || return 1
  find bin/packages -type f -mmin -"$ARTIFACT_FRESHNESS_MINUTES" \
    \( -name "${1}_*.apk" -o -name "${1}-*.apk" \) -print -quit | grep -q .
}

# ── 统计变量 / Counters ────────────────────────────────────────────────────
TOTAL_BUILT=0  TOTAL_FAILED=0  TOTAL_FAILED_LIST=""
GROUP_LABELS=()  GROUP_BUILT=()  GROUP_FAILED=()  GROUP_TIMES=()

# ── build_group <label> <pkg…> ─────────────────────────────────────────────
build_group() {
  local label="$1"; shift
  local pkgs=("$@")
  local built=0 failed=0 failed_list="" t0; t0=$(date +%s)

  group_start "Building $label packages"
  log_info "Packages ($label): ${pkgs[*]}"

  for pkg in "${pkgs[@]}"; do
    log_info "Building ($label): $pkg"

    # 查找包路径 / Locate package path
    local pkg_path=""
    [ -d "package/passwall-packages/$pkg" ] && pkg_path="package/passwall-packages/$pkg"
    [ -z "$pkg_path" ] && [ -d "package/$pkg" ] && pkg_path="package/$pkg"
    if [ -z "$pkg_path" ]; then
      log_warning "Package not found: $pkg"
      failed=$((failed + 1)); failed_list="$failed_list $pkg"; continue
    fi

    # 清除旧产物 / Remove stale artifacts
    find bin/packages -type f \( -name "${pkg}_*.apk" -o -name "${pkg}-*.apk" \) -delete 2>/dev/null || true
    sync

    if make_with_retry "$pkg_path/compile" "$pkg"; then
      if pkg_artifacts_fresh "$pkg"; then
        log_info "Fresh artifacts built for $pkg"
      else
        log_warning "Build OK but no fresh artifacts for $pkg (cached?)"
      fi
      built=$((built + 1))
    elif pkg_artifacts_exist "$pkg"; then
      log_warning "Build error for $pkg but cached artifacts found"
      built=$((built + 1))
    else
      log_warning "Failed ($label): $pkg — skipping"
      failed=$((failed + 1)); failed_list="$failed_list $pkg"
    fi
  done

  local elapsed=$(($(date +%s) - t0))
  log_info "$label: $built built, $failed failed (${elapsed}s)"
  [ -n "$failed_list" ] && log_warning "$label failed:$failed_list"
  group_end

  TOTAL_BUILT=$((TOTAL_BUILT + built))
  TOTAL_FAILED=$((TOTAL_FAILED + failed))
  TOTAL_FAILED_LIST="$TOTAL_FAILED_LIST$failed_list"
  GROUP_LABELS+=("$label")
  GROUP_BUILT+=("$built")
  GROUP_FAILED+=("$failed")
  GROUP_TIMES+=("$elapsed")
}

# ── 开始编译 / Start compilation ───────────────────────────────────────────
log_info "Jobs: $(nproc)  Disk: $(df -h / --output=avail | tail -1 | tr -d ' ')"
check_disk_space 10 || die "Insufficient disk space"

build_group "C/C++"    "${C_PACKAGES[@]}"
check_disk_space 5 || log_warning "Low disk after C/C++"

build_group "Go"       "${GO_PACKAGES[@]}"
check_disk_space 5 || log_warning "Low disk after Go"

build_group "Rust"     "${RUST_PACKAGES[@]}"
check_disk_space 5 || log_warning "Low disk after Rust"

build_group "Prebuilt" "${PREBUILT_PACKAGES[@]}"

# ── 编译摘要 / Build summary ──────────────────────────────────────────────
log_info "Total: $TOTAL_BUILT built, $TOTAL_FAILED failed"
[ -n "$TOTAL_FAILED_LIST" ] && log_warning "Failed:$TOTAL_FAILED_LIST"

# 写入 GitHub Step Summary / Write step summary
write_summary() {
  echo "## PassWall Build Summary"
  echo "| Group | Built | Failed | Time |"
  echo "|-------|-------|--------|------|"
  for i in "${!GROUP_LABELS[@]}"; do
    local t="${GROUP_TIMES[$i]}"
    local ts="${t}s"; [ "$t" -ge 60 ] && ts="$((t / 60))m $((t % 60))s"
    echo "| ${GROUP_LABELS[$i]} | ${GROUP_BUILT[$i]} | ${GROUP_FAILED[$i]} | $ts |"
  done
  echo "| **Total** | **$TOTAL_BUILT** | **$TOTAL_FAILED** | — |"
  if [ -n "$TOTAL_FAILED_LIST" ]; then
    echo ""
    echo "### Failed Packages"
    for p in $TOTAL_FAILED_LIST; do echo "- \`$p\`"; done
  fi
  echo ""
  echo "### Build Status"
  if [ "$TOTAL_BUILT" -ge "$MIN_REQUIRED_PACKAGES" ] && [ "$TOTAL_FAILED" -le "$MAX_ALLOWED_FAILURES" ]; then
    echo "✅ Build requirements met ($TOTAL_BUILT ≥ $MIN_REQUIRED_PACKAGES, failures $TOTAL_FAILED ≤ $MAX_ALLOWED_FAILURES)"
  else
    echo "⚠️ Build requirements not fully met (need $MIN_REQUIRED_PACKAGES packages, max $MAX_ALLOWED_FAILURES failures)"
  fi
}

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && write_summary >> "$GITHUB_STEP_SUMMARY"

log_info "Disk after deps: $(df -h / --output=avail | tail -1 | tr -d ' ')"

# ── 检查依赖包构建结果 / Check dependency build results ───────────────────
# 如果失败太多或成功太少，提前退出
# Fail early if too many failures or not enough successes
if [ "$TOTAL_FAILED" -gt "$MAX_ALLOWED_FAILURES" ]; then
  die "Too many package failures: $TOTAL_FAILED (max allowed: $MAX_ALLOWED_FAILURES)"
fi
if [ "$TOTAL_BUILT" -lt "$MIN_REQUIRED_PACKAGES" ]; then
  log_warning "Only $TOTAL_BUILT packages built (recommended minimum: $MIN_REQUIRED_PACKAGES)"
  # 继续尝试编译主包，collect-packages.sh 会进行最终验证
  # Continue to try compiling main package; collect-packages.sh will do final validation
fi

# ── 编译 luci-app-passwall / Compile main package ─────────────────────────
group_start "Compiling luci-app-passwall"
make_with_retry "package/luci-app-passwall/compile" "luci-app-passwall" \
  || die "Failed to compile luci-app-passwall"
group_end

log_info "Compilation completed: $TOTAL_BUILT dependencies + luci-app-passwall"
