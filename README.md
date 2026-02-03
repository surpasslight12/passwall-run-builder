# PassWall Installer Builder

本项目基于上游开源项目 [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)，使用 GitHub Actions 自动编译 PassWall 及其依赖，并生成自解压 `.run` 安装包。

This project is based on the upstream [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) project and uses GitHub Actions to automatically compile PassWall and its dependencies, generating a self-extracting `.run` installer.

## 主要特性 | Key Features

- ✅ 自动从 OpenWrt SDK 编译 luci-app-passwall
- ✅ 使用最新版本的 Go 和 Rust 工具链确保编译成功
- ✅ 自动编译依赖包
- ✅ 生成一键安装的 `.run` 安装包
- ✅ 支持自定义 OpenWrt SDK 版本和架构
- ✅ 支持 OpenWrt 25.12 的 APK 包管理器（替代 OPKG）

## 快速开始 | Quick Start

### 1. Fork 并克隆本仓库

```bash
git clone https://github.com/<your-username>/passwall-run-builder.git
cd passwall-run-builder
```

### 2. 配置 OpenWrt SDK

编辑 `config/openwrt-sdk.conf`，设置你的设备对应的 SDK 下载链接：

```bash
# Example for x86_64 architecture with OpenWrt 25.12
OPENWRT_SDK_URL=https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-sdk-25.12.0-x86-64_gcc-14.2.0_musl.Linux-x86_64.tar.zst
```

