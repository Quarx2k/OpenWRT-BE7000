#!/bin/bash
# Embedded initramfs: validate Image, DTB and purgatory without /dev/mem.
set -eu
base=${0%/*}
. "$base/target.env"
[ "$#" -eq 1 ] && [ -r "$1" ] || exit 2
fail() { echo 'Invalid Image/DTB/purgatory placement' >&2; exit 1; }
rows=$(awk '/^segment\[[0-9]+\]\.mem(sz)? += / {print $1, $3}' "$1")
[ "$(printf '%s\n' "$rows" | wc -l)" -eq 6 ] || fail
get() {
    value=$(printf '%s\n' "$rows" | awk -v key="$1" '$1 == key {print $2}')
    case "$value" in 0x*) ;; *) fail ;; esac
    case "${value#0x}" in ''|*[!0-9a-fA-F]*) fail ;; esac
    [ "${#value}" -le 10 ] || fail
    [ "$((value % 4096))" -eq 0 ] || fail
    printf '%s\n' "$value"
}
K=$(get 'segment[0].mem'); KS=$(get 'segment[0].memsz')
D=$(get 'segment[1].mem'); DS=$(get 'segment[1].memsz')
P=$(get 'segment[2].mem'); PS=$(get 'segment[2].memsz')
[ "$((K))" -eq "$((KERNEL_ENTRY))" ] || fail
[ "$((KS))" -eq "$KERNEL_MEMORY_BYTES" ] || fail
[ "$((HOLDING_PEN))" -ge "$((K))" ] && [ "$((HOLDING_PEN))" -lt "$((K + KS))" ] || fail
[ "$((D))" -ge "$((K + KS))" ] || fail
[ "$((P))" -ge "$((D + DS))" ] || fail
[ "$((DS))" -ge @DTB_BYTES@ ] && [ "$((DS))" -le 2097152 ] || fail
[ "$((PS))" -gt 0 ] && [ "$((PS))" -le 2097152 ] || fail
[ "$((P + PS))" -le "$((0x49b00000))" ] || fail
printf '%s %s\n' "$D" "$P"
