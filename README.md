<div align="center">

# 📱 红米 Note 11T 5G · 多发行版 Linux

**把手机刷成一台 106 GiB、SSH 可登、带 WiFi/触摸/音频的 Linux 小电脑**

[![设备](https://img.shields.io/badge/设备-evergo%20%2F%20everpal-FF6900?style=for-the-badge&logo=xiaomi&logoColor=white)](https://github.com/ccmx200/redmi_note115G_pmos)
[![SoC](https://img.shields.io/badge/SoC-MT6833%20天玑810-00A3E0?style=for-the-badge)](https://github.com/ccmx200/redmi_note115G_pmos)
[![内核](https://img.shields.io/badge/内核-7.3.0--rc4-FCC624?style=for-the-badge&logo=linux&logoColor=black)](https://github.com/ccmx200/linux-evergo)
[![发行版](https://img.shields.io/badge/发行版-Arch%20%7C%20Debian%20%7C%20Ubuntu%20%7C%20Fedora-1793D1?style=for-the-badge)](https://github.com/ccmx200/redmi_note115G_pmos/releases)

</div>

---

## 这是什么

Redmi Note 11T 5G（codename `evergo` / `everpal`，MT6833 天玑 810）的 **mainline Linux 成品镜像**：刷完直接进 Linux，不是 Android、也不是容器。

- 内核：[`ccmx200/linux-evergo`](https://github.com/ccmx200/linux-evergo)（基于 [KevinLmK0702/linux-evergo](https://github.com/KevinLmK0702/linux-evergo) 继续 mainline 化）
- 本仓库：把内核 + 发行版 rootfs 打包成 `boot.img` / `userdata` 的构建系统与预编译镜像

| 发行版 | 版本 | 包管理器 | 说明 |
|:---|:---|:---:|:---|
| 🟦 Arch Linux ARM | rolling | `pacman` | 体积最大，软件最新 |
| 🟥 Debian | 13 (trixie) | `apt` | 最小最稳 |
| 🟧 Ubuntu | 26.04 LTS | `apt` | 可选 GNOME / XFCE / Phosh 桌面 |
| 🟪 Fedora | 44 | `dnf` | — |

每个发行版都有 **6 GiB / 8 GiB** 内存变体，**必须和手机的 RAM 匹配**。

---

## 快速开始

### 1. 下载

到 [**Releases**](https://github.com/ccmx200/redmi_note115G_pmos/releases) 下载：

- `boot-<发行版>-<内存>gib.img`（内核 + initramfs，所有发行版通用，但按内存分）
- `userdata-<发行版>-<内存>gib.simg`（发行版根文件系统）

### 2. 刷入

```bash
# 进 fastboot 后
fastboot -S 200M flash boot_a   boot-debian-6gib.img
fastboot -S 200M flash boot_b   boot-debian-6gib.img
fastboot -S 200M flash userdata userdata-debian-6gib.simg
fastboot reboot
```

> ⚠️ 会清空 Android 数据；想回 Android 用 `fastboot --set-active=a` 并重新格式化数据分区。
> Windows 刷 6 GiB 文件有坑，见 [刷机教程](docs/TUTORIAL.md#windows-用户注意)。

### 3. 登录

首次开机约 **1–10 分钟**（自动把 userdata 扩容到 106 GiB），然后手机通过 USB 网卡出现在电脑上：

```bash
ssh root@169.254.42.1     # 密码 evergo
```

没有串口、不用驱动：插电脑零配置，插路由器还能直接上网。

### 4. 联网（可选）

```bash
nmtui                                  # TUI 里选 Wi-Fi，输入密码
# 或
evergo-wifi scan
evergo-wifi connect "Wi-Fi 名称" "密码"
```

USB 网络与 Wi-Fi 可同时使用，互不影响。

---

## 常用命令

```bash
evergo-info            # 一屏系统概览
evergo-mode status     # USB 网络模式（pc / router）
evergo-wifi scan       # 扫描 Wi-Fi
evergo-wifi connect SSID 密码
swapon --show          # 确认 zram 交换已启用
```

---

## 已知限制（重要）

| 项 | 状态 |
|:---|:---|
| 内存高压力下可能 panic | 已知硬件/内核问题，镜像已用 zram 缓解；跑桌面/重负载前确认交换已启用，详见 [PANIC](docs/PANIC.md) |
| CPU / GPU 调频 | 已移植、编译通过，**尚未在真机验证**（内核分支 `dvfs-idle`），当前为固定频率 |
| CPU idle / 深度待机 | PSCI idle 已移植但未验证；s2idle 可手动进/出，默认不自动休眠 |
| 蓝牙 | 控制器能上电，但出厂地址主线读不到，BlueZ 暂不可用 |
| 基带 / 相机 / NFC | 暂不支持（无驱动） |
| 面板 | 两种面板（Tianma / CSOT），刷机时选 `PANEL` 对应的 boot.img |

---

## 文档

**使用类**

| 文档 | 内容 |
|:---|:---|
| 📖 [刷机与使用教程](docs/TUTORIAL.md) | 下载、刷机、首次开机、联网、包管理 |
| 🔌 [硬件支持与清单](docs/HARDWARE.md) | 支持矩阵、硬件清单、限制 |
| 🕳️ [踩坑记录](docs/TROUBLESHOOTING.md) | 按症状查：启动失败、不扩容、连不上、构建报错 |
| 🩺 [抓 panic 日志](docs/PANIC.md) | 无串口时从 expdb/pstore 取崩溃 trace |

**技术/开发类**

| 文档 | 内容 |
|:---|:---|
| 🐧 [内核移植状态](docs/KERNEL.md) | 内核仓库、已合入提交、DVFS/idle 分支与验证计划 |
| 🛠️ [构建指南](docs/BUILDING.md) | 本地构建、CI 参数、多发行版机制、内核配置 |
| 🧩 [内核模块与设备](docs/MODULES.md) | 各子系统驱动/设备树分布 |
| 🧪 [压力测试](docs/STRESS.md) | 压测项目与结果记录 |
| 🏗️ [Vendor 移植笔记](docs/VENDOR-PORT.md) | vendor 镜像/DTB 分析摘要 |

---

## ⚠️ 警告

> 🗑️ **会清空 Android 数据**（userdata 是 FBE 加密，主线 Linux 读不了）。
>
> 🚫 **非官方支持**：与小米、联发科无关，刷机风险自负。

---

## 致谢

| 贡献 | 来源 |
|:---|:---|
| 🧠 内核移植起点 | [KevinLmK0702/linux-evergo](https://github.com/KevinLmK0702/linux-evergo) |
| 🐧 Arch 根文件系统 | [Arch Linux ARM](https://archlinuxarm.org/) |
| 💡 分区扩容思路 | [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)、[postmarketOS](https://postmarketos.org/) |
| 🔧 MT6833 主线化参考 | Poco M3 Pro 5G（camellia）、[A22x mainline](https://github.com/Dodaskot/a22x-mainline) |

<div align="center">

**GPL-2.0** · ⭐ 如果这个项目帮到你，点个 Star

</div>
