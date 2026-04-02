#!/usr/bin/env bash
#
# full-build.sh — shared full build pipeline for GitHub Actions and local builds

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
source "$SCRIPT_DIR/build-lib.sh"

CONFIG_FILE="$REPO_ROOT/config/config.conf"
OUTPUT_DIR="$REPO_ROOT"
PAYLOAD_DIR=""
TAG_OVERRIDE=""
SDK_ROOT=""
SDK_ARCHIVE_OVERRIDE=""
PASSWALL_LUCI_DIR=""
PASSWALL_PACKAGES_DIR=""
PASSWALL_LUCI_REPO=""
PASSWALL_PACKAGES_REPO=""
KEEP_WORKDIR=0
WORKDIR=""
SUMMARY_FILE=""
RAW_TAG=""
PASSWALL_VERSION_TAG=""
FULL_SDK_DIR=""
RUN_OUTPUT=""
RUN_NAME=""
METADATA_FILE=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --repo-root DIR             Repository root (default: script parent directory)
  --config FILE               Config file to load (default: config/config.conf)
  --tag TAG                   Use an explicit PassWall tag
  --output-dir DIR            Directory where the generated .run artifact will be written
  --payload-dir DIR           Directory used to assemble payload APKs before packaging
  --sdk-root DIR              Path to an existing OpenWrt SDK tree; if omitted, download from OPENWRT_SDK_URL
  --sdk-archive PATH|URL      Override the SDK archive source when --sdk-root is not provided
  --passwall-luci-dir DIR     Path to an existing openwrt-passwall checkout
  --passwall-packages-dir DIR Path to an existing openwrt-passwall-packages checkout
  --passwall-luci-repo URL    Override the openwrt-passwall clone source
  --passwall-packages-repo URL
                              Override the openwrt-passwall-packages clone source
  --metadata-file FILE        Write build metadata as KEY=VALUE pairs
  --keep-workdir              Keep temporary workspace for inspection
  --help                      Show this help
USAGE
}

cleanup() {
  if [ "$KEEP_WORKDIR" -eq 0 ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}

copy_tree() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  cp -a "$src/." "$dest/"
}

clone_git_ref() {
  local repo="$1" ref="$2" dest="$3"
  if [ -d "$repo" ]; then
    retry 3 10 git clone --branch "$ref" "$repo" "$dest"
  else
    retry 3 10 git clone --branch "$ref" --depth=1 "$repo" "$dest"
  fi
}

sdk_arch_slug() {
  local arch
  arch=$(printf '%s' "$OPENWRT_SDK_URL" | sed -n 's#.*/targets/\([^/]*/[^/]*\)/.*#\1#p')
  [ -n "$arch" ] || arch="unknown"
  printf '%s\n' "$arch" | tr '/' '_'
}

sdk_version_from_url() {
  local version
  version=$(printf '%s' "$OPENWRT_SDK_URL" | sed -n 's#.*/openwrt-sdk-\([0-9.]*\(-rc[0-9]*\)\?\)-.*#\1#p')
  [ -n "$version" ] || version="unknown"
  printf '%s\n' "$version"
}

prepare_workspace() {
  local cache_root="${XDG_CACHE_HOME:-${HOME:-$REPO_ROOT}/.cache}/passwall-run"
  WORKDIR=$(make_managed_tempdir "passwall-full-build" \
    "${PASSWALL_TMPDIR:-}" \
    "${TMPDIR:-}" \
    /var/tmp \
    "$cache_root" \
    "$REPO_ROOT/.tmp")
  FULL_SDK_DIR="$WORKDIR/openwrt-sdk"
  SUMMARY_FILE="$WORKDIR/summary.txt"
  trap cleanup EXIT

  mkdir -p "$OUTPUT_DIR"
  if [ -z "$PAYLOAD_DIR" ]; then
    PAYLOAD_DIR="$WORKDIR/payload"
  fi
  mkdir -p "$PAYLOAD_DIR"
}

