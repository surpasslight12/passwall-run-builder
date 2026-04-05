#!/usr/bin/env bash
# build.sh — PassWall full build pipeline (CI & local)

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
source "$SCRIPT_DIR/lib.sh"

# ── Constants ─────────────────────────────────────────

UPSTREAM_OWNER="Openwrt-Passwall"
UPSTREAM_REPO="openwrt-passwall"
LUCI_REPO_DEFAULT="https://github.com/Openwrt-Passwall/openwrt-passwall"
PACKAGES_REPO_DEFAULT="https://github.com/Openwrt-Passwall/openwrt-passwall-packages"
OPENWRT_FEED_BASE="https://github.com/openwrt"

# ── CLI state ─────────────────────────────────────────

CONFIG_FILE="$REPO_ROOT/config/config.conf"
OUTPUT_DIR="$REPO_ROOT"
TAG_OVERRIDE=""
SDK_ROOT=""
SDK_ARCHIVE=""
LUCI_DIR=""
PACKAGES_DIR=""
LUCI_REPO=""
PACKAGES_REPO=""
KEEP_WORKDIR=0

# ── Runtime state ─────────────────────────────────────

WORKDIR=""
SDK=""
PAYLOAD=""
RAW_TAG=""
TAG=""
RUN_NAME=""

usage() {
  cat <<'USAGE'
Usage: build.sh [options]

Options:
  --config FILE               Config file (default: config/config.conf)
  --tag TAG                   Explicit PassWall tag
  --output-dir DIR            Output directory for .run artifact
  --sdk-root DIR              Existing OpenWrt SDK tree
  --sdk-archive PATH|URL      SDK archive override
  --passwall-luci-dir DIR     Existing passwall-luci checkout
  --passwall-packages-dir DIR Existing passwall-packages checkout
  --passwall-luci-repo URL    Override passwall luci repo URL
  --passwall-packages-repo URL Override passwall packages repo URL
  --keep-workdir              Keep temporary workspace
  --help                      Show help
USAGE
}

cleanup() {
  [ "$KEEP_WORKDIR" -eq 0 ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR" || :
}

# ══════════════════════════════════════════════════════
#  Phase 1: Setup
# ══════════════════════════════════════════════════════

phase_setup() {
  log_info "=== Setup ==="
  TMPDIR=$(resolve_tmpdir 10485760) || die "No temp directory with at least 10GB free space available"
  export TMPDIR
  export TMP="$TMPDIR" TEMP="$TMPDIR"
  WORKDIR=$(mktemp -d "$TMPDIR/passwall-build.XXXXXX")
  SDK="$WORKDIR/sdk"
  PAYLOAD="$WORKDIR/payload"
  mkdir -p "$OUTPUT_DIR" "$PAYLOAD" "$SDK"
  trap cleanup EXIT

  LUCI_REPO="${LUCI_REPO:-$LUCI_REPO_DEFAULT}"
  PACKAGES_REPO="${PACKAGES_REPO:-$PACKAGES_REPO_DEFAULT}"
}

# ══════════════════════════════════════════════════════
#  Phase 2: Config & Tag
# ══════════════════════════════════════════════════════

phase_config() {
  log_info "=== Load config ==="
  load_config "$CONFIG_FILE"
  [[ "${OPENWRT_SDK_URL:-}" =~ ^https:// ]] || die "OPENWRT_SDK_URL must use https"

  log_info "=== Resolve tag ==="
  if [ -n "$TAG_OVERRIDE" ]; then
    RAW_TAG="$TAG_OVERRIDE"
  elif [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    RAW_TAG="$GITHUB_REF_NAME"
  else
    RAW_TAG=$(resolve_latest_release_tag "$UPSTREAM_OWNER" "$UPSTREAM_REPO")
    [ -n "$RAW_TAG" ] || die "Failed to resolve upstream tag"
  fi
  TAG=$(trim_tag "$RAW_TAG")
  gh_set_env "PASSWALL_VERSION_TAG" "$TAG"
  gh_set_env "PASSWALL_VERSION_TAG_RAW" "$RAW_TAG"
  gh_summary "- PassWall tag: \`$RAW_TAG\`"
  log_info "Tag: $RAW_TAG → $TAG"
}

# ══════════════════════════════════════════════════════
#  Phase 3: Validate
# ══════════════════════════════════════════════════════

phase_validate() {
  log_info "=== Validate ==="
  local t
  for t in bash sh curl make git makeself file sha256sum; do require_tool "$t"; done
  bash -n "$SCRIPT_DIR/lib.sh"
  bash -n "$SCRIPT_DIR/build.sh"
  sh -n "$REPO_ROOT/payload/install.sh"

  if [ -n "$SDK_ROOT" ]; then
    [ -d "$SDK_ROOT" ] || die "SDK root not found: $SDK_ROOT"
  else
    require_tool tar
    [ -n "$SDK_ARCHIVE" ] && [ -f "$SDK_ARCHIVE" ] || require_tool wget
  fi
  [ -z "$LUCI_DIR" ] || [ -d "$LUCI_DIR" ] || die "Luci dir missing: $LUCI_DIR"
  [ -z "$PACKAGES_DIR" ] || [ -d "$PACKAGES_DIR" ] || die "Packages dir missing: $PACKAGES_DIR"
}

# ══════════════════════════════════════════════════════
#  Phase 4: Prepare SDK
# ══════════════════════════════════════════════════════

phase_sdk() {
  log_info "=== Prepare SDK ==="
  if [ -n "$SDK_ROOT" ]; then
    cp -a "$SDK_ROOT/." "$SDK/"
  else
    local src="${SDK_ARCHIVE:-$OPENWRT_SDK_URL}"
    local archive="$WORKDIR/$(basename "$src")"
    if [ -f "$src" ]; then cp "$src" "$archive"
    else retry 3 20 wget -q "$src" -O "$archive"; fi
    case "$archive" in
      *.tar.zst) tar --use-compress-program=zstd -xf "$archive" -C "$SDK" --strip-components=1 ;;
      *.tar.xz)  tar -xf "$archive" -C "$SDK" --strip-components=1 ;;
      *.tar.gz)  tar -xzf "$archive" -C "$SDK" --strip-components=1 ;;
      *) die "Unsupported archive: $archive" ;;
    esac
  fi
  [ -f "$SDK/Makefile" ] || die "SDK Makefile missing"
  mkdir -p "$SDK/dl" "$SDK/tmp/go-build"
}

