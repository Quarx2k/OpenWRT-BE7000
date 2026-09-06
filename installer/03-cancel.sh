#!/bin/sh

set -eu

SELF_DIR=${0%/*}
[ "$SELF_DIR" = "$0" ] && SELF_DIR=.
BASE_DIR=$(CDPATH= cd "$SELF_DIR" 2>/dev/null && pwd)
KEXEC="$BASE_DIR/kexec"
PID_FILE="/tmp/be7000-kexec-quiesce.pid"
PHASE_FILE="/tmp/be7000-kexec-quiesce.phase"

[ "$(id -u)" = "0" ] || {
	echo "ERROR: run as root" >&2
	exit 1
}

if [ -r "$PID_FILE" ]; then
	WORKER_PID=$(cat "$PID_FILE" 2>/dev/null || true)
	PHASE=$(cat "$PHASE_FILE" 2>/dev/null || echo unknown)
	WORKER_LIVE=0
	if [ -n "$WORKER_PID" ] && kill -0 "$WORKER_PID" 2>/dev/null; then
		WORKER_LIVE=1
	fi
	case "$PHASE" in
		countdown*)
			if [ "$WORKER_LIVE" -eq 1 ]; then
				kill "$WORKER_PID" 2>/dev/null || true
				sleep 1
				kill -KILL "$WORKER_PID" 2>/dev/null || true
			fi
			;;
		quiescing|transition)
			echo "ERROR: worker is already in phase '$PHASE'; cancellation is unsafe" >&2
			exit 2
			;;
		*)
			if [ "$WORKER_LIVE" -eq 1 ]; then
				echo "ERROR: live worker has unknown phase '$PHASE'; refusing cancellation" >&2
				exit 2
			fi
			;;
	esac
fi

rm -f /tmp/be7000-kexec-quiesce.bin \
	/tmp/be7000-kexec-quiesce-stage2.sh "$PID_FILE" "$PHASE_FILE"

if [ -r /sys/kernel/kexec_loaded ] && [ "$(cat /sys/kernel/kexec_loaded)" = "1" ]; then
	"$KEXEC" -c -u
fi

if grep -q '^kexec_mod ' /proc/modules 2>/dev/null; then
	rmmod kexec_mod
fi

if grep -q '^kexec_mod_arm64 ' /proc/modules 2>/dev/null; then
	rmmod kexec_mod_arm64
fi

rm -f "$BASE_DIR/loaded-state.txt"
echo "Prepared image, worker and modules are unloaded. No /dev/mem check and no reboot were performed."
