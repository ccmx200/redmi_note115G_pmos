#!/bin/bash
# Read the kernel panic log without UART.
#
# This board has no serial console, but the kernel writes its console output into
# a DRAM ring that the bootloader (LK) flushes into the "expdb" UFS partition at
# the end of every boot session (see arch/arm64/kernel/setup.c, evergo_ring).
# That makes expdb the only place a panic survives a reboot, so this script
# dumps it and extracts the readable text:
#
#   ssh root@169.254.42.1 ./scripts/read-expdb.sh
#
# usage: read-expdb.sh [DISK] [OUTFILE]
#   DISK     UFS LUN that carries the GPT (default: autodetect)
#   OUTFILE  where the extracted log goes (default /tmp/evergo-panic.log)
#
# The dump itself lands in /tmp/expdb.bin (40 MiB).  Requires root, python3,
# dd and a little free space in /tmp.

set -euo pipefail

OUT="${2:-/tmp/evergo-panic.log}"
DUMP=/tmp/expdb.bin

find_disk() {
    if [ "$#" -gt 0 ] && [ -n "$1" ]; then echo "$1"; return; fi
    for d in /sys/block/sd*; do
        [ -e "$d" ] || continue
        local dev=/dev/$(basename "$d")
        # GPT header sits at LBA1; this device uses 4096-byte logical blocks
        if dd if="$dev" bs=4096 skip=1 count=1 2>/dev/null | head -c 8 | grep -q "EFI PART"; then
            echo "$dev"; return
        fi
    done
    return 1
}

DISK="$(find_disk "${1:-}")" || {
    echo "no UFS LUN with a GPT found; pass the disk explicitly (read-expdb.sh /dev/sdX)" >&2
    exit 1
}
echo "disk:  $DISK"

# parse the GPT, find expdb, print its first LBA and size in blocks
INFO="$(python3 - "$DISK" <<'PY'
import struct, sys
disk = sys.argv[1]
with open(disk, "rb") as f:
    f.seek(4096)                       # LBA1 with 4096-byte logical blocks
    hdr = f.read(92)
    if hdr[:8] != b"EFI PART":
        sys.exit("no GPT header at LBA1 on " + disk)
    entry_lba = struct.unpack("<Q", hdr[72:80])[0]
    n_entries = struct.unpack("<I", hdr[80:84])[0]
    entry_size = struct.unpack("<I", hdr[84:88])[0]
    f.seek(entry_lba * 4096)
    entries = f.read(n_entries * entry_size)
for i in range(n_entries):
    e = entries[i * entry_size:(i + 1) * entry_size]
    if e[:16] == b"\0" * 16:
        continue
    start_lba, last_lba = struct.unpack("<QQ", e[32:48])
    name = e[56:128].decode("utf-16-le").split("\0", 1)[0]
    if name == "expdb":
        print(start_lba, last_lba - start_lba + 1)
        sys.exit(0)
sys.exit("expdb partition not found in the GPT")
PY
)"
START="$(echo "$INFO" | cut -d" " -f1)"
BLOCKS="$(echo "$INFO" | cut -d" " -f2)"

[ -n "${START:-}" ] || { echo "could not locate expdb" >&2; exit 1; }
echo "expdb: LBA $START, $((BLOCKS * 4096 / 1048576)) MiB"

echo "dumping to $DUMP ..."
dd if="$DISK" of="$DUMP" bs=4096 skip="$START" count="$BLOCKS" status=none
sync

echo "extracting ..."
python3 - "$DUMP" "$OUT" <<'PY'
import struct
import sys

data = open(sys.argv[1], "rb").read()
text = data.replace(b"\x00", b"\n").decode("utf-8", "replace")
lines = text.splitlines()

# The ring frames the evergo console writes are stamped "EVFRAME" + seq + len
# + text; collect every copy, keep the newest, and put that log first.
frames = {}
i = 0
while True:
    i = data.find(b"EVFRAME", i)
    if i < 0:
        break
    seq, ln = struct.unpack("<II", data[i + 8:i + 16])
    body = data[i + 16:i + 16 + ln]
    frames.setdefault((seq, ln), body)
    i += 1

ring = []
for (seq, ln), body in sorted(frames.items(), key=lambda kv: kv[0][0])[-400:]:
    ring.append(body.decode("utf-8", "replace"))
ring_text = "".join(ring)

markers = ("Kernel panic", "Unable to handle", "Internal error",
           "BUG: Bad page map", "Call trace", "Oops")
last = 0
for n, line in enumerate(lines):
    if any(m in line for m in markers):
        last = n

with open(sys.argv[2], "w") as out:
    out.write("=== last crash block (from the LK log store) ===\n")
    out.write("\n".join(lines[max(0, last - 120):last + 120]))
    out.write("\n\n=== evergo console ring (newest frames) ===\n")
    out.write(ring_text)

print(f"wrote {sys.argv[2]}")
for n, line in enumerate(lines):
    if "Kernel panic" in line:
        print("last panic:", line.strip()[:120])
PY

echo "log:  $OUT"
echo "hint: grep -nE 'Kernel panic|Unable to handle|BUG: Bad page map|Call trace' $OUT"
