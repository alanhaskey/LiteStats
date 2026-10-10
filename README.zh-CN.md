# LiteStats

<img src="docs/images/icon.png" width="110" align="right" alt="LiteStats 图标" />

![平台](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![版本](https://img.shields.io/badge/version-1.0.3-blue)
![许可](https://img.shields.io/badge/license-MIT-green)

**一个住在 MacBook 刘海里的轻量系统监控。**

鼠标移到刘海上，面板下坠展开，显示 CPU、GPU、内存、网络、磁盘、温度和风扇；
鼠标移开，它自己收回去 —— 不占菜单栏，不进 Dock。

*[English →](README.md)*

![面板](docs/images/panel.png)

## 特性

- **藏在刘海里** —— 收起态与刘海融为一体，像素级看不出接缝
- **悬浮即开** —— 移到刘海上立刻展开；点一下可以固定住慢慢看
- **一眼看全** —— CPU（总体 + 每核心）、GPU、内存、网络、磁盘、温度、风扇
- **常驻指示条** —— 可选：收起时在刘海两侧各显示一个指标
- **支持外接屏** —— 没有刘海的屏幕，在顶部中央显示一颗常驻小胶囊
- **本地历史** —— 按天查看的日历、每小时的负载、按应用的占用，全部只存在本机
- **开销很低** —— 空闲时约 0.1% CPU、16 MB 内存
- **零依赖** —— 纯 Swift + 系统框架

| 常驻指示条 | 外接屏上的收起态 | 历史统计 |
| --- | --- | --- |
| ![指示条](docs/images/indicators.png) | ![圆槽](docs/images/slot.png) | ![历史](docs/images/history.png) |

## 系统要求

macOS 14 或更高版本，Apple Silicon。

## 安装

1. 到 [Releases](https://github.com/alanhaskey/LiteStats/releases) 下载 `LiteStats-1.0.3.dmg`
2. 打开后把 **LiteStats** 拖进「应用程序」
3. 启动即可 —— 应用常驻后台，不显示 Dock 图标

> 没有做代码签名与公证，所以首次打开时 macOS 会让你确认：
> **右键点应用 → 打开**，或者执行
> `xattr -d com.apple.quarantine /Applications/LiteStats.app`

## 使用

| 操作 | 结果 |
| --- | --- |
| 鼠标移到刘海 | 面板展开，数据每秒刷新 |
| 鼠标移到面板上 | 保持展开，可以慢慢看 |
| 鼠标移开 | 面板收起，采样自动放慢 |
| 点击刘海或面板 | 固定展开（再点一次取消） |
| 菜单栏图标 | 历史统计（⌘H）· 设置（⌘,）· 退出（⌘Q） |

**设置**里可以选择刘海两侧各显示哪个指标（也可以都不显示）、两侧的宽度、数据刷新频率、
面板显示在哪块屏幕上，以及是否开机自动启动。

**历史统计**会打开一个窗口：今天的每小时负载、可以按天翻看的日历，以及按 CPU、网络、内存
排名的应用。数据随时可以一键清空，不会离开你的电脑。

## 从源码构建

只需要 SwiftPM，没有 Xcode 工程。

```bash
git clone https://github.com/alanhaskey/LiteStats.git
cd LiteStats
./scripts/build-app.sh release
open "dist/LiteStats.app"
```

常用脚本：`./scripts/run.sh`（前台运行）、`./scripts/test.sh`（单元测试）、
`./scripts/run.sh --selftest`（无头自检）。

## 更多

实现细节、实测数据和过程中踩过的坑都在 [docs/architecture.md](docs/architecture.md)。

## 许可

[MIT](LICENSE) © 2026 alanhaskey

温度和风扇读取用到了 Apple 未公开的传感器接口，属于可选项 —— 读不到就不显示，不影响其它功能。
