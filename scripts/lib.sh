#!/usr/bin/env bash
# lib.sh — shared utilities for PassWall build scripts
# Source this file; do not execute directly.

# ── Logging ───────────────────────────────────────────

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '[WARN]  %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$@"; exit 1; }

# ── CI helpers ────────────────────────────────────────

group_start() { printf '::group::%s\n' "$*"; }
group_end()   { printf '::endgroup::\n'; }

gh_set_env() {
  export "$1=$2"
  [ -n "${GITHUB_ENV:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
}

gh_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

gh_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

# ── Payload layout constants ─────────────────────────

PAYLOAD_APK_DIR="apks"
PAYLOAD_META_DIR="metadata"
PAYLOAD_WHITELIST="$PAYLOAD_META_DIR/INSTALL_WHITELIST"
PAYLOAD_APK_MAP="$PAYLOAD_META_DIR/PAYLOAD_APK_MAP"
PAYLOAD_REPO_INDEX="$PAYLOAD_APK_DIR/packages.adb"

# ── Core utilities ────────────────────────────────────

retry() {
  local max="$1" delay="$2"; shift 2
  local attempt=1
  while [ "$attempt" -le "$max" ]; do
    log_info "Attempt $attempt/$max: $*"
    "$@" && return 0
    [ "$attempt" -eq "$max" ] && { log_error "Failed after $max attempts: $*"; return 1; }
    log_warn "Attempt $attempt failed, retrying in ${delay}s…"
    sleep "$delay"; attempt=$((attempt + 1))
  done
}

require_tool() { command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"; }

trim_tag() { printf '%s\n' "${1#v}"; }

load_config() {
  local file="$1"
  [ -f "$file" ] || die "Config not found: $file"
  while IFS='=' read -r key value; do
    key=${key#${key%%[![:space:]]*}}
    key=${key%%[[:space:]]*}
    [ -n "${key:-}" ] || continue
    [[ "$key" =~ ^# ]] && continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid config key: $key"
    value=${value#${value%%[![:space:]]*}}
    value=${value%${value##*[![:space:]]}}
    export "$key=$value"
    [ -n "${GITHUB_ENV:-}" ] && printf '%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
  done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file")
}

# ── Git / Remote ──────────────────────────────────────

resolve_latest_release_tag() {
  curl -fsSL --retry 3 --retry-delay 10 \
    "https://api.github.com/repos/$1/$2/releases/latest" \
    | tr -d '\n' \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

resolve_remote_tag() {
  local repo_url="$1"; shift
  local tag
  for tag in "$@"; do
    [ -n "$tag" ] || continue
    git ls-remote --exit-code --refs --tags "$repo_url" "refs/tags/$tag" >/dev/null 2>&1 \
      && { printf '%s\n' "$tag"; return 0; }
  done
  return 1
}

resolve_remote_default_branch() {
  git ls-remote --symref "$1" HEAD 2>/dev/null \
    | awk '/^ref:/ { sub("refs/heads/","",$2); print $2; exit }'
}

# ── Build helper ──────────────────────────────────────

make_pkg() {
  local target="$1" label="${2:-$1}"
  local jobs logfile
  jobs=$(nproc)
  logfile="/tmp/build-${label//\//_}-$$.log"

  local -a env_args=()
  [ -n "${RUSTFLAGS:-}" ]                    && env_args+=("RUSTFLAGS=$RUSTFLAGS")
  [ -n "${CARGO_INCREMENTAL:-}" ]            && env_args+=("CARGO_INCREMENTAL=$CARGO_INCREMENTAL")
  [ -n "${CARGO_NET_GIT_FETCH_WITH_CLI:-}" ] && env_args+=("CARGO_NET_GIT_FETCH_WITH_CLI=$CARGO_NET_GIT_FETCH_WITH_CLI")
  [ -n "${CARGO_PROFILE_RELEASE_DEBUG:-}" ]  && env_args+=("CARGO_PROFILE_RELEASE_DEBUG=$CARGO_PROFILE_RELEASE_DEBUG")

  log_info "Compiling $label (-j$jobs)"
  local j fallback=$(( jobs > 2 ? jobs / 2 : 1 ))
  for j in "$jobs" "$fallback" 1; do
    if env ${env_args[@]+"${env_args[@]}"} make "$target" -j"$j" V=s >"$logfile" 2>&1; then
      rm -f "$logfile"; return 0
    fi
    [ "$j" -gt 1 ] && log_warn "Build failed at -j$j for $label, retrying…"
  done
  log_error "Build failed: $label"
  tail -50 "$logfile" 2>/dev/null || true
  rm -f "$logfile"; return 1
}

# ── APK utilities ─────────────────────────────────────

apk_pkg_name() {
  local base="${1##*/}"
  [[ "$base" == *.apk ]] || return 1
  printf '%s\n' "$base" | sed -E 's/[-_][0-9].*\.apk$//'
}

pick_newer_apk() {
  [ -n "$1" ] || { printf '%s\n' "$2"; return; }
  [ -n "$2" ] || { printf '%s\n' "$1"; return; }
  local winner
  winner=$(printf '%s\n%s\n' "$(basename "$1")" "$(basename "$2")" | LC_ALL=C sort -V | tail -1)
  [[ "$winner" == "$(basename "$2")" ]] && printf '%s\n' "$2" || printf '%s\n' "$1"
}

find_best_apk() {
  local dir="$1" pkg="$2" best="" f
  while IFS= read -r -d '' f; do
    best=$(pick_newer_apk "$best" "$f")
  done < <(find "$dir" -type f \( -name "${pkg}-[0-9]*.apk" -o -name "${pkg}_[0-9]*.apk" \) -print0)
  [ -n "$best" ] && printf '%s\n' "$best"
}

pkg_candidates() {
  case "$1" in
    nftables)               printf '%s\n' nftables nftables-json nftables-nojson ;;
    hysteria|hysteria2|hy2) printf '%s\n' hysteria hysteria2 hy2 ;;
    *)                      printf '%s\n' "$1" ;;
  esac
}

find_payload_apk() {
  local dir="$1" pkg="$2" candidate f
  while IFS= read -r candidate; do
    f=$(find_best_apk "$dir" "$candidate" || true)
    [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
  done < <(pkg_candidates "$pkg")
  return 1
}

map_passwall_src_dir() {
  case "$1" in
    shadowsocks-libev-*)                        echo "package/passwall-packages/shadowsocks-libev" ;;
    shadowsocks-rust-*)                         echo "package/passwall-packages/shadowsocks-rust" ;;
    shadowsocksr-libev-*)                       echo "package/passwall-packages/shadowsocksr-libev" ;;
    simple-obfs-*)                              echo "package/passwall-packages/simple-obfs" ;;
    v2ray-geoip|v2ray-geosite)                  echo "package/passwall-packages/v2ray-geodata" ;;
    luci-app-passwall|luci-i18n-passwall-zh-cn) echo "package/passwall-luci/luci-app-passwall" ;;
    *) [ -d "package/passwall-packages/$1" ] && echo "package/passwall-packages/$1" || return 1 ;;
  esac
}

