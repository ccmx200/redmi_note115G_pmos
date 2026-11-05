# 🐧 evergo · 红米 Note 11T 5G 主线 Linux

Redmi Note 11T 5G（`evergo` / `everpal`，联发科 MT6833）的 **mainline Linux** 镜像。
不是 Android，也不是套壳 —— 是跑在手机裸硬件上的完整 Linux 系统。

---

## 📦 本版本内容

| 发行版 | 内存变体 | 文件 |
|:---|:---:|:---|
| 🟦 Arch Linux ARM | 6 GiB / 8 GiB | `boot-arch-6gib.img` · `userdata-arch-6gib.img.gz` |
| 🟥 Debian 13 (trixie) | 6 GiB / 8 GiB | `boot-debian-6gib.img` · `userdata-debian-6gib.img.gz` |
| 🟧 Ubuntu 26.04 LTS | 6 GiB / 8 GiB | `boot-ubuntu-6gib.img` · `userdata-ubuntu-6gib.img.gz` |
| 🟪 Fedora | 6 GiB / 8 GiB | `boot-fedora-6gib.img` · `userdata-fedora-6gib.img.gz` |

> 🧠 **内存变体只影响内核的设备树** —— 镜像里传给内核的内存大小必须和你的手机一致。
> 4 GiB 机型请用 `6gib` 的版本（向下兼容），8 GiB 机型务必用 `8gib`。

每个文件旁都有对应的 `SHA256SUM-<distro>-<ram>gib.txt` 校验和。

---

## 🚀 刷入

```bash
# 1. 解压根文件系统（6 GiB）
gunzip userdata-arch-6gib.img.gz

# 2. 刷引导（两个槽都刷，避免掉槽）
fastboot -S 200M flash boot_a boot-arch-6gib.img
fastboot -S 200M flash boot_b boot-arch-6gib.img

# 3. 刷根文件系统（必须加 -S，否则 fastboot 会因文件过大失败）
fastboot -S 200M flash userdata userdata-arch-6gib.img

# 4. 重启
fastboot reboot
```

<details>
<summary>💡 <b>Windows 用户注意</b>（fastboot 会崩，点开看解决办法）</summary>

Windows 版 `fastboot` 会把整个 6 GiB 镜像读进内存然后崩溃（`std::bad_alloc`）。两种办法：

**方法一：流式刷入**
```bash
gunzip -c userdata-arch-6gib.img.gz | fastboot -S 200M flash userdata -
```

**方法二：先转稀疏镜像**（推荐，最快，6 GiB → 约 2.1 GB）
```bash
img2simg userdata-arch-6gib.img userdata.simg
fastboot -S 200M flash userdata userdata.simg
```
</details>

---

## ⏳ 首次开机

**首次开机约 10 分钟** —— 系统会自动把 6 GiB 的根分区扩展到整块 eMMC（约 106 GiB）：

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

第一次登录会自动进入彩色设置向导：

```
┌──────────────────────────────────────────────────────────────┐
│   🐧  evergo   ·   Arch Linux ARM   ·   首次登录设置          │
│       Redmi Note 11T 5G  ·  MediaTek MT6833                  │
└──────────────────────────────────────────────────────────────┘

  [1/3]  用户账户
  ──────────────────────────────────────────────────────────────
  ?  创建普通用户？[Y/n]
  ?  用户名 [evergo] :
  ?  密码（输入时不显示）  :

  [2/3]  主机名
  [3/3]  root 密码
```

可以全部跳过，直接使用 `root`。

---

## 🎛️ 常用命令

| 命令 | 作用 |
|:---|:---|
| `evergo-mode status` | 查看当前 USB 网络模式 |
| `evergo-mode router` | DHCP 客户端（默认）—— 插路由器拿 IP |
| `evergo-mode pc` | DHCP 服务端 —— 直连电脑自动拿 `192.168.42.x` |
| `evergo-info` | 一屏系统概览 |

**国内源已预配置**：Arch 用清华 + 中科大，Debian/Ubuntu/Fedora 用清华，开箱即可 `pacman -S` / `apt install` / `dnf install`。

---

## ✅ 硬件支持

