# PassWall Installer Builder

基于 [OpenWrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)，通过 GitHub Actions 自动编译 PassWall 及依赖并打包为 `.run` 安装包。  
Builds a self-extracting installer based on the upstream project using GitHub Actions.

## 特性 | Features

- 自动从 OpenWrt SDK 编译 PassWall 与依赖
- 生成一键安装的 `.run` 包
- 支持自定义 SDK 版本与架构
- 适配 OpenWrt 25.12+ APK 包管理器

## 快速开始 | Quick Start

1. **克隆仓库**
   ```bash
   git clone https://github.com/<your-username>/passwall-run-builder.git
   cd passwall-run-builder
   ```
2. **配置 SDK** (`config/openwrt-sdk.conf`)
   ```bash
   OPENWRT_SDK_URL=https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-sdk-25.12.0-x86-64_gcc-14.2.0_musl.Linux-x86_64.tar.zst
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
- 仅编译 `luci-app-passwall` 与 PassWall 依赖包，跳过不必要的 luci-base host tools。
- `luci-i18n-passwall-zh-cn` 为可选包，若编译失败不会影响主包打包。
- 依赖包编译失败会被跳过，仅打包成功产物。

## 系统要求 | Requirements

- OpenWrt 25.12+（APK 包管理器）
- SDK 架构与设备一致
- 至少 50MB 可用空间，建议 128MB RAM

## 常见问题 | FAQ

- **Kconfig 警告**：属正常提示，不影响编译。
- **部分包编译失败**：查看 Actions 日志，失败包会被跳过。
- **旧版 OpenWrt**：24.10 及更早版本需使用旧版脚本或自行修改。

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
