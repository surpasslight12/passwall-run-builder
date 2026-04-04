#!/usr/bin/env bash
# Shared helper library for PassWall workflow and build scripts.

log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '::warning::%s\n' "$*"; }
log_error() { printf '::error::%s\n' "$*"; }
die()       { log_error "$@"; exit 1; }

group_start() { printf '::group::%s\n' "$*"; }
group_end()   { printf '::endgroup::\n'; }

_STEP_NAME=""
_STEP_T0=""
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

  local duration=$(( $(date +%s) - _STEP_T0 ))
  log_info "── $_STEP_NAME done (${duration}s) ──"
  _STEP_NAME=""
  _STEP_T0=""
}

retry() {
  local max_attempts="$1" delay_seconds="$2"
  shift 2

  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    log_info "Attempt $attempt/$max_attempts: $*"
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -eq "$max_attempts" ]; then
      log_error "Failed after $max_attempts attempts: $*"
      return 1
    fi
    log_warn "Attempt $attempt failed, retrying in ${delay_seconds}s…"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1"
}

trim_tag() {
  printf '%s\n' "${1#v}"
}

make_pkg() {
  local target="$1" label="${2:-$1}"
  local jobs fallback_jobs logfile
  jobs=$(nproc)
  fallback_jobs=$((jobs / 2))
  [ "$fallback_jobs" -lt 1 ] && fallback_jobs=1
  logfile="/tmp/build-pkg-${label//\//_}-$$.log"

  local env_args=()
  [ -n "${RUSTFLAGS:-}" ] && env_args+=("RUSTFLAGS=${RUSTFLAGS}")
  [ -n "${CARGO_INCREMENTAL:-}" ] && env_args+=("CARGO_INCREMENTAL=${CARGO_INCREMENTAL}")
  [ -n "${CARGO_NET_GIT_FETCH_WITH_CLI:-}" ] && env_args+=("CARGO_NET_GIT_FETCH_WITH_CLI=${CARGO_NET_GIT_FETCH_WITH_CLI}")
  [ -n "${CARGO_PROFILE_RELEASE_DEBUG:-}" ] && env_args+=("CARGO_PROFILE_RELEASE_DEBUG=${CARGO_PROFILE_RELEASE_DEBUG}")

  log_info "Compiling $label (-j$jobs)"
  if env ${env_args[@]+"${env_args[@]}"} make "$target" -j"$jobs" V=s >"$logfile" 2>&1; then
    rm -f "$logfile"
    return 0
  fi

  if [ "$fallback_jobs" -lt "$jobs" ]; then
    log_warn "Parallel build failed for $label, retrying with -j${fallback_jobs}"
    if env ${env_args[@]+"${env_args[@]}"} make "$target" -j"$fallback_jobs" V=s >"$logfile" 2>&1; then
      rm -f "$logfile"
      return 0
    fi
  fi

  log_warn "Retrying single-threaded for $label"
  if env ${env_args[@]+"${env_args[@]}"} make "$target" -j1 V=s >"$logfile" 2>&1; then
    rm -f "$logfile"
    return 0
  fi

  log_error "Build failed: $label"
  tail -50 "$logfile" 2>/dev/null || true
  rm -f "$logfile"
  return 1
}

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

gh_set_env() {
  export "$1=$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
  fi
}

gh_summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

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
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf '%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
    fi
  done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$config_file")
}

config_default() {
  local key="$1" default_value="$2"
  if [ -z "${!key:-}" ]; then
    export "$key=$default_value"
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf '%s=%s\n' "$key" "$default_value" >> "$GITHUB_ENV"
    fi
  fi
}

resolve_latest_github_release_tag() {
  local owner="$1" repo="$2"
  curl -fsSL --retry 3 --retry-delay 10 "https://api.github.com/repos/${owner}/${repo}/releases/latest" \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("tag_name") or "").strip())'
}

sed_escape_replacement() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

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

