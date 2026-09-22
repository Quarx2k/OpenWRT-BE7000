# IPQ9574 secure WCSS loader

Derived from the public OpenWrt qualcommax patch
`target/linux/qualcommax/patches-6.18/0188-remoteproc-qcom-add-hexagon-based-wcss-secure-pil-driver.patch`
at OpenWrt revision `3a117c0c53e31756f09067eec46b71e142b7c086`.
The original Qualcomm/Linaro/Sony copyright notices are retained.
The BE7000 compatibility packaging, M3 loading and coredump adaptations
are by Nickolai Semendiaev <agent00791@gmail.com>.

This package builds the PAS6/IPQ9574 path against the configured kernel's
remoteproc headers and exports, without changing its Kconfig or public structures.
The unused IPQ5424 TME mailbox path and other SoC matches are omitted. Coredump
mapping uses the existing callback-private pointer instead of adding `io_ptr`
to `struct rproc_dump_segment`; the final dump chunk is copied before unmapping.

The second `firmware-name` entry loads Xiaomi's M3 image into the same reserved
memory using `qcom_mdt_load_no_init()`. Its relocation does not overwrite Q6's.
Both firmware files are required. The startup remains controlled by ath11k
(`auto_boot = false`), while TrustZone owns the Q6 clock/reset sequence.
This is a remoteproc loader, with no QSDK WLAN host driver dependency.
