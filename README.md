# Redmi Note 11T 5G (evergo / MT6833) - mainline Linux images

Automated builds of mainline Linux for the Redmi Note 11T 5G (Xiaomi `evergo`,
MediaTek MT6833 / Dimensity 810), packaged so that flashing two images gives a
working Alpine userspace.

Every release contains:

| file | what it is |
|---|---|
| `boot.img` | kernel 7.3-rc4 + initramfs installer. **Carries the rootfs inside it** and installs it on first boot. |
| `userdata.img.gz` | prebuilt ext4 rootfs, if you would rather flash the partition directly |
| `SHA256SUMS` | checksums |

## flash

```bash
fastboot flash boot_b  boot.img
fastboot --set-active=b
fastboot reboot
```

That is enough - on first boot the installer writes the carried rootfs onto the
userdata region and switches into it. If you prefer to flash the filesystem
yourself:

```bash
gunzip userdata.img.gz
fastboot flash userdata userdata.img
```

## console

There is no visible console on the panel during bring-up; the phone exposes a
**USB gadget serial port**. Plug it into a PC and a new COM port appears. Open it
at **115200 8N1**:

```bash
# Windows: use PuTTY / Tera Term on the new COM port
# Linux:
picocom -b 115200 /dev/ttyACM0
```

You land in a root shell.

## status

Working on hardware:

| subsystem | state |
|---|---|
| mainline kernel 7.3.0-rc4 | works |
| RAM detection (4/6/8 GiB variants) | selected at build time |
| UFS storage (128 GB) | works |
| display / framebuffer console | works (`mediatekdrmfb`) |
| USB gadget serial console | works |
| Alpine rootfs on userdata | works, `apk` functional |
| hardware watchdog | fed from userspace |

Known gaps (the upstream bring-up tree is still in progress):

- the PMIC (MT6359) is not wired up, so regulators are modelled as fixed;
- the first video-mode switch reports `Wait DSI IRQ(0x00000008) Timeout` - this
  is expected and non-fatal, see the comment in `mtk_dsi.c`;
- USB host mode, WiFi, modem, audio and the touch panel firmware are not done.

## how it is built

`.github/workflows/build.yml` runs `build.sh`, which:

1. clones the kernel from [`ccmx200/linux-evergo`](https://github.com/ccmx200/linux-evergo)
   (branch `bringup/evergo-mainline`, a fork of
   [`KevinLmK0702/linux-evergo`](https://github.com/KevinLmK0702/linux-evergo));
2. applies the exact kernel config the kernel author uses - it is extractable
   from their image because the kernel ships `/proc/config.gz`;
3. rewrites two device-tree values for this handset: RAM size and panel variant;
4. builds the kernel and DTB;
5. builds an ext4 rootfs from the Alpine minirootfs, adding a small PID 1
   (`/bin/evergo-init`) because the minirootfs has no openrc;
6. packs `boot.img` and appends the AVB footer the bootloader requires.

## pitfalls this repository exists to avoid

Each of these cost real debugging time; they are written down so nobody repeats
them.

| symptom | cause |
|---|---|
| `bootreason=lk_crash`, reboots before any kernel output | the boot image header was built without the `name[16]` field, shifting `dtb_size` by 16 bytes |
| `Failed to execute /init (error -8)` | an x86-64 busybox was copied into the initramfs from the build host |
| reboots every 31 s | the hardware watchdog is armed by the bootloader and nothing fed it |
| `losetup: unrecognized option: sizelimit` | busybox's losetup has no `--sizelimit`; a loop over the raw disk already stops at the end of the disk |
| `can't open /dev/wdt` | an `inittab` respawn entry whose id is not a tty |
| `can't run '/sbin/openrc'` | the Alpine minirootfs does not ship openrc |

Also note the GPT on these handsets declares a 226 GiB `userdata` while the UFS
LUN is only 119 GiB; the installer therefore uses a loop device over the raw disk
rather than formatting the partition directly.

## warning

Flashing `boot_b` and using the userdata region **destroys Android's user data**
(it is FBE-encrypted and unreadable from mainline anyway). `fastboot
--set-active=a` boots Android again, which will want to format data.

Nothing here is supported by Xiaomi or MediaTek. Use at your own risk.

## credits

- Kernel work by [KevinLmK0702](https://github.com/KevinLmK0702/linux-evergo);
  this repository only packages it and adapts it per variant.
- MT6833 mainline bring-up originated with the Poco M3 Pro 5G (camellia) work.
- Alpine Linux for the rootfs.
- Everything here is GPL-2.0, matching the kernel.
