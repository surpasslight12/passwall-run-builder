#!/bin/bash
set -e

# ============================================================
# PassWall Installer Script
# Improved error handling and logging
# ============================================================

# Logging functions
log_info() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

log_warning() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $*" >&2
}

log_error() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

log_success() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $*"
}

# Error handler
handle_error() {
	local exit_code=$?
	local line_number=$1
	log_error "Script failed at line $line_number with exit code $exit_code"
	log_error "脚本在第 $line_number 行失败，退出码: $exit_code"
	exit $exit_code
}

trap 'handle_error $LINENO' ERR

log_info "Starting PassWall installation..."
log_info "开始安装 PassWall..."

# Extract version numbers from package filenames
pw_pkg=""
pwzh_pkg=""
for candidate in luci-app-passwall-*.apk luci-app-passwall_*.apk; do
	if [ -e "$candidate" ]; then
		pw_pkg="$candidate"
		break
	fi
done
for candidate in luci-i18n-passwall-zh-cn-*.apk luci-i18n-passwall-zh-cn_*.apk; do
	if [ -e "$candidate" ]; then
		pwzh_pkg="$candidate"
		break
	fi
done
pw_ver=""
pwzh_ver=""
if [ -n "$pw_pkg" ]; then
	pw_base=$(basename "$pw_pkg" | sed -E 's/^luci-app-passwall[-_]//; s/\.apk$//')
	if echo "$pw_base" | grep -q '_'; then
		pw_ver="${pw_base%_*}"
	else
		pw_ver="${pw_base%-all}"
	fi
fi
if [ -n "$pwzh_pkg" ]; then
	pwzh_base=$(basename "$pwzh_pkg" | sed -E 's/^luci-i18n-passwall-zh-cn[-_]//; s/\.apk$//')
	if echo "$pwzh_base" | grep -q '_'; then
		pwzh_ver="${pwzh_base%_*}"
	else
		pwzh_ver="${pwzh_base%-all}"
	fi
fi

# Validate versions were extracted successfully
if [ -z "$pw_pkg" ] || [ -z "$pw_ver" ]; then
	log_error "Failed to detect luci-app-passwall version"
	log_error "无法检测到 luci-app-passwall 版本"
	log_info "Troubleshooting: Ensure the .run file was extracted correctly"
	log_info "排查建议：请确保 .run 文件已正确解压"
	exit 1
fi

if [ -n "$pwzh_pkg" ] && [ -z "$pwzh_ver" ]; then
	log_error "Failed to parse luci-i18n-passwall-zh-cn version from package filename"
	log_error "无法从安装包文件名解析 luci-i18n-passwall-zh-cn 版本"
	exit 1
fi

log_info "Detected PassWall version: $pw_ver"
log_info "检测到 PassWall 版本：$pw_ver"

# Update package lists with retry logic
MAX_RETRIES=3
RETRY_DELAY=5
for attempt in $(seq 1 $MAX_RETRIES); do
	log_info "Updating package lists (attempt $attempt/$MAX_RETRIES)..."
	log_info "正在更新软件源列表 (尝试 $attempt/$MAX_RETRIES)..."
	if apk update; then
		log_info "Package lists updated successfully"
		break
	else
		if [ $attempt -eq $MAX_RETRIES ]; then
			log_error "Failed to update package lists after $MAX_RETRIES attempts"
			log_error "更新软件源列表失败，已尝试 $MAX_RETRIES 次"
			log_info "Troubleshooting: Check network connection and repository configuration"
			log_info "排查建议：请检查路由器网络连接以及软件源配置"
			exit 1
		fi
		log_warning "Update failed, retrying in ${RETRY_DELAY}s..."
		log_warning "更新失败，${RETRY_DELAY}秒后重试..."
		sleep $RETRY_DELAY
		RETRY_DELAY=$((RETRY_DELAY * 2))
	fi
done

# Check for and update legacy dependencies from older firmware versions
if apk list -I libsodium | grep -Eq "\d.\d.\d{2}-\d" || apk list -I boost | grep -Eq "\d.\d{2}.\d-\d"; then
	log_info "Detected legacy dependency versions from firmware upgrade, updating dependencies..."
	log_info "检测到旧版本固件升级保留的依赖版本问题，正在更新相关依赖..."
	if ! apk add libev libsodium libudns boost boost-system boost-program_options libltdl7 liblua5.3-5.3 libcares coreutils-base64 coreutils-nohup; then
		log_warning "Some dependencies may have failed to update. Installation will continue..."
		log_warning "部分依赖更新可能失败。安装将继续..."
	fi
fi

# Install PassWall packages
# Note: For local .apk files with --allow-untrusted, APK requires explicit removal before reinstallation
# We remove existing packages first, then add the new ones. This is the proper method for local packages.
if [ -n "$pwzh_pkg" ]; then
	set -- "$pw_pkg" "$pwzh_pkg"
else
	log_info "luci-i18n-passwall-zh-cn package not found, continuing without it"
	log_info "未找到 luci-i18n-passwall-zh-cn 软件包，将跳过安装"
	set -- "$pw_pkg"
fi

deps_added=0
if [ -d depends ]; then
	for dep in depends/*.apk; do
		if [ -e "$dep" ]; then
			set -- "$@" "$dep"
			deps_added=$((deps_added + 1))
		fi
	done
	log_info "Found $deps_added dependency packages in depends/"
	log_info "在 depends/ 目录下找到 $deps_added 个依赖包"
fi

if [ "$deps_added" -eq 0 ]; then
	log_warning "No dependency packages found under depends/"
	log_warning "depends/ 目录下未找到依赖包"
fi

set -- "$@" haproxy

if apk list -I luci-app-passwall | grep -q "$pw_ver"; then
	log_info "Same version detected, performing forced reinstallation of PassWall $pw_ver"
	log_info "发现相同版本，正在执行强制重新安装 PassWall $pw_ver"
	
	# Remove existing packages first, then reinstall
	log_info "Removing existing PassWall packages..."
	log_info "正在移除现有的 PassWall 软件包..."
	for pkg in luci-app-passwall luci-i18n-passwall-zh-cn; do
		if apk info -e "$pkg" >/dev/null 2>&1; then
			log_info "Removing: $pkg"
			if ! apk del "$pkg"; then
				log_warning "Failed to remove $pkg, continuing anyway..."
			fi
		fi
	done
	
	log_info "Installing PassWall $pw_ver..."
	log_info "正在安装 PassWall $pw_ver..."
	if ! apk add --allow-untrusted "$@"; then
		log_error "PassWall reinstallation failed"
		log_error "PassWall 重新安装失败"
		log_info "Troubleshooting: Check if all dependencies are available"
		log_info "排查建议：请检查所有依赖是否可用"
		exit 1
	fi
else
	log_info "Installing PassWall $pw_ver"
	log_info "正在安装 PassWall $pw_ver"
	if ! apk add --allow-untrusted "$@"; then
		log_error "PassWall installation failed"
		log_error "PassWall 安装失败"
		log_info "Troubleshooting: Check if all dependencies are available"
		log_info "排查建议：请检查所有依赖是否可用"
		exit 1
	fi
fi

log_success "PassWall $pw_ver installed successfully"
log_success "PassWall $pw_ver 安装完成"
log_info "Please restart PassWall service: /etc/init.d/passwall restart"
log_info "请重启 PassWall 服务: /etc/init.d/passwall restart"

exit 0
