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
- 优先通过系统显示器 UUID 识别物理显示器，无法获取时回退到硬件指纹
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

### 4. 问题反馈

打开菜单栏面板，点击 `Feedback`，或连续点击面板左上角 Zcreen 图标 **5 次**（相邻点击间隔不超过 2 秒）。填写问题描述，可选择附带最近两天的日志（总量最多 4 MB，超出时截取最新内容）。确认后生成发给 `hg.dendi@gmail.com` 的邮件草稿，检查附件后在邮件应用里点击发送。

日志可能包含应用名和窗口标题；只有确认生成草稿才会打包。没有可用的邮件账户时，可点击 `Open Package` 取出反馈 ZIP 后手动发送。`Logs` 仍可直接打开原始日志目录。

自动更新会核验新包与当前应用的 Bundle ID 和 Developer ID 签名团队，暂存完成后才替换应用；替换或打开失败会回滚。成功更新后，旧应用保留在应用所在目录的隐藏 `.ZcreenUpdate-*/Previous.app` 中。临时签名的源码构建需手动下载更新。

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

## License

MIT
