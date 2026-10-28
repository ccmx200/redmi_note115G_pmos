<div align="center">

# 📱 红米 Note 11T 5G · Arch Linux ARM

**给 Redmi Note 11T 5G 装上真正的 Linux 桌面系统**

[![设备](https://img.shields.io/badge/设备-evergo%20%2F%20everpal-FF6900?style=for-the-badge&logo=xiaomi&logoColor=white)](https://github.com/ccmx200/redmi_note115G_pmos)
[![芯片](https://img.shields.io/badge/SoC-MT6833%20天玑810-00A3E0?style=for-the-badge)](https://github.com/ccmx200/redmi_note115G_pmos)
[![系统](https://img.shields.io/badge/系统-Arch%20Linux%20ARM-1793D1?style=for-the-badge&logo=archlinux&logoColor=white)](https://archlinuxarm.org/)
[![内核](https://img.shields.io/badge/内核-7.3.0--rc4-FCC624?style=for-the-badge&logo=linux&logoColor=black)](https://github.com/ccmx200/linux-evergo)

</div>

---

## ✨ 这是什么

这不是 Android，也不是套壳 Linux —— 是**跑在手机裸硬件上的完整 Arch Linux**。

基于 [KevinLmK0702](https://github.com/KevinLmK0702/linux-evergo) 的 MT6833 主线内核移植，本仓库负责把内核、根文件系统、引导镜像打包成**刷完就能用**的成品。

> 🎯 **一句话**：`fastboot` 刷两个文件，手机就变成一台 106 GiB 存储、SSH 可登的 Arch 电脑。

---

## 🚀 三分钟上手

### 1️⃣ 下载

前往 [**Releases**](https://github.com/ccmx200/redmi_note115G_pmos/releases) 下载最新版本：

| 文件 | 说明 |
|:---|:---|
| 🥾 `boot.img` | 内核 + 引导 initramfs |
| 💾 `userdata.img.gz` | 根文件系统（6 GiB，**首次开机自动扩到 106 GiB**） |
| 🔐 `SHA256SUMS` | 校验和 |

### 2️⃣ 刷入

```bash
# 解压根文件系统
gunzip userdata.img.gz

# 刷引导（两个槽都刷，避免掉槽）
fastboot -S 200M flash boot_a boot.img
fastboot -S 200M flash boot_b boot.img

# 刷根文件系统（必须加 -S，否则 fastboot 会因文件过大失败）
fastboot -S 200M flash userdata userdata.img

# 重启
fastboot reboot
```

<details>
<summary>💡 <b>Windows 用户注意</b>（点开）</summary>

Windows 版 `fastboot` 会把整个 6 GiB 镜像读进内存然后崩溃（`std::bad_alloc`）。

两个解决办法：

**方法一：流式刷入**
```bash
gunzip -c userdata.img.gz | fastboot -S 200M flash userdata -
```

**方法二：先转稀疏镜像**（推荐，最快）
```bash
img2simg userdata.img userdata.simg    # 6 GiB → 约 2.1 GB
fastboot -S 200M flash userdata userdata.simg
```
</details>

### 3️⃣ 开机

⏳ **首次开机需要约 10 分钟** —— 系统会自动把 6 GiB 的根分区扩展到整块 eMMC（约 106 GiB），之后每次开机都很快。

---

## 🔌 连接手机

### ⚠️ 没有串口！

本方案**完全移除了 COM / 串口控制台**。手机通过 **USB RNDIS 网卡**接入，用 SSH 管理。

### 插电脑（最简单）

手机固定持有链路本地地址 `169.254.42.1`，**电脑什么都不用配**（Windows 自动分配 APIPA 同网段地址）：

```bash
ssh root@169.254.42.1
```

> 🔑 默认密码：`evergo`

### 插路由器（有外网）

插到路由器的 USB 口上，手机会作为 **DHCP 客户端**加入该 LAN，自动获得 IP 并联网：

```
路由器 USB 口 → usb0 桥接进 LAN → DHCP 分配 192.168.x.x → 上网 ✅
```

> 💡 如果你用 OpenWrt / LibWrt 路由器，装上[自动桥接脚本](#-路由器自动桥接)即可。

### 首次登录向导

第一次用 SSH 登录会自动进入设置向导：

```
┌─────────────────────────────────────────┐
│  ① 创建普通用户  （可跳过，直接用 root） │
│  ② 设置主机名    （默认 evergo）         │
│  ③ 修改 root 密码（可选）                │
└─────────────────────────────────────────┘
```

登录后看到的界面：

```
                                      root@evergo
                   -`                -----------
                  .o+`               OS       Arch Linux ARM aarch64
                 `ooo/               Kernel   7.3.0-rc4-gcb9ba2ee0f92
                `+oooo:              Uptime   5 hours, 6 mins
               `+oooooo:             Packages 204 (pacman)
               -+oooooo+:            shell    bash
             `/:-:++oooo+:           Memory   495 MiB / 5.63 GiB (9%)
            `/++++/+++++++:          Disk     2.1 GiB / 106 GiB (2%) - ext4
           `/+++ooooooooooooo/`      CPU      mt6833 (8)
          ./ooosssso++osssssso+      -----------
         .oossssso-````/ossssss+     network  router
        -osssssso.      :ssssssso.   Local IP 192.168.111.210/24
```

---

## 🎛️ 常用命令

### `evergo-mode` —— 切换 USB 工作模式

| 命令 | 作用 |
|:---|:---|
| `evergo-mode status` | 查看当前模式 |
| `evergo-mode router` | **DHCP 客户端**（默认）—— 插路由器拿 IP 上网 |
| `evergo-mode pc` | **DHCP 服务端** —— 让直连的电脑自动拿到 `192.168.42.x` |

### `evergo-info` —— 一屏系统概览

```bash
evergo-info
```

### 软件包管理

```bash
pacman -Syu              # 更新系统
pacman -S <包名>          # 安装软件
pacman -Sc               # 清理缓存
```

> 📦 镜像源已配好**清华** + **中科大**，`pacman` 开箱可用。

---

## ✅ 硬件支持

| 子系统 | 状态 | 说明 |
|:---|:---:|:---|
| 🧠 主控 | ✅ | MT6833 / 天玑 810，8 核 |
| 💾 存储 | ✅ | 128 GB eMMC，自动扩展到 ~106 GiB |
| 🖥️ 显示 | ✅ | `mediatekdrmfb` 帧缓冲控制台 |
| 🌐 USB 网络 | ✅ | RNDIS，高速模式，实测 ~4.5 MB/s |
| 🔌 SSH | ✅ | 密码登录，密钥已禁用 |
| ⏱️ 硬件看门狗 | ✅ | `evergo-watchdog.service` 自动喂狗 |
| 💿 内存 | ✅ | 实测 5.63 GiB 可用（6 GiB 版本） |

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

Fork 本仓库 → 进入 **Actions** → 选择「build evergo images」→ **Run workflow**

可调参数：`ram_gib`（4/6/8）、`panel`（天马/华星）、`rootfs_mb`

构建完成后自动发布到 Releases。

### 本地构建

```bash
git clone https://github.com/ccmx200/redmi_note115G_pmos.git
cd redmi_note115G_pmos
./build.sh
```

产物在 `out/` 目录：

```
out/
├── boot.img            # 引导镜像
├── userdata.img        # 6 GiB ext4 根文件系统
├── userdata.img.gz     # 压缩版
├── userdata.simg       # 稀疏版（fastboot 用）
└── SHA256SUMS
```

### 可调环境变量

| 变量 | 默认值 | 说明 |
|:---|:---|:---|
| `RAM_GIB` | `6` | 内存版本（4 / 6 / 8） |
| `PANEL` | `k16a_36_02_0a_vdo,lcm` | 屏幕型号（天马；华星为 `k16a_42_02_0b_vdo,lcm`） |
| `ROOTFS_MB` | `6144` | 根文件系统大小 |
| `KERNEL_SRC` | *(空)* | 复用已有的内核源码树 |
| `MIRROR_HOST` | `mirrors.ocf.berkeley.edu` | 构建时用的镜像站 |

---

## 🔬 构建原理

```
┌──────────────────────────────────────────────────────────┐
│  1. 内核                                                  │
│     克隆 ccmx200/linux-evergo @ cb9ba2ee（锁定版本）       │
│     应用 config/evergo.config（硬件验证过的配置）          │
│     打 4 处设备树补丁：                                    │
│       • 内存 6 GiB                                        │
│       • 屏幕型号（天马/华星）                              │
│       • USB 高速模式                                       │
│       • 精简启动参数                                       │
├──────────────────────────────────────────────────────────┤
│  2. 根文件系统                                            │
│     Arch Linux ARM aarch64 官方 tarball                   │
│     初始化 pacman keyring → 装软件 → 应用定制覆盖层        │
│     mke2fs -d 一步生成 6 GiB ext4 镜像                    │
├──────────────────────────────────────────────────────────┤
│  3. initramfs                                             │
│     精简 busybox + e2fsck + resize2fs                     │
│     首次开机：卸载 → e2fsck → resize2fs → 重新挂载 → 快照 │
├──────────────────────────────────────────────────────────┤
│  4. 打包                                                  │
│     mkbootimg 生成 boot.img → avb.py 追加 AVB 签名        │
└──────────────────────────────────────────────────────────┘
```

---

## 🕳️ 踩坑记录

这些坑都是用真机调试换来的，写下来免得后人重踩：

| 症状 | 原因 |
|:---|:---|
| `bootreason=lk_crash`，内核毫无输出就重启 | boot 镜像头漏了 `name[16]` 字段，`dtb_size` 整体偏移 16 字节 |
| `Failed to execute /init (error -8)` | 把 x86-64 的 busybox 拷进了 aarch64 的 initramfs |
| 每 31 秒重启一次 | 硬件看门狗由 bootloader 武装，用户态没人喂 |
| `f2fs: Unknown parameter 'offset'` | `mount -o loop,offset=` 不支持 f2fs，必须 `losetup -o` |
| switch_root 后每 33 秒重启 | initramfs 重开了 `/dev/watchdog`，`/dev` 被移动后失败 → 必须用继承的 fd 3 |
| `restricting filesystem access failed` | pacman 7.x 的 Landlock 沙箱 vs 没开 `CONFIG_SECURITY_LANDLOCK` 的内核 |
| qemu chroot 里 `Could not resolve host` | aarch64 glibc 的解析器在 qemu-user 下失效 → 构建时把镜像站 IP 写进 `/etc/hosts` |
| `PubkeyAuthentication no` 不生效 | **`sshd_config` 是第一个值生效**，不是最后一个 |
| `The source tree is not clean`（O=out） | 源码树里残留 `include/config` / `include/generated` |
| `rm -rf` 把宿主 `/sys` 删了 | `out/work/rootfs` 下有残留 bind mount，删除前必须卸载 |
| **`resize.f2fs` 永久卡死** | 本机型上不可用（试过 `-F`、`</dev/null`、关 discard），**还会损坏文件系统** |
| 全新刷入的镜像登不进去 | Arch tarball 的 root 密码是锁定的，而本镜像只允许密码登录 |
| CI 编的 boot.img 循环重启 | 上游 `main` 被重写过，能编译但启动不了 → 锁定 `cb9ba2ee` |
| 控制台刷屏 `sleep: not found` | initramfs 里 busybox 的 applet 链接不全 |

---

## 📐 分区布局

手机的 eMMC 分区表（来自官方 scatter 文件）：

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

### 💽 路由器自动桥接

如果你用 OpenWrt 系路由器，把下面的脚本放到 `/etc/hotplug.d/net/40-evergo-usb`：

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
| 🐧 根文件系统 | [Arch Linux ARM](https://archlinuxarm.org/) |
| 💡 分区扩容思路 | [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)、[postmarketOS](https://postmarketos.org/) |
| 🔧 MT6833 主线化起点 | Poco M3 Pro 5G（camellia）项目 |

---

<div align="center">

**GPL-2.0** · 与内核协议一致

⭐ 如果这个项目帮到你，点个 Star 吧

</div>
