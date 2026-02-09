#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install-toolchains.sh — 安装或更新 Go 和 Rust 工具链
# install-toolchains.sh — Install / upgrade Go and Rust toolchains
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Go ──────────────────────────────────────────────────────────────────────
group_start "Installing Go"

GO_VERSION=""
fetch_go_version() {
  GO_VERSION=$(curl -sf https://go.dev/VERSION?m=text 2>/dev/null | head -1 | sed 's/go//')
  [ -n "$GO_VERSION" ]
}
retry 3 10 60 "Fetch Go version" fetch_go_version \
  || die "Failed to fetch latest Go version"
log_info "Latest Go: $GO_VERSION"

NEED_GO=true
if command -v go >/dev/null 2>&1; then
  CUR=$(go version | awk '{print $3}' | sed 's/go//')
  if [ "$CUR" = "$GO_VERSION" ]; then
    log_info "Go $CUR already up-to-date"; NEED_GO=false
  else
    log_info "Upgrading Go: $CUR → $GO_VERSION"
  fi
fi

if [ "$NEED_GO" = true ]; then
  TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"
  retry 3 20 120 "Download Go" "wget -q 'https://go.dev/dl/${TARBALL}' -O '/tmp/${TARBALL}'"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "/tmp/${TARBALL}"
  rm -f "/tmp/${TARBALL}"
  [ -n "${GITHUB_PATH:-}" ] && echo "/usr/local/go/bin" >> "$GITHUB_PATH"
  export PATH="/usr/local/go/bin:$PATH"
  /usr/local/go/bin/go version || die "Go installation verification failed"
  log_info "Go $GO_VERSION installed"
fi
group_end

# ── Rust ────────────────────────────────────────────────────────────────────
group_start "Installing Rust"

NEED_RUST=true
if command -v rustc >/dev/null 2>&1; then
  log_info "Rust installed: $(rustc --version | awk '{print $2}')"
  [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
  [ -n "${GITHUB_PATH:-}" ] && echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
  if rustup target list --installed | grep -q x86_64-unknown-linux-musl; then
    log_info "musl target already present"; NEED_RUST=false
  else
    rustup target add x86_64-unknown-linux-musl; NEED_RUST=false
  fi
fi

if [ "$NEED_RUST" = true ]; then
  log_info "Installing Rust…"
  retry 3 20 120 "Install rustup" \
    "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable"
  source "$HOME/.cargo/env"
  [ -n "${GITHUB_PATH:-}" ] && echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"
  rustup target add x86_64-unknown-linux-musl
  rustc --version && cargo --version || die "Rust verification failed"
  log_info "Rust installed"
fi
group_end