load_config() {
  step_start "Load build config"
  load_env_config "$CONFIG_FILE"
  config_default "PASSWALL_UPSTREAM_OWNER" "Openwrt-Passwall"
  config_default "PASSWALL_UPSTREAM_REPO" "openwrt-passwall"
  config_default "PASSWALL_LUCI_REPO" "https://github.com/Openwrt-Passwall/openwrt-passwall"
  config_default "PASSWALL_PACKAGES_REPO" "https://github.com/Openwrt-Passwall/openwrt-passwall-packages"
  config_default "OPENWRT_BASE_FEED_REPO" "https://github.com/openwrt/openwrt.git"
  config_default "OPENWRT_PACKAGES_FEED_REPO" "https://github.com/openwrt/packages.git"
  config_default "OPENWRT_LUCI_FEED_REPO" "https://github.com/openwrt/luci.git"
  config_default "OPENWRT_ROUTING_FEED_REPO" "https://github.com/openwrt/routing.git"
  config_default "OPENWRT_TELEPHONY_FEED_REPO" "https://github.com/openwrt/telephony.git"
  config_default "OPENWRT_SOURCE_CDN_URL" "https://sources.cdn.openwrt.org"
  config_default "OPENWRT_SOURCE_MIRROR_URL" "https://sources.openwrt.org"
  config_default "GOPROXY" "https://proxy.golang.org,https://goproxy.io,direct"
  [[ "${OPENWRT_SDK_URL:-}" =~ ^https:// ]] || die "OPENWRT_SDK_URL must use https"
  log_info "Using SDK URL: $OPENWRT_SDK_URL"
  step_end
}

resolve_tag() {
  step_start "Resolve PassWall tag"
  if [ -n "$TAG_OVERRIDE" ]; then
    RAW_TAG="$TAG_OVERRIDE"
    log_info "Using explicit tag $RAW_TAG"
  elif [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    RAW_TAG="$GITHUB_REF_NAME"
    log_info "Using workflow tag $RAW_TAG"
  else
    RAW_TAG=$(resolve_latest_github_release_tag "$PASSWALL_UPSTREAM_OWNER" "$PASSWALL_UPSTREAM_REPO")
    [ -n "$RAW_TAG" ] || die "Failed to resolve latest upstream stable tag"
    log_info "Resolved latest upstream stable tag $RAW_TAG"
  fi

  PASSWALL_VERSION_TAG=$(trim_tag "$RAW_TAG")
  gh_set_env "PASSWALL_VERSION_TAG" "$PASSWALL_VERSION_TAG"
  gh_set_env "PASSWALL_VERSION_TAG_RAW" "$RAW_TAG"
  gh_summary "- Upstream PassWall tag: \`$RAW_TAG\`"
  log_info "Normalized tag: $PASSWALL_VERSION_TAG"
  step_end
}

validate_inputs() {
  step_start "Validate build inputs"
  require_tool bash
  require_tool sh
  require_tool python3
  require_tool curl
  require_tool make
  require_tool git
  require_tool makeself
  require_tool file
  require_tool sha256sum
  bash -n "$SCRIPT_DIR/build-lib.sh"
  bash -n "$SCRIPT_DIR/full-build.sh"
  sh -n "$REPO_ROOT/payload/install.sh"

  if [ -n "$SDK_ROOT" ]; then
    [ -d "$SDK_ROOT" ] || die "SDK root not found: $SDK_ROOT"
  else
    require_tool tar
    if [ -z "$SDK_ARCHIVE_OVERRIDE" ] || [ ! -f "$SDK_ARCHIVE_OVERRIDE" ]; then
      require_tool wget
    fi
  fi

  if [ -n "$PASSWALL_LUCI_DIR" ]; then
    [ -d "$PASSWALL_LUCI_DIR" ] || die "PassWall luci dir not found: $PASSWALL_LUCI_DIR"
  fi
  if [ -n "$PASSWALL_PACKAGES_DIR" ]; then
    [ -d "$PASSWALL_PACKAGES_DIR" ] || die "PassWall packages dir not found: $PASSWALL_PACKAGES_DIR"
  fi

  step_end
}

prepare_sdk_workspace() {
  step_start "Prepare SDK workspace"
  local sdk_source sdk_file
  mkdir -p "$FULL_SDK_DIR"

  if [ -n "$SDK_ROOT" ]; then
    log_info "Copying local SDK tree from $SDK_ROOT"
    copy_tree "$SDK_ROOT" "$FULL_SDK_DIR"
  else
    sdk_source="${SDK_ARCHIVE_OVERRIDE:-$OPENWRT_SDK_URL}"
    sdk_file="$WORKDIR/$(basename "$sdk_source")"
    if [ -f "$sdk_source" ]; then
      log_info "Using local SDK archive $sdk_source"
      cp "$sdk_source" "$sdk_file"
    else
      log_info "Downloading SDK archive $(basename "$sdk_file")"
      retry 3 20 wget -q "$sdk_source" -O "$sdk_file"
    fi
    case "$sdk_file" in
      *.tar.zst) tar --use-compress-program=zstd -xf "$sdk_file" -C "$FULL_SDK_DIR" --strip-components=1 ;;
      *.tar.xz) tar -xf "$sdk_file" -C "$FULL_SDK_DIR" --strip-components=1 ;;
      *.tar.gz) tar -xzf "$sdk_file" -C "$FULL_SDK_DIR" --strip-components=1 ;;
      *) die "Unsupported SDK archive: $sdk_file" ;;
    esac
  fi

  [ -f "$FULL_SDK_DIR/Makefile" ] || die "SDK Makefile not found under $FULL_SDK_DIR"
  mkdir -p "$FULL_SDK_DIR/dl" "$FULL_SDK_DIR/tmp/go-build"
  step_end
}

