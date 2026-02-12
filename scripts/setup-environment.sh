#!/usr/bin/env bash
# setup-environment.sh — 释放磁盘空间、安装构建依赖
# Free disk space and install build dependencies
source "$(dirname "$0")/lib.sh"

step_start "Setup environment"
export DEBIAN_FRONTEND=noninteractive

group_start "Free disk space"
log_info "Before cleanup: $(df -h / --output=avail | tail -1 | tr -d ' ')"

sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
  /opt/hostedtoolcache/CodeQL /usr/local/share/powershell \
  /usr/share/swift /usr/local/.ghcup 2>/dev/null || true

sudo docker image prune -af 2>/dev/null || true
sudo apt-get clean 2>/dev/null || true

log_info "After cleanup: $(df -h / --output=avail | tail -1 | tr -d ' ')"
group_end

group_start "Install build dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential libncurses5-dev gawk gettext unzip file \
  libssl-dev wget python3 git ca-certificates makeself zstd \
  || die "apt-get install failed"
log_info "Build dependencies installed"
group_end

step_end
