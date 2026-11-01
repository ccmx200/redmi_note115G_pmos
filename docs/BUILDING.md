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

**内核只按内存变体编译，不再每个发行版编译一次**：

```
plan ──┬─ boot / 6 GiB   （编译内核 + initramfs + arch rootfs → boot-6gib.img）
       └─ boot / 8 GiB   （同上，DTB/Image 与 6 GiB 不同，所以必须分开编）

       └─ distro / {debian,ubuntu,fedora} × {6,8} GiB
            下载对应 boot-<ram>gib.img，只构建自己的 rootfs + userdata
            （build.sh 加 BOOT_IMG=... 直接复用预编译 boot.img，完全不编译内核）
```

- 内核编译次数：从「8 次」降到「2 次」；distro job 只跑 rootfs（每个约 5–8 分钟）。
- 内核 Image 与发行版无关：initramfs（busybox + e2fsprogs）是自包含的，arch job 产出的 boot.img 在 debian/ubuntu/fedora 上同样可用。
- 产物自动发布到 Releases，命名 `boot-<distro>-<ram>gib.img` / `userdata-<distro>-<ram>gib.simg`。

### 清理老 release

Actions → 「cleanup old releases」→ **Run workflow**：

| 参数 | 说明 |
|:---|:---|
| `keep_last` | 保留最近几个 build（默认 5） |
| `dry_run` | 默认 `true`，只打印要删什么；确认后改 `false` 真删 |
| `delete_tags` | 连 git tag 一起删（默认 true） |

只删 tag 形如 `build-<数字>` 的自动构建，手工 release 不动。
本地也可以用脚本（需要带 repo 写权限的 token）：

```bash
GITHUB_TOKEN=ghp_xxx ./scripts/cleanup-releases.py --keep 5 --dry-run
GITHUB_TOKEN=ghp_xxx ./scripts/cleanup-releases.py --keep 5 --yes
```

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

