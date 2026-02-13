#!/usr/bin/env bash
# collect-packages.sh — 收集 APK 到 payload 目录
# Collect built APKs into payload directory
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib.sh"

step_start "Collect packages"

cd openwrt-sdk || die "Cannot enter openwrt-sdk directory"

PAYLOAD="${GITHUB_WORKSPACE:-.}/payload"
DEPENDS="$PAYLOAD/depends"
mkdir -p "$DEPENDS"

# ── 收集指定前缀的最新版本 APK / Collect latest APK by prefix ──
collect_pkg() {
  local prefix="$1" dest="$2"
  local best=""
  while IFS= read -r -d '' f; do
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
  done < <(find bin/packages -type f \( -name "${prefix}-*.apk" -o -name "${prefix}_*.apk" \) -print0)
  [ -n "$best" ] || return 1
  cp "$best" "$dest/"
  log_info "Collected $prefix → $(basename "$best")"
}

# ── 收集主包 / Collect main packages ──
group_start "Collect packages"

find bin/packages \( -name "luci-app-passwall-*.apk" -o -name "luci-app-passwall_*.apk" \) \
  -exec cp {} "$PAYLOAD/" \;

collect_pkg "luci-i18n-passwall-zh-cn" "$PAYLOAD" \
  || log_info "Chinese i18n package not found (non-critical)"

# ── 收集依赖 / Collect dependencies ──
DEPS=()
PKGCONF="$SCRIPT_DIR/../config/packages.conf"
if [ -f "$PKGCONF" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    if [[ "$line" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
      DEPS+=("$line")
    else
      log_warn "Skipping invalid package name in packages.conf: $line"
    fi
  done < "$PKGCONF"
else
  log_warn "packages.conf not found, dependency collection list is empty"
fi

COLLECTED=0
for p in "${DEPS[@]}"; do
  if collect_pkg "$p" "$DEPENDS"; then
    COLLECTED=$((COLLECTED + 1))
  else
    log_warn "Missing: $p"
  fi
done
log_info "Collected $COLLECTED/${#DEPS[@]} dependency packages"
group_end

# ── 校验 / Validate ──
group_start "Validate payload"
DEP_COUNT=$(find "$DEPENDS" -name "*.apk" | wc -l)
MIN_DEPS=${MIN_REQUIRED_PACKAGES:-10}
[ "$DEP_COUNT" -eq 0 ] && die "No dependency APKs found"
[ "$DEP_COUNT" -lt "$MIN_DEPS" ] && log_warn "Only $DEP_COUNT packages (expected ≥$MIN_DEPS)"

[ -f "$PAYLOAD/install.sh" ] || die "install.sh missing from payload"

find "$PAYLOAD" -maxdepth 1 -type f \
  \( -name "luci-app-passwall-*.apk" -o -name "luci-app-passwall_*.apk" \) \
  -print -quit | grep -q . \
  || die "luci-app-passwall not found in payload"

log_info "Payload OK: $DEP_COUNT deps"
group_end

step_end
