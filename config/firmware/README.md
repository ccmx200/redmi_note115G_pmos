# MediaTek CONN/WMT firmware for the evergo

Vendor firmware blobs for the MT6833's integrated CONN subsystem (MT6631,
"SOC2_1X1" chip family, AXI bus).  They are the files the stock evergo firmware
keeps in `/lib/firmware`; the copies here come from the initramfs image the WiFi
bring-up was tested with (`/root/initramfs-good/lib/firmware` on the build host).

`build.sh` stages these blobs plus the freshly built
`mt6833-xiaomi-evergo.dtb` in `out/work/fw` and points
`CONFIG_EXTRA_FIRMWARE` / `CONFIG_EXTRA_FIRMWARE_DIR` there.  The WMT stack is
built into the kernel and fetches them before the rootfs exists, so they end up
embedded in `boot.img` - the rootfs needs no `/lib/firmware` copy.

| file | used by |
|:---|:---|
| `WIFI_RAM_CODE_soc2_2_1a_1.bin` | gen4m WLAN firmware (1a variant) |
| `WIFI_RAM_CODE_soc2_2_1_1.bin` | gen4m WLAN firmware (1 variant) |
| `soc2_2_ram_mcu_1a_1_hdr.bin` | CONN MCU RAM code (1a) |
| `soc2_2_ram_mcu_1_1_hdr.bin` | CONN MCU RAM code (1) |
| `soc2_2_ram_wifi_1_1_hdr.bin` | WLAN section header |
| `soc2_2_ram_bt_1_1_hdr.bin` | BT section header |
| `WMT_SOC.cfg` | WMT/STP UART or bus configuration |
| `wifi.cfg` | WLAN configuration |
| `txpowerctrl.cfg` | per-band TX power limits |

Keep the names as-is: the vendor driver requests them by name (no subdirectory).

These are vendor binaries and are not covered by this repository's GPL-2.0
license; they are redistributed only so that a matching `boot.img` can be
rebuilt.
