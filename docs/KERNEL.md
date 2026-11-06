# 🐧 内核移植状态

内核仓库：[`ccmx200/linux-evergo`](https://github.com/ccmx200/linux-evergo)（mainline 7.3-rc4 基线）
构建仓库通过 `KERNEL_COMMIT` pin 内核提交，见 [BUILDING](BUILDING.md)。

## 分支与提交

### `master` — 已上机验证（构建镜像 pin 这里）

| 提交 | 内容 | 状态 |
|:---|:---|:---|
| `4835f9b8` | **LVTS 温控**：`mediatek,mt6833-lvts` + 13 个只读热区 | ✅ |
| `3d60ec40` | **DRM 管线修复**：恢复 OVL frame-done 中断流，息屏/休眠 resume 后屏幕自动恢复 | ✅ |
| `41739d2c` | **触摸休眠修复**：Novatek 驱动接入 `dev_pm_ops` | ✅ |
| `c8c1ead7` | **CPU DVFS**（mediatek-cpufreq + mcusys mux/OPP/供电路轨） | ✅ |
| `76dc0b9d` | **GPU DVFS**（Panfrost 390–880 MHz，固定 0.78125 V / VSRAM 0.85 V） | ✅ |
| `d1536c41` | **LVTS critical trips + 休眠上下文恢复** | ✅ |
| `88aa1fd0` | **MT6360 ADC 通道绑定头**（给 fuel-gauge 引用 VBAT 通道用） | ✅ |
| `6796f40a` | **fuel-gauge 改读 MT6360 ADC VBAT**（原来读 MT6359 阻抗通道，读出负电压） | ✅ |
| `7480c0a7` | **fuel-gauge 电压单位修正**（uV 结果被再乘 1000 导致 int 溢出） | ✅ |
| `1a91f097` | **电池 OCV 表单位修正**（整表原来放大了 10 倍） | ✅ |
| `320373f5` | **CPU/GPU 温控降频**：passive cooling（80/90/100°C），critical 115°C | ✅ |
| `12717b45` | **LK mblock 保留**：补全基带/SCP/SPM/RKP 等固件内存，修复内存压力 panic | ✅ |

`master` 当前 tip = **`1a91f097`**。

### `cpuidle-exp` — 实验分支，不要合并

PSCI CPU idle states（cpuoff/clusteroff + 广播定时器 `timer@10017000`）。状态确实生效（`psci_idle`，usage/time 增长），但与 DVFS 组合后压力测试/休眠时会硬挂，并造成过 userdata 文件系统损坏。仅保留在分支，等挂死原因定位后再考虑。

## 已验证的关键结论

### CPU DVFS

- 驱动 `mtk-cpufreq`，governor `schedutil`
- 小核簇 950 MHz – 2.0 GHz；大核簇 725 MHz – 2.0 GHz
  - 大核不上 2.203 GHz：那是 A22x 逐片 EEM 校准值，主线读不到 EEM 表
  - 小核下限 950 MHz：CCI 与 Vproc2 共享、CCI DVFS 未移植
- 8 核满载可到 2.0 GHz；降频/升频、s2idle 后都正常

### GPU DVFS

- `/sys/class/devfreq/13000000.gpu`，`simple_ondemand`，390–880 MHz
- 955 MHz 会重启（vendor 表同为 0.78125 V，说明是 MFG PLL/posdiv 问题而非欠压）→ 已从 OPP 表移除
- GPU-bound OpenGL ES 基准（EGL pbuffer + 全屏 fragment shader，Mali-G57 MC2/Panfrost）：

| GPU 频率 | fps |
|:---:|:---:|
| 390 MHz | 9.5 |
| 545 MHz | 13.3 |
| 622 MHz | 15.2 |
| 700 MHz | 17.0 |
| 880 MHz | 21.3 |

### 休眠

CPU+GPU DVFS 同时启用时 **s2idle 进出正常**（已验证：suspend_stats success=1，resume 后显示/触摸/cpufreq/GPU devfreq 都恢复）。之前的挂死是 PSCI CPU idle 造成的，跟 DVFS 无关。

### 电池 / 充电（本次修复）

修复前：

```
POWER_SUPPLY_VOLTAGE_NOW=-1329350976   (负电压)
charge_now=892 uAh  on 5000 mAh pack
capacity=0
```

根因与修复：

1. fuel-gauge 的 `io-channels` 指向 MT6359 AUXADC 的阻抗通道（`MT6359_AUXADC_VBAT`），该通道的 IIO scale 不是 uV/LSB，读出来是垃圾；
2. 改为读 MT6360 充电 ADC 的真实 VBAT 通道（`in_voltage4_scale=1250`，uV/LSB）；
3. 驱动里对已经是 uV 的结果又乘了 1000，int 溢出变成负电压 → 删掉多余乘法；
4. DTS 里电池 OCV 表所有电压值放大了 10 倍（44150000 = 44.15 V）→ 整表除以 10。

修复后真机：`voltage_now=4287500 uV`、`capacity=85 %`、`charge_now=4255435 uAh`、`current_now=279541 uA`（充电中）。

### 手电筒

MT6360 白闪 LED 由内核 LED class 驱动暴露为 `/sys/class/leds/white:flash-1`：

- `brightness` 1–7：手电筒亮度档位；
- `flash_strobe`：相机闪光脉冲；
- `flash_fault`：过压/欠压状态（正常为空）。

镜像内提供 `evergo-torch` 命令（`on [1-7]` / `off` / `toggle` / `strobe` / `status`），真机验证 1/3/7 档与 strobe 均正常，无 fault。

## 温控与压力测试（本次新增）

CPU/GPU DVFS 打开后，8 核满载可以一直维持 2.0 GHz；没有 cooling device 时温度会从 80°C 一路升到 102°C 然后整机挂死（已复现）。给 13 个热区加上 passive cooling 后：

- CPU 小核/大核：80/90/100°C 三档降频（cpufreq cooling）；
- GPU：80/90°C 两档降频（devfreq cooling）；
- SOC 区：85/95°C；
- critical trip 从 117°C 降到 115°C。

真机 5 分钟 8 核满载结果：温度稳定在 **~81°C**，max_freq 逐步从 2.0 → 1.916 → 1.812 → 1.75 GHz，系统持续存活（uptime 连续），不再挂死。


## 内存压力 panic：根因与修复（12717b45）

以前"内存用多了就随机 panic"（`pc=0` 软中断、slab refill NULL、Bad page map）的根因已经定位：

- 内核用编译进 Image 的 DTB，丢掉了 **LK 启动时注入的 `/memory` + `/reserved-memory` mblock**；
- LK 给基带（`ap_md_c_smem` 0x6c000000 等约 230 MB）、SCP 0xb9400000、SPM、RKP 0xd0000000 以及 framebuffer/MCUPM/TEE 保留的 DRAM 没有被 Linux 保留，固件和 Linux 同时使用 → 数据被踩；
- 用 4.2 GiB 内存测试可以复现：修复前 47,308 个坏页，物理范围 0x6c000000..0xb52ff000（正好是基带 mblock）；补全 mblock 后 **0 坏页**。

`mem=4G` 的临时规避不再需要。

## 验证计划（继续）

1. `cpuidle-exp` 的挂死定位（优先怀疑 PSCI 状态与 CPU PLL/CCI 恢复顺序）；
2. DVFS 长稳：CPU 满载 30 min、GPU 满载 5 min、混合负载、s2idle ×20、重启 ×10；
3. 摄像头/基带按 [CAMERA-MODEM](CAMERA-MODEM.md) 的结论暂缓。

## 已知限制与风险

| 项 | 说明 |
|:---|:---|
| 大核上限 2.0 GHz | 2.203 GHz 是逐片 EEM 校准值 |
| GPU 上限 880 MHz | 955 MHz 会重启（PLL/posdiv） |
| 117 °C trip | 基于未校准的 LVTS golden temp，仅作最后保护 |
| PSCI idle | 实验分支，不稳定 |
| MCUPM / SCP / SSPM | RISC-V TinySys，无主线驱动；传感器 hub、modem 卡在这里 |
| 内存压力 panic | 见 [PANIC](PANIC.md) |

## 抓内核崩溃日志（无串口）

SSH 失联超过 60 秒按 panic 处理，重新开机后：

```bash
ls /sys/fs/pstore/
cat /sys/fs/pstore/console-ramoops-0
```

取不到时从 expdb 分区提取，步骤见 [PANIC](PANIC.md)。

## 提交规范

- 一个功能一个提交，提交信息写"为什么"和"上机验证了什么"；未验证的改动明确标注并放在分支上。
- 不提交调试打印/死代码；发布镜像只 pin 已上机验证的 `master`。
- DTS 变更按 board/SoC 分开，方便其他 MT6833 机型复用。