# ══════════════════════════════════════════════════════
#  Phase 5: Configure Feeds
# ══════════════════════════════════════════════════════

phase_feeds() {
  log_info "=== Configure feeds ==="
  [ -x "$SDK/scripts/feeds" ] || die "SDK feeds helper missing"

  (
    cd "$SDK"

    # Initialize feeds.conf
    if [ -f feeds.conf.default ]; then
      cp feeds.conf.default feeds.conf
    else
      printf 'src-git packages %s/packages.git\nsrc-git luci %s/luci.git\n' \
        "$OPENWRT_FEED_BASE" "$OPENWRT_FEED_BASE" > feeds.conf
    fi

    # Redirect git.openwrt.org → GitHub
    sed -i \
      -e "s|https://git.openwrt.org/openwrt/openwrt.git|${OPENWRT_FEED_BASE}/openwrt.git|g" \
      -e "s|https://git.openwrt.org/feed/packages.git|${OPENWRT_FEED_BASE}/packages.git|g" \
      -e "s|https://git.openwrt.org/project/luci.git|${OPENWRT_FEED_BASE}/luci.git|g" \
      -e "s|https://git.openwrt.org/feed/routing.git|${OPENWRT_FEED_BASE}/routing.git|g" \
      -e "s|https://git.openwrt.org/feed/telephony.git|${OPENWRT_FEED_BASE}/telephony.git|g" \
      feeds.conf

    retry 3 30 ./scripts/feeds update -a || die "Feeds update failed"

    # Patch: GOTOOLCHAIN
    find feeds/packages/lang/golang -type f \( -name "*.mk" -o -name "Makefile" \) \
      -exec grep -l 'GOTOOLCHAIN=local' {} \; \
      -exec sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' {} \; 2>/dev/null || true

    # Patch: curl LDAP dependency
    [ -f feeds/packages/net/curl/Makefile ] \
      && sed -i 's/[[:space:]]*+LIBCURL_LDAP:libopenldap[[:space:]]*//g' feeds/packages/net/curl/Makefile 2>/dev/null || true

    # Patch: Rust download-ci-llvm
    [ -f feeds/packages/lang/rust/Makefile ] \
      && sed -i -E 's/download-ci-llvm=(true|if-unchanged)/download-ci-llvm=false/g' feeds/packages/lang/rust/Makefile 2>/dev/null || true

    # Patch: Go host bootstrap
    patch_go_host_bootstrap

    # Install feed packages
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
    ./scripts/feeds install luci-base || log_warn "luci-base had issues"
  )
}

