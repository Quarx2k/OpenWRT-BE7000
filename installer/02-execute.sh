#!/bin/sh

set -eu
umask 077

BUILD_TAG="be7000-kexec-v63-owrt-v12-ram"
SELF_DIR=${0%/*}
[ "$SELF_DIR" = "$0" ] && SELF_DIR=.
BASE_DIR=$(CDPATH= cd "$SELF_DIR" 2>/dev/null && pwd)

TMP_KEXEC="/tmp/be7000-kexec-quiesce.bin"
TMP_STAGE2="/tmp/be7000-kexec-quiesce-stage2.sh"
PID_FILE="/tmp/be7000-kexec-quiesce.pid"
PHASE_FILE="/tmp/be7000-kexec-quiesce.phase"
ARMED=0
OWN_TMP=0

die()
{
	echo "ERROR: $*" >&2
	exit 1
}

cleanup()
{
	rc=$?
	if [ "$ARMED" -ne 1 ] && [ "$OWN_TMP" -eq 1 ]; then
		rm -f "$TMP_KEXEC" "$TMP_STAGE2" "$PID_FILE" "$PHASE_FILE"
	fi
	trap - EXIT HUP INT TERM
	exit "$rc"
}
trap cleanup EXIT HUP INT TERM

[ "${1:-}" = "EXECUTE-KEXEC-QUIESCED" ] || {
	echo "This starts the guarded, still untested kexec transition."
	echo "It stops active services, unmounts USB, freezes remaining userspace,"
	echo "then attempts to start the prepared source QSDK RAM kernel."
	echo "Explicit syntax: $0 EXECUTE-KEXEC-QUIESCED"
	exit 2
}

[ "$(id -u)" = "0" ] || die "run as root"
[ "$(uname -v)" = "#0 SMP PREEMPT Tue Jan 27 03:33:27 2026" ] ||
	die "v63 requires the audited January 2026 original kernel build"
[ -c /dev/kexec ] || die "/dev/kexec is absent"
[ -r /sys/kernel/kexec_loaded ] || die "kexec state is unavailable"
[ "$(cat /sys/kernel/kexec_loaded)" = "1" ] || die "no kernel image is loaded"
grep -q '^kexec_mod_arm64 ' /proc/modules || die "architecture module is not loaded"
grep -q '^kexec_mod ' /proc/modules || die "core module is not loaded"
[ -r "$BASE_DIR/loaded-state.txt" ] || die "load record is absent"
grep -q "^build=$BUILD_TAG$" "$BASE_DIR/loaded-state.txt" || die "wrong module build was loaded"
grep -q '^target=qsdk-initramfs-owrt12$' "$BASE_DIR/loaded-state.txt" ||
	die "loaded target is not the owrt12 RAM system"
grep -q '^purgatory_checks=disabled$' "$BASE_DIR/loaded-state.txt" ||
	die "this diagnostic run requires purgatory integrity checks disabled"
grep -q '^breadcrumb=0x4fb3f000:v4.3:no-devmem-read$' "$BASE_DIR/loaded-state.txt" ||
	die "persistent breadcrumb was not armed by this build"
grep -q '^crash_transport=xiaomi-rmem-stock-recovery$' "$BASE_DIR/loaded-state.txt" ||
	die "persistent crash transport was not armed by this build"
grep -q '^placement_min=0x42000000$' "$BASE_DIR/loaded-state.txt" ||
	die "safe memory placement was not requested"
grep -q '^kernel_base=0x42000000$' "$BASE_DIR/loaded-state.txt" ||
	die "loaded kernel base is not the guarded v5 address"
grep -q '^kernel_entry=0x42080000$' "$BASE_DIR/loaded-state.txt" ||
	die "loaded kernel entry is not the guarded v5 address"
LOAD_LOG=$(sed -n 's/^load_log=//p' "$BASE_DIR/loaded-state.txt")
[ -f "$LOAD_LOG" ] || die "load log is absent"
LAYOUT=$(sh "$BASE_DIR/06-check-layout.sh" "$LOAD_LOG") || die "invalid loaded segment layout"
set -- $LAYOUT
grep -qx "dtb=$1" "$BASE_DIR/loaded-state.txt" || die "DTB record disagrees with load log"
grep -qx "purgatory=$2" "$BASE_DIR/loaded-state.txt" || die "purgatory record disagrees with load log"
grep -qx 'image_bytes=30822408' "$BASE_DIR/loaded-state.txt" || die "wrong Image size record"
RECORDED_CMDLINE=$(sed -n 's/^cmdline=//p' "$BASE_DIR/loaded-state.txt")
for arg in root=/dev/ram0 rdinit=/init be7000_printk=1 be7000_handoff=1 be7000_source=owrt12 maxcpus=1; do
	case " $RECORDED_CMDLINE " in
		*" $arg "*) ;;
		*) die "missing target boot argument: $arg" ;;
	esac
done
grep -q '^image_probe=owrt12:source-qsdk:printk-ring-rsvd1:serialized-rpm-glink-handoff$' "$BASE_DIR/loaded-state.txt" ||
	die "the v52 serialized RPM GLINK handoff Image was not loaded"
grep -q '^printk_ring=0x4fa00020:KXLG:v1:text-at-0x4fa00040$' "$BASE_DIR/loaded-state.txt" ||
	die "the persistent printk-ring layout was not recorded"
grep -q '^rpm_glink_handoff=0x4fb3f300:RGLH:v1:pointer-free$' "$BASE_DIR/loaded-state.txt" ||
	die "the pointer-free RPM GLINK handoff record was not selected"
grep -q '^rpm_glink_fifo_init=saved-idle-cursors:remote-cursor-guard$' "$BASE_DIR/loaded-state.txt" ||
	die "the guarded RPM GLINK FIFO restoration was not selected"
grep -q '^rpm_glink_negotiation=retained-link:no-version-replay$' "$BASE_DIR/loaded-state.txt" ||
	die "the retained-link negotiation policy was not selected"
grep -q '^rpm_glink_channel=normal-ram-open:saved-lcid-rcid:fresh-kernel-objects$' "$BASE_DIR/loaded-state.txt" ||
	die "the fresh-object RPM channel adoption path was not selected"
grep -q '^old_glink_hooks=version-ack-stock:open-wait-stock:klist-stock:timer-stock$' "$BASE_DIR/loaded-state.txt" ||
	die "old experimental GLINK hooks were not recorded as original"
grep -q '^uevent_diagnostic=stock-kobject-uevent$' "$BASE_DIR/loaded-state.txt" ||
	die "the original kobject uevent path was not selected"
grep -q '^second_kernel_watchdog=ram-init-manual-ping$' "$BASE_DIR/loaded-state.txt" ||
	die "the clean-control watchdog policy was not selected"
grep -q '^smp_diagnostic=maxcpus-1:physical-spin-table-handoff$' "$BASE_DIR/loaded-state.txt" ||
	die "loaded state is not the physical spin-table diagnostic"
grep -q '^cpu_quiesce=final-stage:ipi-cpu-soft-restart:fail-closed$' "$BASE_DIR/loaded-state.txt" ||
	die "MMU-off secondary CPU parking was not armed"
grep -q '^cpu_handoff=code-0x4fb3e000:release-0x4fb3eff8:acks-0x4fb3f800$' "$BASE_DIR/loaded-state.txt" ||
	die "physical spin-table layout was not recorded"
grep -q '^target_cpu_method=cpu0-psci:cpu1-3-spin-table$' "$BASE_DIR/loaded-state.txt" ||
	die "target DT CPU methods were not recorded"
grep -q '^physical_layout=stock-fit-0x42080000$' "$BASE_DIR/loaded-state.txt" ||
	die "loaded state is not the original FIT physical-layout diagnostic"
grep -q '^kexec_tool=forced-arm64-kernel-base$' "$BASE_DIR/loaded-state.txt" ||
	die "loaded state was not prepared by the forced-base kexec tool"
grep -q '^rpm_glink_handover=serialized-state:no-release:no-new-rpm-memory-map$' "$BASE_DIR/loaded-state.txt" ||
	die "the serialized rpm-glink handover was not loaded"
grep -q '^module_device_abi=stock-driver-104:stock-driver-data-120$' "$BASE_DIR/loaded-state.txt" ||
	die "the verified original struct device ABI was not loaded"
grep -q '^pci_bus_master_quiesce=post-device-shutdown$' "$BASE_DIR/loaded-state.txt" ||
	die "post-shutdown PCI bus-master quiesce was not loaded"
grep -q '^wlan_quiesce=vendor-wifi-unload-required$' "$BASE_DIR/loaded-state.txt" ||
	die "vendor WLAN/remoteproc quiesce was not armed"
grep -q '^module_quiesce=reverse-load-order:eip-ppe-ssdk-protected$' "$BASE_DIR/loaded-state.txt" ||
	die "reverse-order module teardown was not armed"
# Direct physical-memory reads are intentionally forbidden after the RPM
# message-RAM /dev/mem incident.  01-load-only verified v4.3 through module
# metadata and successful module initialization.
[ -w /proc/sysrq-trigger ] || die "SysRq protection is unavailable"
[ -x /sbin/start-stop-daemon ] || die "start-stop-daemon is unavailable"
[ -x /usr/bin/timeout ] || die "timeout helper is unavailable"
command -v rmmod >/dev/null 2>&1 || die "rmmod is unavailable"
[ -x /sbin/wifi ] || die "vendor /sbin/wifi teardown helper is unavailable"
[ -r /sys/class/remoteproc/remoteproc0/state ] ||
	die "WCSS remoteproc state is unavailable"
[ -r /sys/class/remoteproc/remoteproc1/state ] ||
	die "QCN9224 remoteproc state is unavailable"
[ -x /bin/ubus ] || command -v ubus >/dev/null 2>&1 ||
	die "ubus is unavailable"
[ -x "$BASE_DIR/02-quiesce-stage2.sh" ] || die "stage-2 script is absent"
[ -w /data/usr/log ] || die "/data/usr/log is not writable"
CRASH_UPLOAD=$(uci -q get miwifi.server.LOG 2>/dev/null || true)
[ "$CRASH_UPLOAD" = "127.0.0.1:9" ] ||
	die "crash-log retention stub is not armed (miwifi.server.LOG=${CRASH_UPLOAD:-unset})"
WATCHDOG_STATE=$(ubus call system watchdog '{}' 2>/dev/null || true)
echo "$WATCHDOG_STATE" | grep -q '"status":[[:space:]]*"running"' ||
	die "hardware watchdog is not running; refusing a transition without recovery"
[ "$(cat /sys/devices/system/cpu/online)" = "0-3" ] ||
	die "v63 requires CPUs 0-3 online before arming"

if [ -r "$PID_FILE" ]; then
	OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
	[ -z "$OLD_PID" ] || ! kill -0 "$OLD_PID" 2>/dev/null ||
		die "a transition worker is already running as PID $OLD_PID"
fi

strings "$BASE_DIR/kexec_mod.ko" |
	grep -q 'Freezing user space before device shutdown' ||
	die "package contains an old core module"
strings "$BASE_DIR/kexec_mod.ko" |
	grep -q 'rpm-glink handoff ready' ||
	die "package core module cannot serialize the rpm-glink channel"
strings "$BASE_DIR/kexec_mod.ko" |
	grep -q 'be7000_rpm_glink=serialized-handoff-v1' ||
	die "package core module has the wrong rpm-glink handoff metadata"
strings "$BASE_DIR/kexec_mod.ko" |
	grep -q 'be7000_cpu_quiesce=physical-spin-table-v1' ||
	die "package core module cannot hand secondary CPUs to spin-table"
strings "$BASE_DIR/kexec_mod_arm64.ko" |
	grep -q 'be7000_cpu_handoff=physical-spin-table-v1' ||
	die "package architecture module has no physical CPU pen"
strings "$BASE_DIR/kexec_mod_arm64.ko" |
	grep -q 'be7000_spin_table=code-4fb3e000-release-4fb3eff8-entry-427321a4' ||
	die "package architecture module has the wrong physical pen layout"
if strings "$BASE_DIR/kexec_mod.ko" |
	grep -q 'Gracefully unregistering rpm-glink child'; then
	die "package core module still contains the v44 close path"
fi
strings "$BASE_DIR/kexec_mod.ko" |
	grep -q 'PCI quiesce inspected' ||
	die "package core module cannot clear PCI bus mastering"
grep -q 'reverse module quiesce pass' "$BASE_DIR/02-quiesce-stage2.sh" ||
	die "package stage-2 script has no reverse-order module teardown"
grep -q 'qca_nss_eip|qca_nss_ppe|qca_ssdk' "$BASE_DIR/02-quiesce-stage2.sh" ||
	die "package stage-2 script does not protect EIP/PPE/SSDK"

STAMP=$(date '+%Y%m%d-%H%M%S')
PERSIST_LOG="/data/usr/log/kexec-quiesce-$STAMP.log"
mkdir -p "$BASE_DIR/logs"
ARM_LOG="$BASE_DIR/logs/arm-$STAMP.log"

if [ -s /data/usr/log/panic.tar.gz ]; then
	PANIC_BACKUP="/data/usr/log/panic-before-kexec-$STAMP.tar.gz"
	cp /data/usr/log/panic.tar.gz "$PANIC_BACKUP"
	echo "Previous panic archive preserved as: $PANIC_BACKUP"
fi

cp "$BASE_DIR/kexec" "$TMP_KEXEC"
cp "$BASE_DIR/02-quiesce-stage2.sh" "$TMP_STAGE2"
chmod 0700 "$TMP_KEXEC" "$TMP_STAGE2"
OWN_TMP=1

USB_MOUNT=$(awk -v base="$BASE_DIR/" '
	$2 ~ "^/mnt/usb-" && index(base, $2 "/") == 1 { print $2; exit }
' /proc/mounts)
[ -n "$USB_MOUNT" ] || USB_MOUNT="none"

{
	echo "time: $(date -Iseconds 2>/dev/null || date)"
	echo "build: $BUILD_TAG"
	echo "kernel: $(uname -a)"
	echo "cmdline: $(cat /proc/cmdline)"
	echo "kexec_loaded: $(cat /sys/kernel/kexec_loaded)"
	echo "usb_mount: $USB_MOUNT"
	echo "persistent_log: $PERSIST_LOG"
	echo "action: 10-second cancel window, service/WLAN/remoteproc quiesce, reverse-order module unload with EIP/PPE/SSDK retained, USB detach, sync, read-only remount, device/PCI shutdown, serialize RPM GLINK, park CPU1-3 in the physical spin-table pen, then kexec"
	echo "purgatory_checks: disabled for this diagnostic run"
	echo "watchdog_before: $(echo "$WATCHDOG_STATE" | tr '\n' ' ')"
} > "$ARM_LOG"
cp "$ARM_LOG" "$PERSIST_LOG"
sync

echo "countdown" > "$PHASE_FILE"
/sbin/start-stop-daemon -S -b -m -p "$PID_FILE" -x "$TMP_STAGE2" -- \
	"$TMP_KEXEC" "$PERSIST_LOG" "$USB_MOUNT" "$PHASE_FILE" "$PID_FILE"
ARMED=1

sleep 1
[ -r "$PID_FILE" ] || die "transition worker did not create its PID file"
WORKER_PID=$(cat "$PID_FILE")
kill -0 "$WORKER_PID" 2>/dev/null || die "transition worker exited early"

echo "Quiesced kexec worker armed as PID $WORKER_PID."
echo "There is a 10-second cancellation window before services are stopped."
echo "Cancel during that window with: $BASE_DIR/03-cancel.sh"
echo "After the phase changes to 'quiescing', do not interrupt power manually."
echo "Persistent progress log: $PERSIST_LOG"
