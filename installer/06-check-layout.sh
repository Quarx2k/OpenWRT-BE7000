#!/bin/sh
# Read loader diagnostics only. Never access physical RAM or invoke kexec.
set -eu
[ "$#" -eq 1 ] && [ -r "$1" ] || exit 2
fail() { echo "ERROR: invalid Image/DTB/purgatory placement" >&2; exit 1; }
ROWS=$(awk '/^segment\[[0-9]+\]\.mem(sz)? += / {print $1, $3}' "$1")
[ "$(printf '%s\n' "$ROWS" | wc -l)" -eq 6 ] || fail
get() {
    value=$(printf '%s\n' "$ROWS" | awk -v key="$1" '$1 == key {print $2}')
    case "$value" in 0x*) ;; *) fail ;; esac
    case "${value#0x}" in ''|*[!0-9a-fA-F]*) fail ;; esac
    # At most 32-bit physical values in this test window.
    [ "${#value}" -le 10 ] || fail
    printf '%s\n' "$value"
}
K=$(get 'segment[0].mem'); KS=$(get 'segment[0].memsz')
D=$(get 'segment[1].mem'); DS=$(get 'segment[1].memsz')
P=$(get 'segment[2].mem'); PS=$(get 'segment[2].memsz')
[ "$((K))" -eq "$((0x42080000))" ] || fail
[ "$((KS))" -eq 31272960 ] || fail
for value in "$K" "$KS" "$D" "$DS" "$P" "$PS"; do
    [ "$((value % 4096))" -eq 0 ] || fail
done
[ "$((DS))" -ge 65536 ] && [ "$((DS))" -le 2097152 ] || fail
[ "$((PS))" -gt 0 ] && [ "$((PS))" -le 2097152 ] || fail
[ "$((D))" -ge "$((K + KS))" ] || fail
[ "$((P))" -ge "$((D + DS))" ] || fail
[ "$((P + PS))" -le "$((0x4a000000))" ] || fail
printf '%s %s\n' "$D" "$P"
