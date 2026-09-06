# Evaluate OpenWrt's package definitions with GNU make, including helper macros.
INCLUDE_DIR := $(OPENWRT)/include
SCRIPT_DIR := $(OPENWRT)/scripts
LINUX_DIR := $(KERNEL_BUILD)
KERNEL_PATCHVER := 5.4
BOARD := qualcommax
SUBTARGET := ipq95xx
CONFIG_IPV6 := y
CONFIG_ARM64 := y
CONFIG_aarch64 := y
CONFIG_64BIT := y
empty :=
space := $(empty) $(empty)
-include $(KERNEL_BUILD)/.config

split_version = $(subst ., ,$(1))
version_field = $(if $(word $(1),$(2)),$(word $(1),$(2)),0)
kernel_version_merge = $$(( ($(call version_field,1,$(1)) << 24) + ($(call version_field,2,$(1)) << 16) + ($(call version_field,3,$(1)) << 8) ))
kernel_version_cmp = $(shell [ $(call kernel_version_merge,$(call split_version,$(2))) $(1) $(call kernel_version_merge,$(call split_version,$(3))) ] && echo 1)
CompareKernelPatchVer = $(if $(call kernel_version_cmp,-$(2),$(1),$(3)),1,0)
kernel_patchver_ge = $(call kernel_version_cmp,-ge,$(KERNEL_PATCHVER),$(1))
kernel_patchver_lt = $(call kernel_version_cmp,-lt,$(KERNEL_PATCHVER),$(1))
version_filter = $(if $(findstring @,$(1)),$(shell $(SCRIPT_DIR)/package-metadata.pl version_filter $(KERNEL_PATCHVER) $(1)),$(1))
AutoLoad = $(if $(1),$(1),0) $(if $(3),1,0) $(call version_filter,$(2))
AutoProbe = $(call AutoLoad,,$(1),$(2))

define KernelPackage
$(eval TITLE :=)
$(eval DEPENDS :=)
$(eval KCONFIG :=)
$(eval FILES :=)
$(eval AUTOLOAD :=)
$(eval MODPARAMS :=)
$(eval $(call KernelPackage/$(1)))
$(eval $(call KernelPackage/$(1)/$(BOARD)))
$(eval $(call KernelPackage/$(1)/$(BOARD)/$(SUBTARGET)))
$(file >>$(OUTPUT),Name: kmod-$(1))
$(file >>$(OUTPUT),Title: $(strip $(TITLE)))
$(file >>$(OUTPUT),Depends: $(strip $(DEPENDS)))
$(file >>$(OUTPUT),Kconfig: $(strip $(call version_filter,$(KCONFIG))))
$(file >>$(OUTPUT),Files: $(strip $(call version_filter,$(FILES))))
$(file >>$(OUTPUT),Autoload: $(strip $(AUTOLOAD)))
$(file >>$(OUTPUT),Params: $(strip $(MODPARAMS)))
$(file >>$(OUTPUT),End:)
endef

$(file >$(OUTPUT),)
include $(sort $(wildcard $(OPENWRT)/package/kernel/linux/modules/*.mk))
.PHONY: all
all:
	@:
