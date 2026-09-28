include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=7
PKG_LICENSE:=Apache-2.0
LUCI_MAINTAINER:=Nickolai Semendiaev <agent00791@gmail.com>
LUCI_TITLE:=BE7000 NFC Wi-Fi sharing
LUCI_DEPENDS:=@TARGET_qualcommbe_ipq95xx +luci-base +rpcd +bash +flock +jshn +i2c-tools +coreutils-sleep

define Package/luci-app-be7000-nfc/conffiles
/etc/config/be7000_nfc
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
