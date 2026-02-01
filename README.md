# PassWall Installer CI

本项目基于上游开源项目 [Openwrt-Passwall/openwrt-passwall](https://github.com/Openwrt-Passwall/openwrt-passwall)，使用 GitHub Actions 在 CI 中自动：

- 下载指定版本的 OpenWrt SDK；
- 接入 openwrt-passwall 官方推荐的 feeds；
- 编译 `luci-app-passwall` 及其依赖 IPK；
- 将编译出的 IPK 自动填充到本仓库的 `payload/` 目录；
- 使用 makeself 生成自解压 `.run` 安装包。

整体行为：

- 需要手工维护的只有 `payload/install.sh`（已根据官方 install.sh 写好）。其余 IPK 由 GitHub Actions 自动编译并放入：
   - `payload/luci-app-passwall_*.ipk`
   - `payload/luci-i18n-passwall-zh-cn_*.ipk`
   - `payload/depends/*.ipk`
- GitHub Actions 工作流位于 `.github/workflows/build-installer.yml`。
- 每次推送 tag（如 `v26.1.21`）或手动触发 workflow 时，会在 CI 中生成形如 `PassWall_<版本号>_x86_64_all_sdk_24.10.run` 的安装包并作为构建工件（artifact）上传，并在 tag 情况下自动创建 GitHub Release 并附加该 .run 文件。

## 使用步骤

1. 将本目录初始化为 Git 仓库并推送到 GitHub：

   ```bash
   git init
   git add .
   git commit -m "init PassWall installer project"
   git branch -M main
   git remote add origin git@github.com:<your-account>/passwall-installer.git
   git push -u origin main
   ```

2. 在 GitHub 仓库的 **Actions** 页面启用 workflow。

3. 根据你的设备和 OpenWrt 版本，修改 `config/openwrt-sdk.conf` 中的 `OPENWRT_SDK_URL` 为对应的 OpenWrt SDK 下载链接（当前默认示例为 x86_64 的 23.05.3 SDK），**无需修改 GitHub Actions 文件本身**。

4. 给仓库打一个版本 tag 触发构建：

   ```bash
   git tag v26.1.21
   git push origin v26.1.21
   ```

5. 在构建完成后，到该 workflow 的构建详情页中下载 artifact（名称类似 `PassWall_<版本号>_x86_64_all_sdk_24.10.run`）。

   对于通过 tag 触发的构建，还可以在对应的 GitHub Release 页面直接下载该 `.run` 文件。

## 自定义安装内容

- 将你真实的程序、脚本等放到 `payload/` 目录中。
- 编辑 `payload/install.sh`，实现实际的安装逻辑（复制文件、注册服务等）。

> 提示：现有的官方 `.run` 安装包信息显示，其是使用 makeself 以 `PassWall_26.1.21_with_sdk_24.10` 作为标识字符串打包的，并在解压后执行 `./install.sh`。本项目生成的 `.run` 在这两点上与原包保持一致，你只需要确保 `payload/` 目录中的内容和你的实际发布内容匹配即可。

### 与上游项目的关系

- 上游源码仓库：<https://github.com/Openwrt-Passwall/openwrt-passwall>
- 你可以按照上游 README 中的说明，在 OpenWrt 源码/SDK 中编译出 `luci-app-passwall` 及其依赖 IPK，然后将这些 IPK 拷贝到本项目的 `payload/` 中：
   - `payload/luci-app-passwall_*.ipk`
   - `payload/luci-i18n-passwall-zh-cn_*.ipk`
   - `payload/depends/*.ipk`
- 本项目的 `payload/install.sh` 已根据官方安装脚本编写，会在 OpenWrt 设备上调用 `opkg` 安装/强制重装这些 IPK，并处理部分旧依赖问题。
- **注意**：由于某些依赖包（如 xray-core、v2ray-plugin 等）在 OpenWrt SDK 24.10 下编译可能失败，workflow 会自动从官方 PassWall 发布中下载预编译包作为补充，确保所有依赖都能正确包含在最终的安装包中。

生成的 `.run` 文件可以直接在 Linux 上执行：

```bash
chmod +x PassWall_26.1.21_x86_64_all_sdk_24.10.run
./PassWall_26.1.21_x86_64_all_sdk_24.10.run
```

## 依赖包说明

本项目生成的安装包包含以下依赖（20+ 个 IPK 文件）：

- **核心代理工具**：xray-core, sing-box, v2ray-plugin, xray-plugin
- **传输协议**：
  - shadowsocks-libev (ss-local, ss-redir, ss-server)
  - shadowsocks-rust (sslocal, ssserver)
  - shadowsocksr-libev (ssr-local, ssr-redir, ssr-server)
  - trojan-plus, hysteria, naiveproxy, tuic-client
- **辅助工具**：chinadns-ng, dns2socks, ipt2socks, microsocks, simple-obfs-client, tcping, shadow-tls
- **地理数据**：v2ray-geoip, v2ray-geosite, geoview

这些依赖包通过以下方式获取：
1. 优先尝试从源码编译（使用 OpenWrt SDK，Go/Rust 工具链来自 OpenWrt 社区包 master 分支以获取最新版本）
2. 对于编译失败的包，自动从 SourceForge 上的官方 PassWall 预编译版本下载补充
3. 作为最后的回退，尝试从 OpenWrt 官方发布源 (https://downloads.openwrt.org/releases/) 下载

## Go/Rust 工具链

本项目使用 OpenWrt 社区包仓库的 master 分支 (https://github.com/openwrt/packages/tree/master) 来获取最新的 Go 和 Rust 编译工具链。这确保了：

- **Go**: 使用最新版本，满足 xray-core、v2ray-plugin、geoview、hysteria 等包对 Go >= 1.24.0 的要求
- **Rust**: 使用最新版本，满足 shadowsocks-rust、shadow-tls 等包的编译需求

通过使用 master 分支的工具链，可以编译更多的 PassWall 依赖包，减少对预编译包的依赖。

## 常见问题 / FAQ

### 构建过程中出现 Kconfig 警告

在 CI 构建过程中，你可能会看到类似如下的警告信息：

```
tmp/.config-package.in:677:warning: ignoring type redefinition of 'LUCI_LANG_zh_Hant' from 'bool' to 'tristate'
tmp/.config-package.in:1244:warning: ignoring type redefinition of 'PACKAGE_cgi-io' from 'bool' to 'tristate'
Config-build.in:1247:warning: defaults for choice values not supported
```

**这些警告是正常的，不会影响最终的编译结果。** 它们是 OpenWrt 的 Kconfig 配置系统在合并多个软件包的配置选项时产生的通知信息。本项目通过使用 `yes '' | make defconfig` 自动接受所有默认配置，确保 CI 构建不会在配置阶段卡住等待用户输入。

### 构建失败或超时

如果 GitHub Actions 构建失败或超时：
1. 检查 OpenWrt SDK 的下载链接是否有效
2. 查看构建日志，确认是网络问题还是编译错误
3. 某些依赖包可能需要特定版本的 SDK，可以尝试切换 SDK 版本

# passwall_run
