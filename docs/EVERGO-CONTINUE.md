# EVERGO 全链条收尾清单（必读，不要停）

本文件是这次工作的“必须完成清单”。任何后续接手的人/模型：按顺序执行，做一项勾一项，
不要等用户说“继续”。

## 已确认的产品决定

1. **90 Hz 保留**：面板是 90 Hz 屏，90 Hz 模式能让屏幕点亮即接受（60 Hz 不再要求共存/自动切换）。
2. 蓝牙文件传输、桌面预装应用、中文补全、构建流程优化都属于必做。
3. 电源键“能关不能开”继续修：若 DRM 重新点亮路径修不动，至少给临时方案并写入 Known Issues。
4. TSL2522 环境光当前 raw 恒 0（vendor sensor-hub 配置问题）→ 记录为已知问题；LSM6DSO 受 SCP 固件独占 → 已知问题。
5. 内核源码要干净：无 bring-up 调试打印、无 selftest 死代码、模块化提交、可复现构建。

## 目录 / 工具速查

- 内核树（WSL）：`/root/evergo-work`，分支 master
- 构建仓库（WSL）：`/root/redmi_note115G_pmos`
- 只编 boot：`KERNEL_SRC=/root/evergo-work RAM_GIB=6 PANEL=k16a_36_02_0a_vdo,lcm KERNEL_ONLY=1 INITRAMFS_ROOTFS=/root/alpine-e2fs ./build.sh`
- 全量 phosh：`KERNEL_SRC=/root/evergo-work RAM_GIB=6 PANEL=k16a_36_02_0a_vdo,lcm EDITION=phosh DISTRO=ubuntu ROOTFS_MB=10240 INITRAMFS_ROOTFS=/root/alpine-e2fs ./build.sh`
- 刷 boot：fastboot flash boot_a/boot_b/boot `D:\evergo\bootimg\boot-*.img`
- 刷 userdata：`fastboot -S 200M flash userdata <out/userdata.simg>`
- 设备：root@169.254.42.1（sshpass -p evergo）
- ESP：`http://192.168.111.188/off`、`/power?ms=6000`、`/fastboot?power=4000&hold=1000&off=1`
- GitHub 代理：`HTTPS_PROXY` 不可用，从 **Windows** 用 `curl.exe -s -k -x http://127.0.0.1:31181 ...` 调 `https://api.github.com`
- 内核提交工具：本机 PowerShell 脚本 + GitHub Git Data API（`--force` 更新 ref）

## 清单

### A. 内核整理（必须全部完成）
- [x] AW8697 / audio / fuel-gauge / TSL2522 / DTS 模块化提交（4 个提交，tip `2d3737d2`）
- [x] 删除 DRM 层 `evergo:`/`k16a:` 调试打印与 DSI selftest/vdo-test 死代码
- [ ] 恢复 90 Hz 面板模式（单模式，preferred；屏幕能亮即接受）
- [ ] 编译验证清理后的内核
- [ ] 提交内核清理 + 90 Hz + pmic-keys wakeup（提交历史保持整齐）
- [ ] 推送 `ccmx200/linux-evergo` master（新 tip）

### B. 构建仓库
- [x] phosh 预装应用/中文/obexd/iio-sensor-proxy/uinput/s2idle
- [ ] 全量 phosh 镜像构建成功（boot + userdata）
- [ ] `KERNEL_COMMIT` pin 更新到新内核 tip
- [ ] 推送 `ccmx200/redmi_note115G_pmos` main
- [ ] 触发目标 CI（ubuntu/6gib/phosh/Tianma/10240），确认 release

### C. 真机
- [ ] 刷 boot + userdata
- [ ] 屏幕点亮（90 Hz，DRM state 确认 90）
- [ ] 应用齐全（浏览器/计算器/时钟/看图/PDF/视频/压缩/截图/字符/磁盘/联系人/日历）
- [ ] 中文界面 + 输入法组件存在
- [ ] 蓝牙：obexd 服务存在，配对后文件传输可被 D-Bus 激活
- [ ] 音频/震动/充电/磁力计回归
- [ ] 电源键行为记录（能关不能开的日志，尝试修复）

### D. 压力测试（用户睡觉期间尽量跑）
- [ ] CPU 满载 10 min
- [ ] 内存压力至 OOM
- [ ] UFS 读写压力
- [ ] Wi-Fi 大流量 + 蓝牙开关
- [ ] 音频播放/录音/切换循环
- [ ] 震动循环
- [ ] 显示亮度/DPMS/电源键循环（抓 flip_done/DSI timeout）
- [ ] 传感器高频 I2C
- [ ] 充放电读值
- [ ] 重启 x5
- [ ] SSH 看门狗：>60 s 失联 → ESP 重启，收集 panic（pstore/dmesg/journal）

### E. 文档 & 清理
- [ ] `docs/MODULES.md` 更新：90 Hz、电源键、蓝牙、传感器、应用清单
- [ ] `README`/构建说明更新
- [ ] 压力测试结果写入 docs
- [ ] 取消残留 Actions 运行
- [ ] 删除临时 release（保留最终 build）
- [ ] 最终报告：改动、commit、证据、剩余风险、需用户手测项
