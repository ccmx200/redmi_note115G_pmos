# 抓 panic 日志（没有串口时怎么排查）

这块板子没有 UART。内核的 console 输出由 `arch/arm64/kernel/setup.c` 里的
`evergo_ring` 写进一块 DRAM ring（0x7ffbf000，256 KiB），**每次启动时 LK 会把上一
次会话的 ring 刷进 `expdb` 分区**。所以：

- `/sys/fs/pstore` 在重启后通常是空的（ramoops 只在同一会话内有效，且 LK 会把它
  转存到 expdb）；
- 唯一能跨重启看到 panic 的地方是 **`expdb` 分区**（GPT 里 40 MiB）。

## 用法

在手机上（root）：

```bash
./scripts/read-expdb.sh              # 自动找带 GPT 的 UFS LUN
./scripts/read-expdb.sh /dev/sdc     # 手动指定
```

脚本会：

1. 解析 GPT 找到 `expdb` 分区（这个设备的 GPT 在 **LBA1、4096 字节逻辑块**，
   所以是磁盘偏移 4096，不是 512）；
2. `dd` 出 40 MiB 到 `/tmp/expdb.bin`；
3. 把 NUL 替换成换行，输出最后一段崩溃块（`Kernel panic` / `Unable to handle` /
   `BUG: Bad page map` / `Call trace`）；
4. 解析 `EVFRAME` 帧，把内核 console ring 按序号拼出最近的日志。

输出在 `/tmp/evergo-panic.log`（默认）。常用：

```bash
grep -nE 'Kernel panic|Unable to handle|BUG: Bad page map|Call trace|pc :' /tmp/evergo-panic.log
```

从 PC 上跑：

```bash
ssh root@169.254.42.1 ./scripts/read-expdb.sh
ssh root@169.254.42.1 grep -nE 'Kernel panic|Call trace' /tmp/evergo-panic.log
```

## 已知的崩溃形态（2026-11-01 用 expdb 取回）

在 `a602c03b` 内核（build-40）上，跑 `apt install ubuntu-desktop-minimal`
（dpkg 解包/删除大量包）约 2.3 小时后崩：

```
BUG: Bad page map in process rm  pte:ffefffffffff1f7f
pgd:0000000000000000 p4d:080000006b7db403 pud:080000006b7dc403 pmd:080000006c03c403
addr:0000ffff8e026000 vm_flags:00000070 anon_vma:0000000000000000 mapping:0000000000000000
...
Internal error: SP/PC alignment exception: 000000008a000000 [#1]  SMP
Kernel panic - not syncing: SP/PC alignment exception: Fatal exception in interrupt
```

`rm` 的 munmap 路径里，一整段 VMA 的 **PTE 全是 `0xffef…f7f` 这样的乱值**（每页递增
0x1000）——这是**内存/页表被踩**，不是某个 NULL 指针的小 bug。同一次 expdb 里更早的
内核（#33/#37/#38/#41）还有：

- `Kernel panic - not syncing: kernel stack overflow`（pc 落在 `el1h_64_sync`）
- `timer_recalc_next_expiry` 里的 paging request（timer wheel 读到坏指针）
- `Attempted to kill the idle task` / `cpu_util` 里的 paging request

这些都是**同一类现象：内存被写坏**，坏在哪取决于踩的是哪块内存。

## 下一步排查建议

1. **关掉 WiFi/CONN 复测**：`systemctl stop evergo-wmt`，`modprobe -r` gen4m 相关
   模块（或干脆用一个不带 `wmt-init` 的 boot.img），再跑同样的 dpkg 负载几小时。
   若不再崩，重点查 CONN/gen4m 的 DMA/EMI 窗口是否有越界写（EMI 5 MiB @0xbf000000、
   WiFi 6 MiB @0xbe000000，都是 `no-map` 的 reserved-memory，理论上是安全的，
   但固件 DMA 不一定遵守）。
2. **复测 8 GiB 变体**：`boot-*-8gib.img` 的 DTB memory 节点与 6 GiB 不同，若 8 GiB
   镜像在 6 GiB 机上反而稳定/相反，说明是 memory/EMI 布局问题。
3. **memtester**：`apt install memtester && memtester 4G 1` 跑几轮，排除 DDR 本身
   marginal 的可能（老机器 + 之前的 ext4 报错也要留意）。
4. 复现后立刻 `./scripts/read-expdb.sh` 拿 trace；如果是内核 bug，把 trace 贴回上游
   `KevinLmK0702/linux-evergo`。

## 高负载下的 allocator panic（2026-11-01，装桌面时）

装 `ubuntu-desktop` 时板子在 uptime ~95 s 和 ~204 s 各崩一次，expdb 里取到的两条：

```
# 1) 中断上下文里跳到空指针（PC = 0）
CPU: 0 PID: 0 Comm: swapper/0  pc : 0x0
Call trace:
 0x0
 rcu_core_si+0x10/0x1c        ← 软中断回调指针被写坏
 handle_softirqs / __do_softirq / __irq_exit_rcu / el1_interrupt / default_idle_call
Kernel panic - not syncing: Oops: Fatal exception in interrupt

# 2) 写块设备时 SLUB refill 里 NULL 解引用
CPU: 3 PID: 240 Comm: dd
Unable to handle kernel NULL pointer dereference at virtual address 00000000000000c0
pc : __refill_objects_node+0x2a4   (ldr x5, [x6, x1] ；x6=0，x1=0xc0)
Call trace:
 __refill_objects_node → refill_objects → __pcs_replace_empty_main
 kmem_cache_alloc_noprof → bio_alloc_bioset → __bh_submit
 __block_write_full_folio → blkdev_writepages → bdev_release
```

