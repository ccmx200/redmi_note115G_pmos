# 🔌 硬件支持与清单

设备：**Redmi Note 11T 5G**（`evergo` / `everpal`，MT6833 天玑 810，6×A55 + 2×A76，Mali-G57 MC2）。

## 支持矩阵

| 子系统 | 状态 | 备注 |
|:---|:---:|:---|
| 主控 / 存储 | ✅ | 128 GB eMMC，首次启动自动扩到 ~106 GiB |
| 显示 | ✅ | mediatek-drm + 90 Hz 面板；息屏/唤醒/resume 均已修 |
| 触摸 | ✅ | Novatek NT36672C（SPI，固件内嵌并按面板自动选择）；休眠唤醒后自动复位 |
| GPU | ✅ | Panfrost (Mali-G57)；电压固定 781250 µV / VSRAM 850 mV，DVFS 见 [KERNEL](KERNEL.md) |
| Wi-Fi | ✅ | MT6631 / gen4m + WMT，固件内嵌 boot.img |
| 蓝牙 | 🟡 | CONNSYS BT 核可通过 WMT 上电（HCI 5.1），但出厂地址主线读不到，BlueZ 暂不可用 |
| USB 网络 | ✅ | CDC-NCM，直连电脑 169.254.42.1，插路由器可上网 |
| SSH | ✅ | 密码登录（root/evergo），首次登录有配置向导 |
| 音频 | ✅ | MT6833 AFE + MT6359 codec + AW8697 功放；麦克风/耳机 |
| 振动 | ✅ | AW8697 |
| 充电 / 电量 | ✅ | MT6360 充电 + MT6359 库仑计；VBAT 改读 MT6360 ADC 并修正 OCV 表后，电压/容量/charge_now 均正确（详见 [KERNEL](KERNEL.md)） |
| 手电筒 / 闪光灯 | ✅ | MT6360 白闪 LED（`/sys/class/leds/white:flash-1`）；镜像内 `evergo-torch on/off/toggle/strobe/status` 可用 |
| RTC | ✅ | MT6359 RTC；开机/关机与定时保存，时间不丢 |
| 温度传感器/温控 | ✅ | MT6833 LVTS：13 个热区；CPU/GPU/SOC 带 passive cooling（80/90/100°C 降频），critical 115°C |
| CPU / GPU 调频 | ✅ | 已合入内核 `master`：CPU 小核 950 MHz–2.0 GHz / 大核 725 MHz–2.0 GHz，GPU 390–880 MHz；s2idle 已验证正常，满载由温控自动降频（~81°C 稳定） |
| CPU idle（PSCI） | 🚧 | 实验分支 `cpuidle-exp`：状态生效但压力/休眠下会挂，未合并，见 [KERNEL](KERNEL.md) |
| 休眠 s2idle | 🟡 | 已验证可进/出（DVFS 同时启用也正常），resume 后显示/触摸/调频恢复；默认不自动休眠 |
| 传感器 | 🟡 | AK09918 / TSL2522 / LSM6DSO 由 SCP RISC-V 传感器 hub 独占，主线无驱动 |
| 基带 / SIM | ❌ | 无 CCCI/MDF 驱动，通话/短信/数据暂不支持，见 [CAMERA-MODEM](CAMERA-MODEM.md) |
| 相机 | ❌ | sensor 驱动有，但无 camsys ISP/seninf 平台驱动，见 [CAMERA-MODEM](CAMERA-MODEM.md) |
| NFC | ❌ | 本机无 NFC 硬件 |

## 面板与触摸

这台机器有两种 K16A 面板，**刷机时必须选对**：

| 面板 | 兼容字符串（`PANEL=`） | 触摸固件 |
|:---|:---|:---|
| Tianma | `k16a_36_02_0a_vdo,lcm`（默认） | `novatek_ts_fw.bin` |
| CSOT | `k16a_42_02_0b_vdo,lcm` | `novatek_ts_ct_fw.bin` |

选错的表现：显示/触摸几何异常、屏幕某一侧触摸不灵。触摸固件由设备树里的面板节点自动选择（构建时打补丁 `config/patches/0003-novatek-touch-fw-by-panel.patch`），不需要手动换固件。

## 硬件清单（来自 stock ROM 分析）

分析对象：`evergo_images_V14.0.4.0.TGBCNXM_13.0`（HyperOS V14 / Android 13）的 `boot.img`、`dtbo.img`、`super.img`。

### SoC 与协处理器

