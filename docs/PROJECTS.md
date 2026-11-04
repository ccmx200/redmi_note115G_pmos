# Vendor-image archaeology and follow-ups for evergo mainline

Source: stock ROM `evergo_images_V14.0.4.0.TGBCNXM_13.0` (HyperOS
V14.0.4.0.TGBCNXM, Android 13).  Everything below is read-only analysis of
those images plus the resulting mainline changes; the images themselves are
not needed any more except as reference.

## 1. Vendor DTB (boot.img / dtbo.img) — done

* `boot.img` has one appended FDT at offset 37253184 (169861 bytes).
* `dtbo.img` is an Android DTBO table with one overlay entry (102661 bytes).
* Extracted with a small script and decompiled with the kernel's own `dtc`.
* DTB contents (`/root/rom/boot37253184.dts`, `dtbo0.dts` on the build host):

| node | details |
|:---|:---|
| `scp@10500000` | SRAM 0x10500000 + 0xc0000; cfgreg 0x10724000, clkreg 0x10721000, cfgreg core0/core1 0x10730000/0x10740000, bus tracker 0x10752000, L1C 0x10760000, sec 0x107a5000; **5 mailboxes** at 0x107fb000, 0x107fc000, 0x107fd000, 0x107fe000, 0x107ff000; IRQs 0x1b2/0x1b3 (ipc0/ipc1) + 0x1b4..0x1b8 (mbox0..4); `scp_sramSize = 0xc0000` |
| `reserve-memory-scp_share` | no-map, 0x320000, alloc range 0x50000000-0x90000000 |
| `sspm@10400000` | SSPM base + 5 mailboxes, share 0x510000 |
| `mcupm@0c540000` | MCUPM base + 8 mailboxes, share 0x610000 |
| `mali@13000000` | GPU, vendor compatible `mediatek,mt6833-mali` |
| `dpmaif@10014000` | modem data path (MTK modem AP interface) |
| `panel1@0` (dtbo) | `k16a_36_02_0a_vdo,lcm` (Tianma K16A), `lcm-bl-enable-gpios = <&pio 0x57>` |
| `panel2@0` (dtbo) | `k16a_42_02_0b_vdo,lcm` (CSOT K16A) |
| `novatek@0` (dtbo) | NT36672C SPI touch: reset GPIO13, IRQ GPIO14, `swrst-n8-addr=0x3f0fe`, `spi-rd-fast-addr=0x3f310` |

Conclusion for mainline: the panel (both K16A variants), the Novatek NT36672C
touch wiring and the GPU are already represented in the mainline DTS
(`mt6833-xiaomi-evergo.dts` + `panel-k16a-vdo.c`); the remaining vendor nodes
are the TinySys coprocessors, covered below.

## 2. super.img — unpacked, complete hardware inventory

`super.img` is Android sparse (7.4 GiB -> 9.1 GiB raw).  `scripts/lpunpack.py`
(pure python, no AOSP tools) parses the LP metadata and extracts the logical
partitions: `system_a`, `system_ext_a`, `product_a`, `vendor_a`, `mi_ext_a`;
the `_b` slots are empty.

Inventory from `vendor_a` / `system_a`:

* **SoC coprocessors**: all TinySys firmwares are RISC-V — `scp.img`
  (`tinysys-scp-RV55_A`), `mcupm.img` (`tinysys-mcupm-RV33_A`), `sspm.img`
  (`tinysys-sspm`).  They use MediaTek's raw FW container (magic `0x58881688`),
  not ELF.
* **Sensors**: `/vendor/etc/sensors/hals.conf` plus
  `lib64/hw/sensors.mt6833.so`, `lib64/libsensor_custom.so`.  Strings found:
  `TSL2522 LIGHT`, `lsm6dso_acc`, `lsm6dso_gyro`, `LSM6DSO ACCELEROMETER`,
  `LSM6DSO GYROSCOPE`, `akm09918`, `AKM09918 MAGNETOMETER`.  These are
  configured by the SCP sensor-hub firmware; there are no AP-side register
  tables and no calibration file in `vendor`.
* **Cameras**: `libCamera_s5kjn1sunnymipiraw_*` (main 50 MP Samsung S5KJN1),
  `ov8856` (8 MP ultra-wide), `ov02`/`gc02` (2 MP macro variants),
  `imx355ofilm_mipi_raw_*` (16 MP front, Sony IMX355).  Tuning data under
  `/vendor/etc/camera` (`goldResult_K16B_*.bin`, `LDC_packdata_xiaomi.dat`,
  `sceneDetection.xml`, `sr_params.xml`, `vidhance_calibration`, ...).
* **NFC**: *no hardware*.  Only framework stubs (`com.android.nfc_extras`)
  and the `MIpay_NO_NFC` / `MITSMClientNoneNfc` apps; no NFC HAL, library or
  firmware.
* **Charging**: no `sc8551`/`ln8000`/`mp2762`/`bq25970` anywhere in
  vendor/system, so charging is handled by MT6360 alone (no separate
  charge-pump/divider IC to port).
