#!/bin/bash
set -e

# Extract version numbers from package filenames
pw_pkg=$(ls luci-app-passwall-*.apk luci-app-passwall_*.apk 2>/dev/null | head -n1)
pwzh_pkg=$(ls luci-i18n-passwall-zh-cn-*.apk luci-i18n-passwall-zh-cn_*.apk 2>/dev/null | head -n1)
pw_ver=$(basename "$pw_pkg" | sed -E 's/^luci-app-passwall[-_]//; s/\.apk$//; s/(_all|-all)$//')
pwzh_ver=$(basename "$pwzh_pkg" | sed -E 's/^luci-i18n-passwall-zh-cn[-_]//; s/\.apk$//; s/(_all|-all)$//')

# Validate versions were extracted successfully
if [ -z "$pw_pkg" ] || [ -z "$pw_ver" ]; then
	echo "ERROR: Failed to detect luci-app-passwall version"
	echo "错误：无法检测到 luci-app-passwall 版本"
	exit 1
fi

if [ -z "$pwzh_pkg" ] || [ -z "$pwzh_ver" ]; then
	echo "ERROR: Failed to detect luci-i18n-passwall-zh-cn version"
	echo "错误：无法检测到 luci-i18n-passwall-zh-cn 版本"
	exit 1
fi

echo "Detected PassWall version: $pw_ver"
echo "检测到 PassWall 版本：$pw_ver"

# Update package lists
apk update
if [ $? -ne 0 ]; then
	echo "ERROR: Failed to update package lists. Please check network connection and repository configuration."
	echo "错误：更新软件源列表失败，请检查路由器网络连接以及软件源配置。"
	exit 1
fi

# Check for and update legacy dependencies from older firmware versions
if apk list -I libsodium | grep -Eq "\d.\d.\d{2}-\d" || apk list -I boost | grep -Eq "\d.\d{2}.\d-\d"; then
	echo "Detected legacy dependency versions from firmware upgrade, updating dependencies..."
	echo "检测到旧版本固件升级保留的依赖版本问题，正在更新相关依赖..."
	apk add libev libsodium libudns boost boost-system boost-program_options libltdl7 liblua5.3-5.3 libcares coreutils-base64 coreutils-nohup
	if [ $? -ne 0 ]; then
		echo "WARNING: Some dependencies may have failed to update. Installation will continue..."
		echo "警告：部分依赖更新可能失败。安装将继续..."
	fi
fi

# Install PassWall packages
# Note: For local .apk files with --allow-untrusted, APK requires explicit removal before reinstallation
# We remove existing packages first, then add the new ones. This is the proper method for local packages.
if apk list -I luci-app-passwall | grep -q "$pw_ver"; then
	echo "Same version detected, performing forced reinstallation of PassWall $pw_ver"
	echo "发现相同版本，正在执行强制重新安装 PassWall $pw_ver"
	# Remove existing packages first, then reinstall
	# Check if packages are installed before attempting removal to avoid unnecessary errors
	echo "Removing existing PassWall packages..."
	echo "正在移除现有的 PassWall 软件包..."
	for pkg in luci-app-passwall luci-i18n-passwall-zh-cn; do
		if apk info -e "$pkg" >/dev/null 2>&1; then
			apk del "$pkg"
		fi
	done
	apk add --allow-untrusted "$pw_pkg" "$pwzh_pkg" depends/*.apk haproxy
	if [ $? -ne 0 ]; then
		echo "ERROR: PassWall reinstallation failed"
		echo "错误：PassWall 重新安装失败"
		exit 1
	fi
else
	echo "Installing PassWall $pw_ver"
	echo "正在安装 PassWall $pw_ver"
	apk add --allow-untrusted "$pw_pkg" "$pwzh_pkg" depends/*.apk haproxy
	if [ $? -ne 0 ]; then
		echo "ERROR: PassWall installation failed"
		echo "错误：PassWall 安装失败"
		exit 1
	fi
fi

echo "SUCCESS: PassWall $pw_ver installed successfully"
echo "成功：PassWall $pw_ver 安装完成"

exit 0
