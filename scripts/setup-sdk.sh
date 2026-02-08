#!/usr/bin/env bash
# Download (if needed) and prepare the OpenWrt SDK.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: "${OPENWRT_SDK_URL:?OPENWRT_SDK_URL not set}"
SDK_CACHE_HIT="${1:-false}"          # "true" when the cache step hit

# ── Verify / download SDK ───────────────────────────────────────────────────
if [ "$SDK_CACHE_HIT" = "true" ] && [ -d openwrt-sdk ] && [ -f openwrt-sdk/scripts/feeds ]; then
  log_info "Cached SDK verified"
else
  group_start "Downloading OpenWrt SDK"
  rm -rf openwrt-sdk; mkdir -p openwrt-sdk; cd openwrt-sdk

  SDK_FILE=$(basename "$OPENWRT_SDK_URL")
  log_info "Downloading: $SDK_FILE"
  retry 3 30 300 "Download SDK" "wget -q '$OPENWRT_SDK_URL' -O '$SDK_FILE'"

  [ -f "$SDK_FILE" ] || { log_error "SDK download failed"; exit 1; }
  log_info "SDK downloaded ($(du -h "$SDK_FILE" | cut -f1))"

  log_info "Extracting SDK…"
  case "$SDK_FILE" in
    *.tar.zst) tar --use-compress-program=zstd -xf "$SDK_FILE" --strip-components=1 ;;
    *.tar.xz)  tar xf "$SDK_FILE" --strip-components=1 ;;
    *) log_error "Unsupported archive format: $SDK_FILE"; exit 1 ;;
  esac
  rm -f "$SDK_FILE"
  log_info "SDK extracted"
  cd ..
  group_end
fi

# ── Replace SDK-bundled Go with system Go ───────────────────────────────────
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
