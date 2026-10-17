#!/usr/bin/env bash
# Build the evergo (Redmi Note 11T 5G / MT6833) Linux boot + rootfs images.
#
# Produces, in out/:
#   boot.img       kernel + initramfs installer (auto-installs on first boot)
#   userdata.img   prebuilt ext4 rootfs for the userdata partition
#
# Everything here was established by bring-up on real hardware; the comments note
# why each step exists because several of them are not obvious.
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/ccmx200/linux-evergo.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-bringup/evergo-mainline}"
RAM_GIB="${RAM_GIB:-6}"                  # this handset is 6 GiB; 4/8 GiB units exist
PANEL="${PANEL:-k16a_36_02_0a_vdo,lcm}"  # Tianma; CSOT is k16a_42_02_0b_vdo,lcm
ROOTFS_MB="${ROOTFS_MB:-1536}"
ALPINE_BRANCH="${ALPINE_BRANCH:-latest-stable}"
DISTRO="${DISTRO:-alpine}"

# build.sh lives at the repository root, so the script's own directory is the
# root.  Adding "/.." here (as if it lived in scripts/) puts every output one
# level above the checkout, which is how CI managed to fail with
#   cp: cannot stat '.../redmi_note115G_pmos/config/author.config'
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
SRC="$OUT/src"
WORK="$OUT/work"
mkdir -p "$OUT" "$SRC" "$WORK"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
command -v ccache >/dev/null && export CC="ccache aarch64-linux-gnu-gcc"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ----------------------------------------------------------------- kernel ----
say "kernel source ($KERNEL_BRANCH)"
if [ ! -d "$SRC/linux/.git" ]; then
    git clone --depth 1 --single-branch --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$SRC/linux"
else
    echo "reusing $SRC/linux"
fi

say "apply config"
cp "$HERE/config/author.config" "$SRC/linux/.config"
# paths that only make sense inside the CI workspace
sed -i "s|^CONFIG_EXTRA_FIRMWARE_DIR=.*|CONFIG_EXTRA_FIRMWARE_DIR=\"$SRC/linux/arch/arm64/boot/dts/mediatek\"|" \
    "$SRC/linux/.config"
sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"$WORK/initramfs\"|" \
    "$SRC/linux/.config"
grep -q '^CONFIG_INITRAMFS_COMPRESSION_GZIP' "$SRC/linux/.config" || \
    echo 'CONFIG_INITRAMFS_COMPRESSION_GZIP=y' >> "$SRC/linux/.config"

say "adapt the device tree (RAM $RAM_GIB GiB, panel $PANEL)"
DTS="$SRC/linux/arch/arm64/boot/dts/mediatek/mt6833-xiaomi-evergo.dts"
python3 - "$DTS" "$RAM_GIB" "$PANEL" <<'PY'
import re, sys
dts, gib, panel = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = open(dts).read()
# memory: the author's tree hardcodes 8 GiB for their own unit
cells = "0 0x40000000 0x1 0x80000000" if gib == 6 else "0 0x40000000 2 0x00000000"
s2 = re.sub(r'(memory:\s*memory@40000000\s*\{[^}]*?reg\s*=\s*<)[^>]*(>;)',
            r'\g<1>' + cells + r'\2', s, flags=re.S)
if s2 == s:
    raise SystemExit("memory node not found in DTS")
s = s2
# panel: two modules exist for this handset
s = re.sub(r'compatible = "k16a_[0-9a_]+[a-z]*_vdo,lcm";',
           f'compatible = "{panel}";', s, count=1)

# Trim the command line.  The author ships loglevel=8 + ignore_loglevel +
# drm.debug=0x1e, which emit about 1.4 MB per boot; console output is synchronous
# so at 115200 baud that is roughly two minutes spent blocked on the UART
# (measured: 1.01 s to a shell after trimming, ~125 s before).  Everything
# functional is deliberately left in place - the *_ignore_unused options and the
# initcall blacklist work around a board whose PMIC has no driver yet.
BOOTARGS = (
    "earlycon=mtk8250,0x11002000 console=evenring console=ttyS0,921600n8 "
    "console=tty0 loglevel=4 printk.devkmsg=on clk_ignore_unused "
    "pd_ignore_unused regulator_ignore_unused panic=10 softlockup_panic=1 "
    "watchdog_thresh=5 initcall_blacklist=exynos4_pm_init_power_domain "
    "fbcon=nodefer cma=256M"
)
s, n = re.subn(r'bootargs = "[^"]*";', f'bootargs = "{BOOTARGS}";', s)
if n != 1:
    raise SystemExit(f"expected 1 bootargs node, replaced {n}")