两条都是**内存/分配器数据被踩**的表现（软中断函数指针变成 0、slab sheaf 里出现 NULL
对象指针），压力越大越容易命中。和 display 的 NULL state 不是同一个问题。

**缓解**：给 6 GiB 版本加 swap，降低「真的把内存用满」的概率。镜像里已经加了
`evergo-swapfile.service`（MemTotal < 7 GiB 时首次启动创建 3 GiB `/swapfile` 并
`swapon`）。装桌面这种重活建议：

```bash
fallocate -l 3G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
systemd-run --unit=desktop-install --collect --no-block \
    /bin/bash -c 'apt-get -y --no-install-recommends install ubuntu-desktop-minimal > /root/desktop-install.log 2>&1'
```

彻底避免的办法是**离线把桌面装进镜像**（在 PC 的 chroot 里装好再刷），不在手机上跑 apt。

## 2026-11-01：memtester 实测结果（内存压力下数据错乱）

装桌面反复 panic 后，直接在系统里跑 `memtester`（先连 WiFi `apt install memtester`）：

| 测试 | 结果 |
|:---|:---|
| `memtester 4G 1` | **几百万个数据不匹配**；集中在 256–512 MiB、768–1024 MiB、1280–1536 MiB、1536–1792 MiB 等连续区间，读回值像内核数据/随机值 |
| `memtester 3G 1`（同一系统、驱动全开） | 基本干净（只有 1 处不匹配） |

结论：

* 不是 WiFi / display / initramfs 的软件 bug。**用到的内存越多越容易踩到坏区**，
  这正好对应“平时能用、一装桌面/高负载就 panic”。
* panic 形态（`pc : 0x0` 软中断、`__refill_objects_node` 里 NULL、Bad page map）都是
  内存数据错乱的后果，不是彼此独立的 bug。

规避手段：

1. 镜像自带 `evergo-swapfile.service`（RAM < 7 GiB 时首次启动建 3 GiB swap），降低内存压力。
2. 本机实测 **bootargs 加 `mem=4G`** 限制可用内存后稳定性明显改善（可用 ~3.7 GiB）；
   这是一个取舍，是否默认开启见 `build.sh` 的 `BOOTARGS`。
3. 装桌面用 CI 的 desktop 镜像 / 离线 chroot 装好再刷，不要在手机上跑
   `apt install ubuntu-desktop`（那是最容易触发 panic 的场景）。
4. 想彻底确认硬件：刷回官方系统在同样负载下跑内存测试；官方系统也报错就是硬件问题
   （保修/换板）。

### 与 `构建` 相关的一个 bug（已修）

boot job 之前用默认 `DISTRO=arch` 跑了一遍完整 rootfs，导致每次“内核构建”日志里都在编
Arch。现在 `KERNEL_ONLY=1` 会在 `rootfs` 段之前直接跳过所有发行版 rootfs，日志会出现
`kernel-only build: distribution rootfs + userdata skipped`；CI run 50 的 `boot / 6 GiB`
和 `boot / 8 GiB` 已验证不再编任何发行版。


### build-51..53 的 4 GiB 上限是个意外（已在下一个提交撤回）

`mem=4G` 原本只是本机稳定性实验，但它在修 gdm 符号链接的提交（5438501）里被
`git add build.sh` 一起带进了仓库，于是 build-51/52/53 产出的所有镜像都被限制到
3.8 GiB（`/proc/cmdline` 里有 `mem=4G`）。已撤回，镜像恢复 6 GiB；如果以后想再压内存，
在 `build.sh` 的 BOOTARGS 里加回 `mem=4G` 即可（代价是可用 3.8 GiB）。

## 2026-11-03：GPU/BT 修好后仍然存在的 slab/写回 oops

在 build-69（kernel 0334da9 + CONFIG_SCHED_CACHE 关闭 + GPU OPP）上，重负载
（apt 下载/解包 + 根文件系统 loop 写回）时段仍然出现两次非致命 oops：

```
#1  Workqueue: loop0 loop_rootcg_workfn
    pc : __refill_objects_node+0x2a4        (slab sheaf 里 NULL/负 node)
    refill_objects -> __pcs_replace_empty_main -> kmem_cache_alloc_noprof
    -> alloc_buffer_head -> folio_alloc_buffers

#2  Workqueue: writeback wb_workfn (flush-8:32)
    pc : __block_write_full_folio+0xd4
    block_write_full_folio -> blkdev_writepages ...
```

之后系统会卡死（SSH banner 超时），需要 ESP32 断电重启。结论：

* 不是 GPU（panfrost fault 计数为 0）也不是 BT 的问题；
* CVE-2026-31648（filemap_map_pages 下溢）在本 tree 里已修复，CVE-2026-98385
  （sched cache UAF）已通过关闭 CONFIG_SCHED_CACHE 规避，但都没能消掉这个 oops；
* 它落在 SLUB per-CPU sheaf 和 block writeback 路径，属于 **7.3-rc4 基线里的
  内存管理/块层问题**（或本 port 的 trigger）。当前 kernel 仓库没有 7.3-rc5/稳定版
  tag，要根治需要把整个 MT6833 port rebase 到更新的 mainline，或继续 backport
  具体修复。
* 临时缓解可试 `mem=4G`/`mem=5G` 限制内存压力（构建脚本 BOOTARGS 加回即可）。
