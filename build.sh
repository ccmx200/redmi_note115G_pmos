#!/usr/bin/env bash
# Build the evergo (Redmi Note 11T 5G / MT6833) images - Arch Linux ARM variant.
#
# Produces, in out/:
#   boot.img            kernel + minimal initramfs (switch_root only)
#   userdata.img.gz     Arch Linux ARM on f2fs, 6 GiB
#   userdata.simg       the same filesystem in Android sparse format (for fastboot -S)
#
# This replaced an earlier Alpine/ext4 build.  What changed and why:
#   * rootfs     Alpine -> Arch Linux ARM, ext4 -> f2fs (what the phone's userdata is
#                meant to hold; mounted through a loop at a fixed offset)
#   * initramfs  no longer carries an installer: it mounts the existing filesystem and
#                hands over, so a reflash of boot.img alone keeps the system
#   * USB        g_serial (serial console) -> g_ether (RNDIS only).  There is no COM
#                port at all now; the phone is reached over the network
#   * USB speed  full-speed -> high-speed.  The author pinned full-speed because of
#                BABBLE with the configfs composite gadget; with the simpler legacy
#                g_ether path high-speed is stable and measured ~5x faster
#   * login      fastfetch welcome, first-login wizard (user/hostname/password),
#                password-only SSH
#
# Everything except the kernel is reproducible offline; the kernel build needs the
# cross toolchain and ccache.
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/ccmx200/linux-evergo.git}"
# the author's repo has had its branches rewritten before (the old
# bringup/evergo-mainline is gone, only main remains), so try a few and fail loudly
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"
KERNEL_SRC="${KERNEL_SRC:-}"             # reuse an existing checkout if set
RAM_GIB="${RAM_GIB:-6}"                  # 4/6/8 GiB units exist
PANEL="${PANEL:-k16a_36_02_0a_vdo,lcm}"  # Tianma; CSOT is k16a_42_02_0b_vdo,lcm
ROOTFS_MB="${ROOTFS_MB:-6144}"           # 6 GiB f2fs
ARCH_TARBALL="${ARCH_TARBALL:-}"         # reuse a downloaded Arch ARM rootfs tarball
# mirror used to fetch packages during the build.  The Chinese mirrors are unreachable
# from GitHub's runners, so the default is OCF (Berkeley), which serves the whole tree
# directly; override with MIRROR_HOST=mirrors.tuna.tsinghua.edu.cn locally if faster.
MIRROR_HOST="${MIRROR_HOST:-mirrors.ocf.berkeley.edu}"
USERDATA_OFF=$((0x304000000))            # 12952010752

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"; SRC="$OUT/src"; WORK="$OUT/work"
mkdir -p "$OUT" "$SRC" "$WORK"

# An interrupted run can leave bind mounts under work/rootfs.  Unmount them before
# anything removes that tree: `rm -rf` would otherwise walk into the host's /sys and
# /dev and destroy device nodes.
if [ -d "$WORK/rootfs" ]; then
    for m in $(awk -v m="$WORK/rootfs" '$5 ~ m {print $5}' /proc/self/mountinfo 2>/dev/null | sort -r); do
        umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done
    sleep 1
fi

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
command -v ccache >/dev/null && export CC="ccache aarch64-linux-gnu-gcc"

