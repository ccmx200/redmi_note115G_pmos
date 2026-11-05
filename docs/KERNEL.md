# 🐧 内核移植状态

内核仓库：[`ccmx200/linux-evergo`](https://github.com/ccmx200/linux-evergo)（mainline 7.3.0-rc4 基线）
构建仓库通过 `KERNEL_COMMIT` pin 内核提交，见 [BUILDING](BUILDING.md)。

## 分支与提交

### `master` — 已上机验证（构建镜像 pin 这里）

| 提交 | 内容 |
|:---|:---|
| `41739d2c` | **触摸休眠修复**：Novatek 驱动接入 `dev_pm_ops`，suspend 深睡、resume 复位 TP_RST 并重新使能中断（真机日志验证） |
| `3d60ec40` | **DRM 管线修复**：去掉 bring-up 的 OVL/RDMA 跳过、mutex SOF 覆盖和 DSI 关屏死等，恢复 OVL frame-done 中断流；息屏/休眠 resume 后屏幕自动恢复 |
| `4835f9b8` | **LVTS 温控**：`mediatek,mt6833-lvts` 驱动 + 13 个只读热区（CPU/GPU/SOC/CONNSYS/MD），真机温度合理 |

更早的 bring-up 提交（音频/振动/充电/传感器/DTS/90 Hz 面板/pmic-keys 等）在各自独立提交中。

### 分支 `dvfs-idle` — 已编译，**未上机验证**

| 提交 | 内容 |
|:---|:---|
| `88b66aca` | **CPU DVFS**（mediatek-cpufreq）：mcusys CPU mux 时钟驱动、MT6833 platform data、board DTS OPP/供电路轨。小核 950 MHz–2.0 GHz，大核 725 MHz–2.0 GHz |
| `985a071e` | **GPU DVFS**（Panfrost）：MFG PLL mux parking、MAINPLL 保护、单 supply、390–955 MHz OPP（固定 781250 µV / VSRAM 850 mV） |
| `1a31829e` | **PSCI CPU idle + 温控 trips**：CPU idle states + 广播定时器 `timer@10017000`、117 °C critical trip、LVTS 休眠上下文恢复 |

> 分支基于 `master`（`41739d2c`），构建镜像暂不 pin 该分支。硬件验证通过后逐个合回 `master`。

## 为什么 CPU 调频要单独做

MT6833 的 CPU DVFS 由 **MCUPM（RISC-V RV33 TinySys 固件）** 主导，AP 侧不能直接改 ARMPLL/电压。之前试过主线 `mediatek-cpufreq-hw` 的 LUT 方案，在该 SoC 上读出乱码频率表（出现 3.9 GHz），已回滚。

A22x（同 MT6833）主线的做法是走经典 **`mediatek-cpufreq` + mcusys mux + MT6359 供电路轨**，绕开 MCUPM 的 IPI；本分支即该方案的移植。完整 MCUPM 分析（IPI 协议、DVFS SRAM、boot chain）记录了后续"用 MCUPM 官方调频"的路线。

## 验证计划（等设备恢复后执行）

按风险从低到高，**每一步都准备好回退镜像**：

1. `idle-boot-no-cpuidle.img`（无 PSCI idle）→ 确认广播定时器、温控 trips、LVTS 休眠恢复都正常，不硬死机。
2. `cpudvfs-boot.img` → 查 `/sys/devices/system/cpu/cpu0/cpufreq`：驱动应为 `mtk-cpufreq`，governor `schedutil`，小核频率表 950 MHz–2.0 GHz；跑 `stress-ng` 观察是否死机/欠压。
3. `gpudvfs-boot.img` → 查 `/sys/class/devfreq/13000000.gpu`：`available_frequencies` 390–955 MHz，切换时 `clk_summary` 里 **MAINPLL 不变**，显示不闪。
4. `idle-boot.img`（含 PSCI idle）→ `/sys/devices/system/cpu/cpuidle/current_driver=psci_idle`，`state1/state2` 的 usage 增长；注意本机 ATF 从未验证过 `CPU_SUSPEND`，若一进 idle 就死机属于已知风险，直接回退。

## 已知限制与风险

| 项 | 说明 |
|:---|:---|
| 大核上限 2.0 GHz | 2.203 GHz 是 A22x 逐片 EEM 校准值；主线读不到 EEM，强行加有欠压死机风险 |
| 小核下限 950 MHz | CCI 与 Vproc2 共享、CCI DVFS 未移植，低于 950 MHz 电压不足 |
| 117 °C trip | 基于 LVTS 未校准的 golden temp，只作为最后保护，不是精确规格 |
| MFG mux / PLL 假设 | 来自 A22x 同 SoC 的寄存器布局，若 GPU 起不来优先回退 clock 补丁 |
| MCUPM / SCP / SSPM | 均为 RISC-V TinySys，主线无驱动；传感器 hub、modem 都卡在这里 |
| 内存压力 panic | 见 [PANIC](PANIC.md) |

## 抓内核崩溃日志（无串口）

设备有 pstore/ramoops 与 expdb 分区。SSH 失联超过 60 秒按 panic 处理，重新开机后：

```bash
ls /sys/fs/pstore/            # console-ramoops-0 / dmesg-ramoops-0
cat /sys/fs/pstore/console-ramoops-0
```

取不到时从 expdb 分区提取，步骤见 [PANIC](PANIC.md)。

## 提交规范

- 一个子系统一个提交，提交信息写"为什么"和"上机验证了什么"；未验证的改动明确标注并放在分支上。
- 不提交调试打印/死代码；构建镜像只 pin 已上机验证的提交。
- DTS 变更尽量按 board/SoC 分开，方便其他 MT6833 机型复用。
