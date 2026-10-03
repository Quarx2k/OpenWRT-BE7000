include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=13
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)
PKG_LICENSE:=Apache-2.0
LUCI_MAINTAINER:=Nickolai Semendiaev <agent00791@gmail.com>

LUCI_TITLE:=BE7000 5 GHz radio mode
LUCI_DEPENDS:=@TARGET_qualcommbe_ipq95xx +luci-base +rpcd +bash +flock +jshn +iw +jsonfilter

define Package/luci-app-be7000-wifi/conffiles
/etc/config/be7000_wifi
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
