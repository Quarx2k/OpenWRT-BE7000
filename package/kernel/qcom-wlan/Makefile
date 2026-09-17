include $(TOPDIR)/rules.mk

PKG_NAME:=qcom-wlan
PKG_RELEASE:=11
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=ssh://git@github.com/Quarx2k/QCOM-WLAN.git
PKG_SOURCE_DATE:=2026-09-17
PKG_SOURCE_VERSION:=4c4aff4b193ac3a0b59a8caeaba791baac366cba
PKG_MIRROR_HASH:=skip
PKG_LICENSE:=GPL-2.0-only ISC BSD-3-Clause
PKG_BUILD_PARALLEL:=1
PKG_FLAGS:=nonshared
PKG_BUILD_FLAGS:=no-lto
PKG_EXTMOD_SUBDIRS:=build/qca-wifi

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

WLAN_BUILD_DIR=$(PKG_BUILD_DIR)/build

define KernelPackage/cfg80211-native
  SUBMENU:=Wireless Drivers
  TITLE:=Native kernel cfg80211 for Qualcomm source WLAN
  DEPENDS:=@TARGET_qualcommbe_ipq95xx +iw +!WIFI_SCRIPTS_UCODE:iwinfo +wifi-scripts +wireless-regdb
  CONFLICTS:=kmod-cfg80211 kmod-mac80211
  KCONFIG:=CONFIG_CFG80211=m CONFIG_CFG80211_WEXT=y CONFIG_CFG80211_DEBUGFS=y \
	CONFIG_CFG80211_CRDA_SUPPORT=y CONFIG_CFG80211_DEFAULT_PS=y \
	CONFIG_CFG80211_CERTIFICATION_ONUS=y CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=n \
	CONFIG_CFG80211_REG_CELLULAR_HINTS=n CONFIG_CFG80211_REG_RELAX_NO_IR=n \
	CONFIG_CFG80211_DEVELOPER_WARNINGS=n CONFIG_NL80211_TESTMODE=n \
	CONFIG_FIPS_SIGNATURE_SELFTEST=n CONFIG_PKCS7_TEST_KEY=n \
	CONFIG_PKCS8_PRIVATE_KEY_PARSER=n CONFIG_SECONDARY_TRUSTED_KEYRING=n \
	CONFIG_SYSTEM_EXTRA_CERTIFICATE=n CONFIG_VIRT_WIFI=n CONFIG_RTL8723BS=n
  FILES:=$(LINUX_DIR)/net/wireless/cfg80211.ko
  AUTOLOAD:=$(call AutoLoad,20,cfg80211)
endef

define KernelPackage/qcom-wlan
  SUBMENU:=Wireless Drivers
  TITLE:=Qualcomm IPQ9574 and QCN9224 source WLAN
  DEPENDS:=@TARGET_qualcommbe_ipq95xx +kmod-cfg80211-native \
	+@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT +@DRIVER_11BE_SUPPORT
  KCONFIG:=CONFIG_QCOM_BE7000_WLAN=y CONFIG_QCOM_QMI_HELPERS=m CONFIG_QRTR=y CONFIG_QRTR_SMD=y \
	CONFIG_QRTR_MHI=y CONFIG_MHI_BUS=y
  FILES:= \
	$(LINUX_DIR)/drivers/soc/qcom/qmi_helpers.ko \
	$(WLAN_BUILD_DIR)/wcss/qcom_q6v5_wcss_sec.ko \
	$(WLAN_BUILD_DIR)/qca-wifi/mem_manager.ko \
	$(WLAN_BUILD_DIR)/qca-wifi/platform/cnss/ipq_cnss2.ko \
	$(WLAN_BUILD_DIR)/qca-wifi/qdf.ko \
	$(WLAN_BUILD_DIR)/qca-wifi/wifi_3_0.ko \
	$(WLAN_BUILD_DIR)/qca-wifi/umac.ko \
	$(WLAN_BUILD_DIR)/qca-wifi/qca_ol.ko
  AUTOLOAD:=$(call AutoLoad,19,qcom_q6v5_wcss_sec)
endef

define KernelPackage/qcom-wlan/description
  Source-built P74 WLAN, including QDF and CNSS, for Xiaomi BE7000.
  Uses the native kernel cfg80211 ABI. Firmware and INI are supplied by
  qcom-wlan-firmware-xiaomi-be7000, with device calibration on USB.
  WLAN direct switching is disabled.
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	bash $(PKG_BUILD_DIR)/tools/prepare-linux-6.12.sh $(WLAN_BUILD_DIR)
endef

define Build/Compile
	+$(KERNEL_MAKE) $(PKG_JOBS) M="$(WLAN_BUILD_DIR)/wcss" modules
	+$(KERNEL_MAKE) $(PKG_JOBS) \
		M="$(WLAN_BUILD_DIR)/qca-wifi" \
		KCFLAGS="-include $(WLAN_BUILD_DIR)/compat/linux-6.12.h -Wno-error=missing-prototypes -Wno-error=unused-function -Wno-error=unused-but-set-parameter -Wno-error=enum-conversion -Wno-error=address -Wno-error=implicit-fallthrough -Wno-error=old-style-declaration -Wno-error=empty-body" \
		modules
endef

$(eval $(call KernelPackage,cfg80211-native))
$(eval $(call KernelPackage,qcom-wlan))
