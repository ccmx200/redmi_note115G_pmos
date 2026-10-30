# 🕳️ 踩坑记录

> 这些都是用真机一次次刷机、看屏幕、抓日志换来的。按「症状 → 原因 → 解法」整理，方便后人直接搜索症状。

---

## 🔁 重启循环类

### 手机每 ~50 秒自己重启一次（看起来像「改主机名时重启」）

**症状**：用着用着突然重启；`ping` 一会儿通一会儿不通；第一次登录向导走到某一步就重启。

**真相**：这是硬件看门狗在复位，和向导做了什么**毫无关系**。50 秒 ≈ 31 秒看门狗超时 + 20 秒启动。向导只是刚好跑到那一步。

**三个叠加的 bug**：

| # | Bug | 后果 |
|:---:|:---|:---|
| 1 | initramfs 的 applet 列表**漏了 `awk`** | `delay()` 兜底用 `awk` 读 `/proc/uptime`，awk 不存在 → `_now` 恒为 0 → `while [ 0 -lt n ]` 永不退出 → **喂狗循环卡死** |
| 2 | 喂狗循环**跨 `switch_root` 存活** | 一直占着 `/dev/watchdog` → systemd 服务报 `Device or resource busy` → 谁也喂不了 |
| 3 | 服务用 `echo . > /dev/watchdog` | 每次**开-写-关**，`nowayout=0` 下**关闭即解除武装** → 从来没真正武装过 |

**排查命令**（在能连上 SSH 的窗口里跑）：

```bash
# 看 /dev/watchdog 是否被占用
echo . > /dev/watchdog        # 报 "Device or resource busy" 就是被占了
# 找谁占着
for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep -q watchdog && echo "$p $(cat $p/comm)"; done
# 看内核日志
dmesg | grep -i watchdog
# 看服务
systemctl status evergo-watchdog
```

**修复（3 处）**：

1. initramfs applet 列表补 `awk usleep ps kill`
2. init 在 `switch_root` 前 **kill 掉喂狗循环并关闭 fd**
3. systemd 单元**保持 fd 打开**：

```sh
ExecStart=/bin/sh -c 'for d in /dev/watchdog0 /dev/watchdog; do [ -e "$d" ] && { exec 3>"$d"; break; }; done; [ -e /proc/self/fd/3 ] || exec sleep infinity; while : ; do echo . >&3 || break; sleep 10; done'
```

> ⚠️ 千万不要用 `echo . > /dev/watchdog` —— 关闭 fd 会解除武装，等于没喂。

---

### `watchdog0: watchdog did not stop!` 刷屏

**原因**：用了 `echo . > /dev/watchdog` 这种开-写-关的写法，每次关闭内核都警告一次。

**解法**：按上面的写法**保持 fd 打开**。

---

## 启动类

### 卡在 Redmi logo 不动

**原因**：`boot.img` 里没有 AVB footer。

**说明**：mainline 内核 + 解锁的 bootloader，那个 512 字节的 `AVB0` 尾巴看起来完全是死重。但实测**去掉它就卡在 LK 的 Redmi logo**，内核根本没被加载。

**解法**：保留 AVB footer（`scripts/avb.py` 那段不要删）。

---

### `bootreason=lk_crash`，内核毫无输出就重启

**原因**：Android boot image 头漏了 `name[16]` 字段。

**说明**：boot image v2 头里 `name[16]` 必须存在（可以全空）。少了它，后面的 `dtb_size` / `dtb_addr` 会**整体前移 16 字节**，LK 读到错误的 DTB 尺寸直接崩溃。

**解法**：`scripts/mkbootimg.py` 里写满 1660 字节的头。

---

### `Failed to execute /init (error -8)` / `error -2`

| 错误码 | 含义 | 原因 |
|:---:|:---|:---|
| `-8` (ENOEXEC) | 格式不对 | 把 **x86-64** 的 busybox 拷进了 aarch64 的 initramfs |
| `-2` (ENOENT) | 找不到 | `/init` 的 shebang 指向的 `/bin/sh` 不存在 |
| | | 或动态链接的 busybox 找不到 `/lib/ld-musl-*` |

**解法**：initramfs 一律用 **aarch64 静态** busybox，并确认 cpio 里 `bin/sh -> busybox` 存在。

---

### 每 31 / 33 秒重启一次

**原因**：硬件看门狗。

**说明**：LK 在跳转内核前会武装看门狗（31 秒超时），用户态必须持续喂。两个坑：

