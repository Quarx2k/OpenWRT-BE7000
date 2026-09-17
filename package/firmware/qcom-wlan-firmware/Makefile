include $(TOPDIR)/rules.mk

PKG_NAME:=qcom-wlan-firmware
PKG_VERSION:=1.1.38
PKG_RELEASE:=4
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.xz
PKG_SOURCE_URL:=file://$(TOPDIR)/dl
PKG_HASH:=skip

include $(INCLUDE_DIR)/package.mk

RSTRIP:=:
STRIP:=:

CALDATA_SOURCE:=xiaomi-be7000-wlan-caldata.tar.xz

define Download/be7000-caldata
  FILE:=$(CALDATA_SOURCE)
  URL:=file://$(TOPDIR)/dl
  HASH:=skip
  MIRROR:=0
endef

define Package/qcom-wlan-firmware-xiaomi-be7000
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Qualcomm AP WLAN firmware and configuration for Xiaomi BE7000
  PKGARCH:=all
endef

define Package/qcom-wlan-firmware-xiaomi-be7000/description
  IPQ9574 and QCN9224 firmware, INI files and device calibration for the
  Qualcomm AP WLAN driver. Local xiaomi-be7000-wlan-caldata.tar.xz supplies
  IPQ9574/caldata.bin and qcn9224/caldata_3.bin from this individual router.
endef

define Package/qcom-wlan-firmware-xiaomi-be7000/conffiles
/lib/firmware/global.ini
/lib/firmware/QCA9574.ini
/lib/firmware/QCN9224.ini
/lib/firmware/internal/global_i.ini
/lib/firmware/internal/QCA9574_i.ini
/lib/firmware/internal/QCN9224_i.ini
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(TAR) -xJf $(DL_DIR)/$(CALDATA_SOURCE) -C $(PKG_BUILD_DIR)
endef

define Build/Compile
	test -s $(PKG_BUILD_DIR)/IPQ9574/caldata.bin
	test -s $(PKG_BUILD_DIR)/qcn9224/caldata_3.bin
endef

define Package/qcom-wlan-firmware-xiaomi-be7000/install
	$(INSTALL_DIR) $(1)/lib/firmware/IPQ9574 $(1)/lib/firmware/qcn9224 $(1)/lib/firmware/internal
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/IPQ9574/* $(1)/lib/firmware/IPQ9574/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qcn9224/* $(1)/lib/firmware/qcn9224/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/*.ini $(1)/lib/firmware/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/internal/*.ini $(1)/lib/firmware/internal/
	$(LN) /lib/firmware $(1)/ini
endef

$(eval $(call Download,be7000-caldata))
$(eval $(call BuildPackage,qcom-wlan-firmware-xiaomi-be7000))