apk_package_name_from_file() {
  local apk_file="$1" apk_base pkg_name
  apk_base=$(basename "$apk_file")
  case "$apk_base" in
    *.apk) ;;
    *) return 1 ;;
  esac
  pkg_name=$(printf '%s\n' "$apk_base" | sed -E 's/[-_][0-9].*\.apk$//')
  [ -n "$pkg_name" ] || return 1
  printf '%s\n' "$pkg_name"
}

prefer_newer_file_by_basename() {
  local current_file="$1" candidate_file="$2"
  local current_base candidate_base preferred_base

  [ -n "$current_file" ] || {
    printf '%s\n' "$candidate_file"
    return 0
  }
  [ -n "$candidate_file" ] || {
    printf '%s\n' "$current_file"
    return 0
  }

  current_base=$(basename "$current_file")
  candidate_base=$(basename "$candidate_file")
  preferred_base=$(printf '%s\n%s\n' "$current_base" "$candidate_base" | LC_ALL=C sort -V | tail -n 1)
  if [ "$preferred_base" = "$candidate_base" ]; then
    printf '%s\n' "$candidate_file"
  else
    printf '%s\n' "$current_file"
  fi
}

find_pkg_file() {
  local dir="$1" pkg="$2" candidate_file best_file=""
  while IFS= read -r -d '' candidate_file; do
    best_file=$(prefer_newer_file_by_basename "$best_file" "$candidate_file")
  done < <(find "$dir" -type f \( -name "${pkg}-[0-9]*.apk" -o -name "${pkg}_[0-9]*.apk" \) -print0)

  [ -n "$best_file" ] && printf '%s\n' "$best_file"
}

payload_pkg_candidates() {
  local pkg="$1"
  case "$pkg" in
    nftables)
      printf '%s\n' nftables nftables-json nftables-nojson
      ;;
    hysteria|hysteria2|hy2)
      printf '%s\n' hysteria hysteria2 hy2
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

generate_sha256_manifest() {
  local dir="$1" manifest="${2:-SHA256SUMS}"
  (
    cd "$dir"
    find . -type f ! -name "$manifest" -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum > "$manifest"
  )
}

count_file_lines() {
  local file="$1"
  [ -f "$file" ] || {
    printf '0\n'
    return 0
  }
  awk 'END { print NR + 0 }' "$file"
}

summary_append_line() {
  local var_name="$1" line="$2"
  printf -v "$var_name" '%s%s\n' "${!var_name:-}" "$line"
}

build_payload_dependency_summary() {
  local requested_root_count="$1" resolved_apk_count="$2" dependency_apk_count="$3"
  local whitelist_file="$4" missing_local_count="$5" official_fallback_count="$6"
  local whitelist_count summary

  whitelist_count=$(count_file_lines "$whitelist_file")
  summary=""
  summary_append_line summary "## Payload Dependency Closure"
  summary_append_line summary "- Requested root packages: $requested_root_count"
  summary_append_line summary "- Resolved APK set: $resolved_apk_count"
  summary_append_line summary "- Collected dependency APKs: $dependency_apk_count"
  summary_append_line summary "- Installer whitelist packages: $whitelist_count"
  summary_append_line summary "- Missing locally built requested APKs: $missing_local_count"
  summary_append_line summary "- Official fallback roots: $official_fallback_count"
  printf '%s' "$summary"
}

payload_apk_dir_name() {
  printf '%s\n' "apks"
}

payload_metadata_dir_name() {
  printf '%s\n' "metadata"
}

payload_toplevel_packages_name() {
  printf '%s\n' "$(payload_metadata_dir_name)/TOPLEVEL_PACKAGES"
}

payload_install_whitelist_name() {
  printf '%s\n' "$(payload_metadata_dir_name)/INSTALL_WHITELIST"
}

payload_package_manifest_name() {
  printf '%s\n' "$(payload_metadata_dir_name)/PAYLOAD_APK_MAP"
}

payload_repo_index_name() {
  printf '%s\n' "$(payload_apk_dir_name)/packages.adb"
}

