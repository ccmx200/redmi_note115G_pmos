# 🐧 evergo · 红米 Note 11T 5G 主线 Linux

Redmi Note 11T 5G（`evergo` / `everpal`，联发科 MT6833）的 **mainline Linux** 镜像。
不是 Android，也不是套壳 —— 是跑在手机裸硬件上的完整 Linux 系统。

---

## 📦 本版本内容

| 发行版 | 说明 |
|:---|:---|
| 🟩 Arch Linux ARM | `boot-arch-*.img` · `userdata-arch-*.simg` |
| 🟥 Debian 13 (trixie) | `boot-debian-*.img` · `userdata-debian-*.simg` |
| 🟧 Ubuntu 26.04 LTS | `boot-ubuntu-*.img` · `userdata-ubuntu-*.simg` |
| 🟦 Fedora | `boot-fedora-*.img` · `userdata-fedora-*.simg` |
| 🖥️ Ubuntu 桌面版 | `*-desktop-*`（GNOME / phosh / XFCE，附中文语言与输入法） |

> 🧠 **内存变体只影响内核的设备树** —— 镜像里传给内核的内存大小必须和你的手机一致。
> 4 GiB 机型请用 `6gib` 的版本（向下兼容），8 GiB 机型务必用 `8gib`。

每个文件旁都有对应的 `SHA256SUM-<distro>-<ram>gib.txt` 校验和。

---

## 🚀 刷入

```bash
# 1. 刷引导（两个槽都刷，避免掉槽）
fastboot -S 200M flash boot_a boot-ubuntu-6gib.img
fastboot -S 200M flash boot_b boot-ubuntu-6gib.img

# 2. 刷根文件系统（必须加 -S，否则 fastboot 会因文件过大失败）
fastboot -S 200M flash userdata userdata-ubuntu-6gib.simg

# 3. 重启
fastboot reboot
```

<details>
<summary>💡 <b>Windows 用户注意</b>（fastboot 会崩，点开看解决办法）</summary>

Windows 版 `fastboot` 会把整个镜像读进内存然后崩溃（`std::bad_alloc`）。用 `-S 200M`
分片刷入即可；`.simg` 已经是稀疏镜像，直接刷。

</details>

---

## ⏳ 首次开机

**首次开机约 1~10 分钟** —— 系统会自动把根分区扩展到整块 eMMC（约 106 GiB）：

```
6 GiB  →  106 GiB     ← 全自动，之后每次开机都很快
```

扩展完成后 `df -h /` 会显示约 **103 GiB 可用**。

---

## 🔌 连接手机

### ⚠️ 没有串口！

本方案**完全移除了 COM / 串口控制台**。手机通过 **USB RNDIS 网卡**接入，用 SSH 管理。

**插电脑**（最简单，电脑零配置）：

```bash
ssh root@169.254.42.1          # 密码：evergo
```

手机固定持有链路本地地址 `169.254.42.1`，Windows 会自动分配同网段地址。

**插路由器**（有外网）：手机作为 **DHCP 客户端**加入该 LAN，自动获得 IP 并联网。

### 首次登录向导

第一次登录会自动进入 **彩色向导**（带 emoji 和加载动画）：

```
  ╭──────────────────────────────────────────────────────────╮
  │  🟧 ✨ evergo 首次登录设置 ✨
  │     Ubuntu 26.04 LTS  ·  Redmi Note 11T 5G  ·  MT6833
  ╰──────────────────────────────────────────────────────────╯

  ⠙ 正在检测系统环境… ✔
  • 发行版：Ubuntu 26.04 LTS
  • 包管理：apt update && apt upgrade

  [1/3] 👤 用户账户
  [2/3] 🏠 主机名
  [3/3] 🔑 root 密码
```

可以全部跳过，直接使用 `root`。

---

## 🎛️ 常用命令

| 命令 | 作用 |
|:---|:---|
| `evergo-mode status` | 查看当前 USB 网络模式 |
| `evergo-mode router` | DHCP 客户端（默认）—— 插路由器拿 IP |
| `evergo-mode pc` | DHCP 服务端 —— 直连电脑自动拿 `192.168.42.x` |
| `evergo-info` | 一屏系统概览（内核/内存/温度/网络） |
| `evergo-first-login --force` | 重新运行首次登录向导 |

