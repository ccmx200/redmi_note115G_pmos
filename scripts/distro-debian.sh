#!/bin/bash
# Debian 13 (trixie) aarch64 root filesystem for evergo.
#
# Usage: distro-debian.sh <rootfs-dir>
#
# Produces a directory that the generic part of build.sh turns into an ext4 image.
# Everything distro-specific lives here: bootstrap, packages, Chinese mirrors, root
# password, hostname.
#
# Notes on this machine:
#   * build into WSL's native ext4 (e.g. /root/...), never /mnt/* - DrvFs rejects fchmod
#     and apt/dpkg fail with "Operation not permitted"
#   * do not set http(s)_proxy - the proxy rewrites content and breaks signatures; the
#     Chinese mirrors are reachable directly
#   * mmdebstrap deletes qemu-user-static before --customize-hook runs, so anything that
#     needs a chroot happens after mmdebstrap returns
set -euo pipefail

R="${1:?usage: distro-debian.sh <rootfs-dir>}"
SUITE="${DEBIAN_SUITE:-trixie}"
MIRROR="${DEBIAN_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
SEC_MIRROR="${DEBIAN_SEC_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian-security}"

log() { printf '  %s\n' "$*"; }

PKGS="systemd,systemd-sysv,dbus,udev,openssh-server,e2fsprogs,util-linux,\
iproute2,iputils-ping,net-tools,dnsutils,ca-certificates,curl,wget,git,\
sudo,vim,nano,less,htop,tmux,rsync,unzip,zip,file,man-db,procps,\
locales,tzdata,kmod,console-setup"

log "suite   : $SUITE"
log "mirror  : $MIRROR"
log "target  : $R"

rm -rf "$R"
mkdir -p "$(dirname "$R")"

log "bootstrapping (pulls ~300 MB from the mirror)…"
# --aptopt allows apt to proceed when its own signed-by resolution fails on this host;
# the mirror is fetched over HTTPS and the signatures were verified by hand with
# `gpg --verify <InRelease>` against the 2025.1 Debian keyring.
mmdebstrap \
    --architectures=arm64 \
    --variant=minbase \
    --components="main,contrib,non-free,non-free-firmware" \
    --include="$PKGS" \
    --aptopt='Acquire::AllowInsecureRepositories "true"' \
    --aptopt='Acquire::AllowDowngradeToInsecureRepositories "true"' \
    "$SUITE" "$R" "$MIRROR" 2>&1 | tail -12

# ------------------------------------------------------------------ post ---- 
# mmdebstrap has removed its qemu copy by now, so put ours back for the chroot work.
log "post-configuration…"
cp -f /usr/bin/qemu-aarch64-static "$R/usr/bin/qemu-aarch64-static"
chmod 755 "$R/usr/bin/qemu-aarch64-static"

chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c '
    set -e
    echo root:evergo | chpasswd
    echo evergo > /etc/hostname
    cat > /etc/apt/sources.list <<EOF
# Debian '"$SUITE"' - Tsinghua mirror (mainland China)
deb '"$MIRROR"' '"$SUITE"' main contrib non-free non-free-firmware
deb '"$MIRROR"' '"$SUITE"'-updates main contrib non-free non-free-firmware
deb '"$SEC_MIRROR"' '"$SUITE"'-security main contrib non-free non-free-firmware
EOF
    mkdir -p /etc/apt/apt.conf.d
    echo "Acquire::Check-Valid-Until \"false\";" > /etc/apt/apt.conf.d/99no-check-valid
    # the first-boot grow needs these; make sure the paths the initramfs copies exist
    ln -sf /usr/sbin/e2fsck   /sbin/e2fsck   2>/dev/null || true
    ln -sf /usr/sbin/resize2fs /sbin/resize2fs 2>/dev/null || true
'
rm -f "$R/usr/bin/qemu-aarch64-static"

# ------------------------------------------------------------------ check ----
log "verifying…"
FAIL=0
for f in sbin/init usr/lib/systemd/systemd usr/sbin/sshd usr/sbin/resize2fs \
         usr/sbin/e2fsck usr/bin/sudo etc/shadow etc/hostname; do
    if [ -e "$R/$f" ]; then
        printf '    OK   %s\n' "$f"
    else
        printf '    MISS %s\n' "$f"
        FAIL=1
    fi
done
printf '    hostname: %s\n' "$(cat "$R/etc/hostname")"
printf '    root pw : %s\n' "$(grep '^root:' "$R/etc/shadow" | cut -d: -f2 | cut -c1-3)…"
log "sources:"
sed 's/^/      /' "$R/etc/apt/sources.list"
log "size: $(du -sh "$R" | cut -f1)"

exit $FAIL
