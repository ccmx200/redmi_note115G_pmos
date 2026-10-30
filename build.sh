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
# The upstream tree has been rewritten and main no longer carries the port files;
# this is the commit that was cross-built and booted on hardware.  Fetching it by
# SHA works even though the branch it lived on is gone.
KERNEL_COMMIT="${KERNEL_COMMIT:-cb9ba2ee0f929ff8985f4821a0ee32fa1c06c5fd}"
KERNEL_SRC="${KERNEL_SRC:-}"             # reuse an existing checkout if set
RAM_GIB="${RAM_GIB:-6}"                  # 4/6/8 GiB units exist
PANEL="${PANEL:-k16a_36_02_0a_vdo,lcm}"  # Tianma; CSOT is k16a_42_02_0b_vdo,lcm
ROOTFS_MB="${ROOTFS_MB:-6144}"           # 6 GiB f2fs
# Which distribution to put in the image.  Each one is built by its own script,
# scripts/distro-$DISTRO.sh, which populates a plain directory; the image creation,
# initramfs and boot.img packing below are shared by all of them.
DISTRO="${DISTRO:-arch}"                         # arch | debian | ubuntu | fedora
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
        # fetch the pinned commit first: that is the tree that was booted on hardware.
        # Upstream's branches have been rewritten, so a plain clone of main is not
        # equivalent.
        mkdir -p "$L"
        git -C "$L" init -q .
        git -C "$L" remote add origin "$KERNEL_REPO"
        if git -C "$L" fetch --depth 1 origin "$KERNEL_COMMIT" 2>/dev/null; then
            git -C "$L" checkout -q FETCH_HEAD
            echo "  using pinned commit $KERNEL_COMMIT"
        else
            echo "  !! could not fetch $KERNEL_COMMIT, falling back to a branch"
            rm -rf "$L"
            for b in "$KERNEL_BRANCH" main master; do
                echo "  cloning branch $b"
                if git clone --depth 1 --single-branch --branch "$b" "$KERNEL_REPO" "$L" 2>/dev/null; then
                    echo "  using $b"
                    break
                fi
                rm -rf "$L"
            done
        fi
        [ -d "$L/.git" ] || { echo "  !! could not get the kernel source"; exit 1; }
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
    # fbcon=nodefer is required: without it the kernel does not reach userspace on
    # this panel (the RNDIS gadget never enumerates).  It also means the Tux logo is
    # drawn before the DSI panel is up and is lost - a cosmetic trade we accept.
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
say "rootfs: $DISTRO"

# The rootfs is assembled as a plain directory by a per-distro script; the image is only
# created at the very end with mke2fs -d, which needs neither mounting nor root.
R="$WORK/rootfs"
rm -rf "$R"; mkdir -p "$R"

export WORK
export MIRROR_HOST ARCH_TARBALL
if [ ! -x "$HERE/scripts/distro-$DISTRO.sh" ]; then
    echo "  !! no scripts/distro-$DISTRO.sh (pick arch, debian, ubuntu or fedora)"
    exit 1
fi
bash "$HERE/scripts/distro-$DISTRO.sh" "$R" || { echo "  !! rootfs build failed"; exit 1; }
echo "  $(du -sh "$R" | cut -f1) in $R"

say "rootfs: upgrade to the latest packages"
# Each distro script already upgrades its base system inside its own chroot (see
# scripts/distro-common.sh).  Nothing to do here.
echo "  handled by scripts/distro-$DISTRO.sh"

say "rootfs: apply the evergo overlay"
tar xzf "$HERE/rootfs-overlay.tar.gz" -C "$R" --numeric-owner
chmod 755 "$R/usr/local/bin/evergo-mode" "$R/usr/local/bin/evergo-info" "$R/usr/local/bin/evergo-first-login" 2>/dev/null || true
chmod 644 "$R/etc/profile.d/00-evergo-welcome.sh" "$R/etc/evergo/fastfetch.jsonc" 2>/dev/null || true
rm -f "$R/etc/hosts" 2>/dev/null || true
mkdir -p "$R/etc/systemd/system/multi-user.target.wants" \
         "$R/etc/systemd/system/sysinit.target.wants" \
         "$R/etc/systemd/system/getty.target.wants" \
         "$R/etc/ssh/sshd_config.d" "$R/var/log" "$R/root"