write_payload_package_manifest() {
  local payload_dir="$1"
  local apk_rel_dir="${2:-$(payload_apk_dir_name)}"
  local manifest_rel_path="${3:-$(payload_package_manifest_name)}"
  local apk_dir manifest_path apk_file rel_path pkg_name current_path preferred_path
  declare -A pkg_paths=()

  apk_dir="$payload_dir/$apk_rel_dir"
  manifest_path="$payload_dir/$manifest_rel_path"
  [ -d "$apk_dir" ] || die "Payload APK directory missing for manifest: $apk_dir"
  mkdir -p "$(dirname "$manifest_path")"

  while IFS= read -r -d '' apk_file; do
    rel_path="${apk_file#"$payload_dir"/}"
    pkg_name=$(apk_package_name_from_file "$apk_file" || true)
    [ -n "$pkg_name" ] || continue

    current_path="${pkg_paths[$pkg_name]:-}"
    if [ -n "$current_path" ]; then
      preferred_path=$(prefer_newer_file_by_basename "$payload_dir/$current_path" "$apk_file")
      [ "$preferred_path" = "$apk_file" ] || continue
    fi
    pkg_paths["$pkg_name"]="$rel_path"
  done < <(find "$apk_dir" -maxdepth 1 -type f -name '*.apk' -print0)

  : > "$manifest_path"
  while IFS= read -r pkg_name; do
    [ -n "$pkg_name" ] || continue
    printf '%s|%s\n' "$pkg_name" "${pkg_paths[$pkg_name]}" >> "$manifest_path"
  done < <(printf '%s\n' "${!pkg_paths[@]}" | LC_ALL=C sort)

  [ -s "$manifest_path" ] || die "Payload package manifest is empty: $manifest_path"
}

write_mock_apk_stub() {
  local mock_apk="$1"
  cat > "$mock_apk" <<'MOCKAPK'
#!/bin/sh
printf '%s\n' "$*" >> "${APK_INVOCATIONS_LOG:?}"
case "$1" in
  info)
    case "${3:-}" in
      dnsmasq|dnsmasq-dhcpv6)
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  list|del)
    exit 0
    ;;
  add)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --allow-untrusted|--force-reinstall|--force-refresh|--no-cache|--no-interactive)
          shift
          ;;
        --repositories-file|--arch|--repository)
          [ "$#" -ge 2 ] || exit 9
          shift 2
          ;;
        --repositories-file=*|--arch=*|--repository=*)
          shift
          ;;
        --*)
          shift
          ;;
        *)
          break
          ;;
      esac
    done

    if [ "${APK_MOCK_REQUIRE_APK_FILES:-0}" = "1" ]; then
      [ "$#" -gt 0 ] || exit 10
      for install_target in "$@"; do
        case "$install_target" in
          *.apk)
            ;;
          *)
            printf 'expected explicit apk payload target, got: %s\n' "$install_target" >&2
            exit 11
            ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
MOCKAPK
  chmod +x "$mock_apk"
}

run_mocked_installer() {
  local payload_dir="$1" install_log="$2" apk_invocations="$3" mockbin="$4"
  local -a shell_cmd
  local shell_label

  mkdir -p "$mockbin"
  : > "$install_log"
  : > "$apk_invocations"
  write_mock_apk_stub "$mockbin/apk"

  if command -v busybox >/dev/null 2>&1; then
    shell_cmd=(busybox sh)
  else
    shell_cmd=(sh)
  fi
  shell_label="${shell_cmd[*]}"

  (
    cd "$payload_dir" || exit 1
    printf '[INFO]  Smoke shell: %s\n' "$shell_label"
    env \
      APK_INVOCATIONS_LOG="$apk_invocations" \
      APK_MOCK_REQUIRE_APK_FILES=1 \
      PATH="$mockbin:$PATH" \
      "${shell_cmd[@]}" ./install.sh
  ) >"$install_log" 2>&1
}

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

resolve_remote_default_branch() {
  local repo_url="$1"
  git ls-remote --symref "$repo_url" HEAD 2>/dev/null \
    | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}'
}

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