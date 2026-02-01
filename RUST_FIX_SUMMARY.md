# Rust 环境问题修复总结

## 问题描述

用户要求：检查最新的action日志，查看编译时rust环境的问题

## 调查过程

### 1. 查看最新的 GitHub Actions 日志

检查了最新的成功构建日志 (Run ID: 21564051125, 2026-02-01):
- 虽然构建最终成功，但发现了 Rust 包编译失败的问题
- 影响的包: shadow-tls, shadowsocks-rust-sslocal, shadowsocks-rust-ssserver

### 2. 发现的关键错误信息

```
WARNING: Makefile 'package/passwall-packages/shadow-tls/Makefile' has a build dependency on 'rust/host', which does not exist
WARNING: Makefile 'package/passwall-packages/shadowsocks-rust/Makefile' has a build dependency on 'rust/host', which does not exist
```

```
make[2]: *** [Makefile:108: /home/runner/work/.../rustc-1.89.0-src/.built] Error 1
ERROR: package/feeds/packages/rust [host] failed to build.
make: *** [.../package/passwall-packages/shadow-tls/compile] Error 2
[WARNING] Failed to compile shadow-tls, will use prebuilt if available
```

### 3. 根本原因分析

工作流尝试从 OpenWrt feeds 的 packages_master 分支安装并编译 Rust：

1. **耗时过长**: 从源码编译 Rust 编译器通常需要超过 30 分钟
2. **经常失败**: CI 环境资源限制导致 Rust 编译器构建失败
3. **依赖缺失**: 编译失败后，shadow-tls 和 shadowsocks-rust 找不到 rust/host 依赖
4. **降级方案**: 最终只能从 SourceForge 下载预编译包

## 解决方案

### 实施的修复

模仿 Go 1.25.6 的安装方式，使用官方 rustup 工具安装 Rust：

#### 1. 新增工作流步骤: "Install Rust toolchain"

```yaml
- name: Install Rust toolchain
  run: |
    set -e
    echo "=========================================="
    echo "Installing Rust toolchain for OpenWrt SDK"
    echo "=========================================="
    
    # Install Rust using rustup (official Rust installer)
    echo "Installing rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    
    echo "Setting up Rust environment..."
    source "$HOME/.cargo/env"
    echo "$HOME/.cargo/bin" >> $GITHUB_PATH
    
    # Verify installation
    rustc --version
    cargo --version
    echo "[SUCCESS] Rust toolchain installed successfully and added to PATH"
```

#### 2. 移除 packages_master feed

之前添加此 feed 仅为了获取较新版本的 Rust，现在不再需要：

```yaml
# 删除了以下代码:
echo "src-git packages_master https://github.com/openwrt/packages.git;master" >> feeds.conf
```

#### 3. 更新构建依赖安装步骤

不再尝试从 feeds 安装 Rust，直接使用系统 Rust：

```yaml
echo "Verifying system toolchain versions..."
echo "System Go version (will be used for compilation):"
go version || echo "[WARNING] Go not found in PATH"
echo "System Rust version (will be used for compilation):"
rustc --version || echo "[WARNING] Rust not found in PATH"
cargo --version || echo "[WARNING] Cargo not found in PATH"

echo ""
echo "NOTE: Go 1.25.6 and Rust were installed system-wide in previous steps"
echo "NOTE: We do NOT install golang or rust packages from feeds because:"
echo "  1. Feeds golang (1.23.12) is too old for xray-core (requires >= 1.25.6)"
echo "  2. Building Rust compiler from feeds takes too long and often fails in CI"
echo "  3. OpenWrt SDK will automatically use system Go and Rust from PATH"
echo ""
```

#### 4. 更新文档

在 README.md 中更新了 Rust 工具链说明：

