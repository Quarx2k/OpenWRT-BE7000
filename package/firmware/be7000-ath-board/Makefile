include $(TOPDIR)/rules.mk

PKG_NAME:=be7000-ath-board
PKG_VERSION:=1.1.38
PKG_RELEASE:=3
PKG_SOURCE:=qcom-wlan-firmware-$(PKG_VERSION).tar.xz
PKG_SOURCE_URL:=file://$(TOPDIR)/dl
PKG_HASH:=skip
PKG_FLAGS:=nonshared

include $(INCLUDE_DIR)/package.mk

RSTRIP:=:
STRIP:=:
define Package/be7000-ath-board
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=Xiaomi BE7000 board data for ath11k/ath12k
  DEPENDS:=@TARGET_qualcommbe +ath12k-firmware-qcn9274
endef

define Package/be7000-ath-board/description
  Wrap the BDFs used by Xiaomi firmware 1.1.38 in the native ath board-2
  format. Per-device calibration is copied from the installing router by
  the USB installer, never embedded in the build.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(TAR) -xJf $(DL_DIR)/$(PKG_SOURCE) --strip-components=1 -C $(PKG_BUILD_DIR)
endef

define Build/Compile
	bash ./board-2.sh ath11k 'bus=ahb,qmi-chip-id=0,qmi-board-id=255,variant=Xiaomi-BE7000' \
		$(PKG_BUILD_DIR)/IPQ9574/bdwlan.bin $(PKG_BUILD_DIR)/IPQ9574/regdb.bin \
		$(PKG_BUILD_DIR)/IPQ9574/board-2.bin
	bash ./board-2.sh ath12k 'bus=pci,qmi-chip-id=0,qmi-board-id=2,variant=Xiaomi-BE7000' \
		$(PKG_BUILD_DIR)/qcn9224/bdwlan.b0002 $(PKG_BUILD_DIR)/qcn9224/regdb.bin \
		$(PKG_BUILD_DIR)/qcn9224/board-2.bin
endef

define Package/be7000-ath-board/install
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ9574/hw1.0 $(1)/lib/firmware/ath12k/QCN9274/hw2.0
endef

define Package/be7000-ath-board/install-overlay
	$(INSTALL_DIR) $(1)/lib/firmware/ath11k/IPQ9574/hw1.0 $(1)/lib/firmware/ath12k/QCN9274/hw2.0
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/IPQ9574/board-2.bin $(1)/lib/firmware/ath11k/IPQ9574/hw1.0/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/qcn9224/board-2.bin $(1)/lib/firmware/ath12k/QCN9274/hw2.0/
endef

$(eval $(call BuildPackage,be7000-ath-board))
