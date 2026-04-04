# PassWall Installer Builder

通过 GitHub Actions 自动编译 [PassWall](https://github.com/Openwrt-Passwall/openwrt-passwall) 相关组件并收集所需依赖 APK，打包为 `.run` 自解压安装文件。

Builds PassWall components and required APK dependencies via GitHub Actions into a self-extracting `.run` installer.

## 特性 | Features

- 从 OpenWrt SDK 交叉编译 PassWall 相关组件，并收集所需依赖 APK
- 生成自解压 `.run` 安装包，一键部署到 OpenWrt 设备
- 支持自定义 SDK 版本和架构
- 每次执行完整构建，无增量编译，确保产物一致性
- **Rust 编译优化**（并行代码生成、优化 RUSTFLAGS）
- 编译自动降级（并行 → 单线程）
- 适配 OpenWrt 25.12+ APK 包管理器
- 按 luci-app-passwall 的默认功能开关与目标架构条件自动分析并本地编译 PassWall 相关组件
- 对缺失的系统依赖 APK 自动从官方 OpenWrt 源拉取并并入 `.run`
- 仅通过 `GO_VERSION` / `RUST_TOOLCHAIN_VERSION` 指定工具链版本，workflow 自动安装
- 安装前自动校验 payload 内全部文件的 SHA256
- 安装时仅使用 payload 内嵌仓库索引与包路径 manifest，避免默认 `dnsmasq`/`ip-tiny` 等 provider 与 PassWall 依赖冲突
- payload 采用统一目录结构：`apks/` 存放全部 APK，`metadata/` 存放安装清单与 manifest，安装逻辑更直接
- 安装器支持 `auto` / `top-level` / `whitelist` / `full` 模式，默认优先安装构建时生成的 PassWall 组件白名单
- payload 在打包前按包名去重，优先保留本地编译版本，减少版本漂移
- 支持手动触发构建，也支持定时同步上游稳定版 tag 后自动构建

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

  若要显式安装打包时生成的 PassWall 组件白名单，可使用：

  ```bash
  ssh root@openwrt 'cd /tmp && chmod +x passwall_*.run && ./passwall_*.run --install-mode whitelist'
  ```

### 安装模式 | Install Modes

- `auto`：默认模式；若 payload 包含 `INSTALL_WHITELIST`，则优先安装其中列出的 PassWall 组件，否则回退到 `TOPLEVEL_PACKAGES`
- `top-level`：仅安装顶层根包集合，行为与旧版安装器一致
- `whitelist`：安装构建阶段生成的 PassWall 组件白名单，适合希望一并更新相关插件二进制的场景
- `full`：安装 payload 内所有 APK，适合离线完整同步；该模式也会升级 payload 中携带的系统依赖

## 项目结构 | Structure

```
├── .github/workflows/
│   └── passwall.yml           # 统一工作流（配置加载 / 构建上下文 / 构建 / 发布）
├── config/
│   └── config.conf            # 集中化构建配置
├── scripts/
│   ├── build-lib.sh          # workflow / full-build / local-build 共用 helper
│   ├── full-build.sh          # 共享 full build 内核（Actions / 本地共用）
│   └── local-build.sh         # 本地 smoke/full 入口
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
| `GO_VERSION` | ✅ | Go 版本 |
| `RUST_TOOLCHAIN_VERSION` | ✅ | Rust 版本 |
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

共享 full build 内核会根据当前构建对应的 PassWall release tag，克隆匹配 tag 的 `openwrt-passwall`，并对 `openwrt-passwall-packages` 采用“优先同名 tag、否则回退默认分支”的策略；随后从 `luci-app-passwall` 的 Makefile 自动分析默认启用的功能开关，并结合目标架构条件生成 PassWall 根包列表。编译完成后，会先把本地产物构造成一个临时 APK 仓库，再让 `apk fetch --recursive` 同时从“本地仓库 + 与 SDK 同版本同架构的官方 OpenWrt 仓库”解析并抓取完整依赖闭包；payload 会在打包前按包名去重、优先保留本地构建版本，并额外生成 `INSTALL_WHITELIST` 供安装器默认使用。

当前 `.run` 内 payload 结构为：

```text
payload/
  install.sh
  apks/
    *.apk
    packages.adb
  metadata/
    TOPLEVEL_PACKAGES
    INSTALL_WHITELIST
    PAYLOAD_APK_MAP
  SHA256SUMS
```

## 本地验证入口 | Local Validation Entry

可使用 `scripts/local-build.sh` 执行本地验证或本地完整打包：

```bash
./scripts/local-build.sh --tag 26.4.1-1
```

默认是 `smoke` 模式：脚本会验证配置加载、tag 解析、payload 校验、payload 依赖摘要生成、安装脚本主流程以及 `.run` 打包链路，而无需真的编译 OpenWrt SDK。

若要执行本地 `full` 模式，可传入一个已准备好的 SDK 目录，以及可选的本地 PassWall 源码目录：

```bash
./scripts/local-build.sh --mode full \
  --sdk-root /path/to/openwrt-sdk \
  --passwall-luci-dir /path/to/openwrt-passwall \
  --passwall-packages-dir /path/to/openwrt-passwall-packages \
  --tag 26.4.1-1
```

`full` 模式现在直接委托给 `scripts/full-build.sh`，与 GitHub Actions 共用同一条 full build 链路。若不传 `--sdk-root`，脚本会自动根据 `config/config.conf` 中的 `OPENWRT_SDK_URL` 下载并解包 SDK；若不传本地源码目录，则会按当前 tag 自动克隆配置文件中指定的 PassWall 仓库。若不传 `--tag`，脚本会自动查询配置文件指定上游仓库的最新稳定版 tag。共享 full build 还会在进入 Rust host 编译前预取并校验 `rustc` 源码包，减少本地大文件下载中途重置导致的卡顿。默认产物输出到系统临时目录下的 `passwall-local-build-output/`，可通过 `--output-dir` 自定义。

如需直接调用共享 full build 内核，也可以执行：

```bash
./scripts/full-build.sh \
  --output-dir /path/to/out \
  --sdk-root /path/to/openwrt-sdk \
  --passwall-luci-dir /path/to/openwrt-passwall \
  --passwall-packages-dir /path/to/openwrt-passwall-packages \
  --tag 26.4.1-1
```

## License

遵循上游仓库 LICENSE。感谢 [Openwrt-Passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)。
