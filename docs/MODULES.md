# 已移植硬件模块 / 已知问题（evergo）

内核分支：`ccmx200/linux-evergo` `master`，构建仓库 `ccmx200/redmi_note115G_pmos`。
本文件随内核 `KERNEL_COMMIT` 同步更新。

## 功能矩阵

| 模块 | 状态 | 关键证据 / 说明 |
|:---|:---|:---|
| 显示 1080x2400 **90 Hz** | ✅ | 面板驱动用 vendor “performance mode” 时序（VFP 54/VSA 4/VBP 16，vtotal 2474，clock 303708），并写面板 page 0x25 / 0x18 = 0x20；DRM state 显示 `1080x2400: 90 303708 ... 2474` |
| 触摸、按键、USB 网络+SSH、Wi-Fi | ✅ | 之前已完成；SSH `root@169.254.42.1` |
| 音频：扬声器/听筒/耳机/麦克风 + UCM | ✅ | 用户实测“全部正常”；UCM `mt6833_mt6359` 已随镜像安装 |
| 震动 AW8697 | ✅ | VIBR LDO 3.3 V、驱动电平 96、FF 映射下限 0x38；用户实测正常 |
| 充电 MT6360 + 电量 MT6359 FG | ✅ | 用户实测充电正常；`/sys/class/power_supply/battery` |
| 磁力计 AK09918 | ✅ | 旋转手机三轴 raw 明显变化（x 65→283 等） |
| 环境光 TSL2522 | ⚠️ | 驱动绑定、ID 0x5C、状态位 valid，但 ALS 双通道恒 0；怀疑 vendor sensor-hub 的 photodiode/SMUX registry 配置，自动亮度暂不可用 |
| 加速度/陀螺 LSM6DSO | ❌ | SCP sensor hub 固件通过 SPI 独占，AP 侧没有总线 |
| 蓝牙 | ⚠️ | 配对可用；内核已补 `BT_RFCOMM/BNEP/HIDP/LE`（之前 OBEX/OPP/FTP profile 因 RFCOMM 缺失全部启动失败）。文件传输需配对后由对端发起，待最终回归 |
| 电源键 | ⚠️ | 可按灭屏幕，按亮时 DRM commit（flip_done）超时导致黑屏；`mtk-pmic-keys` 已标记 wakeup，suspend 路径仍需修 |
| 桌面应用 | ✅ | phosh 预装 epiphany/计算器/时钟/看图/PDF/视频/压缩/截图/字符/磁盘/联系人/日历 |
| 中文 | ✅ | `language-pack-gnome-zh-hans` + ibus-libpinyin + Noto CJK/Emoji |

## 镜像里预装的关键软件（phosh 版）

`epiphany-browser`（浏览器）、`gnome-calculator`、`gnome-clocks`、`eog`、`evince`、
`totem`、`file-roller`、`gnome-screenshot`、`gnome-characters`、`gnome-disk-utility`、
`gnome-contacts`、`gnome-calendar`、`iio-sensor-proxy`、`bluez-obexd`、
`language-pack-gnome-zh-hans`、`ibus-libpinyin`、`libreoffice` 未装（体积原因）。

## 蓝牙文件传输

- 内核：`CONFIG_BT_RFCOMM=y`、`CONFIG_BT_RFCOMM_TTY=y`、`CONFIG_BT_BNEP=y`、
  `CONFIG_BT_HIDP=y`、`CONFIG_BT_LE=y`
- 用户态：`bluez-obexd`（`/usr/libexec/bluetooth/obexd`，D-Bus `org.bluez.obex`）
- 排查命令：`journalctl -u bluetooth -b | grep -i rfcomm`、`bluetoothctl show | grep -i obex`
- 之前失败根因：`socket(STREAM, RFCOMM): Protocol not supported` → OBEX/OPP/FTP/HFP/PBAP
  全部无法启动；补内核配置后恢复

## 电源键 / 休眠已知问题

- 按电源键可以关屏；再按一次时面板和 DSI 重新上电，但 mtk-drm 的 `flip_done timed out`
  / commit wait 超时，画面保持黑。内核 suspend 统计 `success=0`（phosh 持有
  handle-power-key 抑制器，走的是 phosh 自己的 blank 流程）。
- 内核已把 pmic keys 标记成 wakeup source、默认 `mem_sleep_default=s2idle`，
  但 phosh 的 blank 路径仍会触发上述 DRM bug，suspend/resume 需要继续修。
- 临时绕过：锁屏后用触摸唤醒；或不要用电源键关屏，改 5 分钟自动熄屏。

## 90 Hz 说明

- 只暴露 90 Hz 首选模式，60 Hz 时序代码保留但不再 probe（用户确认“90 Hz 保留，能亮即可”）。
- 若需要 60/90 动态切换，需要移植 vendor 的 dyn-fps（面板 0x18 命令 + DSI vfp 动态调整）
  并解决 DRM 重新点亮超时，本次未做。

## 环境光 / 加速度计

- TSL2522：soft reset + WTIME + APERS + PON|AEN 后 STATUS2/ALS_STATUS 正常、数据恒 0；
  扫过 mod channel(0x40)/ALS_SCALE/TRIGGER_MODE/APERS 组合均无效。需要 vendor sensor-hub
  registry 或屏幕下方点亮时序，公开寄存器表不够。
- LSM6DSO：SCP 固件字符串 `lsm6dso_gyro`/`accGyro: spi error`，AP 侧 i2c 总线扫描不到，
  需先让主线内核接管 SCP/SPI 或逆向 SCP 协议。

## 压力测试

见 `docs/STRESS.md`：CPU/内存/UFS/音频/震动/传感器/电源/背光/蓝牙连续压力 344 s，
全程 SSH 在线，无 panic/Oops/OOM/文件系统错误。唯一稳定性问题是显示
blank/unblank（电源键）的 DRM 提交超时，与负载无关。

复现：用 `/dev/uinput` 注入 KEY_POWER，logind 记录按键后 mtk-drm 立刻报
`flip_done timed out` / `commit wait timed out` / `failed to switch cmd mode`。
曾在 `mtk_crtc_atomic_begin` 提前完成 CRTC 事件，结果 blank 提交直接卡死，
31 s 后被硬件看门狗复位，已回退，该问题保留为 Known Issue。

## 刷机

```
fastboot flash boot_a boot.img
fastboot flash boot_b boot.img
fastboot flash boot   boot.img
fastboot -S 200M flash userdata userdata.simg
fastboot reboot
```

## 已知风险清单

1. 电源键亮屏（DRM unblank commit 超时）未修
2. 蓝牙文件传输需实测（内核配置已补）
3. TSL2522 ALS 不可用
4. LSM6DSO 不可用
5. 摄像头/Modem/指纹/NFC/快充协议 IC 未实现（未在本次范围）
6. suspend/s2idle 未验证通过
