# Vendor-image archaeology: possible projects for evergo mainline

Source: stock ROM `evergo_images_V14.0.4.0.TGBCNXM_13.0` (HyperOS
V14.0.4.0.TGBCNXM, Android 13).  Everything below is read-only analysis of
those images; nothing here changes the running mainline system.

## 1. Vendor DTB (boot.img / dtbo.img) — done

`boot.img` has one appended FDT at offset 37253184 (169861 bytes); `dtbo.img`
is an Android DTBO table with one overlay entry (102661 bytes).  Extracted and
decompiled with the kernel's own `dtc`; results in `/root/rom/*.dts`.

Interesting nodes in the vendor DTB:

| node | address | notes |
|:---|:---|:---|
| `scp@10500000` | SCP SRAM 0xc0000, cfgreg 0x10724000, clkreg 0x10721000 | 5 mailboxes (0x107fb000..0x107ff000), IRQs: ipc0/ipc1 + mbox0..4 (229..231), `scp_sramSize = 0xc0000` |
| `reserve-memory-scp_share` | size 0x320000, alloc range 0x50000000 | SCP <-> AP shared memory |
| `sspm@10400000` | SSPM base + 5 mailboxes | share memory 0x510000 |
| `mcupm@0c540000` | MCUPM base + 8 mailboxes | share memory 0x610000 |
| `mali@13000000` | GPU | vendor compatible `mediatek,mt6833-mali`; mainline already binds `arm,mali-valhall-jm` |
| `dpmaif@10014000` | modem data path | MTK modem AP interface |
| dtbo: `panel1@0` | `k16a_36_02_0a_vdo,lcm` | panel + `lcm-bl-enable-gpios` |

Firmware images themselves identify their cores: `scp.img` header
`tinysys-scp-RV55_A`, `mcupm.img` `tinysys-mcupm-RV33_A`, `sspm.img`
`tinysys-sspm` — i.e. the whole TinySys coprocessor family on MT6833 is
**RISC-V**, and the images are in MediaTek's proprietary FW container
(magic `0x58881688`), not ELF.

## 2. super.img — unpacked, hardware inventory

`super.img` is Android sparse (7.4 GiB -> 9.1 GiB raw).  `scripts/lpunpack.py`
(pure python, no AOSP tools) parses the LP metadata and extracts the logical
partitions: `system_a`, `system_ext_a`, `product_a`, `vendor_a`, `mi_ext_a`
(the `_b` slots are empty).

Findings from `vendor_a`:

* Sensors: `/vendor/etc/sensors/hals.conf` +
  `lib64/hw/sensors.mt6833.so`, `lib64/libsensor_custom.so` — the latter two
  contain the strings `tsl2522` and `lsm6dso`, confirming the ALS and IMU are
  driven through the SCP sensor hub (the HAL only forwards IPI requests).
  No AP-side register tables and no sensor calibration file in `vendor`.
* NFC: **no NFC hardware** — only framework stubs (`com.android.nfc_extras`)
  and the "MIpay_NO_NFC" apps; no NFC HAL/library or firmware.
* Fast charge: no `sc8551` / `ln8000` / `mp2762` / `bq25970` strings anywhere
  in vendor/system, so charging is handled by MT6360 alone (vendor calls it
  33 W "turbo charge", but there is no separate charge-pump/divider IC to
  port).
* Camera: only `imx355` is discoverable in the camera custom libs (front
  sensor); the rear sensors are compiled into the ISP sensor libraries.
* `ro.hardware.vulkan = mali`, `ro.hardware.egl = meow`.

## 3. GPU (Panfrost) — already working, nothing to port

`CONFIG_DRM_PANFROST=y` is already in `config/evergo.config`, and the mainline
DTS has `gpu@13000000` with `arm,mali-valhall-jm`.  Boot log:

```
panfrost 13000000.gpu: mali-g57 id 0x9093 major 0x0 minor 0x1 status 0x0
panfrost 13000000.gpu: Features: L2:0x08130206 Shader:0x00000000 ...
[drm] Initialized panfrost 1.6.0 for 13000000.gpu on minor 1
```

`/dev/dri/renderD128` exists and phoc renders through it.  No vendor firmware
file is needed for this GPU.  So project "enable GPU" reduces to "it is
already enabled".

## 4. SCP sensor hub on mainline — blocked (needs a new driver)

Why it is not a small job:

* mainline `drivers/remoteproc/mtk_scp.c` only supports **ARM Cortex-M4**
  SCPs (`mediatek,mt8183/8186/8188/8192/8195-scp`) and loads **ELF32**
  firmware (`scp_elf_load_segments`, section-based IPI buffer address lookup).
* MT6833's SCP is a **RISC-V RV55** core (see `scp.img` header
  `tinysys-scp-RV55_A`) and its firmware is a raw MediaTek TinySys container
  with header magic `0x58881688`, load address 0x10700000, and no ELF
  sections.
* The vendor kernel does not drive the chip either: `alspshub.c` only sends
  IPI commands to SCP; the sensor register sequences live inside `scp.img`
  (that is exactly how we recovered the TSL2522 one).

A mainline port would need: a RISC-V TinySys loader/remoteproc driver, the
SCP IPI mailbox driver and table, the `sensorhub` IPI client protocol, plus
SCP power-domain/clock handling for MT6833 — i.e. a new subsystem-sized
driver, not a DT patch.  **Verdict: not feasible in this round.**

## 5. Suspend / deep idle — s2idle works, resume is broken

* `mem_sleep` defaults to `s2idle`.
* With the 31 s `mtk-wdt` disarmed (`/usr/lib/systemd/system-sleep/50-evergo-watchdog`
  stops `evergo-watchdog.service` and magic-closes `/dev/watchdog0`), a raw
  `echo mem > /sys/power/state` succeeds: `suspend_stats` shows
  `success=2`, `fail=0`, `PM: suspend entry (s2idle)` ... `PM: suspend exit`.
* RTC (`mt6359-rtc`) alarms can wake the system (`rtcwake -m no -s 120`);
  note the RTC runs with a wrong epoch on mainline (rtc `since_epoch` is
  ~2069, ~43 years ahead of system time), so the wake-up delay needs care.
* **The display does not come back after resume**: phoc re-commits the CRTC
  and hits the same failure as the blank/power-key bug —
  `vblank wait timed out on crtc 0`, `commit wait timed out`.  The screen
  stays dark (`dpms=Off`, backlight 2); injecting a volume-key event makes
  phoc set `dpms=On` and the panel comes back.
* Because of that, suspend is not usable yet: keep `enable-suspend=false`
  (already the default in `sm.puri.phosh`), and use the volume keys to wake
  the screen (that path works).

## 6. Other image-based ideas (not started)

* `md1img.img` (65 MB) — modem firmware; mainline has no CCCI/MDF/EMD driver,
  so calls/SMS/mobile data would be a months-scale port.
* `dpm.img` — TinySys display/platform firmware (tiny image, `dpmpm`
  strings); only relevant once the display power path is reworked.
* `cust.img` — Xiaomi region/APN/theme data; not useful for drivers.
* `tee.img`, `gz.img`, `lk.img`, `preloader_*` — boot chain / TEE; not
  applicable to mainline (and the bootloader is already replaced/flashed).
