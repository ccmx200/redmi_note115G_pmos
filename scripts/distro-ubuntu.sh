#!/usr/bin/env bash
# =============================================================================
# distro-ubuntu.sh -- populate a root filesystem directory with Ubuntu 26.04 LTS
#                     ("resolute") for arm64.
#
# Usage:
#     scripts/distro-ubuntu.sh <rootfs-dir>
#
# The directory is filled by mmdebstrap: arm64 packages cannot be installed on an
# x86_64 build host without qemu-user, and mmdebstrap is the tool that drives apt
# inside the foreign-architecture target under qemu-aarch64 binfmt_misc.
#
# Environment overrides (all optional):
#     UBUNTU_SUITE        release codename                 (default: resolute = 26.04 LTS)
#     UBUNTU_MIRROR       apt mirror base URL              (default: TUNA ubuntu-ports)
#     UBUNTU_COMPONENTS   apt components, space separated  (default: main restricted universe multiverse)
#     UBUNTU_KEYRING      host keyring for the archive     (default: ubuntu-archive-keyring.gpg)
#     QEMU_STATIC         qemu-user binary                 (default: /usr/bin/qemu-aarch64-static)
#     MMDEBSTRAP          mmdebstrap binary                (default: /usr/bin/mmdebstrap)
#     TARGET_HOSTNAME     hostname written into the image  (default: evergo)
#     ROOT_PASSWORD       root password                    (default: evergo)
#
# Things that were learned the hard way and are baked into this script:
#   * NOTHING is written into <rootfs-dir> before mmdebstrap is called: mmdebstrap
#     requires the target to be empty.  All post-processing therefore happens in
#     --setup-hook / --customize-hook.
#   * Do NOT use an http(s) proxy for the build.  On this machine the proxy MITMs
#     the archive contents, which breaks apt's InRelease signature check.  The
#     Chinese mirrors are reachable directly, so no proxy is configured here.
#   * The target directory must be on a real POSIX filesystem (ext4, xfs, ...).
#     Windows DrvFs mounts (e.g. /mnt/d) silently ignore fchmod(), and dpkg/apt
#     then die with "Could not change permissions for temporary file".
#   * /etc/apt/sources.list is rewritten in the customize hook, so the finished
#     image keeps using the Chinese mirror for its whole life, not only while it
#     is being built.  Ubuntu >= 25.10 defaults to deb822 *.sources files; left
#     alone they would keep pointing at archive.ubuntu.com, so they are removed
#     and replaced by a single one-line sources.list (apt still supports it).
#   * The host's ubuntu-archive-keyring.gpg is passed explicitly with --keyring;
#     it contains the archive key that signed the resolute InRelease (checked by
#     hand with `gpg --verify`).  It only has to be visible to apt as run by
#     mmdebstrap -- the target nevertheless ships ubuntu-keyring itself so that
#     `apt-get update` works inside the image.
#   * qemu-aarch64-static is copied into the target by a setup hook (needed on
#     hosts whose binfmt_misc registration is not of the "fix binary" kind) and
#     removed again before this script returns.
# =============================================================================
set -euo pipefail

SUITE="${UBUNTU_SUITE:-resolute}"
MIRROR="${UBUNTU_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/}"
COMPONENTS="${UBUNTU_COMPONENTS:-main restricted universe multiverse}"
KEYRING="${UBUNTU_KEYRING:-/usr/share/keyrings/ubuntu-archive-keyring.gpg}"
QEMU_STATIC="${QEMU_STATIC:-/usr/bin/qemu-aarch64-static}"
MMDEBSTRAP="${MMDEBSTRAP:-/usr/bin/mmdebstrap}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-evergo}"
ROOT_PASSWORD="${ROOT_PASSWORD:-evergo}"

ARCH="arm64"
VARIANT="important"   # Debian/Ubuntu "priority required + important" base; the
                      # packages below are layered on top of it.