patch_go_host_bootstrap() {
  local compiler_mk="feeds/packages/lang/golang/golang-compiler.mk"
  [ -d "feeds/packages/lang/golang/golang1.26" ] || return 0
  [ -f "$compiler_mk" ] || return 0

  sed -i 's/$(error go-/$(warning go-/g' "$compiler_mk" 2>/dev/null || true

  local gl_ver="feeds/packages/lang/golang/golang-version.mk"
  if [ -f "$gl_ver" ] && ! grep -qF 'TITLE:=Go programming language' "$gl_ver"; then
    local gv_tmp
    gv_tmp=$(mktemp "${TMPDIR:-/tmp}/gv-patched.XXXXXX")
    awk '/^define Package\/\$\(PKG_NAME\)\/Default/ { print; print "  TITLE:=Go programming language"; next } { print }' \
      "$gl_ver" > "$gv_tmp" && mv "$gv_tmp" "$gl_ver"
  fi

  local sys_go; sys_go=$(command -v go 2>/dev/null || true)
  [ -n "$sys_go" ] || return 0
  local sys_ver; sys_ver=$("$sys_go" version 2>/dev/null | awk '{print $3}')
  case "$sys_ver" in
    go1.26*)
      local goroot; goroot=$("$sys_go" env GOROOT 2>/dev/null || true)
      [ -n "$goroot" ] && [ -d "$goroot" ] || return 0
      if [ ! -f "staging_dir/host/lib/go-1.26/bin/go" ]; then
        log_info "Pre-installing Go 1.26 from system"
        mkdir -p staging_dir/host/lib/go-1.26
        cp -a "$goroot/." staging_dir/host/lib/go-1.26/
        rm -rf staging_dir/host/lib/go-1.26/pkg/linux_amd64 2>/dev/null || true
        if [ -f feeds/packages/lang/golang/go-gcc-helper ]; then
          mkdir -p staging_dir/host/lib/go-1.26/openwrt
          install -m 755 feeds/packages/lang/golang/go-gcc-helper staging_dir/host/lib/go-1.26/openwrt/
          ln -sf go-gcc-helper staging_dir/host/lib/go-1.26/openwrt/gcc 2>/dev/null || true
          ln -sf go-gcc-helper staging_dir/host/lib/go-1.26/openwrt/g++ 2>/dev/null || true
        fi
        mkdir -p staging_dir/host/bin
        ln -sf ../lib/go-1.26/bin/go staging_dir/host/bin/go1.26 2>/dev/null || true
        ln -sf ../lib/go-1.26/bin/gofmt staging_dir/host/bin/gofmt1.26 2>/dev/null || true
      fi
      mkdir -p build_dir/hostpkg/go-1.26.0 staging_dir/host/stamp
      touch build_dir/hostpkg/go-1.26.0/{.configured,.built,.installed,.stamp_configured,.stamp_built,.stamp_installed}
      touch staging_dir/host/stamp/.golang1.26_installed
      ;;
  esac
}

# ══════════════════════════════════════════════════════
#  Phase 6: Prefetch Rust Sources
# ══════════════════════════════════════════════════════

phase_prefetch_rust() {
  local mk="$SDK/feeds/packages/lang/rust/Makefile"
  [ -f "$mk" ] || return 0
  log_info "=== Prefetch Rust ==="

  local ver src hash src_url
  ver=$(sed -n 's/^PKG_VERSION:=//p' "$mk" | head -1)
  src=$(sed -n 's/^PKG_SOURCE:=//p' "$mk" | head -1)
  hash=$(sed -n 's/^PKG_HASH:=//p' "$mk" | head -1)
  src_url=$(sed -n 's/^PKG_SOURCE_URL:=//p' "$mk" | head -1)
  src="${src//\$(PKG_VERSION)/$ver}"; src_url="${src_url//\$(PKG_VERSION)/$ver}"
  [ -n "$src" ] && [ -n "$hash" ] || return 0

  local cdn="${OPENWRT_SOURCE_CDN_URL:-https://sources.cdn.openwrt.org}"
  local mirror="${OPENWRT_SOURCE_MIRROR_URL:-https://sources.openwrt.org}"
  local -a urls=("${cdn%/}/$src" "${mirror%/}/$src")
  [ -n "$src_url" ] && urls=("${src_url%/}/$src" "${urls[@]}")
  download_verified "$SDK/dl" "$src" "$hash" "${urls[@]}"
}

# ══════════════════════════════════════════════════════
#  Phase 7: Prepare PassWall Sources
# ══════════════════════════════════════════════════════

phase_sources() {
  log_info "=== Prepare PassWall sources ==="
  (
    cd "$SDK"
    mkdir -p package
    rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
    rm -rf package/passwall-packages package/passwall-luci
  )

  # Packages
  if [ -n "$PACKAGES_DIR" ]; then
    cp -a "$PACKAGES_DIR/." "$SDK/package/passwall-packages/"
  else
    local tag
    tag=$(resolve_remote_tag "$PACKAGES_REPO" "$RAW_TAG" "$TAG" "v$TAG" || true)
    if [ -n "$tag" ]; then
      retry 3 10 git clone --branch "$tag" --depth=1 "$PACKAGES_REPO" "$SDK/package/passwall-packages"
    else
      local branch; branch=$(resolve_remote_default_branch "$PACKAGES_REPO")
      [ -n "$branch" ] || die "Cannot resolve packages repo branch"
      log_warn "No matching packages tag; using branch $branch"
      retry 3 10 git clone --branch "$branch" --depth=1 "$PACKAGES_REPO" "$SDK/package/passwall-packages"
    fi
    gh_summary "- Packages commit: \`$(git -C "$SDK/package/passwall-packages" rev-parse --short HEAD)\`"
  fi

  # Luci
  if [ -n "$LUCI_DIR" ]; then
    cp -a "$LUCI_DIR/." "$SDK/package/passwall-luci/"
  else
    local tag
    tag=$(resolve_remote_tag "$LUCI_REPO" "$RAW_TAG" "$TAG" "v$TAG") \
      || die "Cannot resolve passwall-luci tag"
    retry 3 10 git clone --branch "$tag" --depth=1 "$LUCI_REPO" "$SDK/package/passwall-luci"
    gh_summary "- Luci tag: \`$tag\`"
  fi

  [ -f "$SDK/package/passwall-luci/luci-app-passwall/Makefile" ] || die "PassWall luci Makefile missing"
}

