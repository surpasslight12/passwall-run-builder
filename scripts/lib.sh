#!/usr/bin/env bash
# lib.sh — 公共函数库 / Shared helper library
# Usage: source "$(dirname "$0")/lib.sh"

set -euo pipefail

trap 'rm -f /tmp/build-*.log 2>/dev/null' EXIT

# ── 日志 / Logging ──
log_info()  { printf '[INFO]  %s\n' "$*"; }
log_warn()  { printf '::warning::%s\n' "$*"; }
log_error() { printf '::error::%s\n' "$*"; }
die()       { log_error "$@"; exit 1; }

group_start() { echo "::group::$*"; }
group_end()   { echo "::endgroup::"; }

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
# Usage: make_pkg <target> [label] [timeout_minutes]
make_pkg() {
  local target="$1" label="${2:-$1}" timeout_min="${3:-60}"
  local jobs; jobs=$(nproc)
  local logfile="/tmp/build-${label//\//_}-$$.log"
  local timeout_sec exit_code

  # Validate timeout
  if ! [[ "$timeout_min" =~ ^[0-9]+$ ]] || [ "$timeout_min" -le 0 ]; then
    log_error "Invalid timeout: $timeout_min (must be positive integer)"
    return 1
  fi
  timeout_sec=$((timeout_min * 60))

  log_info "Compiling $label (-j$jobs, timeout: ${timeout_min}m)"
  timeout "$timeout_sec" make "$target" -j"$jobs" V=s >"$logfile" 2>&1
  exit_code=$?
  if [ $exit_code -eq 0 ]; then
    rm -f "$logfile"; return 0
  elif [ $exit_code -eq 124 ]; then
    log_error "Build timeout: $label (exceeded ${timeout_min}m)"
    rm -f "$logfile"; return 1
  fi

  log_warn "Parallel build failed for $label, retrying single-threaded"
  timeout "$timeout_sec" make "$target" -j1 V=s >"$logfile" 2>&1
  exit_code=$?
  if [ $exit_code -eq 0 ]; then
    rm -f "$logfile"; return 0
  elif [ $exit_code -eq 124 ]; then
    log_error "Build timeout: $label (exceeded ${timeout_min}m)"
    rm -f "$logfile"; return 1
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

# ── GitHub Actions 辅助 / GitHub Actions helpers ──
gh_set_env() {
  export "$1=$2"
  [ -n "${GITHUB_ENV:-}" ] && echo "$1=$2" >> "$GITHUB_ENV"
}

gh_set_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"
}

gh_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}