1. **没人喂** → 补一个后台循环 `while :; do echo . >&3; sleep 8; done &`
2. **用错 fd** → `switch_root` 会把 `/dev` 移到新根下，之后再 `open("/dev/watchdog")` 会失败。必须用 `switch_root` **之前**打开的 fd 3，并跨 `switch_root` 继承。

---

### 内核完全没启动，USB 都不枚举

**排查顺序**：

1. 确认 `boot.img` 的 `image_size` 正常（约 18-20 MB，不是 90 MB）—— initramfs 塞太大会出问题
2. 确认 `dtb_size` 不是 0
3. 屏幕拍照看有没有 `Kernel panic` 字样
4. 换回**已验证能启动**的 boot.img 做对照，隔离是 boot 还是 rootfs 的问题

---

## 文件系统类

### `resize.f2fs` 永久卡死

**症状**：initramfs 里跑 `resize.f2fs` 不返回，等 20 分钟也没动静；还会损坏文件系统。

**已试过全部无效**：
- `-F` 强制
- `< /dev/null` 避免交互提示
- 关闭 loop 的 `discard_max_bytes`

**结论**：这个机型上 **f2fs 无法扩容**。内核的 `F2FS_IOC_RESIZE_FS` 也只实现了缩小（`block_count > old_block_count` 直接返回 `-EINVAL`）。

**解法**：用 **ext4** + `resize2fs`（只扩元数据，秒级完成）。

---

### Fedora 启动正常，但根分区没扩容

**原因**：`/usr/lib64`。

**说明**：`collect-libs.py` 把所有动态库平铺到 `usr/lib`，但 **Fedora 的加载器只搜 `/usr/lib64`**，于是 initramfs 里的 `e2fsck` / `resize2fs` 报：

```
error while loading shared libraries: libext2fs.so.2: cannot open shared object file
```

扩容静默失败，而标记文件照样写，导致永远不会重试。

**解法**：库同时镜像到 `usr/lib64`；扩容标记只在 `resize2fs` **成功后**才写。

---

### 全新刷入后登不进去

**原因**：Arch 官方 tarball / Fedora 的 root 密码是**锁定**的（`root:*`），而镜像只允许密码登录。

**解法**：构建时 `echo "root:evergo" | chpasswd`，并 `passwd -S root` 确认是 `P`。

---

### `mount: failed to setup loop device`（CI）

**原因**：GitHub runner 的内核没有 f2fs 模块，且挂载需要 root。

**解法**：不挂载 —— 用 `mke2fs -d <目录>` 一步生成 ext4 镜像，不需要 loop、不需要 root。

---

### 目标目录建在 `/mnt/*` 上时 apt/dpkg 全挂

**症状**：

```
E: Could not change permissions for temporary file ... - fchmod (1: Operation not permitted)
```

**原因**：Windows DrvFs 挂载不支持 `fchmod`。

**解法**：rootfs 一律建在 WSL 原生 ext4（如 `/root/...`）上。

---

## 🐌 性能类

### USB 网络速度实测

| 方向 | 吞吐 | 说明 |
|:---|---:|:---|
| 手机 → PC（NCM，1 GiB 持续） | **9.04 MB/s（76 Mbps）** | 最可靠的数据 |
| 手机 → PC（NCM，12 秒窗口） | 10.93 MB/s | 短时峰值 |
| 手机 → PC（NCM，256 MB） | 5.91 MB/s | 含慢启动 |
| PC → 手机（NCM，256 MB） | 5.56 MB/s | — |
| 手机 → PC（旧 RNDIS） | 3.59 MB/s（30 Mbps） | 基准 |

**NCM 相对 RNDIS 提升约 2.5 倍**，链路速度从 30 Mbps 提到 **426 Mbps**。

### 瓶颈在哪里 —— 是 MUSB 控制器，不是 CPU

一开始怀疑 CPU（因为没有 cpufreq 驱动），实测推翻了这个猜测：

**测量方法**：传输期间抓 `/proc/stat` 和 `/proc/interrupts` 的前后快照，算每核占用。

```
传输期间每核占用
  cpu0   2.8%
  cpu1   1.1%
  cpu2  63.3%    ← USB 中断全在这里
  cpu3   0.5%
  cpu4   1.2%
  cpu5   2.4%
  cpu6   0.1%
  cpu7   0.0%
```

| 假设 | 实测 | 结论 |
|:---|:---|:---|
| CPU 跑满 | 最忙核心 **63%** | ❌ 不是 CPU |
| 多核没利用 | musb 中断 175,996 次全在 CPU 2 | ✅ 确实是单核 |
| 软中断堆积 | RPS 摊到 CPU 4-7，速度 **+0%** | ❌ 不是软中断 |
| 纯内核锁 | RPS 无效 + CPU 有余量 | ❌ 不是锁 |
| **MUSB 硬件** | 9 MB/s ÷ 8000 微帧 ≈ 1125 B/微帧 | ✅ **就是它** |