| 部件 | 说明 |
|:---|:---|
| SCP | RISC-V RV55 TinySys（`scp.img`，`tinysys-scp-RV55_A`），SRAM 0x10500000、5 mailboxes、IRQ 0x1b2–0x1b8 |
| SSPM | `sspm@10400000`，5 mailboxes |
| MCUPM | `mcupm@0c540000`，RISC-V RV33（`tinysys-mcupm-RV33_A`），8 mailboxes + share memory 0x610000；CPU DVFS 的实际控制者 |
| GPU | `mali@13000000`，vendor compatible `mediatek,mt6833-mali`（Panfrost 已用 `arm,mali-valhall-jm`） |
| 调制解调器数据通路 | `dpmaif@10014000`（无主线上层驱动） |

三个 TinySys 固件都是裸 MediaTek FW 容器（magic `0x58881688`），不是 ELF；主线 `mtk_scp` 只支持 ARM M4 + ELF，所以 SCP/SSPM/MCUPM 都需要新的 RISC-V TinySys remoteproc + IPI 驱动。详见 [VENDOR-PORT](VENDOR-PORT.md) 与 [KERNEL](KERNEL.md)。

### 其它硬件

| 部件 | 型号 / 说明 |
|:---|:---|
| 主摄 | S5KJN1 50 MP |
| 超广角 | OV8856 8 MP |
| 微距 | OV02 / GC02 2 MP |
| 前摄 | IMX355 16 MP |
| NFC | 无硬件（仅框架 stub） |
| 充电 IC | 仅 MT6360（无 sc8551/ln8000/mp2762 等快充 IC） |
| 传感器 | TSL2522 光线、LSM6DSO 加速度/陀螺、AK09918 磁力计（vendor 全部经 SCP sensor hub） |
| 振动 | AW8697 |
| 音频功放 | 扬声器 AW8697/SIA 类（见驱动） |

## 已知限制

1. **内存高压力可能 panic** — 与本机内存/内核行为有关，非单一驱动问题；镜像用 zram 缓解，重负载前确认交换已启用。详见 [PANIC](PANIC.md)。
2. **CPU/GPU 调频未验证** — 频率目前固定，跑分/功耗非最优。
3. **休眠默认关闭** — 避免未知唤醒问题；可手动 `echo mem > /sys/power/state` 测试。
4. **蓝牙不可用** — 地址问题未解决。
5. **面板必须选对** — 见上表。
6. **无基带/相机/NFC** — 需要长期驱动工作。

## 虚拟化、Type-C/PD、Snap 与品牌信息

| 项目 | 状态 | 说明 |
|:---|:---:|:---|
| 虚拟化 | ✅ | KVM 已启用并通过硬件检测（EL2/VHE，`/dev/kvm`、`vhost-net`）；装 `qemu-system-arm`/libvirt 即可跑 aarch64 虚拟机 |
| USB Type-C / PD | 🟡 待真机验证 | MT6360 TCPC 节点已补（GPIO9 = PD_IRQB，sink PDO 5 V / 9 V）；PD 充电器实测前无法确认协商结果 |
| Snap | ✅ | Ubuntu/Debian 镜像预装并启用 `snapd`，首次开机即可 `snap install snap-store`（squashfs xz/zstd 已支持） |
| 型号信息 | ✅ | DT `model = "Xiaomi Redmi Note 11 5G"`、`compatible = "xiaomi,evergo"`、`chassis-type = "handset"` |

## 性能调优（构建时生效）

| 调整 | 原因 |
|:---|:---|
| zram 改用 `lz4` | A55/A76 上 zstd 压缩/解压明显更慢；lz4 降低 swap 延迟和 CPU 占用 |
| `vm.swappiness=100`、`page-cluster=0`、`watermark_boost_factor=0` | zram 是随机访问的快速 swap，积极换出匿名页比保留它们更划算 |
| `vm.dirty_background_ratio=5`、`dirty_ratio=15` | 避免大文件写入时一次回写过多，UFS 上会卡桌面数秒 |
| `vm.vfs_cache_pressure=50` | 内存紧张时多保留 dentry/inode 缓存 |
| UFS 调度器设为 `none`、`read_ahead_kb=128` | UFS 自带深队列，mq-deadline 只增加开销 |
| 温控 passive 阈值 80/90/100 → 85/95/105 °C | 原先 80 °C 就开始降频，持续负载只能跑 ~1.75 GHz；提高后能维持更高频率（critical 仍 115 °C） |

对应的文件：`rootfs-overlay.tar.gz` 里的 `/etc/sysctl.d/95-evergo-performance.conf`、
`/etc/udev/rules.d/60-evergo-ufs.rules`、`/usr/local/bin/evergo-swapfile`，
以及内核 `ee6cb578`（温控 trip）。

