# 已移植硬件模块（音频 / 震动 / 充电 / 传感器）

内核分支：`ccmx200/linux-evergo` `master`，本次工作基于 `3ded92b`，共 5 个提交，
tip = `50ca8781`。构建仓库 `build.sh` 的 `KERNEL_COMMIT` 已 pin 到该 commit。

| 模块 | 状态 | 关键证据 |
|:---|:---|:---|
| 音频（扬声器/听筒/耳机/麦克风） | ✅ 真机可用 | `/proc/asound/cards` 有 `mt6833-mt6359`；`speaker-test`/用户实听有声音；扬声器播放时设备麦克风录音 RMS 从 ~309 升到 ~2655（8.6 倍） |
| 震动（AW8697） | ✅ 真机可用（已由用户确认） | `aw8697 1-005a: detected AW869X chip id 0x97`；`/proc/bus/input/devices` 有 `aw8697-haptics`（event3，FF_RUMBLE/FF_PERIODIC）；`fftest` 上传并播放 sine/rumble 效果，用户实测能感觉到震动；VIBR LDO 需 3.3V（3.0V 时 AW8697 报 UVLO、电机不转）；驱动电平 96 + FF 下限 0x38，用户实测震动/扬声器/麦克风“全部正常” |
| 充电/电量（MT6360 + MT6359 FG） | ✅ 可用 | `/sys/class/power_supply/battery`（capacity/status/current_now）、`mt6360-chg.4.auto`（online/status） |
| 传感器 | ⚠️ 部分 | AK09918 磁力计（IIO `3-000c`，三轴 raw 有值）；TSL2522 环境光（IIO `tsl2522` 已注册）；LSM6DSO 加速度/陀螺仪由 SCP sensor hub 固件独占，AP 侧暂不可达 |

## 音频

* 机器驱动：`sound/soc/mediatek/mt8192/mt6833-mt6359.c`（MT6833 AFE 复用 mt8192 驱动，
  新增 `mediatek,mt6833-audio` compatible；MT6359 codec 走 MTKAIF，SIA8109 功放作为
  aux device 由 `aw8738` 单线协议驱动，GPIO131）。
* SoC 侧：audsys 时钟驱动 `of_platform_populate` 出 AFE 子设备；`mt6833-pm-domains.h`
  按 vendor `clk-mt6833-pg.c` 增加 AUDIO MTCMOS（PWR_CON 0x0358 / status bit22 /
  SRAM PDN 8-12 / TOPAXI PROTECTEN_2 bit4）；`mt6359-accdet` 补 OF match。
* UCM：`/usr/share/alsa/ucm2/conf.d/mt6833_mt6359/`（overlay 里；目录名是
  card driver `mt6833_mt6359`，文件是 card longname `mt6833-mt6359.conf`），依赖
  `alsa-utils` + `alsa-ucm-conf`。真机用 `alsaucm -c mt6833-mt6359 set _verb HiFi`
  验证过：设置后 `arecord -D hw:0,3` 直接成功（不需要手工 cset）。
* 重要：DPCM 的 FE→BE 连接只在 DAPM 路径已经使能后才会被发现，所以 **必须先 set
  UCM Verb/Device**（`ADDA_UL_Mux=MTKAIF`、`UL_SRC_MUX=AMIC`、
  `UL1_CH1 ADDA_UL_CH1=1` 等），然后才能打开 capture PCM；否则 `arecord` 会
  返回 EINVAL。UCM 已经按此顺序写好。

## 震动

* `drivers/input/misc/aw8697.c`：AW869X 寄存器表 + 连续模式（CONT）播放，FF
  rumble/periodic 映射到驱动电平；reset GPIO132、f0/驱动电平/BEMF 等从 vendor DT
  读取。
* 主线 `aw86927.c` 不能绑定：它读 0x57/0x58 的 16 位 ID，而 AW8697 在 0x00 返回
  0x97。

## 充电 / 电量

* DTS：i2c5 上的 MT6360（MFD + charger + flash LED + ADC），中断 GPIO10；MT6359
  fuel gauge 走 `pmic_adc` 的 VBAT 通道（auxadc），电池 OCV 表由 vendor
  `battery_S98016_CWD_4V45_5000mah.dtsi` 生成。
* `drivers/power/supply/mt6359-fuel-gauge.c`：FGADC 库仑计 + OCV 锚定，freezable
  workqueue 轮询（不唤醒 s2idle）。
* MT6360 的 i2c 总线 vendor DT 没有描述；真机扫描确认在 **i2c5 @0x34**（和 a22x
  MT6833+MT6360 参考设计一致）。

## 传感器

* i2c1：AK09918 @0x0c（`ak8975` 驱动，IIO 三轴 raw 有值）、TSL2522 @0x39
  （新 `drivers/iio/light/tsl2522.c`，连续 ALS，6 字节 FIFO）。
* LSM6DSO 不在任何 AP i2c 总线上（10 条总线都扫过），SCP 固件里有
  `lsm6dso_gyro`/`accGyro: spi error` 字符串，说明加速度计/陀螺仪由 SCP
  sensor hub 固件通过 SPI 独占，AP 侧要接管需要额外逆向 SPI 总线/CS 或实现
  nanohub 协议，暂未完成。

## 验证脚本

设备上（root）：

```sh
cat /proc/asound/cards
speaker-test -D hw:0,0 -c 2 -r 48000 -t sine -f 440 -l 1
arecord -D hw:0,3 -f S16_LE -r 48000 -c 2 -d 2 /tmp/mic.wav   # 先 alsaucm set _verb HiFi
fftest /dev/input/event3
cat /sys/class/power_supply/battery/capacity
cat /sys/bus/iio/devices/iio:device*/name
```

## 已知风险 / 待办

1. 扬声器/听筒/耳机音质与音量曲线未做主观调校（SIA8109 OWI mode 6 来自 a22x 同
   芯片经验，evergo 未逐档验证）。
2. 耳机插拔检测（MT6359 accdet）只注册了 jack，未做机械插拔实测。
3. AW8697 的驱动电平改为 96（vendor 默认 53），FF 事件映射到 [0x38, 96]；用户
   实测强度正常，但未做逐档（轻/中/重）强度校准。
4. TSL2522 的 ALS raw 当前读到 0（FIFO 有数据但 4 个通道都是 0，已按 Mikroe
   参考实现配置；需要 datasheet 级别的测量序列/增益调试后再接入自动亮度）。
5. LSM6DSO（加速度/陀螺）受 SCP 固件独占，未完成。
6. MT6360 的 Type-C/TCPC 节点未加（不影响充电）；SC8551/LN8000 快充 IC 没有
   主线驱动。
