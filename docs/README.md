# 📚 文档索引

文档按"只想用"和"想改/想调"分开。不确定看哪篇？先看下面的分类。

## 使用类（刷机、日常使用）

| 文档 | 什么时候看 |
|:---|:---|
| [../README.md](../README.md) | 项目是什么、快速开始、常用命令 |
| [TUTORIAL.md](TUTORIAL.md) | 第一次刷机：下载、fastboot、首次开机、联网、包管理 |
| [HARDWARE.md](HARDWARE.md) | 支持哪些硬件、面板/触摸怎么选、有哪些限制 |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | 开不了机 / 连不上 / 不扩容 / 构建报错，按症状查 |
| [PANIC.md](PANIC.md) | 内核崩了、无串口时怎么把 trace 抓出来 |

## 技术类（构建、内核、调试）

| 文档 | 什么时候看 |
|:---|:---|
| [BUILDING.md](BUILDING.md) | 本地构建 boot.img / 全量镜像，CI 参数，多发行版机制 |
| [KERNEL.md](KERNEL.md) | 内核仓库结构、已合入提交、DVFS/idle 分支与验证计划 |
| [MODULES.md](MODULES.md) | 各子系统（显示/触摸/WiFi/BT/音频/充电/传感器）的驱动与设备树 |
| [STRESS.md](STRESS.md) | 压力测试项目与历史结果 |
| [CAMERA-MODEM.md](CAMERA-MODEM.md) | 摄像头/基带的硬件现状、阻塞点与工作量分析 |
| [VENDOR-PORT.md](VENDOR-PORT.md) | 从 vendor 镜像/DTB 提取的信息摘要 |

## 变更记录

- 每个构建版本的改动见 [Release Notes](../.github/release-notes.md) 或对应 Release 页面。

## 维护约定

1. **README 只放用户需要的内容**（是什么、怎么刷、怎么连、已知限制）；技术细节一律放 `docs/`。
2. 新增文档先在上面的索引表里登记，并放到正确的分类下。
3. 内部交接/临时清单不提交到仓库；需要保留的写进对应的技术文档。
4. Release Notes 面向所有用户，按"新增 / 修复 / 已知问题"组织，不写实现细节。
