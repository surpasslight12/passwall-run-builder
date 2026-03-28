# PassWall Installer Builder

通过 GitHub Actions 自动编译 [PassWall](https://github.com/Openwrt-Passwall/openwrt-passwall) 及其全部依赖，打包为 `.run` 自解压安装文件。

Automatically compiles PassWall and all dependencies via GitHub Actions into a self-extracting `.run` installer.

## 特性 | Features

- 从 OpenWrt SDK 交叉编译全部依赖（C/C++、Go、Rust、预编译）
- 生成自解压 `.run` 安装包，一键部署到 OpenWrt 设备
- 支持自定义 SDK 版本和架构
- 每次执行完整构建，无增量编译，确保产物一致性
- **Rust 编译优化**（并行代码生成、优化 RUSTFLAGS）
- 编译自动降级（并行 → 单线程）
- 适配 OpenWrt 25.12+ APK 包管理器
- 按 luci-app-passwall 的默认功能开关与目标架构条件自动分析并本地编译 PassWall 相关组件
- 对缺失的系统依赖 APK 自动从官方 OpenWrt 源拉取并并入 `.run`
- 固定 Go / Rust 工具链版本并校验官方安装包
- 安装前自动校验 payload 内全部文件的 SHA256
- 安装时优先使用 payload 内嵌的本地 APK 仓库索引，避免默认 `dnsmasq`/`ip-tiny` 等 provider 与 PassWall 依赖冲突
- 支持手动触发构建，也支持定时检查上游稳定版并在有新版本时自动触发构建

## 快速开始 | Quick Start

1. **Fork 仓库**
2. **配置构建参数** — 编辑 `config/config.conf`，集中设置 SDK 下载地址、镜像、Go/Rust 版本与上游仓库
3. **触发构建** — 在 GitHub Actions 页面手动触发 `passwall.yml`
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
│   └── passwall.yml           # 统一工作流（配置加载 / 构建上下文 / 构建 / 发布）
├── config/
│   └── config.conf            # 集中化构建配置
├── scripts/
│   ├── full-build.sh          # 共享 full build 内核（Actions / 本地共用）
│   ├── local-build.sh         # 本地 smoke/full 入口
│   └── utils.sh               # 工具函数库（日志、重试、make 封装等）
├── payload/
│   └── install.sh             # 设备安装脚本
└── README.md
```

## 配置 | Configuration

### `config/config.conf`

| 变量 Variable | 必填 Required | 说明 Description |
|---------------|---------------|------------------|
| `OPENWRT_SDK_URL` | ✅ | SDK 下载地址 |
| `PASSWALL_LUCI_REPO` | ✅ | `openwrt-passwall` 源码仓库 |
| `PASSWALL_PACKAGES_REPO` | ✅ | `openwrt-passwall-packages` 源码仓库 |
| `OPENWRT_BASE_FEED_REPO` | ✅ | OpenWrt base feed 镜像地址 |
| `OPENWRT_*_FEED_REPO` | ✅ | OpenWrt feed 镜像地址 |
| `OPENWRT_SOURCE_*` | ✅ | OpenWrt 源码下载镜像 |
| `GO_VERSION` / `GO_SHA256_LINUX_AMD64` | ✅ | Go 版本与校验值 |
| `RUST_TOOLCHAIN_VERSION` / `RUSTUP_INIT_*` | ✅ | Rust 版本、安装地址与校验值 |
| `GOPROXY` | ✅ | Go 模块代理链 |
| `MIN_REQUIRED_PACKAGES` | ✅ | payload 依赖包数量下限保护 |

### Workflow 手动触发参数 | Workflow Dispatch Inputs

手动触发 `passwall.yml` 时支持以下输入；仓库不再通过 Git push 自动触发构建：

| 输入 Input | 默认值 | 说明 Description |
|------------|--------|------------------|
| `mode` | `build` | `build` 直接构建；`sync-and-build` 先同步上游稳定版 tag，再在同一 workflow 内继续构建/发布 |
| `tag` | 空 | 仅在 `build` 模式可选；不填时自动解析上游最新稳定版 tag |

## 系统要求 | Requirements

- OpenWrt **25.12+**（APK 包管理器）
- SDK 架构必须与目标设备一致
- GitHub Actions runner（`ubuntu-latest`）

## 构建流程 | Build Pipeline

```
passwall.yml
  → load-config
  → prepare-build
  → schedule / sync-and-build: 同步上游 tag 并决定是否发布
  → build: 解析手动 tag 或上游最新稳定版
  → build
      → Setup Environment → Install Toolchains
      → scripts/full-build.sh
          → Load Config / Resolve Tag / Setup SDK
          → Configure Feeds & Patches / Prepare PassWall Sources
          → Generate .config / Compile Packages
          → Collect APK Payload / Smoke Install Check
          → Build .run Installer
  → release
```

`scripts/full-build.sh` 是线上 Action 和本地 `full` 模式共享的构建内核；workflow 只负责加载集中配置、解析触发上下文、准备 runner 环境、调用共享内核、上传产物与 release 封装。本地 `scripts/local-build.sh --mode full` 也直接走同一条 full build 路径，避免线上/本地行为漂移。

共享 full build 内核会根据当前构建对应的 PassWall release tag，克隆匹配 tag 的 `openwrt-passwall`，并对 `openwrt-passwall-packages` 采用“优先同名 tag、否则回退默认分支”的策略；随后从 `luci-app-passwall` 的 Makefile 自动分析默认启用的功能开关，并结合目标架构条件生成 PassWall 根包列表。编译完成后，会先把本地产物构造成一个临时 APK 仓库，再让 `apk fetch --recursive` 同时从“本地仓库 + 与 SDK 同版本同架构的官方 OpenWrt 仓库”解析并抓取完整依赖闭包，生成 payload 的 `SHA256SUMS` 校验清单，最后一起打包进 `.run`。

## 本地验证入口 | Local Validation Entry

可使用 `scripts/local-build.sh` 执行本地验证或本地完整打包：

```bash
./scripts/local-build.sh --tag 26.2.6-1
```

默认是 `smoke` 模式：脚本会验证配置加载、tag 解析、payload 校验、安装脚本主流程以及 `.run` 打包链路，而无需真的编译 OpenWrt SDK。

若要执行本地 `full` 模式，可传入一个已准备好的 SDK 目录，以及可选的本地 PassWall 源码目录：

```bash
./scripts/local-build.sh --mode full \
  --sdk-root /path/to/openwrt-sdk \
  --passwall-luci-dir /path/to/openwrt-passwall \
  --passwall-packages-dir /path/to/openwrt-passwall-packages \
  --tag 26.2.6-1
```

`full` 模式现在直接委托给 `scripts/full-build.sh`，与 GitHub Actions 共用同一条 full build 链路。若不传 `--sdk-root`，脚本会自动根据 `config/config.conf` 中的 `OPENWRT_SDK_URL` 下载并解包 SDK；若不传本地源码目录，则会按当前 tag 自动克隆配置文件中指定的 PassWall 仓库。若不传 `--tag`，脚本会自动查询配置文件指定上游仓库的最新稳定版 tag。共享 full build 还会在进入 Rust host 编译前预取并校验 `rustc` 源码包，减少本地大文件下载中途重置导致的卡顿。默认产物输出到系统临时目录下的 `passwall-local-build-output/`，可通过 `--output-dir` 自定义。

如需直接调用共享 full build 内核，也可以执行：

```bash
./scripts/full-build.sh \
  --output-dir /path/to/out \
  --sdk-root /path/to/openwrt-sdk \
  --passwall-luci-dir /path/to/openwrt-passwall \
  --passwall-packages-dir /path/to/openwrt-passwall-packages \
  --tag 26.2.6-1
```

## 性能优化 | Performance

### Rust 编译加速

自动应用以下优化以加快 Rust 组件编译：

- **增量编译**: 禁用 `CARGO_INCREMENTAL=0`，避免生成无用增量产物占用磁盘
- **并行代码生成**: 默认 `-C codegen-units=8`，在编译时间与运行时性能间平衡
- **LTO 可选**: 默认关闭 `-C lto`，避免与 `embed-bitcode=no` 冲突，可通过 `RUST_LTO_MODE=thin/fat` 显式开启
- **优化级别**: 默认 `-C opt-level=3`，提升运行时性能
- **减少调试信息**: `CARGO_PROFILE_RELEASE_DEBUG=0` 加速编译和链接

由于每次构建均为全新流程（无 Build Cache），增量编译已禁用；并行代码生成可减少 Rust 组件的编译时间。

## 常见问题 | FAQ

### 为什么 shadow-tls 体积不大却编译很久？

- shadow-tls 本身代码量不多，但依赖链很重：主要依赖 `ring`，而 `ring` 会内置构建 BoringSSL/汇编优化代码，跨架构交叉编译时会完整编译一遍。
- Rust 交叉编译会同时构建目标架构的标准库和所有依赖的 release 版本，首次构建需要下载/编译完整的 crate 栈。
- 本仓库启用了并行代码生成（`-C codegen-units=8`）并禁用了增量编译（每次均为全新构建，无缓存复用）。Rust 组件（尤其是 shadow-tls、shadowsocks-rust）首次编译耗时较长属正常现象。

### 如何更换目标架构？

修改 `config/config.conf` 中的 `OPENWRT_SDK_URL`，使用与目标设备匹配的 SDK。例如 aarch64 设备使用 `aarch64_cortex-a53` 对应的 SDK。

### xray-plugin 编译失败？

xray-plugin 可能因为其依赖 `github.com/sagernet/sing` 与较新版本的 Go（如 Go 1.25+）不兼容而编译失败，报错类似 `invalid reference to net.errNoSuchInterface`。这是上游依赖兼容性问题，需要等待 [openwrt-passwall-packages](https://github.com/Openwrt-Passwall/openwrt-passwall-packages) 更新 xray-plugin 或其依赖版本后才能解决。当前工作流采用失败即终止策略，因此若它位于本次默认启用的构建集合中，编译失败会直接导致 workflow 失败。

## License

遵循上游仓库 LICENSE。感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)。
