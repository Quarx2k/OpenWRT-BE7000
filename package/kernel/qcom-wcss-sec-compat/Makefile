include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=qcom-wcss-sec-compat
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/qcom-wcss-sec-compat
  SUBMENU:=Other modules
  TITLE:=IPQ9574 secure WCSS loader for the official kernel profile
  DEPENDS:=@TARGET_qualcommbe
  FILES:=$(PKG_BUILD_DIR)/qcom_q6v5_wcss_sec.ko
  AUTOLOAD:=$(call AutoLoad,19,qcom_q6v5_wcss_sec)
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) $(LINUX_DIR)/drivers/remoteproc/qcom_common.h $(PKG_BUILD_DIR)/
	$(CP) $(LINUX_DIR)/drivers/remoteproc/qcom_q6v5.h $(PKG_BUILD_DIR)/
	$(CP) $(LINUX_DIR)/drivers/remoteproc/qcom_pil_info.h $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(KERNEL_MAKE) M=$(PKG_BUILD_DIR) modules
endef

$(eval $(call KernelPackage,qcom-wcss-sec-compat))