# 只构建 rootfs，复用已经编好的 boot.img（CI 的 distro job 就是这么干的）
BOOT_IMG=out-boot/boot-6gib.img DISTRO=debian RAM_GIB=6 ./build.sh
```

---

## 多发行版机制

**核心原则：能用官方预构建的 rootfs 就直接解压，Debian 没有官方 rootfs 时才 bootstrap。**

| 发行版 | 源文件 | 来源 |
|:---|:---|:---|
| Arch | `ArchLinuxARM-aarch64-latest.tar.gz` | archlinuxarm.org / 清华 |
| Debian | debootstrap 生成的 rootfs（`main`，minbase） | 清华 Debian 镜像 |
| Ubuntu | `ubuntu-base-26.04-base-arm64.tar.gz` | cdimage.ubuntu.com / 清华 |
| Fedora | `Fedora-WSL-Base-44-*.aarch64.wsl`（plain tar） | 清华 / USTC |

**为什么 Debian 用 debootstrap**

Debian 官方**没有** root filesystem tarball：cloud.debian.org 的
`debian-<suite>-generic*.tar.xz` 是磁盘镜像（解压出来是 `disk.raw`），不是文件树。
之前那份脚本照着 Ubuntu 的写法下载并解压它，CI 里就报
`cp: cannot create .../usr/bin/qemu-aarch64-static: No such file or directory`。
所以 Debian 改回 `debootstrap --foreign` + qemu-user 二阶段；脚本里用
`--no-check-gpg`，包本身仍由 apt 校验。

想要"解压即得"的话，可以自己先用 debootstrap 生成一份 tarball，放到本地/内网
用 `DEBIAN_ROOTFS_TARBALL=/path/to/debian-trixie-arm64.tar.xz` 复用（脚本保留了这个环境变量）。

**为什么其他发行版不 bootstrap**

Arch/Ubuntu/Fedora 都有官方 rootfs tarball，解压只要几秒，也不会因为宿主的
apt 配置、代理、密钥轮换而漂；能直接解压就不从零装 300+ 包。

### 脚本分工

```
scripts/distro-arch.sh      Arch 专属（tarball + pacman -Syu）
scripts/distro-debian.sh    Debian 专属（debootstrap + qemu 二阶段 + 调 common）
scripts/distro-ubuntu.sh    Ubuntu 专属（下载 + 解压 + 调 common）
scripts/distro-fedora.sh    Fedora 专属（下载 + 解压 + 调 common）
scripts/distro-common.sh    debian/ubuntu/fedora 的公共配置
```

`distro-common.sh` 干的事（这些是**真正的发行版特定工作**）：

1. **换源** —— 清华镜像 + `Acquire::ForceIPv4`
2. **全量升级** —— `apt upgrade` + `full-upgrade` / `dnf upgrade`
3. **装必需包** —— `openssh-server`、`e2fsprogs`、`sudo`、`iproute2`、`wpa_supplicant` / `iw` / `dhcpcd`（Wi-Fi）等
4. **设密码** —— `echo root:evergo | chpasswd`
5. **设主机名** —— `evergo`
6. **mask 掉会卡首启的服务** —— NetworkManager、cloud-init、ubuntu-advantage、apt-daily
7. **验证** —— sshd / e2fsck / resize2fs / systemd / root 密码哈希，缺一个就 `exit 1`

### 定制层 `rootfs-overlay.tar.gz`

所有发行版共用，`build.sh` 在 distro 脚本之后套上去：

| 文件 | 作用 |
|:---|:---|
| `/usr/local/bin/evergo-mode` | USB 网络模式切换 |
| `/usr/local/bin/evergo-wifi` | Wi-Fi 站点模式管理（up / scan / connect / status / down） |
| `/usr/local/bin/evergo-info` | 系统概览 |
| `/usr/local/bin/evergo-first-login` | 首次登录向导 |
| `/etc/evergo/wifi.conf.example` | 开机自动连 Wi-Fi 的配置模板（复制成 `wifi.conf` 才生效） |
| `/etc/profile.d/00-evergo-welcome.sh` | 欢迎界面 + 触发向导 |
| `/etc/systemd/network/10-usb0.network` | usb0 配置 |
| `/etc/systemd/system/evergo-watchdog.service` | 喂狗（保持 fd 打开） |
| `/etc/systemd/system/evergo-wifi.service` | 按 `/etc/evergo/wifi.conf` 自动连 Wi-Fi（文件不存在则不动作） |
| `/etc/ssh/sshd_config.d/10-bringup.conf` | 只允许密码登录 |
| `/etc/evergo/fastfetch.jsonc` | 欢迎界面配置 |

### 加新发行版

1. 找一个**官方预构建 rootfs tarball**（不是 installer，不是 bootstrap）
2. 写 `scripts/distro-<name>.sh`：下载 + 解压到 `$1`
3. 在 `scripts/distro-common.sh` 的 `case` 里加一个分支（换源 / 升级 / 装包 / 设密码）
4. 在 `.github/workflows/build.yml` 的 `plan` job 里加上名字
5. 在 `build.sh` 的 `case "$DISTRO"` 里处理残留文件差异（如删掉 Arch 的 pacman 配置）

**必须满足**：

- `/sbin/init` 或 `/usr/lib/systemd/systemd` 存在
- `/usr/sbin/sshd`、`/usr/sbin/e2fsck`、`/usr/sbin/resize2fs` 存在
- root 密码已设、主机名已设
- 国内源已配置
- 首启会卡住的联网服务已 mask

## 环境变量

| 变量 | 默认 | 说明 |
|:---|:---|:---|
| `DISTRO` | `arch` | `arch` / `debian` / `ubuntu` / `fedora` |
| `RAM_GIB` | `6` | 内存版本（4 / 6 / 8） |
| `PANEL` | `k16a_36_02_0a_vdo,lcm` | 屏幕型号 |
| `ROOTFS_MB` | `6144` | 根文件系统初始大小 |
| `KERNEL_SRC` | *(空)* | 复用已有内核源码树（旧版 build.sh 留下的 pre-WiFi 树会被检测出来并报错） |
| `BOOT_IMG` | *(空)* | 复用预编译的 boot.img：跳过内核/initramfs 编译，只构建 rootfs + userdata（CI distro job 用） |
| `ARCH_TARBALL` | *(空)* | 复用 Arch ARM tarball |
| `MIRROR_HOST` | `mirrors.ocf.berkeley.edu` | Arch 构建镜像站 |

---

## 构建流程详解

### 1. 内核

```
① 取内核源码
   KERNEL_COMMIT=5bba54524ae56cc211f823a7bf586271e5cb2eb5  ← 锁定版本（bringup/evergo-mainline tip，含蓝牙修复）
   git fetch --depth 1 origin $KERNEL_COMMIT && git checkout FETCH_HEAD
   然后套用 config/patches/*.patch（目前一个：SOC 上跳过重复注册的 HIF-SDIO 驱动，
   否则 WMT 初始化在 /dev/stpwmt 出现之前就 -EBUSY 退出）

② 应用配置
   cp config/evergo.config  $L/out/.config   # 含 CONFIG_MTK_GEN4M_WIFI=y
   make olddefconfig                        # 该符号必须存活，否则 build.sh 直接退出

③ 打设备树补丁（python 正则替换）
   • memory 节点 → RAM_GIB
   • panel compatible → PANEL
   • USB maximum-speed → high-speed
   • bootargs → 精简（loglevel=4 等）

④ 编译 DTB，然后内嵌固件
   make dtbs
   config/firmware/* + mt6833-xiaomi-evergo.dtb → out/work/fw
   .config 写入 CONFIG_EXTRA_FIRMWARE="<12 个固件 + dtb>"
            CONFIG_EXTRA_FIRMWARE_DIR="out/work/fw"

⑤ 编译内核
   make Image
```

> ⚠️ **为什么要锁 commit？**
> `805764287e7b` 是 `master` 上实测能跑的版本（cb9ba2ee + 6 个 WMT/gen4m 提交），Wi-Fi 就靠它。锁 SHA 是为了构建可复现，上游以后即使再改写分支也不影响。

> 📦 **固件为什么要内嵌？**
> WMT 栈是编进内核的，开机时在 rootfs 出现之前就要加载 CONN/Wi-Fi 固件。`CONFIG_EXTRA_FIRMWARE` 把 12 个 blob 和设备树一起塞进 `Image`，`boot.img` 自带全部固件；rootfs 的 `/lib/firmware` 里也会装一份，因为用户态的 ROM patch launcher（wmt-init）需要读这些文件的头。

> 🗑️ **`config/port` 已删除**：以前上游树缺 3 个 dt-bindings 头文件、DTS 里也没有 consys/wifi/btif 节点，所以 `build.sh` 会用 `config/port` 里 vendor 的旧 DTS 覆盖。现在 pinned 树是完整的（那 3 个头文件与树里完全一致），再覆盖旧 DTS 反而会删掉 Wi-Fi 节点，因此整套 vendored 覆盖逻辑已移除。

### 2. 根文件系统

见 [多发行版机制](#多发行版机制)。

装完一定要**升级到最新**，否则镜像里是几周前的包：

| 发行版 | 升级命令 | 位置 |
|:---|:---|:---|
| Arch | `pacman -Syu` | `scripts/distro-arch.sh` |
| Debian / Ubuntu | `apt-get update` → `upgrade` → `full-upgrade` → `autoremove` | `build.sh` 统一处理 |
| Fedora | `dnf -y --refresh upgrade` | `build.sh` 统一处理 |

**为什么必须升级**：

- **Arch** 的官方 tarball 是**月度快照**，`pacman -Sy` 只同步索引不升级包
- **mmdebstrap** 按 bootstrap 那一刻的索引装包，之后不会再动
- **dnf** 会用缓存的 metadata 解析依赖

> 💡 apt 升级加了 `--force-confold`，升级时保留原配置文件，**不会中途弹交互提示**。
> 升级结束后会删掉 `/var/lib/apt/lists/*` 缩体积，并把临时拷进去的 qemu 二进制清理掉。

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
| 内核 `EXTRA_FIRMWARE` | **内核** | 编译出的 `mt6833-xiaomi-evergo.dtb`（真实设备树）+ `config/firmware/` 里 12 个 WMT/gen4m 固件，全部内嵌进 `Image` |
| `tools/wmt-init.c` | **rootfs** | 编译成静态 aarch64 的 `/usr/sbin/wmt-init`，由 `evergo-wmt.service` 在开机时执行：跑 wmt_loader/wmt_launcher 的 ioctl 序列并常驻应答 ROM patch 请求，之后 gen4m 才会 probe 出 `wlan0` |
| `config/firmware/` | **rootfs** | 同一批固件也装到 `/lib/firmware`，给 wmt-init 读 ROM patch 头 |
| `bluez` | **rootfs** | 各发行版脚本安装，`bluetooth.service` 开机启用（BT 核在 CONNSYS 里，走 BTIF/btmtkuart） |
| `NetworkManager` + `nmtui` | **rootfs** | 各发行版脚本安装；`/etc/NetworkManager/conf.d/10-evergo-usb0.conf` 把 usb0 标为 unmanaged，usb0 仍由 systemd-networkd 管，wlan0 交给 NetworkManager（`nmtui`/`nmcli`） |

启动日志出现 `evergo: using embedded device tree` 就说明用的是第二份。

> 📡 Wi-Fi 由 `CONFIG_MTK_GEN4M_WIFI=y` 编译进内核（gen4m 驱动 + WMT 栈 + `wmtWifi` 控制节点），设备树节点来自 pinned 树的 `mt6833.dtsi`（consys / wifi / btif）。旧的 `CONFIG_MTK_MT6833_CONN`（`drivers/soc/mediatek/mt6833-conn.c`）保持不设置。
> 🔵 蓝牙走同一 CONNSYS：`CONFIG_BT_MTK_BTIF=y`（BTIF serdev 控制器）+ `CONFIG_BT_MTKUART=y`（HCI 传输），`CONFIG_BT_HCIUART=y` 是前者的依赖；`CONFIG_MT6833_EVERGO_WDT=y` 来自作者 defconfig（早期看门狗接管）。build.sh 在 `olddefconfig` 后会检查这几个符号是否还在，掉了就报错退出。

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
