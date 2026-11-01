#!/bin/bash
# Debian root filesystem for evergo, built with debootstrap.
#
# Earlier revisions downloaded "debian-<suite>-generic-arm64.tar.xz" from
# cloud.debian.org and extracted it.  That does not work: the generic/genericcloud
# images are *disk images* tarred up (they contain disk.raw), not root filesystem
# tarballs, so extraction produced no /usr/bin and the CI job died with
#   cp: cannot create ... /usr/bin/qemu-aarch64-static: No such file or directory
#
# Debian has no official rootfs tarball, so debootstrap is used instead: first
# stage from an amd64 host, second stage under qemu-user.  This needs the host
# packages `debootstrap` and `qemu-user-static` (the CI workflow and docs install
# them).
#
# Usage: distro-debian.sh <rootfs-dir>
set -euo pipefail

R="${1:?usage: distro-debian.sh <rootfs-dir>}"
SUITE="${DEBIAN_SUITE:-trixie}"
MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/evergo-work}"
QEMU=/usr/bin/qemu-aarch64-static

log() { printf '  %s\n' "$*"; }

command -v debootstrap >/dev/null 2>&1 || {
    echo "  !! debootstrap missing (apt install debootstrap)"; exit 1; }
[ -x "$QEMU" ] || { echo "  !! $QEMU missing (apt install qemu-user-static)"; exit 1; }

mkdir -p "$WORK"
rm -rf "$R"
mkdir -p "$R"

TARBALL="${DEBIAN_ROOTFS_TARBALL:-}"
if [ -n "$TARBALL" ] && [ -s "$TARBALL" ]; then
    log "using DEBIAN_ROOTFS_TARBALL=$TARBALL"
    rm -rf "$R"; mkdir -p "$R"
    tar xJf "$TARBALL" -C "$R" --numeric-owner 2>/dev/null || \
        tar xf "$TARBALL" -C "$R" --numeric-owner
    log "extracted $(find "$R" -xdev -type f 2>/dev/null | wc -l) files"
    bash "$HERE/distro-common.sh" "$R" debian
    exit 0
fi

log "debootstrap $SUITE arm64, first stage"
# --no-check-gpg: the archive keys of the host running this build are not part of
# the images and the runner image does not ship debian-archive-keyring; apt inside
# the target verifies the packages again on every later install.
if debootstrap --arch=arm64 --foreign --no-check-gpg --variant=minbase \
        --components=main --include=ca-certificates,apt \
        "$SUITE" "$R" "$MIRROR"; then
    :
else
    echo "  !! first stage failed"; exit 1
fi
log "debootstrap first stage done: $(find "$R" -xdev -type f 2>/dev/null | wc -l) files"

log "debootstrap $SUITE arm64, second stage under qemu"
cp -f "$QEMU" "$R/usr/bin/qemu-aarch64-static"
chmod 755 "$R/usr/bin/qemu-aarch64-static"
chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c '
    set -e
    /debootstrap/debootstrap --second-stage
' || { echo "  !! second stage failed"; exit 1; }
rm -f "$R/usr/bin/qemu-aarch64-static"
log "rootfs ready: $(du -sh "$R" | cut -f1)"

bash "$HERE/distro-common.sh" "$R" debian