# ══════════════════════════════════════════════════════
#  Phase 8: Generate Config
# ══════════════════════════════════════════════════════

phase_config_gen() {
  log_info "=== Generate build config ==="
  local roots="$SDK/.compile-roots"
  local unselected="$SDK/.unselected-pkgs"

  tr ',' '\n' <<< "${PASSWALL_REQUIRED_PACKAGES:-}" | sed '/^$/d' | LC_ALL=C sort -u > "$SDK/.required"
  tr ',' '\n' <<< "${PASSWALL_OPTIONAL_SELECTED_PACKAGES:-}" | sed '/^$/d' | LC_ALL=C sort -u > "$SDK/.selected"
  tr ',' '\n' <<< "${PASSWALL_OPTIONAL_UNSELECTED_PACKAGES:-}" | sed '/^$/d' | LC_ALL=C sort -u > "$unselected"
  cat "$SDK/.required" "$SDK/.selected" | sed '/^$/d' | LC_ALL=C sort -u > "$roots"

  [ -s "$roots" ] || die "No compile root packages"

  # Validate: selected ∩ unselected = ∅
  local overlap
  overlap=$(comm -12 "$roots" "$unselected" | head -1 || true)
  [ -z "$overlap" ] || die "Package in both selected and unselected: $overlap"

  (
    cd "$SDK"
    rm -f .config .config.old
    {
      printf 'CONFIG_PACKAGE_luci-app-passwall=m\nCONFIG_PACKAGE_luci-i18n-passwall-zh-cn=m\n'
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf 'CONFIG_PACKAGE_%s=m\n' "$pkg" || :
      done < "$roots"
      while IFS= read -r pkg; do
        [ -n "$pkg" ] && printf '# CONFIG_PACKAGE_%s is not set\n' "$pkg" || :
      done < "$unselected"
    } > .config
    make defconfig </dev/null
  )
  log_info "Compile roots: $(wc -l < "$roots") ($(wc -l < "$SDK/.required") required + $(wc -l < "$SDK/.selected") optional)"
}

# ══════════════════════════════════════════════════════
#  Phase 9: Compile
# ══════════════════════════════════════════════════════

