# Rust 跨平台编译问题修复报告
# Rust Cross-Compilation Fix Report

**日期 / Date**: 2026-02-01  
**问题编号 / Issue**: 检查最新的action日志，检查为什么rust工具链没能正常使用

---

## 问题摘要 / Executive Summary

经过对最新 GitHub Actions 日志（workflow run #50）的详细分析，发现了 Rust 工具链无法正常工作的根本原因：**缺少跨平台编译所需的目标标准库**。

After detailed analysis of the latest GitHub Actions logs (workflow run #50), I identified the root cause of the Rust toolchain issues: **missing target standard library for cross-compilation**.

---

## 调查过程 / Investigation Process

### 1. 日志分析 / Log Analysis

检查了最新的成功构建（run #50, 2026-02-01 15:36:57 UTC）的完整日志：
- ✅ Rust 1.93.0 通过 rustup 成功安装
- ✅ rustc 和 cargo 命令可用
- ❌ shadow-tls 编译失败
- ❌ shadowsocks-rust 编译失败

Checked the complete logs of the latest successful build (run #50):
- ✅ Rust 1.93.0 successfully installed via rustup
- ✅ rustc and cargo commands available
- ❌ shadow-tls compilation failed
- ❌ shadowsocks-rust compilation failed

### 2. 错误信息 / Error Messages

关键错误：
```
error[E0463]: can't find crate for `core`
```

编译命令显示目标平台：
```bash
--target x86_64-unknown-linux-musl
```

但 rustup 只安装了默认主机平台：
```
x86_64-unknown-linux-gnu  (host platform)
```

Key error:
```
error[E0463]: can't find crate for `core`
```

Compilation command shows target platform:
```bash
--target x86_64-unknown-linux-musl
```

But rustup only installed the default host platform:
```
x86_64-unknown-linux-gnu  (host platform)
```

### 3. 根本原因 / Root Cause

这是一个**跨平台编译配置不完整**的问题：

This is an **incomplete cross-compilation configuration** issue:

| 组件 / Component | 平台 / Platform | 状态 / Status |
|-----------------|----------------|--------------|
| 编译主机 / Build Host | x86_64-unknown-linux-gnu | ✅ 已安装 / Installed |
| 目标平台 / Target Platform | x86_64-unknown-linux-musl | ❌ 未安装 / Not Installed |
| OpenWrt SDK 需求 / Required | x86_64-unknown-linux-musl | ⚠️ 不匹配 / Mismatch |

**原因说明 / Explanation:**
1. OpenWrt 使用 musl libc 而不是 glibc
2. Rust 需要为目标平台提供标准库（std、core 等）
3. rustup 默认只安装主机平台的标准库
4. 缺少 musl 目标的标准库导致编译失败

1. OpenWrt uses musl libc instead of glibc
2. Rust requires standard library (std, core, etc.) for target platform
3. rustup only installs host platform standard library by default
4. Missing musl target standard library causes compilation failure

---

## 解决方案 / Solution

### 修改内容 / Changes Made

**文件 / File**: `.github/workflows/build-installer.yml`

```yaml
# 添加 musl 目标支持 / Add musl target support
echo "Adding x86_64-unknown-linux-musl target..."
rustup target add x86_64-unknown-linux-musl

# 验证安装的目标 / Verify installed targets
rustup target list --installed
```

### 技术细节 / Technical Details

**之前的流程 / Previous Flow:**
```
rustup 安装 → 仅主机标准库 → OpenWrt SDK 需要 musl → 找不到 core → 编译失败
rustup install → host stdlib only → OpenWrt needs musl → core not found → build fails
```

**修复后的流程 / Fixed Flow:**
```
rustup 安装 → 添加 musl 目标 → 两个标准库都可用 → OpenWrt SDK 使用 musl → 编译成功
rustup install → add musl target → both stdlibs available → OpenWrt uses musl → build succeeds
```

---

## 预期效果 / Expected Results

### 直接效果 / Direct Impact

- ✅ **shadow-tls** 包应该能够从源码成功编译
- ✅ **shadowsocks-rust-sslocal** 包应该能够从源码成功编译
- ✅ **shadowsocks-rust-ssserver** 包应该能够从源码成功编译
- ✅ 不再出现 "can't find crate for `core`" 错误

- ✅ **shadow-tls** package should compile successfully from source
- ✅ **shadowsocks-rust-sslocal** package should compile successfully from source
- ✅ **shadowsocks-rust-ssserver** package should compile successfully from source
- ✅ No more "can't find crate for `core`" errors

### 间接效果 / Indirect Impact

- ✅ **减少预编译包依赖** / Reduced dependency on prebuilt packages
- ✅ **构建更加透明** / More transparent build process
- ✅ **更容易调试问题** / Easier to debug issues
- ✅ **完整的源码构建** / Complete source-based build

---

## 警告信息说明 / Warning Explanation

你可能仍然会看到以下警告，这是**正常且预期的**：

You may still see the following warnings, which are **normal and expected**:

```
WARNING: Makefile 'package/passwall-packages/shadow-tls/Makefile' has a build dependency on 'rust/host', which does not exist
WARNING: Makefile 'package/passwall-packages/shadowsocks-rust/Makefile' has a build dependency on 'rust/host', which does not exist
```

**原因 / Reason:**
- 这些包的 Makefile 声明依赖 `rust/host` (来自 OpenWrt feeds)
- 我们使用系统 rustup 安装的 Rust，不是从 feeds 安装
- OpenWrt SDK 会自动使用 PATH 中的 rustc 和 cargo
- 警告可以忽略，不影响编译

- Package Makefiles declare dependency on `rust/host` (from OpenWrt feeds)
- We use system rustup-installed Rust, not from feeds
- OpenWrt SDK automatically uses rustc and cargo from PATH
- Warning can be ignored, does not affect compilation

---

## 验证步骤 / Verification Steps

当下次 workflow 运行时，你应该能看到：

In the next workflow run, you should see:

### 1. Rust 安装步骤 / Rust Installation Step
```
Installing rustup...
✓ Rust is installed now. Great!
Adding x86_64-unknown-linux-musl target...
✓ downloading component 'rust-std' for 'x86_64-unknown-linux-musl'
Installed targets:
- x86_64-unknown-linux-gnu
- x86_64-unknown-linux-musl
```

### 2. Rust 包编译 / Rust Package Compilation
```
Compiling shadow-tls...
✓ Finished release [optimized] target(s)
Compiling shadowsocks-rust...
✓ Finished release [optimized] target(s)
```

### 3. 成功标志 / Success Indicators
- 不再出现 "can't find crate for `core`" 错误
- shadow-tls、shadowsocks-rust 包成功编译
- 最终的 .run 安装包包含所有 Rust 包

- No more "can't find crate for `core`" errors
- shadow-tls, shadowsocks-rust packages compile successfully
- Final .run installer contains all Rust packages

---

## 相关文档 / Related Documentation

- `RUST_FIX_SUMMARY.md` - Rust 工具链修复历史 / Rust toolchain fix history
- `INVESTIGATION_SUMMARY.md` - Go 环境调查报告 / Go environment investigation
- `.github/workflows/build-installer.yml` - 构建工作流 / Build workflow

---

## 安全检查 / Security Check

- ✅ 代码审查通过，无问题 / Code review passed, no issues
- ✅ CodeQL 安全扫描通过，无漏洞 / CodeQL security scan passed, no vulnerabilities
- ✅ 仅添加官方 Rust 目标，无安全风险 / Only adding official Rust target, no security risks

---

## 总结 / Summary

### 中文总结

这次修复解决了 Rust 工具链的最后一个关键问题。虽然 Rust 1.93.0 已经成功安装，但由于缺少 musl 目标的标准库，OpenWrt SDK 无法进行跨平台编译。通过添加 `x86_64-unknown-linux-musl` 目标，现在 Rust 包应该能够正常编译了。

这个修复与之前的 Go 工具链修复（安装 Go 1.25.6）互补，现在整个构建系统应该能够：
1. ✅ 使用最新的 Go 1.25.6 编译 Go 包
2. ✅ 使用 Rust 1.93.0 + musl 目标编译 Rust 包
3. ✅ 减少对预编译包的依赖
4. ✅ 提供更透明、可靠的构建过程

### English Summary

This fix addresses the final critical issue with the Rust toolchain. Although Rust 1.93.0 was successfully installed, the OpenWrt SDK couldn't perform cross-compilation due to missing musl target standard library. By adding the `x86_64-unknown-linux-musl` target, Rust packages should now compile successfully.

This fix complements the previous Go toolchain fix (installing Go 1.25.6). The entire build system should now be able to:
1. ✅ Compile Go packages using latest Go 1.25.6
2. ✅ Compile Rust packages using Rust 1.93.0 + musl target
3. ✅ Reduce dependency on prebuilt packages
4. ✅ Provide more transparent and reliable build process
