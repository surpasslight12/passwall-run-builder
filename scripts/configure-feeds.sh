#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# configure-feeds.sh — 配置 feeds、应用补丁、安装 PassWall 源码与依赖
# configure-feeds.sh — Configure feeds, apply patches, set up PassWall sources
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cd openwrt-sdk
FEEDS_CACHED="${1:-false}"

# ── 配置 feeds / Configure feeds ───────────────────────────────────────────
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

validate_feeds_cache() {
  local dirs=(feeds/packages feeds/luci feeds/packages/lang feeds/luci/applications)
  local files=(feeds/packages.index feeds/luci.index)
  for d in "${dirs[@]}";  do [ -d "$d" ] || return 1; done
  for f in "${files[@]}"; do [ -f "$f" ] || return 1; done
}

if [ "$FEEDS_CACHED" = "true" ] && validate_feeds_cache; then
  log_info "Cached feeds validated, running index update only"
  ./scripts/feeds update -i
else
  [ "$FEEDS_CACHED" = "true" ] && log_warning "Cached feeds validation failed, performing full update"
  if ! retry 3 30 120 "Update feeds" "./scripts/feeds update -a"; then
    log_warning "Feed update failed, falling back to GitHub mirrors…"
    sed -i \
      -e 's|https://git.openwrt.org/openwrt/openwrt.git|https://github.com/openwrt/openwrt.git|g' \
      -e 's|https://git.openwrt.org/feed/packages.git|https://github.com/openwrt/packages.git|g' \
      -e 's|https://git.openwrt.org/project/luci.git|https://github.com/openwrt/luci.git|g' \
      -e 's|https://git.openwrt.org/feed/routing.git|https://github.com/openwrt/routing.git|g' \
      -e 's|https://git.openwrt.org/feed/telephony.git|https://github.com/openwrt/telephony.git|g' \
      feeds.conf
    ./scripts/feeds update -a || die "Failed to update feeds even with GitHub mirrors"
  fi
fi
group_end

# ── 补丁 / Patches ─────────────────────────────────────────────────────────
# 1) GOTOOLCHAIN: local → auto
group_start "Patching GOTOOLCHAIN"
if [ -d feeds/packages/lang/golang ]; then
  PATCHED=0
  while IFS= read -r f; do
    if grep -q 'GOTOOLCHAIN=local' "$f"; then
      sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' "$f"
      PATCHED=$((PATCHED + 1))
    fi
  done < <(find feeds/packages/lang/golang -type f \( -name "*.mk" -o -name "Makefile" \) 2>/dev/null)
  log_info "Patched GOTOOLCHAIN in $PATCHED file(s)"
else
  log_warning "feeds/packages/lang/golang not found"
fi
group_end

# 2) curl LDAP 循环依赖 / curl LDAP dependency loop
group_start "Patching curl LDAP dependency"
CURL_MK="feeds/packages/net/curl/Makefile"
if [ -f "$CURL_MK" ] && grep -q "LIBCURL_LDAP:libopenldap" "$CURL_MK"; then
  sed -i 's/[[:space:]]*+LIBCURL_LDAP:libopenldap[[:space:]]*//g' "$CURL_MK"
  log_info "Removed LIBCURL_LDAP conditional dependency"
else
  log_info "curl LDAP patch not needed"
fi
group_end

# 3) Rust download-ci-llvm (rust-lang/rust#141782)
group_start "Patching Rust download-ci-llvm"
RUST_MK="feeds/packages/lang/rust/Makefile"
if [ -f "$RUST_MK" ] && grep -q 'download-ci-llvm=true' "$RUST_MK"; then
  sed -i 's/download-ci-llvm=true/download-ci-llvm=if-unchanged/g' "$RUST_MK"
  log_info "Patched download-ci-llvm in $RUST_MK"
else
  log_info "Rust download-ci-llvm patch not needed"
fi
group_end

# ── 克隆 PassWall 源码 / Clone PassWall sources ───────────────────────────
group_start "Setting up PassWall sources"

log_info "Removing conflicting feed packages…"
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,\
hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,\
shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,\
xray-plugin,geoview,shadow-tls}

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
    || die "Failed to checkout ref: $PASSWALL_LUCI_REF"
fi
group_end

# ── 安装 feeds 包 / Install feed packages ──────────────────────────────────
group_start "Installing feed packages"
./scripts/feeds update -i

log_info "Go:   $(go version 2>/dev/null || echo 'N/A')"
log_info "Rust: $(rustc --version 2>/dev/null || echo 'N/A')"

./scripts/feeds install \
  libev libmbedtls libsodium libopenssl libpcre2 libudns \
  boost boost-program_options boost-system \
  ca-bundle c-ares pcre2 zlib libubox libubus \
  rpcd rpcd-mod-file rpcd-mod-ucode ucode ucode-mod-fs ucode-mod-uci \
  ucode-mod-ubus ucode-mod-math libucode \
  coreutils coreutils-base64 coreutils-nohup curl dnsmasq-full ip-full \
  libuci-lua luci-compat luci-lib-jsonc resolveip luci-lua-runtime \
  iwinfo openssl libnl-tiny golang rust \
  || log_warning "Some feed dependencies may be unavailable, continuing…"

./scripts/feeds install luci-base || log_warning "luci-base installation had issues"
./scripts/feeds install luci-app-passwall \
  || die "Failed to install luci-app-passwall"
group_end

# ── 生成 .config / Generate build config ───────────────────────────────────
group_start "Generating build config"

rm -f .config .config.old 2>/dev/null || true
rm -rf tmp/.config-*.in 2>/dev/null || true
make defconfig < /dev/null

# 读取包列表配置 / Load package list from config
PACKAGES_CONF="$SCRIPT_DIR/../config/packages.conf"
if [ -f "$PACKAGES_CONF" ]; then
  log_info "Loading package config: $PACKAGES_CONF"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # 验证包名格式 / Validate package name format
    if [[ "$line" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      echo "CONFIG_PACKAGE_${line}=m" >> .config
    else
      log_warning "Skipping invalid package name: $line"
    fi
  done < "$PACKAGES_CONF"
else
  log_warning "packages.conf not found, using built-in defaults"
  cat >> .config << 'EOF'
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
EOF
fi

make defconfig < /dev/null
log_info "Build configured"
group_end

# ── 验证构建环境 / Validate build environment ──────────────────────────────
group_start "Validating build environment"

ERRORS=0
for tool in go rustc cargo make gcc; do
  if command -v "$tool" >/dev/null 2>&1; then
    log_info "$tool: $("$tool" --version 2>&1 | head -1)"
  else
    log_error "Missing tool: $tool"; ERRORS=$((ERRORS + 1))
  fi
done

check_disk_space 10 || ERRORS=$((ERRORS + 1))

for item in scripts/feeds staging_dir Makefile package/passwall-packages package/passwall-luci; do
  [ -e "$item" ] || { log_error "Missing: $item"; ERRORS=$((ERRORS + 1)); }
done

[ "$ERRORS" -gt 0 ] && die "Validation failed ($ERRORS errors)"
log_info "Build environment validated"
group_end
