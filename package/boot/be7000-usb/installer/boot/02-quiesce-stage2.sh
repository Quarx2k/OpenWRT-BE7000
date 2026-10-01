#!/bin/bash
set -u
umask 077
trap '' HUP
KEXEC_BIN=${1:?}
PERSIST_LOG=${2:?}
USB_MOUNT=${3:-none}
PHASE_FILE=${4:-/tmp/be7000-kexec-quiesce.phase}
TMP_LOG=/tmp/be7000-kexec-quiesce-stage2.log
cp "$PERSIST_LOG" "$TMP_LOG" || exit 1
exec </dev/null >> "$TMP_LOG" 2>&1
cd /tmp || exit 1
log()
{
    printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$TMP_LOG"
}
abort()
{
    log "$*; staying in stock"
    echo failed:quiesce > "$PHASE_FILE"
    cp "$TMP_LOG" "$PERSIST_LOG"
    sync
    exit 1
}
unload_tree()
{
    local module=$1 holder
    case "$module" in qca_nss_eip|qca_nss_ppe|qca_ssdk) abort "protected dependency: $module";; esac
    [ -d "/sys/module/$module" ] || return 0
    for holder in "/sys/module/$module/holders/"*; do
        [ -e "$holder" ] || continue
        unload_tree "${holder##*/}"
    done
    log "unloading hardware module: $module"
    /usr/bin/timeout -t 12 rmmod "$module" >> "$TMP_LOG" 2>&1 || abort "module unload failed: $module"
}
log 'selective hardware teardown armed; no cancellation delay'
while [ -n "${6:-}" ] && kill -0 "$6" 2>/dev/null; do
    sleep 0.1
done
trap '' TERM INT
echo quiescing > "$PHASE_FILE"
log 'stopping network and WLAN services'
for SERVICE in network qca-hostapd qca-wpa-supplicant cnss_diag; do
    [ -x "/etc/init.d/$SERVICE" ] || continue
    /usr/bin/timeout -t 20 "/etc/init.d/$SERVICE" stop >> "$TMP_LOG" 2>&1 || log "service stop returned nonzero: $SERVICE"
done
killall -TERM cnssdaemon 2>/dev/null || true
for LEFT in 1 2; do
    pidof cnssdaemon >/dev/null || break
    sleep 1
done
killall -KILL cnssdaemon 2>/dev/null || true
log 'unloading vendor WLAN'
/usr/bin/timeout -t 60 /sbin/wifi unload >> "$TMP_LOG" 2>&1 || log 'wifi unload returned nonzero; checking state'
for MODULE in qca_ol wifi_3_0; do
    [ ! -d "/sys/module/$MODULE" ] || abort "WLAN module remains: $MODULE"
done
for RPROC in remoteproc0 remoteproc1; do
    STATE=$(cat "/sys/class/remoteproc/$RPROC/state" 2>/dev/null)
    log "$RPROC state: $STATE"
    [ "$STATE" = offline ] || abort "$RPROC is not offline"
done
for IFACE_PATH in /sys/class/net/*; do
    IFACE=${IFACE_PATH##*/}
    [ "$IFACE" = lo ] && continue
    tc qdisc del dev "$IFACE" root >/dev/null 2>&1 || true
    tc qdisc del dev "$IFACE" ingress >/dev/null 2>&1 || true
    ip link set dev "$IFACE" down >/dev/null 2>&1 || true
done
for IFACE in bond0 br-lan br-guest utun tun0; do
    ip link delete "$IFACE" >/dev/null 2>&1 || true
done
awk '{print $1}' /proc/modules > /tmp/be7000-hardware-modules.txt
while IFS= read -r MODULE; do
    case "$MODULE" in
        qca_nss_eip|qca_nss_ppe|qca_ssdk) continue;;
        ecm*|qca_nss_*|qca_mcs|emesh_sp|ipq_cnss2|umac|qdf|mem_manager) unload_tree "$MODULE";;
    esac
done < /tmp/be7000-hardware-modules.txt
if grep -qE 'edma_(txcmpl|rxdesc|misc)' /proc/interrupts; then
    abort 'EDMA interrupt handlers remain'
fi
for MODULE in qca_nss_eip qca_nss_ppe qca_ssdk; do
    for HOLDER in "/sys/module/$MODULE/holders/"*; do
        [ -e "$HOLDER" ] || continue
        case "$MODULE:${HOLDER##*/}" in qca_nss_ppe:qca_nss_eip|qca_ssdk:qca_nss_ppe) ;; *) abort "unexpected holder: $HOLDER";; esac
    done
done
[ "$(cat /sys/module/qca_nss_eip/refcnt)" = 0 ] || abort 'EIP is still in use'
IRQ_BEFORE=$(awk '/eip_irq_ring_/ { for(i=2; i<=NF && $i ~ /^[0-9]+$/; i++) n+=$i } END {print n+0}' /proc/interrupts)
sleep 1
IRQ_AFTER=$(awk '/eip_irq_ring_/ { for(i=2; i<=NF && $i ~ /^[0-9]+$/; i++) n+=$i } END {print n+0}' /proc/interrupts)
[ "$IRQ_BEFORE" = "$IRQ_AFTER" ] || abort 'EIP interrupts are active'
log 'WLAN and Ethernet teardown verified'
if [ -x /etc/init.d/indexservice.init ]; then
    log 'stopping USB index service'
    /usr/bin/timeout -t 20 /etc/init.d/indexservice.init stop >> "$TMP_LOG" 2>&1 || abort 'USB index service stop failed'
fi
sync
if [ "$USB_MOUNT" != none ]; then
    log "unmounting USB: $USB_MOUNT"
    /usr/bin/timeout -t 20 umount "$USB_MOUNT" >> "$TMP_LOG" 2>&1 || abort 'USB unmount failed'
fi
for MODULE in g_diag diagchar usb_f_diag libcomposite usb_storage xhci_plat_hcd xhci_pci xhci_hcd ehci_platform ehci_hcd dwc3_qcom dwc3; do
    [ -d "/sys/module/$MODULE" ] || continue
    log "unloading USB module: $MODULE"
    /usr/bin/timeout -t 12 rmmod "$MODULE" >> "$TMP_LOG" 2>&1 || abort "USB module unload failed: $MODULE"
    [ ! -d "/sys/module/$MODULE" ] || abort "USB module remains: $MODULE"
done
echo transition > "$PHASE_FILE"
WDT_REPLY=$(ubus call system watchdog '{"timeout":32,"frequency":1}' 2>&1 || true)
printf '%s\n' "$WDT_REPLY" >> "$TMP_LOG"
if ! echo "$WDT_REPLY" | grep -q '"status":[[:space:]]*"running"'; then
    echo failed:watchdog > "$PHASE_FILE"
    log 'watchdog rearm failed; staying in stock'
    cp "$TMP_LOG" "$PERSIST_LOG"
    sync
    exit 1
fi
log 'WLAN, Ethernet and USB teardown complete; calling kexec after sync'
cat /proc/uptime >> "$TMP_LOG"
cp "$TMP_LOG" "$PERSIST_LOG"
sync
"$KEXEC_BIN" -e
RC=$?
echo "failed:$RC" > "$PHASE_FILE"
log "kexec returned rc=$RC; rebooting to stock"
cp "$TMP_LOG" "$PERSIST_LOG"
sync
/sbin/reboot -f
