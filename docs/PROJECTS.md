# Vendor-image archaeology and follow-ups for evergo mainline

Source: stock ROM `evergo_images_V14.0.4.0.TGBCNXM_13.0` (HyperOS
V14.0.4.0.TGBCNXM, Android 13).  Everything below is read-only analysis of
those images plus the resulting mainline changes.

## 1. Vendor DTB (boot.img / dtbo.img) — done

* `boot.img` has one appended FDT at offset 37253184 (169861 bytes).
* `dtbo.img` is an Android DTBO table with one overlay entry (102661 bytes).
* Extracted with a small script and decompiled with the kernel's own `dtc`.

| node | details |
|:---|:---|
| `scp@10500000` | SRAM 0x10500000 + 0xc0000; cfgreg 0x10724000, clkreg 0x10721000, cfgreg core0/core1 0x10730000/0x10740000, bus tracker 0x10752000, L1C 0x10760000, sec 0x107a5000; **5 mailboxes** at 0x107fb000..0x107ff000; IRQs 0x1b2/0x1b3 (ipc0/ipc1) + 0x1b4..0x1b8 (mbox0..4); `scp_sramSize = 0xc0000` |
| `reserve-memory-scp_share` | no-map, 0x320000, alloc range 0x50000000-0x90000000 |
| `sspm@10400000` | SSPM base + 5 mailboxes, share 0x510000 |
| `mcupm@0c540000` | MCUPM base + 8 mailboxes, share 0x610000 |
| `mali@13000000` | GPU, vendor compatible `mediatek,mt6833-mali` |
| `dpmaif@10014000` | modem data path (MTK modem AP interface) |
| `panel1@0` (dtbo) | `k16a_36_02_0a_vdo,lcm` (Tianma K16A), `lcm-bl-enable-gpios = <&pio 0x57>` |
| `panel2@0` (dtbo) | `k16a_42_02_0b_vdo,lcm` (CSOT K16A) |
| `novatek@0` (dtbo) | NT36672C SPI touch: reset GPIO13, IRQ GPIO14, `swrst-n8-addr=0x3f0fe`, `spi-rd-fast-addr=0x3f310` |

Conclusion: the panel (both K16A variants), the Novatek NT36672C touch wiring
and the GPU are already represented in the mainline DTS; the remaining vendor
nodes are the TinySys coprocessors, covered below.

## 2. super.img — unpacked, complete hardware inventory

`super.img` is Android sparse (7.4 GiB -> 9.1 GiB raw).  `scripts/lpunpack.py`
(pure python, no AOSP tools) parses the LP metadata and extracts the logical
partitions: `system_a`, `system_ext_a`, `product_a`, `vendor_a`, `mi_ext_a`;
the `_b` slots are empty.

* **Coprocessors**: all TinySys firmwares are RISC-V — `scp.img`
  (`tinysys-scp-RV55_A`), `mcupm.img` (`tinysys-mcupm-RV33_A`), `sspm.img`
  (`tinysys-sspm`); raw MediaTek FW container (magic `0x58881688`), not ELF.
* **Sensors**: `lib64/hw/sensors.mt6833.so`, `lib64/libsensor_custom.so`
  contain `TSL2522 LIGHT`, `lsm6dso_acc`, `lsm6dso_gyro`,
  `LSM6DSO ACCELEROMETER/GYROSCOPE`, `akm09918`, `AKM09918 MAGNETOMETER`;
  all driven by the SCP sensor hub (no AP register tables/calibration files).
* **Cameras**: `S5KJN1` (50 MP main), `OV8856` (8 MP ultra-wide),
  `OV02`/`GC02` (2 MP macro), `IMX355` (16 MP front); tuning data under
  `/vendor/etc/camera`.
* **NFC**: no hardware (only framework stubs + `MIpay_NO_NFC` apps).
* **Charging**: no `sc8551`/`ln8000`/`mp2762`/`bq25970`; MT6360 only.
* **Audio**: full AudioFlinger policy set; **thermal**: 15 profiles;
  **connectivity**: `WIFI_RAM_CODE_soc2_2_*`, `soc2_2_ram_bt_*`, `BT_FW.cfg`.

## 3. GPU (Panfrost) — already working

`CONFIG_DRM_PANFROST=y`, DTS `gpu@13000000` with `arm,mali-valhall-jm`;
boot log shows `mali-g57 id 0x9093` and `/dev/dri/renderD128` exists.

## 4. SCP sensor hub — blocked (needs a new driver)

