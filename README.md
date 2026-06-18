# Zcreen

<p align="center">
  <a href="https://github.com/chdendi/Zcreen/releases/latest">
    <img src="https://img.shields.io/github/v/release/chdendi/Zcreen?style=flat-square&color=blue" alt="Latest Release">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License">
  <a href="README_EN.md">English</a>
</p>

**插上显示器，窗口自动回到上次的位置。** Zcreen 会按屏幕组合自动记忆和恢复窗口布局。

<p align="center">
  <a href="https://github.com/chdendi/Zcreen/releases/latest">
    <b>下载最新版 DMG</b>
  </a>
</p>

---

## 核心能力

### 1. 自动记忆 & 恢复窗口布局

- 自动保存每种屏幕组合下所有窗口的精确位置
- 通过硬件指纹（厂商 + 型号 + 序列号）识别物理显示器
- 插上显示器后自动恢复对应布局
- 支持竖屏、不同分辨率、不同排列方式

### 2. Snap Bar — 拖拽即布局

拖拽窗口时屏幕顶部自动弹出布局条，松手即吸附：

| 布局 | 说明 |
|------|------|
| **Full** | 全屏 |
| **Padded** | 80% 居中，四周留白 |
| **½** | 左右分屏，拖到对应侧选择 |
| **⅓** | 三等分：左 / 中 / 右 |
| **¼** | 四象限：左上 / 右上 / 左下 / 右下 |

- 竖屏自动切换为纵向分割
- 相邻窗口 6pt 智能间隙

### 3. Caffeinate — 防息屏

菜单栏一键防止显示器休眠，可选 1h / 2h / 4h，带倒计时。

## 安装

**直接下载（推荐）**

从 [Releases](https://github.com/chdendi/Zcreen/releases/latest) 下载 DMG → 拖到 Applications → 启动 → 授予辅助功能权限。

**源码构建**

```bash
git clone https://github.com/chdendi/Zcreen.git && cd Zcreen
make install
```

## 系统要求

- macOS 13+（Ventura）
- Apple Silicon 或 Intel
- 辅助功能权限（首次启动提示授权）

## 常见问题

| 问题 | 解决 |
|------|------|
| 需要辅助功能权限 | 系统设置 → 隐私与安全性 → 辅助功能 → 添加 Zcreen |
| 重新构建后权限失效 | 每次构建产生新签名，需重新添加 |
| Snap Bar 不弹出 | 确认辅助功能权限已授予，重启应用 |

## 反馈问题

提交 issue 时，请尽量附上：

- macOS 版本、Zcreen 版本、屏幕数量和排列方式
- 复现步骤，例如“把 Xcode 拖到 Snap Bar 的左侧 1/2”
- 复现前后几分钟的日志

打开日志：点击菜单栏里的 Zcreen → 点击底部 **Logs**。日志文件位于 `~/Library/Logs/Zcreen/`，文件名形如 `zcreen-YYYYMMDD.log`。

隐藏调试入口：打开菜单后，连续点击左上角 Zcreen 图标 5 次可以打开配置目录 `~/.config/zcreen`。如果问题和规则或快照有关，也可以把相关配置或 snapshot 一起附在 issue 里。

## License

MIT
