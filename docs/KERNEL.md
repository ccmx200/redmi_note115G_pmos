# 🐧 内核移植状态

内核仓库：[`ccmx200/linux-evergo`](https://github.com/ccmx200/linux-evergo)（mainline 7.3.0-rc4 基线）
构建仓库通过 `KERNEL_COMMIT` pin 内核提交，见 [BUILDING](BUILDING.md)。

## 分支与提交

### `master` — 已上机验证（构建镜像 pin 这里）

| 提交 | 内容 |
|:---|:---|
| `41739d2c` | **触摸休眠修复**：Novatek 驱动接入 `dev_pm_ops`，suspend 深睡、resume 复位 TP_RST 并重新使能中断 |
| `3d60ec40` | **DRM 管线修复**：去掉 bring-up 的 OVL/RDMA 跳过、mutex SOF 覆盖和 DSI 关屏死等，恢复 OVL frame-done 中断流；息屏/休眠 resume 后屏幕自动恢复 |
| `4835f9b8` | **LVTS 温控**：`mediatek,mt6833-lvts` 驱动 + 13 个只读热区 |

`master` 是发布镜像使用的、经过上机验证的提交。

### `dvfs` — 已上机验证大部分，未合 master

| 提交 | 内容 | 验证 |
|:---|:---|:---|
| `c8c1ead7` | **CPU DVFS**（mediatek-cpufreq + mcusys mux/OPP/供电） | ✅ 小核 950 MHz–2.0 GHz、大核 725 MHz–2.0 GHz；8 核满载 2.0 GHz；降频/升频、s2idle 后都正常 |
| `76dc0b9d` | **GPU DVFS**（Panfrost 390–880 MHz，固定 0.78125 V / VSRAM 0.85 V） | ✅ devfreq 生效；频率随 OpenGL ES 负载线性变化；880 MHz 连续满载 20 s 无故障 |
| `d1536c41` | **LVTS critical trips + 休眠上下文恢复** | ✅ 9 个热区 117 °C trip；s2idle 后温度仍合理 |

> ⚠️ 已知问题：**CPU DVFS + GPU DVFS 同时启用时，s2idle resume 可能硬挂**（一次测试中挂死后强制断电把 userdata 的 ext4 journal 写坏，已重刷恢复）。在定位/压测通过前，`dvfs` 分支不进入发布镜像。

### `cpuidle-exp` — 实验分支，不要合并

`b68469a6`：PSCI CPU idle states（cpuoff/clusteroff + 广播定时器 `timer@10017000`）。

- 状态生效：`current_driver=psci_idle`，`cpuoff_l`/`clusteroff_l` 的 usage/time 都在增长；
- 但与 DVFS 组合后，压力测试/休眠时可能硬挂，并造成过 userdata 损坏 → 仅保留在分支，等挂死原因定位后再考虑。

## CPU DVFS 说明

MT6833 的 CPU DVFS 由 MCUPM（RISC-V RV33 TinySys 固件）主导，AP 侧不能直接改 ARMPLL/电压；主线 `mediatek-cpufreq-hw` 的 LUT 方案在该 SoC 上读出乱码（曾出现 3.9 GHz），已放弃。

`dvfs` 分支改用 A22x（同 MT6833）的经典 **`mediatek-cpufreq` + mcusys mux + MT6359 供电路轨**，绕开 MCUPM IPI：

- 小核簇：950 MHz – 2.0 GHz（与 Vproc2/CCI 共享，下限 950 MHz 保安全）
- 大核簇：725 MHz – 2.0 GHz（A22x 的 2.203 GHz 是逐片 EEM 校准值，主线读不到 EEM，不冒险加）

上机验证命令：

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver      # mtk-cpufreq
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor    # schedutil
```

## GPU DVFS 与 OpenGL ES 基准

GPU 频率/电压表从 stock `boot.img` 的 vendor DTB 和 vendor 内核源码（`gpufreq_v1/mt6833`）中提取：955 MHz 官方电压就是 0.78125 V，与主线固定电压一致，因此 955 MHz 重启不是欠压，而是 MFG PLL/posdiv 问题 → 已从 OPP 表移除，**上限 880 MHz**。

用 headless EGL pbuffer + GLES2 的 GPU-bound 基准（全屏 1024×1024、64 次 ALU 循环的 fragment shader，Mesa 26.0.8 / Panfrost）：

| GPU 频率 | fps |
|:---:|:---:|
| 390 MHz（旧固定值） | 9.5 |
| 545 MHz | 13.3 |
| 622 MHz | 15.2 |
| 700 MHz | 17.0 |
| 880 MHz | 21.3 |

880/390 = 2.26 倍频率，实测 2.24 倍 fps，说明 DVFS 确实生效；880 MHz 连续满载 20 s 正常（21.3 fps）。

## 验证计划（等稳定性问题修复后）

1. `cpuidle-exp` 之外，先在 `dvfs` 分支上复测：CPU 满载 30 min、GPU 满载 5 min、两者混合、s2idle 进出 ×20、重启 ×10；
2. 定位 CPU+GPU DVFS 组合下 s2idle resume 挂死（优先怀疑 GPU PM / PLL 恢复顺序）；
3. 通过后 `dvfs` 合入 `master`，构建仓库 pin 更新，发布带调频的镜像；
4. PSCI idle 另外单独压测，稳定后再合入。

## 已知限制与风险

| 项 | 说明 |
|:---|:---|
| 大核上限 2.0 GHz | 2.203 GHz 是 A22x 逐片 EEM 校准值，主线读不到 EEM |
| 小核下限 950 MHz | CCI 与 Vproc2 共享、CCI DVFS 未移植 |
| GPU 上限 880 MHz | 955 MHz 会重启（PLL/posdiv 问题，与电压无关） |
| 117 °C trip | 基于未校准的 LVTS golden temp，仅作最后保护 |
| 组合 DVFS + s2idle | 已知会挂，未进发布镜像 |
| MCUPM / SCP / SSPM | 均为 RISC-V TinySys，主线无驱动；传感器 hub、modem 卡在这里 |
| 内存压力 panic | 见 [PANIC](PANIC.md) |

## 抓内核崩溃日志（无串口）

SSH 失联超过 60 秒按 panic 处理，重新开机后：

```bash
ls /sys/fs/pstore/            # console-ramoops-0 / dmesg-ramoops-0
cat /sys/fs/pstore/console-ramoops-0
```

取不到时从 expdb 分区提取，步骤见 [PANIC](PANIC.md)。

## 提交规范

- 一个子系统一个提交，提交信息写"为什么"和"上机验证了什么"；未验证的改动明确标注并放在分支上。
- 不提交调试打印/死代码；发布镜像只 pin 已上机验证的 `master`。
- DTS 变更按 board/SoC 分开，方便其他 MT6833 机型复用。
