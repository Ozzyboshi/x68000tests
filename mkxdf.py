#!/usr/bin/env python3
"""
mkxdf.py - build a Human68k 2HD floppy image (.XDF) straight from Linux.

No mtools, no emulator round trip: writes the boot sector, both FATs, the root
directory and the data area itself.

Why mtools does not work here: mformat writes an MS-DOS boot sector, and the
MS-DOS BPB is not the Human68k BPB. Human68k puts its BPB at offset 10 of the
boot sector, big-endian, and orders the fields differently - the FAT count
comes BEFORE the reserved-sector count, and their sizes are swapped:

    MS-DOS   11.w bytes/sector  13.b sec/cluster  14.w reserved  16.b nFATs ...
    Human68k 10.w bytes/sector  12.b sec/cluster  13.b nFATs     14.w reserved

so an MS-DOS image read by Human68k yields nonsense geometry and it looks for
the root directory in the wrong place - hence an apparently empty disk.

Usage:
    ./mkxdf.py -o data.xdf DEMO.X [more files...]
    ./mkxdf.py --dump some.xdf          # inspect any image (use on a real
                                        # Human68k disk to confirm the layout)
"""

import argparse
import os
import struct
import sys
import time

# ---- 2HD geometry -----------------------------------------------------------
SECTOR_SIZE         = 1024
CYLINDERS           = 77
HEADS               = 2
SECTORS_PER_TRACK   = 8
TOTAL_SECTORS       = CYLINDERS * HEADS * SECTORS_PER_TRACK    # 1232
IMAGE_SIZE          = TOTAL_SECTORS * SECTOR_SIZE              # 1261568

# ---- filesystem layout ------------------------------------------------------
SECTORS_PER_CLUSTER = 1
NUM_FATS            = 2
RESERVED_SECTORS    = 1
ROOT_ENTRIES        = 192
MEDIA_BYTE          = 0xFE
SECTORS_PER_FAT     = 2

ROOT_SECTORS = ROOT_ENTRIES * 32 // SECTOR_SIZE                # 6
FAT_START    = RESERVED_SECTORS                                # 1
ROOT_START   = RESERVED_SECTORS + NUM_FATS * SECTORS_PER_FAT   # 5
DATA_START   = ROOT_START + ROOT_SECTORS                       # 11
CLUSTER_SIZE = SECTOR_SIZE * SECTORS_PER_CLUSTER
MAX_CLUSTERS = TOTAL_SECTORS - DATA_START


def build_boot_sector(oem=b"MKXDF1.0"):
    """Boot sector with a Human68k BPB. Not bootable - data disk only."""
    buf = bytearray(SECTOR_SIZE)
    buf[0:2] = b"\x60\x1E"          # BRA.S to the stub at offset $20
    buf[2:10] = oem.ljust(8)[:8]
    # BPB at offset 10, big-endian
    struct.pack_into(">H", buf, 10, SECTOR_SIZE)
    buf[12] = SECTORS_PER_CLUSTER
    buf[13] = NUM_FATS
    struct.pack_into(">H", buf, 14, RESERVED_SECTORS)
    struct.pack_into(">H", buf, 16, ROOT_ENTRIES)
    struct.pack_into(">H", buf, 18, TOTAL_SECTORS)
    buf[20] = MEDIA_BYTE
    buf[21] = SECTORS_PER_FAT
    buf[0x20:0x22] = b"\x4E\x75"    # rts - nothing to boot here
    return buf


def fat12_set(fat, cluster, value):
    """Write one 12-bit FAT entry (same nibble packing as MS-DOS FAT12)."""
    off = cluster + (cluster >> 1)          # cluster * 1.5
    if cluster & 1:
        fat[off] = (fat[off] & 0x0F) | ((value << 4) & 0xF0)
        fat[off + 1] = (value >> 4) & 0xFF
    else:
        fat[off] = value & 0xFF
        fat[off + 1] = (fat[off + 1] & 0xF0) | ((value >> 8) & 0x0F)


def fat12_get(fat, cluster):
    off = cluster + (cluster >> 1)
    if cluster & 1:
        return ((fat[off] & 0xF0) >> 4) | (fat[off + 1] << 4)
    return fat[off] | ((fat[off + 1] & 0x0F) << 8)


def dos_datetime(mtime):
    t = time.localtime(mtime)
    dos_time = (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2)
    dos_date = ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday
    return dos_time, dos_date


def split_83(name):
    """Human68k keeps MS-DOS 8.3 in the first 11 bytes (18.3 uses 12..21)."""
    base, _, ext = os.path.basename(name).upper().rpartition(".")
    if not base:
        base, ext = ext, ""
    if len(base) > 8 or len(ext) > 3:
        raise ValueError(f"{name}: name does not fit 8.3 ({base}.{ext})")
    return base.ljust(8).encode("ascii"), ext.ljust(3).encode("ascii")


def dir_entry(name, first_cluster, size, mtime, attr=0x20):
    base, ext = split_83(name)
    dos_time, dos_date = dos_datetime(mtime)
    e = bytearray(32)
    e[0:8] = base
    e[8:11] = ext
    e[11] = attr
    # 12..21 is where Human68k stores the extra characters of an 18.3 name;
    # for a plain 8.3 name it stays zeroed.
    struct.pack_into("<HHH", e, 22, dos_time, dos_date, first_cluster)
    struct.pack_into("<I", e, 28, size)
    return e


