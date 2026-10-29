#!/bin/bash
# 通用部分：把一个解压好的官方 rootfs 目录配置成可启动的 evergo 镜像。
#
# 用法（由 distro-*.sh 调用）：
#   rootfs_common_config <rootfs-dir> <distro-kind>
#
#   distro-kind: debian | ubuntu | fedora
#
# 做的事：
#   * 设 root 密码 evergo、主机名 evergo
#   * 把包管理器源指向国内镜像
#   * 装 e2fsprogs（initramfs 需要 e2fsck/resize2fs 及其库）
#   * 装一个基础工具集
#   * enable sshd / systemd-networkd
#   * 清理
set -euo pipefail

R="${1:?usage: rootfs_common_config <rootfs-dir> <kind>}"
KIND="${2:?kind required}"

log() { printf '    %s\n' "$*"; }

TUNA_DEB="https://mirrors.tuna.tsinghua.edu.cn"
TUNA_FEDORA="https://mirrors.tuna.tsinghua.edu.cn/fedora"

# 宿主上有 qemu 才能 chroot 进 aarch64
QEMU=/usr/bin/qemu-aarch64-static
[ -x "$QEMU" ] || { echo "    !! $QEMU missing"; exit 1; }

# 官方 rootfs 里可能已经有自己的 qemu；无论如何拷一份进去
cp -f "$QEMU" "$R/usr/bin/qemu-aarch64-static"
chmod 755 "$R/usr/bin/qemu-aarch64-static"

# DNS 在 qemu-user chroot 里不可靠，pin 镜像 IP
for h in mirrors.tuna.tsinghua.edu.cn; do
    ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$ip" ] && ip=$(getent hosts "$h" 2>/dev/null | awk '$1 ~ /^[0-9]+\./ {print $1; exit}')
    [ -n "$ip" ] && echo "$ip $h" >> "$R/etc/hosts" && log "pinned $h -> $ip"
done
printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$R/etc/resolv.conf"

case "$KIND" in
debian|ubuntu)
    if [ "$KIND" = "debian" ]; then
        SUITE=trixie
        MIRROR="$TUNA_DEB/debian"
        SEC="$TUNA_DEB/debian-security"
        EXTRA="contrib non-free non-free-firmware"
    else
        SUITE=resolute
        MIRROR="$TUNA_DEB/ubuntu-ports"
        SEC="$TUNA_DEB/ubuntu-ports"
        EXTRA="main restricted universe multiverse"
    fi

    mkdir -p "$R/etc/apt/sources.list.d"
    rm -f "$R"/etc/apt/sources.list.d/*.sources "$R"/etc/apt/sources.list.d/*.list 2>/dev/null || true
    cat > "$R/etc/apt/sources.list" <<EOF
# $KIND $SUITE - Tsinghua mirror (mainland China)
deb $MIRROR $SUITE $EXTRA
deb $MIRROR $SUITE-updates $EXTRA
deb $SEC $SUITE-security $EXTRA
EOF
    mkdir -p "$R/etc/apt/apt.conf.d"
    echo 'Acquire::ForceIPv4 "true";' > "$R/etc/apt/apt.conf.d/99force-ipv4"
    echo 'Acquire::Check-Valid-Until "false";' > "$R/etc/apt/apt.conf.d/99no-check-valid"

    log "apt update + upgrade + install"
    chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
        apt-get update
        $APT upgrade
        $APT full-upgrade
        $APT install --no-install-recommends \
            openssh-server e2fsprogs sudo curl wget ca-certificates \
            iproute2 iputils-ping net-tools less procps kmod tzdata \
            nano vim-tiny htop rsync unzip file man-db
        $APT autoremove --purge
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        echo root:evergo | chpasswd
        echo evergo > /etc/hostname
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl enable systemd-networkd 2>/dev/null || true
    '
    ;;
fedora)
    rm -f "$R"/etc/yum.repos.d/*.repo
    mkdir -p "$R/etc/yum.repos.d"
    cat > "$R/etc/yum.repos.d/fedora.repo" <<EOF
[fedora]
name=Fedora - Tsinghua mirror
baseurl=$TUNA_FEDORA/releases/\$releasever/Everything/aarch64/os/
enabled=1
gpgcheck=0
countme=0

[updates]
name=Fedora Updates - Tsinghua mirror
baseurl=$TUNA_FEDORA/updates/\$releasever/Everything/aarch64/
enabled=1
gpgcheck=0
countme=0
EOF
    log "dnf upgrade + install"
    chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c '
        set -e
        dnf -y --refresh upgrade || true
        dnf -y install openssh-server e2fsprogs sudo curl wget ca-certificates \
            iproute iputils less procps-ng kmod tzdata nano vim-minimal \
            htop rsync unzip file man-db || true
        dnf -y clean all
        echo root:evergo | chpasswd
        echo evergo > /etc/hostname
        systemctl enable sshd 2>/dev/null || true
        systemctl enable systemd-networkd 2>/dev/null || true
    '
    ;;
*)
    echo "    !! unknown kind $KIND"
    exit 1
    ;;
esac

rm -f "$R/usr/bin/qemu-aarch64-static"

# systemd-networkd 要接管 usb0；NetworkManager 会抢，mask 掉
mkdir -p "$R/etc/systemd/system"
for u in NetworkManager.service NetworkManager-wait-online.service \
         systemd-networkd-wait-online.service cloud-init.service \
         cloud-init-local.service cloud-config.service cloud-final.service \
         ubuntu-advantage.service ua-reboot-cmds.service ua-timer.timer \
         apt-daily.service apt-daily-upgrade.service unattended-upgrades.service; do
    if [ -e "$R/usr/lib/systemd/system/$u" ] || [ -e "$R/lib/systemd/system/$u" ] || [ -e "$R/etc/systemd/system/$u" ]; then
        ln -sf /dev/null "$R/etc/systemd/system/$u"
    fi
done

# hosts / hostname / machine-id
printf '127.0.0.1   localhost\n::1         localhost\n127.0.1.1   evergo\n' > "$R/etc/hosts"
printf 'evergo\n' > "$R/etc/hostname"
[ -e "$R/etc/machine-id" ] && : > "$R/etc/machine-id"

# 验证
FAIL=0
for f in usr/sbin/sshd usr/sbin/e2fsck usr/sbin/resize2fs usr/lib/systemd/systemd; do
    if [ -e "$R/$f" ]; then log "OK   /$f"; else log "MISS /$f"; FAIL=1; fi
done
ROOT_HASH=$(awk -F: '$1 == "root" {print $2}' "$R/etc/shadow" 2>/dev/null || true)
case "$ROOT_HASH" in
    \$*\$*) log "OK   root password set" ;;
    *)      log "MISS root password"; FAIL=1 ;;
esac
[ "$FAIL" -eq 0 ] || { echo "    !! verification failed"; exit 1; }
log "size: $(du -sh "$R" | cut -f1)"
