#!/usr/bin/env bash
# Configure OpenWrt feeds, patch known issues, set up PassWall sources,
# install feed packages, and generate the build .config.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd openwrt-sdk

FEEDS_CACHED="${1:-false}"

# ── Configure feeds ─────────────────────────────────────────────────────────
group_start "Configuring feeds"

if [ -f feeds.conf.default ]; then
  cp feeds.conf.default feeds.conf
else
  log_warning "feeds.conf.default not found, creating minimal config"
  cat > feeds.conf <<'EOF'
src-git packages https://github.com/openwrt/packages.git
src-git luci https://github.com/openwrt/luci.git
EOF
fi
log_info "feeds.conf:"; cat feeds.conf

# Validate cached feeds to ensure they're not corrupted
validate_feeds_cache() {
  [ -d feeds/packages ] || return 1
  [ -d feeds/luci ] || return 1
  [ -f feeds/packages.index ] || return 1
  [ -f feeds/luci.index ] || return 1
  # Check that feeds have actual content
  [ -d feeds/packages/lang ] || return 1
  [ -d feeds/luci/applications ] || return 1
  return 0
}

if [ "$FEEDS_CACHED" = "true" ] && validate_feeds_cache; then
  log_info "Cached feeds validated, running index update only"
  ./scripts/feeds update -i
else
  [ "$FEEDS_CACHED" = "true" ] && log_warning "Cached feeds validation failed, performing full update"
  log_info "Updating feeds…"
  if ! retry 3 30 120 "Update feeds" "./scripts/feeds update -a"; then
    log_warning "Feed update failed, falling back to GitHub mirrors…"
    sed -i \
      -e 's|https://git.openwrt.org/openwrt/openwrt.git|https://github.com/openwrt/openwrt.git|g' \
      -e 's|https://git.openwrt.org/feed/packages.git|https://github.com/openwrt/packages.git|g' \
      -e 's|https://git.openwrt.org/project/luci.git|https://github.com/openwrt/luci.git|g' \
      -e 's|https://git.openwrt.org/feed/routing.git|https://github.com/openwrt/routing.git|g' \
      -e 's|https://git.openwrt.org/feed/telephony.git|https://github.com/openwrt/telephony.git|g' \
      feeds.conf
    ./scripts/feeds update -a || { log_error "Failed to update feeds even with GitHub mirrors"; exit 1; }
  fi
fi
group_end

# ── Patch GOTOOLCHAIN (local → auto) ───────────────────────────────────────
group_start "Patching GOTOOLCHAIN"
if [ -d feeds/packages/lang/golang ]; then
  PATCHED=0
  while IFS= read -r f; do
    if grep -q 'GOTOOLCHAIN=local' "$f"; then
      sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' "$f"
      log_info "Patched GOTOOLCHAIN in $f"
      PATCHED=$((PATCHED + 1))
    fi
  done < <(find feeds/packages/lang/golang -type f \( -name "*.mk" -o -name "Makefile" \) 2>/dev/null)
  log_info "Patched GOTOOLCHAIN in $PATCHED file(s)"
else
  log_warning "feeds/packages/lang/golang not found, skipping"
fi
group_end

# ── Patch curl LDAP dependency (avoid Kconfig recursion) ────────────────────
group_start "Patching curl LDAP dependency"
CURL_MK="feeds/packages/net/curl/Makefile"
if [ -f "$CURL_MK" ] && grep -q "LIBCURL_LDAP:libopenldap" "$CURL_MK"; then
  sed -i 's/[[:space:]]*+LIBCURL_LDAP:libopenldap[[:space:]]*//g' "$CURL_MK"
  log_info "Removed LIBCURL_LDAP conditional dependency from libcurl"
else
  log_info "curl LDAP dependency already patched or not applicable"
fi
group_end

# ── Patch Rust llvm.download-ci-llvm (true → if-unchanged) ─────────────────
# Rust ≥1.90 bootstrap panics when download-ci-llvm is "true" and a CI
# environment is detected (GITHUB_ACTIONS).  Changing to "if-unchanged" is
# the recommended upstream fix (rust-lang/rust#141782).
group_start "Patching Rust download-ci-llvm"
RUST_MK="feeds/packages/lang/rust/Makefile"
if [ -f "$RUST_MK" ] && grep -q 'download-ci-llvm=true' "$RUST_MK"; then
  sed -i 's/download-ci-llvm=true/download-ci-llvm=if-unchanged/g' "$RUST_MK"
  log_info "Patched download-ci-llvm in $RUST_MK"
else
  log_info "Rust download-ci-llvm already patched or not applicable"
fi
group_end

# ── Clone PassWall sources ──────────────────────────────────────────────────
group_start "Setting up PassWall sources"

log_info "Removing conflicting feed packages…"
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}

rm -rf package/passwall-packages
retry 3 10 120 "Clone passwall-packages" \
  "git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages"

rm -rf feeds/luci/applications/luci-app-passwall package/passwall-luci
retry 3 10 120 "Clone passwall-luci" \
  "git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall package/passwall-luci"

