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
	$(if $(IB),,$(call Device/xiaomi_be7000-nand-source))
endef
TARGET_DEVICES += xiaomi_be7000-nand

define Build/be7000-nand-prepare
	bash $(TOPDIR)/package/boot/be7000-nand/image-prepare.sh $(TOPDIR) $(KDIR) $@ "$$(nproc)" $(TARGET_DIR)
endef

define Build/be7000-nand-copy
	cp $(KDIR)/be7000-nand-artifacts/$(1) $@
endef

define Device/xiaomi_be7000-nand-source
	KERNEL_NAME := Image
	KERNEL := be7000-nand-prepare
	KERNEL_DEPENDS := $(TOPDIR)/.config $(shell find $(TOPDIR)/package/boot/be7000-nand -type f)
	IMAGES := sysupgrade.bin factory.ubi
	IMAGE/sysupgrade.bin := be7000-nand-copy root.squashfs | be7000-nand-sysupgrade | append-metadata
	IMAGE/factory.ubi := be7000-nand-copy factory.ubi
	ARTIFACTS := installer.tar.gz
	ARTIFACT/installer.tar.gz := be7000-nand-copy be7000-nand-install.tar.gz
endef