```markdown
## Go/Rust 工具链

本项目使用以下编译工具链：

- **Go**: 从 Go 官方源安装 1.25.6 版本，满足 xray-core (>= 1.25.6)、v2ray-plugin (>= 1.25)、geoview、hysteria 等包的编译需求
- **Rust**: 使用 rustup (官方 Rust 安装程序) 安装最新稳定版本，满足 shadowsocks-rust、shadow-tls 等包的编译需求

**注意**：之前尝试从 OpenWrt feeds 安装 Rust，但在 CI 环境中从源码编译 Rust 编译器耗时过长（通常超过 30 分钟）且经常失败。改用 rustup 安装预编译的 Rust 工具链可以显著提高构建速度和成功率。
```

## 预期效果

### 性能提升
- ✅ **显著缩短构建时间**: rustup 安装 < 30 秒 vs 从源码编译 > 30 分钟
- ✅ **更高的成功率**: 使用预编译的稳定工具链，避免 CI 环境中的编译失败

### 编译成功率提升
- ✅ **shadow-tls** 应该能够成功编译
- ✅ **shadowsocks-rust-sslocal** 应该能够成功编译
- ✅ **shadowsocks-rust-ssserver** 应该能够成功编译

### 依赖管理改进
- ✅ **减少预编译包依赖**: 更多包将从源码编译而非下载
- ✅ **更可靠的构建**: 减少因网络问题下载失败的风险

## 验证步骤

需要触发一次新的 GitHub Actions 运行来验证修复效果：

1. ✅ 推送更改到 GitHub
2. ⏳ 触发 workflow 运行
3. ⏳ 检查 "Install Rust toolchain" 步骤是否成功
4. ⏳ 检查 Rust 包编译日志，确认不再出现 "rust/host does not exist" 错误
5. ⏳ 确认 shadow-tls 和 shadowsocks-rust 包编译成功
6. ⏳ 验证最终生成的安装包包含所有 Rust 包

## 技术细节

### 为什么 rustup 比 feeds 安装更好？

1. **预编译工具链**: rustup 提供经过充分测试的预编译工具链
2. **快速安装**: 下载预编译二进制文件，无需从源码编译
3. **稳定可靠**: 官方维护，确保兼容性
4. **版本管理**: 可以轻松切换和更新 Rust 版本

### OpenWrt SDK 如何使用系统 Rust？

OpenWrt SDK 的构建系统会自动检测并使用 PATH 中的工具：
1. 当 Rust 包需要编译时，SDK 会查找 `rustc` 和 `cargo` 命令
2. 由于我们将 `$HOME/.cargo/bin` 添加到 PATH，SDK 会找到并使用系统 Rust
3. 不需要从 feeds 安装 rust 包，SDK 直接使用系统工具链

### 与 Go 修复的相似之处

这个 Rust 修复与之前的 Go 修复（参见 INVESTIGATION_SUMMARY.md）采用了相同的策略：
1. **问题相似**: feeds 提供的版本太旧或编译失败
2. **解决方案相似**: 使用官方安装程序安装系统级工具链
3. **效果相似**: 显著提高构建速度和成功率

## 相关文件修改

- `.github/workflows/build-installer.yml`: 主要修改文件
  - 添加 "Install Rust toolchain" 步骤
  - 移除 packages_master feed 配置
  - 更新 "Install build dependencies" 步骤
  - 更新注释和说明

- `README.md`: 文档更新
  - 更新 Go/Rust 工具链章节
  - 添加 Rust 安装方法说明

## 总结

这个修复解决了 CI 中 Rust 环境的根本问题：
- ❌ **之前**: 尝试从 feeds 编译 Rust → 耗时长且经常失败 → Rust 包编译失败 → 依赖预编译包
- ✅ **现在**: 使用 rustup 安装 Rust → 快速稳定 → Rust 包应该能成功编译 → 减少预编译包依赖

与 Go 修复结合后，现在 Go 和 Rust 工具链都使用官方工具安装，确保了最佳的编译环境和成功率。