def build_image(files, out_path, label=None):
    image = bytearray(IMAGE_SIZE)
    image[0:SECTOR_SIZE] = build_boot_sector()

    fat = bytearray(SECTORS_PER_FAT * SECTOR_SIZE)
    fat[0], fat[1], fat[2] = MEDIA_BYTE, 0xFF, 0xFF

    root = bytearray(ROOT_SECTORS * SECTOR_SIZE)
    slot = 0

    if label:
        e = bytearray(32)
        e[0:11] = label.upper().ljust(11).encode("ascii")[:11]
        e[11] = 0x08                       # volume label
        root[0:32] = e
        slot = 1

    next_cluster = 2
    for path in files:
        data = open(path, "rb").read()
        need = max(1, (len(data) + CLUSTER_SIZE - 1) // CLUSTER_SIZE)
        if next_cluster - 2 + need > MAX_CLUSTERS:
            sys.exit("error: disk full")
        if slot >= ROOT_ENTRIES:
            sys.exit("error: root directory full")

        first = next_cluster
        for i in range(need):
            c = first + i
            fat12_set(fat, c, 0xFFF if i == need - 1 else c + 1)
            off = (DATA_START + (c - 2) * SECTORS_PER_CLUSTER) * SECTOR_SIZE
            chunk = data[i * CLUSTER_SIZE:(i + 1) * CLUSTER_SIZE]
            image[off:off + len(chunk)] = chunk
        next_cluster += need

        root[slot * 32:(slot + 1) * 32] = dir_entry(
            path, first, len(data), os.path.getmtime(path))
        slot += 1
        print(f"  {os.path.basename(path).upper():<14} {len(data):>7} bytes "
              f"-> cluster {first}")

    for i in range(NUM_FATS):
        off = (FAT_START + i * SECTORS_PER_FAT) * SECTOR_SIZE
        image[off:off + len(fat)] = fat
    off = ROOT_START * SECTOR_SIZE
    image[off:off + len(root)] = root

    with open(out_path, "wb") as f:
        f.write(image)
    print(f"{out_path}: {IMAGE_SIZE} bytes, "
          f"{(MAX_CLUSTERS - (next_cluster - 2)) * CLUSTER_SIZE} bytes free")


def dump(path):
    """Inspect an image. Run this on a real Human68k disk to confirm the
    layout this script assumes."""
    img = open(path, "rb").read()
    print(f"{path}: {len(img)} bytes\n")
    print("first 32 bytes:")
    print("  " + " ".join(f"{b:02x}" for b in img[:16]))
    print("  " + " ".join(f"{b:02x}" for b in img[16:32]))

    h = {
        "bytes/sector":  struct.unpack_from(">H", img, 10)[0],
        "sec/cluster":   img[12],
        "num FATs":      img[13],
        "reserved":      struct.unpack_from(">H", img, 14)[0],
        "root entries":  struct.unpack_from(">H", img, 16)[0],
        "total sectors": struct.unpack_from(">H", img, 18)[0],
        "media":         f"0x{img[20]:02x}",
        "sec/FAT":       img[21],
    }
    m = {
        "bytes/sector":  struct.unpack_from("<H", img, 11)[0],
        "sec/cluster":   img[13],
        "reserved":      struct.unpack_from("<H", img, 14)[0],
        "num FATs":      img[16],
        "root entries":  struct.unpack_from("<H", img, 17)[0],
        "total sectors": struct.unpack_from("<H", img, 19)[0],
        "media":         f"0x{img[21]:02x}",
        "sec/FAT":       struct.unpack_from("<H", img, 22)[0],
    }
    print("\nread as Human68k BPB (offset 10, big-endian):")
    for k, v in h.items():
        print(f"  {k:<14} {v}")
    print("\nread as MS-DOS BPB (offset 11, little-endian):")
    for k, v in m.items():
        print(f"  {k:<14} {v}")

    bpb = h if h["bytes/sector"] in (256, 512, 1024, 2048) else m
    which = "Human68k" if bpb is h else "MS-DOS"
    if bpb["bytes/sector"] not in (256, 512, 1024, 2048):
        print("\nneither BPB looks sane - stopping here")
        return
    ss = bpb["bytes/sector"]
    root_start = bpb["reserved"] + bpb["num FATs"] * bpb["sec/FAT"]
    print(f"\nroot directory per the {which} BPB, sector {root_start}:")
    off = root_start * ss
    for i in range(bpb["root entries"]):
        e = img[off + i * 32: off + i * 32 + 32]
        if not e or e[0] in (0x00,):
            break
        if e[0] == 0xE5:
            continue
        name = e[0:8].decode("ascii", "replace").rstrip()
        ext = e[8:11].decode("ascii", "replace").rstrip()
        le_cl, = struct.unpack_from("<H", e, 26)
        le_sz, = struct.unpack_from("<I", e, 28)
        be_cl, = struct.unpack_from(">H", e, 26)
        be_sz, = struct.unpack_from(">I", e, 28)
        print(f"  {name}.{ext:<3} attr={e[11]:02x}  "
              f"LE: cluster {le_cl:>5} size {le_sz:>9}   "
              f"BE: cluster {be_cl:>5} size {be_sz:>9}")


def main():
    p = argparse.ArgumentParser(description="Build a Human68k 2HD .XDF image")
    p.add_argument("files", nargs="*", help="files to place in the root")
    p.add_argument("-o", "--output", default="data.xdf")
    p.add_argument("-l", "--label", help="volume label (up to 11 chars)")
    p.add_argument("--dump", metavar="IMAGE", help="inspect an image instead")
    a = p.parse_args()

    if a.dump:
        dump(a.dump)
        return
    if not a.files:
        p.error("no input files")
    build_image(a.files, a.output, a.label)


if __name__ == "__main__":
    main()