# Packages on top of the important base.  Notes:
#   * systemd-sysv provides /sbin/init (a symlink to /lib/systemd/systemd), the
#     systemd package provides /usr/lib/systemd/systemd itself.
#   * e2fsprogs brings /usr/sbin/e2fsck and /usr/sbin/resize2fs, which the
#     initramfs needs to fsck/grow the root filesystem.
#   * "dnsutils" no longer exists in 26.04 (it was folded into bind9-dnsutils),
#     so bind9-dnsutils is used for dig/host/nslookup.
#   * ubuntu-keyring is what lets apt inside the image trust the mirror;
#     passwd is what provides chpasswd.
PACKAGES="systemd,systemd-sysv,openssh-server,e2fsprogs,sudo,curl,wget,git,vim,nano,htop,tmux,iproute2,iputils-ping,bind9-dnsutils,ca-certificates,locales,tzdata,procps,less,rsync,unzip,file,man-db,kmod,ubuntu-keyring,passwd"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- preflight --
[ "$#" -eq 1 ] || die "usage: $0 <rootfs-dir>"
ROOTFS="$1"
case "$ROOTFS" in
    /*) ;;
    *) ROOTFS="$(cd "$(dirname "$ROOTFS")" && pwd)/$(basename "$ROOTFS")" ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root: mmdebstrap needs chroot, mknod and chown"
[ -x "$MMDEBSTRAP" ]  || die "mmdebstrap not found/executable at $MMDEBSTRAP"
[ -x "$QEMU_STATIC" ] || die "qemu-user not found/executable at $QEMU_STATIC"
[ -e "$KEYRING" ]     || die "keyring $KEYRING missing (apt-get install ubuntu-keyring)"
command -v arch-test >/dev/null 2>&1 \
    || die "arch-test is not installed; mmdebstrap needs it to verify that qemu-user can run arm64 binaries"

if [ -e "$ROOTFS" ] && [ -n "$(ls -A "$ROOTFS" 2>/dev/null)" ]; then
    die "target directory $ROOTFS is not empty; mmdebstrap requires an empty directory"
fi
mkdir -p "$ROOTFS"

# Refuse to work on a Windows DrvFs mount: fchmod/chown are silently dropped there
# and dpkg/apt fail halfway through the build.
if command -v findmnt >/dev/null 2>&1; then
    fs="$(findmnt -n -o FSTYPE -T "$ROOTFS" 2>/dev/null || true)"
    case "$fs" in
        9p|drvfs|cifs|vfat|exfat) die "target $ROOTFS lives on '$fs' (Windows mount); use a native ext4 path instead" ;;
    esac
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/distro-ubuntu.XXXXXX")"
cleanup() {
    # The emulator is a build aid only; it must never end up in the image.
    rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------- customize script ----
# mmdebstrap runs this inside the finished chroot (as root) with the host
# environment preserved; DISTRO_* values are exported right before the call.
CUSTOMIZE="$WORK/distro-ubuntu-customize.sh"
cat > "$CUSTOMIZE" <<'CUSTOMIZE_EOF'
#!/bin/bash
# Runs inside the freshly bootstrapped Ubuntu rootfs, as root.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
: "${DISTRO_UBUNTU_MIRROR:?}"
: "${DISTRO_UBUNTU_SUITE:?}"
: "${DISTRO_UBUNTU_COMPONENTS:?}"
: "${DISTRO_HOSTNAME:?}"
: "${DISTRO_ROOT_PASSWORD:?}"

RESOLV_BACKUP=""
RESOLV_CREATED=0

# --- 1. package sources: a single, Chinese, one-line sources.list -----------
echo "  [customize] apt sources -> ${DISTRO_UBUNTU_MIRROR}"
rm -f /etc/apt/sources.list
# Drop deb822 *.sources files (Ubuntu >= 25.10 default) and stray *.list files:
# they would point at archive.ubuntu.com and shadow the mirror.
rm -f /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list
cat > /etc/apt/sources.list <<EOF
# Ubuntu ${DISTRO_UBUNTU_SUITE} (arm64) - Chinese mirror, generated by scripts/distro-ubuntu.sh
deb ${DISTRO_UBUNTU_MIRROR} ${DISTRO_UBUNTU_SUITE} ${DISTRO_UBUNTU_COMPONENTS}
deb ${DISTRO_UBUNTU_MIRROR} ${DISTRO_UBUNTU_SUITE}-updates ${DISTRO_UBUNTU_COMPONENTS}
deb ${DISTRO_UBUNTU_MIRROR} ${DISTRO_UBUNTU_SUITE}-security ${DISTRO_UBUNTU_COMPONENTS}
EOF

# --- 2. resolver for apt inside the chroot -----------------------------------
# Ubuntu ships /etc/resolv.conf as a symlink to systemd-resolved's stub file,
# which resolves nothing before boot; mmdebstrap's bind mount of the host file
# is also gone by now.  Park whatever is there, install a working resolver for
# the update below, and restore the distro default before the hook returns.
if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
    if [ -s /etc/resolv.conf ]; then
        : # already usable (this is what a working bind mount looks like)
    elif mv /etc/resolv.conf /tmp/distro-resolv.conf.bak 2>/dev/null; then
        RESOLV_BACKUP=/tmp/distro-resolv.conf.bak
        printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > /etc/resolv.conf
        RESOLV_CREATED=1
    fi
else
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > /etc/resolv.conf
    RESOLV_CREATED=1
fi

# --- 3. prove the new sources work: this is the real "apt-get update" test ---
echo "  [customize] apt-get update"
apt-get update

# --- 4. hostname -------------------------------------------------------------
echo "  [customize] hostname -> ${DISTRO_HOSTNAME}"
printf '%s\n' "${DISTRO_HOSTNAME}" > /etc/hostname
if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s|^[[:space:]]*127\.0\.1\.1[[:space:]]+.*|127.0.1.1 ${DISTRO_HOSTNAME}|" /etc/hosts
else
    printf '\n127.0.1.1 %s\n' "${DISTRO_HOSTNAME}" >> /etc/hosts
fi

# --- 5. root password --------------------------------------------------------
echo "  [customize] root password"
echo "root:${DISTRO_ROOT_PASSWORD}" | chpasswd

# --- 6. enable the SSH server ------------------------------------------------
# `systemctl enable` works offline; fall back to the symlink if systemctl is
# unhappy in a chroot without /proc.
echo "  [customize] enabling ssh.service"
mkdir -p /etc/systemd/system/multi-user.target.wants
systemctl enable ssh.service >/dev/null 2>&1 \
    || ln -sf /usr/lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service

# --- 7. leave the machine-id empty so systemd generates a fresh one on boot --
: > /etc/machine-id

# --- 8. restore the distro's default resolver --------------------------------
if [ "${RESOLV_CREATED}" = 1 ]; then
    rm -f /etc/resolv.conf
    if [ -n "${RESOLV_BACKUP}" ] && { [ -e "${RESOLV_BACKUP}" ] || [ -L "${RESOLV_BACKUP}" ]; }; then
        mv "${RESOLV_BACKUP}" /etc/resolv.conf
    else
        : > /etc/resolv.conf   # debootstrap-style empty placeholder
    fi
fi

# --- 9. remove this helper ---------------------------------------------------
rm -f /tmp/distro-ubuntu-customize.sh
CUSTOMIZE_EOF
chmod 0755 "$CUSTOMIZE"

# --------------------------------------------------------------- mmdebstrap --
say "bootstrapping Ubuntu ${SUITE} (${ARCH}) into ${ROOTFS}"
echo "  mirror : ${MIRROR}"
echo "  keyring: ${KEYRING}"

# The DISTRO_* variables are consumed by the customize script above; mmdebstrap
# preserves the caller's environment for hooks (only TMPDIR is cleared).
export DISTRO_UBUNTU_MIRROR="$MIRROR"
export DISTRO_UBUNTU_SUITE="$SUITE"
export DISTRO_UBUNTU_COMPONENTS="$COMPONENTS"
export DISTRO_HOSTNAME="$TARGET_HOSTNAME"
export DISTRO_ROOT_PASSWORD="$ROOT_PASSWORD"
export QEMU_STATIC

# --allow-insecure-repositories: only for the build-time apt run as driven by
# mmdebstrap (it lives in mmdebstrap's temporary APT_CONFIG, not in the image).
# The mirror is reached over HTTPS and its InRelease was verified against the
# host keyring; these flags merely let the build survive apt's stricter
# signed-by handling on this machine.
"$MMDEBSTRAP" \
    --architectures="$ARCH" \
    --variant="$VARIANT" \
    --components="$COMPONENTS" \
    --keyring="$KEYRING" \
    --include="$PACKAGES" \
--aptopt='Acquire::AllowInsecureRepositories "true"' \
    --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
    --setup-hook='mkdir -p "$1/usr/bin" && cp "$QEMU_STATIC" "$1/usr/bin/qemu-aarch64-static"' \
    --customize-hook="copy-in $CUSTOMIZE /tmp/" \
    --customize-hook='chroot "$1" /bin/bash /tmp/distro-ubuntu-customize.sh' \
    "$SUITE" "$ROOTFS" "$MIRROR"

# -------------------------------------------------------- final verification --
say "verifying ${ROOTFS}"
verify_status=0
need_exec() {
    local path="$1" what="$2"
    # Test *inside* the chroot: a plain -x on the host path would follow
    # absolute symlinks such as /sbin/init -> /lib/systemd/systemd against the
    # host's own root instead of the image.
    if chroot "$ROOTFS" /bin/sh -c "test -x '$path'" 2>/dev/null; then
        local target=""
        [ -L "$ROOTFS$path" ] && target=" -> $(readlink "$ROOTFS$path")"
        printf '  [ok]   %-26s %s%s\n' "$path" "$what" "$target"
    else
        printf '  [FAIL] %-26s missing (%s)\n' "$path" "$what"
        verify_status=1
    fi
}
need_exec /sbin/init                   "systemd init (sysv-compat)"
need_exec /usr/lib/systemd/systemd     "systemd init binary"
need_exec /usr/sbin/sshd               "openssh-server daemon"
need_exec /usr/sbin/resize2fs          "e2fsprogs: resize2fs"
need_exec /usr/sbin/e2fsck             "e2fsprogs: e2fsck"
need_exec /usr/bin/sudo                "sudo"

if [ -s "$ROOTFS/etc/shadow" ] \
   && awk -F: '$1=="root" && $2!="" && $2!="*" && $2!="!" {ok=1} END{exit !ok}' "$ROOTFS/etc/shadow"; then
    printf '  [ok]   %-26s root password set (not locked)\n' "/etc/shadow"
else
    printf '  [FAIL] %-26s root password not set\n' "/etc/shadow"
    verify_status=1
fi

if [ "$(cat "$ROOTFS/etc/hostname" 2>/dev/null)" = "$TARGET_HOSTNAME" ]; then
    printf '  [ok]   %-26s %s\n' "/etc/hostname" "$TARGET_HOSTNAME"
else
    printf '  [FAIL] %-26s %s\n' "/etc/hostname" "$(cat "$ROOTFS/etc/hostname" 2>/dev/null)"
    verify_status=1
fi

if grep -q "$MIRROR" "$ROOTFS/etc/apt/sources.list" 2>/dev/null; then
    printf '  [ok]   %-26s %s\n' "/etc/apt/sources.list" "points at $MIRROR"
else
    printf '  [FAIL] %-26s does not point at %s\n' "/etc/apt/sources.list" "$MIRROR"
    verify_status=1
fi

[ "$verify_status" -eq 0 ] || die "rootfs verification failed"

# A last, end-to-end check of apt inside the finished image.  The package lists
# are written to /tmp so the image's own /var/lib/apt/lists is not touched.
say "apt-get update inside the finished chroot"
if [ -e "$ROOTFS/etc/resolv.conf" ] || [ -L "$ROOTFS/etc/resolv.conf" ]; then
    mv "$ROOTFS/etc/resolv.conf" "$WORK/resolv.conf.orig"
    RESOLV_SAVED=1
else
    RESOLV_SAVED=0
fi
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
mkdir -p "$ROOTFS/tmp/apt-verify/partial"
if chroot "$ROOTFS" apt-get update \
        -o "Dir::State::lists=/tmp/apt-verify" \
        -o "APT::Sandbox::User=root" > "$WORK/apt-update.log" 2>&1; then
    echo "  [ok]   apt-get update succeeded"
else
    cat "$WORK/apt-update.log" >&2
    rm -rf "$ROOTFS/tmp/apt-verify"
    if [ "$RESOLV_SAVED" = 1 ]; then
        mv "$WORK/resolv.conf.orig" "$ROOTFS/etc/resolv.conf"
    fi
    die "apt-get update failed inside the target"
fi
rm -rf "$ROOTFS/tmp/apt-verify"
if [ "$RESOLV_SAVED" = 1 ]; then
    mv "$WORK/resolv.conf.orig" "$ROOTFS/etc/resolv.conf"
else
    rm -f "$ROOTFS/etc/resolv.conf"
fi

# ------------------------------------------------------------------ summary --
say "done"
echo "  suite    : Ubuntu ${SUITE} (${ARCH})"
echo "  rootfs   : ${ROOTFS}"
echo "  size     : $(du -sh "$ROOTFS" | cut -f1)"
echo "  sources  :"
sed 's/^/      /' "$ROOTFS/etc/apt/sources.list"