mainline `mtk_scp` only supports ARM Cortex-M4 + ELF firmware
(mt8183/8186/8188/8192/8195); MT6833's SCP is RISC-V RV55 with a raw TinySys
image.  The vendor kernel only sends IPI requests (`alspshub.c`); a port needs
a RISC-V TinySys remoteproc, SCP IPI/mailbox driver, sensorhub protocol and
MT6833 SCP power/clock support.  Not feasible in this round.

## 5. Display / DRM vblank path

Observed on the device (before/after the fix):

* `/proc/interrupts` shows the OVL, RDMA and DSI interrupts **stop
  incrementing** once the pipeline is running (e.g. dsi stayed at 277 for
  minutes), i.e. no vblank/frame-done IRQs are delivered in steady state.
* Consequently every atomic commit that waits for vblank times out:
  `vblank wait timed out on crtc 0`, `flip_done timed out`,
  `commit wait timed out`; a blanked screen stayed dark until another
  commit (volume-key event) was forced.
* Fix in `drm/mediatek` (`36427477a309`): in `mtk_crtc_atomic_disable()` do
  not call `drm_crtc_wait_one_vblank()` while tearing the pipeline down;
  call `drm_crtc_vblank_off()` first (it flushes pending vblank/commit
  events) and let `mtk_crtc_ddp_hw_fini()` complete the CRTC event.
  With this, power-key blanking no longer produces `commit wait timed out`.
* Still remaining: `drm_atomic_helper_wait_for_vblanks` warns after an
  unblank, because the vblank IRQ stream is still missing; fixing that needs
  the MTK display IRQ/mutex/TE setup to be reworked (the "evergo kick"
  workaround in `mtk_crtc.c` documents the state of that investigation).

## 6. Power key (Android-like screen off/on, no suspend)

`evergo-powerkey` (systemd service) reads `/dev/input/event1`
(`mtk-pmic-keys`) and on KEY_POWER toggles the display without touching DRM:

* screen off: save the current backlight, pause `ambient-enabled` (gsd would
  otherwise immediately raise the backlight again), lock the session
  (`org.gnome.ScreenSaver.SetActive(true)`), write backlight 0;
* screen on: restore the saved backlight, re-enable ambient brightness,
  unlock the session.

Also pinned on every boot by `evergo-session-config`: gsd
`power-button-action='nothing'`, `idle-dim=false`, `idle-delay=0`,
`ambient-enabled=true`; and `/etc/systemd/logind.conf.d/50-evergo.conf`
sets `HandlePowerKey=ignore` so nothing else acts on the key.

Verified with physical (ESP) short presses: backlight 200 -> 0 -> saved value,
session locked/unlocked, `dpms` stays On (no DRM disable), no suspend
(`PM: suspend entry` count unchanged), no new DRM timeouts.

## 7. RTC — fixed

`mt6397-rtc` was running with a bogus epoch (2069) and the rootfs has no
`hwclock`.  `evergo-rtc-sync` (python RTC_SET_TIME helper) +
`evergo-rtc-sync.service` write the system clock to `/dev/rtc0` at boot
(after `time-sync.target`) and at shutdown.  Verified: epoch matches the
system clock, survives a reboot (`setting system clock to 2026-11-04...`),
and `rtcwake -m no -s 30` fires ~31 s later.

## 8. Suspend (s2idle) — works mechanically, display resume still broken

With the 31 s watchdog disarmed (sleep hook `50-evergo-watchdog`) and WiFi/BT
blocked (otherwise connsys suspends/resumes immediately):

* `echo mem > /sys/power/state` enters s2idle and the RTC alarm wakes it:
  `suspend_stats success=1, fail=0`, `PM: suspend entry/exit (s2idle)`.
* After resume the display stays off (`dpms=Off`); a volume-key/power event
  re-enables it.  Because of that, suspend stays disabled by default
  (`sm.puri.phosh enable-suspend=false`) and the power key uses the
  backlight-toggle path above.

## 9. CPU idle

The mainline kernel registers the `menu` cpuidle governor but exposes no
cpuidle states (`/sys/devices/system/cpu/cpu0/cpuidle/` has no state
directories), so the CPUs only use the architectural WFI idle.  Deeper CPU
idle and real low-power standby depend on the s2idle/display issues above.

## 10. Other image-based ideas (not started)

* `md1img.img` (65 MB) — modem firmware; no CCCI/MDF/EMD driver in mainline,
  calls/SMS/data would be a months-scale port.
* `dpm.img` — TinySys display/platform firmware; relevant only once the
  display power path is reworked.
* `cust.img`, `tee.img`, `gz.img`, `lk.img`, `preloader_*` — not useful for
  the mainline port.