prepare_full_sources() {
  step_start "Prepare PassWall sources"
  local luci_tag packages_tag packages_branch packages_ref_kind packages_commit

  mkdir -p "$FULL_SDK_DIR/package"
  rm -rf "$FULL_SDK_DIR/feeds/packages/net/"{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
  rm -rf "$FULL_SDK_DIR/package/passwall-packages" "$FULL_SDK_DIR/package/passwall-luci"

  if [ -n "$PASSWALL_PACKAGES_DIR" ]; then
    log_info "Copying local passwall-packages tree from $PASSWALL_PACKAGES_DIR"
    copy_tree "$PASSWALL_PACKAGES_DIR" "$FULL_SDK_DIR/package/passwall-packages"
  else
    packages_tag=$(resolve_remote_tag "$PASSWALL_PACKAGES_REPO" "$RAW_TAG" "$PASSWALL_VERSION_TAG" "v$PASSWALL_VERSION_TAG" || true)
    if [ -n "$packages_tag" ]; then
      clone_git_ref "$PASSWALL_PACKAGES_REPO" "$packages_tag" "$FULL_SDK_DIR/package/passwall-packages"
      packages_ref_kind="tag"
    else
      packages_branch=$(resolve_remote_default_branch "$PASSWALL_PACKAGES_REPO")
      [ -n "$packages_branch" ] || die "Cannot resolve default branch for packages repo: $PASSWALL_PACKAGES_REPO"
      log_warn "No matching packages tag found; falling back to default branch $packages_branch"
      clone_git_ref "$PASSWALL_PACKAGES_REPO" "$packages_branch" "$FULL_SDK_DIR/package/passwall-packages"
      packages_tag="$packages_branch"
      packages_ref_kind="branch"
    fi
    packages_commit=$(git -C "$FULL_SDK_DIR/package/passwall-packages" rev-parse --short HEAD)
    log_info "Prepared passwall-packages from ${packages_ref_kind}: ${packages_tag} (${packages_commit})"
    gh_summary "- PassWall packages source ${packages_ref_kind}: \`${packages_tag}\`"
    gh_summary "- PassWall packages source commit: \`${packages_commit}\`"
  fi

  if [ -n "$PASSWALL_LUCI_DIR" ]; then
    log_info "Copying local passwall-luci tree from $PASSWALL_LUCI_DIR"
    copy_tree "$PASSWALL_LUCI_DIR" "$FULL_SDK_DIR/package/passwall-luci"
  else
    luci_tag=$(resolve_remote_tag "$PASSWALL_LUCI_REPO" "$RAW_TAG" "$PASSWALL_VERSION_TAG" "v$PASSWALL_VERSION_TAG") \
      || die "Cannot resolve passwall-luci tag for full build"
    clone_git_ref "$PASSWALL_LUCI_REPO" "$luci_tag" "$FULL_SDK_DIR/package/passwall-luci"
    gh_summary "- PassWall luci source tag: \`${luci_tag}\`"
  fi

  [ -f "$FULL_SDK_DIR/package/passwall-luci/luci-app-passwall/Makefile" ] || die "PassWall luci Makefile missing"
  step_end
}

configure_local_feeds() {
  step_start "Configure feeds"
  [ -x "$FULL_SDK_DIR/scripts/feeds" ] || die "SDK feeds helper not found: $FULL_SDK_DIR/scripts/feeds"

  (
    cd "$FULL_SDK_DIR"

    if [ -f feeds.conf.default ]; then
      cp feeds.conf.default feeds.conf
    else
      cat > feeds.conf <<EOF
src-git packages ${OPENWRT_PACKAGES_FEED_REPO}
src-git luci ${OPENWRT_LUCI_FEED_REPO}
EOF
    fi

    base_feed_repo=$(sed_escape_replacement "$OPENWRT_BASE_FEED_REPO")
    packages_feed_repo=$(sed_escape_replacement "$OPENWRT_PACKAGES_FEED_REPO")
    luci_feed_repo=$(sed_escape_replacement "$OPENWRT_LUCI_FEED_REPO")
    routing_feed_repo=$(sed_escape_replacement "$OPENWRT_ROUTING_FEED_REPO")
    telephony_feed_repo=$(sed_escape_replacement "$OPENWRT_TELEPHONY_FEED_REPO")
    sed -i \
      -e "s|https://git.openwrt.org/openwrt/openwrt.git|${base_feed_repo}|g" \
      -e "s|https://git.openwrt.org/feed/packages.git|${packages_feed_repo}|g" \
      -e "s|https://git.openwrt.org/project/luci.git|${luci_feed_repo}|g" \
      -e "s|https://git.openwrt.org/feed/routing.git|${routing_feed_repo}|g" \
      -e "s|https://git.openwrt.org/feed/telephony.git|${telephony_feed_repo}|g" \
      feeds.conf

    retry 3 30 ./scripts/feeds update -a || die "Feeds update failed"

    if [ -d feeds/packages/lang/golang ]; then
      find feeds/packages/lang/golang -type f \( -name "*.mk" -o -name "Makefile" \) \
        -exec grep -l 'GOTOOLCHAIN=local' {} \; \
        -exec sed -i 's/GOTOOLCHAIN=local/GOTOOLCHAIN=auto/g' {} \;
      log_info "Patched GOTOOLCHAIN"
    fi

    CURL_MK="feeds/packages/net/curl/Makefile"
    if [ -f "$CURL_MK" ] && grep -q "LIBCURL_LDAP:libopenldap" "$CURL_MK"; then
      sed -i 's/[[:space:]]*+LIBCURL_LDAP:libopenldap[[:space:]]*//g' "$CURL_MK"
      log_info "Patched curl LDAP"
    fi

    RUST_MK="feeds/packages/lang/rust/Makefile"
    if [ -f "$RUST_MK" ] && grep -qE 'download-ci-llvm=(true|if-unchanged)' "$RUST_MK"; then
      sed -i -E 's/download-ci-llvm=(true|if-unchanged)/download-ci-llvm=false/g' "$RUST_MK"
      log_info "Patched Rust download-ci-llvm"
    fi

    COMPILER_MK="feeds/packages/lang/golang/golang-compiler.mk"
    if [ -d "feeds/packages/lang/golang/golang1.26" ] && [ -f "$COMPILER_MK" ]; then
      if grep -q '$(error go-' "$COMPILER_MK"; then
        sed -i 's/$(error go-/$(warning go-/g' "$COMPILER_MK"
        log_info "Patched golang-compiler.mk: CheckHost error -> warning"
      fi
      GL_VERSION="feeds/packages/lang/golang/golang-version.mk"
      if [ -f "$GL_VERSION" ] && ! grep -qF 'TITLE:=Go programming language' "$GL_VERSION"; then
        awk '/^define Package\/\$\(PKG_NAME\)\/Default/ { print; print "  TITLE:=Go programming language"; next } { print }' \
          "$GL_VERSION" > /tmp/gv-patched.mk && mv /tmp/gv-patched.mk "$GL_VERSION"
        log_info "Patched golang-version.mk: added TITLE to Package/Default"
      fi
      SYS_GO_BIN=$(command -v go 2>/dev/null || true)
      if [ -n "$SYS_GO_BIN" ]; then
        SYS_GO_VER=$("$SYS_GO_BIN" version 2>/dev/null | awk '{print $3}')
        case "$SYS_GO_VER" in
          go1.26*)
            SYS_GOROOT=$("$SYS_GO_BIN" env GOROOT 2>/dev/null || true)
            HOST_LIB="staging_dir/host/lib/go-1.26"
            GO126_BUILD="build_dir/hostpkg/go-1.26.0"
            if [ -n "$SYS_GOROOT" ] && [ -d "$SYS_GOROOT" ]; then
              if [ ! -f "$HOST_LIB/bin/go" ]; then
                log_info "Pre-installing golang1.26 from system $SYS_GO_VER"
                mkdir -p "$HOST_LIB"
                cp -a "$SYS_GOROOT/." "$HOST_LIB/"
                rm -rf "$HOST_LIB/pkg/linux_amd64" 2>/dev/null || true
                GCC_HELPER="feeds/packages/lang/golang/go-gcc-helper"
                if [ -f "$GCC_HELPER" ]; then
                  mkdir -p "$HOST_LIB/openwrt"
                  install -m 755 "$GCC_HELPER" "$HOST_LIB/openwrt/"
                  [ -L "$HOST_LIB/openwrt/gcc" ] || ln -sf "go-gcc-helper" "$HOST_LIB/openwrt/gcc"
                  [ -L "$HOST_LIB/openwrt/g++" ] || ln -sf "go-gcc-helper" "$HOST_LIB/openwrt/g++"
                fi
                mkdir -p "staging_dir/host/bin"
                [ -L "staging_dir/host/bin/go1.26" ] || ln -sf "../lib/go-1.26/bin/go" "staging_dir/host/bin/go1.26"
                [ -L "staging_dir/host/bin/gofmt1.26" ] || ln -sf "../lib/go-1.26/bin/gofmt" "staging_dir/host/bin/gofmt1.26"
              fi
              mkdir -p "$GO126_BUILD" "staging_dir/host/stamp"
              for s in .configured .built .installed .stamp_configured .stamp_built .stamp_installed; do
                touch "$GO126_BUILD/$s"
              done
              touch "staging_dir/host/stamp/.golang1.26_installed"
            fi
            ;;
        esac
      fi
    fi

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
  )

  step_end
}

