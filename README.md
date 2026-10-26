# Redmi Note 11T 5G (evergo / MT6833) — Arch Linux ARM

Automated builds of mainline Linux for the Redmi Note 11T 5G (Xiaomi `evergo`,
MediaTek MT6833 / Dimensity 810), packaged so that flashing two images gives a
working **Arch Linux ARM** system.

Every release contains:

| file | what it is |
|---|---|
| `boot.img` | kernel 7.3-rc4 + a ~4 KB initramfs that mounts userdata and `switch_root`s into it |
| `userdata.img.gz` | Arch Linux ARM on a 6 GiB f2fs filesystem |
| `SHA256SUMS` | checksums |

## flash

```bash
fastboot flash boot_b  boot.img
gunzip -c userdata.img.gz | fastboot -S 200M flash userdata -   # or use userdata.simg
fastboot --set-active=b
fastboot reboot
```

Both images are needed. Reflashing `boot.img` alone never touches the rootfs, because
the initramfs only mounts the existing filesystem — it does not install one.

## reaching the phone

There is **no serial console**. The phone is a USB RNDIS network device:

```
plugged into a router's USB port   -> DHCP client, joins that LAN, has internet
plugged into a computer            -> always reachable at 169.254.42.1/16
```

So, with the phone on a USB port and nothing configured:

```bash
ssh root@169.254.42.1        # password: evergo
```

`169.254.42.1/16` is always present, which is what makes a plain PC work: Windows
falls back to an APIPA address on the same link when no DHCP server answers.

On the first login a wizard asks whether to create a normal user, then sets the
hostname and optionally changes the root password. **SSH accepts passwords only** —
key authentication is disabled (`PubkeyAuthentication no`).

Useful commands:

```bash
evergo-mode status      # show how usb0 is addressed
evergo-mode router      # DHCP client - for the router (default)
evergo-mode pc          # DHCP server - gives the computer 192.168.42.x
evergo-info             # one-screen system summary
```

## what works on hardware

| subsystem | state |
|---|---|
| mainline kernel 7.3.0-rc4 | works |
| RAM detection (4/6/8 GiB variants) | selected at build time |
| storage (128 GB eMMC) | works, f2fs on the userdata region |
| display / framebuffer console | works (`mediatekdrmfb`) |
| USB gadget networking (RNDIS) | works, high-speed, ~4.5 MB/s over scp |
| hardware watchdog | fed from userspace (`evergo-watchdog.service`) |
| Arch userspace | works, `pacman` functional |

Known gaps (the upstream bring-up tree is still in progress):

- the PMIC (MT6359) is not wired up, so regulators are modelled as fixed;
- the first video-mode switch reports `Wait DSI IRQ(0x00000008) Timeout` — expected
  and non-fatal, see the comment in `mtk_dsi.c`;
- USB host mode, WiFi, modem, audio and the touch panel firmware are not done.

## how it is built

`.github/workflows/build.yml` runs `build.sh`, which:

1. clones the kernel from [`ccmx200/linux-evergo`](https://github.com/ccmx200/linux-evergo)
   (branch `main`, a fork of
   [`KevinLmK0702/linux-evergo`](https://github.com/KevinLmK0702/linux-evergo)), or
   reuses an existing tree via `KERNEL_SRC`;
2. applies `config/evergo.config`, the kernel configuration validated on the handset;
3. rewrites four device-tree values for this handset: RAM size, panel variant,
   `maximum-speed = "high-speed"` for USB, and a trimmed command line;
4. builds the kernel and DTB;
5. builds the rootfs: the Arch Linux ARM tarball, pacman keyring initialised, packages
   installed, then `rootfs-overlay.tar.gz` unpacked over it (the `evergo-mode` and
   `evergo-info` helpers, the fastfetch welcome, the first-login wizard, the systemd
   units and the SSH policy);
6. packs `boot.img` and appends the AVB footer the bootloader requires.

Everything except the kernel build runs offline. Two things in the rootfs build are
worth knowing:

- **pacman's Landlock sandbox has to be disabled.** pacman 7.x sandboxes itself, but
  this kernel has `CONFIG_SECURITY_LANDLOCK` off, so every transaction fails with
  "restricting filesystem access failed". `DisableSandboxFilesystem` and
  `DisableSandboxSyscalls` in `pacman.conf` is an Arch-side switch, no kernel work.
- **DNS does not work inside the qemu-user chroot.** The aarch64 glibc resolver fails
  under emulation even though plain IP traffic works, so the mirror hostnames are
  pinned in `/etc/hosts` for the duration of the build and removed afterwards.

## pitfalls this repository exists to avoid

Each of these cost real debugging time; they are written down so nobody repeats them.

| symptom | cause |
|---|---|
| `bootreason=lk_crash`, reboots before any kernel output | the boot image header was built without the `name[16]` field, shifting `dtb_size` by 16 bytes |
| `Failed to execute /init (error -8)` | an x86-64 busybox was copied into the initramfs from the build host |
| reboots every 31 s | the hardware watchdog is armed by the bootloader and nothing fed it |
| `f2fs: Unknown parameter 'offset'` | `mount -o loop,offset=` is not supported for f2fs; use `losetup -o OFS` and mount the loop device |
| reboots every ~33 s after switching root | the initramfs re-opened `/dev/watchdog` after `/dev` was moved; hold the descriptor open across `switch_root` instead |
| `restricting filesystem access failed because Landlock is not supported` | pacman 7.x sandbox vs. a kernel without `CONFIG_SECURITY_LANDLOCK` |
| `Could not resolve host` inside the qemu chroot | aarch64 glibc's resolver under qemu-user; pin the mirror IPs |
| `PubkeyAuthentication no` seems ignored | `sshd_config` takes the **first** value it sees, so an earlier drop-in wins |
| `The source tree is not clean` on an `O=out` kernel build | in-tree `include/config` or `include/generated` left behind by an earlier in-tree build |
| a build's `rm -rf` walked into `/sys` | a stale bind mount under `out/work/rootfs`; unmount before removing the tree |

Also note the GPT on these handsets declares a 226 GiB `userdata` while the eMMC is
only 119 GiB; the initramfs therefore uses a loop over the raw disk rather than
formatting the partition directly.

## warning

Flashing `boot_b` and using the userdata region **destroys Android's user data**
(it is FBE-encrypted and unreadable from mainline anyway). `fastboot
--set-active=a` boots Android again, which will want to format data.

Nothing here is supported by Xiaomi or MediaTek. Use at your own risk.

## credits

- Kernel work by [KevinLmK0702](https://github.com/KevinLmK0702/linux-evergo);
  this repository only packages it and adapts it per variant.
- MT6833 mainline bring-up originated with the Poco M3 Pro 5G (camellia) work.
- Arch Linux ARM for the rootfs; `build-alpine.sh.orig` keeps the earlier Alpine build.
- Everything here is GPL-2.0, matching the kernel.
