#!/bin/sh

set -eu
umask 077

BUILD_TAG="be7000-kexec-v63-owrt-v12-ram"
SELF_DIR=${0%/*}
[ "$SELF_DIR" = "$0" ] && SELF_DIR=.
BASE_DIR=$(CDPATH= cd "$SELF_DIR" 2>/dev/null && pwd)

KEXEC="$BASE_DIR/kexec"
IMAGE="$BASE_DIR/Image"
ARCH_MODULE="$BASE_DIR/kexec_mod_arm64.ko"
CORE_MODULE="$BASE_DIR/kexec_mod.ko"
# @BE7000_KERNEL_PROFILE@
DTB_TEMPLATE="$BASE_DIR/be7000-spin-table.dtb"
LIVE_DTB="/tmp/be7000-kexec-spin-table.$$.dtb"
MEM_MIN="0x42000000"
EXPECTED_KERNEL_BASE="0x42000000"
EXPECTED_KERNEL_ENTRY="0x42080000"
EXPECTED_IMAGE_BYTES="30822408"
SUCCESS=0
OWN_IMAGE=0
LOADED_ARCH=0
LOADED_CORE=0

die()
{
	echo "ERROR: $*" >&2
	exit 1
}

module_loaded()
{
	grep -q "^$1 " /proc/modules 2>/dev/null
}

cleanup()
{
	rc=$?
	rm -f "$LIVE_DTB"

	if [ "$SUCCESS" -ne 1 ]; then
		if [ "$OWN_IMAGE" -eq 1 ] && [ "$(cat /sys/kernel/kexec_loaded)" = "1" ]; then
			"$KEXEC" -c -u >/dev/null 2>&1 || true
		fi
		if [ "$LOADED_CORE" -eq 1 ]; then
			rmmod kexec_mod >/dev/null 2>&1 || true
		fi
		if [ "$LOADED_ARCH" -eq 1 ]; then
			rmmod kexec_mod_arm64 >/dev/null 2>&1 || true
		fi
	fi

	trap - EXIT HUP INT TERM
	exit "$rc"
}

trap cleanup EXIT HUP INT TERM

[ "${1:-}" = "LOAD-OWRT12-CANDIDATE" ] || {
	echo "This offline candidate loads experimental kernel modules into RAM."
	echo "It is intentionally inert without an explicit authorization token."
	echo "Explicit syntax: $0 LOAD-OWRT12-CANDIDATE"
	exit 2
}

[ "$(id -u)" = "0" ] || die "run as root"
be7000_kernel_profile || die "unsupported Xiaomi kernel"

for required in "$KEXEC" "$IMAGE" "$ARCH_MODULE" "$CORE_MODULE" \
	"$DTB_TEMPLATE" "$BASE_DIR/02-quiesce-stage2.sh" "$BASE_DIR/06-check-layout.sh"; do
	[ -r "$required" ] || die "missing $required"
done

command -v strings >/dev/null 2>&1 || die "strings is required"
for module in "$CORE_MODULE" "$ARCH_MODULE"; do
	supported=$(strings "$module" | sed -n 's/^be7000_source_kernels=//p')
	case ",$supported," in
		*,"$KERNEL_PROFILE",*) ;;
		*) die "This image does not support the router kernel. Use the latest release.";;
	esac
done
[ "$(wc -c < "$IMAGE")" = "$EXPECTED_IMAGE_BYTES" ] ||
	die "Image has an unexpected size"

strings "$CORE_MODULE" |
	grep -q 'Freezing user space before device shutdown' ||
	die "core module is not the quiesce-fixed build"
strings "$CORE_MODULE" |
	grep -q 'rpm-glink handoff ready' ||
	die "core module has no serialized rpm-glink handoff"
strings "$CORE_MODULE" |
	grep -q 'be7000_rpm_glink=serialized-handoff-v1' ||
	die "core module metadata does not identify serialized GLINK handoff v1"
strings "$CORE_MODULE" |
	grep -q 'be7000_device_abi=stock-driver-data-120' ||
	die "core module does not use the verified original struct device ABI"
strings "$CORE_MODULE" |
	grep -q 'be7000_cpu_quiesce=physical-spin-table-v1' ||
	die "core module has no physical spin-table CPU handoff"
if strings "$CORE_MODULE" |
	grep -q 'Gracefully unregistering rpm-glink child'; then
	die "core module still contains the destructive v44 GLINK close path"
fi
strings "$CORE_MODULE" |
	grep -q 'PCI quiesce inspected' ||
	die "core module has no post-shutdown PCI bus-master quiesce"
strings "$ARCH_MODULE" |
	grep -q 'through Xiaomi crash buffers' ||
	die "architecture module has no Xiaomi crash-buffer breadcrumb support"
strings "$ARCH_MODULE" |
	grep -q 'be7000_breadcrumb=4.3' ||
	die "architecture module does not contain breadcrumb format v4.3"
strings "$ARCH_MODULE" |
	grep -q 'be7000_cpu_handoff=physical-spin-table-v1' ||
	die "architecture module has no MMU-off physical CPU pen"
strings "$ARCH_MODULE" |
	grep -q 'secondary spin-table handoff prepared at physical' ||
	die "architecture module has no physical pen preparation code"
strings "$ARCH_MODULE" |
	grep -q 'be7000_spin_table=code-4fb3e000-release-4fb3eff8-entry-427321a4' ||
	die "architecture module has the wrong physical pen layout"
strings "$KEXEC" |
	grep -q -- '--kernel-base=ADDR' ||
	die "kexec binary has no guarded ARM64 forced-base support"
grep -q 'reverse module quiesce pass' "$BASE_DIR/02-quiesce-stage2.sh" ||
	die "stage-2 script has no reverse-order module teardown"
grep -q 'qca_nss_eip|qca_nss_ppe|qca_ssdk' "$BASE_DIR/02-quiesce-stage2.sh" ||
	die "stage-2 script does not protect the non-unloadable EIP/PPE/SSDK chain"
grep -q ' [Tt] freeze_processes$' /proc/kallsyms 2>/dev/null ||
	die "original kernel does not expose freeze_processes through kallsyms"
grep -q ' [Tt] smp_call_function_single$' /proc/kallsyms 2>/dev/null ||
	die "original kernel does not expose smp_call_function_single"
for KSYM in pci_get_device pci_clear_master \
	pci_wait_for_pending_transaction pci_read_config_word; do
	grep -q " [Tt] ${KSYM}$" /proc/kallsyms 2>/dev/null ||
		die "original kernel does not expose $KSYM through kallsyms"
done

CURRENT_CMDLINE=$(cat /proc/cmdline)
case " $CURRENT_CMDLINE " in
	*" boot_source=kexec "*) die "v63 must start from the original bootloader kernel" ;;
	*) ;;
esac

ROOT_MOUNT=$(mount | grep ' on / ' | head -n 1)
[ "$(cat /sys/devices/system/cpu/online)" = "0-3" ] ||
	die "v63 requires all four old-kernel CPUs online"

module_loaded kexec_mod && die "kexec_mod is already loaded; use 03-cancel.sh first"
module_loaded kexec_mod_arm64 && die "kexec_mod_arm64 is already loaded; use 03-cancel.sh first"

if [ -r /sys/kernel/kexec_loaded ] && [ "$(cat /sys/kernel/kexec_loaded)" = "1" ]; then
	die "a kexec image is already loaded; use 03-cancel.sh first"
fi

insmod "$ARCH_MODULE" detect_el2=1 shim_hyp=0 probe_idmap=1
LOADED_ARCH=1
insmod "$CORE_MODULE"
LOADED_CORE=1

# Do not inspect crash or RPM RAM through /dev/mem.  Successful core-module
# initialization already means kexec_breadcrumb_init() completed; format v4.3
# is verified from signed-in-package module metadata above.

[ -c /dev/kexec ] || die "/dev/kexec was not created"
[ -r /sys/kernel/kexec_loaded ] || die "/sys/kernel/kexec_loaded was not created"
[ "$(cat /sys/kernel/kexec_loaded)" = "0" ] || die "unexpected kexec_loaded state"

cp "$DTB_TEMPLATE" "$LIVE_DTB"
[ "$(wc -c < "$LIVE_DTB")" -ge 65536 ] || die "live DTB is unexpectedly small"
[ "$(strings "$LIVE_DTB" | grep -c 'spin-table$')" = "3" ] ||
	die "target DTB does not contain three spin-table CPU methods"

FINAL_CMDLINE="console=ttyMSM0,115200n8 uart_en=1 root=/dev/ram0 rdinit=/init boot_source=kexec kexec_quiesce=1 maxcpus=1 be7000_printk=1 be7000_handoff=1 be7000_source=owrt12"
mkdir -p "$BASE_DIR/logs"
STAMP=$(date '+%Y%m%d-%H%M%S')
LOAD_LOG="$BASE_DIR/logs/load-$STAMP.log"

OWN_IMAGE=1
if {
	echo "time: $(date -Iseconds 2>/dev/null || date)"
	echo "build: $BUILD_TAG"
	echo "kernel: $(uname -a)"
	echo "source_kernel_profile: $KERNEL_PROFILE"
	echo "root: $ROOT_MOUNT"
	echo "cmdline: $FINAL_CMDLINE"
	echo "spin_table_dtb_bytes: $(wc -c < "$LIVE_DTB")"
	echo "image_bytes: $(wc -c < "$IMAGE")"
	echo "core_module_bytes: $(wc -c < "$CORE_MODULE")"
	echo "arch_module_bytes: $(wc -c < "$ARCH_MODULE")"
	echo "placement_min: $MEM_MIN"
	echo
	"$KEXEC" -d -i -c --mem-min="$MEM_MIN" \
		--kernel-base="$EXPECTED_KERNEL_BASE" -l "$IMAGE" \
		--dtb="$LIVE_DTB" --append="$FINAL_CMDLINE"
} >"$LOAD_LOG" 2>&1; then
	:
else
	cat "$LOAD_LOG" >&2
	die "kexec image load failed; details: $LOAD_LOG"
fi

[ "$(cat /sys/kernel/kexec_loaded)" = "1" ] ||
	die "loader returned success, but kexec_loaded is not 1"

grep -q '^image_arm64_load: kernel_segment: 0000000042000000$' "$LOAD_LOG" ||
	die "loader did not choose the required kernel base $EXPECTED_KERNEL_BASE"
grep -q '^segment\[0\]\.mem   = 0x42080000$' "$LOAD_LOG" ||
	die "kernel entry is not at the required address $EXPECTED_KERNEL_ENTRY"
LAYOUT=$(sh "$BASE_DIR/06-check-layout.sh" "$LOAD_LOG") || die "invalid loaded segment layout"
set -- $LAYOUT
EXPECTED_DTB=$1
EXPECTED_PURGATORY=$2

{
	echo "loaded_at=$STAMP"
	echo "build=$BUILD_TAG"
	echo "source_kernel_profile=$KERNEL_PROFILE"
	echo "target=qsdk-initramfs-owrt12"
	echo "purgatory_checks=disabled"
	echo "breadcrumb=0x4fb3f000:v4.3:no-devmem-read"
	echo "crash_transport=xiaomi-rmem-stock-recovery"
	echo "placement_min=$MEM_MIN"
	echo "kernel_base=$EXPECTED_KERNEL_BASE"
	echo "kernel_entry=$EXPECTED_KERNEL_ENTRY"
	echo "dtb=$EXPECTED_DTB"
	echo "purgatory=$EXPECTED_PURGATORY"
	echo "image_probe=owrt12:source-qsdk:printk-ring-rsvd1:serialized-rpm-glink-handoff"
	echo "printk_ring=0x4fa00020:KXLG:v1:text-at-0x4fa00040"
	echo "rpm_glink_handoff=0x4fb3f300:RGLH:v1:pointer-free"
	echo "rpm_glink_fifo_init=saved-idle-cursors:remote-cursor-guard"
	echo "rpm_glink_negotiation=retained-link:no-version-replay"
	echo "rpm_glink_channel=normal-ram-open:saved-lcid-rcid:fresh-kernel-objects"
	echo "old_glink_hooks=version-ack-stock:open-wait-stock:klist-stock:timer-stock"
	echo "uevent_diagnostic=stock-kobject-uevent"
	echo "second_kernel_watchdog=ram-init-manual-ping"
	echo "smp_diagnostic=maxcpus-1:physical-spin-table-handoff"
	echo "cpu_quiesce=final-stage:ipi-cpu-soft-restart:fail-closed"
	echo "cpu_handoff=code-0x4fb3e000:release-0x4fb3eff8:acks-0x4fb3f800"
	echo "target_cpu_method=cpu0-psci:cpu1-3-spin-table"
	echo "physical_layout=stock-fit-0x42080000"
	echo "kexec_tool=forced-arm64-kernel-base"
	echo "rpm_glink_handover=serialized-state:no-release:no-new-rpm-memory-map"
	echo "module_device_abi=stock-driver-104:stock-driver-data-120"
	echo "pci_bus_master_quiesce=post-device-shutdown"
	echo "wlan_quiesce=vendor-wifi-unload-required"
	echo "module_quiesce=reverse-load-order:eip-ppe-ssdk-protected"
	echo "cmdline=$FINAL_CMDLINE"
	echo "image_bytes=$(wc -c < "$IMAGE")"
	echo "core_module_bytes=$(wc -c < "$CORE_MODULE")"
	echo "arch_module_bytes=$(wc -c < "$ARCH_MODULE")"
	echo "load_log=$LOAD_LOG"
} > "$BASE_DIR/loaded-state.txt"

SUCCESS=1
echo "QSDK kernel with embedded OpenWrt 25.12.5 initramfs is loaded into RAM."
echo "Verified placement: kernel=$EXPECTED_KERNEL_ENTRY dtb=$EXPECTED_DTB purgatory=$EXPECTED_PURGATORY"
echo "The physical spin-table handoff with maxcpus=1 is armed; no transition was performed."
echo "Load log: $LOAD_LOG"
echo "To cancel:  $BASE_DIR/03-cancel.sh"
echo "To execute later: $BASE_DIR/02-execute.sh EXECUTE-KEXEC-QUIESCED"
