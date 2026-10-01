include $(TOPDIR)/rules.mk

PKG_NAME:=be7000-package-feed
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/be7000-package-feed
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=BE7000 signed package repository
  DEPENDS:=@TARGET_qualcommbe_ipq95xx
endef

define Build/Compile
endef

define Package/be7000-package-feed/install
	$(INSTALL_DIR) $(1)/etc/apk/keys $(1)/etc/uci-defaults
	$(INSTALL_DATA) ./files/be7000-packages.pem $(1)/etc/apk/keys/
	$(INSTALL_BIN) ./files/92-be7000-packages $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,be7000-package-feed))
