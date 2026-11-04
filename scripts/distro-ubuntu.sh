#!/bin/bash
# Ubuntu root filesystem for evergo, from the OFFICIAL prebuilt base tarball.
#
# No debootstrap: Canonical ships ubuntu-base-<ver>-base-arm64.tar.gz, which is exactly
# the minimal root filesystem we want.  Downloading + extracting it takes seconds and
# cannot drift the way a bootstrap does.
#
# The tarball is checked against the official SHA256SUMS published in the same
# release directory (see scripts/verify-download.sh); a corrupted/truncated
# download is a hard failure instead of a puzzling tar/qemu error later.
#
# Usage: distro-ubuntu.sh <rootfs-dir>
set -euo pipefail

R="${1:?usage: distro-ubuntu.sh <rootfs-dir>}"
VER="${UBUNTU_VERSION:-26.04}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/evergo-work}"

log() { printf '  %s\n' "$*"; }

# shellcheck source=verify-download.sh
. "$HERE/verify-download.sh"

mkdir -p "$WORK"
rm -rf "$R"
mkdir -p "$R"
mkdir -p "$(dirname "$R")"

TARBALL="$WORK/ubuntu-base-$VER-arm64.tar.gz"
REMOTE_NAME="ubuntu-base-$VER-base-arm64.tar.gz"

# Mirrors first (mainland China), official cdimage last.  Every candidate's
# SHA256SUMS is handed to the verifier so a mirror that forgot to sync the
# checksum file does not silently turn verification off.
BASES=(
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases"
    "https://cdimage.ubuntu.com/ubuntu-base/releases"
)
SUM_URLS=()
for base in "${BASES[@]}"; do
    SUM_URLS+=("$base/$VER/release/SHA256SUMS")
done

if [ ! -s "$TARBALL" ]; then
    log "downloading ubuntu-base $VER (official)"
    ok=0
    for base in "${BASES[@]}"; do
        url="$base/$VER/release/$REMOTE_NAME"
        log "  $url"
        if curl -fsSL --max-time 600 -o "$TARBALL" "$url"; then ok=1; break; fi
        rm -f "$TARBALL"
    done
    [ "$ok" = 1 ] || { echo "  !! cannot download ubuntu-base $VER"; exit 1; }
else
    log "reusing cached $(basename "$TARBALL")"
fi

# Verify whether the tarball was just downloaded or is a cached file from an
# earlier build: a stale/partial cache is exactly as dangerous as a bad mirror.
verify_download "$TARBALL" "$REMOTE_NAME" "ubuntu-base $VER arm64" "${SUM_URLS[@]}"

log "extracting $(stat -c%s "$TARBALL") bytes"
tar xzf "$TARBALL" -C "$R" --numeric-owner 2>/dev/null || true
log "extracted $(find "$R" -xdev -type f 2>/dev/null | wc -l) files"

# ubuntu-base ships almost nothing; the common config installs what we need
bash "$HERE/distro-common.sh" "$R" ubuntu
