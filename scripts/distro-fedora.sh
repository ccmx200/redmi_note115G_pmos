#!/bin/bash
# Fedora 44 aarch64 root filesystem for evergo (Redmi Note 11T 5G / MT6833).
#
# Usage: distro-fedora.sh <rootfs-dir>
#
# Produces a plain directory that the generic part of build.sh turns into an ext4
# image with `mke2fs -d`.  The distro is installed by the host's dnf in
# --installroot mode: dnf resolves the aarch64 repositories directly (--forcearch)
# and every RPM scriptlet runs through qemu-aarch64, which the host registers in
# binfmt_misc.  A short qemu chroot at the end sets the root password.
#
# The target directory must live on a native Linux filesystem (ext4/xfs/...), not on
# a Windows DrvFs/9p mount: rpm and dnf need working fchmod/fchown, which DrvFs denies.
#
# Environment overrides:
#   FEDORA_RELEASE         Fedora release to install       (default: 44)
#   FEDORA_MIRROR          Chinese mirror base URL         (default: TUNA Tsinghua)
#   FEDORA_BUILD_GPGCHECK  0/1, verify RPMs while building (default: 0; mirror is HTTPS)
#
# The image's own /etc/yum.repos.d/fedora.repo is always rewritten to point at
# $FEDORA_MIRROR with gpgcheck=1, so `dnf install ...` inside the flashed system
# keeps using the Chinese mirror.
set -euo pipefail

R="${1:-}"
[ -n "$R" ] || { echo "usage: $0 <rootfs-dir>" >&2; exit 2; }
REL="${FEDORA_RELEASE:-44}"
MIRROR="${FEDORA_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/fedora}"
MIRROR="${MIRROR%/}"
BUILD_GPGCHECK="${FEDORA_BUILD_GPGCHECK:-0}"
ARCH="aarch64"

