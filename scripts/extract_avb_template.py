#!/usr/bin/env python3
"""
Reduce the AVB template to the two small pieces the packer needs.

The template came from a dumped 128 MiB boot partition, which is far too big to
commit.  All that is actually required is the last 64 bytes (the footer) and the
vbmeta blob it points at, so extract those into a couple of hundred bytes and
keep the repository small.
"""
import struct

SRC = r"C:\Users\cuicanmx\Documents\deepseek-harness\default-workspace\kvm\phone\boot_a.img"
OUT_DIR = r"C:\Users\cuicanmx\Documents\deepseek-harness\default-workspace\pmos-repo\config"

data = open(SRC, "rb").read()
tail = data[-64:]
if tail[:4] != b"AVBf":
    raise SystemExit("no AVBf footer in the source image")

ver_major, ver_minor = struct.unpack_from(">2I", tail, 4)
orig, = struct.unpack_from(">Q", tail, 12)
vo, vs = struct.unpack_from(">Q", tail, 20)[0], struct.unpack_from(">Q", tail, 28)[0]
print(f"footer: version {ver_major}.{ver_minor}  original_image_size {orig}")
print(f"        vbmeta offset {vo} size {vs}")

open(f"{OUT_DIR}/avb_footer.bin", "wb").write(tail)
open(f"{OUT_DIR}/avb_vbmeta.bin", "wb").write(data[vo:vo + vs])
print(f"wrote avb_footer.bin ({len(tail)} B)")
print(f"wrote avb_vbmeta.bin ({vs} B)")

vb = data[vo:vo + vs]
magic = vb[:4]
algo = struct.unpack_from(">I", vb, 28)[0]
print(f"vbmeta magic {magic!r} algorithm {algo} "
      f"({'NONE - no signing key needed' if algo == 0 else 'SIGNED'})")