phase_compile() {
  log_info "=== Compile ==="
  local roots="$SDK/.compile-roots"
  local timings="$WORKDIR/timings.txt"
  local src_list="$WORKDIR/sources.txt"
  local results="$WORKDIR/compile-results.txt"
  : > "$timings"

  # Ensure Rust target if needed
  if grep -Eq '^(shadow-tls|shadowsocks-rust-)' "$roots"; then
    local gcc triple
    gcc=$(find "$SDK/staging_dir" -type f -path '*/toolchain-*/bin/*-gcc' 2>/dev/null | LC_ALL=C sort | head -1 || true)
    [ -n "$gcc" ] || die "Toolchain gcc not found"
    triple=$("$gcc" -dumpmachine | sed 's/openwrt/unknown/')
    rustup target list --installed | grep -qx "$triple" || rustup target add "$triple"
  fi

  # Resolve source directories
  (
    cd "$SDK"
    declare -A src_dirs=()
    local pkg dir mk
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      dir=$(map_passwall_src_dir "$pkg" || true)
      if [ -z "$dir" ]; then
        case "$pkg" in kmod-*) [ -d package/kernel/linux ] && dir="package/kernel/linux" ;; esac
      fi
      if [ -z "$dir" ]; then
        # Prefer package/feeds/ symlinks (valid make targets) over raw feeds/ paths
        local feed_link
        for feed_link in package/feeds/*/"$pkg"; do
          [ -d "$feed_link" ] && { dir="$feed_link"; break; }
        done
      fi
      if [ -z "$dir" ]; then
        mk=$(grep -RslF --include='Makefile' "define Package/${pkg}" package 2>/dev/null | LC_ALL=C sort | head -1 || true)
        [ -z "$mk" ] && mk=$(grep -RslF --include='Makefile' "PKG_NAME:=${pkg}" package 2>/dev/null | LC_ALL=C sort | head -1 || true)
        [ -z "$mk" ] && mk=$(grep -RslF --include='Makefile' "define Package/${pkg}" feeds 2>/dev/null | LC_ALL=C sort | head -1 || true)
        [ -z "$mk" ] && mk=$(grep -RslF --include='Makefile' "PKG_NAME:=${pkg}" feeds 2>/dev/null | LC_ALL=C sort | head -1 || true)
        [ -n "$mk" ] && dir="$(dirname "$mk")" || die "Cannot find source for: $pkg"
      fi
      src_dirs["$dir"]=1
    done < "$roots"
      src_dirs["package/passwall-luci/luci-app-passwall"]=1

      # Build kernel packaging first so feed packages that consume kmods
      # (notably dnsmasq-full/nftables in this config) see staged kernel APKs.
      if [ -n "${src_dirs["package/kernel/linux"]+x}" ]; then
        printf '%s\n' "package/kernel/linux"
      fi
      printf '%s\n' "${!src_dirs[@]}" | LC_ALL=C sort | awk '$0 != "package/kernel/linux"'
    ) > "$src_list"

  # Compile all sources
  (
    cd "$SDK"
    export FORCE_UNSAFE_CONFIGURE=1 CARGO_INCREMENTAL=0 CARGO_NET_GIT_FETCH_WITH_CLI=true
    export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
    unset CI GITHUB_ACTIONS 2>/dev/null || true

    local avail_gb=$(( $(df / --output=avail | tail -1 | tr -d ' ') / 1024 / 1024 ))
    [ "$avail_gb" -ge 10 ] || die "Low disk: ${avail_gb}GB"

    local ok=0 fail=0 failed="" dir label t0
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      label=$(basename "$dir"); t0=$(date +%s)
      if make_pkg "$dir/compile" "$label"; then
        ok=$((ok + 1))
        printf '%s|ok|%ss\n' "$label" "$(( $(date +%s) - t0 ))" >> "$timings"
      else
        fail=$((fail + 1))
        failed="$failed $label"
        printf '%s|fail|%ss\n' "$label" "$(( $(date +%s) - t0 ))" >> "$timings"
      fi
    done < "$src_list"
    printf '%s\n%s\n%s\n' "$ok" "$fail" "$failed" > "$results"
  )

  local ok fail failed
  ok=$(sed -n '1p' "$results"); fail=$(sed -n '2p' "$results"); failed=$(sed -n '3p' "$results")
  [ "$ok" -gt 0 ] || die "No packages built"
  [ "$fail" -eq 0 ] || die "Build failed for:$failed"

  # Emit summary
  local summary="## Build Summary"$'\n'"- Built: $ok"$'\n'"- Failed: $fail"$'\n'
  if [ -s "$timings" ]; then
    summary+="### Durations"$'\n'"| Package | Status | Time |"$'\n'"| --- | --- | --- |"$'\n'
    while IFS='|' read -r p s t; do
      [ -n "$p" ] && summary+="| $p | $s | $t |"$'\n' || :
    done < "$timings"
  fi
  gh_summary "$summary"
  log_info "Compiled $ok package source(s)"
}

# ══════════════════════════════════════════════════════
#  Phase 10: Collect Payload
# ══════════════════════════════════════════════════════

phase_payload() {
  log_info "=== Collect payload ==="
  local local_repo="$SDK/bin/packages"
  local local_targets="$SDK/bin/targets"
  local local_search="$SDK/bin"
  local roots="$SDK/.compile-roots"
  local apk_tool="$SDK/staging_dir/host/bin/apk"
  local arch
  arch=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"/\1/p' "$SDK/.config" | head -1)

  # Reset payload
  rm -rf "$PAYLOAD/$PAYLOAD_APK_DIR" "$PAYLOAD/$PAYLOAD_META_DIR"
  mkdir -p "$PAYLOAD/$PAYLOAD_APK_DIR" "$PAYLOAD/$PAYLOAD_META_DIR"
  cp "$REPO_ROOT/payload/install.sh" "$PAYLOAD/install.sh"

  [ -d "$local_repo" ] || die "Local package output missing: $local_repo"
  [ -x "$apk_tool" ] || die "Host apk tool missing: $apk_tool"
  [ -n "$arch" ] || die "Cannot derive ARCH_PACKAGES from .config"

  (
    cd "$SDK"
    declare -A toplevel=() missing=() official_fallback=() selected_apks=() selected_src=() whitelist=()
    local -a specs=()

    # ── Stage 1: Build local APK index ──
    local mkndx_log="${TMPDIR:-/tmp}/pkg-index-$$.log"
    find "$local_repo" -type f -name 'packages.adb' -delete 2>/dev/null || true
    make package/index V=s >"$mkndx_log" 2>&1 || { tail -60 "$mkndx_log"; die "Local APK index failed"; }
    rm -f "$mkndx_log"

    local local_index_list="$SDK/.local-repos"
    {
      find "$local_repo" -type f -name 'packages.adb'
      [ -d "$local_targets" ] && find "$local_targets" -type f -path '*/packages/packages.adb'
    } | LC_ALL=C sort -u > "$local_index_list"
    [ -s "$local_index_list" ] || die "No local packages.adb found"

    # ── Stage 2: Build requested root specs ──
    toplevel["luci-app-passwall"]=1
    local luci_spec
    luci_spec=$(local_pkg_spec "$local_search" "luci-app-passwall" || true)
    [ -n "$luci_spec" ] || die "luci-app-passwall APK not found"
    specs+=("$luci_spec" "dnsmasq-full")

    local zh_spec
    zh_spec=$(local_pkg_spec "$local_search" "luci-i18n-passwall-zh-cn" || true)
    if [ -n "$zh_spec" ]; then
      toplevel["luci-i18n-passwall-zh-cn"]=1
      specs+=("$zh_spec")
    fi

    local pkg pkg_spec root_count=0
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      root_count=$((root_count + 1))
      toplevel["$pkg"]=1
      pkg_spec=$(local_pkg_spec "$local_search" "$pkg" || true)
      if [ -n "$pkg_spec" ]; then
        specs+=("$pkg_spec")
      else
        specs+=("$pkg")
        if map_passwall_src_dir "$pkg" >/dev/null 2>&1; then
          missing["$pkg"]=1
        else
          official_fallback["$pkg"]=1
        fi
      fi
    done < "$roots"

    local specs_file="$WORKDIR/specs.txt"
    printf '%s\n' "${specs[@]}" | sed '/^$/d' | LC_ALL=C sort -u > "$specs_file"
    mapfile -t specs < "$specs_file"

    # ── Stage 3: Resolve dependencies via combined repos ──
    local combined_repo="$SDK/.combined-repos"
    local dist_root="${OPENWRT_SDK_URL%%/targets/*}"
    local target_path
    target_path=$(printf '%s' "$OPENWRT_SDK_URL" | sed -n 's#.*/targets/\([^/]*/[^/]*\)/.*#\1#p')
    [ -n "$dist_root" ] && [ -n "$target_path" ] || die "Cannot derive dist root from SDK URL"

    # Build combined repository list
    sed 's|^|file://|' "$local_index_list" > "$combined_repo"
    local kmods_dir
    kmods_dir=$(curl -fsSL "${dist_root}/targets/${target_path}/kmods/" 2>/dev/null \
      | grep -oE 'href="[^"]+/"' | sed 's/^href="//;s#/"$##' | grep -E '^[^/]+$' | head -1 || true)
    cat >> "$combined_repo" <<EOF