open(dts, "w").write(s)
print(f"  memory   -> {cells}")
print(f"  panel    -> {panel}")
print(f"  bootargs -> loglevel=4, no drm.debug, no ignore_loglevel")
PY

say "build dtb + kernel"
cd "$SRC/linux"
make -s olddefconfig
make -s -j"$(nproc)" dtbs
DTB=arch/arm64/boot/dts/mediatek/mt6833-xiaomi-evergo.dtb
[ -f "$DTB" ] || { echo "dtb build failed"; exit 1; }
ls -l "$DTB"

# --------------------------------------------------------------- rootfs -----
say "rootfs ($DISTRO)"
case "$DISTRO" in
alpine)
    AIDX="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/aarch64/"
    curl -fsSL "$AIDX" -o "$WORK/idx.html"
    TGZ=$(grep -oE 'alpine-minirootfs-[0-9.]+-aarch64\.tar\.gz' "$WORK/idx.html" | head -1)
    [ -n "$TGZ" ] || { echo "cannot find minirootfs"; exit 1; }
    curl -fsSL -o "$WORK/$TGZ" "$AIDX$TGZ"
    rm -rf "$WORK/rootfs" && mkdir -p "$WORK/rootfs"
    tar xzf "$WORK/$TGZ" -C "$WORK/rootfs"
    # aarch64 static busybox for the installer initramfs
    BIDX="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main/aarch64/"
    curl -fsSL "$BIDX" -o "$WORK/bidx.html"
    BB=$(grep -oE 'busybox-static-[^"]*\.apk' "$WORK/bidx.html" | head -1)
    curl -fsSL -o "$WORK/$BB" "$BIDX$BB"
    rm -rf "$WORK/bb" && mkdir -p "$WORK/bb"
    tar xzf "$WORK/$BB" -C "$WORK/bb"
    cp "$WORK/bb/bin/busybox.static" "$WORK/busybox"
    ;;
*)
    echo "DISTRO=$DISTRO is not wired up yet; only alpine is implemented."
    echo "Debian/Ubuntu need debootstrap plus qemu-aarch64-static in a second stage."
    exit 1
    ;;
esac
chmod 755 "$WORK/busybox"

R="$WORK/rootfs"
mkdir -p "$R"/{proc,sys,dev,tmp,run,mnt,media,opt,srv,root,var/log}

# The minirootfs has no openrc, so /sbin/init cannot start.  Use a small PID 1
# instead; it also feeds the watchdog, which is mandatory or the SoC resets at
# 31 s.
cat > "$R/bin/evergo-init" <<'INIT'
#!/bin/sh
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc     none /proc 2>/dev/null
mount -t sysfs    none /sys  2>/dev/null
mount -t devtmpfs none /dev  2>/dev/null
mkdir -p /dev/pts /tmp /run
mount -t devpts none /dev/pts 2>/dev/null
mount -t tmpfs  none /tmp 2>/dev/null
mount -t tmpfs  none /run 2>/dev/null
[ -x /bin/wdtfeed ] && /bin/wdtfeed &
exec >/dev/ttyGS0 2>&1 </dev/ttyGS0
echo ""
echo "=========================================================="
echo "   $(cat /etc/os-release 2>/dev/null | sed -n 's/^PRETTY_NAME=//p' | tr -d '\"') on evergo"
echo "   $(uname -srm)"
echo "=========================================================="
echo "BOOT_TO_SHELL_UPTIME: $(cut -d' ' -f1 /proc/uptime)"
head -3 /proc/meminfo
echo "dmesg lines: $(dmesg 2>/dev/null | wc -l)"
echo "rootfs: $(grep ' / ' /proc/mounts | head -1)"
echo ""
exec /bin/sh
INIT
chmod 755 "$R/bin/evergo-init"

