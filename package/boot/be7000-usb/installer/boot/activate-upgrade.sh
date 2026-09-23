#!/bin/sh
# Runs after ramfs teardown, or from stock when resuming an interrupted update.
set -eu
base=$1
case "$base" in /mnt/usb*/BE7000-OpenWrt-Snapshot) ;; *) exit 1;; esac
[ "$(readlink -f "$base")" = "$base" ]
next=$base/.upgrade-next
[ -f "$base/.upgrade-pending" ] && [ -f "$next/READY" ]
[ ! -L "$next" ]
for part in payload boot; do
    [ ! -L "$base/$part" ]
    # Rename each file on the same filesystem. Already moved files disappear
    # from staging, allowing the next stock boot to resume after power loss.
    (cd "$next"; find "$part" -type d) > "$next/directories"
    while IFS= read -r path; do
        [ ! -L "$base/$path" ]
        mkdir -p "$base/$path"
    done < "$next/directories"
    (cd "$next"; find "$part" \( -type f -o -type l \)) > "$next/files"
    while IFS= read -r path; do
        mv -f "$next/$path" "$base/$path"
    done < "$next/files"
done
for part in system.img userdata.img; do
    [ ! -L "$base/$part" ]
    if [ -f "$next/$part" ]; then
        mv -f "$next/$part" "$base/$part"
    fi
    [ -s "$base/$part" ]
done
sync
# Clear the pending marker only after all replacements are on disk.
rm -f "$base/.upgrade-pending"
sync
rm -rf "$next"
rm -f "$base/.upgrade-activate.sh"
