<div align="center">

# 📱 红米 Note 11T 5G · 多发行版 Linux

**把手机变成一台 106 GiB 存储、SSH 可登的 Linux 电脑**

[![设备](https://img.shields.io/badge/设备-evergo%20%2F%20everpal-FF6900?style=for-the-badge&logo=xiaomi&logoColor=white)](https://github.com/ccmx200/redmi_note115G_pmos)
[![SoC](https://img.shields.io/badge/SoC-MT6833%20天玑810-00A3E0?style=for-the-badge)](https://github.com/ccmx200/redmi_note115G_pmos)
[![内核](https://img.shields.io/badge/内核-7.3.0--rc4-FCC624?style=for-the-badge&logo=linux&logoColor=black)](https://github.com/ccmx200/linux-evergo)
[![发行版](https://img.shields.io/badge/发行版-Arch%20%7C%20Debian%20%7C%20Ubuntu%20%7C%20Fedora-1793D1?style=for-the-badge)](https://github.com/ccmx200/redmi_note115G_pmos/releases)

</div>

---

## 这是什么

Redmi Note 11T 5G（MT6833 / 天玑 810）的 **mainline Linux** 镜像。不是 Android，也不是套壳 —— 是跑在手机裸硬件上的完整 Linux 系统。

基于 [KevinLmK0702](https://github.com/KevinLmK0702/linux-evergo) 的内核移植，本项目负责打包成**刷完就能用**的成品。

| 发行版 | 版本 | userdata A 体积 | 包管理器 |
|:---|:---|:---:|:---|
| 🟦 Arch Linux ARM | rolling | 840 MB | `pacman` |
| 🟥 Debian | 13 (trixie) | 162 MB | `apt` |
| 🟧 Ubuntu | 26.04 LTS | 206 MB | `apt` |
| 🟪 Fedora | 44 | 142 MB | `dnf` |

每个发行版都有 **6 GiB / 8 GiB** 两种内存变体（对应手机 RAM）。

---

## 快速开始

### 1. 下载

[**Releases**](https://github.com/ccmx200/redmi_note115G_pmos/releases) → 选 `boot-<发行版>-<内存>gib.img` + `userdata-<发行版>-<内存>gib.img.gz`

> 🧠 内存变体必须和手机匹配。4 GiB 机型用 `6gib`，**8 GiB 机型必须用 `8gib`**。

### 2. 刷入

```bash
gunzip userdata-debian-6gib.img.gz

fastboot -S 200M flash boot_a    boot-debian-6gib.img
fastboot -S 200M flash boot_b    boot-debian-6gib.img
fastboot -S 200M flash userdata  userdata-debian-6gib.img
fastboot reboot
```

> 💡 Windows 版 fastboot 处理不了 6 GiB 文件，见 **[教程](docs/TUTORIAL.md#windows-用户注意)**。

### 3. 连上

**首次开机约 1-10 分钟**（自动扩容 6 GiB → 106 GiB），然后：

```bash
ssh root@169.254.42.1        # 密码 evergo
```

**没有串口** —— 手机通过 USB RNDIS 网卡接入。插电脑零配置，插路由器可上网。

📖 **完整图文教程** → **[docs/TUTORIAL.md](docs/TUTORIAL.md)**

---

## 硬件支持

| 子系统 | 状态 |
|:---|:---:|
| 主控 MT6833 / 天玑 810（8 核） | ✅ |
| 存储 128 GB eMMC → 自动扩到 106 GiB | ✅ |
| 显示（`mediatekdrmfb` 帧缓冲控制台） | ✅ |
| USB RNDIS 网络（高速模式，~4.5 MB/s） | ✅ |
| SSH 密码登录 | ✅ |
| 硬件看门狗 | ✅ |

**未完成**：PMIC、Wi-Fi / 蓝牙、基带、音频、相机、触摸固件、USB Host

---

## 文档

| 文档 | 内容 |
|:---|:---|
| 📖 **[刷机与使用教程](docs/TUTORIAL.md)** | 下载、刷机、联网、首次登录、包管理、模式切换 |
| 🛠️ **[构建指南](docs/BUILDING.md)** | 本地构建、CI、多发行版脚本、内核配置 |
| 🕳️ **[踩坑记录](docs/TROUBLESHOOTING.md)** | 按症状查：启动失败、不扩容、连不上、构建报错 |

---

## 常用命令

```bash
evergo-mode status     # 当前 USB 网络模式
evergo-mode router     # DHCP 客户端（插路由器，默认）
evergo-mode pc         # DHCP 服务端（直连电脑）
evergo-info            # 一屏系统概览
```

---

## ⚠️ 警告

> 🗑️ **会清空 Android 数据**。刷入会破坏 userdata 分区（FBE 加密，主线 Linux 本来读不了）。
>
> 想回 Android：`fastboot --set-active=a`，但 Android 会要求重新格式化数据分区。

> 🚫 **非官方支持**。本项目与小米、联发科无关，刷机风险自负。

---

## 致谢

| 贡献 | 来源 |
|:---|:---|
| 🧠 内核移植 | [KevinLmK0702/linux-evergo](https://github.com/KevinLmK0702/linux-evergo) |
| 🐧 Arch 根文件系统 | [Arch Linux ARM](https://archlinuxarm.org/) |
| 💡 分区扩容思路 | [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)、[postmarketOS](https://postmarketos.org/) |
| 🔧 MT6833 主线化起点 | Poco M3 Pro 5G（camellia）项目 |

<div align="center">

**GPL-2.0** · ⭐ 如果这个项目帮到你，点个 Star

</div>
