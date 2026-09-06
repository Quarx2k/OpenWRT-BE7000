#!/usr/bin/env python3
"""Bind the stock-ABI CPU sender to the final linked source kernel."""
import argparse
import json
from pathlib import Path
import struct


def layout(image, symbols):
    if len(image) < 64 or image[56:60] != b"ARM\x64":
        raise ValueError("not an uncompressed ARM64 Image")
    offset, size, flags = struct.unpack_from("<QQQ", image, 8)
    if offset != 0x80000 or not len(image) <= size or flags & 1:
        raise ValueError("unexpected Image offset, size or endianness")
    entry = 0x42000000 + offset
    pen = entry + symbols["secondary_holding_pen"] - symbols["_text"]
    if not entry <= pen < entry + len(image) or pen & 3:
        raise ValueError("secondary pen is outside Image or unaligned")
    if entry + size >= 0x4a000000:
        raise ValueError("Image extends beyond the guarded test window")
    return dict(kernel_base=0x42000000, kernel_entry=entry,
                image_bytes=len(image), image_size=size,
                kernel_memsz=(size + 4095) & ~4095, holding_pen=pen,
                spin_table=f"code-4fb3e000-release-4fb3eff8-entry-{pen:x}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("artifact", type=Path)
    p.add_argument("sender", type=Path)
    a = p.parse_args()
    syms = {}
    for line in (a.artifact / "System.map").read_text().splitlines():
        addr, kind, name = line.split()
        if name in ("_text", "secondary_holding_pen"):
            syms[name] = int(addr, 16)
    result = layout((a.artifact / "Image").read_bytes(), syms)
    header = ("/* Generated from the final Image and System.map. */\n"
              f"#define KEXEC_SECONDARY_HOLDING_PEN_PHYS 0x{result['holding_pen']:x}ULL\n"
              f"#define BE7000_TARGET_SPIN_TABLE \"{result['spin_table']}\"\n")
    (a.sender / "kernel/arch/arm64/be7000_target.h").write_text(header)
    (a.artifact / "target-layout.json").write_text(json.dumps(result, indent=2) + "\n")
    (a.artifact / "be7000_target.h").write_text(header)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
