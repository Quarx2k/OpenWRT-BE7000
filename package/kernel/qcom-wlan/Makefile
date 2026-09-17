include $(TOPDIR)/rules.mk

PKG_NAME:=qcom-wlan
PKG_RELEASE:=16
PKG_SOURCE_DATE:=2026-09-18
PKG_SOURCE_VERSION:=c1fbf574afba3fbd00c2a7af5e5c9bf445f06619
PKG_VERSION:=$(subst -,.,$(PKG_SOURCE_DATE))~$(call version_abbrev,$(PKG_SOURCE_VERSION))
PKG_SOURCE_URL:=file://$(TOPDIR)/dl
PKG_HASH:=skip
PKG_SOURCE_MIRROR:=0
PKG_LICENSE:=GPL-2.0-only ISC BSD-3-Clause
PKG_BUILD_PARALLEL:=1
PKG_FLAGS:=nonshared
PKG_BUILD_FLAGS:=no-lto
PKG_EXTMOD_SUBDIRS:=build/qca-wifi

include $(INCLUDE_DIR)/kernel.mk

WLAN_SOURCE_ARCHIVE:=$(PKG_NAME)-$(PKG_VERSION).tar.zst
# A local source archive or an OpenWrt source-tree override takes precedence.
WLAN_FROM_SOURCE:=$(if $(strip $(wildcard $(DL_DIR)/$(WLAN_SOURCE_ARCHIVE)) $(USE_SOURCE_DIR) $(wildcard $(TOPDIR)/git-src/$(PKG_NAME)/.git) $(if $(CONFIG_SRC_TREE_OVERRIDE),$(wildcard ./git-src))),1,0)
PKG_PREPARED_DEPENDS+=WLAN_FROM_SOURCE

ifeq ($(WLAN_FROM_SOURCE),1)
  PKG_SOURCE:=$(WLAN_SOURCE_ARCHIVE)
else
  PKG_SOURCE:=$(PKG_NAME)-prebuilt-$(PKG_VERSION)-linux-$(LINUX_VERSION).tar.xz
  STAMP_BUILT_DEPENDS+=$(LINUX_DIR)/.vermagic $(LINUX_DIR)/include/config/kernel.release

  # Binary modules do not provide a Kbuild Module.symvers file.
  define collect_module_symvers
	$(INSTALL_DIR) $(PKG_SYMVERS_DIR)
	: > $(PKG_SYMVERS_DIR)/$(PKG_NAME).symvers
  endef
endif

include $(INCLUDE_DIR)/package.mk

WLAN_BUILD_DIR=$(PKG_BUILD_DIR)/build

define KernelPackage/cfg80211-native
  SUBMENU:=Wireless Drivers
  TITLE:=Native kernel cfg80211 for Qualcomm WLAN
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
  TITLE:=Qualcomm IPQ9574 and QCN9224 WLAN
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
  AUTOLOAD:=$(call AutoLoad,30,qmi_helpers mem_manager qdf umac ipq_cnss2 qca_ol wifi_3_0)
  MODPARAMS.qcom_q6v5_wcss_sec:=bringup_debug=1
  MODPARAMS.ipq_cnss2:=bdf_pci2=0x02 enable_mlo_support=0 bringup_debug=1
endef

define KernelPackage/qcom-wlan/install
	# CNSS obtains WCSS through remoteproc, without an ELF module dependency.
	$(call ModuleAutoLoad,qcom-wlan,$(1),19-,,qcom_q6v5_wcss_sec)
endef

define KernelPackage/qcom-wlan/description
  P74 WLAN, including QDF and CNSS, for Xiaomi BE7000. Builds from a local
  source archive in dl when available; otherwise uses prebuilt modules
  matching the kernel release and OpenWrt kernel ABI. Firmware, INI and
  device calibration are supplied by qcom-wlan-firmware-xiaomi-be7000.
  WLAN direct switching is disabled.
endef

ifeq ($(WLAN_FROM_SOURCE),1)
define Build/Prepare
	$(call Build/Prepare/Default)
	bash $(PKG_BUILD_DIR)/tools/prepare-linux-6.18.sh $(WLAN_BUILD_DIR)
endef

define Build/Compile
	+$(KERNEL_MAKE) $(PKG_JOBS) M="$(WLAN_BUILD_DIR)/wcss" modules
	+$(KERNEL_MAKE) $(PKG_JOBS) \
		M="$(WLAN_BUILD_DIR)/qca-wifi" \
		KCFLAGS="-include $(WLAN_BUILD_DIR)/compat/linux-6.12.h -Wno-error=missing-prototypes -Wno-error=unused-function -Wno-error=unused-but-set-parameter -Wno-error=enum-conversion -Wno-error=address -Wno-error=implicit-fallthrough -Wno-error=old-style-declaration -Wno-error=empty-body" \
		modules
endef
else
define Build/Compile
	bash ./prebuilt.sh check "$(PKG_BUILD_DIR)" "$(LINUX_DIR)" "$(TARGET_CROSS)"
endef
endif

$(eval $(call KernelPackage,cfg80211-native))
$(eval $(call KernelPackage,qcom-wlan))
