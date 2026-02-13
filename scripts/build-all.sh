#!/usr/bin/env bash
# build-all.sh — 统一执行完整构建流程，减少多脚本传递交互问题
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib.sh"

step_start "Unified build pipeline"

SDK_CACHE_HIT="${1:-false}"
FEEDS_CACHE_HIT="${2:-false}"
CFG_FILE="$SCRIPT_DIR/../config/openwrt-sdk.conf"

[ -f "$CFG_FILE" ] || die "Config file not found: $CFG_FILE"
while IFS= read -r line || [ -n "$line" ]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && export "$line"
done < "$CFG_FILE"

: "${OPENWRT_SDK_URL:?OPENWRT_SDK_URL not set}"

"$SCRIPT_DIR/setup-environment.sh"
"$SCRIPT_DIR/install-toolchains.sh"
"$SCRIPT_DIR/setup-sdk.sh" "$SDK_CACHE_HIT"
"$SCRIPT_DIR/configure-feeds.sh" "$FEEDS_CACHE_HIT"
RUST_ENV_DIAG=1 "$SCRIPT_DIR/compile-packages.sh"
"$SCRIPT_DIR/collect-packages.sh"
"$SCRIPT_DIR/build-installer.sh"

step_end
