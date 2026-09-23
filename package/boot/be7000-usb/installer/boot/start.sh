#!/bin/sh
set -eu
# Resume USB update
be7000_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
if [ -f "$be7000_dir/.upgrade-pending" ]; then
    sh "$be7000_dir/.upgrade-activate.sh" "$be7000_dir" || exit 1
    exec sh "$0" "$@"
fi
unset be7000_dir
# End USB update
base=$(CDPATH= cd "$(dirname "$0")" && pwd)
runtime=$base/bash-runtime
run() { "$runtime/lib/ld-musl-aarch64.so.1" --library-path "$runtime/lib" "$runtime/bin/bash" "$@"; }
mkdir -p "$base/logs"
log=$base/logs/installer-start-$(date +%Y%m%d-%H%M%S).log
if { run "$base/01-load-only.sh" LOAD-LINUX618-Vinstaller &&
     run "$base/02-execute.sh" EXECUTE-KEXEC-QUIESCED; } >"$log" 2>&1; then
    echo "Startup armed. Log: $log"
else
    tail -n 20 "$log" >&2
    exit 1
fi
