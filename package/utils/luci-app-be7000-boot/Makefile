include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)
PKG_LICENSE:=Apache-2.0
LUCI_MAINTAINER:=Nickolai Semendiaev <agent00791@gmail.com>
LUCI_TITLE:=BE7000 reboot into Xiaomi firmware
LUCI_DEPENDS:=@TARGET_qualcommbe_ipq95xx +luci-base +rpcd-mod-file +be7000-usb +bash

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
