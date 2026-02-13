#!/usr/bin/env bash
# install-toolchains.sh — 安装 Go 和 Rust 工具链
# Install Go and Rust toolchains
source "$(dirname "$0")/lib.sh"

step_start "Install toolchains"

# ── Go ──
group_start "Install Go"

GO_VER=$(retry 3 10 bash -c 'curl -sf https://go.dev/VERSION?m=text | head -1' | sed 's/go//')
[ -n "$GO_VER" ] || die "Cannot fetch Go version"

CURRENT_GO=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
if [ "$CURRENT_GO" = "$GO_VER" ]; then
  log_info "Go $GO_VER already installed"
else
  log_info "Installing Go $GO_VER"
  TARBALL="go${GO_VER}.linux-amd64.tar.gz"
  retry 3 20 wget -q "https://go.dev/dl/${TARBALL}" -O "/tmp/${TARBALL}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "/tmp/${TARBALL}"
  rm -f "/tmp/${TARBALL}"
  export PATH="/usr/local/go/bin:$PATH"
  [ -n "${GITHUB_PATH:-}" ] && echo "/usr/local/go/bin" >> "$GITHUB_PATH"
fi

go version || die "Go verification failed"
group_end

# ── Rust ──
group_start "Install Rust"

if command -v rustc >/dev/null 2>&1; then
  log_info "Rust $(rustc --version | awk '{print $2}') already installed"
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
else
  log_info "Installing Rust"
  retry 3 20 bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable"
  source "$HOME/.cargo/env"
fi

[ -n "${GITHUB_PATH:-}" ] && echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
rustup target list --installed | grep -q x86_64-unknown-linux-musl \
  || rustup target add x86_64-unknown-linux-musl
rustc --version || die "Rust verification failed"
cargo --version || die "Cargo verification failed"

# 安装 sccache 用于加速 Rust 编译 / Install sccache for faster Rust builds
if ! command -v sccache >/dev/null 2>&1; then
  log_info "Installing sccache"
  # 最多 3 次尝试，每次间隔 20 秒 / Up to 3 attempts with 20s delay
  retry 3 20 cargo install sccache --locked
else
  log_info "sccache already installed: $(sccache --version)"
fi

group_end

step_end
