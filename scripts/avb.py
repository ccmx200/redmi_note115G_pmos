#!/usr/bin/env python3
"""
Append the AVB footer + vbmeta to a boot image.

The stock boot partition ends with an AVBf footer whose original_image_size tells
the bootloader where the image really ends (47 MiB of a 128 MiB partition); an
image without one makes the bootloader compute a bogus size.

The stock vbmeta uses algorithm 0 (AVB_ALGORITHM_TYPE_NONE), so no signing key is
needed - recompute sha256(salt || image) and patch it into a copy of the stock
hash descriptor, then write the footer at the end of the partition.

--footer-template / --vbmeta-template are the 64-byte footer and its vbmeta blob
carved out of a stock boot partition (see extract_avb_template.py), so the
repository does not have to carry a 128 MiB image.
"""
import argparse
import hashlib
import struct

PARTITION_DEFAULT = 134217728


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--footer-template", required=True)
    ap.add_argument("--vbmeta-template", required=True)
    ap.add_argument("--partition-size", type=int, default=PARTITION_DEFAULT)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()

    raw = open(a.image, "rb").read()
    orig = len(raw)

    footer_t = open(a.footer_template, "rb").read()
    if footer_t[:4] != b"AVBf":
        raise SystemExit("footer template does not start with AVBf")
    vb = bytearray(open(a.vbmeta_template, "rb").read())
    if vb[:4] != b"AVB0":
        raise SystemExit("vbmeta template does not start with AVB0")

    algo = struct.unpack_from(">I", vb, 28)[0]
    if algo != 0:
        raise SystemExit(f"vbmeta algorithm is {algo}, expected 0 (unsigned)")

    desc = 256
    tag, _nbf = struct.unpack_from(">2Q", vb, desc)
    if tag != 2:
        raise SystemExit("first descriptor is not AVB_HASH")
    isz_off = desc + 16
    lens_off = isz_off + 8 + 32
    pname_len, salt_len, digest_len, _flags = struct.unpack_from(">4I", vb, lens_off)
    body = lens_off + 16 + 60
    salt = bytes(vb[body + pname_len: body + pname_len + salt_len])
    dig_off = body + pname_len + salt_len

    struct.pack_into(">Q", vb, isz_off, orig)
    vb[dig_off:dig_off + digest_len] = hashlib.sha256(salt + raw).digest()

    buf = bytearray(raw) + vb
    vbmeta_off = len(raw)
    footer_off = a.partition_size - 64
    if len(buf) > footer_off:
        raise SystemExit(f"image too large: {len(buf)} > {footer_off}")
    buf += b"\x00" * (footer_off - len(buf))

    footer = bytearray(64)
    footer[0:4] = b"AVBf"
    struct.pack_into(">2I", footer, 4, 1, 0)
    struct.pack_into(">Q", footer, 12, orig)
    struct.pack_into(">Q", footer, 20, vbmeta_off)
    struct.pack_into(">Q", footer, 28, len(vb))
    buf += footer
    assert len(buf) == a.partition_size

    open(a.output, "wb").write(buf)
    print(f"wrote {a.output}: {len(buf)} bytes, image_size {orig}, vbmeta@{vbmeta_off}")


main()
