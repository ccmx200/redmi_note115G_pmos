<div align="center">

# 📱 红米 Note 11T 5G · 多发行版 Linux

**给 Redmi Note 11T 5G 装上真正的 Linux —— Arch / Debian / Ubuntu / Fedora 任选**

[![设备](https://img.shields.io/badge/设备-evergo%20%2F%20everpal-FF6900?style=for-the-badge&logo=xiaomi&logoColor=white)](https://github.com/ccmx200/redmi_note115G_pmos)
[![SoC](https://img.shields.io/badge/SoC-MT6833%20天玑810-00A3E0?style=for-the-badge)](https://github.com/ccmx200/redmi_note115G_pmos)
[![内核](https://img.shields.io/badge/内核-7.3.0--rc4-FCC624?style=for-the-badge&logo=linux&logoColor=black)](https://github.com/ccmx200/linux-evergo)
[![发行版](https://img.shields.io/badge/发行版-Arch%20%7C%20Debian%20%7C%20Ubuntu%20%7C%20Fedora-1793D1?style=for-the-badge)](https://github.com/ccmx200/redmi_note115G_pmos/releases)

</div>

---

## ✨ 这是什么

这不是 Android，也不是套壳 —— 是**跑在手机裸硬件上的完整 Linux 系统**。

基于 [KevinLmK0702](https://github.com/KevinLmK0702/linux-evergo) 的 MT6833 主线内核移植，本仓库负责把内核、根文件系统、引导镜像打包成**刷完就能用**的成品。

> 🎯 **一句话**：`fastboot` 刷两个文件，手机就变成一台 **106 GiB 存储、SSH 可登**的 Linux 电脑。

### 支持的发行版

| 发行版 | 版本 | 用户data 体积 | 包管理器 |
|:---|:---|:---:|:---|
| 🟦 **Arch Linux ARM** | rolling | 840 MB | `pacman` |
| 🟥 **Debian** | 13 (trixie) | 162 MB | `apt` |
| 🟧 **Ubuntu** | 26.04 LTS (resolute) | 206 MB | `apt` |
| 🟪 **Fedora** | 44 | 142 MB | `dnf` |

每个发行版都提供 **6 GiB / 8 GiB** 两种内存变体（对应手机的 RAM 版本）。

---

## 🚀 三分钟上手

### 1️⃣ 下载

前往 [**Releases**](https://github.com/ccmx200/redmi_note115G_pmos/releases) 下载，文件名规则：

```
boot-<发行版>-<内存>gib.img          引导镜像
userdata-<发行版>-<内存>gib.img.gz   根文件系统（首次开机自动扩到 106 GiB）
SHA256SUM-<发行版>-<内存>gib.txt     校验和
```

例如 Debian + 6 GiB 内存：`boot-debian-6gib.img` + `userdata-debian-6gib.img.gz`

> 🧠 **内存变体只影响内核设备树**。4 GiB 机型请用 `6gib`（向下兼容），**8 GiB 机型务必用 `8gib`**。

### 2️⃣ 刷入

```bash
# 解压根文件系统
gunzip userdata-debian-6gib.img.gz

# 刷引导（两个槽都刷，避免掉槽）
fastboot -S 200M flash boot_a boot-debian-6gib.img
fastboot -S 200M flash boot_b boot-debian-6gib.img

# 刷根文件系统（必须加 -S）
fastboot -S 200M flash userdata userdata-debian-6gib.img

# 重启
fastboot reboot
```

<details>
<summary>💡 <b>Windows 用户注意</b>（fastboot 会崩，点开）</summary>

Windows 版 `fastboot` 会把整个 6 GiB 镜像读进内存然后崩溃（`std::bad_alloc`）。两招：

**流式刷入**
```bash
gunzip -c userdata-debian-6gib.img.gz | fastboot -S 200M flash userdata -
```

**先转稀疏镜像**（推荐，6 GiB → 约 2.1 GB，快得多）
```bash
img2simg userdata-debian-6gib.img userdata.simg
fastboot -S 200M flash userdata userdata.simg
```
</details>

### 3️⃣ 开机

⏳ **首次开机约 1-10 分钟** —— 系统会自动把 6 GiB 根分区扩展到整块 eMMC（约 106 GiB）：

```
6 GiB  →  106 GiB     ← 全自动，之后每次开机都很快
```

---

## 🔌 联网说明

> ⚠️ **本方案没有串口！** COM / 串口控制台已完全移除。
>
> 手机通过 **USB RNDIS 网卡**（`usb0`）接入，只能走网络管理。

### 手机的两个「身份」

手机内部固定持有链路本地地址 **`169.254.42.1/16`**，这是永远不会变的锚点。在此基础上，`usb0` 有两种工作模式：

| 模式 | 命令 | 手机做什么 | 对端做什么 | 适用场景 |
|:---|:---|:---|:---|:---|
| 🌐 **router** | `evergo-mode router` | **DHCP 客户端** + 保持 `169.254.42.1` | 路由器分配 IP | 插路由器 USB 口，**要外网** |
| 💻 **pc** | `evergo-mode pc` | **DHCP 服务端**（`192.168.42.1/24`） | 电脑自动获取 IP | 直连电脑，**没路由器** |

**默认是 `router` 模式**，且始终保留 `169.254.42.1` —— 所以**任何情况下直连电脑都能登**。

---

### 场景一：直连电脑（最简单，零配置）

```
┌──────────┐   USB 线   ┌──────────┐
│   手机    │◄─────────►│   电脑    │
│169.254.42.1│          │ 自动 APIPA│
└──────────┘            └──────────┘
```

**步骤**：

1. 手机用 USB 线插到电脑
2. 等系统起来（首次开机要扩容，约 10 分钟）
3. 直接 SSH：

```bash
ssh root@169.254.42.1
```

**电脑需要配置什么？** 什么都不用。Windows / macOS / Linux 都会自动给 RNDIS 网卡分配 `169.254.x.x` 的链路本地地址，和 `169.254.42.1` 天然同网段。

> 🔑 默认密码：`evergo`

**验证连没连上**：

```bash
# Windows
ipconfig | findstr 169.254
ping 169.254.42.1

# Linux / macOS
ip addr show | grep 169.254
ping -c 3 169.254.42.1
```

---

### 场景二：插路由器（要外网）

```
┌──────────┐  USB 线  ┌──────────┐        ┌────────┐
│   手机    │◄────────►│  路由器   │◄──────►│ 互联网  │
│ DHCP 客户端│          │  br-lan  │        └────────┘
└──────────┘            └──────────┘
```

手机作为 **DHCP 客户端**加入路由器所在的 LAN，拿到 `192.168.x.x` 的地址，**直接就能上网**：

```bash
# 在手机上验证
ping -c 3 baidu.com
apt update          # 或 pacman -Sy / dnf check-update
```

**这时候怎么 SSH 进去？**

两个办法：

```bash
# 办法 1：查路由器的 DHCP 租约表，找到 usb0 的 MAC 对应的 IP
# 办法 2（推荐）：插到电脑上，用固定的 169.254.42.1 登录后执行
evergo-info                 # 看当前所有 IP
```

> 💡 手机的 `169.254.42.1` 在 router 模式下**依然存在**，所以插电脑永远是后门。

**OpenWrt 系路由器**：默认不会把 USB 网卡桥进 LAN，需要装热插拔脚本，见 [路由器自动桥接](#-路由器自动桥接)。

---

### 场景三：电脑也要能上网（pc 模式）

直连电脑、又想让电脑通过手机联网？—— 目前**不支持 USB 反向共享**（手机没有上行链路）。`evergo-mode pc` 只是让手机当 DHCP 服务端，方便电脑免配置拿到 `192.168.42.x`。

---

### 首次登录向导

第一次 SSH 登录会进入彩色设置向导：

```
  ┌──────────────────────────────────────────────────────────────┐
  │   🐧  evergo   ·   Debian GNU/Linux 13   ·   首次登录设置      │
  │       Redmi Note 11T 5G  ·  MediaTek MT6833                  │
  └──────────────────────────────────────────────────────────────┘

  [1/3]  用户账户
  ─────────────────────────────────────────────────────────────
  ?  创建普通用户？[Y/n]
  ?  用户名 [evergo] :
  ?  密码（输入时不显示）  :
  ?  再输一次           :

  [2/3]  主机名
  ?  主机名 [evergo] :

  [3/3]  root 密码
  ?  修改 root 密码？[y/N]
```

全部可以跳过，直接继续用 `root` / `evergo`。

登录后的欢迎界面（fastfetch + 设备信息）：

```
                                      root@evergo
                   -`                -----------
                  .o+`               OS       Debian GNU/Linux 13
                 `ooo/               Kernel   7.3.0-rc4-gcb9ba2ee0f92
                `+oooo:              Uptime   5 hours, 6 mins
               `+oooooo:             Packages 203 (dpkg)
               -+oooooo+:            Shell    bash
             `/:-:++oooo+:           Memory   495 MiB / 5.63 GiB
            `/++++/+++++++:          Disk     2.1 GiB / 106 GiB (2%) ext4
           `/+++ooooooooooooo/`      CPU      mt6833 (8)
          ./ooosssso++osssssso+      -----------
         .oossssso-````/ossssss+     Network  usb0
        -osssssso.      :ssssssso.   Local IP 169.254.42.1
```

---

### 连不上？按这个顺序查

| 步骤 | 检查项 | 命令 / 方法 |
|:---:|:---|:---|
| 1 | 电脑认到网卡了吗 | 设备管理器看有没有 `USB Ethernet/RNDIS Gadget`；Linux 看 `dmesg \| tail` |
| 2 | 网卡是 Up 吗 | Windows `ipconfig`；Linux `ip link` |
| 3 | 等够时间了吗 | **首次开机要扩容约 10 分钟**，期间网卡已 Up 但还没配 IP |
| 4 | 电脑有 169.254 地址吗 | `ipconfig \| findstr 169.254` |
| 5 | ping 通吗 | `ping 169.254.42.1` |
| 6 | 端口通吗 | 用 `Test-NetConnection 169.254.42.1 -Port 22` 或 `nc -zv 169.254.42.1 22` |
| 7 | 防火墙拦了吗 | 电脑防火墙可能要放行「公用网络」 |

**症状对照**：

| 现象 | 可能原因 |
|:---|:---|
| 网卡**完全没出现** | 内核没启动（boot.img 问题），或 USB 线只有充电功能 |
| 网卡出现但**一直 Disconnected** | initramfs 阶段；扩容中 |
| 网卡 **Up 但 ping 不通** | 还没到用户态；或 systemd 没起来 |
| **ping 通但 22 端口关** | sshd 没启动；看屏幕有没有报错 |
| 开机**反复回到 Redmi logo** | boot.img 有问题（见 [TROUBLESHOOTING](docs/TROUBLESHOOTING.md)） |

---

### 路由器自动桥接

OpenWrt / LibWrt 默认**不会**把 USB 网卡桥进 LAN。把下面的脚本放到 `/etc/hotplug.d/net/40-evergo-usb`：

```sh
#!/bin/sh
# 手机插入路由器 USB 口后自动桥进 br-lan
[ "$ACTION" = "add" ] || exit 0
case "$INTERFACE" in wan|lan3|pppoe-wan*|rmnet*) exit 0 ;; esac
DEVLINK=$(readlink -f "/sys/class/net/$INTERFACE/device" 2>/dev/null)
case "$DEVLINK" in *usb*) ;; *) exit 0 ;; esac
[ -e "/sys/class/net/$INTERFACE/brport" ] && exit 0
ip link set "$INTERFACE" up
ip link set "$INTERFACE" master br-lan
```

```bash
chmod +x /etc/hotplug.d/net/40-evergo-usb
```

之后手机插上路由器 USB 口就会被 DHCP 分配地址，直接联网。

---

## 🎛️ 常用命令

### `evergo-mode` —— USB 工作模式

```bash
evergo-mode status      # 查看当前模式
evergo-mode router      # DHCP 客户端（插路由器，默认）
evergo-mode pc          # DHCP 服务端（直连电脑）
```

### `evergo-info` —— 一屏系统概览

```bash
evergo-info
```

### 包管理器

```bash
# Arch
pacman -Syu && pacman -S <包名>

# Debian / Ubuntu
apt update && apt install <包名>

# Fedora
dnf update && dnf install <包名>
```

> 📦 **国内源已预配置**（清华），开箱即可用。

---

## ✅ 硬件支持

| 子系统 | 状态 | 说明 |
|:---|:---:|:---|
| 🧠 主控 | ✅ | MT6833 / 天玑 810，8 核 |
| 💾 存储 | ✅ | 128 GB eMMC，自动扩展到 ~106 GiB |
| 🖥️ 显示 | ✅ | `mediatekdrmfb` 帧缓冲控制台 |
| 🌐 USB 网络 | ✅ | RNDIS，高速模式，实测 ~4.5 MB/s |
| 🔌 SSH | ✅ | 密码登录，密钥已禁用 |
| ⏱️ 硬件看门狗 | ✅ | 自动喂狗，不再 33 秒重启 |
| 💿 内存 | ✅ | 6 GiB 版本实测 5.63 GiB 可用 |

### 🚧 尚未完成

| 项目 | 说明 |
|:---|:---|
| 🔋 PMIC（MT6359） | 未接入，稳压器按固定电压处理 |
| 📶 Wi-Fi / 蓝牙 | 由其他人负责 |
| 📞 基带 / 通话 | 未支持 |
| 🔊 音频 | 未支持 |
| 📷 相机 | 未支持 |
| 👆 触摸屏固件 | 未完成 |
| 🔌 USB Host（OTG） | 未支持 |

---

## 🛠️ 自己构建

### GitHub Actions（推荐）

Fork 本仓库 → **Actions** → 「build evergo images」→ **Run workflow**

可选参数：`distro`（arch / debian / ubuntu / fedora / all）、`ram_gib`（6 / 8 / all）、`panel`、`rootfs_mb`

构建完成后自动发布到 Releases，一个 release 包含所有组合。

### 本地构建

```bash
git clone https://github.com/ccmx200/redmi_note115G_pmos.git
cd redmi_note115G_pmos

# 需要：root 权限、qemu-user-static、mke2fs
sudo DISTRO=debian RAM_GIB=6 ./build.sh
```

产物在 `out/`：

```
out/boot.img           引导镜像
out/userdata.img       6 GiB ext4 根文件系统
out/userdata.img.gz    压缩版
out/userdata.simg      稀疏版（fastboot 用）
out/SHA256SUMS         校验和
```

### 环境变量

| 变量 | 默认值 | 说明 |
|:---|:---|:---|
| `DISTRO` | `arch` | `arch` / `debian` / `ubuntu` / `fedora` |
| `RAM_GIB` | `6` | 内存版本（4 / 6 / 8） |
| `PANEL` | `k16a_36_02_0a_vdo,lcm` | 屏幕型号（华星为 `k16a_42_02_0b_vdo,lcm`） |
| `ROOTFS_MB` | `6144` | 根文件系统初始大小 |
| `KERNEL_SRC` | *(空)* | 复用已有内核源码树 |
| `MIRROR_HOST` | `mirrors.ocf.berkeley.edu` | Arch 构建时的镜像站 |

---

## 🔬 构建原理

```
┌──────────────────────────────────────────────────────────┐
│  1. 内核                                                  │
│     克隆 ccmx200/linux-evergo @ cb9ba2ee（锁定版本）       │
│     应用 config/evergo.config（硬件验证过的配置）          │
│     打 4 处设备树补丁：                                    │
│       • 内存大小（6/8 GiB）                                │
│       • 屏幕型号（天马/华星）                              │
│       • USB 高速模式                                       │
│       • 精简启动参数                                       │
├──────────────────────────────────────────────────────────┤
│  2. 根文件系统（按发行版分派）                             │
│     scripts/distro-<name>.sh 生成一个普通目录             │
│       arch   → 官方 tarball + pacman                      │
│       debian → mmdebstrap (trixie)                        │
│       ubuntu → mmdebstrap (resolute)                      │
│       fedora → dnf --installroot                          │
│     全部配置国内源（清华）                                 │
├──────────────────────────────────────────────────────────┤
│  3. 镜像                                                  │
│     mke2fs -d 一步生成 6 GiB ext4（不需要 loop/root）      │
├──────────────────────────────────────────────────────────┤
│  4. initramfs（4.7 MB）                                   │
│     静态 busybox + e2fsck + resize2fs                     │
│     首次开机：挂载 → e2fsck → resize2fs → 重挂 → 快照     │
│     失败时标记不写，下次开机重试                           │
├──────────────────────────────────────────────────────────┤
│  5. 打包                                                  │
│     mkbootimg 生成 boot.img → avb.py 追加 AVB footer      │
└──────────────────────────────────────────────────────────┘
```

---

## 📐 分区布局

```
┌─────────────────────────────────────────────────────┐
│  preloader / misc / … / super   （Android 系统区）    │
├─────────────────────────────────────────────────────┤ ← 0x304000000 (12.06 GiB)
│                                                      │
│              userdata  ← 我们装系统的位置             │
│              loop0 覆盖 107.1 GiB                     │
│              ext4 首次开机扩到 ~106 GiB               │
│                                                      │
└─────────────────────────────────────────────────────┘ ← 119.2 GiB (eMMC 实际容量)
```

> ⚠️ scatter 里 userdata 只声明了 10 GiB，但 LK 实际报告 **226 GiB**，loop 设备能覆盖到盘尾 **107.1 GiB**。

---

## 🕳️ 遇到问题？

启动失败、不扩容、连不上、构建报错 —— 全部整理在 **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**，按症状搜。

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

## 🙏 致谢

| 贡献 | 来源 |
|:---|:---|
| 🧠 内核移植 | [KevinLmK0702/linux-evergo](https://github.com/KevinLmK0702/linux-evergo) |
| 📦 内核打包参考 | [ccmx200/linux-evergo](https://github.com/ccmx200/linux-evergo) |
| 🐧 Arch 根文件系统 | [Arch Linux ARM](https://archlinuxarm.org/) |
| 💡 分区扩容思路 | [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)、[postmarketOS](https://postmarketos.org/) |
| 🔧 MT6833 主线化起点 | Poco M3 Pro 5G（camellia）项目 |

---

<div align="center">

**GPL-2.0** · 与内核协议一致

⭐ 如果这个项目帮到你，点个 Star 吧

</div>
