include $(TOPDIR)/rules.mk

PKG_NAME:=be7000-wifi
PKG_RELEASE:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/be7000-wifi
  SECTION:=net
  CATEGORY:=Network
  TITLE:=BE7000 external WLAN capabilities
  DEPENDS:=+wpad-mbedtls +@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT +@DRIVER_11BE_SUPPORT
endef

define Build/Compile
endef

define Package/be7000-wifi/install
endef

$(eval $(call BuildPackage,be7000-wifi))