# distro-specific bits the overlay cannot express
case "$DISTRO" in
arch)
    # Arch tarball ships root with a locked password; handled in distro-arch.sh
    ;;
debian|ubuntu)
    # the Debian family has no /etc/pacman.conf; drop the Arch leftovers from the overlay
    rm -f "$R/etc/pacman.conf" "$R/etc/pacman.d/mirrorlist" 2>/dev/null || true
    rmdir "$R/etc/pacman.d" 2>/dev/null || true
    # sudo group is "sudo" there
    echo '%sudo ALL=(ALL:ALL) ALL' > "$R/etc/sudoers.d/10-sudo" 2>/dev/null || true
    chmod 440 "$R/etc/sudoers.d/10-sudo" 2>/dev/null || true
    ;;
fedora)
    rm -f "$R/etc/pacman.conf" "$R/etc/pacman.d/mirrorlist" 2>/dev/null || true
    rmdir "$R/etc/pacman.d" 2>/dev/null || true
    echo '%wheel ALL=(ALL:ALL) ALL' > "$R/etc/sudoers.d/10-wheel" 2>/dev/null || true
    chmod 440 "$R/etc/sudoers.d/10-wheel" 2>/dev/null || true
    ;;
esac

# enable the services we ship
for u in sshd systemd-networkd systemd-resolved evergo-firstboot; do
    if [ -e "$R/usr/lib/systemd/system/$u.service" ] || [ -e "$R/lib/systemd/system/$u.service" ]; then
        ln -sf "/usr/lib/systemd/system/$u.service" \
            "$R/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || \
        ln -sf "/lib/systemd/system/$u.service" \
            "$R/etc/systemd/system/multi-user.target.wants/$u.service" 2>/dev/null || true
    fi
done
ln -sf /usr/lib/systemd/system/systemd-networkd.socket "$R/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" 2>/dev/null || true
ln -sf /etc/systemd/system/evergo-watchdog.service "$R/etc/systemd/system/sysinit.target.wants/evergo-watchdog.service" 2>/dev/null || true
[ -e "$R/etc/systemd/system/default.target" ] || ln -sf /usr/lib/systemd/system/multi-user.target "$R/etc/systemd/system/default.target" 2>/dev/null || true

# Some bootstraps (mmdebstrap in particular) leave /etc/hostname empty and only count on
# the overlay to fill it; do it explicitly so the image is never hostnameless.
printf 'evergo\n' > "$R/etc/hostname"
if [ -f "$R/etc/hosts" ]; then
    grep -q '^127\.0\.1\.1' "$R/etc/hosts" || echo '127.0.1.1 evergo' >> "$R/etc/hosts"
fi

say "rootfs: distro post-processing"

# Services that try to reach the internet (or the cloud) during the first boot and can
# hold up the boot for minutes on a phone whose only uplink is an RNDIS cable.  Masking
# them is cheap and they are useless here.
for u in ubuntu-advantage.service ua-reboot-cmds.service ua-timer.timer \
         apport.service whoopsie.service snapd.service snapd.socket \
         unattended-upgrades.service apt-daily.service apt-daily-upgrade.service \
         NetworkManager.service NetworkManager-wait-online.service \
         cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service \
         systemd-networkd-wait-online.service; do
    if [ -e "$R/usr/lib/systemd/system/$u" ] || [ -e "$R/lib/systemd/system/$u" ] ||
       [ -e "$R/etc/systemd/system/$u" ]; then
        mkdir -p "$R/etc/systemd/system"
        ln -sf /dev/null "$R/etc/systemd/system/$u"
    fi
done

# systemd-networkd owns usb0.  Fedora enables NetworkManager by default, and two network
# managers fighting over the interface means no address at all.
if [ -e "$R/usr/lib/systemd/system/systemd-networkd.service" ] ||
   [ -e "$R/lib/systemd/system/systemd-networkd.service" ]; then
    mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/systemd-networkd.service \
        "$R/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || \
    ln -sf /lib/systemd/system/systemd-networkd.service \
        "$R/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true
fi

