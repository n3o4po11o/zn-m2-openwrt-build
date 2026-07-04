#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part3.sh
# Description: OpenWrt DIY script part 3 (After Install feeds)
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.100.1/g' package/base-files/files/bin/config_generate

#修改版本信息
sed -i "s/DISTRIB_DESCRIPTION='*.*'/DISTRIB_DESCRIPTION='OpenWrt IPQ6000 ZN-M2 (build time: $(date +%Y%m%d))'/g"  package/base-files/files/etc/openwrt_release
# 替换golang版本为1.26
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang

# 替换源码/feeds 自带的 mosdns、v2ray-geodata 为 sbwml 版本 (luci-app-mosdns v5)
# 1) 先清理可能存在的旧克隆，保证脚本可重复执行（不残留被破坏的 Makefile）
rm -rf package/mosdns package/v2ray-geodata
# 2) 删除源码/feeds 自带的 Makefile（feeds/packages 真实文件 + package/feeds 软链均会命中）
find ./ -name Makefile | grep -E 'mosdns|v2ray-geodata' | xargs -r rm -f
# 3) 引入 sbwml 维护的 mosdns (含 luci-app-mosdns v5) 与 v2ray-geodata
git clone https://github.com/sbwml/luci-app-mosdns -b v5 package/mosdns
git clone https://github.com/sbwml/v2ray-geodata package/v2ray-geodata

# ttyd免登陆
sed -i -r 's#/bin/login#/bin/login -f root#g' feeds/packages/utils/ttyd/files/ttyd.config

# design修改proxy链接
sed -i -r "s#navbar_proxy = 'openclash'#navbar_proxy = 'passwall'#g" feeds/luci/themes/luci-theme-design/luasrc/view/themes/design/header.htm
