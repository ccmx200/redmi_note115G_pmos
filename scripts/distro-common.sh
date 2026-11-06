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

# The caller extracts the rootfs here, but be defensive: a missing target must be
# an error, not a weird "No such file or directory" from cp three lines later.
[ -d "$R" ] || { echo "    !! rootfs dir $R does not exist"; exit 1; }

log() { printf '    %s\n' "$*"; }

TUNA_DEB="https://mirrors.tuna.tsinghua.edu.cn"
TUNA_FEDORA="https://mirrors.tuna.tsinghua.edu.cn/fedora"

# 宿主上有 qemu 才能 chroot 进 aarch64
QEMU=/usr/bin/qemu-aarch64-static
[ -x "$QEMU" ] || { echo "    !! $QEMU missing"; exit 1; }

# 官方 rootfs 里可能已经有自己的 qemu；无论如何拷一份进去
cp -f "$QEMU" "$R/usr/bin/qemu-aarch64-static"
chmod 755 "$R/usr/bin/qemu-aarch64-static"

# The maintainer scripts of systemd (and several others) need /proc and /sys: without
# them the systemd postinst dies with
#   Cannot open '/etc/machine-id' in neither writable nor read-only mode
# and dpkg leaves the whole transaction unconfigured.  Bind-mount the pseudo
# filesystems into the chroot for the whole package-install phase.
EVERGO_MOUNTS=""
for m in dev proc sys; do
    mkdir -p "$R/$m"
    if mount --bind "/$m" "$R/$m" 2>/dev/null; then
        EVERGO_MOUNTS="$R/$m $EVERGO_MOUNTS"
    fi
done
cleanup_mounts() {
    for m in $EVERGO_MOUNTS; do umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; done
}
trap cleanup_mounts EXIT

# chroot 里没有 init：让服务安装脚本直接跳过启动，而不是报错
mkdir -p "$R/usr/sbin"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"
chmod 755 "$R/usr/sbin/policy-rc.d"
# 给 systemd 一个合法的 machine-id，postinst 就不会去生成（qemu-user 下那一步会 ENOSYS）
printf '0123456789abcdef0123456789abcdef\n' > "$R/etc/machine-id"
chmod 444 "$R/etc/machine-id"

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
        EXTRA="main contrib non-free non-free-firmware"
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
    # The official rootfs tarball has no usable CA bundle and the build runs under
    # qemu-user, so apt's HTTPS peer check fails for every mirror ("certificate verify
    # failed") and no package index can be fetched.  Package metadata is still GPG
    # signed, so disable only the TLS peer/host verification for the build chroot.
    cat > "$R/etc/apt/apt.conf.d/99evergo-tls" <<'AC'
