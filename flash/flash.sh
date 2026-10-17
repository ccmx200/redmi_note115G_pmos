#!/usr/bin/env bash
# Flash the evergo images from a Linux/macOS host.
#
# boot.img alone is sufficient - it carries the rootfs and installs it on first
# boot. Pass --with-userdata to also write the filesystem directly.
set -euo pipefail

cd "$(dirname "$0")/.."

WITH_USERDATA=0
[ "${1:-}" = "--with-userdata" ] && WITH_USERDATA=1

[ -f out/boot.img ] || { echo "out/boot.img missing - run build.sh first"; exit 1; }

echo "== checking for the device"
fastboot devices

echo "== flashing boot_b"
fastboot flash boot_b out/boot.img

if [ "$WITH_USERDATA" = 1 ]; then
    [ -f out/userdata.img ] || gunzip -kf out/userdata.img.gz
    echo "== flashing userdata (this wipes Android user data)"
    fastboot flash userdata out/userdata.img
fi

echo "== switching to slot b"
fastboot --set-active=b
fastboot reboot

cat <<'EOF'

== after reboot

The phone runs mainline Linux with no on-screen console. Plug it into a PC and
open the new serial port at 115200 8N1; you will get a root shell.

The first boot formats the userdata region and copies the rootfs, which takes
about a minute. Later boots go straight to the shell.

To return to Android:
    fastboot --set-active=a
(Android will then want to format data, because userdata was repurposed.)
EOF