local_pkg_spec() {
  local dir="$1" pkg="$2" f ver
  f=$(find_best_apk "$dir" "$pkg" || true); [ -n "$f" ] || return 1
  ver="${f##*/}"; ver="${ver%.apk}"; ver="${ver#"${pkg}"-}"; ver="${ver#"${pkg}"_}"
  [ -n "$ver" ] || return 1
  printf '%s=%s\n' "$pkg" "$ver"
}

# ── Payload generation ────────────────────────────────

generate_sha256sums() {
  ( cd "$1"
    find . -type f ! -name SHA256SUMS -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum > SHA256SUMS )
}

write_apk_manifest() {
  local payload_dir="$1"
  local apk_dir="$payload_dir/$PAYLOAD_APK_DIR"
  local manifest="$payload_dir/$PAYLOAD_APK_MAP"
  declare -A pkg_map=()
  local f rel pkg cur preferred

  [ -d "$apk_dir" ] || die "APK directory missing: $apk_dir"
  mkdir -p "$(dirname "$manifest")"

  while IFS= read -r -d '' f; do
    rel="${f#"$payload_dir"/}"
    pkg=$(apk_pkg_name "$f" || true); [ -n "$pkg" ] || continue
    cur="${pkg_map[$pkg]:-}"
    if [ -n "$cur" ]; then
      preferred=$(pick_newer_apk "$payload_dir/$cur" "$f")
      [ "$preferred" = "$f" ] || continue
    fi
    pkg_map["$pkg"]="$rel"
  done < <(find "$apk_dir" -maxdepth 1 -type f -name '*.apk' -print0)

  : > "$manifest"
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '%s|%s\n' "$name" "${pkg_map[$name]}" >> "$manifest"
  done < <(printf '%s\n' "${!pkg_map[@]}" | LC_ALL=C sort)
  [ -s "$manifest" ] || die "Payload APK manifest is empty"
}

