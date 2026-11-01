#!/bin/bash

# ============================================================
# AX5 side-gateway custom build
#   1. default LAN IP -> 192.168.5.250 (reachable from the main router,
#      so no direct-ethernet session is ever needed after flashing)
#   2. argon theme as default
#   3. add kenzok8 small-package feed
# ============================================================

sed -i 's/192\.168\.1\.1/192.168.5.250/g' package/base-files/files/bin/config_generate

# default theme: argon
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# argon background
cp -f $GITHUB_WORKSPACE/images/bg1.jpg package/luci-theme-argon/htdocs/luci-static/argon/img/bg1.jpg

sed -i '$a src-git smpackage https://github.com/kenzok8/small-package' feeds.conf.default
./scripts/feeds update
rm -rf feeds/smpackage/{base-files,dnsmasq,firewall*,fullconenat,libnftnl,nftables,ppp,opkg,ucl,upx,vsftpd-alt,miniupnpd-iptables,wireless-regdb}
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 22.x feeds/packages/lang/golang

./scripts/feeds install -a
