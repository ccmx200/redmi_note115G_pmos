#!/usr/bin/env python3
"""
Pack an Android boot image v2 with the field layout the MTK bootloader expects.

The name[16] field is easy to miss and it breaks everything downstream: omitting
it shifts cmdline, id, extra_cmdline, header_size and dtb_size by 16 bytes, the
bootloader then reads dtb_size from the wrong offset and asserts
(bootreason=lk_crash) before a single line of kernel code runs.  That cost a lot
of time during bring-up, hence this file being explicit about the layout.

    8s   magic "ANDROID!"
    10I  kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
         second_size, second_addr, tags_addr, page_size,
         header_version, os_version
    16s  name
    512s cmdline
    32s  id  (sha1 of kernel+ramdisk, each followed by its size)
    1024s extra_cmdline
    I Q I  recovery_dtbo_size, recovery_dtbo_offset, header_size (=1660)
    I Q    dtb_size, dtb_addr
"""
import argparse
import hashlib
import struct

BOOT_MAGIC = b"ANDROID!"
HEADER_V2_SIZE = 1660


def pad(data: bytes, page: int) -> bytes:
    return data + b"\x00" * ((page - len(data) % page) % page)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", required=True)
    ap.add_argument("--dtb")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--name", default="")
    ap.add_argument("--pagesize", type=int, default=2048)
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0x40000000)
    ap.add_argument("--kernel-offset", type=lambda x: int(x, 0), default=0x00080000)
    ap.add_argument("--ramdisk-offset", type=lambda x: int(x, 0), default=0x11100000)
    ap.add_argument("--tags-offset", type=lambda x: int(x, 0), default=0x07c80000)
    ap.add_argument("--os-version", type=lambda x: int(x, 0), default=0)
    ap.add_argument("--header-version", type=int, default=2)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read()
    dtb = open(a.dtb, "rb").read() if a.dtb else b""
    page = a.pagesize

    kernel_addr = a.base + a.kernel_offset
    ramdisk_addr = a.base + a.ramdisk_offset
    tags_addr = a.base + a.tags_offset

    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(struct.pack("<I", len(kernel)))
    sha.update(ramdisk)
    sha.update(struct.pack("<I", len(ramdisk)))
    img_id = sha.digest() + b"\x00" * 12

    hdr = bytearray()
    hdr += struct.pack("<8s10I", BOOT_MAGIC,
                       len(kernel), kernel_addr,
                       len(ramdisk), ramdisk_addr,
                       0, 0, tags_addr, page, a.header_version, a.os_version)
    assert len(hdr) == 48
    hdr += a.name.encode()[:15].ljust(16, b"\x00")
    hdr += a.cmdline.encode()[:511].ljust(512, b"\x00")
    hdr += img_id
    hdr += b"\x00" * 1024
    hdr += struct.pack("<IQI", 0, 0, HEADER_V2_SIZE)
    hdr += struct.pack("<IQ", len(dtb), tags_addr)
    assert len(hdr) == HEADER_V2_SIZE, len(hdr)

    out = pad(bytes(hdr), page) + pad(kernel, page) + pad(ramdisk, page) + pad(dtb, page)
    open(a.output, "wb").write(out)
    print(f"wrote {a.output}: header {len(hdr)}, kernel {len(kernel)}, "
          f"ramdisk {len(ramdisk)}, dtb {len(dtb)}, total {len(out)}")


main()
