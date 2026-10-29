#!/bin/bash
# Fedora root filesystem for evergo, from the OFFICIAL prebuilt container base tarball.
#
# No dnf --installroot: Fedora publishes Fedora-Container-Base-*.aarch64.oci.tar.xz (an OCI
# archive) and Fedora-WSL-Base-*.aarch64.wsl (a plain rootfs tar).  The WSL one is a
# straight tar, so extracting it is trivial.
#
# Usage: distro-fedora.sh <rootfs-dir>
set -euo pipefail

R="${1:?usage: distro-fedora.sh <rootfs-dir>}"
REL="${FEDORA_RELEASE:-44}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/evergo-work}"

log() { printf '  %s\n' "$*"; }

mkdir -p "$WORK"
rm -rf "$R"
mkdir -p "$(dirname "$R")"

# Fedora publishes the WSL base as a plain tar; the container base is an OCI archive that
# would need layer extraction.  Prefer the plain one.
TARBALL="$WORK/fedora-$REL-rootfs.tar"
if [ ! -s "$TARBALL" ]; then
    log "downloading Fedora $REL WSL base (official)"
    ok=0
    for base in \
        "https://mirrors.tuna.tsinghua.edu.cn/fedora/releases/$REL/Container/aarch64/images" \
        "https://mirrors.ustc.edu.cn/fedora/releases/$REL/Container/aarch64/images" \
        "https://download.fedoraproject.org/pub/fedora/linux/releases/$REL/Container/aarch64/images"; do
        # find the current WSL base filename
        name=$(curl -fsSL --max-time 60 "$base/" 2>/dev/null \
               | grep -oE "Fedora-WSL-Base-$REL[^\"]*\.aarch64\.wsl" | sort -u | tail -1)
        [ -z "$name" ] && continue
        log "  $name"
        if curl -fsSL --max-time 900 -o "$TARBALL" "$base/$name"; then ok=1; break; fi
        rm -f "$TARBALL"
    done
    [ "$ok" = 1 ] || { echo "  !! cannot download the Fedora rootfs"; exit 1; }
fi
log "extracting $(stat -c%s "$TARBALL") bytes"
tar xf "$TARBALL" -C "$R" --numeric-owner 2>/dev/null || true
# WSL images sometimes wrap everything in a single top directory
if [ ! -e "$R/etc/os-release" ]; then
    inner=$(find "$R" -maxdepth 2 -name os-release -path '*/etc/*' 2>/dev/null | head -1)
    if [ -n "$inner" ]; then
        top="${inner%/etc/os-release}"
        log "flattening $top"
        shopt -s dotglob
        mv "$top"/* "$R"/ 2>/dev/null || true
        rmdir "$top" 2>/dev/null || true
        shopt -u dotglob
    fi
fi
log "extracted $(find "$R" -xdev -type f 2>/dev/null | wc -l) files"

bash "$HERE/distro-common.sh" "$R" fedora
