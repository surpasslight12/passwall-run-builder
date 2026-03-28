#!/usr/bin/env bash
# utils.sh — 工具函数库 / Utility functions
# Usage: source scripts/utils.sh

set -euo pipefail

trap 'rm -f /tmp/build-pkg-*.log 2>/dev/null' EXIT

# ── 日志 / Logging ──
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '::warning::%s\n' "$*"; }
log_error() { printf '::error::%s\n' "$*"; }
die()       { log_error "$@"; exit 1; }

group_start() { echo "::group::$*"; }
group_end()   { echo "::endgroup::"; }

# ── 步骤计时 / Step timing ──
# Usage: step_start "Step name"  … work …  step_end
_STEP_NAME="" _STEP_T0=""
step_start() {
  _STEP_NAME="$1"
  _STEP_T0=$(date +%s)
  log_info "── $_STEP_NAME ──"
}
step_end() {
  if [ -z "$_STEP_T0" ]; then
    log_warn "step_end called without step_start"
    return
  fi
  local dur=$(( $(date +%s) - _STEP_T0 ))
  log_info "── $_STEP_NAME done (${dur}s) ──"
  _STEP_NAME="" _STEP_T0=""
}

# ── 重试 / Retry ──
# Usage: retry <max_attempts> <delay_sec> <command…>
retry() {
  local max="$1" delay="$2"; shift 2
  local i=1
  while [ "$i" -le "$max" ]; do
    log_info "Attempt $i/$max: $1"
    if "$@"; then return 0; fi
    [ "$i" -eq "$max" ] && { log_error "Failed after $max attempts: $1"; return 1; }
    log_warn "Attempt $i failed, retrying in ${delay}s…"
    sleep "$delay"
    i=$((i + 1))
  done
}

# ── Make 封装：并行 → 单线程降级 / Make wrapper with fallback ──
# Usage: make_pkg <target> [label]
make_pkg() {
  local target="$1" label="${2:-$1}"
  local jobs fallback_jobs
  jobs=$(nproc)
  fallback_jobs=$((jobs / 2))
  [ "$fallback_jobs" -lt 1 ] && fallback_jobs=1
  local logfile="/tmp/build-pkg-${label//\//_}-$$.log"

  # Build environment argument array with Rust/Cargo variables
  local env_args=()
  [ -n "${RUSTFLAGS:-}" ] && env_args+=("RUSTFLAGS=${RUSTFLAGS}")
  [ -n "${CARGO_INCREMENTAL:-}" ] && env_args+=("CARGO_INCREMENTAL=${CARGO_INCREMENTAL}")
  [ -n "${CARGO_NET_GIT_FETCH_WITH_CLI:-}" ] && env_args+=("CARGO_NET_GIT_FETCH_WITH_CLI=${CARGO_NET_GIT_FETCH_WITH_CLI}")
  [ -n "${CARGO_PROFILE_RELEASE_DEBUG:-}" ] && env_args+=("CARGO_PROFILE_RELEASE_DEBUG=${CARGO_PROFILE_RELEASE_DEBUG}")

  log_info "Compiling $label (-j$jobs)"
  if env ${env_args[@]+"${env_args[@]}"} make "$target" -j"$jobs" V=s >"$logfile" 2>&1; then
    rm -f "$logfile"; return 0
  fi

  if [ "$fallback_jobs" -lt "$jobs" ]; then
    log_warn "Parallel build failed for $label, retrying with -j${fallback_jobs}"
    if env ${env_args[@]+"${env_args[@]}"} make "$target" -j"$fallback_jobs" V=s >"$logfile" 2>&1; then
      rm -f "$logfile"; return 0
    fi
  fi

  log_warn "Retrying single-threaded for $label"
  if env ${env_args[@]+"${env_args[@]}"} make "$target" -j1 V=s >"$logfile" 2>&1; then
    rm -f "$logfile"; return 0
  fi

  log_error "Build failed: $label"
  tail -50 "$logfile" 2>/dev/null || true
  rm -f "$logfile"; return 1
}

# ── 磁盘空间检查 / Disk check ──
check_disk_space() {
  local min_gb="${1:-10}"
  local avail_gb=$(( $(df / --output=avail | tail -1 | tr -d ' ') / 1024 / 1024 ))
  if [ "$avail_gb" -lt "$min_gb" ]; then
    die "Disk space low: ${avail_gb}GB < ${min_gb}GB required"
  fi
  log_info "Disk: ${avail_gb}GB available"
}

path_available_gb() {
  local path="$1"
  [ -e "$path" ] || mkdir -p "$path"
  df -Pk "$path" | awk 'NR==2 {print int($4 / 1024 / 1024)}'
}

choose_temp_root() {
  local min_gb="${1:-4}"
  shift || true
  local candidate avail_gb

  for candidate in "$@"; do
    [ -n "${candidate:-}" ] || continue
    mkdir -p "$candidate" 2>/dev/null || continue
    avail_gb=$(path_available_gb "$candidate" 2>/dev/null || echo 0)
    if [ "${avail_gb:-0}" -ge "$min_gb" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

make_managed_tempdir() {
  local prefix="$1"
  shift
  local root
  root=$(choose_temp_root 4 "$@") || die "Cannot find temp root with enough free space"
  mktemp -d "$root/${prefix}.XXXXXX"
}

# ── GitHub Actions 辅助 / GitHub Actions helpers ──
gh_set_env() {
  export "$1=$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "$1=$2" >> "$GITHUB_ENV"
  fi
  return 0
}

gh_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
  return 0
}

# ── 配置加载 / Load KEY=VALUE config into environment ──
load_env_config() {
  local config_file="$1"
  [ -f "$config_file" ] || die "Config file not found: $config_file"

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
  done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$config_file")

  return 0
}

config_default() {
  local key="$1" default_value="$2"
  if [ -z "${!key:-}" ]; then
    export "$key=$default_value"
    [ -n "${GITHUB_ENV:-}" ] && printf '%s=%s\n' "$key" "$default_value" >> "$GITHUB_ENV"
  fi
}

# ── GitHub release tag 解析 / Resolve latest GitHub release tag ──
resolve_latest_github_release_tag() {
  local owner="$1" repo="$2"
  curl -fsSL --retry 3 --retry-delay 10 "https://api.github.com/repos/${owner}/${repo}/releases/latest" \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("tag_name") or "").strip())'
}

