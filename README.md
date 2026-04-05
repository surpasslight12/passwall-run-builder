# PassWall Installer Builder

基于 OpenWrt SDK 编译 PassWall 组件并打包为 `.run` 安装器，支持 GitHub Actions 与本地构建。

## 目录结构

```text
config/config.conf           # 构建配置
scripts/lib.sh               # 公共函数库
scripts/build.sh             # 完整构建入口（CI/本地共用）
scripts/smoke.sh             # 本地烟雾测试入口
payload/install.sh           # 设备安装脚本
```

## 配置

核心变量位于 `config/config.conf`：

- `OPENWRT_SDK_URL`：OpenWrt SDK 地址
- `OPENWRT_SOURCE_CDN_URL` / `OPENWRT_SOURCE_MIRROR_URL` / `GOPROXY`：可选下载加速参数
- `PASSWALL_ALL_PACKAGES`：上游包全集（用于校验）
- `PASSWALL_REQUIRED_PACKAGES`：必选编译组件（允许包含 OpenWrt feed/system 包）
- `PASSWALL_OPTIONAL_SELECTED_PACKAGES`：已选可选组件（会编译）
- `PASSWALL_OPTIONAL_UNSELECTED_PACKAGES`：未选可选组件（默认不编译）

PassWall 上游仓库与 OpenWrt feed 源已在脚本内固定，不再作为配置项。

启用未选组件：把组件从 `PASSWALL_OPTIONAL_UNSELECTED_PACKAGES` 移到 `PASSWALL_OPTIONAL_SELECTED_PACKAGES`。

## 构建方式

### GitHub Actions

手动触发 `.github/workflows/passwall.yml`，输入 `mode=build`（或 `sync-and-build`），可选输入 `tag`。

### 本地烟雾测试

```bash
./scripts/smoke.sh --tag 26.4.1-1
```

### 本地完整构建

```bash
./scripts/build.sh \
  --output-dir /path/to/out \
  --sdk-root /path/to/openwrt-sdk \
  --tag 26.4.1-1
```

## 安装器

- `--auto`：安装白名单包（默认）
- `--full`：安装 payload 全部 APK

安装器默认启用版本保护：跳过设备上已有同版本或更高版本的包。

```bash
scp passwall_*.run root@openwrt:/tmp/
ssh root@openwrt 'cd /tmp && chmod +x passwall_*.run && ./passwall_*.run --auto'
```

## 输出物

`.run` payload 结构：

```text
payload/
  install.sh
  apks/*.apk
  apks/packages.adb
  metadata/INSTALL_WHITELIST
  metadata/PAYLOAD_APK_MAP
  SHA256SUMS
```

## License

遵循上游仓库 License。
