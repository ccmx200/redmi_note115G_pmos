# 压力测试记录（evergo, phosh 镜像）

测试对象：`db89f4e6`（构建仓库，内核 `d08c206` 之前的 `d08c206` 同源树）
测试时间：2026-11-04 01:44 ~ 01:48（设备本地时钟）
环境：phosh 镜像（Ubuntu 26.04 base）、内核 `7.3.0-rc4-g3ded92b343f0-dirty`、
6 GiB RAM、90 Hz 面板、USB RNDIS + SSH。

## 测试项与结果

| 阶段 | 内容 | 结果 |
|:---|:---|:---|
| CPU | 4 线程满载 120 s | 通过，无异常 |
| 内存 | Python 连续分配 3.5 GB | 用户态进程自己因 `free(): invalid size` 退出（测试脚本问题），内核无 OOM/panic |
| UFS | 1 GiB 写入 + 读回 | 写 584 MB/s，读 3.2 GB/s，无错误 |
| 音频 | 4 轮 speaker-test + arecord（UCM Speaker/Mic 切换） | 通过 |
| 震动 | 4 轮 sine + strong rumble | 通过 |
| 传感器 | 500 轮 AK09918 三轴 + TSL2522 读取 | 通过（ALS 仍为 0，见 MODULES.md） |
| 电源 | 300 轮 battery capacity/current/voltage 读取 | 通过 |
| 背光 | 60 轮 1→255 亮度扫描 | 通过 |
| 蓝牙 | 8 轮 `bluetoothctl power off/on` | 通过 |
| 网络 | curl 外网 10 MB | 未通（`000`，外网/镜像源不可达，非驱动崩溃） |
| 综合 | 上述连续执行 344 s | 全程 SSH 在线，无重启、无 panic |

## 压力测试中暴露的问题（与压力无关，但真实存在）

1. **电源键/DPMS blank 路径**：
   - 用 `/dev/uinput` 注入 `KEY_POWER`（模拟电源键）可稳定复现：
     logind 记录 `Power key pressed short`，随后 mtk-drm 报
     `flip_done timed out` / `commit wait timed out` / `failed to switch cmd mode`，
     屏幕黑但系统仍在线；再按一次无法恢复画面。
   - 曾试过在 `mtk_crtc_atomic_begin` 提前完成 CRTC 事件，结果 blank 提交直接
     卡死，31 s 后硬件看门狗复位（见下），已回退。
2. **硬件看门狗**：`mtk-wdt` 以 31 s 超时使能，`evergo-watchdog.service` 每 10 s 喂狗。
   suspend 期间该服务无法喂狗，若系统真的进入 suspend 会被看门狗复位；
   目前默认 `mem_sleep_default=s2idle` 但没有 suspend 成功路径，需注意。
3. 启动时 DSI 有一次 `Wait DSI IRQ(0x08) Timeout`（约 1.28 s），之后正常；
   疑似 vendor 时序/命令模式切换问题，暂未修。

## 结论

- 正常使用路径（CPU/内存/存储/音频/震动/传感器/电源/背光/蓝牙）在压力下稳定，
  未见内核 panic、Oops、OOM 或文件系统错误。
- 剩下的稳定性问题是 **显示 blank/unblank（电源键）** 的 DRM 提交超时，
  属于显示子系统问题，与负载无关。

## 复现命令（电源键）

```sh
# 设备上（root）
cat > /tmp/pwr.py <<'EOF'
import struct, fcntl, os, time
fd=os.open("/dev/uinput", os.O_RDWR|os.O_NONBLOCK)
for bit in (1,0): fcntl.ioctl(fd, 0x40045564, bit)   # EV_KEY, EV_SYN
fcntl.ioctl(fd, 0x40045565, 116)                     # KEY_POWER
os.write(fd, struct.pack("80sHHHHI", b"evergo-test-power",0,0,0,0,0) + b"\0"*(64*4*4))
fcntl.ioctl(fd, 0x5501)
time.sleep(1)
def emit(t,c,v): os.write(fd, struct.pack("llHHi",0,0,t,c,v))
emit(1,116,1); emit(0,0,0); time.sleep(.1); emit(1,116,0); emit(0,0,0)
EOF
python3 /tmp/pwr.py
dmesg | grep -E 'flip_done|commit wait|cmd mode'
```


## 2026-11 自动化结果（内核 320373f5 + thermal cooling）

在最小 Ubuntu 镜像、内核 `320373f5`（CPU/GPU DVFS + 电池修复 + 温控降频，未启用 PSCI idle）上自动执行：

| 测试 | 结果 |
|:---|:---|
| 8 核 CPU 满载 5 分钟 | 温度稳定 **~81°C**（未加 cooling 前升到 102°C 后挂死）；cpufreq max_freq 自动 2.0 → 1.916 → 1.812 → 1.75 GHz；uptime 连续、无 panic |
| s2idle 进/出 ×3 | `suspend_stats success=3 fail=0`；每次 resume 后 dpms=On、cpufreq/GPU devfreq 正常 |
| 重启 ×3 | 每次都能在 60 s 内重新 SSH；battery/cpufreq/devfreq/thermal 服务自动恢复 |
| 电池读数 | `voltage_now=4.26–4.30 V`、`capacity=83–86 %`、`charge_now≈4.25 Ah`，与充电电流一致 |
| 手电筒 | `/sys/class/leds/white:flash-1` 亮度 1/3/7 与 flash_strobe 均正常，`flash_fault` 为空 |
| GPU 880 MHz 持续负载 | 在带 Mesa 的镜像上跑 21.3 fps、20 s 无故障；最小镜像没有 libEGL，无法跑该基准（需要 `mesa-utils`） |

已知未测试/遗留：PSCI CPU idle（`cpuidle-exp`，会挂死）、摄像头/基带（见 [CAMERA-MODEM](CAMERA-MODEM.md)）。