# Feed the hardware watchdog without spamming the log.
#
# `echo 1 > /dev/watchdog` opens and closes the device on every tick, and because
# the magic 'V' byte is never written the watchdog core logs
#   watchdog0: watchdog did not stop!
# at CRIT level and re-arms the timer - once every 8 seconds, forever.  Holding the
# descriptor open and writing a byte on demand keeps the timer fed and the log
# quiet.  Measured on the handset: the message count stops growing entirely.
cat > "$R/bin/wdtfeed" <<'WDTFEED'
#!/bin/sh
exec 3>/dev/watchdog || exit 1
while true; do
    echo . >&3
    sleep 8
done
WDTFEED
chmod 755 "$R/bin/wdtfeed"

cat > "$R/etc/fstab" <<'FSTAB'
/dev/loop0  /      ext4  defaults,noatime  0 1
proc        /proc  proc  defaults          0 0
sysfs       /sys   sysfs defaults          0 0
devtmpfs    /dev   devtmpfs defaults       0 0
FSTAB

say "userdata.img"
rm -f "$OUT/userdata.img"
truncate -s "${ROOTFS_MB}M" "$OUT/userdata.img"
mke2fs -t ext4 -F -L evergo-root -d "$R" -m 1 -q "$OUT/userdata.img"
debugfs -R 'cat /etc/alpine-release' "$OUT/userdata.img" 2>/dev/null | sed 's/^/  alpine /'
ls -l "$OUT/userdata.img"
gzip -9 -c "$OUT/userdata.img" > "$OUT/userdata.img.gz"

# ------------------------------------------------------------- initramfs ----
say "installer initramfs"
IR="$WORK/initramfs"
rm -rf "$IR" && mkdir -p "$IR"/{bin,dev,proc,sys,tmp,run,newroot}
cp "$OUT/userdata.img.gz" "$IR/rootfs.img.gz"
cp "$WORK/busybox" "$IR/bin/busybox"
chmod 755 "$IR/bin/busybox"
for a in sh mount umount cat gzip losetup switch_root sleep echo ls blockdev mkdir ln sync; do
    ln -sf busybox "$IR/bin/$a"
done

# The kernel opens /dev/console before exec'ing init.  With an initramfs present
# prepare_namespace() never runs, so CONFIG_DEVTMPFS_MOUNT has no effect and
# devtmpfs is not mounted yet - the node has to be inside the archive, or the
# kernel prints "Warning: unable to open an initial console".  gen_initramfs.sh
# emits "nod" entries for real character devices, so create them here.
if [ "$(id -u)" = 0 ]; then
    mknod "$IR/dev/console" c 5 1 && chmod 600 "$IR/dev/console"
    mknod "$IR/dev/null"    c 1 3 && chmod 666 "$IR/dev/null"
else
    echo "  (not root: skipping device nodes, the console warning will appear)"
fi

cat > "$IR/init" <<'INSTALLER'
#!/bin/sh
export PATH=/bin
mount -t proc     none /proc 2>/dev/null
mount -t sysfs    none /sys  2>/dev/null
mount -t devtmpfs none /dev  2>/dev/null
mkdir -p /newroot /tmp /run

# nothing else feeds the watchdog once the bootloader has armed it.  Hold the
# descriptor open like the rootfs wdtfeed does: `echo > /dev/watchdog` in a loop
# closes the device every tick and the core logs "did not stop!" at CRIT level.
[ -e /dev/watchdog ] && ( exec 3>/dev/watchdog; while : ; do echo . >&3; sleep 8; done ) &

i=0; while [ $i -lt 40 ]; do [ -c /dev/ttyGS0 ] && break; sleep 0.25; i=$((i+1)); done
if [ -c /dev/ttyGS0 ]; then exec >/dev/ttyGS0 2>&1 </dev/ttyGS0
else exec >/dev/console 2>&1 </dev/console; fi

