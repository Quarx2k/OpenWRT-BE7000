include $(TOPDIR)/rules.mk

PKG_NAME:=be7000-ath-board
PKG_VERSION:=1.1.38
PKG_RELEASE:=2
PKG_SOURCE:=qcom-wlan-firmware-$(PKG_VERSION).tar.xz
PKG_SOURCE_URL:=file://$(TOPDIR)/dl
PKG_HASH:=skip
PKG_FLAGS:=nonshared

include $(INCLUDE_DIR)/package.mk

RSTRIP:=:
STRIP:=:
CALDATA_SOURCE:=xiaomi-be7000-wlan-caldata.tar.xz

define Download/be7000-ath-caldata
  FILE:=$(CALDATA_SOURCE)
  URL:=file://$(TOPDIR)/dl
  HASH:=skip
  MIRROR:=0
endef

define Package/be7000-ath-board
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Xiaomi BE7000 board data and local calibration for ath11k/ath12k
  DEPENDS:=@TARGET_qualcommbe +ath12k-firmware-qcn9274
endef

define Package/be7000-ath-board/description
  Wrap the BDFs used by Xiaomi firmware 1.1.38 in the native ath board-2
  format. Install calibration from this router's local, unpublished archive.
  This package and images containing it must not be redistributed.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(TAR) -xJf $(DL_DIR)/$(PKG_SOURCE) --strip-components=1 -C $(PKG_BUILD_DIR)
	$(TAR) -xJf $(DL_DIR)/$(CALDATA_SOURCE) -C $(PKG_BUILD_DIR)
endef

define Build/Compile
	stat -c %s $(PKG_BUILD_DIR)/IPQ9574/caldata.bin | grep -qx 131072
	stat -c %s $(PKG_BUILD_DIR)/qcn9224/caldata_3.bin | grep -qx 184320
	bash ./board-2.sh ath11k 'bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=Xiaomi-BE7000' \
		$(PKG_BUILD_DIR)/IPQ9574/bdwlan.bin $(PKG_BUILD_DIR)/IPQ9574/regdb.bin \
		$(PKG_BUILD_DIR)/IPQ9574/board-2.bin
	bash ./board-2.sh ath12k 'bus=pci,qmi-chip-id=0,qmi-board-id=2,variant=Xiaomi-BE7000' \
		$(PKG_BUILD_DIR)/qcn9224/bdwlan.b0002 $(PKG_BUILD_DIR)/qcn9224/regdb.bin \
		$(PKG_BUILD_DIR)/qcn9224/board-2.bin
endef

define Package/be7000-ath-board/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ9574/hw1.0 $(1)/lib/firmware/ath12k/QCN9274/hw2.0
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/IPQ9574/caldata.bin \
		$(1)/lib/firmware/ath11k/IPQ9574/hw1.0/cal-ahb-c000000.wifi.bin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qcn9224/caldata_3.bin \
		$(1)/lib/firmware/ath12k/QCN9274/hw2.0/cal-pci-0002:01:00.0.bin
endef

define Package/be7000-ath-board/install-overlay
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ9574/hw1.0 $(1)/lib/firmware/ath12k/QCN9274/hw2.0
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/IPQ9574/board-2.bin $(1)/lib/firmware/ath11k/IPQ9574/hw1.0/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qcn9224/board-2.bin $(1)/lib/firmware/ath12k/QCN9274/hw2.0/
endef

$(eval $(call Download,be7000-ath-caldata))
$(eval $(call BuildPackage,be7000-ath-board))
