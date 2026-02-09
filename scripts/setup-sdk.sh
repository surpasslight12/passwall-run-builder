#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-sdk.sh — 下载或验证 OpenWrt SDK，替换内置 Go
# setup-sdk.sh — Download / validate OpenWrt SDK and update bundled Go
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: "${OPENWRT_SDK_URL:?OPENWRT_SDK_URL not set}"
SDK_CACHE_HIT="${1:-false}"

# ── 验证 SDK 缓存完整性 / Validate cached SDK ──────────────────────────────
validate_sdk_cache() {
  local required=(openwrt-sdk openwrt-sdk/Makefile openwrt-sdk/scripts/feeds
                  openwrt-sdk/staging_dir openwrt-sdk/staging_dir/host/bin/xz)
  for item in "${required[@]}"; do
    [ -e "$item" ] || return 1
  done
}

# ── 下载或使用缓存 / Download or use cache ─────────────────────────────────
if [ "$SDK_CACHE_HIT" = "true" ] && validate_sdk_cache; then
  log_info "Cached SDK validated"
  # 清除旧构建产物和配置，防止缓存掩盖编译错误
  # Clean stale artifacts/config to prevent cache masking build failures
  rm -rf openwrt-sdk/bin/packages/* 2>/dev/null || true
  rm -f  openwrt-sdk/.config openwrt-sdk/.config.old 2>/dev/null || true
  rm -rf openwrt-sdk/tmp/.config-*.in 2>/dev/null || true
  log_info "Stale build artifacts and config cleaned"
else
  [ "$SDK_CACHE_HIT" = "true" ] && log_warning "Cached SDK validation failed, re-downloading"
  group_start "Downloading OpenWrt SDK"
  rm -rf openwrt-sdk; mkdir -p openwrt-sdk; cd openwrt-sdk

  SDK_FILE=$(basename "$OPENWRT_SDK_URL")
  log_info "Downloading: $SDK_FILE"
  retry 3 30 300 "Download SDK" "wget -q '$OPENWRT_SDK_URL' -O '$SDK_FILE'"
  [ -f "$SDK_FILE" ] || die "SDK download failed"
  log_info "Downloaded ($(du -h "$SDK_FILE" | cut -f1))"

  log_info "Extracting SDK…"
  case "$SDK_FILE" in
    *.tar.zst) tar --use-compress-program=zstd -xf "$SDK_FILE" --strip-components=1 ;;
    *.tar.xz)  tar xf "$SDK_FILE" --strip-components=1 ;;
    *)         die "Unsupported archive: $SDK_FILE" ;;
  esac
  rm -f "$SDK_FILE"
  log_info "SDK extracted"
  cd ..
  group_end
fi

# ── 替换 SDK 内置 Go / Replace SDK bundled Go ──────────────────────────────
group_start "Updating SDK Go toolchain"

SYSTEM_GO=$(command -v go 2>/dev/null || echo "/usr/local/go/bin/go")
if [ ! -x "$SYSTEM_GO" ]; then
  log_warning "System Go not found, skipping SDK Go update"
  group_end; exit 0
fi

SYSTEM_GO_VER=$("$SYSTEM_GO" version | awk '{print $3}')
GOROOT=$("$SYSTEM_GO" env GOROOT)
log_info "System Go: $SYSTEM_GO_VER (GOROOT: $GOROOT)"

REPLACED=0
for root in openwrt-sdk/staging_dir/hostpkg openwrt-sdk/staging_dir/host; do
  [ -d "$root" ] || continue
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    SDK_VER=$("$d/bin/go" version 2>/dev/null | awk '{print $3}' || echo "unknown")
    if [ "$SDK_VER" = "$SYSTEM_GO_VER" ]; then
      log_info "SDK Go at $d already up-to-date"
    else
      log_info "Replacing SDK Go ($SDK_VER) at $d"
      rm -rf "$d"; cp -a "$GOROOT" "$d"
    fi
    REPLACED=$((REPLACED + 1))
  done < <(find "$root" -maxdepth 3 -type d \( -name "go-*" -o -name "go" \) 2>/dev/null)
done
[ "$REPLACED" -eq 0 ] && log_info "No SDK Go directories found; system Go will be used"
group_end
