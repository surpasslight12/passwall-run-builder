#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# lib.sh — 构建流水线公共函数库
# lib.sh — Shared helper functions for the build pipeline
#
# 使用方法 / Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── 临时文件清理 / Temp file cleanup ────────────────────────────────────────
cleanup() { rm -f /tmp/build-*.log 2>/dev/null || true; }
trap cleanup EXIT

# ── 日志函数 / Logging ──────────────────────────────────────────────────────
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info()    { echo "[$(_ts)] [INFO]    $*"; }
log_warning() { echo "::warning::[$(_ts)] $*"; }
log_error()   { echo "::error::[$(_ts)] $*"; }

# 致命错误：输出日志后立即退出
# Fatal error: log and exit immediately
die() { log_error "$@"; exit 1; }

group_start() { echo "::group::$*"; }
group_end()   { echo "::endgroup::"; }

# ── 带指数退避的重试 / Retry with exponential back-off ──────────────────────
# Usage: retry <max> <initial_delay> <max_delay> <label> <command…>
retry() {
  local max=${1:-3} delay=${2:-5} max_delay=${3:-300} label=${4:-"op"}
  shift 4
  local attempt=1
  while [ "$attempt" -le "$max" ]; do
    log_info "Attempt $attempt/$max — $label"
    if eval "$*"; then
      log_info "$label succeeded (attempt $attempt)"
      return 0
    fi
    [ "$attempt" -eq "$max" ] && { log_error "$label failed after $max attempts"; return 1; }
    log_warning "Attempt $attempt failed, retrying in ${delay}s…"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2 > max_delay ? max_delay : delay * 2))
  done
  return 1
}

# ── Make 构建助手：先并行，失败后单线程重试 / Make helper ───────────────────
# Usage: make_with_retry <target> [label] [timeout_minutes]
make_with_retry() {
  local target="$1" label="${2:-$1}" timeout_min="${3:-60}"
  local jobs; jobs=$(nproc)
  local log="/tmp/build-${label//\//_}-$$.log"
  local t0; t0=$(date +%s)
  local timeout_sec=$((timeout_min * 60))

  log_info "Building $label (timeout ${timeout_min}m, jobs $jobs)"

  # 第一次：并行构建 / First try: parallel build
  if timeout "$timeout_sec" make "$target" -j"$jobs" V=s 2>&1 | tee "$log"; then
    log_info "Built $label — parallel, $(($(date +%s) - t0))s"
    rm -f "$log"; return 0
  fi
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    log_error "Build timeout (${timeout_min}m): $label"
    tail -50 "$log" 2>/dev/null || true; rm -f "$log"; return 1
  fi

  # 第二次：单线程重试 / Second try: single-threaded fallback
  log_warning "Parallel build failed for $label, retrying single-threaded…"
  tail -30 "$log" 2>/dev/null || true
  if timeout "$timeout_sec" make "$target" V=s 2>&1 | tee "$log"; then
    log_info "Built $label — single-threaded, $(($(date +%s) - t0))s"
    rm -f "$log"; return 0
  fi
  rc=$?
  [ "$rc" -eq 124 ] \
    && log_error "Build timeout (${timeout_min}m, single-threaded): $label" \
    || log_error "Build failed: $label ($(($(date +%s) - t0))s)"
  tail -50 "$log" 2>/dev/null || true; rm -f "$log"; return 1
}

# ── APK 版本号提取 / Extract version from APK filename ──────────────────────
# $1 — 文件名 filename   $2 — 包名前缀 package-name prefix
extract_version() {
  local base; base=$(basename "$1")
  local prefix="$2"
  base="${base%.apk}"
  if [ -n "$prefix" ]; then
    base="${base#"${prefix}"}"; base="${base#-}"; base="${base#_}"
  fi
  # 去除架构后缀 / Strip architecture suffix
  if printf '%s' "$base" | grep -q '_all$'; then
    base="${base%_all}"
  elif printf '%s' "$base" | grep -q -- '-all$'; then
    base="${base%-all}"
  elif printf '%s' "$base" | grep -q '_[^_]*$'; then
    base="$(printf '%s' "$base" | sed -E 's/_[^_]+$//')"
  fi
  echo "$base"
}

# ── 磁盘空间检查 / Disk space check ────────────────────────────────────────
# Usage: check_disk_space [min_gb]
check_disk_space() {
  local min_gb="${1:-10}"
  local avail_kb; avail_kb=$(df / --output=avail | tail -1 | tr -d ' ')
  local avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt "$min_gb" ]; then
    log_error "Disk space low: ${avail_gb}GB available (need ${min_gb}GB)"
    return 1
  fi
  log_info "Disk space: ${avail_gb}GB available"
}

# ── GitHub Actions 环境变量写入 / GitHub Actions env helpers ────────────────
gh_env() {
  local line="$1"
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=.+ ]] || { log_warning "Malformed env: $line"; return 1; }
  export "${line?}"
  [ -n "${GITHUB_ENV:-}" ] && echo "$line" >> "$GITHUB_ENV"
}

gh_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"
}

# ── Step summary 追加 / Append to GitHub step summary ───────────────────────
gh_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$1" >> "$GITHUB_STEP_SUMMARY"
}
