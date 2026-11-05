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
| 充电 / 电量 | ✅ | MT6360 充电 + MT6359 fuel gauge |
| RTC | ✅ | MT6359 RTC；开机/关机与定时保存，时间不丢 |
| 温度传感器 | ✅ | MT6833 LVTS：13 个热区（CPU/GPU/SOC/CONNSYS/MD），只读 |
| CPU / GPU 调频 | 🚧 | 已移植、编译通过，**未上机验证**（内核分支 `dvfs-idle`）；当前固定频率 |
| CPU idle（PSCI） | 🚧 | 已移植（含广播定时器），未上机，见 [KERNEL](KERNEL.md) |
| 休眠 s2idle | 🟡 | 可手动进/出，显示与触摸能恢复；默认不开自动休眠 |
| 传感器 | 🟡 | AK09918 / TSL2522 / LSM6DSO 由 SCP RISC-V 传感器 hub 独占，主线无驱动 |
| 基带 / SIM | ❌ | 无 CCCI/MDF 驱动，通话/短信/数据暂不支持 |
| 相机 | ❌ | 无 ISP/相机驱动 |
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