**原理**：USB 2.0 高速的 Bulk 传输每 **125 µs** 一个微帧，理论上能塞 13 个 512B 包（≈53 MB/s）。
**MUSB 是 FIFO 架构，没有 DMA scatter-gather**，实测每微帧只走约 **2 个包**（1125 B），
所以卡在 9 MB/s。这是**控制器硬件限制，不是软件能调的**。

**这解释了为什么这些调整全部无效**：

| 调整 | 结果 |
|:---|:---|
| USB 中断绑到 CPU 2 | 无效（单核本来就没跑满） |
| RPS 软中断摊到 4 核 | **+0%** |
| `txqueuelen` 加到 4000 | 无效 |
| MTU 9000 | PC 端要管理员权限，未测出收益 |

### 为什么用 CDC-NCM 而不是继续用 RNDIS

`g_ether` 是 2008 年的老 gadget，**每个以太网帧一次 USB 传输**，不做聚合。
CDC-NCM 把多个帧装进一个 USB 传输（NTB），所以少了一半以上的中断和拷贝。

**配置**（`config/evergo.config`）：

```
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_NCM=y
CONFIG_USB_F_NCM=y
CONFIG_USB_F_RNDIS=y          # 保留做 fallback
CONFIG_USB_CONFIGFS_RNDIS=y
CONFIG_USB_ETH is not set     # 关掉 g_ether，腾出唯一的 UDC
```

**为什么不怕改坏**：`f_ncm` 和 `f_rndis` 都是 **configfs 函数**，initramfs 里
`config/gadget-setup.sh` 先试 NCM、失败自动退 RNDIS。两个都不依赖 `g_ether`。

### 为什么不做 cpufreq

即使做了也没用 —— **CPU 只有 63% 占用**，瓶颈在 USB 控制器。所以**本项目明确不做**：

1. 实测证明 CPU 有余量，调频不会提速
2. 加 `mtk-cpufreq` / `CCI` / OPP 是内核级大改动，有刷砖风险
3. 这台设备**没有串口兜底**

### BBR：加了，但吞吐没变

内核里编了 `CONFIG_TCP_CONG_BBR=y` + `CONFIG_NET_SCH_FQ=y` + `CONFIG_DEFAULT_NET_SCH="fq"`，
initramfs 启动时切 `bbr` 并给 usb0 挂 `fq`，rootfs 里也有
`/etc/sysctl.d/90-evergo.conf`。

**BBR 和 CUBIC 实测六个数字完全一样**（256 MB 交替跑三次）：

```
bbr    5.94 MB/s
cubic  5.94 MB/s
bbr    5.94 MB/s
cubic  5.94 MB/s
bbr    5.94 MB/s
cubic  5.94 MB/s
```

小数点后两位一模一样。**这本身就是结论：拥塞控制不是变量，链路没有拥塞。**

BBR 擅长「丢包不等于拥塞」的场景（高延迟、有丢包的广域网）。我们的链路是
**USB 局域网直连、零丢包**，CUBIC 已经跑满硬件能力，BBR 没有发挥空间。

> 💡 保留 BBR 是因为它对「远距离 + 大缓冲」的场景更稳，成本为零；但不是提速手段。

### 真实的吞吐曲线：有 20 秒固定开销

| 传输量 | 耗时 | 平均速率 |
|---:|---:|---:|
| 256 MB | 43.1 s | 5.94 MB/s |
| 1 GiB | 114.1 s | 8.97 MB/s |
| 2 GiB | 204.1 s | 10.03 MB/s |

三点线性拟合：

```
时间 = 20.1 秒 + 数据量 / 11.1 MB/s
```

**稳态吞吐 11.1 MB/s（89 Mbps）**，前面有约 **20 秒固定开销**（TCP 慢启动 + NCM
缓冲填充）。测速时用大文件才能看到真实速率。

### 所有软件调优都试过了，全部无效

| 尝试 | 结果 |
|:---|:---|
| USB 中断绑到 CPU 2 | 无效（单核本来就只 63%） |
| RPS 软中断摊到 CPU 4-7 | **+0.2%** |
| `txqueuelen` 加到 4000 | 无效 |
| TCP 缓冲区加到 16M（`rmem_max`/`wmem_max`/`tcp_rmem`/`tcp_wmem`） | **+0.9%**（9.04 → 9.12） |
| `ethtool -K usb0 gso on` | ❌ `Could not change any device features` |
| `ethtool -K usb0 tso on` | ❌ `tx-tcp-segmentation: off [fixed]` |
| `ethtool -K usb0 sg on` | ❌ `tx-scatter-gather: off [fixed]` |
| MTU 9000 | ❌ 见下 |

