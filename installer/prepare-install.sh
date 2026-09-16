#!/bin/sh
# Pause automatic startup for this Xiaomi boot before changing the USB files.
set -eu
fail() { echo "$*" >&2; exit 1; }
check_transition() {
    phase=$(cat /tmp/be7000-kexec-quiesce.phase 2>/dev/null || true)
    case "$phase" in
        quiescing|transition|failed:*) fail 'The previous boot attempt reached shutdown. Restart Xiaomi before retrying.';;
    esac
    pid=$(cat /tmp/be7000-kexec-quiesce.pid 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        fail 'A boot transition is already running. Wait for it to finish.'
    fi
}
check_transition
mkdir -p /tmp/be7000-autostart.lock
touch /tmp/be7000-installing
for attempt in 1 2 3 4 5; do
    running=0
    for command in /proc/[0-9]*/cmdline; do
        [ -r "$command" ] || continue
        case "$(tr '\000' ' ' < "$command" 2>/dev/null)" in
            'sh /data/BE7000-OpenWrt/autostart.sh run '*|'/bin/sh /data/BE7000-OpenWrt/autostart.sh run '*) running=1;;
        esac
    done
    if [ "$running" -eq 0 ]; then
        check_transition
        exit 0
    fi
    sleep 1
done
fail 'Automatic startup is already running. Wait for it to finish, then retry.'
