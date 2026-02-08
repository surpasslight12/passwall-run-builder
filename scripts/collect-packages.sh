#!/usr/bin/env bash
# Collect built APKs into the payload directory and validate the results.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd openwrt-sdk

PAYLOAD="$GITHUB_WORKSPACE/payload"
DEPENDS="$PAYLOAD/depends"
mkdir -p "$PAYLOAD" "$DEPENDS"

# ── Helper: pick the latest-version APK for a package prefix ────────────────
select_latest_pkg() {
  local prefix="$1" dest="$2"
  local best_file="" best_ver=""
  while IFS= read -r -d '' f; do
    local v; v=$(extract_version "$f" "$prefix")
    [ -z "$v" ] && continue
    if [ -z "$best_ver" ] || [ "$(printf '%s\n' "$best_ver" "$v" | sort -V | tail -n1)" = "$v" ]; then
      best_ver="$v"; best_file="$f"
    fi
  done < <(find bin/packages -type f \( -name "${prefix}-*.apk" -o -name "${prefix}_*.apk" \) -print0)
  [ -n "$best_file" ] || return 1
  cp "$best_file" "$dest/"
  log_info "Collected $prefix: $(basename "$best_file")"
}

# ── Collect main package ────────────────────────────────────────────────────
group_start "Collecting packages"

find bin/packages \( -name "luci-app-passwall-*.apk" -o -name "luci-app-passwall_*.apk" \) -exec cp {} "$PAYLOAD/" \;
select_latest_pkg "luci-i18n-passwall-zh-cn" "$PAYLOAD" \
  || log_info "Chinese i18n package not found (non-critical)"

# ── Collect dependencies ────────────────────────────────────────────────────
DEP_PREFIXES=(
  chinadns-ng dns2socks geoview hysteria ipt2socks microsocks naiveproxy
  shadow-tls
  shadowsocks-libev-ss-local shadowsocks-libev-ss-redir shadowsocks-libev-ss-server
  shadowsocks-rust-sslocal shadowsocks-rust-ssserver
  shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir shadowsocksr-libev-ssr-server
  simple-obfs-client sing-box tcping trojan-plus tuic-client
  v2ray-geoip v2ray-geosite v2ray-plugin xray-core xray-plugin
)

log_info "Collecting dependency packages…"
printf "%-35s %-15s\n" "Package" "Version"
printf "%-35s %-15s\n" "---" "---"

COLLECTED=0 MISSING=""
for p in "${DEP_PREFIXES[@]}"; do
  if select_latest_pkg "$p" "$DEPENDS"; then
    VER=$(extract_version \
      "$(find "$DEPENDS" -maxdepth 1 -type f \( -name "${p}_*.apk" -o -name "${p}-*.apk" \) -print -quit)" "$p")
    printf "%-35s %-15s\n" "$p" "$VER"
    COLLECTED=$((COLLECTED + 1))
  else
    printf "%-35s %-15s\n" "$p" "(none)"
    MISSING="$MISSING $p"
  fi
done

log_info "Collected $COLLECTED dependency packages"
[ -n "$MISSING" ] && log_warning "Missing:$MISSING"
group_end

# ── Validate ────────────────────────────────────────────────────────────────
group_start "Validating packages"

DEP_COUNT=$(find "$DEPENDS" -name "*.apk" | wc -l)
[ "$DEP_COUNT" -eq 0 ] && { log_error "No dependency APKs found"; exit 1; }
[ "$DEP_COUNT" -lt 10 ] && log_warning "Only $DEP_COUNT packages (expected ≥10)"
log_info "Found $DEP_COUNT dependency packages"

log_info "Main packages:"
find "$PAYLOAD" -maxdepth 1 -name "*.apk" | xargs -r -n1 basename | sort | sed 's/^/  - /'

log_info "Dependencies ($DEP_COUNT):"
ls -1 "$DEPENDS" | sort | sed 's/^/  - /'

[ -f "$PAYLOAD/install.sh" ]   || { log_error "install.sh missing from payload"; exit 1; }

if [ -z "$(find "$PAYLOAD" -maxdepth 1 -type f \( -name 'luci-app-passwall-*.apk' -o -name 'luci-app-passwall_*.apk' \) -print -quit 2>/dev/null)" ]; then
  log_error "luci-app-passwall package not found in payload"; exit 1
fi

log_info "Package validation passed"
group_end
