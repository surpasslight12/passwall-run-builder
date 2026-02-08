#!/bin/sh
set -e

# ============================================================
# PassWall Installer Script for OpenWrt (APK-based)
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
	local exit_code=${LAST_EXIT_CODE:-$?}
	log_error "Script failed with exit code $exit_code"
	log_error "脚本失败，退出码: $exit_code"
	exit $exit_code
}

trap 'LAST_EXIT_CODE=$?; [ "$LAST_EXIT_CODE" -ne 0 ] && handle_error' EXIT

log_info "Starting PassWall installation..."
log_info "开始安装 PassWall..."

# ---- Detect package files and extract version strings ----
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

# Helper: extract version string from an APK filename.
# $1 - full package filename (e.g. luci-app-passwall-1.2.3_all.apk)
# $2 - package name prefix to strip (e.g. luci-app-passwall)
# Prints the version string (e.g. 1.2.3).
extract_ver() {
	local base
	base=$(basename "$1" | sed -E "s/^$2[-_]//; s/\.apk$//")
	if echo "$base" | grep -q '_'; then
		echo "${base%_*}"
	else
		echo "${base%-all}"
	fi
}

pw_ver=""
if [ -n "$pw_pkg" ]; then
	pw_ver=$(extract_ver "$pw_pkg" "luci-app-passwall")
fi
pwzh_ver=""
if [ -n "$pwzh_pkg" ]; then
	pwzh_ver=$(extract_ver "$pwzh_pkg" "luci-i18n-passwall-zh-cn")
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

# ---- Update package lists with retry & exponential backoff ----
MAX_RETRIES=3
RETRY_DELAY=5
MAX_DELAY=30
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
	log_info "Updating package lists (attempt $attempt/$MAX_RETRIES)..."
	log_info "正在更新软件源列表 (尝试 $attempt/$MAX_RETRIES)..."
	if apk update; then
		log_info "Package lists updated successfully"
		break
	fi
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
	if [ $RETRY_DELAY -gt $MAX_DELAY ]; then
		RETRY_DELAY=$MAX_DELAY
	fi
	attempt=$((attempt + 1))
done

# ---- Upgrade legacy dependencies left over from older firmware ----
# BusyBox grep: use [0-9] character classes instead of \d
if apk list -I libsodium | grep -Eq "[0-9]\.[0-9]\.[0-9][0-9]-[0-9]" || apk list -I boost | grep -Eq "[0-9]\.[0-9][0-9]\.[0-9]-[0-9]"; then
	log_info "Detected legacy dependency versions from firmware upgrade, updating dependencies..."
	log_info "检测到旧版本固件升级保留的依赖版本问题，正在更新相关依赖..."
	if ! apk add libev libsodium libudns boost boost-system boost-program_options libltdl7 liblua5.3-5.3 libcares coreutils-base64 coreutils-nohup; then
		log_warning "Some dependencies may have failed to update. Installation will continue..."
		log_warning "部分依赖更新可能失败。安装将继续..."
	fi
fi

# ---- Build the package list ----
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

# ---- Install / Reinstall PassWall ----
# For local .apk files with --allow-untrusted, APK requires explicit removal
# before reinstallation. Remove existing packages first when same version is detected.
if apk list -I luci-app-passwall | grep -q "$pw_ver"; then
	log_info "Same version detected, performing forced reinstallation of PassWall $pw_ver"
	log_info "发现相同版本，正在执行强制重新安装 PassWall $pw_ver"

	log_info "Removing existing PassWall packages..."
	log_info "正在移除现有的 PassWall 软件包..."
	for pkg in luci-app-passwall luci-i18n-passwall-zh-cn; do
		if apk info -e "$pkg" >/dev/null 2>&1; then
			log_info "Removing: $pkg"
			apk del "$pkg" || log_warning "Failed to remove $pkg, continuing anyway..."
		fi
	done
fi

log_info "Installing PassWall $pw_ver..."
log_info "正在安装 PassWall $pw_ver..."
if ! apk add --allow-untrusted "$@"; then
	log_error "PassWall installation failed"
	log_error "PassWall 安装失败"
	log_info "Troubleshooting: Check if all dependencies are available"
	log_info "排查建议：请检查所有依赖是否可用"
	exit 1
fi

log_success "PassWall $pw_ver installed successfully"
log_success "PassWall $pw_ver 安装完成"
log_info "Please restart PassWall service: /etc/init.d/passwall restart"
log_info "请重启 PassWall 服务: /etc/init.d/passwall restart"

exit 0
