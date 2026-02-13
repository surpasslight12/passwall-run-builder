#!/usr/bin/env bash
# setup-sdk.sh — 下载或恢复 OpenWrt SDK，替换内置 Go
# Download/restore OpenWrt SDK and replace bundled Go
source "$(dirname "$0")/lib.sh"

step_start "Setup SDK"

: "${OPENWRT_SDK_URL:?OPENWRT_SDK_URL not set}"
SDK_CACHE_HIT="${1:-false}"

# ── SDK 下载或缓存恢复 / Download or restore SDK ──
if [ "$SDK_CACHE_HIT" = "true" ] && [ -f openwrt-sdk/Makefile ]; then
  log_info "Using cached SDK"
  rm -rf openwrt-sdk/bin/packages/* openwrt-sdk/.config openwrt-sdk/.config.old 2>/dev/null || true
else
  group_start "Download SDK"
  rm -rf openwrt-sdk
  mkdir -p openwrt-sdk
  cd openwrt-sdk || die "Cannot enter openwrt-sdk directory"

  SDK_FILE=$(basename "$OPENWRT_SDK_URL")
  log_info "Downloading $SDK_FILE"
  retry 3 30 wget -q "$OPENWRT_SDK_URL" -O "$SDK_FILE"
  [ -f "$SDK_FILE" ] || die "Download failed"

  log_info "Extracting…"
  case "$SDK_FILE" in
    *.tar.zst) tar --use-compress-program=zstd -xf "$SDK_FILE" --strip-components=1 ;;
    *.tar.xz)  tar xf "$SDK_FILE" --strip-components=1 ;;
    *.tar.gz)  tar xzf "$SDK_FILE" --strip-components=1 ;;
    *)         die "Unsupported archive: $SDK_FILE" ;;
  esac
  rm -f "$SDK_FILE"
  cd ..
  group_end
fi

# ── 替换 SDK 内置 Go / Replace SDK bundled Go ──
group_start "Update SDK Go"
SYS_GO=$(command -v go 2>/dev/null || echo "/usr/local/go/bin/go")
if [ -x "$SYS_GO" ]; then
  SYS_VER=$("$SYS_GO" version | awk '{print $3}')
  GOROOT=$("$SYS_GO" env GOROOT)
  log_info "System Go: $SYS_VER ($GOROOT)"

  while IFS= read -r -d '' godir; do
    SDK_VER=$("$godir/bin/go" version 2>/dev/null | awk '{print $3}' || echo "unknown")
    if [ "$SDK_VER" != "$SYS_VER" ]; then
      log_info "Replacing $godir ($SDK_VER → $SYS_VER)"
      rm -rf "$godir" && cp -a "$GOROOT" "$godir"
    fi
  done < <(find openwrt-sdk/staging_dir -maxdepth 4 -type d \( -name "go-*" -o -name "go" \) -print0 2>/dev/null)
else
  log_warn "System Go not found, skipping SDK Go replacement"
fi
group_end

step_end
