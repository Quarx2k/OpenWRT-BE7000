include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=qrtr-smd-compat
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define KernelPackage/qrtr-smd-compat
  SUBMENU:=Network Support
  TITLE:=QRTR SMD transport for the official qualcommbe kernel profile
  DEPENDS:=@TARGET_qualcommbe +kmod-qrtr
  PROVIDES:=kmod-qrtr-smd
  FILES:=$(PKG_BUILD_DIR)/qrtr-smd.ko
  AUTOLOAD:=$(call AutoProbe,qrtr-smd)
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) $(LINUX_DIR)/net/qrtr/smd.c $(PKG_BUILD_DIR)/qrtr-smd.c
	$(CP) $(LINUX_DIR)/net/qrtr/qrtr.h $(PKG_BUILD_DIR)/
	printf '%s\n' 'obj-m := qrtr-smd.o' > $(PKG_BUILD_DIR)/Makefile
endef

define Build/Compile
	$(KERNEL_MAKE) M=$(PKG_BUILD_DIR) modules
endef

$(eval $(call KernelPackage,qrtr-smd-compat))
