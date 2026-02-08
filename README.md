# PassWall Installer Builder

基于 [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)，通过 GitHub Actions 自动编译 PassWall 及依赖并打包为 `.run` 安装包。  
Builds a self-extracting installer based on the upstream project using GitHub Actions.

## 特性 | Features

- 自动从 OpenWrt SDK 编译 PassWall 与依赖
- 生成一键安装的 `.run` 包
- 支持自定义 SDK 版本与架构
- 适配 OpenWrt 25.12+ APK 包管理器
- **缓存机制**：自动缓存 SDK、Go/Rust 工具链和 feeds，加速后续构建
- **重试机制**：网络操作自动重试，支持指数退避

## 快速开始 | Quick Start

1. **克隆仓库**
   ```bash
   git clone https://github.com/<your-username>/passwall-run-builder.git  # 替换为你的 GitHub 用户名
   cd passwall-run-builder
   ```
2. **配置 SDK** (`config/openwrt-sdk.conf`)
   ```bash
   OPENWRT_SDK_URL=https://downloads.openwrt.org/releases/25.12.0-rc4/targets/x86/64/openwrt-sdk-25.12.0-rc4-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
   ```
3. **触发构建**：Actions 手动触发或 push tag
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
4. **安装**：下载 `.run` → 上传到设备 → 执行
   ```bash
   scp PassWall_*.run root@openwrt:/tmp/
   ssh root@openwrt
   cd /tmp && chmod +x PassWall_*.run
   ./PassWall_*.run
   /etc/init.d/passwall restart
   ```

## 编译说明 | Build Notes

- 自动安装最新 Go/Rust，用于编译 Go/Rust 依赖包。
- 自动将 SDK 内置的 Go 更新为系统最新版本，以确保 xray-core、v2ray-plugin 等上游包的 Go 版本要求得到满足。
- 仅编译 `luci-app-passwall` 与 PassWall 依赖包，跳过 luci-base host tools 以减少构建耗时。
- 如遇构建问题，可在 `.github/workflows/build-installer.yml` 的编译阶段、`Configure build options` 之后手动补回 `make package/feeds/luci/luci-base/host/compile` 步骤。
- `luci-i18n-passwall-zh-cn` 为可选包，若编译失败不会影响主包打包。
- 依赖包编译失败会被跳过，仅打包成功产物。

### 缓存说明 | Cache Details

工作流使用 GitHub Actions Cache 来加速构建：

- **SDK 缓存**：根据 SDK URL 哈希缓存整个 SDK 目录
  - 自动清理缓存中的 bin/packages/ 构建产物，防止旧构建掩盖新错误
  - 自动清理 .config 和 tmp/ 配置文件，避免配置冲突
- **Go 缓存**：缓存 SDK 的 Go 模块下载缓存（`openwrt-sdk/dl/go-mod-cache`）
- **Rust 缓存**：缓存 Cargo 注册表和 rustup
- **Feeds 缓存**：缓存 OpenWrt feeds 目录
  - 自动验证缓存完整性，如验证失败则重新下载

缓存按周更新，如需强制刷新可修改 `CACHE_VERSION` 环境变量。

#### 缓存健康检查 | Cache Health Checks

构建系统包含多项缓存验证机制：

1. **SDK 验证**：检查关键文件和目录，确保 SDK 完整
2. **Feeds 验证**：检查 feeds 索引和内容，防止损坏
3. **构建产物清理**：每次构建前删除旧的 APK 文件
4. **配置文件清理**：清除可能导致冲突的配置文件
5. **新鲜度检测**：只接受近期（默认 5 分钟）内修改的构建产物，避免使用缓存掩盖失败

查看 GitHub Actions 的 "Cache Diagnostics" 和 "Build Summary" 了解缓存使用情况。

## 系统要求 | Requirements

- OpenWrt 25.12+（APK 包管理器）
- SDK 架构与设备一致
- 至少 50MB 可用空间，建议 128MB RAM

## 常见问题 | FAQ

- **Kconfig 警告**：属正常提示，不影响编译。
- **部分包编译失败**：查看 Actions 日志，失败包会被跳过。
- **旧版 OpenWrt**：24.10 及更早版本需使用旧版脚本或自行修改。
- **缓存问题**：如遇缓存导致的构建问题，可增加 `CACHE_VERSION` 值来清除缓存。
  - 构建系统会自动验证缓存完整性并清理潜在冲突
  - 查看 GitHub Actions "Cache Diagnostics" 了解缓存状态
  - 如果构建失败且怀疑是缓存问题，将 `.github/workflows/build-installer.yml` 中的 `CACHE_VERSION: v1` 改为 `v2`

## 项目结构 | Structure

```
passwall-run-builder/
├── .github/workflows/build-installer.yml
├── config/openwrt-sdk.conf
├── payload/install.sh
└── README.md
```

## License / Contributing / Acknowledgments

遵循上游仓库 LICENSE。欢迎提交 Issue/PR。  
感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) 项目维护者。
