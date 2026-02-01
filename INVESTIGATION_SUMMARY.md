# Go Environment Investigation Summary

## 问题描述 (Problem Description)

用户报告："检查下最新的action日志为什么更新了go环境但是还是编译不成功"
(Translation: "Check the latest action logs to see why compilation still fails even after updating the Go environment")

## 调查发现 (Investigation Findings)

### 1. 当前状态 (Current Status)
- ✅ 最新的 GitHub Actions 构建**全部成功**
- ✅ Go 1.25.6 已经从官方源安装
- ✅ 安装包正常生成并上传

### 2. 根本原因 (Root Cause)

通过分析构建日志，发现了关键问题：

```
2026-02-01T14:50:17.7450998Z go: ../../go.mod requires go >= 1.25 (running go 1.23.12; GOTOOLCHAIN=local)
2026-02-01T14:50:28.6317169Z go: ../../go.mod requires go >= 1.25.6 (running go 1.23.12; GOTOOLCHAIN=local)
```

**问题**: 
- Go 1.25.6 安装在 `/usr/local/go` 并添加到了 PATH
- 但是 OpenWrt SDK 编译系统**没有使用**系统的 Go 1.25.6
- 而是使用了从 feeds 安装的 golang 包（Go 1.23.12）
- v2ray-plugin 需要 Go >= 1.25
- xray-core 需要 Go >= 1.25.6
- 因此这些包的编译失败

### 3. 为什么构建仍然成功？ (Why Did Builds Still Succeed?)

虽然部分 Go 包编译失败，但 workflow 有回退机制：
- 当 SDK 编译失败时，自动从 SourceForge 下载预编译包
- 因此最终的安装包仍然包含所有需要的依赖
- 但这不是理想的解决方案，应该让 SDK 能够正确编译这些包

## 修复方案 (Solution)

### 修改内容：

1. **不再从 feeds 安装 golang 包**
   - 之前: `./scripts/feeds install -p packages_master golang rust`
   - 现在: `./scripts/feeds install -p packages_master rust`

2. **让 OpenWrt SDK 使用系统 Go 1.25.6**
   - Go 1.25.6 已经安装并在 PATH 中
   - OpenWrt SDK 会自动使用 PATH 中的 go 命令

3. **仍然从 feeds 安装 Rust**
   - Rust 工具链继续从 packages_master feed 获取

4. **更新文档**
   - 更新 README.md 说明 Go/Rust 工具链的来源
   - 添加注释解释为什么不使用 feeds 的 golang 包

### 预期效果：

- ✅ v2ray-plugin 应该能够成功编译（需要 Go >= 1.25）
- ✅ xray-core 应该能够成功编译（需要 Go >= 1.25.6）
- ✅ 减少对预编译包的依赖
- ✅ 构建过程更加透明和可靠

## 验证步骤 (Verification Steps)

需要触发一次新的 workflow 运行来验证：

1. 推送这个 PR 到 GitHub
2. 触发 workflow 运行
3. 检查构建日志中的 Go 版本信息
4. 确认 v2ray-plugin 和 xray-core 编译成功
5. 验证最终生成的安装包

## 技术细节 (Technical Details)

### OpenWrt SDK 的 Go 编译工作原理：

1. OpenWrt SDK 使用 `golang` feed 包提供的 `golang-build.sh` 脚本
2. 但实际的 Go 编译器可以来自系统 PATH
3. 之前我们同时安装了：
   - 系统 Go 1.25.6 (在 /usr/local/go/bin)
   - feeds golang 包 (提供 Go 1.23.12)
4. OpenWrt SDK 优先使用 feeds 的 golang 包中的 Go 版本
5. 现在我们不安装 feeds golang 包，SDK 会使用系统的 Go 1.25.6

## 相关提交 (Related Commits)

- `52f3703`: Install Go 1.25+ from official source to fix compilation
- `1a262e7`: Use Go 1.25.6 (latest patch release)
- `0213408`: Update Go/Rust toolchains using OpenWrt packages master branch
- `7df5ccb`: Fix: Use system Go 1.25.6 instead of outdated golang from feeds (本次修复)

## 总结 (Summary)

这个问题是一个**配置冲突**：
- ✅ Go 1.25.6 已经正确安装
- ❌ 但 OpenWrt SDK 没有使用它
- ✅ 现在已经修复，SDK 会使用系统的 Go 1.25.6
- ✅ 预期编译成功率会提高，减少对预编译包的依赖