sed_escape_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

# ── PassWall 源目录映射 / PassWall source directory mapping ──
# Maps a package name to its source directory inside the SDK tree.
# Must be called with cwd = SDK root.
map_passwall_source_dir() {
  local pkg="$1"
  case "$pkg" in
    shadowsocks-libev-*) echo "package/passwall-packages/shadowsocks-libev" ;;
    shadowsocks-rust-*) echo "package/passwall-packages/shadowsocks-rust" ;;
    shadowsocksr-libev-*) echo "package/passwall-packages/shadowsocksr-libev" ;;
    simple-obfs-*) echo "package/passwall-packages/simple-obfs" ;;
    v2ray-geoip|v2ray-geosite) echo "package/passwall-packages/v2ray-geodata" ;;
    luci-app-passwall|luci-i18n-passwall-zh-cn) echo "package/passwall-luci/luci-app-passwall" ;;
    *)
      [ -d "package/passwall-packages/$pkg" ] && echo "package/passwall-packages/$pkg" || return 1
      ;;
  esac
}

# ── APK 文件查找 / Find APK file by package name ──
# Finds the APK file for a given package name in a directory.
find_pkg_file() {
  local dir="$1" pkg="$2"
  find "$dir" -type f \( -name "${pkg}-[0-9]*.apk" -o -name "${pkg}_[0-9]*.apk" \) \
    | LC_ALL=C sort | head -n 1
}

payload_pkg_candidates() {
  local pkg="$1"
  case "$pkg" in
    nftables)
      printf '%s\n' nftables nftables-nojson nftables-json
      ;;
    *)
      printf '%s\n' "$pkg"
      ;;
  esac
}

find_payload_pkg_file() {
  local dir="$1" pkg="$2" candidate pkg_file
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    pkg_file=$(find_pkg_file "$dir" "$candidate" || true)
    if [ -n "$pkg_file" ]; then
      printf '%s\n' "$pkg_file"
      return 0
    fi
  done < <(payload_pkg_candidates "$pkg")
  return 1
}

# ── Git tag 解析 / Resolve a remote Git tag from candidate names ──
resolve_remote_tag() {
  local repo_url="$1"
  shift
  local candidate
  for candidate in "$@"; do
    [ -n "$candidate" ] || continue
    if git ls-remote --exit-code --refs --tags "$repo_url" "refs/tags/$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# ── Git 默认分支解析 / Resolve a remote repository default branch ──
resolve_remote_default_branch() {
  local repo_url="$1"
  git ls-remote --symref "$repo_url" HEAD 2>/dev/null \
    | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}'
}

# ── SHA256 清单 / Generate SHA256 manifest for a directory tree ──
generate_sha256_manifest() {
  local dir="$1" manifest="${2:-SHA256SUMS}"
  (
    cd "$dir"
    find . -type f ! -name "$manifest" -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum > "$manifest"
  )
}

# ── 可恢复校验下载 / Verified download with resume support ──
download_verified_file() {
  local dest_dir="$1" filename="$2" expected_sha256="$3"
  shift 3
  local dest_path partial_path url actual_sha256

  [ -n "$dest_dir" ] || die "download_verified_file requires dest_dir"
  [ -n "$filename" ] || die "download_verified_file requires filename"
  [ -n "$expected_sha256" ] || die "download_verified_file requires expected_sha256"
  [ "$#" -gt 0 ] || die "download_verified_file requires at least one URL"

  mkdir -p "$dest_dir"
  dest_path="$dest_dir/$filename"
  partial_path="${dest_path}.dl"

  if [ -f "$dest_path" ]; then
    actual_sha256=$(sha256sum "$dest_path" | awk '{print $1}')
    if [ "$actual_sha256" = "$expected_sha256" ]; then
      log_info "Using cached verified file: $filename"
      return 0
    fi
    log_warn "Cached file hash mismatch for $filename; re-downloading"
    rm -f "$dest_path"
  fi

  for url in "$@"; do
    [ -n "$url" ] || continue
    log_info "Downloading $filename from $url"
    if retry 3 10 curl -fL --connect-timeout 10 --retry 3 --retry-delay 5 --retry-all-errors \
      --continue-at - --output "$partial_path" "$url"; then
      actual_sha256=$(sha256sum "$partial_path" | awk '{print $1}')
      if [ "$actual_sha256" = "$expected_sha256" ]; then
        mv "$partial_path" "$dest_path"
        log_info "Verified download: $filename"
        return 0
      fi
      log_warn "Hash mismatch for $filename from $url"
      rm -f "$partial_path"
    fi
  done

  die "Failed to download verified file: $filename"
}

# ── APK 版本规格 / Derive pinned "pkg=version" spec from APK filename ──
local_pkg_spec() {
  local dir="$1" pkg="$2" pkg_file version
  pkg_file=$(find_pkg_file "$dir" "$pkg" || true)
  [ -n "$pkg_file" ] || return 1
  version=$(basename "$pkg_file")
  version="${version%.apk}"
  version="${version#${pkg}-}"
  version="${version#${pkg}_}"
  [ -n "$version" ] || return 1
  printf '%s=%s\n' "$pkg" "$version"
}
