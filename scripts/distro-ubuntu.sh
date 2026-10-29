#!/bin/bash
# Ubuntu root filesystem for evergo, from the OFFICIAL prebuilt base tarball.
#
# No debootstrap: Canonical ships ubuntu-base-<ver>-base-arm64.tar.gz, which is exactly
# the minimal root filesystem we want.  Downloading + extracting it takes seconds and
# cannot drift the way a bootstrap does.
#
# Usage: distro-ubuntu.sh <rootfs-dir>
set -euo pipefail

R="${1:?usage: distro-ubuntu.sh <rootfs-dir>}"
VER="${UBUNTU_VERSION:-26.04}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/evergo-work}"

log() { printf '  %s\n' "$*"; }

mkdir -p "$WORK"
rm -rf "$R"
mkdir -p "$(dirname "$R")"

TARBALL="$WORK/ubuntu-base-$VER-arm64.tar.gz"
if [ ! -s "$TARBALL" ]; then
    log "downloading ubuntu-base $VER (official)"
    ok=0
    for base in \
        "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases" \
        "https://cdimage.ubuntu.com/ubuntu-base/releases"; do
        url="$base/$VER/release/ubuntu-base-$VER-base-arm64.tar.gz"
        log "  $url"
        if curl -fsSL --max-time 600 -o "$TARBALL" "$url"; then ok=1; break; fi
        rm -f "$TARBALL"
    done
    [ "$ok" = 1 ] || { echo "  !! cannot download ubuntu-base $VER"; exit 1; }
fi
log "extracting $(stat -c%s "$TARBALL") bytes"
tar xzf "$TARBALL" -C "$R" --numeric-owner 2>/dev/null || true
log "extracted $(find "$R" -xdev -type f 2>/dev/null | wc -l) files"

# ubuntu-base ships almost nothing; the common config installs what we need
bash "$HERE/distro-common.sh" "$R" ubuntu
