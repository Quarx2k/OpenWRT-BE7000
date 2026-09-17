include $(TOPDIR)/rules.mk

PKG_NAME:=be7000-usb
PKG_RELEASE:=7
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/be7000-usb
  SUBMENU:=Other modules
  TITLE:=Xiaomi BE7000 USB boot kernel support
  DEPENDS:=@TARGET_qualcommbe_ipq95xx
  KCONFIG:= \
	CONFIG_ARM64_SPIN_TABLE=y \
	CONFIG_ARM_SMCCC_SOC_ID=y \
	CONFIG_BE7000_KEXEC_HANDOFF=y \
	CONFIG_BE7000_PRINTK_PERSIST=y \
	CONFIG_BLK_DEV_LOOP=y \
	CONFIG_BLK_DEV_SD=y \
	CONFIG_DEVTMPFS=y \
	CONFIG_EXT4_FS=y \
	CONFIG_HOTPLUG_CPU=y \
	CONFIG_OVERLAY_FS=y \
	CONFIG_QCOM_CLK_APCS_MSM8916=y \
	CONFIG_SCSI=y \
	CONFIG_USB_DWC3=y \
	CONFIG_USB_DWC3_HOST=y \
	CONFIG_USB_DWC3_QCOM=y \
	CONFIG_USB_STORAGE=y \
	CONFIG_USB_XHCI_HCD=y \
	CONFIG_USB_XHCI_PLATFORM=y
endef

define Package/be7000-usb
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Xiaomi BE7000 USB root and kexec handoff support
  DEPENDS:=@TARGET_qualcommbe_ipq95xx +kmod-be7000-usb +bash +e2fsprogs +blkid +losetup +kmod-usb-storage +kmod-fs-ext4 +kmod-fs-vfat +kmod-usb3
endef

define Build/Compile
endef

define Package/be7000-usb/install
	$(INSTALL_DIR) $(1)/usr/libexec $(1)/etc $(1)/mnt/usb $(1)/rom $(1)/overlay
	$(INSTALL_BIN) ./files/be7000-usb-init $(1)/usr/libexec/
	$(INSTALL_BIN) ./files/be7000-usb-log $(1)/usr/libexec/
	$(INSTALL_DIR) $(1)/usr/libexec/platform
	$(INSTALL_BIN) ./files/be7000-packet-steering $(1)/usr/libexec/platform/packet-steering.sh
	printf 'be7000-openwrt-25.12-linux-6.12-r1\n' > $(1)/etc/be7000-system-id
endef

$(eval $(call BuildPackage,be7000-usb))
$(eval $(call KernelPackage,be7000-usb))