prefetch_rust_sources() {
  local rust_mk rust_version rust_source rust_hash rust_source_url
  rust_mk="$FULL_SDK_DIR/feeds/packages/lang/rust/Makefile"
  [ -f "$rust_mk" ] || return 0

  rust_version=$(sed -n 's/^PKG_VERSION:=//p' "$rust_mk" | head -n 1)
  rust_source=$(sed -n 's/^PKG_SOURCE:=//p' "$rust_mk" | head -n 1)
  rust_hash=$(sed -n 's/^PKG_HASH:=//p' "$rust_mk" | head -n 1)
  rust_source_url=$(sed -n 's/^PKG_SOURCE_URL:=//p' "$rust_mk" | head -n 1)
  rust_source=${rust_source//\$\(PKG_VERSION\)/$rust_version}
  rust_source_url=${rust_source_url//\$\(PKG_VERSION\)/$rust_version}

  [ -n "$rust_source" ] || return 0
  [ -n "$rust_hash" ] || die "Rust source hash missing in $rust_mk"

  step_start "Prefetch Rust sources"
  local -a rust_urls=(
    "${OPENWRT_SOURCE_CDN_URL%/}/$rust_source"
    "${OPENWRT_SOURCE_MIRROR_URL%/}/$rust_source"
  )
  if [ -n "$rust_source_url" ]; then
    rust_urls=("${rust_source_url%/}/$rust_source" "${rust_urls[@]}")
  fi
  download_verified_file "$FULL_SDK_DIR/dl" "$rust_source" "$rust_hash" "${rust_urls[@]}"
  step_end
}

generate_full_config() {
  step_start "Generate build config"
  local passwall_roots
  passwall_roots="$FULL_SDK_DIR/.passwall-package-roots"

  (
    cd "$FULL_SDK_DIR"
    rm -f .config .config.old 2>/dev/null || true
    cat >> .config <<'CFG'
CONFIG_PACKAGE_luci-app-passwall=m
CONFIG_PACKAGE_luci-i18n-passwall-zh-cn=m
CFG
    make defconfig </dev/null
    python3 - <<'PY'
import re
from pathlib import Path

root = Path.cwd()
makefile = root / "package/passwall-luci/luci-app-passwall/Makefile"
config = (root / ".config").read_text()
enabled = set(re.findall(r'^(CONFIG_PACKAGE_luci-app-passwall_[A-Za-z0-9_]+)=[ym]$', config, re.M))

roots = []
current = None
for raw_line in makefile.read_text().splitlines():
    line = raw_line.strip()
    match = re.match(r'^config PACKAGE_\$\(PKG_NAME\)_([A-Za-z0-9_]+)$', line)
    if match:
        current = f"CONFIG_PACKAGE_luci-app-passwall_{match.group(1)}"
        continue
    match = re.match(r'^select PACKAGE_([A-Za-z0-9_\-]+)$', line)
    if match and current in enabled:
        roots.append(match.group(1))

(root / ".passwall-package-roots").write_text("\n".join(sorted(dict.fromkeys(roots))) + "\n")
PY
  )

  [ -s "$passwall_roots" ] || die "Generated PassWall root package list is empty"
  log_info "Generated $(wc -l < "$passwall_roots") PassWall root packages"
  step_end
}

ensure_rust_target() {
  local roots_file="$1"
  grep -Eq '^(shadow-tls|shadowsocks-rust-)' "$roots_file" || return 0
  log_info "Ensuring Rust target is installed"
  (
    cd "$FULL_SDK_DIR"
    GCC_BIN=$(find staging_dir -type f -path '*/toolchain-*/bin/*-gcc' 2>/dev/null | LC_ALL=C sort | head -n 1 || true)
    [ -n "$GCC_BIN" ] || die "Cannot locate OpenWrt toolchain gcc"
    GCC_TRIPLE=$("$GCC_BIN" -dumpmachine 2>/dev/null || true)
    [ -n "$GCC_TRIPLE" ] || die "Cannot determine OpenWrt toolchain target triple"
    RUST_TARGET=$(printf '%s' "$GCC_TRIPLE" | sed 's/openwrt/unknown/')
    [ -n "$RUST_TARGET" ] || die "Cannot derive Rust target from $GCC_TRIPLE"
    if rustup target list --installed | grep -qx "$RUST_TARGET"; then
      log_info "Rust target already installed: $RUST_TARGET"
    else
      log_info "Installing Rust target: $RUST_TARGET"
      rustup target add "$RUST_TARGET" || die "Failed to install Rust target: $RUST_TARGET"
    fi
  )
}

resolve_remote_kmods_repo() {
  local dist_root="$1" target_path="$2" listing_url listing_html kmods_dir
  listing_url="${dist_root%/}/targets/${target_path}/kmods/"
  listing_html=$(curl -fsSL "$listing_url") || return 1
  kmods_dir=$(printf '%s' "$listing_html" \
    | grep -oE 'href="[^"]+/"' \
    | sed 's/^href="//; s#/"$##' \
    | grep -E '^[^/]+$' \
    | head -n 1)
  [ -n "$kmods_dir" ] || return 1
  printf '%s/targets/%s/kmods/%s/packages.adb\n' "${dist_root%/}" "$target_path" "$kmods_dir"
}

compile_full_sources() {
  step_start "Compile package sources"
  local passwall_roots_file total_ok total_fail failed_list timings_file
  passwall_roots_file="$FULL_SDK_DIR/.passwall-package-roots"
  total_ok=0
  total_fail=0
  failed_list=""
  timings_file="$WORKDIR/pkg-timings.txt"
  : > "$timings_file"

  ensure_rust_target "$passwall_roots_file"

  (
    cd "$FULL_SDK_DIR"
    export FORCE_UNSAFE_CONFIGURE=1
    export CARGO_INCREMENTAL=0
    export CARGO_NET_GIT_FETCH_WITH_CLI=true
    export GOPROXY
    unset CI GITHUB_ACTIONS || true

    declare -A local_source_pkgs=()
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      src_dir=$(map_passwall_source_dir "$pkg" || true)
      [ -n "$src_dir" ] || continue
      local_source_pkgs["$src_dir"]+=" $pkg"
    done < "$passwall_roots_file"
    local_source_pkgs["package/passwall-luci/luci-app-passwall"]+=" luci-app-passwall luci-i18n-passwall-zh-cn"

    check_disk_space 10
    while IFS= read -r src_dir; do
      [ -n "$src_dir" ] || continue
      label=$(basename "$src_dir")
      pkg_t0=$(date +%s)
      if make_pkg "$src_dir/compile" "$label"; then
        total_ok=$((total_ok + 1))
        printf '%s|ok|%ss\n' "$label" "$(( $(date +%s) - pkg_t0 ))" >> "$timings_file"
      else
        total_fail=$((total_fail + 1))
        failed_list="$failed_list $label"
        printf '%s|failed|%ss\n' "$label" "$(( $(date +%s) - pkg_t0 ))" >> "$timings_file"
      fi
    done < <(printf '%s\n' "${!local_source_pkgs[@]}" | LC_ALL=C sort)

    printf '%s\n%s\n%s\n' "$total_ok" "$total_fail" "$failed_list" > "$WORKDIR/full-build-results"
  )

  total_ok=$(sed -n '1p' "$WORKDIR/full-build-results")
  total_fail=$(sed -n '2p' "$WORKDIR/full-build-results")
  failed_list=$(sed -n '3p' "$WORKDIR/full-build-results")
  [ "$total_ok" -gt 0 ] || die "No package source built in full mode"
  [ "$total_fail" -eq 0 ] || die "Full mode build failed for:${failed_list}"

  {
    summary="## Build Summary"$'\n'
    summary+="- **Built package sources**: $total_ok"$'\n'
    summary+="- **Failed package sources**: $total_fail"$'\n'
    if [ -s "$timings_file" ]; then
      summary+="### Build Durations"$'\n'
      summary+="| Package Source | Status | Time |"$'\n'
      summary+="| --- | --- | --- |"$'\n'
      while IFS='|' read -r pkg status sec; do
        [ -n "$pkg" ] || continue
        summary+="| $pkg | $status | $sec |"$'\n'
      done < "$timings_file"
    fi
    gh_summary "$summary"
  }

  log_info "Full mode compiled $total_ok package source(s)"
  step_end
}

reset_payload_dir() {
  local payload_dir="$1"

  mkdir -p "$payload_dir/depends"
  find "$payload_dir" -maxdepth 1 -type f \
    \( -name '*.apk' -o -name '*.run' -o -name 'SHA256SUMS' -o -name 'packages.adb' -o -name 'TOPLEVEL_PACKAGES' -o -name 'INSTALL_WHITELIST' \) \
    -delete 2>/dev/null || true
  find "$payload_dir/depends" -maxdepth 1 -type f \
    \( -name '*.apk' -o -name 'packages.adb' \) \
    -delete 2>/dev/null || true
  if [ "$(realpath "$REPO_ROOT/payload/install.sh")" != "$(realpath -m "$payload_dir/install.sh")" ]; then
    cp "$REPO_ROOT/payload/install.sh" "$payload_dir/install.sh"
  fi
}

write_payload_repository_indexes() {
  local apk_tool="$1" payload_dir="$2"
  local -a payload_top_apks payload_dep_apks

  mapfile -t payload_top_apks < <(find "$payload_dir" -maxdepth 1 -type f -name '*.apk' | LC_ALL=C sort)
  [ "${#payload_top_apks[@]}" -gt 0 ] || die "Payload root APK set is empty"
  "$apk_tool" --allow-untrusted mkndx --output "$payload_dir/packages.adb" "${payload_top_apks[@]}" \
    >/dev/null || die "Failed to generate payload root repository index"

  mapfile -t payload_dep_apks < <(find "$payload_dir/depends" -maxdepth 1 -type f -name '*.apk' | LC_ALL=C sort)
  [ "${#payload_dep_apks[@]}" -gt 0 ] || die "Payload dependency APK set is empty"
  "$apk_tool" --allow-untrusted mkndx --output "$payload_dir/depends/packages.adb" "${payload_dep_apks[@]}" \
    >/dev/null || die "Failed to generate payload dependency repository index"
}

emit_payload_dependency_summary() {
  local root_count="$1" total_fetched="$2" dep_count="$3"
  local whitelist_file="$4" missing_count="$5" official_fallback_count="$6"

  gh_summary "$(build_payload_dependency_summary \
    "$root_count" \
    "$total_fetched" \
    "$dep_count" \
    "$whitelist_file" \
    "$missing_count" \
    "$official_fallback_count")"
}

collect_full_payload() {
  step_start "Collect payload"
  local local_repo_root local_target_repo_root local_repo_search_root
  local passwall_roots_file apk_tool arch_packages local_repo_index_list fetch_dir canonical_fetch_dir combined_repo_file requested_specs_file install_whitelist_file
  local_repo_root="$FULL_SDK_DIR/bin/packages"
  local_target_repo_root="$FULL_SDK_DIR/bin/targets"
  local_repo_search_root="$FULL_SDK_DIR/bin"
  passwall_roots_file="$FULL_SDK_DIR/.passwall-package-roots"
  apk_tool="$FULL_SDK_DIR/staging_dir/host/bin/apk"
  arch_packages=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\([^"]*\)"/\1/p' "$FULL_SDK_DIR/.config" | head -n 1)
  local_repo_index_list="$FULL_SDK_DIR/.local-repositories"
  fetch_dir="$FULL_SDK_DIR/.resolved-apks"
  canonical_fetch_dir="$FULL_SDK_DIR/.resolved-apks-canonical"
  combined_repo_file="$FULL_SDK_DIR/.combined-repositories"
  requested_specs_file="$WORKDIR/requested-specs.txt"
  install_whitelist_file="$PAYLOAD_DIR/INSTALL_WHITELIST"

  reset_payload_dir "$PAYLOAD_DIR"

  [ -d "$local_repo_root" ] || die "Local package output directory missing: $local_repo_root"
  [ -d "$local_repo_search_root" ] || die "Local build output directory missing: $local_repo_search_root"
  [ -x "$apk_tool" ] || die "OpenWrt host apk tool not found: $apk_tool"
  [ -n "$arch_packages" ] || die "Cannot derive ARCH_PACKAGES from local .config"

  (
    cd "$FULL_SDK_DIR"
    declare -A toplevel_pkgs=() top_files=() missing_pkgs=() official_fetch_pkgs=() selected_apks=() selected_apk_source=() install_whitelist_pkgs=()
    REQUESTED_SPECS=()

    build_local_repository() {
      local mkndx_log="/tmp/package-index-$$.log"
      find "$local_repo_root" -type f -name 'packages.adb' -delete 2>/dev/null || true
      if make package/index V=s >"$mkndx_log" 2>&1; then
        :
      else
        tail -60 "$mkndx_log" || true
        rm -f "$mkndx_log"
        die "Failed to generate local APK repository indexes"
      fi
      rm -f "$mkndx_log"

      mapfile -t LOCAL_REPO_INDEXES < <(
        {
          find "$local_repo_root" -type f -name 'packages.adb'
          if [ -d "$local_target_repo_root" ]; then
            find "$local_target_repo_root" -type f -path '*/packages/packages.adb'
          fi
        } | LC_ALL=C sort -u
      )
      [ "${#LOCAL_REPO_INDEXES[@]}" -gt 0 ] || die "No local packages.adb indexes found under $local_repo_root or $local_target_repo_root"
      printf 'file://%s\n' "${LOCAL_REPO_INDEXES[@]}" > "$local_repo_index_list"
    }

    make_combined_repositories() {
      local repo_file="$1" dist_root target_path kmods_repo
      dist_root="${OPENWRT_SDK_URL%%/targets/*}"
      target_path=$(printf '%s' "$OPENWRT_SDK_URL" | sed -n 's#.*/targets/\([^/]*/[^/]*\)/.*#\1#p')
      [ -n "$dist_root" ] || die "Cannot derive OpenWrt dist root from SDK URL"
      [ -n "$target_path" ] || die "Cannot derive target path from SDK URL"
      cat "$local_repo_index_list" > "$repo_file"
      kmods_repo=$(resolve_remote_kmods_repo "$dist_root" "$target_path" || true)
      cat >> "$repo_file" <<EOF
$dist_root/targets/$target_path/packages/packages.adb
$dist_root/packages/$arch_packages/base/packages.adb
$dist_root/packages/$arch_packages/packages/packages.adb
$dist_root/packages/$arch_packages/luci/packages.adb
$dist_root/packages/$arch_packages/routing/packages.adb
$dist_root/packages/$arch_packages/telephony/packages.adb
EOF
      if [ -n "$kmods_repo" ]; then
        printf '%s\n' "$kmods_repo" >> "$repo_file"
      else
        log_warn "Unable to resolve remote kmods repository under targets/$target_path/kmods/"
      fi
    }

    fetch_resolved_packages() {
      local repo_file="$1" dest_dir="$2"
      shift 2
      [ "$#" -gt 0 ] || return 0
      rm -rf "$dest_dir"
      mkdir -p "$dest_dir"
      "$apk_tool" \
        --allow-untrusted \
        --force-refresh \
        --no-interactive \
        --no-cache \
        --arch "$arch_packages" \
        --repositories-file "$repo_file" \
        fetch --recursive --output "$dest_dir" "$@"
    }

    register_canonical_apk() {
      local apk_file="$1" apk_source="$2"
      local pkg_name current_file current_source preferred_file target_file

      pkg_name=$(apk_package_name_from_file "$apk_file" || true)
      [ -n "$pkg_name" ] || return 0

      current_file="${selected_apks[$pkg_name]:-}"
      current_source="${selected_apk_source[$pkg_name]:-}"
      if [ -n "$current_file" ]; then
        if [ "$current_source" != "$apk_source" ]; then
          [ "$apk_source" = "local" ] || return 0
          preferred_file="$apk_file"
        else
          preferred_file=$(prefer_newer_file_by_basename "$current_file" "$apk_file")
          [ "$preferred_file" = "$apk_file" ] || return 0
        fi
        rm -f "$current_file"
      fi

      target_file="$canonical_fetch_dir/$(basename "$apk_file")"
      cp -f "$apk_file" "$target_file"
      selected_apks["$pkg_name"]="$target_file"
      selected_apk_source["$pkg_name"]="$apk_source"
    }

    canonicalize_resolved_packages() {
      local apk_file
      rm -rf "$canonical_fetch_dir"
      mkdir -p "$canonical_fetch_dir"

      while IFS= read -r -d '' apk_file; do
        register_canonical_apk "$apk_file" "fetched"
      done < <(find "$fetch_dir" -maxdepth 1 -type f -name '*.apk' -print0)

      while IFS= read -r -d '' apk_file; do
        register_canonical_apk "$apk_file" "local"
      done < <(find "$local_repo_search_root" -type f -name '*.apk' -print0)
    }

    build_local_repository

    toplevel_pkgs["luci-app-passwall"]=1
    luci_spec=$(local_pkg_spec "$local_repo_search_root" "luci-app-passwall" || true)
    [ -n "$luci_spec" ] || die "luci-app-passwall APK not found in local repository"
    REQUESTED_SPECS+=("$luci_spec")
    # Prefer dnsmasq-full as the provider for PassWall's virtual dnsmasq dependency
    # so apk does not resolve it to the conflicting minimal dnsmasq package.
    REQUESTED_SPECS+=("dnsmasq-full")

    zh_spec=$(local_pkg_spec "$local_repo_search_root" "luci-i18n-passwall-zh-cn" || true)
    if [ -n "$zh_spec" ]; then
      toplevel_pkgs["luci-i18n-passwall-zh-cn"]=1
      REQUESTED_SPECS+=("$zh_spec")
    fi

    root_count=0
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      root_count=$((root_count + 1))
      toplevel_pkgs["$pkg"]=1
      pkg_spec=$(local_pkg_spec "$local_repo_search_root" "$pkg" || true)
      if [ -n "$pkg_spec" ]; then
        REQUESTED_SPECS+=("$pkg_spec")
      else
        REQUESTED_SPECS+=("$pkg")
        if map_passwall_source_dir "$pkg" >/dev/null 2>&1; then
          missing_pkgs["$pkg"]=1
        else
          official_fetch_pkgs["$pkg"]=1
        fi
      fi
    done < "$passwall_roots_file"

    printf '%s\n' "${!toplevel_pkgs[@]}" | LC_ALL=C sort > "$PAYLOAD_DIR/TOPLEVEL_PACKAGES"

    printf '%s\n' "${REQUESTED_SPECS[@]}" | sed '/^$/d' | LC_ALL=C sort -u > "$requested_specs_file"
    mapfile -t REQUESTED_SPECS < "$requested_specs_file"
    make_combined_repositories "$combined_repo_file"
    fetch_resolved_packages "$combined_repo_file" "$fetch_dir" "${REQUESTED_SPECS[@]}" \
      || die "Failed to resolve dependency closure from local and official repositories"
    canonicalize_resolved_packages

    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      install_whitelist_pkgs["$pkg"]=1
    done < "$passwall_roots_file"
    install_whitelist_pkgs["luci-app-passwall"]=1
    [ -n "$zh_spec" ] && install_whitelist_pkgs["luci-i18n-passwall-zh-cn"]=1
    while IFS= read -r -d '' apk_file; do
      pkg_name=$(apk_package_name_from_file "$apk_file" || true)
      [ -n "$pkg_name" ] || continue
      if map_passwall_source_dir "$pkg_name" >/dev/null 2>&1; then
        install_whitelist_pkgs["$pkg_name"]=1
      fi
    done < <(find "$canonical_fetch_dir" -maxdepth 1 -type f -name '*.apk' -print0)
    if find_payload_pkg_file "$canonical_fetch_dir" "dnsmasq-full" >/dev/null 2>&1; then
      install_whitelist_pkgs["dnsmasq-full"]=1
    fi
    printf '%s\n' "${!install_whitelist_pkgs[@]}" | LC_ALL=C sort > "$install_whitelist_file"
    [ -s "$install_whitelist_file" ] || die "Installer whitelist is empty"

    for pkg in "${!toplevel_pkgs[@]}"; do
      pkg_file=$(find_payload_pkg_file "$canonical_fetch_dir" "$pkg" || true)
      if [ -n "$pkg_file" ]; then
        cp "$pkg_file" "$PAYLOAD_DIR/"
        top_files["$(basename "$pkg_file")"]=1
      elif [ "$pkg" != "luci-i18n-passwall-zh-cn" ]; then
        die "Top-level package missing after dependency resolution: $pkg"
      fi
    done

    while IFS= read -r -d '' apk_file; do
      base_name=$(basename "$apk_file")
      [ -n "${top_files[$base_name]+x}" ] && continue
      cp "$apk_file" "$PAYLOAD_DIR/depends/"
    done < <(find "$canonical_fetch_dir" -maxdepth 1 -type f -name '*.apk' -print0)

    write_payload_repository_indexes "$apk_tool" "$PAYLOAD_DIR"

    dep_count=$(find "$PAYLOAD_DIR/depends" -maxdepth 1 -name '*.apk' | wc -l)
    total_fetched=$(find "$canonical_fetch_dir" -maxdepth 1 -name '*.apk' | wc -l)
    missing_count=${#missing_pkgs[@]}
    min_deps=${MIN_REQUIRED_PACKAGES:-1}

    emit_payload_dependency_summary \
      "$root_count" \
      "$total_fetched" \
      "$dep_count" \
      "$install_whitelist_file" \
      "$missing_count" \
      "${#official_fetch_pkgs[@]}"

    [ "$dep_count" -gt 0 ] || die "No dependency APKs found"
    [ "$dep_count" -ge "$min_deps" ] || die "Only $dep_count dependency APKs collected (expected at least $min_deps)"
    [ "$missing_count" -eq 0 ] || die "Some locally built PassWall packages are missing from payload: ${!missing_pkgs[*]}"
  )

  find "$PAYLOAD_DIR" -maxdepth 1 -type f \
    \( -name 'luci-app-passwall-*.apk' -o -name 'luci-app-passwall_*.apk' \) \
    -print -quit | grep -q . \
    || die "Payload missing luci-app-passwall APK"
  generate_sha256_manifest "$PAYLOAD_DIR"
  [ -s "$PAYLOAD_DIR/SHA256SUMS" ] || die "Payload checksum manifest missing"
  step_end
}

run_install_smoke_test() {
  step_start "Run installer smoke test"
  local mockbin install_log apk_invocations smoke_payload_dir pkg smoke_status smoke_summary smoke_expected_packages smoke_expected_mode has_dnsmasq_full smoke_exit
  mockbin="$WORKDIR/mockbin"
  install_log="$WORKDIR/install.log"
  apk_invocations="$WORKDIR/apk-invocations.log"
  smoke_payload_dir="$WORKDIR/payload-smoke"

  rm -rf "$smoke_payload_dir"
  mkdir -p "$smoke_payload_dir/depends"
  cp "$REPO_ROOT/payload/install.sh" "$smoke_payload_dir/install.sh"
  cp "$PAYLOAD_DIR/TOPLEVEL_PACKAGES" "$smoke_payload_dir/TOPLEVEL_PACKAGES"
  smoke_expected_packages="$smoke_payload_dir/TOPLEVEL_PACKAGES"
  smoke_expected_mode="top-level"
  if [ -f "$PAYLOAD_DIR/INSTALL_WHITELIST" ]; then
    cp "$PAYLOAD_DIR/INSTALL_WHITELIST" "$smoke_payload_dir/INSTALL_WHITELIST"
    smoke_expected_packages="$smoke_payload_dir/INSTALL_WHITELIST"
    smoke_expected_mode="whitelist"
  fi
  printf 'synthetic-root-index\n' > "$smoke_payload_dir/packages.adb"
  printf 'synthetic-dep-index\n' > "$smoke_payload_dir/depends/packages.adb"

  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    printf 'synthetic-%s-%s\n' "$pkg" "$PASSWALL_VERSION_TAG" > "$smoke_payload_dir/${pkg}-${PASSWALL_VERSION_TAG}-r1.apk"
  done < "$smoke_payload_dir/TOPLEVEL_PACKAGES"

  has_dnsmasq_full=0
  if find_payload_pkg_file "$PAYLOAD_DIR" "dnsmasq-full" >/dev/null 2>&1; then
    has_dnsmasq_full=1
    printf 'synthetic-dnsmasq-full\n' > "$smoke_payload_dir/dnsmasq-full-1.0-r1.apk"
  fi

  if [ -f "$smoke_payload_dir/INSTALL_WHITELIST" ]; then
    while IFS= read -r pkg; do
      [ -n "$pkg" ] || continue
      case "$pkg" in
        luci-app-passwall|luci-i18n-passwall-zh-cn|dnsmasq-full)
          continue
          ;;
      esac
      if grep -qx "$pkg" "$smoke_payload_dir/TOPLEVEL_PACKAGES"; then
        continue
      fi
      printf 'synthetic-%s-%s\n' "$pkg" "$PASSWALL_VERSION_TAG" > "$smoke_payload_dir/depends/${pkg}-${PASSWALL_VERSION_TAG}-r1.apk"
    done < "$smoke_payload_dir/INSTALL_WHITELIST"
  fi

  printf 'synthetic-dependency\n' > "$smoke_payload_dir/depends/example-dependency-1.0-r1.apk"
  generate_sha256_manifest "$smoke_payload_dir"

  smoke_status="ok"

  if ! run_mocked_installer "$smoke_payload_dir" "$install_log" "$apk_invocations" "$mockbin"; then
    smoke_exit=$?
    smoke_status="install-script exited non-zero (${smoke_exit})"
  else
    if ! grep -q "Install mode: $smoke_expected_mode" "$install_log"; then
      smoke_status="install mode mismatch: expected $smoke_expected_mode"
    elif ! grep -q "installed successfully" "$install_log"; then
      smoke_status="success marker missing"
    elif ! grep -q "Using explicit payload APKs for selected packages" "$install_log"; then
      smoke_status="explicit payload install mode missing"
    elif [ -f "$smoke_expected_packages" ]; then
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        if ! grep -q "Installing .*packages: .*${pkg}" "$install_log"; then
          smoke_status="expected package missing from smoke log: $pkg"
          break
        fi
      done < "$smoke_expected_packages"
    fi
  fi

  if [ "$smoke_status" = "ok" ] && [ "$has_dnsmasq_full" -eq 1 ]; then
    if ! grep -q "Removing conflicting packages: dnsmasq dnsmasq-dhcpv6" "$install_log"; then
      smoke_status="dnsmasq-full conflict removal missing"
    elif ! grep -q "del dnsmasq dnsmasq-dhcpv6" "$apk_invocations"; then
      smoke_status="dnsmasq-full removal invocation missing"
    elif ! grep -q -- '--force-reinstall' "$apk_invocations"; then
      smoke_status="force-reinstall flag missing"
    fi
  fi

  if [ "$smoke_status" != "ok" ]; then
    log_error "Installer smoke test failed (${smoke_status})"
    if [ -f "$install_log" ]; then
      group_start "Installer smoke install.log"
      cat "$install_log" || true
      group_end
    fi
    if [ -f "$apk_invocations" ]; then
      group_start "Installer smoke apk invocations"
      cat "$apk_invocations" || true
      group_end
    fi
    smoke_summary="## Installer Smoke Test"$'\n'
    smoke_summary+="- Result: failed"$'\n'
    smoke_summary+="- Reason: ${smoke_status}"$'\n'
    smoke_summary+="- Expected install mode: ${smoke_expected_mode}"$'\n'
    smoke_summary+="- Synthetic package assertions: $(wc -l < "$smoke_expected_packages" | tr -d ' ')"$'\n'
    gh_summary "$smoke_summary"
    die "Installer smoke test failed: ${smoke_status}"
  fi

  step_end
}

build_installer() {
  step_start "Build installer"
  local build_dir label arch sdk_ver
  build_dir="$WORKDIR/build-installer"
  arch=$(sdk_arch_slug)
  sdk_ver=$(sdk_version_from_url)
  RUN_NAME="passwall_${PASSWALL_VERSION_TAG}_${arch}_sdk_${sdk_ver}.run"
  label="passwall_${PASSWALL_VERSION_TAG}_with_sdk_${sdk_ver}"
  RUN_OUTPUT="$OUTPUT_DIR/$RUN_NAME"

  mkdir -p "$build_dir/payload"
  cp -r "$PAYLOAD_DIR"/. "$build_dir/payload/"
  chmod +x "$build_dir/payload/install.sh"

  (
    cd "$build_dir"
    makeself --nox11 --sha256 payload "$RUN_OUTPUT" "$label" ./install.sh >/dev/null
  ) || die "makeself failed during installer build"

  sh "$RUN_OUTPUT" --check >/dev/null || die ".run integrity check failed"
  gh_set_env "RUN_NAME" "$RUN_NAME"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf 'run_name=%s\n' "$RUN_NAME" >> "$GITHUB_OUTPUT"
  gh_summary "- Installer artifact: \`$RUN_NAME\`"
  log_info "Installer created: $RUN_OUTPUT"
  step_end
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
Full build completed successfully.
PassWall tag: $RAW_TAG
Normalized tag: $PASSWALL_VERSION_TAG
SDK URL: $OPENWRT_SDK_URL
Output directory: $OUTPUT_DIR
Artifact: $RUN_OUTPUT
Payload directory: $PAYLOAD_DIR
Workdir: $WORKDIR
EOF
  cat "$SUMMARY_FILE"
}

write_metadata() {
  [ -n "$METADATA_FILE" ] || return 0
  cat > "$METADATA_FILE" <<EOF
RAW_TAG=$RAW_TAG
PASSWALL_VERSION_TAG=$PASSWALL_VERSION_TAG
OPENWRT_SDK_URL=$OPENWRT_SDK_URL
RUN_NAME=$RUN_NAME
RUN_OUTPUT=$RUN_OUTPUT
PAYLOAD_DIR=$PAYLOAD_DIR
WORKDIR=$WORKDIR
FULL_SDK_DIR=$FULL_SDK_DIR
EOF
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo-root)
        REPO_ROOT="${2:-}"
        [ -n "$REPO_ROOT" ] || die "--repo-root requires a value"
        CONFIG_FILE="$REPO_ROOT/config/config.conf"
        OUTPUT_DIR="$REPO_ROOT"
        shift 2
        ;;
      --config)
        CONFIG_FILE="${2:-}"
        [ -n "$CONFIG_FILE" ] || die "--config requires a value"
        shift 2
        ;;
      --tag)
        TAG_OVERRIDE="${2:-}"
        [ -n "$TAG_OVERRIDE" ] || die "--tag requires a value"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="${2:-}"
        [ -n "$OUTPUT_DIR" ] || die "--output-dir requires a value"
        shift 2
        ;;
      --payload-dir)
        PAYLOAD_DIR="${2:-}"
        [ -n "$PAYLOAD_DIR" ] || die "--payload-dir requires a value"
        shift 2
        ;;
      --sdk-root)
        SDK_ROOT="${2:-}"
        [ -n "$SDK_ROOT" ] || die "--sdk-root requires a value"
        shift 2
        ;;
      --sdk-archive)
        SDK_ARCHIVE_OVERRIDE="${2:-}"
        [ -n "$SDK_ARCHIVE_OVERRIDE" ] || die "--sdk-archive requires a value"
        shift 2
        ;;
      --passwall-luci-dir)
        PASSWALL_LUCI_DIR="${2:-}"
        [ -n "$PASSWALL_LUCI_DIR" ] || die "--passwall-luci-dir requires a value"
        shift 2
        ;;
      --passwall-packages-dir)
        PASSWALL_PACKAGES_DIR="${2:-}"
        [ -n "$PASSWALL_PACKAGES_DIR" ] || die "--passwall-packages-dir requires a value"
        shift 2
        ;;
      --passwall-luci-repo)
        PASSWALL_LUCI_REPO="${2:-}"
        [ -n "$PASSWALL_LUCI_REPO" ] || die "--passwall-luci-repo requires a value"
        shift 2
        ;;
      --passwall-packages-repo)
        PASSWALL_PACKAGES_REPO="${2:-}"
        [ -n "$PASSWALL_PACKAGES_REPO" ] || die "--passwall-packages-repo requires a value"
        shift 2
        ;;
      --metadata-file)
        METADATA_FILE="${2:-}"
        [ -n "$METADATA_FILE" ] || die "--metadata-file requires a value"
        shift 2
        ;;
      --keep-workdir)
        KEEP_WORKDIR=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  prepare_workspace
  cd "$REPO_ROOT"
  load_config
  resolve_tag
  validate_inputs
  prepare_sdk_workspace
  configure_local_feeds
  prefetch_rust_sources
  prepare_full_sources
  generate_full_config
  compile_full_sources
  collect_full_payload
  run_install_smoke_test
  build_installer
  write_summary
  write_metadata
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
