#!/usr/bin/env bash
# configure-feeds.sh — 配置 feeds、打补丁、克隆 PassWall、生成 .config
# Configure feeds, apply patches, clone PassWall, generate .config
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib.sh"

step_start "Configure feeds"

cd openwrt-sdk || die "Cannot enter openwrt-sdk directory"
FEEDS_CACHED="${1:-false}"

# ── 配置 feeds / Configure feeds ──
group_start "Configure feeds"

if [ -f feeds.conf.default ]; then
  cp feeds.conf.default feeds.conf
else
  cat > feeds.conf <<'EOF'
src-git packages https://github.com/openwrt/packages.git
src-git luci https://github.com/openwrt/luci.git
EOF
fi

if [ "$FEEDS_CACHED" = "true" ] && [ -d feeds/packages ] && [ -d feeds/luci ]; then
  log_info "Using cached feeds (index update only)"
  ./scripts/feeds update -i
else
  log_info "Full feeds update"
  retry 3 30 ./scripts/feeds update -a || {
    log_warn "Feed update failed, trying GitHub mirrors"
    sed -i \
      -e 's|git.openwrt.org/openwrt/openwrt.git|github.com/openwrt/openwrt.git|g' \
      -e 's|git.openwrt.org/feed/packages.git|github.com/openwrt/packages.git|g' \
      -e 's|git.openwrt.org/project/luci.git|github.com/openwrt/luci.git|g' \
      -e 's|git.openwrt.org/feed/routing.git|github.com/openwrt/routing.git|g' \
      -e 's|git.openwrt.org/feed/telephony.git|github.com/openwrt/telephony.git|g' \
      feeds.conf
    retry 3 30 ./scripts/feeds update -a || die "Feeds update failed"
  }
fi
group_end

# ── 打补丁 / Apply patches ──
group_start "Apply patches"

# GOTOOLCHAIN: local → auto
if [ -d feeds/packages/lang/golang ]; then
  find feeds/packages/lang/golang -type f \( -name "*.mk" -o -name "Makefile" \) \
    -exec grep -l 'GOTOOLCHAIN=local' {} \; \
    -exec sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' {} \;
  log_info "Patched GOTOOLCHAIN"
fi

# curl LDAP 循环依赖 / curl LDAP dependency loop
CURL_MK="feeds/packages/net/curl/Makefile"
if [ -f "$CURL_MK" ] && grep -q "LIBCURL_LDAP:libopenldap" "$CURL_MK"; then
  sed -i 's/[[:space:]]*+LIBCURL_LDAP:libopenldap[[:space:]]*//g' "$CURL_MK"
  log_info "Patched curl LDAP"
fi

# Rust download-ci-llvm: 'if-unchanged' 和 'true' 在 SDK tarball 环境不兼容
RUST_MK="feeds/packages/lang/rust/Makefile"
if [ -f "$RUST_MK" ] && grep -qE 'download-ci-llvm=(true|if-unchanged)' "$RUST_MK"; then
  sed -i -E 's/download-ci-llvm=(true|if-unchanged)/download-ci-llvm=false/g' "$RUST_MK"
  log_info "Patched Rust download-ci-llvm"
fi
group_end

# ── 克隆 PassWall / Clone PassWall ──
group_start "Clone PassWall sources"

# 移除 feeds 中冲突的包
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,\
hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,\
shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,\
xray-plugin,geoview,shadow-tls}

rm -rf package/passwall-packages
retry 3 10 git clone --depth=1 \
  https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages

rm -rf feeds/luci/applications/luci-app-passwall package/passwall-luci
retry 3 10 git clone --depth=1 \
  https://github.com/Openwrt-Passwall/openwrt-passwall package/passwall-luci

if [ -n "${PASSWALL_LUCI_REF:-}" ]; then
  log_info "Checking out: $PASSWALL_LUCI_REF"
  git -C package/passwall-luci fetch --all --tags
  git -C package/passwall-luci checkout "$PASSWALL_LUCI_REF" \
    || die "Failed to checkout: $PASSWALL_LUCI_REF"
fi
group_end

# ── 安装 feeds 包 / Install feeds ──
group_start "Install feeds"
./scripts/feeds update -i

./scripts/feeds install \
  libev libmbedtls libsodium libopenssl libpcre2 libudns \
  boost boost-program_options boost-system \
  ca-bundle c-ares pcre2 zlib libubox libubus \
  rpcd rpcd-mod-file rpcd-mod-ucode ucode ucode-mod-fs ucode-mod-uci \
  ucode-mod-ubus ucode-mod-math libucode \
  coreutils coreutils-base64 coreutils-nohup curl dnsmasq-full ip-full \
  libuci-lua luci-compat luci-lib-jsonc resolveip luci-lua-runtime \
  iwinfo openssl libnl-tiny golang rust \
  || log_warn "Some feed packages unavailable"

./scripts/feeds install luci-base || log_warn "luci-base install had issues"
./scripts/feeds install luci-app-passwall || die "Failed to install luci-app-passwall"
group_end

# ── 生成 .config / Generate build config ──
group_start "Generate .config"
rm -f .config .config.old 2>/dev/null || true
make defconfig </dev/null

PKGCONF="$SCRIPT_DIR/../config/packages.conf"
if [ -f "$PKGCONF" ]; then
  while IFS= read -r pkg; do
    echo "CONFIG_PACKAGE_${pkg}=m" >> .config
  done < <(packages_conf_list "$PKGCONF")
else
  log_warn "packages.conf not found"
fi

make defconfig </dev/null
log_info "Config generated"
group_end

# ── 验证环境 / Validate ──
group_start "Validate build environment"
for tool in go rustc cargo make gcc; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing: $tool"
done
check_disk_space 10
for path in scripts/feeds staging_dir Makefile package/passwall-packages package/passwall-luci; do
  [ -e "$path" ] || die "Missing: $path"
done
log_info "Validation passed"
group_end

step_end
