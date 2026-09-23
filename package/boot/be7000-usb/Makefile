include $(TOPDIR)/rules.mk

PKG_NAME:=be7000-usb
PKG_RELEASE:=15
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/be7000-usb
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Xiaomi BE7000 USB root and kexec handoff support
  DEPENDS:=@TARGET_qualcommbe_ipq95xx +bash +e2fsprogs +blkid +losetup +kmod-usb-storage +kmod-fs-ext4 +kmod-fs-vfat +kmod-usb3 +kmod-usb-dwc3 +kmod-usb-dwc3-qcom
endef

define Build/Compile
endef

define Package/be7000-usb/install
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/etc $(1)/mnt/usb $(1)/rom $(1)/overlay
	$(INSTALL_BIN) ./files/be7000-usb-init $(1)/usr/libexec/
	$(INSTALL_BIN) ./files/be7000-usb-log $(1)/usr/libexec/
	$(INSTALL_BIN) ./files/be7000-usb-upgrade $(1)/usr/libexec/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/be7000-boot-confirm $(1)/etc/init.d/be7000-boot-confirm
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/be7000-flow-offload $(1)/etc/uci-defaults/90-be7000-flow-offload
	$(INSTALL_BIN) ./files/be7000-attendedsysupgrade $(1)/etc/uci-defaults/91-be7000-attendedsysupgrade
	printf 'be7000-openwrt-snapshot-linux-6.18-r2\n' > $(1)/etc/be7000-system-id
endef

$(eval $(call BuildPackage,be7000-usb))
