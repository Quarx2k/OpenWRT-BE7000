DTS_DIR := $(DTS_DIR)/qcom

define Device/8devices_kiwi-dvk
	$(call Device/FitImage)
	$(call Device/EmmcImage)
	DEVICE_VENDOR := 8devices
	DEVICE_MODEL := Kiwi-DVK
	DEVICE_DTS_CONFIG := config@8dev-kiwi
	SOC := ipq9570
	DEVICE_PACKAGES := kmod-ath12k ath12k-firmware-qcn9274 \
		ipq-wifi-8devices_kiwi f2fsck mkf2fs kmod-sfp \
		kmod-phy-maxlinear kmod-phy-realtek rtl826x-firmware
	IMAGE/factory.bin := qsdk-ipq-factory-nor
endef
TARGET_DEVICES += 8devices_kiwi-dvk

define Device/askey_sbe1v1k
	$(call Device/FitImage)
	$(call Device/EmmcImage)
	DEVICE_VENDOR := Askey
	DEVICE_MODEL := SBE1V1K
	DEVICE_ALT0_VENDOR := Askey
	DEVICE_ALT0_MODEL := RTQ7300T
	DEVICE_ALT1_VENDOR := Spectrum
	DEVICE_ALT1_MODEL := SBE1V1K
	DEVICE_DTS_CONFIG := config@rtq7300t-rev0
	KERNEL_LOADADDR := 0x42080000
	SOC := ipq9570
	DEVICE_PACKAGES := ath12k-firmware-qcn9274 f2fsck ipq-wifi-askey_sbe1v1k kmod-ath12k \
		kmod-hwmon-pwmfan kmod-phy-realtek mkf2fs rtl826x-firmware
endef
TARGET_DEVICES += askey_sbe1v1k

define Device/qcom_rdp433
	$(call Device/FitImageLzma)
	DEVICE_VENDOR := Qualcomm Technologies, Inc.
	DEVICE_MODEL := RDP433
	DEVICE_VARIANT := AP-AL02-C4
	BOARD_NAME := ap-al02.1-c4
	DEVICE_DTS_CONFIG := config@rdp433
	DEVICE_DTS_DIR := $(DTS_DIR)
	SOC := ipq9574
	KERNEL_INSTALL := 1
	KERNEL_SIZE := 6096k
	IMAGE_SIZE := 25344k
	IMAGE/sysupgrade.bin := append-kernel | pad-to 64k | append-rootfs | pad-rootfs | check-size | append-metadata
endef
TARGET_DEVICES += qcom_rdp433

define Build/be7000-system
	bash $(TOPDIR)/target/linux/qualcommbe/image/be7000-usb-image.sh system \
		$@ $(STAGING_DIR_HOST) $(SOURCE_DATE_EPOCH)
endef

define Build/be7000-userdata
	bash $(TOPDIR)/target/linux/qualcommbe/image/be7000-usb-image.sh userdata \
		$(IMAGE_ROOTFS) $@ $(STAGING_DIR_HOST) $(SOURCE_DATE_EPOCH)
endef

define Build/be7000-usb-bundle
	bash $(TOPDIR)/target/linux/qualcommbe/image/be7000-usb-image.sh bundle $@ \
		$(KDIR)/Image-initramfs $(KDIR)/vmlinux-initramfs.debug \
		$(KDIR)/image-$(DEVICE_DTS).dtb \
		$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-ext4-system.img \
		$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-ext4-userdata.img \
		$(TARGET_CROSS)nm $(SOURCE_DATE_EPOCH) $(DEVICE_NAME)
endef

define Device/xiaomi_be7000-common
	$(call Device/FitImage)
	DEVICE_VENDOR := Xiaomi
	DEVICE_MODEL := BE7000
	SUPPORTED_DEVICES := xiaomi,be7000
	SOC := ipq9574
	KERNEL_LOADADDR := 0x42000000
	IMAGES := system.img userdata.img
	IMAGE/system.img := append-rootfs | be7000-system
	IMAGE/userdata.img := be7000-userdata
	ARTIFACTS := usb.tar.gz
	ARTIFACT/usb.tar.gz := be7000-usb-bundle
endef

define Device/xiaomi_be7000-native
	$(call Device/xiaomi_be7000-common)
	DEVICE_VARIANT := Native Ethernet + Native WLAN
	DEVICE_DTS := ipq9574-be7000-native
	DEVICE_PACKAGES := -uboot-envtools -kmod-qcom-ppe be7000-usb kmod-qcom-ppe-offload \
		kmod-ath11k-ahb ath11k-firmware-ipq9574 kmod-ath12k ath12k-firmware-qcn9274 be7000-ath-board
endef
TARGET_DEVICES += xiaomi_be7000-native

define Device/xiaomi_be7000-wired
	$(call Device/xiaomi_be7000-common)
	DEVICE_VARIANT := Wired / official kernel module profile
	DEVICE_DTS := ipq9574-be7000-wired
	DEVICE_PACKAGES := -uboot-envtools -kmod-qcom-ppe -wpad-basic-mbedtls \
		be7000-usb kmod-qcom-ppe-offload
endef
TARGET_DEVICES += xiaomi_be7000-wired
