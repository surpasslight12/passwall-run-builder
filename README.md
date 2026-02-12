# PassWall Installer Builder

通过 GitHub Actions 自动编译 [PassWall](https://github.com/Openwrt-Passwall/openwrt-passwall) 及其全部依赖，打包为 `.run` 自解压安装文件。

Automatically compiles PassWall and all dependencies via GitHub Actions into a self-extracting `.run` installer.

## 特性 | Features

- 从 OpenWrt SDK 交叉编译全部依赖（C/C++、Go、Rust、预编译）
- 生成自解压 `.run` 安装包，一键部署到 OpenWrt 设备
- 支持自定义 SDK 版本、架构和 PassWall 版本
- 五层缓存（SDK / Go / Rust / sccache / Feeds）加速构建
- **Rust 编译优化**（sccache、增量编译、优化 RUSTFLAGS）
- 编译自动降级（并行 → 单线程）
- 适配 OpenWrt 25.12+ APK 包管理器

## 快速开始 | Quick Start

1. **Fork 仓库**
2. **配置 SDK** — 编辑 `config/openwrt-sdk.conf`，设置与目标设备匹配的 SDK 下载地址
3. **触发构建** — push tag 或手动触发 workflow
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```
4. **下载产物** — 在 Actions 或 Releases 页面下载 `.run` 文件
5. **安装到设备**
   ```bash
   scp passwall_*.run root@openwrt:/tmp/
   ssh root@openwrt 'cd /tmp && chmod +x passwall_*.run && ./passwall_*.run'
   /etc/init.d/passwall restart
   ```

## 项目结构 | Structure

```
├── .github/workflows/
│   └── build-installer.yml    # CI workflow
├── config/
│   ├── openwrt-sdk.conf       # SDK URL 配置
│   └── packages.conf          # 编译包列表
├── scripts/
│   ├── lib.sh                 # 公共函数库
│   ├── setup-environment.sh   # 环境准备
│   ├── install-toolchains.sh  # Go/Rust 安装
│   ├── setup-sdk.sh           # SDK 下载
│   ├── configure-feeds.sh     # Feeds 与补丁
│   ├── compile-packages.sh    # 包编译
│   ├── collect-packages.sh    # 产物收集
│   └── build-installer.sh     # .run 打包
├── payload/
│   └── install.sh             # 设备安装脚本
└── README.md
```

## 配置 | Configuration

### `config/openwrt-sdk.conf`

| 变量 Variable | 必填 Required | 说明 Description |
|------|------|------|
| `OPENWRT_SDK_URL` | ✅ | SDK 下载地址 / SDK download URL |
| `PASSWALL_LUCI_REF` | ❌ | 固定 PassWall 版本（如 `v26.1.21`）/ Pin PassWall version |

### `config/packages.conf`

每行一个包名，`#` 开头为注释。编译和收集的包均需在此列出。

One package name per line. Lines starting with `#` are comments.

### Workflow 手动触发参数 | Workflow Dispatch Inputs

手动触发 workflow 时可配置以下参数：

| 参数 Input | 默认值 Default | 说明 Description |
|------|------|------|
| `use_cache` | `true` | 是否启用缓存 / Enable caching |
| `min_required_packages` | `15` | 最少成功编译包数 / Minimum required built packages |
| `max_allowed_failures` | `5` | 最大允许失败数 / Maximum allowed build failures |

## 系统要求 | Requirements

- OpenWrt **25.12+**（APK 包管理器 / APK package manager）
- SDK 架构必须与目标设备一致 / SDK architecture must match target device
- GitHub Actions runner（`ubuntu-latest`）

## 构建流程 | Build Pipeline

```
Setup Environment → Install Toolchains (Go/Rust) → Setup SDK
  → Configure Feeds & Patches → Compile Packages → Collect APKs
  → Build .run Installer → Upload & Release
```

编译按工具链分组进行 / Compilation is grouped by toolchain:

| 分组 Group | 包 Packages |
|------|------|
| Rust | shadow-tls, shadowsocks-rust |
| Go | geoview, hysteria, sing-box, v2ray-plugin, xray-core, xray-plugin |
| C/C++ | dns2socks, ipt2socks, microsocks, shadowsocks-libev, shadowsocksr-libev, simple-obfs, tcping, trojan-plus |
| Prebuilt | chinadns-ng, naiveproxy, tuic-client, v2ray-geodata |

## 性能优化 | Performance

### Rust 编译加速

自动应用以下优化以加快 Rust 组件编译：

- **sccache**: 编译器缓存，避免重复编译相同代码
- **增量编译**: 启用 `CARGO_INCREMENTAL=1`
- **并行代码生成**: `-C codegen-units=16` 在编译速度和运行时性能间取得平衡
- **禁用 LTO**: `-C lto=off` 显著加速编译，适合快速迭代
- **优化级别**: `-C opt-level=2` 在编译速度和运行时性能间平衡
- **减少调试信息**: `CARGO_PROFILE_RELEASE_DEBUG=0` 加速编译和链接

首次构建预计提速 **20-30%**，后续构建通过 sccache 可提速 **40-60%**（基于并行代码生成、LTO 禁用和编译器缓存的理论估算）。

### 缓存策略 | Caching

| 缓存 Cache | 内容 Content | Key |
|------|------|------|
| SDK | OpenWrt SDK 完整目录 | SDK URL hash |
| Go modules | Go 模块缓存 | 按周轮换 |
| Rust/Cargo | Cargo registry & rustup | 按周轮换 |
| sccache | Rust 编译缓存 | 按周轮换 |
| Feeds | OpenWrt feeds & packages | 按周轮换 |

## 常见问题 | FAQ

### 为什么 shadow-tls 体积不大却编译很久？

- shadow-tls 本身代码量不多，但依赖链很重：主要依赖 `ring`，而 `ring` 会内置构建 BoringSSL/汇编优化代码，跨架构交叉编译时会完整编译一遍。
- Rust 交叉编译会同时构建目标架构的标准库和所有依赖的 release 版本，首次构建需要下载/编译完整的 crate 栈。
- 本仓库已启用 sccache、增量编译和并行代码生成，首次构建耗时较长属正常现象；后续构建会显著加速（命中缓存后通常缩短到几分钟级别）。

### 如何更换目标架构？ / How to change target architecture?

修改 `config/openwrt-sdk.conf` 中的 `OPENWRT_SDK_URL`，使用与目标设备匹配的 SDK。例如 aarch64 设备使用 `aarch64_cortex-a53` 对应的 SDK。

Change `OPENWRT_SDK_URL` in `config/openwrt-sdk.conf` to point to the SDK matching your target device.

### 安装失败怎么办？ / What if installation fails?

- 确认 `.run` 文件对应的架构与设备匹配
- 确认设备运行 OpenWrt 25.12+（使用 APK 包管理器）
- 检查设备存储空间是否充足（`df -h`）
- 查看安装日志定位具体错误

## License

遵循上游仓库 LICENSE。感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)。
