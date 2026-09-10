#!/bin/sh

set -u
umask 077
trap '' HUP

KEXEC_BIN=${1:?missing temporary kexec binary}
PERSIST_LOG=${2:?missing persistent log path}
USB_MOUNT=${3:-none}
PHASE_FILE=${4:-/tmp/be7000-kexec-quiesce.phase}
PID_FILE=${5:-/tmp/be7000-kexec-quiesce.pid}
TMP_LOG="/tmp/be7000-kexec-quiesce-stage2.log"

if [ -r "$PERSIST_LOG" ]; then
	cp "$PERSIST_LOG" "$TMP_LOG" 2>/dev/null || : > "$TMP_LOG"
else
	: > "$TMP_LOG"
fi
cd /tmp || exit 1

log()
{
	LINE="$(date -Iseconds 2>/dev/null || date) $*"
	echo "$LINE" >> "$TMP_LOG"
	echo "$LINE" > /dev/console 2>/dev/null || true
}

persist_log()
{
	cp "$TMP_LOG" "$PERSIST_LOG" 2>/dev/null || true
	sync
}

stop_service()
{
	SERVICE=$1
	[ -x "/etc/init.d/$SERVICE" ] || return 0
	log "stopping service: $SERVICE"
	/usr/bin/timeout -t 20 "/etc/init.d/$SERVICE" stop >> "$TMP_LOG" 2>&1 ||
		log "service stop returned nonzero or timed out: $SERVICE"
}

module_is_protected()
{
	case "$1" in
		kexec_mod|kexec_mod_arm64|dm_crypt|dm_req_crypt|dm_mirror|dm_region_hash|dm_log|qca_nss_eip|qca_nss_ppe|qca_ssdk)
			return 0
			;;
	esac
	return 1
}

module_holders()
{
	HOLDER_MODULE=$1
	for HOLDER_PATH in "/sys/module/$HOLDER_MODULE/holders"/*; do
		[ -e "$HOLDER_PATH" ] || continue
		echo "${HOLDER_PATH##*/}"
	done | sort | tr '\n' ','
}

module_refcnt()
{
	cat "/sys/module/$1/refcnt" 2>/dev/null || echo unknown
}

eip_irq_total()
{
	awk '
	/eip_irq_ring_/ {
		for (field = 2; field <= NF; field++) {
			if ($field !~ /^[0-9]+$/)
				break
			total += $field
		}
	}
	END { print total + 0 }
	' /proc/interrupts 2>/dev/null
}

unload_one_module()
{
	UNLOAD_MODULE=$1
	[ -d "/sys/module/$UNLOAD_MODULE" ] || return 1
	module_is_protected "$UNLOAD_MODULE" && return 1

	UNLOAD_LOG="/tmp/be7000-rmmod-$UNLOAD_MODULE.log"
	if /usr/bin/timeout -t 12 rmmod "$UNLOAD_MODULE" > "$UNLOAD_LOG" 2>&1; then
		log "module unloaded: $UNLOAD_MODULE"
		rm -f "$UNLOAD_LOG"
		return 0
	else
		UNLOAD_RC=$?
	fi
	if [ "$UNLOAD_RC" -eq 124 ] || [ "$UNLOAD_RC" -eq 137 ]; then
		log "module unload timed out: $UNLOAD_MODULE rc=$UNLOAD_RC"
	fi
	rm -f "$UNLOAD_LOG"
	return 1
}

flush_runtime_network_state()
{
	log "flushing runtime packet-filter and qdisc state before module teardown"
	for TOOL in iptables ip6tables; do
		command -v "$TOOL" >/dev/null 2>&1 || continue
		for TABLE in raw mangle nat filter; do
			"$TOOL" -t "$TABLE" -F >/dev/null 2>&1 || true
			"$TOOL" -t "$TABLE" -X >/dev/null 2>&1 || true
		done
	done
	if command -v ebtables >/dev/null 2>&1; then
		for TABLE in broute nat filter; do
			ebtables -t "$TABLE" -F >/dev/null 2>&1 || true
			ebtables -t "$TABLE" -X >/dev/null 2>&1 || true
		done
	fi
	if command -v nft >/dev/null 2>&1; then
		nft flush ruleset >/dev/null 2>&1 || true
	fi
	if command -v ipset >/dev/null 2>&1; then
		ipset flush >/dev/null 2>&1 || true
		ipset destroy >/dev/null 2>&1 || true
	fi
	ip xfrm policy flush >/dev/null 2>&1 || true
	ip xfrm state flush >/dev/null 2>&1 || true
	if command -v tc >/dev/null 2>&1; then
		for IFACE_PATH in /sys/class/net/*; do
			[ -e "$IFACE_PATH" ] || continue
			IFACE_NAME=${IFACE_PATH##*/}
			[ "$IFACE_NAME" = "lo" ] && continue
			tc qdisc del dev "$IFACE_NAME" root >/dev/null 2>&1 || true
			tc qdisc del dev "$IFACE_NAME" ingress >/dev/null 2>&1 || true
		done
	fi
	for IFACE_PATH in /sys/class/net/*; do
		[ -e "$IFACE_PATH" ] || continue
		IFACE_NAME=${IFACE_PATH##*/}
		[ "$IFACE_NAME" = "lo" ] && continue
		ip link set dev "$IFACE_NAME" down >/dev/null 2>&1 || true
	done
	for VIRTUAL_IFACE in bond0 br-lan br-guest utun tun0; do
		ip link delete "$VIRTUAL_IFACE" >/dev/null 2>&1 || true
	done
}