* **Audio**: full AudioFlinger policy set (`audio_policy_configuration.xml`,
  `audio_policy_volumes.xml`, `audio_device.xml`, `audio_param*`,
  `audio_effects.xml`, A2DP/BT offload configs).
* **Thermal**: 15 profiles (`thermal-normal.conf`, `thermal-phone.conf`,
  `thermal-mgame.conf`, `thermal-camera.conf`, `thermal-chg-only.conf`, ...).
* **Connectivity firmware**: `WIFI_RAM_CODE_soc2_2_*`, `soc2_2_ram_bt_*`,
  `BT_FW.cfg`, `wifi.cfg` (MT6631/MT6635 combo, one of which mainline uses).
* **GPU**: `ro.hardware.vulkan = mali`, `ro.hardware.egl = meow`.

## 3. GPU (Panfrost) — already working, nothing to port

`CONFIG_DRM_PANFROST=y` is already in `config/evergo.config`, and the mainline
DTS has `gpu@13000000` with `arm,mali-valhall-jm`.  Boot log:

```
panfrost 13000000.gpu: mali-g57 id 0x9093 major 0x0 minor 0x1 status 0x0
panfrost 13000000.gpu: [drm] Initialized panfrost 1.6.0 for 13000000.gpu
```

`/dev/dri/renderD128` exists and phoc renders through it; no vendor firmware
file is needed.  So project "enable GPU" is already done.

## 4. SCP sensor hub on mainline — blocked (needs a new driver)

* mainline `drivers/remoteproc/mtk_scp.c` supports only **ARM Cortex-M4** SCPs
  (`mediatek,mt8183/8186/8188/8192/8195-scp`) and loads **ELF32** firmware
  (`scp_elf_load_segments`, section-based IPI buffer lookup).
* MT6833's SCP is a **RISC-V RV55** core with a raw MediaTek TinySys image
  (header magic `0x58881688`, load address 0x10700000) and no ELF sections.
* The vendor kernel does not drive the chip either: `alspshub.c` only sends
  IPI commands; the sensor register sequences live inside `scp.img` (this is
  how the TSL2522 sequence was recovered for the mainline IIO driver).

A port would need a RISC-V TinySys loader/remoteproc driver, SCP IPI/mailbox
driver and table, the `sensorhub` IPI client protocol, and MT6833 SCP
power-domain/clock handling — a new subsystem-sized driver.  Not feasible now.

## 5. Power: RTC fixed, suspend still limited by DRM resume

### RTC (fixed and verified)

The RTC (`mt6397-rtc mt6359-rtc`, `rtc0`) was running with a bogus epoch
(2069-12-31) and there is no `hwclock` binary in the rootfs.  Fixes:

* `usr/local/bin/evergo-rtc-sync` — small python helper: `set` writes the
  system clock (UTC) to `/dev/rtc0` via `RTC_SET_TIME` ioctl, `show` prints
  the hardware time.
* `etc/systemd/system/evergo-rtc-sync.service` — `Type=oneshot`,
  `RemainAfterExit=yes`, runs `set` at boot (after `time-sync.target`) and
  again as `ExecStop` during shutdown, so the RTC stays in sync with the
  system clock (e.g. after NTP/phosh sets the time).

Verified on the device:

* `RTC set to 2026-11-04 06:48:48 UTC`, `sys_epoch == rtc_epoch`
  (`/sys/class/rtc/rtc0/since_epoch`);
* survives a clean reboot (kernel logs `setting system clock to
  2026-11-04T06:49:16 UTC`);
* `rtcwake -m no -s 30` arms the alarm and it fires ~31 s later
  (`wakealarm` clears, no spurious interrupts).

### Suspend (s2idle enters, display resume broken)

* With the 31 s `mtk-wdt` disarmed (sleep hook
  `usr/lib/systemd/system-sleep/50-evergo-watchdog` stops the feed service
  and magic-closes `/dev/watchdog0`), a raw `echo mem > /sys/power/state`
  succeeds: `suspend_stats success=5, fail=0` and
  `PM: suspend entry/exit (s2idle)` appear in the log.
* However the device wakes almost immediately unless WiFi/BT are blocked
  (connsys `mtk_wmt_suspend`/`resume` runs during suspend), and after a real
  sleep the **display does not come back**: phoc re-commits the CRTC and hits
  the same failure as the blank/power-key bug (`vblank wait timed out on
  crtc 0`, `commit wait timed out`).  A volume-key event makes phoc set
  `dpms=On` and the panel returns.
* Keep `enable-suspend=false` (already the default) until the DRM
  vblank/commit timeout is fixed; use the volume keys to wake the screen.

## 6. Other image-based ideas (not started)

* `md1img.img` (65 MB) — modem firmware; mainline has no CCCI/MDF/EMD driver,
  so calls/SMS/mobile data would be a months-scale port.
* `dpm.img` — TinySys display/platform firmware (`dpmpm` strings); only
  relevant once the display power path is reworked.
* `cust.img` — Xiaomi region/APN/theme data; not useful for drivers.
* `tee.img`, `gz.img`, `lk.img`, `preloader_*` — boot chain / TEE; not
  applicable to mainline.
