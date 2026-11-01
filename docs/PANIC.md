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