reverse_module_quiesce()
{
	flush_runtime_network_state
	MODULES_BEFORE_REVERSE=$(wc -l < /proc/modules)
	log "modules loaded before reverse-order unload: $MODULES_BEFORE_REVERSE"
	log "/proc/modules is newest-first in this kernel; using it as reverse load order"
	log "protected non-unloadable chain: qca_nss_eip -> qca_nss_ppe -> qca_ssdk"
	cat /proc/modules >> "$TMP_LOG" 2>&1 || true

	MODULE_PASS=1
	while [ "$MODULE_PASS" -le 8 ]; do
		# kernel/module.c inserts each new module at the list head, and
		# /proc/modules walks that list from its head.  Each snapshot therefore
		# is the exact reverse of successful load order for the remaining set.
		awk '{print $1}' /proc/modules > "/tmp/be7000-modules-pass-$MODULE_PASS.txt"
		PASS_UNLOADED=0
		while IFS= read -r UNLOAD_MODULE; do
			if unload_one_module "$UNLOAD_MODULE"; then
				PASS_UNLOADED=$((PASS_UNLOADED + 1))
			fi
		done < "/tmp/be7000-modules-pass-$MODULE_PASS.txt"
		rm -f "/tmp/be7000-modules-pass-$MODULE_PASS.txt"
		log "reverse module quiesce pass $MODULE_PASS unloaded $PASS_UNLOADED modules"
		[ "$PASS_UNLOADED" -gt 0 ] || break
		MODULE_PASS=$((MODULE_PASS + 1))
	done

	log "modules remaining after reverse-order unload:"
	cat /proc/modules >> "$TMP_LOG" 2>&1 || true
	log "interrupts remaining after reverse-order unload:"
	cat /proc/interrupts >> "$TMP_LOG" 2>&1 || true

	awk '{print $1}' /proc/modules > /tmp/be7000-module-names-final.txt
	MODULE_QUIESCE_OK=1
	while IFS= read -r REMAINING_MODULE; do
		case "$REMAINING_MODULE" in
			qca_nss_eip|qca_nss_ppe|qca_ssdk)
				REMAINING_HOLDERS=$(module_holders "$REMAINING_MODULE")
				REMAINING_REFCNT=$(module_refcnt "$REMAINING_MODULE")
				log "known protected module remains: $REMAINING_MODULE refcnt=$REMAINING_REFCNT holders=${REMAINING_HOLDERS:-none}"
				;;
			ecm*|qca_nss_*|qca_mcs|emesh_sp|ipq_cnss2|qca_ol|wifi_3_0|umac|qdf|mem_manager)
				REMAINING_HOLDERS=$(module_holders "$REMAINING_MODULE")
				REMAINING_REFCNT=$(module_refcnt "$REMAINING_MODULE")
				log "DMA-critical module remains loaded: $REMAINING_MODULE refcnt=$REMAINING_REFCNT holders=${REMAINING_HOLDERS:-none}"
				MODULE_QUIESCE_OK=0
				;;
		esac
	done < /tmp/be7000-module-names-final.txt

	for REQUIRED_RESIDUAL in qca_nss_eip qca_nss_ppe qca_ssdk; do
		if [ ! -d "/sys/module/$REQUIRED_RESIDUAL" ]; then
			log "expected protected residual is unexpectedly absent: $REQUIRED_RESIDUAL"
			MODULE_QUIESCE_OK=0
		fi
	done

	EIP_HOLDERS=$(module_holders qca_nss_eip)
	PPE_HOLDERS=$(module_holders qca_nss_ppe)
	SSDK_HOLDERS=$(module_holders qca_ssdk)
	EIP_REFCNT=$(module_refcnt qca_nss_eip)
	PPE_REFCNT=$(module_refcnt qca_nss_ppe)
	SSDK_REFCNT=$(module_refcnt qca_ssdk)
	if [ -n "$EIP_HOLDERS" ] || [ "$EIP_REFCNT" != "0" ]; then
		log "unexpected EIP residual state: refcnt=$EIP_REFCNT holders=${EIP_HOLDERS:-none}"
		MODULE_QUIESCE_OK=0
	fi
	if [ "$PPE_HOLDERS" != "qca_nss_eip," ]; then
		log "unexpected PPE residual state: refcnt=$PPE_REFCNT holders=${PPE_HOLDERS:-none}"
		MODULE_QUIESCE_OK=0
	fi
	if [ "$SSDK_HOLDERS" != "qca_nss_ppe," ]; then
		log "unexpected SSDK residual state: refcnt=$SSDK_REFCNT holders=${SSDK_HOLDERS:-none}"
		MODULE_QUIESCE_OK=0
	fi

	if grep -qE 'edma_(txcmpl|rxdesc|misc)' /proc/interrupts 2>/dev/null; then
		log "EDMA interrupt handlers remain registered"
		MODULE_QUIESCE_OK=0
	else
		log "EDMA interrupt handlers are absent"
	fi

	log "EIP ring state retained for audit:"
	for EIP_RING in /sys/kernel/debug/qca-nss-eip/eip197/ring_*; do
		[ -r "$EIP_RING" ] || continue
		echo "[$EIP_RING]" >> "$TMP_LOG"
		cat "$EIP_RING" >> "$TMP_LOG" 2>&1 || true
	done
	EIP_IRQ_BEFORE=$(eip_irq_total)
	sleep 1
	EIP_IRQ_AFTER=$(eip_irq_total)
	log "EIP IRQ total idle check: before=$EIP_IRQ_BEFORE after=$EIP_IRQ_AFTER"
	if [ "$EIP_IRQ_BEFORE" != "$EIP_IRQ_AFTER" ]; then
		log "EIP interrupt count changed during idle check"
		MODULE_QUIESCE_OK=0
	fi

	[ "$MODULE_QUIESCE_OK" -eq 1 ] ||
		abort_to_stock "unexpected DMA module, holder, reference, or interrupt activity"
	log "reverse teardown verified: removable DMA modules and EDMA are absent; idle EIP->PPE->SSDK residual retained"
}

