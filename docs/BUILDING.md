# 🛠️ 构建指南

> 只关心刷机？看 [刷机教程](TUTORIAL.md)。只想用？看 [README](../README.md)。

## 目录

- [架构概览](#架构概览)
- [GitHub Actions 构建](#github-actions-构建)
- [本地构建](#本地构建)
- [多发行版机制](#多发行版机制)
- [环境变量](#环境变量)
- [构建流程详解](#构建流程详解)
- [kernel 与设备树](#kernel-与设备树)
- [initramfs](#initramfs)
- [分区与偏移](#分区与偏移)
- [发版](#发版)

---

## 架构概览

```
build.sh
  ├─ 1. 内核      scripts/ → 内核源码 + 设备树补丁 + DTB
  ├─ 2. 根文件系统  scripts/distro-<name>.sh  → 一个普通目录
  ├─ 3. initramfs  内联 heredoc              → 4.7 MB busybox
  ├─ 4. 镜像      mke2fs -d                  → 6 GiB ext4
  └─ 5. 打包      scripts/mkbootimg.py + avb.py → boot.img
```

**关键设计**：根文件系统先做成**普通目录**，最后才 `mke2fs -d` 写进镜像。这样构建过程**不需要 loop 设备、不需要 root 挂载**，CI 上也能跑。

---

## GitHub Actions 构建

Fork 仓库 → **Actions** → 「build evergo images」→ **Run workflow**

| 参数 | 可选值 | 说明 |
|:---|:---|:---|
| `distro` | `arch` / `debian` / `ubuntu` / `fedora` / `all` | 构建哪些发行版 |
| `ram_gib` | `6` / `8` / `all` | 内存变体 |
| `panel` | `k16a_36_02_0a_vdo,lcm`（天马）/ `k16a_42_02_0b_vdo,lcm`（华星） | 屏幕型号 |
| `rootfs_mb` | 默认 `6144` | 根文件系统初始大小 |

**矩阵** = `distro × ram_gib`，最多 8 个并行 job，约 35 分钟。

产物自动发布到 Releases，命名 `<distro>-<ram>gib`。

---

## 本地构建

### 依赖

```bash
# Ubuntu / Debian 主机
sudo apt install -y \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    ccache bc bison flex libssl-dev libelf-dev libncurses-dev \
    cpio gzip xz-utils zstd python3 device-tree-compiler \
    e2fsprogs qemu-user-static android-sdk-libsparse-utils \
    mmdebstrap debootstrap dnf rpm
```

### 跑

```bash
git clone https://github.com/ccmx200/redmi_note115G_pmos.git
cd redmi_note115G_pmos

sudo DISTRO=debian RAM_GIB=6 ./build.sh
```

> ⚠️ **必须 root**（chroot 用），且**目标目录必须在原生 ext4 上** —— `/mnt/*` 这类 Windows 挂载不支持 `fchmod`，apt/dpkg 会全挂。

### 产物

```
out/boot.img           引导镜像（约 128 MB，含 AVB footer）
out/userdata.img       6 GiB ext4 根文件系统
out/userdata.img.gz    压缩版
out/userdata.simg      稀疏版（fastboot 直接刷这个）
out/SHA256SUMS
```

### 复用已下载的东西

```bash
# 复用内核源码树，省一次 clone + 全量编译
KERNEL_SRC=/root/linux-evergo ./build.sh

# 复用 Arch tarball
ARCH_TARBALL=/path/ArchLinuxARM-aarch64-latest.tar.gz ./build.sh
```

---

## 多发行版机制

每个发行版一个脚本，接口统一：

```
scripts/distro-<name>.sh <rootfs-dir>
```

脚本负责把 `rootfs-dir` 填成一个**可启动的根文件系统**：装基础系统、设 root 密码、配国内源、enable 服务。**不需要关心内核、镜像、打包**。

`build.sh` 负责：

```bash
bash "$HERE/scripts/distro-$DISTRO.sh" "$R"   # 填目录
tar xzf rootfs-overlay.tar.gz -C "$R"          # 套定制层
mke2fs -d "$R" "$ROOTIMG"                      # 生成镜像
```

### 定制层 `rootfs-overlay.tar.gz`

| 文件 | 作用 |
|:---|:---|
| `/usr/local/bin/evergo-mode` | USB 网络模式切换 |
| `/usr/local/bin/evergo-info` | 系统概览 |
| `/usr/local/bin/evergo-first-login` | 首次登录向导 |
| `/etc/profile.d/00-evergo-welcome.sh` | 欢迎界面 + 触发向导 |
| `/etc/systemd/network/10-usb0.network` | usb0 配置 |
| `/etc/systemd/system/evergo-watchdog.service` | 看门狗喂狗 |
| `/etc/ssh/sshd_config.d/10-bringup.conf` | 只允许密码登录 |
| `/etc/evergo/fastfetch.jsonc` | 欢迎界面配置 |
| `/etc/fstab`, `/etc/hosts`, `/etc/hostname` | 基础配置 |

### 加新发行版

1. 写 `scripts/distro-<name>.sh`，接收目录参数，填出可启动的 rootfs
2. 在 `.github/workflows/build.yml` 的 `plan` job 里加上名字
3. 在 `build.sh` 的 `case "$DISTRO"` 里处理发行版差异（如删掉 Arch 的 pacman 配置）

**必须满足**：

- `/sbin/init` 或 `/usr/lib/systemd/systemd` 存在
- `/usr/sbin/sshd`、`/usr/sbin/e2fsck`、`/usr/sbin/resize2fs` 存在
- root 密码已设（`echo root:evergo | chpasswd`）
- 国内源已配置
- 首启会卡住的联网服务已 mask

---

## 环境变量

| 变量 | 默认 | 说明 |
|:---|:---|:---|
| `DISTRO` | `arch` | `arch` / `debian` / `ubuntu` / `fedora` |
| `RAM_GIB` | `6` | 内存版本（4 / 6 / 8） |
| `PANEL` | `k16a_36_02_0a_vdo,lcm` | 屏幕型号 |
| `ROOTFS_MB` | `6144` | 根文件系统初始大小 |
| `KERNEL_SRC` | *(空)* | 复用已有内核源码树 |
| `ARCH_TARBALL` | *(空)* | 复用 Arch ARM tarball |
| `MIRROR_HOST` | `mirrors.ocf.berkeley.edu` | Arch 构建镜像站 |

---

## 构建流程详解

### 1. 内核

```
① 取内核源码
   KERNEL_COMMIT=cb9ba2ee0f929ff8985f4821a0ee32fa1c06c5fd  ← 锁定版本
   git fetch --depth 1 origin $KERNEL_COMMIT && git checkout FETCH_HEAD

② 应用配置
   cp config/evergo.config  $L/out/.config
   make olddefconfig

③ 打设备树补丁（python 正则替换）
   • memory 节点 → RAM_GIB
   • panel compatible → PANEL
   • USB maximum-speed → high-speed
   • bootargs → 精简（loglevel=4 等）

④ 编译
   make Image dtbs
```

> ⚠️ **为什么要锁 commit？**
> 上游 `main` 被作者重写过，能编译但**启动不了**。`cb9ba2ee` 是实测能跑的。详见 [踩坑](TROUBLESHOOTING.md#上游-main-编出来的内核能启动吗)。

### 2. 根文件系统

见 [多发行版机制](#多发行版机制)。

### 3. initramfs

**4.7 MB**，静态 busybox + e2fsck + resize2fs + 依赖库：

```
bin/busybox        静态 aarch64
bin/{sh,sleep,dd,...}  23 个 applet 链接
init               启动脚本
usr/sbin/e2fsck
usr/sbin/resize2fs
usr/lib/*.so*      8 个库 + ld-linux
```

**init 干的事**：

```sh
挂载 proc/sys/dev
  ↓
探测 sleep/usleep（执行一次判断，不靠 command -v）
  ↓
开 /dev/watchdog，后台循环喂狗（记录 PID）
  ↓
等 usb0 出现，配 169.254.42.1
  ↓
losetup -o 0x304000000 /dev/loop0 /dev/sdc
  ↓
mount → 检查 /.evergo-grown
  ↓ 没有标记（首次开机）
umount → e2fsck -fp → resize2fs → mount → touch 标记
  ↓
kill 喂狗循环 + 关 fd（干净交接）
  ↓
switch_root /newroot /sbin/init
```

**失败时**：不进 switch_root，留在 initramfs 里，屏幕显示提示 + 保留日志在 `/tmp/init.log`。

### 4. 镜像

```bash
mke2fs -t ext4 -F -L evergo -m 1 -q -d "$R" "$ROOTIMG"
```

`-d` 直接从目录生成，**不需要 loop、不需要 root 挂载**。

然后：
```bash
cp userdata.img out/
gzip -9 -c userdata.img > userdata.img.gz
img2simg userdata.img userdata.simg      # fastboot 直接刷这个
```

### 5. 打包

```bash
gzip -9 Image + vendor_dtb.bin          → kernel.bin
printf '' | gzip -9                     → 空 ramdisk（20 字节）
mkbootimg.py --kernel ... --dtb ...     → boot-nofooter.img
avb.py --footer-template --vbmeta-template → boot.img (128 MB)
```

---

## kernel 与设备树

### 两份 DTB

| 位置 | 谁用 | 内容 |
|:---|:---|:---|
| boot.img 头 `dtb_addr` | **LK** | `config/dt_table_stock.bin`（联发科分区表） |
| 内核 `EXTRA_FIRMWARE` | **内核** | 编译出的 `mt6833-xiaomi-evergo.dtb`（真实设备树） |

启动日志出现 `evergo: using embedded device tree` 就说明用的是第二份。

### vendor DTB

`config/vendor_dtb.bin`（170 KB）拼在 gzip(Image) 后面，**LK 需要**它来解析内存和分区。

### AVB footer

`config/avb_footer.bin` + `avb_vbmeta.bin` → 512 字节签名尾巴。

> ⚠️ **不能删！** 虽然 bootloader 已解锁、mainline 内核也不校验，但实测**去掉它 LK 会卡在 Redmi logo**，内核根本不被加载。

---

## 分区与偏移

```
eMMC 布局（来自官方 scatter）
┌──────────────────────────────────────┐
│ preloader / misc / … / super         │
├──────────────────────────────────────┤ ← 0x304000000 (12.06 GiB)
│                                      │
│  userdata  ← 根文件系统在这           │
│  loop0 覆盖 107.1 GiB                │
│  ext4 首启扩到 ~106 GiB              │
│                                      │
└──────────────────────────────────────┘ ← 119.2 GiB (eMMC 实际容量)
```

| 常量 | 值 |
|:---|:---|
| `UD_OFF`（userdata 起始） | `0x304000000` = 12,952,010,752 B = 12,352 MiB |
| `loop0` 覆盖 | 107.1 GiB（盘尾） |
| `boot_a` | `0xae800000` |
| `boot_b` | `0xd4000000` |
| boot 分区大小 | 128 MiB |

> scatter 里 userdata 只声明 10 GiB，但 LK 实际报 **226 GiB**，loop 能覆盖到盘尾。

---

## 发版

CI 的 `build` job 会：

1. 按矩阵构建
2. 重命名为 `boot-<distro>-<ram>gib.img` / `userdata-<distro>-<ram>gib.img.gz`
3. 每个组合生成 `SHA256SUM-<distro>-<ram>gib.txt`
4. 上传 artifact（保留 14 天）
5. 发布到 tag `build-<run_number>`，说明文件是 `.github/release-notes.md`

### 发布前检查

- [ ] 真的刷到手机上验证过（至少一个发行版）
- [ ] `df -h /` 显示 106G
- [ ] `ssh root@169.254.42.1` 能登
- [ ] `dmesg | grep -i watchdog` 没有 `did not stop`
- [ ] `cat /etc/hostname` 是 `evergo` 不是空

---

<div align="center">

[← 返回 README](../README.md)

</div>