**手机的 usb0 上 GSO / TSO / scatter-gather 全部是 `[fixed] off`**，这是 `u_ether`
框架的硬限制，内核不允许改。所以 gadget 只能一个包一个包地发。

### 巨型帧：这条路彻底堵死

| 环节 | 支持 9000？ |
|:---|:---|
| 手机 gadget（NCM 端） | ✅ 支持到 15412 |
| OpenWrt（Linux `cdc_ncm`） | ✅ 支持，但需手配 |
| **Windows NCM 驱动** | ❌ **上限 1500，无 `JumboPacket` 属性** |
| OpenWrt 桥 `br-lan` | ⚠️ MTU 取所有端口最小值 |

Windows 上执行 `netsh interface ipv4 set subinterface "以太网 5" mtu=9000` 会报
**「参数不正确」** —— 不是权限问题，驱动压根没有这个能力（`UsbNcm Host Device`
10.0.26100.9818 的高级属性里没有 Jumbo Packet）。

端到端任何一跳是 1500，整条路径就按 1500 走。只要经过 Windows，巨型帧永远无意义。

> 💡 **OpenWrt 不需要为巨型帧做任何配置**，它只需要那个桥接热插拔脚本
> （见 [刷机教程](TUTORIAL.md#八路由器桥接)），那跟 MTU 无关。

### 结论

**9 MB/s（77 Mbps）就是这台设备在当前内核下的实际天花板。**

想再快只能让 MUSB 走 DMA（改控制器驱动），风险太大不值得 —— 这台设备没有串口兜底。

---

## 网络类

### 插电脑 ping 不通

**排查**：

```bash
# 1. 网卡有没有枚举（Windows 设备管理器看 "USB Ethernet/RNDIS Gadget"）
# 2. 等够时间 —— 首次开机要扩容，约 10 分钟
# 3. 网卡状态是不是 Up
```

**注意**：扩容期间 USB 已经枚举（内核侧），但 `usb0` 还没配 IP，所以 **ping 不通是正常的**。

---

### Ubuntu / Fedora 启动后没有 SSH

**原因**：首启联网服务卡住。

**说明**：`ubuntu-advantage.service`、`ua-reboot-cmds`、`cloud-init` 这些服务在**没有外网**时会等待/重试，把开机拖到十几分钟。Fedora 还会启用 `NetworkManager`，和我们的 `systemd-networkd` **抢 usb0**，结果谁都没配上地址。

**解法**：构建时 mask 掉这些服务 + mask `NetworkManager`。

---

### `pacman -Sy` / `apt update` 失败（手机上）

**说明**：如果你把手机插在**电脑**上，手机没有外网 —— 这是正常的。要更新软件包，把手机插到**路由器**的 USB 口上。

---

### `Could not connect to server ... after 1 ms`（构建时）

**原因**：`getent hosts` 返回了 IPv6 地址，而 qemu chroot 里没有 IPv6 路由。

**解法**：用 `getent ahostsv4` 强制取 A 记录。

---

## 构建类

### `The source tree is not clean`（`O=out` 内置编译）

**原因**：源码树里残留 `include/config`、`include/generated` 等。

**解法**：`O=out` 时把这些残留删掉再编。

---

### `modprobe: FATAL: Module f2fs not found`（CI）

**原因**：Azure runner 内核没有 f2fs。

**解法**：同上，改用 `mke2fs -d`。

---

### `failed to commit transaction (not enough free disk space)`

**原因**：`pacman` 的 `CheckSpace` 会去 stat 缓存目录的挂载点，而普通目录 chroot 不是挂载点。

**解法**：构建时 `sed -i 's/^CheckSpace/#CheckSpace/'`。

---

### Ubuntu/Debian 的 apt 签名校验失败

**症状**：

```
At least one invalid signature was encountered.
```

**原因**（两种）：

1. 宿主机的 `debian-archive-keyring` **太旧**（比如 2023 版签不了 trixie）
2. 走了 HTTP 代理，代理 **MITM 改写**了 `InRelease`

**解法**：

- 换成最新的 keyring（从镜像站拉 `debian-archive-keyring_2025.1_all.deb`，`dpkg-deb -x` 取出 `.gpg`）
- **国内镜像不要走代理**，直连

---

### Fedora 在 CI 里 `rpmdb missing`

**症状**：

```
!! rpmdb missing at /usr/lib/sysimage/rpm
```

**原因**：Ubuntu 的 `rpm` 默认 `%_dbpath=~/.rpmdb`（rootless），dnf `--installroot` 时数据库位置取决于 `$HOME`：

| 场景 | `$HOME` | 实际落点 |
|:---|:---|:---|
| 本地 `bash build.sh` | `/root` | `$R/root/.rpmdb` ✅ |
| CI `sudo -E` | `/home/runner` | `$R/home/runner/.rpmdb` ❌ |

**解法**：不要假设路径，用 `find "$R" -name .rpmdb` 搜出来再搬。

---

### `rm -rf` 把宿主 `/sys` 删了

**原因**：`out/work/rootfs` 下有残留 bind mount，`rm -rf` 会穿过去。

**解法**：删除前先 `umount`，并检查 `/proc/self/mountinfo`。

---

### `sleep: not found` 刷屏

**原因**：initramfs 里的 busybox 缺少 applet 软链接。

**解法**：`delay()` 分层回退 —— 有 `sleep` 用 `sleep`，没有用 `usleep`，再没有就轮询 `/proc/uptime`。这样无论哪种 busybox 都不会刷屏或空转。

---

## 内核类

### 上游 `main` 编出来的内核能启动吗？

**不能。** 实测：

| 内核来源 | 内核大小 | 结果 |
|:---|---:|:---|
| 上游 `main`（9c62af69） | 19,092,832 B | ❌ 循环重启 |
| `cb9ba2ee`（锁定版） | 19,098,824 B | ✅ 正常 |

作者重写过 `main`，能编译但**启动不了**。所以 `build.sh` 锁定 `KERNEL_COMMIT=cb9ba2ee0f929ff8985f4821a0ee32fa1c06c5fd`（上游还能按 SHA fetch 到）。

---

### 上游 `main` 是残缺的

移植提交缺 3 个头文件，还引用了不存在的头：

- 缺 `dt-bindings/pinctrl/mediatek,mt6833-pinfunc.h`
- 缺 `dt-bindings/power/mediatek,mt6833-power.h`
- 引用不存在的 `gce/mediatek,mt6833-gce.h`、`memory/mt6833-larb-port.h`、`reset/mediatek,mt6833-resets.h`

**解法**：6 个文件 vendor 到 `config/port/`，构建前覆盖。

---

### 开机看不到小企鹅 🐧

**原因**（两层）：

1. 内核确实画了 logo（`CONFIG_LOGO=y` + `LOGO_LINUX_CLUT224=y`）
2. 但 **init 往控制台打了十几行日志**，把 logo 滚出了屏幕

**解法**：`log()` 只写文件，不写控制台。

> ⚠️ 别去掉 `fbcon=nodefer` —— 实测去掉后内核根本到不了用户态。

---

### `f2fs: Unknown parameter 'offset'`

**原因**：`mount -o loop,offset=` 不支持 f2fs。

**解法**：先 `losetup -o <offset> /dev/loop0 /dev/sdc`，再 `mount /dev/loop0`。

---

## 打包类

### `fastboot -S 500M` 报 `data is too large`

**原因**：LK 对大块 sparse 有限制。

**解法**：用 `-S 200M`。

---

### Windows fastboot 崩 `std::bad_alloc`

**原因**：Windows 版 fastboot 会把整个 6 GiB raw 镜像读进内存。

**解法**（二选一）：

```bash
# 流式喂
gunzip -c userdata.img.gz | fastboot -S 200M flash userdata -

# 或先转稀疏（更快，6 GiB → 2.1 GB）
img2simg userdata.img userdata.simg
fastboot -S 200M flash userdata userdata.simg
```

---

## 试过但放弃的方案

| 方案 | 结果 |
|:---|:---|
| f2fs 离线扩容（`resize.f2fs`） | ❌ 永久卡死 + 损坏文件系统 |
| f2fs 在线扩容（内核 ioctl） | ❌ 内核只实现缩小 |
| 100 GiB 整镜像 | ✅ 能构建，但产物 940 MB / 2.2 GB，且违背「小镜像」原则 |
| Alpine initramfs（PE 式调试环境，39 MB） | ❌ panic |
| Alpine initramfs 精简版（15 MB） | ❌ 仍 panic |
| 去掉 AVB footer | ❌ LK 卡 Redmi logo |

最终方案：**4.7 MB 手写 busybox initramfs + ext4 + `resize2fs`**，四个发行版的 rootfs 全部能启动。

---

<div align="center">

遇到这里没写的问题，欢迎提 Issue 并附上**屏幕照片**和 `dmesg`。

</div>