if [ -n "${PASSWALL_LUCI_REF:-}" ]; then
  log_info "Checking out PASSWALL_LUCI_REF: $PASSWALL_LUCI_REF"
  git -C package/passwall-luci fetch --all --tags
  git -C package/passwall-luci checkout "$PASSWALL_LUCI_REF" \
    || { log_error "Failed to checkout ref: $PASSWALL_LUCI_REF"; exit 1; }
fi
group_end

# ── Install feed packages ──────────────────────────────────────────────────
group_start "Installing feed packages"

./scripts/feeds update -i

log_info "System Go: $(go version 2>/dev/null || echo 'Not found')"
log_info "System Rust: $(rustc --version 2>/dev/null || echo 'Not found')"

./scripts/feeds install \
  libev libmbedtls libsodium libopenssl libpcre2 libudns \
  boost boost-program_options boost-system \
  ca-bundle c-ares pcre2 zlib libubox libubus \
  rpcd rpcd-mod-file rpcd-mod-ucode ucode ucode-mod-fs ucode-mod-uci \
  ucode-mod-ubus ucode-mod-math libucode \
  coreutils coreutils-base64 coreutils-nohup curl dnsmasq-full ip-full \
  libuci-lua luci-compat luci-lib-jsonc resolveip luci-lua-runtime \
  iwinfo openssl libnl-tiny golang rust \
  || log_warning "Some dependencies may not be available, continuing…"

./scripts/feeds install luci-base || log_warning "luci-base installation had issues"
./scripts/feeds install luci-app-passwall \
  || { log_error "Failed to install luci-app-passwall"; exit 1; }
group_end

# ── Generate build .config ──────────────────────────────────────────────────
group_start "Configuring build"

rm -f .config .config.old tmp/.config-*.in 2>/dev/null || true

make defconfig < /dev/null

cat >> .config << 'PKGEOF'
CONFIG_PACKAGE_chinadns-ng=m
CONFIG_PACKAGE_dns2socks=m
CONFIG_PACKAGE_geoview=m
CONFIG_PACKAGE_hysteria=m
CONFIG_PACKAGE_ipt2socks=m
CONFIG_PACKAGE_microsocks=m
CONFIG_PACKAGE_naiveproxy=m
CONFIG_PACKAGE_shadow-tls=m
CONFIG_PACKAGE_shadowsocks-rust-sslocal=m
CONFIG_PACKAGE_shadowsocks-rust-ssserver=m
CONFIG_PACKAGE_shadowsocksr-libev-ssr-local=m
CONFIG_PACKAGE_shadowsocksr-libev-ssr-redir=m
CONFIG_PACKAGE_shadowsocksr-libev-ssr-server=m
CONFIG_PACKAGE_simple-obfs-client=m
CONFIG_PACKAGE_sing-box=m
CONFIG_PACKAGE_tcping=m
CONFIG_PACKAGE_trojan-plus=m
CONFIG_PACKAGE_tuic-client=m
CONFIG_PACKAGE_v2ray-geoip=m
CONFIG_PACKAGE_v2ray-geosite=m
CONFIG_PACKAGE_v2ray-plugin=m
CONFIG_PACKAGE_xray-core=m
CONFIG_PACKAGE_xray-plugin=m
PKGEOF

make defconfig < /dev/null
log_info "Build configured"
group_end

# ── Validate environment ───────────────────────────────────────────────────
group_start "Validating build environment"

ERRORS=0
for tool in go rustc cargo make gcc; do
  if command -v "$tool" >/dev/null 2>&1; then
    log_info "$tool: $("$tool" --version 2>&1 | head -1)"
  else
    log_error "Required tool not found: $tool"; ERRORS=$((ERRORS + 1))
  fi
done

MIN_DISK_GB=10
AVAIL_KB=$(df / --output=avail | tail -1 | tr -d ' ')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
if [ "$AVAIL_GB" -lt "$MIN_DISK_GB" ]; then
  log_error "Insufficient disk: ${AVAIL_GB}GB (need ${MIN_DISK_GB}GB)"; ERRORS=$((ERRORS + 1))
else
  log_info "Disk space: ${AVAIL_GB}GB"
fi

for item in scripts/feeds staging_dir Makefile package/passwall-packages package/passwall-luci; do
  [ -e "$item" ] || { log_error "Missing: $item"; ERRORS=$((ERRORS + 1)); }
done

[ "$ERRORS" -gt 0 ] && { log_error "Validation failed ($ERRORS errors)"; exit 1; }
log_info "Build environment validated"

# Report cache usage status for diagnostics
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Cache Status"
    if [ "$FEEDS_CACHED" = "true" ] && validate_feeds_cache; then
      echo "- **Feeds**: ✓ Using validated cache"
    else
      echo "- **Feeds**: ⚠ Cache not used or validation failed (fresh download)"
    fi
    echo "- **Config files**: Cleaned before defconfig to prevent stale state"
  } >> "$GITHUB_STEP_SUMMARY"
fi
group_end