**国内源已预配置**：Arch 用清华 + 中科大，Debian/Ubuntu/Fedora 用清华，开箱即可
`pacman -S` / `apt install` / `dnf install`。

---

## ✅ 硬件支持

| 子系统 | 状态 |
|:---|:---:|
| 主控 MT6833 / 天玑 810（8 核） | ✅ |
| 存储 128 GB eMMC → 自动扩到 106 GiB | ✅ |
| 显示 K16A 90 Hz（天马 / CSOT） | ✅ |
| 触摸 Novatek NT36672C | ✅ |
| 声音（扬声器 / 耳机 / 麦克风） | ✅ |
| 震动 AW8697 | ✅ |
| 充电 MT6360 + 电量计 MT6359 | ✅ |
| 环境光 TSL2522（自动亮度） | ✅ |
| 磁力计 AK09918 | ✅ |
| RTC 时间同步 | ✅ |
| 电源键短按：关屏 / 亮屏（不休眠） | ✅ |
| 硬件看门狗 | ✅ |
| USB RNDIS 网络 + SSH | ✅ |
| WiFi（WMT）+ 蓝牙（配对/传输/音频） | ✅ |
| GPU：Mali-G57 / Panfrost（合成器使用） | ⚠️ |
| 摄像头、基带/通话、指纹、NFC | ❌ |
| 系统休眠（s2idle 能进能出，但亮屏恢复未完成） | 🚧 |

> ⚠️ **GPU 说明**：vendor 的 GPU 电压/OPP 校准没进主线，浏览器等重负载下 panfrost
> 可能报 `DATA_INVALID/TILE_RANGE` 错误并出现绿色花屏。浏览器已经默认改走软件渲染
> （llvmpipe），合成器仍用 GPU，日常界面保持流畅。

---

## 🕳️ 这个版本修掉的问题

| 问题 | 修复 |
|:---|:---|
| 🏷️ **Ubuntu 登录界面显示 “Arch Linux ARM”** | 登录横幅 / motd / 首次登录向导全部改为从 `/etc/os-release` 读取，按发行版显示正确的名称、logo 和包管理器 |
| 🎨 **首次登录向导太朴素** | 重写：emoji、彩色边框、旋转加载动画、发行版检测、更友好的提示 |
| 💡 **自动亮度偶发失效** | 电源键关屏会暂停自动亮度；开机 / 唤醒 / 登录时强制恢复 `ambient-enabled`，崩溃重启也不会再一直关着 |
| 🟢 **浏览器使用中绿色花屏 + 重启** | 浏览器默认软件渲染（llvmpipe），合成器继续用 GPU；等 GPU 校准数据移植后再改回 |
| ⏰ **时间 / RTC 错乱** | 新增 `evergo-rtc-sync`，开机和关机都同步 RTC |
| 🖥️ **息屏后无法唤醒 / commit 超时** | 电源键改为背光开关 + 锁屏（不再走有问题的 DRM disable 路径） |
| 🐧 **开机看不到小企鹅** | 去掉 `fbcon=nodefer` |
| 🔑 **全新刷入登不进去** | 构建时设置 root 默认密码 `evergo` |

---

## 📚 更多

完整文档见仓库 [README](https://github.com/ccmx200/redmi_note115G_pmos#readme)。

---

## ⚠️ 警告

> 🗑️ **会清空 Android 数据**
>
> 刷入本镜像会破坏 Android 的 userdata 分区（FBE 加密，主线 Linux 本来就读不了）。
>
> 想回 Android：`fastboot --set-active=a`，但 Android 会要求重新格式化数据分区。

> 🚫 **非官方支持**
>
> 本项目与小米、联发科无关。刷机有风险，变砖自负。

---

<div align="center">

**GPL-2.0**

🙏 内核移植：[KevinLmK0702/linux-evergo](https://github.com/KevinLmK0702/linux-evergo)

</div>
