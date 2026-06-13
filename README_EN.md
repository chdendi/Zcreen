# Zcreen

<p align="center">
  <a href="https://github.com/chdendi/Zcreen/releases/latest">
    <img src="https://img.shields.io/github/v/release/chdendi/Zcreen?style=flat-square&color=blue" alt="Latest Release">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License">
  <a href="README.md">中文</a>
</p>

**Plug in your monitor, and your windows return to their last positions.** Zcreen remembers and restores layouts for each screen setup.

<p align="center">
  <a href="https://github.com/chdendi/Zcreen/releases/latest">
    <b>Download Latest DMG</b>
  </a>
</p>

---

## Features

### 1. Auto Save & Restore Window Layout

- Saves every window's exact position per screen combination
- Identifies physical monitors by hardware fingerprint (vendor + model + serial)
- Restores the matching layout when displays reconnect
- Portrait displays, mixed resolutions, any arrangement

### 2. Snap Bar — Drag to Layout

Drag a window and a floating layout bar appears at the top. Release to snap:

| Layout | Description |
|--------|-------------|
| **Full** | Entire screen |
| **Padded** | 80% centered with margins |
| **1/2** | Left / Right split |
| **1/3** | Left / Center / Right |
| **1/4** | Top-left / Top-right / Bottom-left / Bottom-right |

- Portrait screens automatically switch to vertical splits
- 6pt smart gaps between adjacent windows

### 3. Caffeinate — Keep Awake

One-click prevent display sleep from the menu bar. Duration: 1h / 2h / 4h with countdown.

## Install

**Download (recommended)**

Grab the DMG from [Releases](https://github.com/chdendi/Zcreen/releases/latest) → drag to Applications → launch → grant Accessibility permission.

**Build from source**

```bash
git clone https://github.com/chdendi/Zcreen.git && cd Zcreen
make install
```

## Requirements

- macOS 13+ (Ventura)
- Apple Silicon or Intel
- Accessibility permission (prompted on first launch)

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Accessibility permission required | System Settings > Privacy & Security > Accessibility > add Zcreen |
| Permission lost after rebuild | Each build changes the code signature; re-add in Accessibility settings |
| Snap Bar not showing | Verify Accessibility permission is granted and restart the app |

## License

MIT