$dist_root/targets/$target_path/packages/packages.adb
$dist_root/packages/$arch/base/packages.adb
$dist_root/packages/$arch/packages/packages.adb
$dist_root/packages/$arch/luci/packages.adb
$dist_root/packages/$arch/routing/packages.adb
$dist_root/packages/$arch/telephony/packages.adb
EOF
    [ -n "$kmods_dir" ] && printf '%s/targets/%s/kmods/%s/packages.adb\n' "$dist_root" "$target_path" "$kmods_dir" >> "$combined_repo"

    # Fetch resolved packages
    local fetch_dir="$SDK/.resolved-apks"
    rm -rf "$fetch_dir"; mkdir -p "$fetch_dir"
    "$apk_tool" --allow-untrusted --force-refresh --no-interactive --no-cache \
      --arch "$arch" --repositories-file "$combined_repo" \
      fetch --recursive --output "$fetch_dir" "${specs[@]}" \
      || die "Dependency resolution failed"

    # ── Stage 4: Canonicalize (local-prefer) ──
    local canonical="$SDK/.canonical-apks"
    rm -rf "$canonical"; mkdir -p "$canonical"
    declare -A fetched_set=()
    local f pkg_name local_f

    while IFS= read -r -d '' f; do
      pkg_name=$(apk_pkg_name "$f" || true); [ -n "$pkg_name" ] || continue
      fetched_set["$pkg_name"]=1
      # Register fetched APK
      local cur="${selected_apks[$pkg_name]:-}"
      if [ -z "$cur" ]; then
        cp -f "$f" "$canonical/$(basename "$f")"
        selected_apks["$pkg_name"]="$canonical/$(basename "$f")"
        selected_src["$pkg_name"]="fetched"
      else
        local preferred; preferred=$(pick_newer_apk "$cur" "$f")
        if [ "$preferred" = "$f" ]; then
          rm -f "$cur"
          cp -f "$f" "$canonical/$(basename "$f")"
          selected_apks["$pkg_name"]="$canonical/$(basename "$f")"
        fi
      fi
    done < <(find "$fetch_dir" -maxdepth 1 -type f -name '*.apk' -print0)

    # Override with local builds where available
    while IFS= read -r pkg_name; do
      [ -n "$pkg_name" ] || continue
      local_f=$(find_payload_apk "$local_search" "$pkg_name" || true)
      [ -n "$local_f" ] || continue
      local cur="${selected_apks[$pkg_name]:-}"
      if [ -n "$cur" ] && [ "${selected_src[$pkg_name]:-}" != "local" ]; then
        rm -f "$cur"
      fi
      cp -f "$local_f" "$canonical/$(basename "$local_f")"
      selected_apks["$pkg_name"]="$canonical/$(basename "$local_f")"
      selected_src["$pkg_name"]="local"
    done < <(printf '%s\n' "${!fetched_set[@]}" | LC_ALL=C sort)

    # ── Stage 5: Build whitelist ──
    local wl_file="$PAYLOAD/$PAYLOAD_WHITELIST"
    while IFS= read -r pkg; do
      [ -n "$pkg" ] && whitelist["$pkg"]=1
    done < "$roots"
    whitelist["luci-app-passwall"]=1
    [ -n "${zh_spec:-}" ] && whitelist["luci-i18n-passwall-zh-cn"]=1

    while IFS= read -r -d '' f; do
      pkg_name=$(apk_pkg_name "$f" || true); [ -n "$pkg_name" ] || continue
      map_passwall_src_dir "$pkg_name" >/dev/null 2>&1 && whitelist["$pkg_name"]=1
    done < <(find "$canonical" -maxdepth 1 -type f -name '*.apk' -print0)

    find_payload_apk "$canonical" "dnsmasq-full" >/dev/null 2>&1 && whitelist["dnsmasq-full"]=1
    printf '%s\n' "${!whitelist[@]}" | LC_ALL=C sort > "$wl_file"
    [ -s "$wl_file" ] || die "Install whitelist is empty"

    # ── Stage 6: Verify and materialize ──
    for pkg in "${!toplevel[@]}"; do
      [ "$pkg" = "luci-i18n-passwall-zh-cn" ] && continue
      find_payload_apk "$canonical" "$pkg" >/dev/null 2>&1 \
        || die "Top-level package missing after resolution: $pkg"
    done

    while IFS= read -r -d '' f; do
      cp "$f" "$PAYLOAD/$PAYLOAD_APK_DIR/"
    done < <(find "$canonical" -maxdepth 1 -type f -name '*.apk' -print0)

    # ── Stage 7: Generate manifests and indexes ──
    write_apk_manifest "$PAYLOAD"

    local -a payload_apks
    mapfile -t payload_apks < <(find "$PAYLOAD/$PAYLOAD_APK_DIR" -maxdepth 1 -type f -name '*.apk' | LC_ALL=C sort)
    [ "${#payload_apks[@]}" -gt 0 ] || die "Payload APK set is empty"
    "$apk_tool" --allow-untrusted mkndx --output "$PAYLOAD/$PAYLOAD_REPO_INDEX" "${payload_apks[@]}" \
      >/dev/null || die "Failed to build payload index"

    # ── Summary ──
    local total_apks dep_count=0
    total_apks=$(find "$PAYLOAD/$PAYLOAD_APK_DIR" -maxdepth 1 -name '*.apk' | wc -l)
    while IFS= read -r -d '' f; do
      pkg_name=$(apk_pkg_name "$f" || true); [ -n "$pkg_name" ] || continue
      [ -n "${toplevel[$pkg_name]+x}" ] && continue
      dep_count=$((dep_count + 1))
    done < <(find "$PAYLOAD/$PAYLOAD_APK_DIR" -maxdepth 1 -type f -name '*.apk' -print0)

    local wl_count; wl_count=$(wc -l < "$wl_file" | tr -d ' ')
    gh_summary "$(printf '## Payload\n- Roots: %s\n- Total APKs: %s\n- Dependencies: %s\n- Whitelist: %s\n- Missing local: %s\n- Official fallback: %s\n' \
      "$root_count" "$total_apks" "$dep_count" "$wl_count" "${#missing[@]}" "${#official_fallback[@]}")"

    [ "$dep_count" -gt 0 ] || die "No dependency APKs found"
    [ "${#missing[@]}" -eq 0 ] || die "Missing local PassWall APKs: ${!missing[*]}"
  )

  # Final validation
  find "$PAYLOAD/$PAYLOAD_APK_DIR" -maxdepth 1 -type f \
    \( -name 'luci-app-passwall-*.apk' -o -name 'luci-app-passwall_*.apk' \) \
    -print -quit | grep -q . \
    || die "Payload missing luci-app-passwall APK"
  generate_sha256sums "$PAYLOAD"
  [ -s "$PAYLOAD/SHA256SUMS" ] || die "Checksum manifest missing"
}

