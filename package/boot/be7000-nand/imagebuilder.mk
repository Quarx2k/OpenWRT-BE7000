define Build/be7000-nand-sysupgrade
	bash $(TOPDIR)/package/boot/be7000-nand/imagebuilder-image.sh \
		$@ $(KDIR)/xiaomi_be7000-nand-kernel.bin $(SOURCE_DATE_EPOCH)
endef

define Device/xiaomi_be7000-nand
	DEVICE_VENDOR := Xiaomi
	DEVICE_MODEL := BE7000
	DEVICE_VARIANT := NAND
	SUPPORTED_DEVICES := xiaomi,be7000-nand
	DEVICE_DTS := ipq9574-be7000-native-nand
	SOC := ipq9574
	FILESYSTEMS := squashfs
	IMAGES := sysupgrade.bin
	IMAGE/sysupgrade.bin := append-rootfs | be7000-nand-sysupgrade | append-metadata
	DEVICE_PACKAGES := -kmod-qcom-ppe -kmod-leds-gpio -e2fsprogs -losetup \
		$(shell cat $(TOPDIR)/package/boot/be7000-nand/packages.list)
endef
TARGET_DEVICES += xiaomi_be7000-nand
