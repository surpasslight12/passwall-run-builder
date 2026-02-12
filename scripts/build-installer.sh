#!/usr/bin/env bash
# build-installer.sh — 打包自解压 .run 安装文件
# Build self-extracting .run installer with makeself
source "$(dirname "$0")/lib.sh"

: "${OPENWRT_SDK_URL:?OPENWRT_SDK_URL not set}"

group_start "Build installer"

mkdir -p build/payload
cp -r payload/* build/payload/
chmod +x build/payload/install.sh
cd build

# 从文件名提取版本 / Extract version from filename
PW_FILE=$(ls payload | grep -E 'luci-app-passwall[-_]' | head -1)
[ -z "$PW_FILE" ] && die "luci-app-passwall package not found"
PW_VER=$(echo "$PW_FILE" | sed -E 's/luci-app-passwall[-_]//; s/[-_].*//')

# 从 SDK URL 提取架构和版本 / Extract arch & version from SDK URL
ARCH=$(echo "$OPENWRT_SDK_URL" | sed -n 's#.*/targets/\([^/]*/[^/]*\)/.*#\1#p' | tr '/' '_')
if [ -z "$ARCH" ]; then
  log_warn "Cannot extract architecture from SDK URL, using 'unknown'"
  ARCH="unknown"
fi
SDK_VER=$(echo "$OPENWRT_SDK_URL" | sed -n 's#.*/openwrt-sdk-\([0-9.]*\(-rc[0-9]*\)\?\)-.*#\1#p')
if [ -z "$SDK_VER" ]; then
  log_warn "Cannot extract SDK version from SDK URL, using 'unknown'"
  SDK_VER="unknown"
fi

RUN_NAME="passwall_${PW_VER}_${ARCH}_sdk_${SDK_VER}.run"
LABEL="passwall_${PW_VER}_with_sdk_${SDK_VER}"

log_info "Building $RUN_NAME"
makeself --nox11 --sha256 payload "../${RUN_NAME}" "${LABEL}" ./install.sh \
  || die "makeself failed"
cd ..
group_end

# ── 校验 / Verify ──
group_start "Verify installer"
file "$RUN_NAME"
sh "$RUN_NAME" --check || die "Integrity check failed"
log_info "OK — $(du -h "$RUN_NAME" | cut -f1)"
group_end

gh_set_env "RUN_NAME" "$RUN_NAME"