你可以从 [OpenWrt Downloads](https://downloads.openwrt.org/) 找到适合你设备的 SDK。

### 3. 触发构建

推送代码或创建 tag 触发 GitHub Actions：

```bash
# 方法 1: 手动触发 (在 GitHub Actions 页面)
# 方法 2: 推送 tag
git tag v1.0.0
git push origin v1.0.0
```

### 4. 下载安装包

构建完成后：
- **Tag 触发**: 在 GitHub Release 页面下载 `.run` 文件
- **手动触发**: 在 Actions 页面下载构建产物 (artifact)

### 5. 在 OpenWrt 设备上安装

```bash
# 上传文件到 OpenWrt 设备
scp PassWall_*.run root@openwrt:/tmp/

# SSH 连接到设备
ssh root@openwrt

# 赋予执行权限并运行
cd /tmp
chmod +x PassWall_*.run
./PassWall_*.run

# 重启 PassWall 服务
/etc/init.d/passwall restart
```

## OpenWrt 25.12 APK 包管理器 | APK Package Manager

**重要说明 | Important Note:**

从 OpenWrt 25.12 开始，系统使用 Alpine Linux 的 APK 包管理器替代了传统的 OPKG。本项目已完全适配 APK 包管理器。

Starting from OpenWrt 25.12, the system uses Alpine Linux's APK package manager instead of the traditional OPKG. This project is fully adapted for the APK package manager.

### 主要变化 | Key Changes

- **包格式**: 从 `.ipk` 变更为 `.apk` 格式
- **Package format**: Changed from `.ipk` to `.apk` format
- **安装命令**: 使用 `apk add` 替代 `opkg install`
- **Installation command**: Use `apk add` instead of `opkg install`

### APK 常用命令 | Common APK Commands

```bash
# 更新软件源 | Update repository database
apk update

# 安装软件包 | Install packages
apk add <package-name>

# 安装本地软件包（如本项目的 .run 安装包）| Install local packages
apk add --allow-untrusted /path/to/package.apk

# 删除软件包 | Remove packages
apk del <package-name>

# 列出已安装软件包 | List installed packages
apk list -I

# 搜索软件包 | Search for packages
apk search <keyword>
```

### 兼容性说明 | Compatibility Notes

- 本安装脚本专为 OpenWrt 25.12+ 设计，使用 APK 包管理器
- The installation script is designed for OpenWrt 25.12+ and uses the APK package manager
- 对于 OpenWrt 25.12+，所有包都以 `.apk` 格式构建和安装
- For OpenWrt 25.12+, all packages are built and installed in `.apk` format
- 对于 OpenWrt 24.10 及更早版本，请使用项目的旧版本
- For OpenWrt 24.10 and earlier versions, please use older project versions

### 参考资源 | Resources

- [OpenWrt APK 官方文档 | Official APK Documentation](https://openwrt.org/docs/guide-user/additional-software/apk)
- [OPKG 到 APK 命令对照表 | OPKG to APK Cheatsheet](https://openwrt.org/docs/guide-user/additional-software/opkg-to-apk-cheatsheet)

## 工具链 | Toolchain

### Go 编译器

- **版本**: 自动安装最新稳定版本
- **用途**: 编译 xray-core, v2ray-plugin, hysteria 等 Go 包
- **来源**: Go 官方 (https://go.dev)

### Rust 编译器

- **版本**: 最新稳定版本 (通过 rustup)
- **用途**: 编译 shadowsocks-rust, shadow-tls 等 Rust 包
- **来源**: Rust 官方 (https://rustup.rs)
- **目标平台**: x86_64-unknown-linux-musl (OpenWrt 使用 musl libc)

## 依赖包 | Dependencies

本项目的安装包包含以下 PassWall 依赖 (20+ 个包)：

**核心代理工具:**
- xray-core, sing-box
- v2ray-plugin, xray-plugin

**传输协议:**
- shadowsocks-libev (ss-local, ss-redir, ss-server)
- shadowsocks-rust (sslocal, ssserver)
- shadowsocksr-libev (ssr-local, ssr-redir, ssr-server)
- trojan-plus, hysteria, naiveproxy, tuic-client

**辅助工具:**
- chinadns-ng, dns2socks, ipt2socks, microsocks
- simple-obfs-client, tcping, shadow-tls

**地理数据:**
- v2ray-geoip, v2ray-geosite, geoview

### 依赖包获取方式

1. **优先编译**: 使用 OpenWrt SDK + 最新 Go/Rust 工具链从源码编译

## 项目结构 | Project Structure

```
passwall-run-builder/
├── .github/
│   └── workflows/
│       └── build-installer.yml    # GitHub Actions 构建流程
├── config/
│   └── openwrt-sdk.conf           # OpenWrt SDK 配置
├── payload/
│   ├── install.sh                 # 安装脚本
│   └── depends/                   # 依赖包目录 (构建时自动填充)
└── README.md
```

## 自定义安装内容 | Customization

### 修改安装脚本

编辑 `payload/install.sh` 来自定义安装逻辑。当前脚本会：
1. 检测 PassWall 版本
2. 运行 `apk update`（OpenWrt 25.12+）
3. 强制重装/安装所有 APK 包
4. 清理旧依赖

### 添加额外文件

将需要安装的额外文件放入 `payload/` 目录，并在 `install.sh` 中添加处理逻辑。

## 系统要求 | Requirements

### OpenWrt 设备

- **架构**: 与 SDK 版本匹配 (如 x86_64, arm_cortex-a9, mipsel_24kc 等)
- **固件版本**: OpenWrt 25.12+ (使用 APK 包管理器)
- **存储空间**: 至少 50MB 可用空间
- **内存**: 建议至少 128MB RAM

### GitHub Actions (CI)

- Ubuntu latest runner
- 约 2GB 磁盘空间用于 SDK 和编译产物
- 构建时间: 通常 20-40 分钟

## 常见问题 | FAQ

### Q: 构建过程中出现 Kconfig 警告

A: 这些是正常警告，不会影响编译结果。OpenWrt 的配置系统在合并多个软件包配置时会产生这些通知。

### Q: 某些包编译失败

A: 请检查 SDK 构建日志中是否有包编译失败的提示。构建成功后 `.run` 安装包会包含所有必要的依赖。

### Q: 如何更换 SDK 版本或架构？

A: 修改 `config/openwrt-sdk.conf` 中的 `OPENWRT_SDK_URL`，指向你需要的 SDK 版本。

### Q: 安装时提示 apk update 失败

A: 确保 OpenWrt 设备网络连接正常，并且 `/etc/apk/repositories` 中的软件源可访问。

### Q: 如何验证安装是否成功？

A: 运行 `apk list -I | grep passwall` 查看已安装的 PassWall 包，然后访问 OpenWrt 的 LuCI 界面检查 PassWall 应用是否正常显示。

### Q: 是否支持旧版本 OpenWrt (24.10 及更早版本)？

A: 本项目针对 OpenWrt 25.12+ 优化，使用 APK 包管理器。如需在使用 OPKG 的旧版本 OpenWrt 上使用，请使用项目的旧版本或自行修改安装脚本。

## 与上游项目的关系 | Relation to Upstream

- **上游仓库**: https://github.com/Openwrt-Passwall/openwrt-passwall
- **本项目目的**: 提供自动化的编译和打包流程，简化 PassWall 的安装
- **安装脚本**: 基于上游官方安装脚本编写，保持兼容性

## 开源协议 | License

本项目遵循上游项目的开源协议。具体请参考上游项目的 LICENSE 文件。

## 贡献 | Contributing

欢迎提交 Issue 和 Pull Request！

## 致谢 | Acknowledgments

感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) 项目的开发者和维护者。
