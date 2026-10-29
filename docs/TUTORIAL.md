# 📖 刷机与使用教程

> 从下载到能用，一步步来。遇到问题查 [踩坑记录](TROUBLESHOOTING.md)。

## 目录

- [一、准备](#一准备)
- [二、下载镜像](#二下载镜像)
- [三、刷入](#三刷入)
- [四、首次开机](#四首次开机)
- [五、联网](#五联网)
- [六、首次登录向导](#六首次登录向导)
- [七、日常使用](#七日常使用)
- [八、路由器桥接](#八路由器桥接)
- [九、常见问题](#九常见问题)

---

## 一、准备

### 你需要

| 项目 | 说明 |
|:---|:---|
| 手机 | Redmi Note 11T 5G（`evergo` / `everpal`） |
| 电脑 | Windows / Linux / macOS |
| 工具 | [platform-tools](https://developer.android.com/studio/releases/platform-tools)（含 `fastboot`） |
| 线缆 | **能传数据的** USB 线（很多线只能充电） |

### 解锁 Bootloader

手机必须已解锁（`fastboot oem device-info` 里 `Device unlocked: true`）。小米的解锁流程见官网，需要账号绑定 7 天。

---

## 二、下载镜像

打开 [**Releases**](https://github.com/ccmx200/redmi_note115G_pmos/releases)，选最新一版。

### 文件命名规则

```
boot-<发行版>-<内存>gib.img            ← 引导镜像（约 128 MB）
userdata-<发行版>-<内存>gib.img.gz     ← 根文件系统（首次开机自动扩容）
SHA256SUM-<发行版>-<内存>gib.txt       ← 校验和
```

### 选哪个

| 你的手机 | 选 |
|:---|:---|
| 4 GiB RAM | `6gib`（向下兼容） |
| 6 GiB RAM | `6gib` |
| 8 GiB RAM | **必须** `8gib` |

> ⚠️ 内存变体只影响内核设备树。选错了内存映射不对，起不来。

### 校验（建议）

```bash
# Linux / macOS
sha256sum -c SHA256SUM-debian-6gib.txt

# Windows
certutil -hashfile userdata-debian-6gib.img.gz SHA256
```

---

## 三、刷入

### 3.1 解压

```bash
gunzip userdata-debian-6gib.img.gz
```

Windows 用 7-Zip 右键解压，或 PowerShell：

```powershell
# 需要 7-Zip
& "C:\Program Files\7-Zip\7z.exe" x userdata-debian-6gib.img.gz
```

### 3.2 进 fastboot

手机关机，**同时按住 音量下 + 电源**，屏幕出现兔子/FASTBOOT 字样。

```bash
fastboot devices          # 应该列出一串序列号
```

### 3.3 刷三个分区

```bash
fastboot -S 200M flash boot_a    boot-debian-6gib.img
fastboot -S 200M flash boot_b    boot-debian-6gib.img
fastboot -S 200M flash userdata  userdata-debian-6gib.img

fastboot reboot
```

> **为什么刷两次 boot？**
>
> 手机是 A/B 双槽。两个槽都刷，避免槽切换后刷回安卓或起不来。

> **为什么必须加 `-S 200M`？**
>
> LK 对单块 sparse 数据有上限，块太大会报 `Failed (remote: 'data is too large')`。

### Windows 用户注意

Windows 版 `fastboot` 会把整个 6 GiB 文件读进内存，然后崩：

```
libc++abi: terminating due to uncaught exception of type std::bad_alloc
```

两个解决办法：

**方法一：转稀疏镜像（推荐，更快）**

```bash
# 需要 img2simg，可从 android-sdk-libsparse-utils 或 WSL 里拿
img2simg userdata-debian-6gib.img userdata.simg
fastboot -S 200M flash userdata userdata.simg
```

6 GiB → 约 2.1 GB，刷写时间从 8 分钟降到 2 分钟。

**方法二：在 WSL / Linux 里流式喂**

```bash
gunzip -c userdata-debian-6gib.img.gz | fastboot -S 200M flash userdata -
```

---

## 四、首次开机

### 时间

| 阶段 | 耗时 |
|:---|:---|
| 内核启动 + USB 网卡枚举 | ~20 秒 |
| 首次扩容（6 GiB → 106 GiB） | 1-10 分钟 |
| 用户态启动到 SSH | ~60 秒 |
| **之后每次开机** | **~60-90 秒** |

### 扩容在做什么

```
初始镜像 6 GiB  →  挂载 → e2fsck → resize2fs → 重新挂载 → 打标记
                 ↓
            整块 eMMC 可用空间 ~106 GiB
```

`resize2fs` 只扩元数据，所以很快。完成后会在根目录留一个 `/.evergo-grown` 标记，**下次开机跳过**。

> 如果扩容失败，标记**不会**写入 —— 下次开机会自动重试。

---

## 五、联网

> ⚠️ **没有串口！** COM / 串口控制台已完全移除。手机只能通过 **USB RNDIS 网卡**接入。

### 手机的两个身份

手机内部**固定**持有链路本地地址 **`169.254.42.1/16`**，这是永远不变的锚点。在此基础上 `usb0` 有两种模式：

| 模式 | 命令 | 手机做什么 | 适用场景 |
|:---|:---|:---|:---|
| 🌐 **router**（默认） | `evergo-mode router` | **DHCP 客户端** + 保持 `169.254.42.1` | 插路由器，**要外网** |
| 💻 **pc** | `evergo-mode pc` | **DHCP 服务端**（`192.168.42.1/24`） | 直连电脑，没路由器 |

### 场景一：直连电脑（最简单）

```
┌──────────┐   USB 线   ┌──────────┐
│   手机    │◄─────────►│   电脑    │
│169.254.42.1│          │ 自动 APIPA│
└──────────┘            └──────────┘
```

**电脑什么都不用配。** Windows / macOS / Linux 都会自动给 RNDIS 网卡分配 `169.254.x.x`，和 `169.254.42.1` 天然同网段。

```bash
ssh root@169.254.42.1      # 密码 evergo
```

**验证每一步**：

```bash
# ① 网卡出现了吗
#   Windows: ipconfig | findstr 169.254
#   Linux:   ip addr show | grep 169.254

# ② 网卡是 Up 吗
#   Windows: 网络适配器里看状态
#   Linux:   ip link

# ③ ping 通吗
ping 169.254.42.1

# ④ 端口通吗
#   Windows: Test-NetConnection 169.254.42.1 -Port 22
#   Linux:   nc -zv 169.254.42.1 22
```

### 场景二：插路由器（要外网）

```
┌──────────┐  USB 线  ┌──────────┐        ┌────────┐
│   手机    │◄────────►│  路由器   │◄──────►│ 互联网  │
│ DHCP 客户端│          │  br-lan  │        └────────┘
└──────────┘            └──────────┘
```

手机作为 **DHCP 客户端**加入路由器 LAN，拿到 `192.168.x.x`，**直接就能上网**：

```bash
# 在手机上
ping -c 3 baidu.com
apt update              # 或 pacman -Sy / dnf check-update
```

**这时怎么 SSH 进去？**

```bash
# 办法 1：查路由器的 DHCP 租约表，找 usb0 的 MAC 对应 IP
# 办法 2（推荐）：插电脑用 169.254.42.1 登录，然后
evergo-info             # 看所有 IP
```

> 💡 `169.254.42.1` 在 router 模式下**依然存在**，插电脑永远是后门。

### OpenWrt 路由器的坑

OpenWrt 默认**不会**把 USB 网卡桥进 LAN，需要装热插拔脚本 → [八、路由器桥接](#八路由器桥接)。

---

## 六、首次登录向导

第一次 SSH 登录进入彩色向导：

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

**全部可以跳过**，直接继续用 `root` / `evergo`。

跳过向导后想重新跑：

```bash
evergo-first-login --force
```

### 登录后的欢迎界面

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

## 七、日常使用

### `evergo-mode` —— 切换 USB 网络模式

```bash
evergo-mode status      # 查看当前
evergo-mode router      # DHCP 客户端（插路由器）
evergo-mode pc          # DHCP 服务端（直连电脑免配置）
```

模式会持久化，重启后保持。

### `evergo-info` —— 系统概览

```bash
evergo-info
```

### 包管理器

```bash
# Arch
pacman -Syu
pacman -S <包名>

# Debian / Ubuntu
apt update
apt install <包名>

# Fedora
dnf update
dnf install <包名>
```

> 📦 **国内源已预配置**（清华），开箱即用。

### 服务管理

```bash
systemctl status sshd
systemctl restart systemd-networkd
journalctl -u evergo-watchdog -n 50
```

### 关机 / 重启

```bash
poweroff
reboot
```

---

## 八、路由器桥接

OpenWrt / LibWrt 默认不桥接 USB 网卡。把脚本放到 `/etc/hotplug.d/net/40-evergo-usb`：

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

然后手机插上路由器 USB 口，就会被 DHCP 分配地址，直接联网。

---

## 九、常见问题

| 现象 | 原因 | 怎么办 |
|:---|:---|:---|
| 网卡**完全没出现** | 内核没启动 / 线只能充电 | 换线；确认刷的是对的 boot.img |
| 网卡 **Disconnected** | initramfs 阶段，正在扩容 | 等 1-10 分钟 |
| 网卡 **Up 但 ping 不通** | 还没到用户态 | 再等；看屏幕有没有报错 |
| **ping 通但 22 端口关** | sshd 没启动 | 插显示器看屏幕；查 [踩坑](TROUBLESHOOTING.md) |
| **反复回到 Redmi logo** | boot.img 问题 | 查 [踩坑记录](TROUBLESHOOTING.md#启动类) |
| **开机后每 50 秒重启** | 看门狗没被喂 | 查 [踩坑记录](TROUBLESHOOTING.md#重启循环类) |
| **根分区还是 6 GiB** | 扩容失败 | 查 [踩坑记录](TROUBLESHOOTING.md#文件系统类) |
| `pacman -Sy` / `apt update` 失败 | 手机没外网 | 插路由器，别插电脑 |

更多 → **[docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md)**

---

## 回滚到 Android

```bash
fastboot --set-active=a
fastboot reboot
```

Android 会要求重新格式化 data 分区（因为被 Linux 覆盖了）。

想彻底恢复原厂：用小米官方线刷工具（MiFlash）刷完整包。

---

<div align="center">

[← 返回 README](../README.md)

</div>
