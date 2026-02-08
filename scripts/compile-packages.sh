#!/usr/bin/env bash
# Compile all PassWall dependency packages and luci-app-passwall.
# Packages are grouped by toolchain (C/C++, Go, Rust, Prebuilt/Data)
# so that failures are easier to diagnose.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd openwrt-sdk
export FORCE_UNSAFE_CONFIGURE=1
export GOPROXY="https://proxy.golang.org,https://goproxy.io,direct"
# Rust 1.90+ bootstrap panics when it detects a CI environment and
# llvm.download-ci-llvm is set to "true".  GitHub Actions sets both CI and
# GITHUB_ACTIONS; unsetting them lets the Rust toolchain build normally.
unset CI GITHUB_ACTIONS

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

# Check if artifacts were built in this session (modified in last 5 minutes)
package_artifacts_fresh() {
  local pkg="$1"
  [ -d bin/packages ] || return 1
  find bin/packages -type f -mmin -5 \( -name "${pkg}_*.apk" -o -name "${pkg}-*.apk" \) -print -quit | grep -q .
}

check_disk_space() {
  local min_gb="${1:-10}"
  local avail_kb; avail_kb=$(df / --output=avail | tail -1 | tr -d ' ')
  local avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt "$min_gb" ]; then
    log_error "Insufficient disk space: ${avail_gb}GB (need ${min_gb}GB)"
    return 1
  fi
  log_info "Available disk space: ${avail_gb}GB"
  return 0
}

TOTAL_BUILT=0 TOTAL_FAILED=0 TOTAL_FAILED_LIST=""
GROUP_LABELS=() GROUP_BUILT=() GROUP_FAILED=() GROUP_TIMES=()

# build_group <group_label> <pkg1> <pkg2> …
build_group() {
  local label="$1"; shift
  local pkgs=("$@")
  local built=0 failed=0 failed_list=""
  local group_start_time; group_start_time=$(date +%s)

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

    # Remove stale cached artifacts so package_artifacts_exist only finds
    # genuinely new output from the current build, not leftovers from the
    # SDK cache that mask real compilation failures.
    find bin/packages -type f \( -name "${pkg}_*.apk" -o -name "${pkg}-*.apk" \) -delete 2>/dev/null || true
    sync  # Ensure filesystem flushes deletes before checking artifacts

    if make_with_retry "$PKG_PATH/compile" "$pkg"; then
      if package_artifacts_fresh "$pkg"; then
        log_info "Successfully built fresh artifacts for $pkg"
        built=$((built + 1))
      else
        log_warning "Build succeeded but no fresh artifacts for $pkg (using cached?)"
        built=$((built + 1))
      fi
    elif package_artifacts_exist "$pkg"; then
      log_warning "Build returned error for $pkg but cached artifacts found"
      built=$((built + 1))
    else
      log_warning "Failed to compile ($label): $pkg (skipping)"
      failed=$((failed + 1)); failed_list="$failed_list $pkg"
    fi
  done

  log_info "$label summary: $built succeeded, $failed failed"
  [ -n "$failed_list" ] && log_warning "$label failed:$failed_list"
  
  local group_duration=$(($(date +%s) - group_start_time))
  log_info "$label completed in ${group_duration}s"
  group_end

  TOTAL_BUILT=$((TOTAL_BUILT + built))
  TOTAL_FAILED=$((TOTAL_FAILED + failed))
  TOTAL_FAILED_LIST="$TOTAL_FAILED_LIST$failed_list"
  GROUP_LABELS+=("$label"); GROUP_BUILT+=("$built"); GROUP_FAILED+=("$failed"); GROUP_TIMES+=("$group_duration")
}

# ── Compile dependencies ────────────────────────────────────────────────────
log_info "Parallel jobs: $(nproc)"
log_info "Disk before build: $(df -h / --output=avail | tail -1 | tr -d ' ')"

check_disk_space 10 || { log_error "Insufficient disk space to continue"; exit 1; }

build_group "C/C++"    "${C_PACKAGES[@]}"
check_disk_space 5 || log_warning "Low disk space after C/C++ builds"

build_group "Go"       "${GO_PACKAGES[@]}"
check_disk_space 5 || log_warning "Low disk space after Go builds"

build_group "Rust"     "${RUST_PACKAGES[@]}"
check_disk_space 5 || log_warning "Low disk space after Rust builds"

build_group "Prebuilt" "${PREBUILT_PACKAGES[@]}"

log_info "Overall summary: $TOTAL_BUILT succeeded, $TOTAL_FAILED failed"
[ -n "$TOTAL_FAILED_LIST" ] && log_warning "Failed:$TOTAL_FAILED_LIST"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## PassWall Dependency Build Summary"
    echo "| Group | Built | Failed | Time |"
    echo "|-------|-------|--------|------|"
    for i in "${!GROUP_LABELS[@]}"; do
      local time_str="${GROUP_TIMES[$i]}s"
      if [ "${GROUP_TIMES[$i]}" -ge 60 ]; then
        time_str="$((GROUP_TIMES[$i] / 60))m $((GROUP_TIMES[$i] % 60))s"
      fi
      echo "| ${GROUP_LABELS[$i]} | ${GROUP_BUILT[$i]} | ${GROUP_FAILED[$i]} | $time_str |"
    done
    echo "| **Total** | **$TOTAL_BUILT** | **$TOTAL_FAILED** | - |"
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
