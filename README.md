# PassWall Installer Builder

通过 GitHub Actions 自动编译 [PassWall](https://github.com/Openwrt-Passwall/openwrt-passwall) 及其全部依赖，打包为 `.run` 自解压安装文件。

Automatically compiles PassWall and all dependencies via GitHub Actions into a self-extracting `.run` installer.

## 特性 | Features

- 从 OpenWrt SDK 交叉编译全部依赖（C/C++、Go、Rust、预编译）
- 生成自解压 `.run` 安装包，一键部署到 OpenWrt 设备
- 支持自定义 SDK 版本、架构和 PassWall 版本
- 四层缓存（SDK / Go / Rust / Feeds）加速构建
- **Rust 编译优化**（sccache、增量编译、优化 RUSTFLAGS）
- 编译自动降级（并行 → 单线程）
- 适配 OpenWrt 25.12+ APK 包管理器

## 快速开始 | Quick Start

1. **Fork 仓库**
2. **配置 SDK** — 编辑 `config/openwrt-sdk.conf`
3. **触发构建** — push tag 或手动触发 workflow
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```
4. **安装到设备**
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

| 变量 | 必填 | 说明 |
|------|------|------|
| `OPENWRT_SDK_URL` | ✅ | SDK 下载地址 |
| `PASSWALL_LUCI_REF` | ❌ | 固定 PassWall 版本 |

### `config/packages.conf`

每行一个包名，`#` 开头为注释。

## 系统要求 | Requirements

- OpenWrt **25.12+**（APK 包管理器）
- SDK 架构与目标设备一致

## 性能优化 | Performance

### Rust 编译加速

自动应用以下优化以加快 Rust 组件编译：

- **sccache**: 编译器缓存，避免重复编译相同代码
- **增量编译**: 启用 `CARGO_INCREMENTAL=1`
- **并行代码生成**: `-C codegen-units=16` 在编译速度和运行时性能间取得平衡
- **禁用 LTO**: `-C lto=off` 显著加速编译，适合快速迭代
- **优化级别**: `-C opt-level=2` 在编译速度和运行时性能间平衡
- **减少调试信息**: `CARGO_PROFILE_RELEASE_DEBUG=0` 加速编译和链接
- **超时配置**: Rust 组件编译超时设置为 60 分钟，可通过 `RUST_TIMEOUT_MIN` 环境变量调整

首次构建预计提速 **20-30%**，后续构建通过 sccache 可提速 **40-60%**（基于并行代码生成、LTO 禁用和编译器缓存的理论估算）。

## License

遵循上游仓库 LICENSE。感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)。
