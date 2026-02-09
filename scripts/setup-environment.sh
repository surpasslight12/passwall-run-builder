#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-environment.sh — 释放磁盘空间并安装构建依赖
# setup-environment.sh — Free disk space and install build dependencies
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export DEBIAN_FRONTEND=noninteractive

# ── 释放磁盘空间 / Free disk space ─────────────────────────────────────────
group_start "Freeing disk space"
log_info "Disk before cleanup: $(df -h / --output=avail | tail -1 | tr -d ' ')"

sudo rm -rf \
  /usr/share/dotnet \
  /usr/local/lib/android \
  /opt/ghc \
  /opt/hostedtoolcache/CodeQL \
  /usr/local/share/powershell \
  /usr/share/swift \
  /usr/local/.ghcup \
  2>/dev/null || true

sudo docker image prune --all --force 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true

log_info "Disk after cleanup: $(df -h / --output=avail | tail -1 | tr -d ' ')"
group_end

# ── 安装系统依赖 / Install build dependencies ──────────────────────────────
group_start "Installing build dependencies"
sudo apt-get update || log_warning "apt-get update had issues, continuing…"

PACKAGES=(
  build-essential libncurses5-dev gawk gettext unzip file
  libssl-dev wget python3 git ca-certificates makeself zstd
)
sudo apt-get install -y "${PACKAGES[@]}" \
  || die "Failed to install build dependencies"

log_info "Build dependencies installed"
group_end