# The watchdog has to be running before anything else can hang.
if [ -e "$R/etc/systemd/system/evergo-watchdog.service" ]; then
    mkdir -p "$R/etc/systemd/system/sysinit.target.wants"
    ln -sf /etc/systemd/system/evergo-watchdog.service \
        "$R/etc/systemd/system/sysinit.target.wants/evergo-watchdog.service" 2>/dev/null || true
fi

say "rootfs: verify"
test -x "$R/sbin/init"                        && echo "  sbin/init ok"
test -x "$R/usr/lib/systemd/systemd"          && echo "  systemd ok"
test -x "$R/usr/sbin/sshd"                    && echo "  sshd ok"
test -x "$R/usr/sbin/resize2fs"               && echo "  resize2fs ok"
test -x "$R/usr/sbin/e2fsck"                  && echo "  e2fsck ok"
test -x "$R/usr/local/bin/evergo-mode"        && echo "  evergo-mode ok"
test -x "$R/usr/local/bin/evergo-first-login" && echo "  first-login ok"
grep -q '^PubkeyAuthentication no' "$R/etc/ssh/sshd_config.d/10-bringup.conf" && echo "  sshd: password only"
echo "  hostname: $(cat "$R/etc/hostname" 2>/dev/null)"

sync

say "userdata image (ext4)"
# ext4 rather than f2fs: the filesystem has to grow from the shipped size to the whole
# eMMC user area on first boot, and f2fs's offline resize (resize.f2fs) never returns on
# this handset.  mke2fs -d populates the image from the directory in one step.
ROOTIMG="$WORK/rootfs.ext4"
rm -f "$ROOTIMG"
truncate -s "${ROOTFS_MB}M" "$ROOTIMG"
mke2fs -t ext4 -F -L evergo -m 1 -q -d "$R" "$ROOTIMG"
echo "  inodes: $(dumpe2fs -h "$ROOTIMG" 2>/dev/null | awk -F: '/Inode count/{gsub(/ /,"",$2); print $2}')"
echo "  blocks: $(dumpe2fs -h "$ROOTIMG" 2>/dev/null | awk -F: '/Block count/{gsub(/ /,"",$2); print $2}')"
e2fsck -fp "$ROOTIMG" >/dev/null 2>&1 || true

say "userdata images"
cp -f "$ROOTIMG" "$OUT/userdata.img"
gzip -9 -c "$ROOTIMG" > "$OUT/userdata.img.gz"
img2simg "$ROOTIMG" "$OUT/userdata.simg" 2>/dev/null && echo "  sparse image ok"
ls -l "$OUT"/userdata.* | awk '{printf "  %-24s %s bytes\n", $9, $5}'

# ------------------------------------------------------------- initramfs ----
say "initramfs (mount userdata, switch_root)"
IR="$WORK/initramfs"
rm -rf "$IR"; mkdir -p "$IR"/{bin,dev,proc,sys,tmp,run,newroot,usr/lib}
# Arch has /lib as a symlink to usr/lib and the ELF interpreter asks for
# /lib/ld-linux-aarch64.so.1, so mirror that layout here
ln -sfn usr/lib "$IR/lib"
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
# the init needs more than the bare minimum: dd and blockdev write the debug log and
# report sizes, df/head/tail/grep print them, touch writes the grown marker
# awk is not optional: delay() reads /proc/uptime with it.  When it was missing the
# busy-wait never ended, the watchdog feed loop stopped pinging and the phone reset every
# 31 seconds.  usleep is the preferred delay and ps/kill are needed to stop that loop.
for a in sh mount umount cat gzip losetup switch_root sleep usleep echo ls mkdir ln sync \
         dd blockdev df head tail grep sed touch cut awk ps kill killall \
         rm rmdir find ifconfig; do
    ln -sf busybox "$IR/bin/$a"
done
# the kernel opens /dev/console before exec'ing init; with an initramfs present
# prepare_namespace() never runs so devtmpfs is not mounted yet
if [ "$(id -u)" = 0 ]; then
    mknod "$IR/dev/console" c 5 1 && chmod 600 "$IR/dev/console"
    mknod "$IR/dev/null"    c 1 3 && chmod 666 "$IR/dev/null"