log()  { printf '  %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*" >&2; }
die()  { printf '  !! %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------- requirements ---
[ "$(id -u)" = "0" ] || die "must run as root (dnf --installroot and the qemu chroot need it)"
for t in dnf rpm qemu-aarch64-static curl; do
    command -v "$t" >/dev/null 2>&1 || die "missing host tool: $t"
done
log "release : $REL"
log "mirror  : $MIRROR"
log "arch    : $ARCH"
log "target  : $R"

# The rootfs has to be assembled on a POSIX filesystem.  dnf/rpm call fchmod and
# fchown on freshly unpacked files; DrvFs and 9p reject both, and the install then
# dies with "Could not change permissions for temporary file ... fchmod".
mkdir -p "$(dirname "$R")"
PARENT="$(cd "$(dirname "$R")" && pwd)"
FSTYPE="$(stat -f -c %T "$PARENT" 2>/dev/null || echo unknown)"
case "$FSTYPE" in
    v9fs|9p|msdos|vfat|exfat|ntfs|fuseblk|cifs)
        die "target parent $PARENT is on '$FSTYPE'; build on a native ext4 path (e.g. /root/rootfs-test/fedora)" ;;
esac
log "parent fs: $FSTYPE"

if [ -e "$R" ] && [ -n "$(ls -A "$R" 2>/dev/null || true)" ]; then
    die "target $R is not empty; remove it first: rm -rf '$R'"
fi
mkdir -p "$R"

AVAIL_KB="$(df -Pk "$PARENT" | awk 'NR==2 {print $4}')"
[ "${AVAIL_KB:-0}" -ge 3145728 ] || die "need at least 3 GiB free on $PARENT (have ${AVAIL_KB} KiB)"

# Scrap space for the build-time repo files and dnf's log; removed on success.
WORK="$(mktemp -d "$PARENT/.fedora-${REL}-work.XXXXXX")"
cleanup() {
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        rm -rf "$WORK"
    else
        warn "build failed; dnf log kept in $WORK/dnf.log"
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------ mirror ----
# Probe the mirror before the 500 MB install: a typo in FEDORA_MIRROR or a release
# that was not synced yet is a lot cheaper to find out here.
probe() {
    curl -fsS -m 20 -o /dev/null \
        "$1/releases/$REL/Everything/$ARCH/os/repodata/repomd.xml" 2>/dev/null
}
if ! probe "$MIRROR"; then
    if [ -n "${FEDORA_MIRROR:-}" ]; then
        die "FEDORA_MIRROR=$MIRROR has no Fedora $REL Everything/$ARCH tree"
    fi
    FALLBACK=""
    for alt in https://mirrors.ustc.edu.cn/fedora https://mirrors.aliyun.com/fedora; do
        if probe "$alt"; then FALLBACK="$alt"; break; fi
    done
    [ -n "$FALLBACK" ] || die "no reachable Fedora $REL mirror (tried TUNA, USTC, Aliyun)"
    log "TUNA unreachable, using $FALLBACK"
    MIRROR="$FALLBACK"
fi

# Build-time repo set (host side).  Signature checks are off by default because the
# mirror is fetched over HTTPS; the image's own repo file keeps gpgcheck=1.
mkdir -p "$WORK/repos"
cat > "$WORK/repos/fedora-mirror.repo" <<EOF
[fedora]
name=Fedora $REL - $ARCH
baseurl=$MIRROR/releases/$REL/Everything/$ARCH/os/
enabled=1
countme=0
gpgcheck=$BUILD_GPGCHECK
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$REL-$ARCH
skip_if_unavailable=False

[updates]
name=Fedora $REL - $ARCH - Updates
baseurl=$MIRROR/updates/$REL/Everything/$ARCH/
enabled=1
countme=0
gpgcheck=$BUILD_GPGCHECK
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$REL-$ARCH
skip_if_unavailable=False
EOF

# ----------------------------------------------------------------- packages ---
# Everything the shared evergo image needs.  Two Fedora 44 renames matter here:
#   * `wget`       no longer exists; `wget1-wget` provides /usr/bin/wget
#   * `dnf` (4.x)  no longer exists; `dnf5`        provides /usr/bin/dnf
PKGS=(
    systemd systemd-udev systemd-networkd
    dnf5 fedora-release shadow-utils bash util-linux
    openssh-server openssh-clients e2fsprogs
    sudo curl wget1-wget git vim-enhanced nano htop tmux
    iproute iputils bind-utils ca-certificates glibc-langpack-en
    procps-ng less rsync unzip file man-db kmod
    tar gzip xz zstd which
)

log "installing ${#PKGS[@]} packages (pulls ~400 MB, takes several minutes)…"
set +e
dnf -y \
    --installroot="$R" \
    --forcearch="$ARCH" \
    --releasever="$REL" \
    --setopt=reposdir="$WORK/repos" \
    --setopt=install_weak_deps=False \
    --setopt=gpgcheck="$BUILD_GPGCHECK" \
    --setopt=retries=3 --setopt=timeout=120 \
    install "${PKGS[@]}" 2>&1 | tee "$WORK/dnf.log" | tail -n 30
RC="${PIPESTATUS[0]}"
set -e
[ "$RC" -eq 0 ] || { tail -n 60 "$WORK/dnf.log" >&2; die "dnf install failed (rc=$RC, log: $WORK/dnf.log)"; }

# Ubuntu/Debian package rpm with a "rootless" default %_dbpath (~/.rpmdb), so it has
# just written the target's rpmdb to $R/root/.rpmdb instead of the /usr/lib/sysimage/rpm
# that Fedora's own rpm and dnf read.  Relocate it: otherwise the flashed image boots
# with dnf/rpm believing that no package is installed, and the first `dnf install`
# would try to install glibc and bash a second time.
# The rpmdb location depends on $HOME: with root's home it is $R/root/.rpmdb, but CI
# runs build.sh through `sudo -E` and keeps HOME=/home/runner, so it turns up under
# $R/home/runner/.rpmdb instead.  Search for it rather than assuming.
RPMDB_DIR=$(find "$R" -maxdepth 4 -type d -name .rpmdb 2>/dev/null | head -1)
if [ -n "$RPMDB_DIR" ]; then
    log "relocating rpmdb from ${RPMDB_DIR#"$R"} to /usr/lib/sysimage/rpm"
    mkdir -p "$R/usr/lib/sysimage/rpm"
    rm -f "$R"/usr/lib/sysimage/rpm/rpmdb.sqlite* "$R/usr/lib/sysimage/rpm/.rpm.lock"
    mv "$RPMDB_DIR"/rpmdb.sqlite* "$R/usr/lib/sysimage/rpm"/ 2>/dev/null || true
    rm -rf "$RPMDB_DIR"
fi
RPMDB="$R/usr/lib/sysimage/rpm/rpmdb.sqlite"
[ -f "$RPMDB" ] || die "rpmdb missing at /usr/lib/sysimage/rpm (rpm/dnf in the image would not work)"
log "packages: $(rpm --root="$R" --dbpath=/usr/lib/sysimage/rpm -qa 2>/dev/null | wc -l) RPMs"

# --------------------------------------------------------------- host config ---
log "writing host and network configuration"
printf 'evergo\n' > "$R/etc/hostname"
cat > "$R/etc/hosts" <<'EOF'
127.0.0.1   localhost localhost.localdomain
::1         localhost localhost.localdomain
127.0.1.1   evergo
EOF
printf 'LANG=en_US.UTF-8\n' > "$R/etc/locale.conf"

# A static resolver: systemd-resolved is not installed and systemd-networkd does not
# rewrite /etc/resolv.conf, so DNS has to be configured here.  Do not copy the build
# host's file - that would bake in whatever resolver the host happens to use (e.g.
# WSL's 10.255.255.254, which is meaningless on the phone).
rm -f "$R/etc/resolv.conf"
cat > "$R/etc/resolv.conf" <<'EOF'
# Static resolvers; AliDNS and Tencent DNS are fast in mainland China.
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
EOF

# dnf scriptlets created a machine-id from the build host; leave an empty file so
# every flashed phone generates its own on first boot.
if [ -e "$R/etc/machine-id" ]; then
    : > "$R/etc/machine-id"
fi

# ---------------------------------------------------------------- chroot -------
# root password, system users and the boot-time services.  binfmt_misc usually runs
# aarch64 binaries transparently, but invoke qemu explicitly as well so this also
# works on a host without a registered aarch64 interpreter.
log "post-configuring (chpasswd, sysusers, sshd) through qemu chroot…"
cp -f /usr/bin/qemu-aarch64-static "$R/usr/bin/qemu-aarch64-static"
if ! chroot "$R" /usr/bin/qemu-aarch64-static /bin/bash -euc '
    # The rpmdb has to be readable by the image own rpm: this is the check that
    # catches a build-host rpm writing the database to the wrong place.
    installed=$(/usr/bin/rpm -qa | wc -l)
    [ "$installed" -ge 200 ] || { echo "image rpm sees only $installed packages" >&2; exit 1; }

    # RPM scriptlets are not allowed to abort a transaction, so a failed one can
    # leave the system users (sshd, systemd-network, ...) uncreated; re-run the
    # declarative sysusers files to make sure they exist.
    /usr/bin/systemd-sysusers >/dev/null 2>&1 || true

    # Apply the vendor preset policy (best effort - a plain chroot has no systemd).
    /usr/bin/systemctl preset-all --root=/ >/dev/null 2>&1 || true

    # The root account is locked in a Fedora install; the image is reached over SSH
    # with this password on first boot.
    printf "root:evergo\n" | /usr/bin/chpasswd

    # Make sure the services the image relies on are enabled even if the preset
    # run above bailed out.
    mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/sockets.target.wants
    ln -sf /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.service /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
    ln -sf /usr/lib/systemd/system/systemd-networkd.socket /etc/systemd/system/sockets.target.wants/systemd-networkd.socket
'; then
    die "qemu chroot post-configuration failed"
fi
rm -f "$R/usr/bin/qemu-aarch64-static"

# ------------------------------------------------------------------ repos -----
# Point every package source at the Chinese mirror, for the build and for the
# flashed system.  Remove the shipped files first: they use mirrors.fedoraproject.org
# metalinks, which are unreachable from mainland China.
log "rewriting /etc/yum.repos.d for $MIRROR"
rm -f "$R"/etc/yum.repos.d/*.repo
KEYFILE="RPM-GPG-KEY-fedora-$REL-$ARCH"
GPGCHECK=1
if [ ! -e "$R/etc/pki/rpm-gpg/$KEYFILE" ]; then
    KEYFILE="RPM-GPG-KEY-$REL-fedora"
fi
if [ ! -e "$R/etc/pki/rpm-gpg/$KEYFILE" ]; then
    warn "no Fedora GPG key in $R/etc/pki/rpm-gpg; writing gpgcheck=0"
    GPGCHECK=0
fi
cat > "$R/etc/yum.repos.d/fedora.repo" <<EOF
# Fedora $REL repositories on the Chinese mirror.
#
# The release is expanded here rather than left as \$releasever: the fedora-release
# in this tree provides system-release($REL) but not system-release(releasever), and
# dnf5 in the flashed image therefore cannot auto-detect \$releasever (its metadata
# requests would literally ask for releases/\$releasever/... and 404).  Bump the
# release by re-running distro-fedora.sh with FEDORA_RELEASE=<N>.
[fedora]
name=Fedora $REL - $ARCH
baseurl=$MIRROR/releases/$REL/Everything/$ARCH/os/
enabled=1
countme=0
metadata_expire=7d
type=rpm
repo_gpgcheck=0
gpgcheck=$GPGCHECK
gpgkey=file:///etc/pki/rpm-gpg/$KEYFILE
skip_if_unavailable=False

[updates]
name=Fedora $REL - $ARCH - Updates
baseurl=$MIRROR/updates/$REL/Everything/$ARCH/
enabled=1
countme=0
metadata_expire=6h
type=rpm
repo_gpgcheck=0
gpgcheck=$GPGCHECK
gpgkey=file:///etc/pki/rpm-gpg/$KEYFILE
skip_if_unavailable=False
EOF

# The package cache is dead weight in a shipped image.  The initramfs boots with
# `switch_root /newroot /sbin/init`, so the leftover rpm transaction lock and cache
# directories are removed as well.
rm -rf "$R/var/cache/dnf" "$R/var/cache/libdnf5" "$R/var/lib/dnf" "$R/var/lib/dnf5" \
       "$R"/var/cache/*.solv "$R"/tmp/* "$R"/var/log/dnf* "$R"/var/log/libdnf*
rm -f "$R/usr/lib/sysimage/rpm/.rpm.lock"
mkdir -p "$R/var/cache" "$R/var/log" "$R/tmp"
chmod 1777 "$R/tmp"

# -------------------------------------------------------------- verification ---
log "verifying…"
FAIL=0
need() {   # need <path-inside-rootfs> [x]
    if [ -e "$R/$1" ] && { [ "${2:-}" != "x" ] || [ -x "$R/$1" ]; }; then
        printf '    OK   /%s\n' "$1"
    else
        printf '    MISS /%s  <-- problem\n' "$1"; FAIL=1
    fi
}
need usr/lib/systemd/systemd x
need sbin/init x
need usr/sbin/sshd x
need usr/sbin/resize2fs x
need usr/sbin/e2fsck x
need usr/bin/sudo x
need usr/bin/dnf x
need usr/bin/wget x
need etc/shadow

if [ -s "$R/usr/lib/sysimage/rpm/rpmdb.sqlite" ] && [ ! -e "$R/root/.rpmdb" ]; then
    printf '    OK   rpmdb at /usr/lib/sysimage/rpm\n'
else
    printf '    MISS rpmdb location (dnf inside the image would see no packages)\n'; FAIL=1
fi

ROOT_HASH="$(awk -F: '$1 == "root" {print $2}' "$R/etc/shadow" 2>/dev/null || true)"
case "$ROOT_HASH" in
    \$*\$*) printf '    OK   root password hash set (%s...)\n' "${ROOT_HASH:0:3}" ;;
    *)      printf '    MISS root password is not set (shadow field: %s)\n' "${ROOT_HASH:-empty}"; FAIL=1 ;;
esac
if [ "$(cat "$R/etc/hostname" 2>/dev/null)" = "evergo" ]; then
    printf '    OK   hostname evergo\n'
else
    printf '    MISS hostname\n'; FAIL=1
fi
REPOFILE="$R/etc/yum.repos.d/fedora.repo"
if grep -Fqx "baseurl=$MIRROR/releases/$REL/Everything/$ARCH/os/" "$REPOFILE" \
   && grep -Fqx "baseurl=$MIRROR/updates/$REL/Everything/$ARCH/" "$REPOFILE" \
   && grep -qx 'gpgcheck=1' "$REPOFILE" \
   && ! grep -q 'fedoraproject.org' "$REPOFILE"; then
    printf '    OK   yum repos point at %s (gpgcheck=1)\n' "$MIRROR"
else
    printf '    MISS yum repos\n'; FAIL=1
fi

# Confirm the exact baseurls written into the image are live on the mirror: a typo
# here only shows up when somebody runs `dnf install` on the phone.
log "checking delivered repo URLs…"
while IFS= read -r url; do
    curl -fsS -m 20 -o /dev/null "$url/repodata/repomd.xml" \
        || { warn "unreachable repo URL: $url"; FAIL=1; }
done < <(sed -n 's/^baseurl=//p' "$REPOFILE")

log "size    : $(du -sh "$R" | cut -f1) ($(du -sb "$R" | cut -f1) bytes)"
log "files   : $(find "$R" -xdev | wc -l)"
log "RPMs    : $(rpm --root="$R" --dbpath=/usr/lib/sysimage/rpm -qa 2>/dev/null | wc -l)"
log "os      : $(grep -E '^(NAME|VERSION)=' "$R/etc/os-release" | tr '\n' ' ')"
log "repos   :"
grep -E '^baseurl=' "$R/etc/yum.repos.d/fedora.repo" | sed 's/^/    /'
[ "$FAIL" -eq 0 ] || die "verification failed"
log "done"
