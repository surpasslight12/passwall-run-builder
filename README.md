# PassWall Installer Builder

基于 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)，通过 GitHub Actions 自动编译 PassWall 及全部依赖，打包为一键安装的 `.run` 文件。

Automatically compiles PassWall and all dependencies via GitHub Actions into a self-extracting `.run` installer.

## 特性 | Features

- 从 OpenWrt SDK 交叉编译 PassWall 全部依赖（C/C++、Go、Rust、预编译）
- 生成自解压 `.run` 安装包，一键部署到 OpenWrt 设备
- 支持自定义 SDK 版本、架构和 PassWall 版本
- 四层缓存（SDK / Go / Rust / Feeds）加速后续构建
- 网络操作自动重试（指数退避），编译自动降级（并行 → 单线程）
- 适配 OpenWrt 25.12+ APK 包管理器

## 快速开始 | Quick Start

1. **Fork / 克隆**
   ```bash
   git clone https://github.com/<your-username>/passwall-run-builder.git
   cd passwall-run-builder
   ```

2. **配置 SDK** — 编辑 `config/openwrt-sdk.conf`
   ```bash
   OPENWRT_SDK_URL=https://downloads.openwrt.org/releases/25.12.0-rc4/targets/x86/64/openwrt-sdk-...tar.zst
   ```

3. **触发构建** — push tag 或手动触发 workflow
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```

4. **安装到设备**
   ```bash
   scp passwall_*.run root@openwrt:/tmp/
   ssh root@openwrt 'cd /tmp && chmod +x passwall_*.run && ./passwall_*.run'
   # 重启服务
   /etc/init.d/passwall restart
   ```

## 项目结构 | Structure

```
passwall-run-builder/
├── .github/workflows/
│   └── build-installer.yml         # CI 工作流 / CI workflow
├── config/
│   ├── openwrt-sdk.conf            # SDK URL 与版本配置 / SDK configuration
│   └── packages.conf               # 编译包列表 / Package list for .config
├── scripts/
│   ├── lib.sh                      # 公共函数库 / Shared helpers
│   ├── setup-environment.sh        # 环境准备 / Disk & deps setup
│   ├── install-toolchains.sh       # Go/Rust 安装 / Toolchain install
│   ├── setup-sdk.sh                # SDK 下载 / SDK download & prep
│   ├── configure-feeds.sh          # Feeds 配置与补丁 / Feeds & patches
│   ├── compile-packages.sh         # 包编译 / Package compilation
│   ├── collect-packages.sh         # 产物收集 / Collect APKs
│   └── build-installer.sh          # .run 打包 / Build installer
├── payload/
│   └── install.sh                  # 设备安装脚本 / On-device installer
└── README.md
```

## 构建流水线 | Build Pipeline

```
Checkout → Load Config → Caches
  → Prepare Environment (disk cleanup, apt dependencies)
  → Install Toolchains (Go, Rust)
  → Setup SDK (download / cache validation)
  → Configure Feeds & Patches (GOTOOLCHAIN, curl LDAP, Rust LLVM)
  → Compile Packages (C/C++ → Go → Rust → Prebuilt → luci-app-passwall)
  → Collect & Validate APKs
  → Build .run Installer (makeself)
  → Publish (Artifact + GitHub Release)
```

## 配置说明 | Configuration

### `config/openwrt-sdk.conf`

| 变量 | 必填 | 说明 |
|------|------|------|
| `OPENWRT_SDK_URL` | ✅ | OpenWrt SDK 下载地址 |
| `PASSWALL_LUCI_REF` | ❌ | 固定 PassWall 版本（tag/branch/commit） |

### `config/packages.conf`

每行一个包名，用于生成 `.config`。注释行以 `#` 开头。

### 缓存 | Caching

工作流支持四类缓存，可通过 `workflow_dispatch` 的 `use_cache` 参数控制：

| 类型 | 说明 |
|------|------|
| SDK | 完整 SDK 目录，按 URL 哈希索引 |
| Go | SDK 的 Go 模块缓存 |
| Rust | Cargo 注册表与 rustup |
| Feeds | OpenWrt feeds 目录 |

如遇缓存问题，修改 `CACHE_VERSION` 即可全部失效。

## 系统要求 | Requirements

- OpenWrt **25.12+**（APK 包管理器）
- SDK 架构与目标设备一致
- 设备至少 50MB 可用空间

## 常见问题 | FAQ

| 问题 | 解决方法 |
|------|---------|
| Kconfig 警告 | 正常提示，不影响编译 |
| 部分包编译失败 | 查看 Actions 日志，失败包会被跳过 |
| 缓存导致的构建问题 | 增加 `CACHE_VERSION` 或禁用缓存 |
| 旧版 OpenWrt (< 25.12) | 需要 APK 包管理器，不支持 opkg |

## License & Acknowledgments

遵循上游仓库 LICENSE。欢迎 Issue / PR。

感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall) 项目。