| 子系统 | 状态 |
|:---|:---:|
| 主控 MT6833 / 天玑 810（8 核） | ✅ |
| 存储 128 GB eMMC → 自动扩到 106 GiB | ✅ |
| 显示（`mediatekdrmfb` 帧缓冲） | ✅ |
| USB RNDIS 网络（高速模式，~4.5 MB/s） | ✅ |
| SSH 密码登录 | ✅ |
| 硬件看门狗 | ✅ |

**未完成**：PMIC、CPU 调频（cpufreq）、Wi-Fi / 蓝牙、基带、音频、相机、触摸固件、USB Host。

---

## 🕳️ 这个版本修掉的问题

| 问题 | 修复 |
|:---|:---|
| 🐧 **开机看不到小企鹅** | 去掉 bootargs 里的 `fbcon=nodefer` —— 它让 fbcon 在 DSI 面板就绪前接管，企鹅被擦掉 |
| 💤 **控制台刷屏 `sleep: not found`** | 改用 `busybox --install -s` 链接**全部** applet，不再靠手写列表 |
| 🎨 向导简陋 | 重写：彩色、边框、分步、密码二次确认、`✔/✘` 状态 |
| 💾 根分区只有 6 GiB | 首次开机自动 `resize2fs` 扩到 106 GiB |
| 🔑 全新刷入登不进去 | 构建时设置 root 默认密码 `evergo` |

---


## ✨ 本版本新增

| 能力 | 说明 |
|:---|:---|
| 🌡️ SoC 温度监控 | 移植 MT6833 LVTS：13 个热区（CPU/GPU/SOC/CONNSYS/MD），只读、不会误降频（`/sys/class/thermal/thermal_zone*/temp`） |
| 🖥️ DRM 管线修复 | 移除 bring-up 的 OVL/RDMA 跳过、错误的 mutex SOF 覆盖、DSI 关屏死等；息屏/休眠 resume 后屏幕自动回来，不再需要按音量键 |
| ⏰ 自动网络校时 | 所有发行版启用 systemd-timesyncd（阿里/腾讯/cn.pool/Cloudflare 备用），与 RTC 备份逻辑配合，联网即自动同步 |
| 💾 zram 交换 | 用 zstd zram（RAM 一半大小）替代 eMMC swapfile：更快、不磨闪存 |
| 🐌 存储与 I/O | 根分区 noatime（initramfs + fstab）、fstrim.timer、zram 推荐 sysctl（swappiness=180, page-cluster=0） |
| 📦 内核精简 | 关闭 DEBUG_INFO（vmlinux 减小约 61%，boot 负载不变），panic 栈符号保留 |
| 🔐 构建可信 | 下载 ubuntu-base/Arch/Fedora 时校验 SHA256/GPG（Arch 公钥已入库），内核 pin 拉取失败直接报错，不再静默换树 |
| 🔋 **电池电压/容量错误** | fuel-gauge 原来读 MT6359 阻抗通道（负电压）、电压单位又溢出、OCV 表放大 10 倍；改读 MT6360 ADC VBAT 并修正单位/表后，电压、百分比、charge_now 都正确 |
| 🔦 **手电筒/闪光灯** | MT6360 白闪 LED 已可用；新增 `evergo-torch on/off/toggle/strobe/status`（真机验证 1–7 档与相机闪光，无 fault） |
| ⚡ **CPU/GPU 调频** | CPU DVFS（小核 950 MHz–2 GHz / 大核 725 MHz–2 GHz）和 GPU DVFS（390–880 MHz）已合入内核，s2idle 同时启用也正常 |
| 📶 **WiFi SSH 断线** | NetworkManager 自带的 default-wifi-powersave-on.conf 会打开 WiFi 省电并覆盖 evergo 的设置；新增 99-evergo-wifi-powersave.conf 强制关闭省电，避免 wlan0 上 SSH 卡死/掉线 |
| 🔌 **USB SSH 断线** | MUSB gadget 控制器运行时自动休眠会让 usb0 carrier 掉线；新增 evergo-usb-stability.service 在启动时把 USB 控制器固定为 control=on，并在 sshd 增加 keepalive |
| 🔁 首次开机自动重启一次 | 首次开机会自动重启一次，让 USB/网络状态彻底初始化，解决之后 SSH 间歇性断线的问题 |
| 👆 息屏唤醒后触摸失灵 | Novatek 触摸驱动补上系统休眠/唤醒回调：suspend 深睡、resume 复位 TP_RST 并重新使能中断，唤醒后触摸立即可用 |

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