Acquire::https::Verify-Peer "false";
Acquire::https::Verify-Host "false";
AC

    log "apt update + upgrade + install"
    chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
        apt-get update
        $APT upgrade
        $APT full-upgrade
        # WiFi station mode (evergo-wifi) needs wpa_supplicant/iw/dhcpcd;
        # dhcpcd-base is the daemon package name on the Debian family.
        # systemd-timesyncd is the network clock source: ubuntu-base ships no NTP
        # client at all and the Debian minimbase has none either, so without this
        # package the phone boots with whatever the (unreliable) RTC said.  The
        # overlay then enables it and points it at good servers.
        $APT install --no-install-recommends \
            openssh-server e2fsprogs sudo curl wget ca-certificates \
            iproute2 iputils-ping net-tools less procps kmod tzdata \
            systemd-timesyncd \
            nano vim-tiny htop rsync unzip file man-db \
            wpasupplicant iw dhcpcd-base wireless-regdb \
            network-manager bluez bluez-obexd rfkill iio-sensor-proxy \
            fonts-noto-cjk fonts-noto-color-emoji locales alsa-utils alsa-ucm-conf
        $APT autoremove --purge
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
        locale-gen >/dev/null 2>&1 || true
        printf 'LANG=zh_CN.UTF-8\nLC_ALL=zh_CN.UTF-8\n' > /etc/default/locale
        echo root:evergo | chpasswd
        echo LANG=zh_CN.UTF-8 > /etc/locale.conf
        echo evergo > /etc/hostname
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl enable systemd-networkd 2>/dev/null || true
        systemctl enable systemd-timesyncd 2>/dev/null || true
    '

    # Snap: the images must ship snapd already installed and enabled, so
    # "snap install snap-store" works on first boot without apt-get first.
    log "preinstall snapd"
    chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        APT=\"apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold\"
        apt-get update
        \$APT install --no-install-recommends snapd
        systemctl enable snapd.socket snapd.service 2>/dev/null || true
        apt-get clean
        rm -rf /var/lib/apt/lists/*
    "

    DESKTOP_APT_FLAGS="--no-install-recommends"
    case "${EVERGO_EDITION:-minimal}" in
    desktop|xfce|phosh)
        if [ "$KIND" != ubuntu ]; then
            echo "  !! the $EVERGO_EDITION edition is only implemented for ubuntu"; exit 1
        fi
        if [ "$EVERGO_EDITION" = phosh ]; then
            log "phosh edition: touch-first mobile desktop (Wayland/phoc) + Chinese"
            PKGS="gdm3 phosh phoc squeekboard phosh-mobile-settings \
                  gnome-settings-daemon gnome-console gnome-text-editor nautilus \
                  upower gnome-control-center \
                  epiphany-browser gnome-calculator gnome-clocks eog evince totem \
                  file-roller gnome-screenshot gnome-characters gnome-disk-utility \
                  gnome-contacts gnome-calendar dconf-cli \
                  language-pack-zh-hans language-pack-gnome-zh-hans \
                  language-pack-gnome-zh-hans-base ibus ibus-libpinyin \
                  fonts-noto-cjk fonts-noto-color-emoji"
        elif [ "$EVERGO_EDITION" = xfce ]; then
            log "xfce edition: XFCE + LightDM + Chinese language/input"
            PKGS="xfce4-panel xfwm4 xfdesktop4 xfce4-session xfce4-settings \
                  xfce4-terminal thunar thunar-volman lightdm lightdm-gtk-greeter \
                  dbus-x11 xserver-xorg xserver-xorg-input-libinput \
                  xserver-xorg-video-fbdev xinit x11-xserver-utils \
                  language-pack-zh-hans language-pack-gnome-zh-hans ibus-libpinyin \
                  fonts-noto-cjk fonts-noto-color-emoji"
        else
            # The full "apt install ubuntu-desktop" experience: keep recommends so
            # the GNOME application set comes in, but pin out the snap-only
            # packages (snapd cannot work in a chroot and is not wanted on the
            # image; firefox/thunderbird are snap transition packages).
            log "desktop edition: full Ubuntu GNOME (ubuntu-desktop) + Chinese"
            PKGS="ubuntu-desktop \
                  gnome-system-monitor upower power-profiles-daemon \
                  language-pack-zh-hans language-pack-gnome-zh-hans \
                  ibus ibus-libpinyin fonts-noto-cjk fonts-noto-color-emoji"
            DESKTOP_APT_FLAGS=""
            mkdir -p "$R/etc/apt/preferences.d"
            cat > "$R/etc/apt/preferences.d/99-evergo-no-snap" <<'PREF'
Package: firefox thunderbird
Pin: release *
Pin-Priority: -1
PREF
        fi
        chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c "
            set -e
            export DEBIAN_FRONTEND=noninteractive
            APT=\"apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold\"
            # the main install block above ends with apt-get clean + rm -rf
            # /var/lib/apt/lists, so refresh the indexes before installing the desktop
            apt-get update
            \$APT install $DESKTOP_APT_FLAGS $PKGS
            apt-get clean
            rm -rf /var/lib/apt/lists/*
        "
        ;;
    esac
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
sslverify=0
countme=0

[updates]
name=Fedora Updates - Tsinghua mirror
baseurl=$TUNA_FEDORA/updates/\$releasever/Everything/aarch64/
enabled=1
gpgcheck=0
sslverify=0
countme=0
EOF
    log "dnf upgrade + install"
    chroot "$R" /usr/bin/qemu-aarch64-static /bin/sh -c '
        set -e
        dnf -y --refresh upgrade || true
        # WiFi station mode (evergo-wifi) needs wpa_supplicant/iw/dhcpcd;
        # wireless-regdb provides the signed regulatory.db for cfg80211.
        dnf -y install openssh-server e2fsprogs sudo curl wget ca-certificates \
            iproute iputils less procps-ng kmod tzdata nano vim-minimal \
            htop rsync unzip file man-db \
            wpa_supplicant iw dhcpcd wireless-regdb \
            NetworkManager NetworkManager-tui bluez rfkill \
            google-noto-sans-cjk-fonts glibc-langpack-zh alsa-utils alsa-ucm || true
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
# NetworkManager is wanted on these images (nmtui/nmcli); usb0 is marked unmanaged in
# /etc/NetworkManager/conf.d/10-evergo-usb0.conf so it cannot take the SSH link away.
for u in \
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
# The install-time machine-id was only there to satisfy systemd's postinst.  Leave it
# empty so the device generates its own on first boot, and drop the install-time
# policy-rc.d (it would block service starts if it ever survived into the image).
: > "$R/etc/machine-id"
chmod 644 "$R/etc/machine-id"
rm -f "$R/usr/sbin/policy-rc.d"

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
# The network clock and the periodic trim are configured by the overlay, but the
# tools themselves come from the packages: warn (do not fail) when a base image
# stops shipping them, so the problem is visible in the build log.
if [ -e "$R/usr/lib/systemd/system/systemd-timesyncd.service" ] || \
   [ -e "$R/lib/systemd/system/systemd-timesyncd.service" ]; then
    log "OK   systemd-timesyncd present"
else
    log "WARN systemd-timesyncd missing (no network clock source)"
fi
if [ -e "$R/usr/lib/systemd/system/fstrim.timer" ] || \
   [ -e "$R/lib/systemd/system/fstrim.timer" ]; then
    log "OK   fstrim.timer present"
else
    log "WARN fstrim.timer missing (no periodic SSD/eMMC trim)"
fi
[ "$FAIL" -eq 0 ] || { echo "    !! verification failed"; exit 1; }
log "size: $(du -sh "$R" | cut -f1)"
