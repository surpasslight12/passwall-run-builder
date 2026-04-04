# PassWall Installer Builder

基于 OpenWrt SDK 编译 PassWall 组件并打包为 `.run` 安装器，支持 GitHub Actions 与本地构建。

## 破坏性变更说明

- 编译清单不再由 luci Makefile 动态推导，改为静态分组驱动。
- 只会编译：PassWall 本体 + 必选组件 + 已选可选组件。
- `shadowsocks-libev` / `shadowsocks-rust` / `v2ray-plugin` 默认移入未选列表，按需启用。

## 目录结构

```text
config/config.conf           # 构建配置
scripts/build-lib.sh         # 公共函数库
scripts/full-build.sh        # 完整构建入口（CI/本地共用）
scripts/local-build.sh       # 本地 smoke/full 入口
payload/install.sh           # 设备安装脚本
```

## 配置模型

核心变量位于 `config/config.conf`：

- `PASSWALL_ALL_PACKAGES`：上游包全集（用于清单校验）
- `PASSWALL_REQUIRED_PACKAGES`：必选编译组件（允许包含 OpenWrt feed/system 包）
- `PASSWALL_OPTIONAL_SELECTED_PACKAGES`：已选可选组件（会编译）
- `PASSWALL_OPTIONAL_UNSELECTED_PACKAGES`：未选可选组件（默认不编译）

启用未选组件方法：把组件从 `PASSWALL_OPTIONAL_UNSELECTED_PACKAGES` 移到 `PASSWALL_OPTIONAL_SELECTED_PACKAGES`。

## 构建方式

### GitHub Actions

- 手动触发 `.github/workflows/passwall.yml`
- 输入 `mode=build`（或 `sync-and-build`）
- 可选输入 `tag`

### 本地 smoke

```bash
./scripts/local-build.sh --mode smoke --tag 26.4.1-1
```

### 本地 full

```bash
./scripts/local-build.sh --mode full \
  --sdk-root /path/to/openwrt-sdk \
  --tag 26.4.1-1
```

也可直接调用：

```bash
./scripts/full-build.sh \
  --output-dir /path/to/out \
  --sdk-root /path/to/openwrt-sdk \
  --tag 26.4.1-1
```

## 安装器模式

- `auto`：优先 `INSTALL_WHITELIST`，否则回退 `TOPLEVEL_PACKAGES`
- `top-level`：只安装顶层包
- `whitelist`：安装白名单
- `full`：安装 payload 全部 APK

默认不会强制重装（不带 `--force-reinstall`），用于避免 payload 中旧版本覆盖设备已安装的新版本。

如需强制覆盖，可显式添加：`--force-reinstall`，或设置环境变量 `PASSWALL_INSTALL_FORCE_REINSTALL=1`。

设备安装示例：

```bash
scp passwall_*.run root@openwrt:/tmp/
ssh root@openwrt 'cd /tmp && chmod +x passwall_*.run && ./passwall_*.run --install-mode whitelist'
```

## 输出物

`.run` payload 结构：

```text
payload/
  install.sh
  apks/*.apk
  apks/packages.adb
  metadata/TOPLEVEL_PACKAGES
  metadata/INSTALL_WHITELIST
  metadata/PAYLOAD_APK_MAP
  SHA256SUMS
```

## License

遵循上游仓库 License。
