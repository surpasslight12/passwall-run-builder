#!/bin/sh

pw_ver=`ls | grep luci-app | awk -F'[_]' '{print $2}'`
pwzh_ver=`ls | grep luci-i18n | awk -F'[_-]' '{print $6}'`

opkg update
if [ $? -ne 0 ]; then
		echo "更新软件源列表错误，请检查路由器自身网络连接以及是否有失效的软件源。"
		exit 1
fi

if opkg list-installed libsodium | grep -Eq "\d.\d.\d{2}-\d" || opkg list-installed boost | grep -Eq "\d.\d{2}.\d-\d"; then
	echo "检测到旧版本固件升级保留的依赖版本问题，更新相关依赖"
	opkg install libev libsodium libudns boost boost-system boost-program_options libltdl7 liblua5.3-5.3 libcares coreutils-base64 coreutils-nohup
fi

if opkg list-installed luci-app-passwall | grep -q "$pw_ver"; then
	echo "发现相同版本，正在执行强制重新安装passwall "$pw_ver""
	opkg install luci-app-passwall_"$pw_ver"_all.ipk luci-i18n-passwall-zh-cn_"$pwzh_ver"_all.ipk depends/*.ipk haproxy --force-reinstall
else
	echo "正在安装passwall "$pw_ver""
	opkg install luci-app-passwall_"$pw_ver"_all.ipk luci-i18n-passwall-zh-cn_"$pwzh_ver"_all.ipk depends/*.ipk haproxy
fi

exit 0