abort_to_stock()
{
	REASON=$*
	echo "failed:quiesce" > "$PHASE_FILE"
	log "critical quiesce verification failed: $REASON"
	log "forcing ordinary original reboot; kexec will not be called"
	persist_log
	/sbin/reboot -f
	while :; do sleep 60; done
}

log "stage 2 armed; cancellation window started"
for LEFT in 10 9 8 7 6 5 4 3 2 1; do
	echo "countdown:$LEFT" > "$PHASE_FILE"
	sleep 1
done

trap '' TERM INT
echo "quiescing" > "$PHASE_FILE"
log "quiescing started"

# High-I/O and event-generating user services. Autostart settings are untouched.
for SERVICE in \
	messagingagent.sh miwifi-discovery cab_meshd miwifi-roam \
	trafficd indexservice.init datacenter smartcontroller baidupan \
	filetunnel stunserver topomon pluginmanager xq_info_sync_mqtt \
	mobile_accel miqos miot mosquitto tbusd netapi wan_check iweventd \
	miniupnpd samba afpd nginx cron telnet dnsmasq odhcpd rpcd cnss_diag
do
	stop_service "$SERVICE"
done

# Stop interfaces only after network consumers are gone. The detached worker
# continues locally after SSH and LAN disappear.
stop_service network
stop_service qca-hostapd
stop_service qca-wpa-supplicant

# The stock kernel has CONFIG_KEXEC_CORE disabled, so PCI core shutdown does
# not clear bus mastering.  First use Qualcomm's own WLAN teardown path: it
# unregisters qca_ol and calls rproc_shutdown() for WCSS and the PCI QCN9224.
# Never force remoteproc sysfs state here: if the vendor teardown cannot prove
# both processors offline, fall back to an ordinary reset instead of kexec.
log "stopping cnssdaemon before vendor WLAN teardown"
killall -TERM cnssdaemon 2>/dev/null || true
sleep 2
killall -KILL cnssdaemon 2>/dev/null || true

[ -x /sbin/wifi ] || abort_to_stock "vendor /sbin/wifi helper is absent"
log "running vendor WLAN module teardown: /sbin/wifi unload"
if /usr/bin/timeout -t 60 /sbin/wifi unload >> "$TMP_LOG" 2>&1; then
	WIFI_UNLOAD_RC=0
else
	WIFI_UNLOAD_RC=$?
	log "vendor wifi unload returned rc=$WIFI_UNLOAD_RC; checking actual state"
