#!/usr/bin/env bash
# Create a self-extracting .run installer with makeself and verify it.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

: "${OPENWRT_SDK_URL:?OPENWRT_SDK_URL not set}"

# ── Build the .run file ────────────────────────────────────────────────────
group_start "Building installer"

mkdir -p build/payload
cp -r payload/* build/payload/
chmod +x build/payload/install.sh
cd build

PW_FILE=$(ls payload | grep -E 'luci-app-passwall[-_]' | head -n1)
[ -z "$PW_FILE" ] && { log_error "luci-app-passwall package not found"; exit 1; }

PW_FULL=$(extract_version "$PW_FILE" "luci-app-passwall")
PW_VER=${PW_FULL%%-*}
log_info "PassWall version: $PW_VER"

ARCH_SEG=$(echo "$OPENWRT_SDK_URL" | sed -n 's#.*/targets/\([^/]\+/[^/]\+\)/.*#\1#p')
ARCH=${ARCH_SEG:+$(echo "$ARCH_SEG" | tr '/' '_')}
ARCH=${ARCH:-unknown}

SDK_VERSION=$(echo "$OPENWRT_SDK_URL" | sed -n 's#.*/openwrt-sdk-\([0-9.]\+\(-rc[0-9]\+\)\?\)-.*#\1#p')
SDK_VERSION=${SDK_VERSION:-unknown}

log_info "Architecture: $ARCH, SDK: $SDK_VERSION"

RUN_NAME="passwall_${PW_VER}_${ARCH}_sdk_${SDK_VERSION}.run"
LABEL="passwall_${PW_VER}_with_sdk_${SDK_VERSION}"
gh_env "RUN_NAME=${RUN_NAME}"
gh_env "LABEL=${LABEL}"

log_info "Building: $RUN_NAME"
makeself --nox11 --sha256 payload "../${RUN_NAME}" "${LABEL}" ./install.sh \
  || { log_error "makeself failed"; exit 1; }

cd ..
group_end

# ── Verify ──────────────────────────────────────────────────────────────────
group_start "Verifying installer"
file "$RUN_NAME"
sh "$RUN_NAME" --info
sh "$RUN_NAME" --check || { log_error "Integrity check failed"; exit 1; }
log_info "Integrity check passed"
log_info "Installer size: $(du -h "$RUN_NAME" | cut -f1)"
group_end
