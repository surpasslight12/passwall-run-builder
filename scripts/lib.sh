#!/usr/bin/env bash
# Shared helper functions for the PassWall build pipeline.
# Source this file at the top of every script:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"

set -euo pipefail

# ── Logging ─────────────────────────────────────────────────────────────────

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info()    { echo "[$(_ts)] [INFO] $*"; }
log_warning() { echo "::warning::[$(_ts)] $*"; }
log_error()   { echo "::error::[$(_ts)] $*"; }
group_start() { echo "::group::$*"; }
group_end()   { echo "::endgroup::"; }

# ── Retry with exponential back-off ─────────────────────────────────────────
# Usage: retry <max> <initial_delay> <max_delay> <label> <command…>
retry() {
  local max=${1:-3} delay=${2:-5} max_delay=${3:-300} label=${4:-"op"}
  shift 4
  local attempt=1
  while [ "$attempt" -le "$max" ]; do
    log_info "Attempt $attempt/$max: $label"
    if eval "$*"; then
      log_info "$label succeeded (attempt $attempt)"
      return 0
    fi
    if [ "$attempt" -eq "$max" ]; then
      log_error "$label failed after $max attempts"
      return 1
    fi
    log_warning "Attempt $attempt failed, retrying in ${delay}s…"
    sleep "$delay"
    delay=$(( delay * 2 ))
    [ "$delay" -gt "$max_delay" ] && delay=$max_delay
    attempt=$(( attempt + 1 ))
  done
}

# ── Make helper: parallel first, then single-threaded fallback ──────────────
# Usage: make_with_retry <target> [label]
make_with_retry() {
  local target="$1" label="${2:-$1}"
  local nproc; nproc=$(nproc)
  local log="/tmp/build-${label//\//_}.log"
  local t0; t0=$(date +%s)

  if make "$target" -j"$nproc" V=s 2>&1 | tee "$log"; then
    log_info "Built $label (parallel, $(( $(date +%s) - t0 ))s)"
    rm -f "$log"; return 0
  fi

  log_warning "Parallel build failed for $label, retrying single-threaded…"
  tail -30 "$log" 2>/dev/null || true

  if make "$target" V=s 2>&1 | tee "$log"; then
    log_info "Built $label (single-threaded, $(( $(date +%s) - t0 ))s)"
    rm -f "$log"; return 0
  fi

  log_error "Build failed: $label ($(( $(date +%s) - t0 ))s)"
  tail -50 "$log" 2>/dev/null || true
  rm -f "$log"; return 1
}

# ── Version extraction from APK filename ────────────────────────────────────
# $1 - filename  $2 - package-name prefix to strip
extract_version() {
  local base; base=$(basename "$1")
  local prefix="$2"
  base="${base%.apk}"
  if [ -n "$prefix" ]; then
    base="${base#"${prefix}"}"
    base="${base#-}"; base="${base#_}"
  fi
  # Strip architecture suffix
  if printf "%s" "$base" | grep -q '_all$'; then
    base="${base%_all}"
  elif printf "%s" "$base" | grep -q -- '-all$'; then
    base="${base%-all}"
  elif printf "%s" "$base" | grep -q '_[^_]*$'; then
    base="$(printf "%s" "$base" | sed -E 's/_[^_]+$//')"
  fi
  echo "$base"
}

# ── Append to $GITHUB_ENV (no-op outside Actions) ──────────────────────────
gh_env() {
  local line="$1"
  export "${line?}"
  [ -n "${GITHUB_ENV:-}" ] && echo "$line" >> "$GITHUB_ENV"
}

# ── Append to $GITHUB_OUTPUT ────────────────────────────────────────────────
gh_output() {
  local line="$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$line" >> "$GITHUB_OUTPUT"
}