# ══════════════════════════════════════════════════════
#  Phase 11: Smoke Test
# ══════════════════════════════════════════════════════

phase_smoke() {
  log_info "=== Smoke test ==="
  local mockbin="$WORKDIR/mockbin"
  local install_log="$WORKDIR/install.log"
  local apk_inv="$WORKDIR/apk-invocations.log"
  local smoke_dir="$WORKDIR/payload-smoke"
  local smoke_apk="$smoke_dir/$PAYLOAD_APK_DIR"
  local smoke_meta="$smoke_dir/$PAYLOAD_META_DIR"
  local smoke_wl="$smoke_dir/$PAYLOAD_WHITELIST"

  rm -rf "$smoke_dir"
  mkdir -p "$smoke_apk" "$smoke_meta"
  cp "$REPO_ROOT/payload/install.sh" "$smoke_dir/install.sh"
  cp "$PAYLOAD/$PAYLOAD_WHITELIST" "$smoke_wl"
  printf 'synthetic-root-index\n' > "$smoke_dir/$PAYLOAD_REPO_INDEX"

  # Create synthetic APKs from whitelist
  local pkg has_dnsmasq=0
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    if [ "$pkg" = "dnsmasq-full" ]; then
      has_dnsmasq=1
      printf 'synthetic-dnsmasq-full\n' > "$smoke_apk/dnsmasq-full-1.0-r1.apk"
    else
      printf 'synthetic-%s\n' "$pkg" > "$smoke_apk/${pkg}-${TAG}-r1.apk"
    fi
  done < "$smoke_wl"
  printf 'synthetic-dep\n' > "$smoke_apk/example-dependency-1.0-r1.apk"

  write_apk_manifest "$smoke_dir"
  generate_sha256sums "$smoke_dir"

  local smoke_ok="ok"
  run_mock_installer "$smoke_dir" "$install_log" "$apk_inv" "$mockbin" || smoke_ok="exit-$?"

  if [ "$smoke_ok" = "ok" ]; then
    grep -q "Install mode: auto" "$install_log"     || smoke_ok="mode mismatch"
    grep -q "installed successfully" "$install_log"  || smoke_ok="no success marker"
    grep -q "Using explicit payload APKs" "$install_log" || smoke_ok="no explicit mode"
  fi

  if [ "$smoke_ok" = "ok" ] && [ "$has_dnsmasq" -eq 1 ]; then
    grep -q "Removing conflicting packages: dnsmasq dnsmasq-dhcpv6" "$install_log" || smoke_ok="no dnsmasq removal"
  fi

  if [ "$smoke_ok" != "ok" ]; then
    log_error "Smoke test failed: $smoke_ok"
    group_start "install.log"; cat "$install_log" 2>/dev/null || true; group_end
    group_start "apk invocations"; cat "$apk_inv" 2>/dev/null || true; group_end
    die "Smoke test failed: $smoke_ok"
  fi
}

