#!/bin/bash
# Arch Linux ARM aarch64 root filesystem for evergo.
#
# Usage: distro-arch.sh <rootfs-dir>
#
# Moved out of build.sh so the multi-distro dispatch stays readable.  Everything Arch
# specific lives here: the tarball, pacman keyring, Landlock workaround, mirrors.
#
# The tarball download is authenticated before it is extracted (see
# scripts/verify-download.sh): Arch Linux ARM publishes an MD5 and, more
# importantly, a detached GPG signature for the rolling tarball.  The signature
# is verified against the Arch Linux ARM Build System key committed in
# config/keys/archlinuxarm.asc, so a mirror cannot serve a different tarball
# unnoticed.
set -euo pipefail

R="${1:?usage: distro-arch.sh <rootfs-dir>}"
MIRROR_HOST="${MIRROR_HOST:-mirrors.ocf.berkeley.edu}"
ARCH_TARBALL="${ARCH_TARBALL:-}"
WORK="${WORK:-/tmp/evergo-work}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/../config/keys/archlinuxarm.asc"

log() { printf '  %s\n' "$*"; }

# shellcheck source=verify-download.sh
. "$HERE/verify-download.sh"

rm -rf "$R"
mkdir -p "$R" "$WORK"

# ---------------------------------------------------------------- tarball ----
TARBALL_NAME="ArchLinuxARM-aarch64-latest.tar.gz"
BASE_PRIMARY="https://$MIRROR_HOST/archlinuxarm/os"
BASE_FALLBACK="https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os"
# Where the tarball (and its .md5/.sig) came from; used to verify a cached copy.
TARBALL_BASE="$BASE_PRIMARY"

if [ -n "$ARCH_TARBALL" ] && [ -f "$ARCH_TARBALL" ]; then
    log "reusing $ARCH_TARBALL"
else
    ARCH_TARBALL="$WORK/$TARBALL_NAME"
    if [ ! -s "$ARCH_TARBALL" ]; then
        log "downloading the Arch Linux ARM tarball"
        ok=0
        for base in "$BASE_PRIMARY" "$BASE_FALLBACK"; do
            log "  $base/$TARBALL_NAME"
            if curl -fsSL --max-time 1800 -o "$ARCH_TARBALL" "$base/$TARBALL_NAME"; then
                ok=1; TARBALL_BASE="$base"; break
            fi
            rm -f "$ARCH_TARBALL"
        done
        [ "$ok" = 1 ] || { echo "  !! cannot download the Arch Linux ARM tarball"; exit 1; }
    else
        log "reusing cached $TARBALL_NAME"
    fi
fi

# The rolling tarball has no SHA256 next to it; Arch ARM publishes an MD5 and a
# detached signature.  Verify the MD5 first (cheap truncation/corruption check),
# then the signature (authenticity).  When a mirror lacks the .sig the build
# prints a warning and continues; EVERGO_VERIFY_DOWNLOADS=strict makes it fail.
verify_md5 "$ARCH_TARBALL" "$TARBALL_BASE/$TARBALL_NAME.md5" "Arch Linux ARM tarball"
# The signature URL may be on the mirror the tarball came from; fall back to the
# other mirror when that one lacks it.
if ! curl -fsSL --max-time 30 -o /dev/null "$TARBALL_BASE/$TARBALL_NAME.sig" 2>/dev/null; then
    if curl -fsSL --max-time 30 -o /dev/null "$BASE_PRIMARY/$TARBALL_NAME.sig" 2>/dev/null; then
        TARBALL_BASE="$BASE_PRIMARY"
    elif curl -fsSL --max-time 30 -o /dev/null "$BASE_FALLBACK/$TARBALL_NAME.sig" 2>/dev/null; then
        TARBALL_BASE="$BASE_FALLBACK"
    fi
fi
verify_gpg_detached "$ARCH_TARBALL" "$TARBALL_BASE/$TARBALL_NAME.sig" "$KEY" "Arch Linux ARM tarball"

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
# Full upgrade, not just a sync: the tarball is a monthly snapshot, so -Sy alone
# would keep shipping packages that are weeks out of date.
pacman -Syu --noconfirm >/dev/null
# WiFi station mode (evergo-wifi) needs wpa_supplicant/iw/dhcpcd; wireless-regdb
# provides the signed regulatory.db cfg80211 asks for at startup.
pacman -S --noconfirm --needed \
  btop htop fastfetch git wget curl nano vim tmux rsync unzip zip file less \
  man-db which pacman-contrib net-tools bind-tools iputils traceroute mtr whois \
  lm_sensors lsof strace sudo wpa_supplicant iw dhcpcd wireless-regdb \
  networkmanager bluez noto-fonts-cjk alsa-utils alsa-ucm-conf >/dev/null
# The tarball ships a locked root password and the image only allows password logins,
# so a freshly flashed phone would be unreachable.
echo "root:evergo" | chpasswd
passwd -S root
# Chinese locale
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
echo LANG=zh_CN.UTF-8 > /etc/locale.conf
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
       "$R"/var/cache/* "$R"/var/lib/pacman/sync/* \
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
