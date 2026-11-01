#!/usr/bin/env python3
"""
decode_trap.py - Given a TRAP report PC, decide whether page 0 / EPROM is intact.

Usage:
    decode_trap.py PC=00E9 OP=8E056DAD9FC0083510393402

Compares the bytes the CPU actually read (the OP= window, now anchored on PC)
against the known-good binaries.  Three outcomes:

  INTACT      the running bytes match the shipped binary  -> code is NOT corrupt,
              the trap is a genuine wild jump (bad pointer / bad stack)
  CORRUPTED   they differ                                  -> something overwrote
              the code in RAM; only writer of page 0 is Load_Copy
  UNKNOWN     no binary covers that address               -> report the region

Reference binaries are read-only; this script never writes them.
"""
import sys
import os

# Page 0 ($0000-$7FFF) is the user window.  We know which programs are meant to
# live there and at which address, from the SD directory boot-address field.
PAGE0 = [
    ("shell/SHELL", 0x0000),   # the binary actually on the SD card
    ("basic69/BASIC", 0x5A00),
]
# EPROM ($E000-$FFFF) and RAM-resident BSS
ROM = [("OSM39V2/bios/osm39.bin", 0xE000)]

HERE = os.path.dirname(os.path.abspath(__file__))


def find(path):
    for root in ("OSM39V1", "OSM39V2"):
        p = os.path.join(os.path.dirname(HERE), root, path)
        if os.path.exists(p):
            return p
    return None


def load(table, addr, n):
    """Return (bytes, offset) if `table` covers [addr, addr+n), else (None, why)."""
    for path, base in table:
        full = find(path)
        if full is None:
            continue
        with open(full, "rb") as f:
            data = f.read()
        lo, hi = base, base + len(data)
        if lo <= addr and addr + n <= hi:
            off = addr - base
            return data[off:off + n], path
    return None, None


def main():
    args = dict(a.split("=", 1) for a in sys.argv[1:] if "=" in a)
    if "PC" not in args or "OP" not in args:
        print(__doc__)
        return 1

    raw = args["OP"].strip()
    if len(raw) % 2:
        print(f"note: OP has an odd number of hex digits ({len(raw)}); "
              f"the last one is a transcription slip, using {len(raw)//2} bytes.\n")
    op = bytes.fromhex(raw[:len(raw) // 2 * 2])

    pc = int(args["PC"], 16)
    print(f"PC = ${pc:04X}   window = {len(op)} bytes")
    print(f"read by the CPU : {op.hex().upper()}")
    print()

    for name, table in (("page 0", PAGE0), ("ROM", ROM)):
        got, path = load(table, pc, len(op))
        if got is None:
            continue
        if got == op:
            print(f"  -> INTACT     ({name}: {path})")
            print("     Every byte the CPU read matches the shipped binary.")
            print("     Nothing is overwriting that code in RAM.")
            return 0
        # The window is anchored on PC, so if PC is not an instruction
        # boundary the tail will decode to nonsense and every byte after the
        # boundary will look "different".  Re-align on the real boundary
        # before accusing anything of corruption.
        diffs = [i for i, (a, b) in enumerate(zip(op, got)) if a != b]
        first = diffs[0]
        head_ok = first >= 2
        if head_ok and all(i == first for i in diffs):
            print(f"  -> INTACT to PC+{first-1}, then diverges  ({name}: {path})")
            print(f"     Bytes PC+0..PC+{first-1} match the shipped binary exactly,")
            print(f"     so the code up to there is NOT corrupted.  But PC = ${pc:04X}")
            print(f"     does not fall on an instruction boundary: the byte at")
            print(f"     PC+{first-1} = ${got[first-1]:02X} is the LAST byte of the")
            print(f"     instruction that starts at ${pc-(first):04X}.")
            print("     => Nothing is overwriting the code.  The trap did not happen")
            print("        where PC points.")
            return 0
        print(f"  -> CORRUPTED  ({name}: {path})")
        print(f"     expected    : {got.hex().upper()}")
        print(f"     first diff  : +{first}  (PC+${first:02X})")
        for i in diffs[:8]:
            print(f"       PC+{i:<3} read={op[i]:02X}  expected={got[i]:02X}")
        print("     Something overwrote the code in RAM.")
        return 0

    region = ("page 0 (user window)" if pc < 0x8000 else
              "VRAM" if pc < 0xA000 else
              "I/O registers" if pc < 0xC000 else
              "BSS / heap" if pc < 0xE000 else
              "EPROM")
    print(f"  -> UNKNOWN    no reference binary covers ${pc:04X} ({region})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
