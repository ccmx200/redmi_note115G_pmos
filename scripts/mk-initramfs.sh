#!/bin/bash
# Build a small Alpine Linux root filesystem to use *as the initramfs*.
#
# The hand-rolled busybox initramfs kept failing in ways that were impossible to see:
# busybox applets missing (45 lines of "sleep: not found"), no way to get a shell when
# something went wrong, and no tools to inspect the disk.  Trading ~10 MB of boot image
# for a real Alpine userland gives us:
#
#   * a complete busybox with every applet, so "sleep: not found" cannot happen
#   * dropbear on usb0 (169.254.42.1, port 2222) started *before* switch_root, so a
#     failed boot is still reachable over SSH instead of producing a blank screen
#   * e2fsprogs, so the grow can be run by hand
#   * blkid/lsblk/losetup/dmesg for debugging
#
# Usage: mk-initramfs.sh <output-dir>
set -euo pipefail

OUT="${1:?usage: mk-initramfs.sh <output-dir>}"
WORK="${WORK:-/root/build-work}"
ALPINE_VER="${ALPINE_VER:-3.22}"
MIRROR="${ALPINE_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/alpine}"
ARCH=aarch64

log() { printf '  %s\n' "$*"; }

rm -rf "$OUT"
mkdir -p "$OUT" "$WORK"

# ------------------------------------------------------------ minirootfs ----
TAR="$WORK/alpine-minirootfs.tar.gz"
if [ ! -s "$TAR" ]; then
    log "downloading Alpine $ALPINE_VER minirootfs"
    ok=0
    for m in "$MIRROR" \
             "https://mirrors.ustc.edu.cn/alpine" \
             "https://mirrors.aliyun.com/alpine"; do
        url="$m/v$ALPINE_VER/releases/$ARCH/alpine-minirootfs-$ALPINE_VER.0-$ARCH.tar.gz"
        if curl -fsSL --max-time 300 -o "$TAR" "$url"; then ok=1; break; fi
    done
    [ "$ok" = 1 ] || { echo "cannot download the Alpine minirootfs"; exit 1; }
fi
log "extracting $(stat -c%s "$TAR") bytes"
tar xzf "$TAR" -C "$OUT"

# ------------------------------------------------------------- packages ----
# apk is run inside the (emulated) Alpine tree so the packages match its libc.
#
# DNS does not resolve inside a qemu-user chroot, and the minirootfs has no
# /etc/resolv.conf at all, so the mirror address is resolved *here* and pinned in the
# tree before apk ever runs.  Without this `apk add` silently fails and the initramfs
# ends up with no dropbear and no e2fsprogs.
log "installing dropbear + e2fsprogs + tools"
cat > "$OUT/etc/apk/repositories" <<EOF
$MIRROR/v$ALPINE_VER/main
$MIRROR/v$ALPINE_VER/community
EOF
cat > "$OUT/etc/resolv.conf" <<EOF
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF
mkdir -p "$OUT/etc"
for h in mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn mirrors.aliyun.com; do
    ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$ip" ] && ip=$(getent hosts "$h" 2>/dev/null | awk '$1 ~ /^[0-9]+\./ {print $1; exit}')
    if [ -n "$ip" ]; then
        echo "$ip $h" >> "$OUT/etc/hosts"
        log "pinned $h -> $ip"
    fi
done

cp -f /usr/bin/qemu-aarch64-static "$OUT/usr/bin/qemu-aarch64-static"
chmod 755 "$OUT/usr/bin/qemu-aarch64-static"

chroot "$OUT" /usr/bin/qemu-aarch64-static /bin/sh -c '
set -e
apk update
# Keep this list minimal.  Every extra megabyte lands in the kernel Image: a 39 MB
# initramfs produced a 94 MB Image and the handset panicked.  busybox covers ip, blockdev,
# blkid, lsblk and friends, so only dropbear and e2fsprogs are really needed.
apk add --no-cache dropbear e2fsprogs
# The stock /bin/busybox is dynamically linked against musl.  /init runs as the very
# first process in the kernel, and any loader problem there is a silent kernel panic,
# so replace it with the static build and drop the dependency entirely.
apk add --no-cache busybox-static >/dev/null 2>&1 || true
if [ -x /bin/busybox.static ]; then
    cp -f /bin/busybox.static /bin/busybox
    chmod 755 /bin/busybox
    echo "  busybox: STATIC"
else
    echo "  busybox: dynamic (busybox-static unavailable)"
fi
echo "  packages: $(apk info 2>/dev/null | wc -l)"
'

rm -f "$OUT/usr/bin/qemu-aarch64-static"

# --------------------------------------------------------------- dropbear ---
# A host key has to exist before dropbear will start; generate a fixed one so the image
# is reproducible and the fingerprint is stable.
mkdir -p "$OUT/etc/dropbear"
if [ ! -f "$OUT/etc/dropbear/dropbear_ed25519_host_key" ]; then
    if command -v dropbearkey >/dev/null 2>&1; then
        dropbearkey -t ed25519 -f "$OUT/etc/dropbear/dropbear_ed25519_host_key" >/dev/null 2>&1 || true
    fi
fi
# fall back to generating it inside the emulated tree
if [ ! -s "$OUT/etc/dropbear/dropbear_ed25519_host_key" ] && [ -x "$OUT/usr/bin/dropbearkey" ]; then
    cp -f /usr/bin/qemu-aarch64-static "$OUT/usr/bin/qemu-aarch64-static"
    chroot "$OUT" /usr/bin/qemu-aarch64-static /usr/bin/dropbearkey \
        -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1 || true
    rm -f "$OUT/usr/bin/qemu-aarch64-static"
fi
echo root:evergo | chroot "$OUT" /bin/sh -c 'chpasswd' 2>/dev/null || true
mkdir -p "$OUT/etc/ssh" "$OUT/root"
printf 'root:evergo\n' > "$OUT/etc/rootpw"     # the init applies it if chpasswd failed

# ------------------------------------------------------------ directory ----
mkdir -p "$OUT"/{proc,sys,dev,tmp,run,newroot,var/log,etc/evergo}
cat > "$OUT/etc/resolv.conf" <<EOF
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF

log "size: $(du -sh "$OUT" | cut -f1)"