say() { echo "[evergo] $*"; }
echo ""
echo "=========================================================="
echo "   evergo installer - Alpine on userdata"
echo "=========================================================="

i=0; while [ $i -lt 60 ]; do [ -b /dev/sdc ] && break; sleep 0.25; i=$((i+1)); done
[ -b /dev/sdc ] || { say "no /dev/sdc"; exec sh; }

# userdata starts here (4096-byte units in the GPT).  No --sizelimit: a loop over
# the raw disk already stops at the end of the disk, which is the only part of
# the declared 226 GiB that physically exists on a 119 GiB LUN.
UD_START=$((3162112 * 4096))
DISK=$(blockdev --getsize64 /dev/sdc 2>/dev/null || echo 0)
say "disk $((DISK / 1048576)) MiB, userdata at +$((UD_START / 1048576)) MiB"
[ "$DISK" -gt "$UD_START" ] || { say "disk too small"; exec sh; }

losetup -o "$UD_START" /dev/loop0 /dev/sdc || { say "losetup failed"; exec sh; }

if mount -t ext4 -o ro /dev/loop0 /newroot 2>/dev/null && [ -f /newroot/etc/alpine-release ]; then
    say "existing rootfs found, keeping it"
    umount /newroot
else
    say "installing rootfs ($(stat -c%s rootfs.img.gz 2>/dev/null) compressed bytes)"
    gzip -dc rootfs.img.gz > /dev/loop0 || { say "write failed"; exec sh; }
    sync
    say "installed"
fi

mount -t ext4 /dev/loop0 /newroot || { say "mount failed"; exec sh; }
[ -x /newroot/bin/evergo-init ] || { say "no evergo-init"; exec sh; }
say "switch_root"
mount --move /proc /newroot/proc 2>/dev/null
mount --move /sys  /newroot/sys  2>/dev/null
mount --move /dev  /newroot/dev  2>/dev/null
exec switch_root /newroot /bin/evergo-init
INSTALLER
chmod 755 "$IR/init"

say "kernel image"
make -s -j"$(nproc)" Image
rm -f usr/initramfs_data.cpio usr/initramfs_data.o usr/initramfs_inc_data usr/.initramfs_data.cpio.d
make -s -j"$(nproc)" Image
IMG=arch/arm64/boot/Image
[ -f "$IMG" ] || { echo "kernel build failed"; exit 1; }
ls -l "$IMG"

# ---------------------------------------------------------------- pack ------
say "boot.img"
# The bootloader expects the kernel payload to be gzip followed by a vendor DTB.
gzip -9 -n -c "$IMG" > "$WORK/image.gz"
cat "$WORK/image.gz" "$HERE/config/vendor_dtb.bin" > "$WORK/kernel.bin"

# empty ramdisk: with CONFIG_INITRAMFS_SOURCE the real initramfs lives inside the
# kernel, and force-DT makes the bootloader's initrd irrelevant anyway
printf '' | gzip -9 > "$WORK/empty-ramdisk.gz"

# the bootloader's own argument line, copied verbatim from the stock image
CMDLINE='bootopt=64S3,32N2,64N2 androidboot.selinux=enforcing buildvariant=user'

python3 "$HERE/scripts/mkbootimg.py" \
    --kernel "$WORK/kernel.bin" \
    --ramdisk "$WORK/empty-ramdisk.gz" \
    --dtb "$HERE/config/dt_table_stock.bin" \
    --pagesize 2048 --header-version 2 --os-version 0x1800017c \
    --cmdline "$CMDLINE" \
    --base 0x40000000 --kernel-offset 0x80000 \
    --ramdisk-offset 0x11100000 --tags-offset 0x7c80000 \
    --output "$WORK/boot-nofooter.img"

python3 "$HERE/scripts/avb.py" \
    --image "$WORK/boot-nofooter.img" \
    --footer-template "$HERE/config/avb_footer.bin" \
    --vbmeta-template "$HERE/config/avb_vbmeta.bin" \
    --output "$OUT/boot.img"

say "artifacts"
ls -l "$OUT"/*.img "$OUT"/*.gz 2>/dev/null | grep -v '^d'
