#!/usr/bin/env bash
# Free disk space and install build dependencies.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export DEBIAN_FRONTEND=noninteractive

# ── Free disk space ─────────────────────────────────────────────────────────
group_start "Freeing disk space"
log_info "Disk before cleanup: $(df -h / --output=avail | tail -1 | tr -d ' ')"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
  /opt/hostedtoolcache/CodeQL /usr/local/share/powershell \
  /usr/share/swift /usr/local/.ghcup 2>/dev/null || true
sudo docker image prune --all --force 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true

log_info "Disk after cleanup: $(df -h / --output=avail | tail -1 | tr -d ' ')"
group_end

# ── Install system packages ─────────────────────────────────────────────────
group_start "Installing build dependencies"
sudo apt-get update || log_warning "apt-get update had issues, continuing…"

PACKAGES=(
  build-essential libncurses5-dev gawk gettext unzip file
  libssl-dev wget python3 git ca-certificates makeself zstd
)
if ! sudo apt-get install -y "${PACKAGES[@]}"; then
  log_error "Failed to install build dependencies"
  exit 1
fi
log_info "Build dependencies installed"
group_end
