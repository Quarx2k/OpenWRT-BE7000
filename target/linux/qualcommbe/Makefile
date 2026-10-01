include $(TOPDIR)/rules.mk

ARCH:=aarch64
BOARD:=qualcommbe
BOARDNAME:=Qualcomm Atheros 802.11be WiSoC-s
FEATURES:=squashfs ramdisk fpu nand rtc emmc
KERNELNAME:=Image
CPU_TYPE:=cortex-a53
SUBTARGETS:=ipq95xx

KERNEL_PATCHVER:=6.18

include $(INCLUDE_DIR)/target.mk

ifneq ($(filter y,$(CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_xiaomi_be7000-native-nand) $(CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_xiaomi_be7000-native-mlo-nand)),)
  ifneq ($(filter y,$(CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_xiaomi_be7000-native) $(CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_xiaomi_be7000-native-mlo) $(CONFIG_TARGET_qualcommbe_ipq95xx_DEVICE_xiaomi_be7000-wired)),)
    $(error Build the NAND flavor separately from kexec profiles)
  endif
  LINUX_KCONFIG_LIST += $(PLATFORM_DIR)/config-nand
  define Kernel/Patch
	$(Kernel/Patch/Default)
	$(PATCH) -d $(LINUX_DIR) -p1 -R < $(PATCH_DIR)/9502-be7000-rpm-handoff.patch
  endef
endif

DEFAULT_PACKAGES += \
	kmod-usb3 kmod-usb-dwc3 kmod-usb-dwc3-qcom \
	kmod-leds-gpio kmod-gpio-button-hotplug \
	kmod-qcom-ppe \
	wpad-basic-mbedtls uboot-envtools \
	e2fsprogs kmod-fs-ext4 losetup

$(eval $(call BuildTarget))
