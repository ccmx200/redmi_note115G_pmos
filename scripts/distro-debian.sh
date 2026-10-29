#!/bin/bash
# Debian root filesystem for evergo, from the OFFICIAL prebuilt generic cloud tarball.
#
# No debootstrap: cloud.debian.org publishes debian-<ver>-generic-arm64.tar.xz, a complete
# root filesystem.  Extracting it takes seconds and does not depend on the host's
# debootstrap version or on Debian archive keys.
#
# Usage: distro-debian.sh <rootfs-dir>
set -euo pipefail

R="${1:?usage: distro-debian.sh <rootfs-dir>}"
SUITE="${DEBIAN_SUITE:-trixie}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/evergo-work}"

log() { printf '  %s\n' "$*"; }

mkdir -p "$WORK"
rm -rf "$R"
mkdir -p "$R"
mkdir -p "$(dirname "$R")"

TARBALL="$WORK/debian-$SUITE-arm64.tar.xz"
if [ ! -s "$TARBALL" ]; then
    log "downloading Debian $SUITE cloud rootfs (official)"
    ok=0
    for url in \
        "https://cloud.debian.org/images/cloud/$SUITE/latest/debian-13-generic-arm64.tar.xz" \
        "https://cloud.debian.org/images/cloud/$SUITE/latest/debian-13-genericcloud-arm64.tar.xz"; do
        log "  $url"
        if curl -fsSL --max-time 600 -o "$TARBALL" "$url"; then ok=1; break; fi
        rm -f "$TARBALL"
    done
    [ "$ok" = 1 ] || { echo "  !! cannot download the Debian cloud rootfs"; exit 1; }
fi
log "extracting $(stat -c%s "$TARBALL") bytes"
tar xJf "$TARBALL" -C "$R" --numeric-owner 2>/dev/null || tar xf "$TARBALL" -C "$R" --numeric-owner
log "extracted $(find "$R" -xdev -type f 2>/dev/null | wc -l) files"

bash "$HERE/distro-common.sh" "$R" debian