# ══════════════════════════════════════════════════════
#  Phase 12: Build Installer
# ══════════════════════════════════════════════════════

phase_installer() {
  log_info "=== Build installer ==="
  local build_dir="$WORKDIR/build-installer"
  local arch sdk_ver
  arch=$(printf '%s' "$OPENWRT_SDK_URL" | sed -n 's#.*/targets/\([^/]*/[^/]*\)/.*#\1#p' | tr '/' '_')
  sdk_ver=$(printf '%s' "$OPENWRT_SDK_URL" | sed -n 's#.*/openwrt-sdk-\([0-9.]*\(-rc[0-9]*\)\?\)-.*#\1#p')
  RUN_NAME="passwall_${TAG}_${arch:-unknown}_sdk_${sdk_ver:-unknown}.run"

  mkdir -p "$build_dir/payload"
  cp -r "$PAYLOAD"/. "$build_dir/payload/"
  chmod +x "$build_dir/payload/install.sh"

  (
    cd "$build_dir"
    makeself --nox11 --sha256 payload "$OUTPUT_DIR/$RUN_NAME" \
      "passwall_${TAG}_sdk_${sdk_ver:-unknown}" ./install.sh >/dev/null
  ) || die "makeself failed"

  sh "$OUTPUT_DIR/$RUN_NAME" --check >/dev/null || die ".run integrity check failed"
  gh_set_env "RUN_NAME" "$RUN_NAME"
  gh_output "run_name" "$RUN_NAME"
  gh_summary "- Installer: \`$RUN_NAME\`"
  log_info "Installer: $OUTPUT_DIR/$RUN_NAME"
}

# ══════════════════════════════════════════════════════
#  Phase 13: Summary
# ══════════════════════════════════════════════════════

phase_summary() {
  cat <<EOF
Full build completed successfully.
  Tag: $RAW_TAG → $TAG
  SDK: $OPENWRT_SDK_URL
  Output: $OUTPUT_DIR/$RUN_NAME
  Workdir: $WORKDIR
EOF
}

# ══════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)               CONFIG_FILE="${2:?--config requires a value}"; shift 2 ;;
      --tag)                  TAG_OVERRIDE="${2:?--tag requires a value}"; shift 2 ;;
      --output-dir)           OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
      --sdk-root)             SDK_ROOT="${2:?--sdk-root requires a value}"; shift 2 ;;
      --sdk-archive)          SDK_ARCHIVE="${2:?--sdk-archive requires a value}"; shift 2 ;;
      --passwall-luci-dir)    LUCI_DIR="${2:?--passwall-luci-dir requires a value}"; shift 2 ;;
      --passwall-packages-dir) PACKAGES_DIR="${2:?--passwall-packages-dir requires a value}"; shift 2 ;;
      --passwall-luci-repo)   LUCI_REPO="${2:?--passwall-luci-repo requires a value}"; shift 2 ;;
      --passwall-packages-repo) PACKAGES_REPO="${2:?--passwall-packages-repo requires a value}"; shift 2 ;;
      --keep-workdir)         KEEP_WORKDIR=1; shift ;;
      --help|-h)              usage; exit 0 ;;
      *)                      die "Unknown argument: $1" ;;
    esac
  done

  phase_setup
  cd "$REPO_ROOT"
  phase_config
  phase_validate
  phase_sdk
  phase_feeds
  phase_prefetch_rust
  phase_sources
  phase_config_gen
  phase_compile
  phase_payload
  phase_smoke
  phase_installer
  phase_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