# ── Smoke test helpers ────────────────────────────────

write_mock_apk() {
  cat > "$1" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "${APK_INVOCATIONS_LOG:?}"
case "$1" in
  info) case "${3:-}" in dnsmasq|dnsmasq-dhcpv6) exit 0 ;; *) exit 1 ;; esac ;;
  list|del) exit 0 ;;
  add)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --allow-untrusted|--no-interactive) shift ;;
        --repositories-file|--arch|--repository) shift 2 ;;
        --*) shift ;;
        *) break ;;
      esac
    done
    if [ "${APK_MOCK_REQUIRE_APK_FILES:-0}" = "1" ]; then
      for t in "$@"; do case "$t" in *.apk) ;; *) exit 11 ;; esac; done
    fi
    exit 0 ;;
esac
exit 0
MOCK
  chmod +x "$1"
}

run_mock_installer() {
  local payload_dir="$1" log="$2" invocations="$3" mockbin="$4"
  mkdir -p "$mockbin"; : > "$log"; : > "$invocations"
  write_mock_apk "$mockbin/apk"
  local -a sh_cmd
  command -v busybox >/dev/null 2>&1 && sh_cmd=(busybox sh) || sh_cmd=(sh)
  ( cd "$payload_dir"
    env APK_INVOCATIONS_LOG="$invocations" APK_MOCK_REQUIRE_APK_FILES=1 \
      PATH="$mockbin:$PATH" "${sh_cmd[@]}" ./install.sh
  ) >"$log" 2>&1
}

# ── Download helper ───────────────────────────────────

download_verified() {
  local dest_dir="$1" filename="$2" expected_sha="$3"; shift 3
  local dest="$dest_dir/$filename" actual url
  mkdir -p "$dest_dir"

  if [ -f "$dest" ]; then
    actual=$(sha256sum "$dest" | awk '{print $1}')
    [ "$actual" = "$expected_sha" ] && { log_info "Cached: $filename"; return 0; }
    rm -f "$dest"
  fi

  for url in "$@"; do
    [ -n "$url" ] || continue
    log_info "Downloading $filename from $url"
    if retry 3 10 curl -fL --connect-timeout 10 --retry 3 --retry-delay 5 -o "$dest" "$url"; then
      actual=$(sha256sum "$dest" | awk '{print $1}')
      [ "$actual" = "$expected_sha" ] && { log_info "Verified: $filename"; return 0; }
      log_warn "Hash mismatch for $filename from $url"; rm -f "$dest"
    fi
  done
  die "Download failed: $filename"
}