fi
sleep 3

WLAN_QUIESCE_OK=1
for WLAN_MODULE in qca_ol wifi_3_0; do
	if [ -d "/sys/module/$WLAN_MODULE" ]; then
		log "WLAN module is still loaded: $WLAN_MODULE"
		WLAN_QUIESCE_OK=0
	else
		log "WLAN module is absent as required: $WLAN_MODULE"
	fi
done

for RPROC in remoteproc0 remoteproc1; do
	STATE_FILE="/sys/class/remoteproc/$RPROC/state"
	if [ ! -r "$STATE_FILE" ]; then
		log "remoteproc state is unavailable: $RPROC"
		WLAN_QUIESCE_OK=0
		continue
	fi
	RPROC_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo unreadable)
	log "$RPROC state after WLAN unload: $RPROC_STATE"
	[ "$RPROC_STATE" = "offline" ] || WLAN_QUIESCE_OK=0
done

[ "$WLAN_QUIESCE_OK" -eq 1 ] ||
	abort_to_stock "WLAN modules or Qualcomm remoteprocs remain active"
log "vendor WLAN teardown verified: WCSS and QCN9224 remoteprocs are offline"

stop_service dropbear

# Remove any residual instances whose vendor init scripts did not stop cleanly.
for PROCESS in \
	lua mihomo messagingagent trafficd indexservice datacenter netapi \
	wan_detect wan_check_status iwevent iwevent-call cab_meshd miwifi-roam \
	miniupnpd dnsmasq odhcpd nginx fcgi-cgi smbd nmbd crond pppd odhcp6c \
	hostapd wpa_supplicant cnssdaemon
do
	killall -TERM "$PROCESS" 2>/dev/null || true
done
killall -TERM dropbear 2>/dev/null || true
sleep 3
for PROCESS in \
	lua mihomo messagingagent trafficd indexservice datacenter netapi \
	wan_detect wan_check_status iwevent iwevent-call cab_meshd miwifi-roam \
	miniupnpd dnsmasq odhcpd nginx fcgi-cgi smbd nmbd crond pppd odhcp6c \
	hostapd wpa_supplicant cnssdaemon
do
	killall -KILL "$PROCESS" 2>/dev/null || true
done
killall -KILL dropbear 2>/dev/null || true

# The image and executor are already in RAM/tmpfs, so USB is no longer needed.
if [ "$USB_MOUNT" != "none" ]; then
	log "unmounting USB: $USB_MOUNT"
	if ! /usr/bin/timeout -t 20 umount "$USB_MOUNT" >> "$TMP_LOG" 2>&1; then
		log "USB unmount failed; syncing and using lazy unmount"
		sync
		umount -l "$USB_MOUNT" >> "$TMP_LOG" 2>&1 || {
			log "lazy unmount failed; attempting read-only remount"
			mount -o remount,ro "$USB_MOUNT" >> "$TMP_LOG" 2>&1 || true
		}
	fi
fi

awk '{print $1}' /proc/modules > /tmp/be7000-module-names-before-reverse.txt
reverse_module_quiesce

stop_service syslog-ng
sleep 5

log "remaining processes before kernel freezer:"
ps w >> "$TMP_LOG" 2>&1 || true
log "syncing all writable filesystems"
sync
echo s > /proc/sysrq-trigger
sleep 2

log "requesting emergency read-only remount"
persist_log
echo "transition" > "$PHASE_FILE"
echo u > /proc/sysrq-trigger
sleep 1

# Reset the Qualcomm watchdog countdown immediately before the kernel call.
# It remains enabled as a 32-second recovery path if relocation/purgatory hangs.
log "rearming hardware watchdog to 32 seconds for transition recovery"
WDT_REPLY=$(ubus call system watchdog \
	'{"timeout":32,"frequency":1}' 2>&1 || true)
echo "$WDT_REPLY" >> "$TMP_LOG"
if ! echo "$WDT_REPLY" | grep -q '"status":[[:space:]]*"running"'; then
	echo "failed:watchdog" > "$PHASE_FILE"
	log "watchdog rearm failed; forcing ordinary reboot instead of kexec"
	/sbin/reboot -f
	while :; do sleep 60; done
fi

log "calling fixed kexec module; it will freeze remaining userspace"
"$KEXEC_BIN" -e
RC=$?

# freeze_processes() thaws automatically when it fails before shutdown.
echo "failed:$RC" > "$PHASE_FILE"
log "kexec returned unexpectedly with rc=$RC; forcing ordinary reboot"
mount -o remount,rw /data >/dev/null 2>&1 || true
persist_log
/sbin/reboot -f

while :; do sleep 60; done
