# 📷 摄像头与基带支持分析

这两项都**没有**在主线内核里实现，属于需要长期驱动工作的部分。这里记录现状、阻塞点和大致工作量，避免重复调研。

## 摄像头

### 硬件

来自 stock ROM `evergo_images_V14.0.4.0.TGBCNXM_13.0` 的 `super.img`（vendor 分区）：

| 位置 | 型号 |
|:---|:---|
| 主摄 | S5KJN1 50 MP |
| 超广角 | OV8856 8 MP |
| 微距 | OV02（OV02A10/OV02C10 类）2 MP |
| 前摄 | IMX355 16 MP |
| 另见 | GC02 2 MP（同定位，随批次） |

### 内核侧现状

好消息：常见 sensor 的主线驱动在树里都有 —— `drivers/media/i2c/s5kjn1.c`、`ov8856.c`、`imx355.c`、`ov02a10.c`/`ov02c10.c`。

坏消息：**没有 MT6833 的相机平台驱动**。vendor 链路是：

```
sensor (MIPI CSI-2) -> seninf (CSI-2 receiver) -> camsys/imgsys ISP -> MDP -> DRM
```

主线 `drivers/media/platform/mediatek/` 只有 `jpeg`、`mdp3`、`vcodec`、`vpu`，没有 camsys ISP / seninf；设备树里也没有 `seninf`、`camsys`、`imgsys` 这些节点。仅有 sensor 驱动无法取流。

### 需要的工作（粗略）

1. DT：`seninf`（CSI-2 D-PHY + MIPI 控制器）、`camsys`/`imgsys`（ISP + MDP）节点、时钟/电源域、sensor 供电轨（DOVDD/DVDD/AVDD）与 GPIO；
2. 驱动：MT6833 seninf（CSI-2 RX）、camsys ISP（至少 RAW→YUV 或 pass-through）、MDP 写回；可参考 MediaTek 上游 `mtk-isp` 的 MT8183/MT8195 版本，但寄存器布局不同；
3. 用户侧：libcamera 的 MTK pipeline handler + sensor 3A（无 vendor 闭源库可用）；
4. 标定：AF/闪光/LSC 等数据在 vendor `/vendor/etc/camera` 里，格式未公开。

工作量：**数月级**，且需要大量硬件调试（MIPI 时序、ISP 同步、供电时序）。短期不做。

## 基带 / SIM

### 硬件与固件

- 基带固件：`md1img.img`（stock images，约 65 MB），另随 `super.img` 的 vendor 里有 CCCI/MDF 相关库；
- AP 侧接口：`dpmaif@10014000`（modem data path，数据面）；控制面是 CCCI/mailbox；
- 主线上目前**没有任何** CCCI/MDF/EMD 驱动，也没有 modem 固件加载器；DT 里连 modem 节点都没有描述（A22x 也只在补丁里描述了 modem 的受保护电源域，见其 `0108-dt-bindings-soc-describe-guarded-MT6833-modem-power`）。

### A22x 同 SoC 的进度

A22x mainline 项目把 modem 作为长期目标，目前只能做到 **HS2 阶段**（约 1400+ 文件系统请求后遇到 DigRF assertion），SIM1/注册/通话/数据都不可用。也就是说同 SoC 的 modem bring-up 仍处于早期。

### 需要的工作

1. `md1img` 解析/加载（MTK 的 modem 固件格式、分区布局）；
2. CCCI/mailbox 驱动 + `dpmaif` 数据面驱动；
3. vendor RIL 协议适配（或 ModemManager 的 MTK 插件）；
4. SIM/EFS 文件系统、NV 数据、射频校准（vendor nvdata，主线无解析）。

工作量：**数月到一年级**，通信协议和射频校准是主要风险。短期不做。

## 结论

- 摄像头、基带都**不在**当前主线支持范围内，需要独立的驱动工程；
- 如果以后要做，建议先做摄像头（Linux 主线有 sensor 驱动 + libcamera 生态），modem 最后做；
- 传感器 hub（SCP）、充电/电量、显示、触摸、WiFi/BT、音频、振动、手电筒都已经在主线工作，见 [HARDWARE](HARDWARE.md)。
