#!/bin/bash
# Arch Linux ARM aarch64 root filesystem for evergo.
#
# Usage: distro-arch.sh <rootfs-dir>
#
# Moved out of build.sh so the multi-distro dispatch stays readable.  Everything Arch
# specific lives here: the tarball, pacman keyring, Landlock workaround, mirrors.
set -euo pipefail

R="${1:?usage: distro-arch.sh <rootfs-dir>}"
MIRROR_HOST="${MIRROR_HOST:-mirrors.ocf.berkeley.edu}"
ARCH_TARBALL="${ARCH_TARBALL:-}"
WORK="${WORK:-/tmp/evergo-work}"

log() { printf '  %s\n' "$*"; }

rm -rf "$R"
mkdir -p "$R" "$WORK"

# ---------------------------------------------------------------- tarball ----
if [ -n "$ARCH_TARBALL" ] && [ -f "$ARCH_TARBALL" ]; then
    log "reusing $ARCH_TARBALL"
else
    ARCH_TARBALL="$WORK/ArchLinuxARM-aarch64-latest.tar.gz"
    if [ ! -s "$ARCH_TARBALL" ]; then
        log "downloading the Arch Linux ARM tarball"
        curl -fsSL -o "$ARCH_TARBALL" \
            "https://$MIRROR_HOST/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz" \
        || curl -fsSL -o "$ARCH_TARBALL" \
            "https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz"
    fi
fi
log "extracting…"
tar xzf "$ARCH_TARBALL" -C "$R" --numeric-owner 2>/dev/null || true
log "extracted $(find "$R" -type f 2>/dev/null | wc -l) files"

# ------------------------------------------------------------ pacman setup ---
# pacman 7.x sandboxes itself with Landlock; this kernel has CONFIG_SECURITY_LANDLOCK
# off, so every transaction fails without this.
sed -i 's/^#DisableSandboxFilesystem/DisableSandboxFilesystem/' "$R/etc/pacman.conf"
sed -i 's/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' "$R/etc/pacman.conf"
# CheckSpace stats the cachedir's mount point; a plain directory chroot is not one, so
# it reports "not enough free disk space" and aborts.
sed -i 's/^CheckSpace/#CheckSpace/' "$R/etc/pacman.conf"

cat > "$R/etc/pacman.d/mirrorlist" <<ML
# build-time mirror list
Server = https://${MIRROR_HOST}/archlinuxarm/\$arch/\$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/\$arch/\$repo
ML

# ---------------------------------------------------------------- chroot -----
cp -f /usr/bin/qemu-aarch64-static "$R/usr/bin/qemu-aarch64-static"
mount --bind /dev  "$R/dev"
mount --bind /proc "$R/proc"
mount --bind /sys  "$R/sys"
cp -f /etc/resolv.conf "$R/etc/resolv.conf"
cp -f "$R/etc/hosts" "$WORK/hosts.bak"

# DNS does not resolve inside a qemu-user chroot, so pin the mirror addresses.  getent
# may return an IPv6 record first, and an IPv6 pin makes curl fail instantly because the
# chroot has no IPv6 route, hence ahostsv4.
for h in "$MIRROR_HOST" mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn; do
    ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$ip" ] && ip=$(getent hosts "$h" 2>/dev/null | awk '$1 ~ /^[0-9]+\./ {print $1; exit}')
    if [ -n "$ip" ]; then
        echo "$ip $h" >> "$R/etc/hosts"
        log "pinned $h -> $ip"
    fi
done

chroot "$R" /usr/bin/qemu-aarch64-static /usr/bin/bash -c '
set -e
pacman-key --init >/dev/null 2>&1
pacman-key --populate archlinuxarm >/dev/null 2>&1
pacman -Sy --noconfirm >/dev/null
pacman -S --noconfirm --needed \
  btop htop fastfetch git wget curl nano vim tmux rsync unzip zip file less \
  man-db which pacman-contrib net-tools bind-tools iputils traceroute mtr whois \
  lm_sensors lsof strace sudo >/dev/null
# The tarball ships a locked root password and the image only allows password logins,
# so a freshly flashed phone would be unreachable.
echo "root:evergo" | chpasswd
passwd -S root
# the package cache is dead weight in a shipped image and decides whether the sparse
# image fits the 2 GB per-asset release limit
pacman -Scc --noconfirm >/dev/null 2>&1 || true
rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/* /tmp/* 2>/dev/null || true
echo "  $(pacman -Q | wc -l) packages"
'

# The delivered image should use mirrors that work in China.
cat > "$R/etc/pacman.d/mirrorlist" <<'ML'
# Arch Linux ARM mirrors.  Tsinghua and USTC are reachable from mainland China; the
# official host is kept as a fallback.
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirror.archlinuxarm.org/$arch/$repo
ML

# ---------------------------------------------------------------- trim ------
# GitHub release assets are capped at 2 GiB and the sparse image of a stock Arch rootfs
# is 2.2 GB.  These files are dead weight on the phone (the kernel is fully built in, so
# the packaged modules are never loaded) and dropping them brings the spare image under
# the limit:
#   usr/lib/modules    186M
#   usr/share/man       51M
#   usr/share/doc       17M
#   usr/share/i18n      17M
log "trimming"
rm -rf "$R"/usr/lib/modules/* \
       "$R"/usr/share/man/* \
       "$R"/usr/share/doc/* \
       "$R"/usr/share/i18n/* \
       "$R"/usr/share/gtk-doc \
       "$R"/var/cache/* "$R"/var/lib/pacman/sync/* \\
       "$R"/tmp/* 2>/dev/null || true
mkdir -p "$R/usr/lib/modules" "$R/var/cache" "$R/var/lib/pacman/sync" "$R/tmp"
chmod 1777 "$R/tmp"
log "trimmed to $(du -sh "$R" | cut -f1)"

# ---------------------------------------------------------------- clean -----
rm -f "$R/usr/bin/qemu-aarch64-static"
rm -f "$R/etc/hosts"; mv -f "$WORK/hosts.bak" "$R/etc/hosts"
pkill -f 'gpg-agent' 2>/dev/null || true
sleep 1
for m in "$R/dev" "$R/proc" "$R/sys"; do
    for _ in 1 2 3 4 5; do
        mountpoint -q "$m" 2>/dev/null || break
        umount "$m" 2>/dev/null && break
        pkill -f 'gpg-agent' 2>/dev/null || true
        sleep 1
    done
    mountpoint -q "$m" 2>/dev/null && umount -l "$m" 2>/dev/null || true
done
sync

log "done: $(du -sh "$R" | cut -f1)"