fi
# The first boot grows the filesystem to the whole eMMC user area, which needs e2fsck
# and resize2fs inside the initramfs together with their library closure.
for tool in /usr/sbin/e2fsck /usr/sbin/resize2fs; do
    if [ -x "$R$tool" ]; then
        python3 "$HERE/scripts/collect-libs.py" "$R" "$tool" "$IR" | sed 's/^/  /'
    else
        echo "  !! $tool missing from the rootfs, first-boot growth disabled"
    fi
done

# CDC-NCM gadget helper: the kernel no longer builds the legacy g_ether gadget, so the
# USB network interface is created here through configfs.  NCM (packet aggregation) is
# tried first, RNDIS second.
cp -f "$HERE/config/gadget-setup.sh" "$IR/gadget-setup.sh"
chmod 644 "$IR/gadget-setup.sh"

cat > "$IR/init" <<'INIT'
#!/bin/sh
# Mount the Arch root filesystem from the eMMC user area, grow it to the whole user area
# on the first boot, and hand over.
#
#   eMMC user area : /dev/sdc (no partition nodes - the GPT is wiped)
#   userdata start : 0x304000000 = 12,952,010,752 bytes = 12352 MiB
#   filesystem     : ext4, via a loop with an explicit offset; the loop spans the rest of
#                    the disk (~107 GiB) and the fs is grown to it once, with resize2fs.
#
# f2fs was tried first and abandoned: resize.f2fs never returns on this handset (three
# attempts, with -F, stdin on /dev/null and discard disabled), and ext4's resize2fs is
# what postmarketOS and the raphael-uboot project use for the same job.
#
# seconds, so a hang can still be read back after rebooting into a working system.
UD_OFF=$((0x304000000))
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Nothing below assumes sleep exists.  An earlier image was missing the applet and the
# console filled with "sleep: not found", so this falls back to usleep and then to
# polling /proc/uptime.
_now() { awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0; }

# Probe the tools by running them, not with `command -v`: a dangling symlink passes
# command -v and then fails at exec time, which is exactly how the console ended up
# full of "sleep: not found".
HAVE_SLEEP=0
HAVE_USLEEP=0
if sleep 0.05 >/dev/null 2>&1; then HAVE_SLEEP=1; fi
if usleep 1000 >/dev/null 2>&1; then HAVE_USLEEP=1; fi

delay() {
    _n=${1:-1}
    if [ "$HAVE_SLEEP" = 1 ]; then
        sleep "$_n" 2>/dev/null && return 0
    fi
    if [ "$HAVE_USLEEP" = 1 ]; then
        usleep $((_n * 1000000)) 2>/dev/null && return 0
    fi
    # last resort: poll the kernel clock.  Bounded so a broken clock cannot hang boot.
    _e=$(( $(_now) + _n ))
    _guard=0
    while [ "$(_now)" -lt "$_e" ]; do
        _guard=$((_guard + 1))
        [ "$_guard" -gt 200000 ] && break
    done
}

# Log to a file only.  Printing to the console scrolls the kernel's Tux logo off the
# screen, which is why no penguin was visible even though CONFIG_LOGO is enabled.
log() {
    echo "[init] $*" >> /tmp/init.log 2>/dev/null
}

mount -t proc     none /proc 2>/dev/null
mount -t sysfs    none /sys  2>/dev/null
mount -t devtmpfs none /dev  2>/dev/null
mkdir -p /newroot /tmp

# ------------------------------------------------------------------ usb gadget --
# There is no built-in g_ether any more (its single UDC has to stay free for configfs),
# so the network interface is created here.  usb0 comes up before the disk work, which
# means the phone is reachable even while the filesystem is being grown.
. /gadget-setup.sh
setup_usb_gadget
GADGET_RC=$?
ifconfig usb0 169.254.42.1 netmask 255.255.0.0 up 2>/dev/null
log "usb0: $(ifconfig usb0 2>/dev/null | awk '/inet addr/{print $2}' | cut -d: -f2) (gadget rc=$GADGET_RC)"
: > /tmp/grow.log
log "init start"

# LK arms the hardware watchdog for 31 s and nothing else feeds it yet.  Keep the fd
# open across switch_root: re-opening /dev/watchdog afterwards fails, which is what
# caused a reboot loop every ~33 s.
WDT_PID=""
if [ -e /dev/watchdog ]; then
    exec 3>/dev/watchdog
    ( while : ; do echo . >&3; delay 8; done ) &
    WDT_PID=$!
    log "watchdog fed (pid $WDT_PID)"
