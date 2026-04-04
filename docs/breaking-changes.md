# 破坏性重构说明

本文档记录本轮极简重构的删除项、保留项与迁移方式，用于替代旧行为兼容说明。

## 已删除项

- 安装器模式 `top-level` 已删除。
- 安装器模式 `whitelist` 已删除（由 `--auto` 统一承载）。
- 安装器参数 `--install-mode` 与 `--force-reinstall` 已删除。
- payload 元数据 `metadata/TOPLEVEL_PACKAGES` 已从生产与消费链路移除。
- `config/config.conf` 中已删除以下配置项：
  - `PASSWALL_UPSTREAM_OWNER`
  - `PASSWALL_UPSTREAM_REPO`
  - `OPENWRT_BASE_FEED_REPO`
  - `OPENWRT_PACKAGES_FEED_REPO`
  - `OPENWRT_LUCI_FEED_REPO`
  - `OPENWRT_ROUTING_FEED_REPO`
  - `OPENWRT_TELEPHONY_FEED_REPO`
  - `GO_VERSION`
  - `RUST_TOOLCHAIN_VERSION`

## 保留项

- 安装器模式保留为 `auto|full`。
- `auto` 为默认模式，读取 `INSTALL_WHITELIST`。
- payload 最小闭集保留为：
  - `metadata/INSTALL_WHITELIST`
  - `metadata/PAYLOAD_APK_MAP`
  - `apks/packages.adb`
  - `SHA256SUMS`

## 迁移指南

1. 旧命令中若包含 `--install-mode top-level` 或 `--install-mode whitelist`，统一改为 `--auto`。
2. 旧命令中若包含 `--install-mode full`，改为 `--full`。
3. `--force-reinstall` 与 `PASSWALL_INSTALL_FORCE_REINSTALL` 已不可用；安装器默认启用版本保护跳过同版/更高版包。
4. 依赖 `TOPLEVEL_PACKAGES` 的下游脚本需改为读取 `INSTALL_WHITELIST`。
5. CI 与自动化脚本不应再从 `config/config.conf` 读取上游仓库与 toolchain 版本配置。

## 本轮重构结果

- 入口收敛：CI 构建入口已统一到 `scripts/local-build.sh --mode full`。
- 阶段拆分：
  - feeds 配置阶段已拆分为独立子函数。
  - 源码准备阶段已拆分为独立子函数。
  - 编译阶段已拆分为源目录解析、执行编译、输出摘要三个函数。
- 回归结果：语法检查与本地 smoke 均通过。