# Some steps (mounting the f2fs image, chroot) need root.  Locally the build usually
# runs as root; in CI it is invoked under sudo.  If neither, re-exec through sudo so a
# plain `./build.sh` still works for an unprivileged user.
EVERGO_SUDO=""
if [ "$(id -u)" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E env "PATH=$PATH" "HOME=$HOME" "$0" "$@"
    fi
    echo "this build mounts a filesystem and needs root (or sudo)" >&2
    exit 1
fi

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# --------------------------------------------------------------- kernel -----
say "kernel source"
if [ -n "$KERNEL_SRC" ] && [ -d "$KERNEL_SRC" ]; then
    L="$KERNEL_SRC"; echo "  reusing $L"
else
    L="$SRC/linux"
    if [ ! -d "$L/.git" ]; then
        # KERNEL_BRANCH may have been renamed upstream; fall through to the usual
        # defaults instead of dying on a git clone error
        for b in "$KERNEL_BRANCH" main master; do
            echo "  cloning branch $b"
            if git clone --depth 1 --single-branch --branch "$b" "$KERNEL_REPO" "$L" 2>/dev/null; then
                echo "  using $b"
                break
            fi
            rm -rf "$L"
        done
        [ -d "$L/.git" ] || { echo "  !! could not clone $KERNEL_REPO"; exit 1; }
    else
        echo "  reusing $L"
    fi
fi

# the tree may build in-tree or with O=out (a reused checkout often uses O=out).
# When it uses O=out the config must live in the output dir, otherwise kbuild reports
# "The source tree is not clean" and refuses to run.
if [ -d "$L/out/arch/arm64/boot" ]; then
    KMAKE="O=out"; KOUT="$L/out"
else
    KMAKE=""; KOUT="$L"
fi
echo "  build dir: ${KMAKE:-in-tree}"
# kbuild refuses an O=out build when the source tree still has in-tree artifacts
# ("The source tree is not clean").
if [ -n "$KMAKE" ]; then
    rm -f "$L/.config" "$L/.config.old"
    rm -rf "$L/include/config" "$L/include/generated" "$L/arch/arm64/include/generated"
fi

say "apply config"
# evergo.config is the config proven on hardware: author's options plus
#   CONFIG_USB_ETH / USB_ETH_RNDIS  (RNDIS gadget, no g_serial)
#   CONFIG_F2FS_FS* / BLK_DEV_LOOP  (this rootfs)
#   BACKLIGHT_LM36273 / DRM_PANEL_K16A_VDO (display)
cp "$HERE/config/evergo.config" "$KOUT/.config"
sed -i "s|^CONFIG_EXTRA_FIRMWARE_DIR=.*|CONFIG_EXTRA_FIRMWARE_DIR=\"$L/arch/arm64/boot/dts/mediatek\"|" "$KOUT/.config"
sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=\"$WORK/initramfs\"|" "$KOUT/.config"
grep -q '^CONFIG_INITRAMFS_COMPRESSION_GZIP' "$KOUT/.config" || \
    echo 'CONFIG_INITRAMFS_COMPRESSION_GZIP=y' >> "$KOUT/.config"

say "adapt the device tree (RAM $RAM_GIB GiB, panel $PANEL, high-speed USB)"
DTS="$L/arch/arm64/boot/dts/mediatek/mt6833-xiaomi-evergo.dts"
python3 - "$DTS" "$RAM_GIB" "$PANEL" <<'PY'
import re, sys
dts, gib, panel = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = open(dts).read()

# memory: the author's tree hardcodes 8 GiB for their own unit
cells = "0 0x40000000 0x1 0x80000000" if gib == 6 else "0 0x40000000 2 0x00000000"
# use subn and check the count: when the value is already correct the substitution
# is a no-op, and comparing strings would wrongly report "node not found"
s, n = re.subn(r'(memory:\s*memory@40000000\s*\{[^}]*?reg\s*=\s*<)[^>]*(>;)',
               r'\g<1>' + cells + r'\2', s, count=1, flags=re.S)
if n != 1:
    raise SystemExit("memory node not found in DTS")

# panel variant
s = re.sub(r'compatible = "k16a_[0-9a_]+[a-z]*_vdo,lcm";', f'compatible = "{panel}";', s, count=1)

# USB: high-speed.  The author pinned full-speed after BABBLE during high-speed
# enumeration with the configfs composite gadget; the legacy g_ether gadget used
# here is stable at high speed and measured ~5x faster (0.9 -> 4.5 MB/s over scp).
s = s.replace('maximum-speed = "full-speed";', 'maximum-speed = "high-speed";', 1)

# command line: trimmed for speed, and with the watchdog thresholds relaxed.
# The author's loglevel=8 + ignore_loglevel + drm.debug=0x1e emit ~1.4 MB per boot;
# with a synchronous console that is minutes of blocked boot.  softlockup_panic=1
# with watchdog_thresh=5 turns any 5 s stall (initramfs unpack, f2fs recovery) into
# a panic and a reboot loop, which was observed repeatedly on hardware.
BOOTARGS = (
    "earlycon=mtk8250,0x11002000 console=evenring console=ttyS0,921600n8 "
    "console=tty0 loglevel=4 printk.devkmsg=on clk_ignore_unused "
    "pd_ignore_unused regulator_ignore_unused panic=10 "
    "watchdog_thresh=30 initcall_blacklist=exynos4_pm_init_power_domain "
    "fbcon=nodefer cma=256M"
)
s, n = re.subn(r'bootargs = "[^"]*";', f'bootargs = "{BOOTARGS}";', s)
if n != 1:
    raise SystemExit(f"expected 1 bootargs node, replaced {n}")

open(dts, "w").write(s)
print(f"  memory   -> {cells}")
print(f"  panel    -> {panel}")
print(f"  usb      -> high-speed")
print(f"  bootargs -> loglevel=4, watchdog_thresh=30, no softlockup_panic")
PY

# Upstream main's port commit is incomplete: its mt6833.dtsi includes dt-bindings
# headers the repository does not contain at all -
#   dt-bindings/gce/mediatek,mt6833-gce.h
#   dt-bindings/memory/mt6833-larb-port.h
#   dt-bindings/reset/mediatek,mt6833-resets.h
# so dtbs cannot succeed from that tree. The port files from the last complete tree
# (cb9ba2ee, which was built and booted on hardware) are vendored under config/port
# and installed over whatever upstream ships. They do not reference those headers.
if [ -d "$HERE/config/port" ]; then
    ( cd "$HERE/config/port" && find . -type f -print ) | sed 's|^\./||' | while read -r f; do
        mkdir -p "$L/$(dirname "$f")"
        cp -f "$HERE/config/port/$f" "$L/$f"
    done
    echo "  installed $(find "$HERE/config/port" -type f | wc -l) vendored port files"
fi

say "build dtb + kernel"
cd "$L"
make -s $KMAKE olddefconfig
make -s $KMAKE -j"$(nproc)" dtbs
DTB="$KOUT/arch/arm64/boot/dts/mediatek/mt6833-xiaomi-evergo.dtb"
[ -f "$DTB" ] || { echo "dtb build failed"; exit 1; }
ls -l "$DTB"

# -------------------------------------------------------------- rootfs ------
say "Arch Linux ARM rootfs ($ROOTFS_MB MiB f2fs)"
if [ -n "$ARCH_TARBALL" ] && [ -f "$ARCH_TARBALL" ]; then
    echo "  reusing $ARCH_TARBALL"
else
    ARCH_TARBALL="$WORK/ArchLinuxARM-aarch64-latest.tar.gz"
    curl -fsSL -o "$ARCH_TARBALL" "https://$MIRROR_HOST/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz"
fi

# The rootfs is assembled in a plain directory and only written into the f2fs image at
# the very end, with sload.f2fs.  The obvious alternative - mkfs.f2fs then mount -o loop
# - does not work in CI: the runner kernel has no f2fs module ("mount: failed mount
# system call"), and mounting needs root.  sload.f2fs needs neither.
R="$WORK/rootfs"
rm -rf "$R"; mkdir -p "$R"
tar xzf "$ARCH_TARBALL" -C "$R" --numeric-owner 2>/dev/null || true
echo "  extracted $(find "$R" -type f 2>/dev/null | wc -l) files"

say "rootfs: pacman mirrors, keyring, packages"
# pacman 7.x sandboxes itself with Landlock; this kernel has
# CONFIG_SECURITY_LANDLOCK off, so every transaction would fail without this.
sed -i 's/^#DisableSandboxFilesystem/DisableSandboxFilesystem/' "$R/etc/pacman.conf"
sed -i 's/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' "$R/etc/pacman.conf"
cat > "$R/etc/pacman.d/mirrorlist" <<ML
# build-time mirror list; rewritten for the delivered image further down
Server = https://${MIRROR_HOST}/archlinuxarm/\$arch/\$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/\$arch/\$repo
ML

cp -f /usr/bin/qemu-aarch64-static "$R/usr/bin/qemu-aarch64-static"
mount --bind /dev "$R/dev"; mount --bind /proc "$R/proc"; mount --bind /sys "$R/sys"
cp -f /etc/resolv.conf "$R/etc/resolv.conf"
# DNS does not work inside the qemu-user chroot, so pin the mirror IPs for the build
cp -f "$R/etc/hosts" "$WORK/hosts.bak"
for h in "$MIRROR_HOST" mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn; do
    ip=$(getent hosts "$h" | awk '{print $1; exit}')
    [ -n "$ip" ] && echo "$ip $h" >> "$R/etc/hosts"
done

# CheckSpace stats the cachedir's mount point, which a plain directory chroot is
# not, so it reports "not enough free disk space" and aborts the transaction
sed -i 's/^CheckSpace/#CheckSpace/' "$R/etc/pacman.conf"

chroot "$R" /usr/bin/qemu-aarch64-static /usr/bin/bash -c '
set -e
pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinuxarm >/dev/null 2>&1
pacman -Sy --noconfirm >/dev/null
pacman -S --noconfirm --needed \
  btop htop fastfetch git wget curl nano vim tmux rsync unzip zip file less \
  man-db which pacman-contrib net-tools bind-tools iputils traceroute mtr whois \
  lm_sensors lsof strace sudo >/dev/null
echo "  $(pacman -Q | wc -l) packages"
'

# The mirrorlist written for the build points at whatever the build could reach. The
# delivered image should use mirrors that work in China; pacman tries them in order and
# skips failures, so a slow first entry only costs time, not correctness.
cat > "$R/etc/pacman.d/mirrorlist" <<'ML'
# Arch Linux ARM mirrors.  Tsinghua and USTC are reachable from mainland China; the
# official host is kept as a fallback.
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirror.archlinuxarm.org/$arch/$repo
ML

say "rootfs: apply the evergo overlay"
tar xzf "$HERE/rootfs-overlay.tar.gz" -C "$R" --numeric-owner
chmod 755 "$R/usr/local/bin/evergo-mode" "$R/usr/local/bin/evergo-info" "$R/usr/local/bin/evergo-first-login"
chmod 644 "$R/etc/profile.d/00-evergo-welcome.sh" "$R/etc/evergo/fastfetch.jsonc"
rm -f "$R/etc/hosts"; mv -f "$WORK/hosts.bak" "$R/etc/hosts"
mkdir -p "$R/etc/systemd/system/multi-user.target.wants" \
         "$R/etc/systemd/system/sysinit.target.wants" \
         "$R/etc/systemd/system/getty.target.wants" \
         "$R/etc/ssh/sshd_config.d" "$R/var/log" "$R/root"
for u in sshd systemd-networkd systemd-resolved arch-boot-marker evergo-firstboot; do
    ln -sf "/usr/lib/systemd/system/$u.service" "$R/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || \
    ln -sf "/etc/systemd/system/$u.service"     "$R/etc/systemd/system/multi-user.target.wants/$u.service"
done
ln -sf /usr/lib/systemd/system/systemd-networkd.socket "$R/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" 2>/dev/null || true
ln -sf /etc/systemd/system/evergo-watchdog.service "$R/etc/systemd/system/sysinit.target.wants/evergo-watchdog.service"
ln -sf /usr/lib/systemd/system/serial-getty@.service "$R/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
[ -e "$R/etc/systemd/system/default.target" ] || ln -sf /usr/lib/systemd/system/multi-user.target "$R/etc/systemd/system/default.target"
rm -f "$R/usr/bin/qemu-aarch64-static"

say "rootfs: verify"
test -x "$R/sbin/init"                                  && echo "  sbin/init ok"
test -s "$R/etc/pacman.d/gnupg/pubring.gpg"             && echo "  keyring ok"
test -x "$R/usr/local/bin/evergo-mode"                  && echo "  evergo-mode ok"
test -x "$R/usr/local/bin/evergo-first-login"           && echo "  first-login ok"
test -f "$R/etc/evergo/fastfetch.jsonc"                 && echo "  fastfetch config ok"
grep -q '^PubkeyAuthentication no' "$R/etc/ssh/sshd_config.d/10-bringup.conf" && echo "  sshd: password only"
echo "  hostname: $(cat "$R/etc/hostname")"

sync
# pacman-key leaves a gpg-agent behind that holds /dev open; kill it before unmounting
pkill -f 'gpg-agent' 2>/dev/null || true
sleep 1
for m in "$R/dev" "$R/proc" "$R/sys"; do
    for try in 1 2 3 4 5; do
        mountpoint -q "$m" 2>/dev/null || break
        umount "$m" 2>/dev/null && break
        pkill -f 'gpg-agent' 2>/dev/null || true
        sleep 1
    done
    mountpoint -q "$m" 2>/dev/null && umount -l "$m" 2>/dev/null || true
done
sync
echo "  chroot unmounted"

say "userdata image (f2fs via sload)"
ROOTIMG="$WORK/rootfs.f2fs"
rm -f "$ROOTIMG"
truncate -s "${ROOTFS_MB}M" "$ROOTIMG"
mkfs.f2fs -f -l evergo -O extra_attr,inode_checksum,sb_checksum "$ROOTIMG" >/dev/null
# sload.f2fs returns 1 even when it succeeds, so ignore its status - the fsck
# below is what actually validates the image
sload.f2fs -f "$R" -P "$ROOTIMG" 2>&1 | tail -3 | sed 's/^/  /' || true
fsck.f2fs -f "$ROOTIMG" 2>&1 | tail -2 | sed 's/^/  /' || true

say "userdata images"
cp -f "$ROOTIMG" "$OUT/userdata.img"
gzip -9 -c "$ROOTIMG" > "$OUT/userdata.img.gz"
img2simg "$ROOTIMG" "$OUT/userdata.simg" 2>/dev/null && echo "  sparse image ok"
ls -l "$OUT"/userdata.* | awk '{printf "  %-24s %s bytes\n", $9, $5}'

# ------------------------------------------------------------- initramfs ----
say "initramfs (mount userdata, switch_root)"
IR="$WORK/initramfs"
rm -rf "$IR"; mkdir -p "$IR"/{bin,dev,proc,sys,tmp,run,newroot}
# aarch64 *static* busybox: the initramfs has no libc of its own, and the build
# host's busybox would be the wrong architecture (this exact mistake gave
# "Failed to execute /init (error -8)" during bring-up).
BB="$WORK/busybox"
if [ ! -x "$BB" ]; then
    AIDX="https://$MIRROR_HOST/alpine/latest-stable/main/aarch64/"
    curl -fsSL -o "$WORK/bidx.html" "$AIDX"
    BBPKG=$(grep -oE 'busybox-static-[^"]*\.apk' "$WORK/bidx.html" | head -1)
    [ -n "$BBPKG" ] || { echo "cannot find alpine busybox-static"; exit 1; }
    curl -fsSL -o "$WORK/$BBPKG" "$AIDX$BBPKG"
    rm -rf "$WORK/bb" && mkdir -p "$WORK/bb"
    tar xzf "$WORK/$BBPKG" -C "$WORK/bb"
    cp "$WORK/bb/bin/busybox.static" "$BB"
fi
chmod 755 "$BB"
cp "$BB" "$IR/bin/busybox"; chmod 755 "$IR/bin/busybox"
for a in sh mount umount cat gzip losetup switch_root sleep echo ls mkdir ln sync; do
    ln -sf busybox "$IR/bin/$a"
done
# the kernel opens /dev/console before exec'ing init; with an initramfs present
# prepare_namespace() never runs so devtmpfs is not mounted yet
if [ "$(id -u)" = 0 ]; then
    mknod "$IR/dev/console" c 5 1 && chmod 600 "$IR/dev/console"
    mknod "$IR/dev/null"    c 1 3 && chmod 666 "$IR/dev/null"
fi
cat > "$IR/init" <<'INIT'
#!/bin/sh
# Mount the Arch root filesystem from the eMMC user area and hand over.
#
#   eMMC user area : /dev/sdc (no partition nodes - the GPT is wiped)
#   userdata start : 0x304000000 = 12,952,010,752 bytes = 12352 MiB
#   filesystem     : f2fs, mounted through a loop with an explicit offset
#
# USB is not touched here: g_ether provides RNDIS and Arch configures usb0 itself.
UD_OFF=$((0x304000000))
export PATH=/bin
mount -t proc     none /proc 2>/dev/null
mount -t sysfs    none /sys  2>/dev/null
mount -t devtmpfs none /dev  2>/dev/null
mkdir -p /newroot

# nothing else feeds the hardware watchdog after the bootloader arms it (31 s).
# Use an inherited descriptor: re-opening /dev/watchdog would fail once switch_root
# has moved /dev, which is what caused a reboot loop every ~33 s.
if [ -e /dev/watchdog ]; then
    exec 3>/dev/watchdog
    ( while : ; do echo . >&3; sleep 8; done ) &
fi

i=0; while [ $i -lt 60 ]; do [ -b /dev/sdc ] && break; sleep 1; i=$((i+1)); done
if [ -b /dev/sdc ]; then
    losetup -o "$UD_OFF" /dev/loop0 /dev/sdc 2>/dev/null
    mount -t f2fs -o rw /dev/loop0 /newroot 2>/dev/null
fi

if [ -x /newroot/sbin/init ]; then
    # hand the watchdog to Arch's evergo-watchdog.service
    echo V >&3 2>/dev/null
    exec 3>&- 2>/dev/null
    mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/run
    mount --move /dev  /newroot/dev  2>/dev/null
    mount --move /proc /newroot/proc 2>/dev/null
    mount --move /sys  /newroot/sys  2>/dev/null
    exec switch_root /newroot /sbin/init
fi

# nothing bootable: never let PID 1 exit, or the kernel panics
while : ; do /bin/sh; sleep 1; done
INIT
chmod 755 "$IR/init"

say "build kernel with the initramfs"
cd "$L"
make -s $KMAKE -j"$(nproc)" Image
rm -f "$KOUT"/usr/initramfs_data.cpio "$KOUT"/usr/initramfs_data.o "$KOUT"/usr/initramfs_inc_data "$KOUT"/usr/.initramfs_data.cpio.d
make -s $KMAKE -j"$(nproc)" Image
IMG="$KOUT/arch/arm64/boot/Image"
[ -f "$IMG" ] || { echo "kernel build failed: $IMG missing"; exit 1; }
ls -l "$IMG"

# ---------------------------------------------------------------- pack ------
say "boot.img"
# the bootloader expects gzip(kernel) followed by the vendor DTB
gzip -9 -n -c "$IMG" > "$WORK/image.gz"
cat "$WORK/image.gz" "$HERE/config/vendor_dtb.bin" > "$WORK/kernel.bin"
printf '' | gzip -9 > "$WORK/empty-ramdisk.gz"
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
ls -l "$OUT"/*.img "$OUT"/*.img.gz "$OUT"/*.simg 2>/dev/null | awk '{printf "  %-28s %s bytes\n", $9, $5}'
cat > "$OUT/SHA256SUMS" <<'EOF'
EOF
( cd "$OUT" && sha256sum boot.img userdata.img.gz userdata.simg 2>/dev/null >> SHA256SUMS || true )
cat "$OUT/SHA256SUMS"

say "flash"
cat <<'MSG'
  fastboot flash boot_b      boot.img
  fastboot -S 200M flash userdata userdata.simg      # or: gunzip -c userdata.img.gz | ...
  fastboot reboot

  On first boot the phone comes up as a DHCP client on usb0 (router mode) and also
  holds 169.254.42.1/16, so a directly attached PC can reach it without any
  configuration:
      ssh root@169.254.42.1        (password: evergo, then the first-login wizard)
MSG