fi

# mirror the log continuously, so a hang still leaves a readable trace

i=0; while [ $i -lt 60 ]; do [ -b /dev/sdc ] && break; delay 1; i=$((i+1)); done
if [ -b /dev/sdc ]; then
    log "sdc=$(blockdev --getsize64 /dev/sdc 2>/dev/null)"
    losetup -o "$UD_OFF" /dev/loop0 /dev/sdc 2>/dev/null
    log "loop0=$(blockdev --getsize64 /dev/loop0 2>/dev/null)"

    mount -t ext4 -o rw /dev/loop0 /newroot 2>/dev/null
    MRC=$?
    log "mount rc=$MRC"
    if [ "$MRC" = "0" ] && [ ! -e /newroot/.evergo-grown ]; then
        log "growing to $(blockdev --getsize64 /dev/loop0 2>/dev/null) bytes"
        umount /newroot 2>/dev/null
        GREW=0
        if [ -x /usr/sbin/resize2fs ]; then
            # -p is preen mode: never prompts, which matters because there is no tty
            if [ -x /usr/sbin/e2fsck ]; then
                /usr/sbin/e2fsck -fp /dev/loop0 >> /tmp/grow.log 2>&1
                log "e2fsck rc=$?"
            fi
            if /usr/sbin/resize2fs /dev/loop0 >> /tmp/grow.log 2>&1; then
                log "resize2fs ok"
                GREW=1
            else
                log "resize2fs FAILED rc=$?"
                cat /tmp/grow.log > /dev/console 2>/dev/null
            fi
        else
            log "resize2fs missing"
        fi
        mount -t ext4 -o rw /dev/loop0 /newroot 2>/dev/null
        log "remount rc=$?"
        if [ "$GREW" = 1 ]; then
            touch /newroot/.evergo-grown 2>/dev/null
            log "marker written rc=$?"
        else
            log "grow did not complete - marker NOT written, will retry next boot"
        fi
        df -h /newroot 2>/dev/null | tail -1 >> /tmp/grow.log
    elif [ -e /newroot/.evergo-grown ]; then
        log "already grown"
    fi
else
    log "no /dev/sdc"
fi
if [ -x /newroot/sbin/init ]; then
    log "switch_root"
    # Stop the feed loop and close the fd before handing over.  Otherwise it survives
    # switch_root holding /dev/watchdog open, the systemd unit gets EBUSY, nobody feeds
    # the watchdog and the phone resets every 31 s.  nowayout=0, so closing the last
    # reference disarms it cleanly and the unit can take over.
    echo V >&3 2>/dev/null
    if [ -n "$WDT_PID" ]; then kill "$WDT_PID" 2>/dev/null; wait "$WDT_PID" 2>/dev/null; fi
    exec 3>&- 2>/dev/null
    log "watchdog handed over to systemd"
    mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/run
    mount --move /dev  /newroot/dev  2>/dev/null
    mount --move /proc /newroot/proc 2>/dev/null
    mount --move /sys  /newroot/sys  2>/dev/null
    exec switch_root /newroot /sbin/init
fi

log "no init, dropping to a shell"
while : ; do /bin/sh; delay 1; done
INIT
chmod 755 "$IR/init"

# Fedora's dynamic loader only searches /usr/lib64 for these, and collect-libs.py
# flattens everything into /usr/lib.  Without the mirror e2fsck exits with
# "libext2fs.so.2: cannot open shared object file" and the grow silently does nothing.
if [ -d "$IR/usr/lib" ]; then
    mkdir -p "$IR/usr/lib64"
    cp -a "$IR/usr/lib/." "$IR/usr/lib64/" 2>/dev/null || true
    ln -sfn usr/lib64 "$IR/lib64" 2>/dev/null || true
fi
echo "  initramfs libs: $(ls "$IR/usr/lib" 2>/dev/null | wc -l) in usr/lib, $(ls "$IR/usr/lib64" 2>/dev/null | wc -l) in usr/lib64"

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

# The AVB footer stays.  It looks like dead weight on an unlocked bootloader, but this
# LK refuses to jump to the kernel without it and simply sits on the Redmi logo.
python3 "$HERE/scripts/avb.py" --image "$WORK/boot-nofooter.img" \
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
