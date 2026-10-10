# 布局恢复维护参考

最后更新：2026-10-10

## 目的

这份文档补充 Zcreen 自动保存/恢复主链路的维护上下文，避免后续开发前需要重新摸索 `Core` 和 `Model` 的实现细节。

## 模块定位

- 快照模型：`Sources/Zcreen/Model/LayoutSnapshot.swift`, `Sources/Zcreen/Model/WindowSnapshot.swift`
- 显示器识别：`Sources/Zcreen/Core/ScreenDetector.swift`, `Sources/Zcreen/Model/ScreenInfo.swift`
- 坐标换算：`Sources/Zcreen/Util/CoordinateConverter.swift`
- 快照保存与恢复：`Sources/Zcreen/Core/LayoutSnapshotStore.swift`, `Sources/Zcreen/Core/SnapshotService.swift`
- 应用选屏规则及历史尺寸恢复：`Sources/Zcreen/Core/RuleApplyService.swift`
- 窗口匹配与过滤：`Sources/Zcreen/Core/WindowMatcher.swift`, `Sources/Zcreen/Core/WindowFilter.swift`

## 快照模型

### `LayoutSnapshot`

`LayoutSnapshot` 是单个屏幕组合下的一份快照头信息，字段很少：

- `profileKey`：当前物理显示器组合的稳定键。
- `profileLabel`：给菜单栏和日志展示的人类可读名称。
- `timestamp`：保存时间。
- `windows`：当前 profile 下的全部 `WindowSnapshot`。

### `WindowSnapshot`

`WindowSnapshot` 保存恢复时真正依赖的窗口元数据：

- `bundleId` / `appName`：应用身份。
- `windowTitle`：多窗口应用的第一层匹配特征。
- `frame`：保存时的绝对 AX 坐标，作为最终兜底。
- `screenName`：保存时屏幕名称，用于补充匹配信号和日志。
- `screenKey`：物理显示器唯一键，来自 `ScreenInfo.uniqueKey`。
- `relativeFrame`：窗口在目标屏幕内的相对位置和尺寸。
- `windowRole` / `windowSubrole`：过滤浮窗并提升恢复匹配稳定性。

### 恢复优先级

恢复时并不是无条件回放绝对坐标，而是按下面的顺序处理：

1. 用 `bundleId` 对快照窗口和运行中窗口分组。
2. 对每组窗口用 `windowTitle`、`role`、`subrole`、`screenName`、窗口尺寸做打分匹配。
3. 如果 `screenKey` 和 `relativeFrame` 能命中当前物理屏幕，则按相对坐标恢复。
4. 如果当前环境无法解析目标物理屏幕，则退回保存时的绝对 `frame`。

### 应用规则与历史布局

- 配置了选屏规则的应用也参与快照保存，手动调整和 Snap Bar 吸附后的尺寸会更新历史记录。
- 规则负责选择目标屏幕；`RuleApplyService` 从当前 `profileKey` 的快照中匹配该应用的窗口，优先恢复保存的几何信息。已在目标屏幕上的窗口也会恢复尺寸。
- 目标屏幕与历史屏幕相同，继续使用物理屏幕 key 和相对坐标；规则改到另一块屏幕时，保留历史尺寸，并把窗口限制在目标屏幕范围内。
- 没有当前屏幕组合的历史记录，或多出来的窗口无法配对时，沿用 `moveWindowToScreen` 的比例映射兜底。不使用其他屏幕组合的快照替代。
- 应用启动、屏幕变化、手动恢复和手动应用规则共用这套策略。目标屏幕可用时，普通快照恢复会跳过对应规则应用，由规则服务恢复，避免窗口先回到历史屏幕后又被搬走。
- 规则目标屏幕未连接时，普通快照恢复仍可恢复该应用，不会仅因存在规则就排除它。

## 显示器识别策略

### 物理屏幕唯一键

`ScreenInfo.uniqueKey` 的格式是 `vendorID-modelID-serialNumber`。Zcreen 当前把它视为“同一块物理屏幕”的稳定标识。

### Profile 生成

`ScreenDetector` 会收集每个 `NSScreen` 的：

- `displayID`
- `localizedName`
- `frame`
- `vendorID`
- `modelID`
- `serialNumber`
- `isBuiltIn`

随后按屏幕 `frame.origin.x` 排序，补充 `leftmost` / `center` / `rightmost` / `single` 位置标签，并生成：

- `profileKey`：所有 `uniqueKey` 排序后用 `+` 拼接。
- `profileLabel`：所有 `shortName` 排序后用 ` + ` 拼接。

这意味着：

- 同一组物理显示器只要硬件 ID 不变，就会落到同一个 `profileKey`。
- 主屏切换、左右顺序变化、竖屏切换不会直接生成新的 profile；这些变化由相对恢复逻辑吸收。

### 屏幕变化事件

`ScreenDetector` 同时监听两类时机：

- `beginConfigurationFlag`：显示器重配即将开始，用于在系统重新排窗前保存快照。
- `add/remove/moved/setMain`：显示器变化完成后，经 debounce 再刷新当前 profile。

## 坐标与恢复策略

- AppKit 全局坐标用主屏左下为原点。
- Accessibility 坐标用主屏左上为原点。
- `CoordinateConverter` 统一负责两套坐标系的换算。
- `relativeFrame` 记录的是窗口在目标屏幕 AX 可见区域中的归一化矩形。
- 恢复时会先把当前 `ScreenInfo.frame` 转成 AX 屏幕矩形，再把 `relativeFrame` 投影回实际坐标。

这套设计的目的是让同一块屏幕在主屏变化、上下堆叠或方向变化后，窗口仍尽量回到对应屏幕的合理区域。

## 已知限制

- 必须有 macOS Accessibility 权限；没有权限时无法枚举和移动窗口。
- 只能恢复 Accessibility API 能返回的窗口。若应用仍在运行但 AX 返回 0 个窗口，会记录日志并进入重试。
- 多窗口匹配主要依赖标题、角色和尺寸。如果应用窗口标题频繁变化或多个窗口标题完全相同，仍可能出现低置信度匹配。
- 相对恢复依赖 `screenKey` 命中当前物理屏幕；如果扩展坞、转接器或系统上报导致硬件 ID 变化，会退回绝对坐标兜底。
- 默认会过滤对话框、浮窗、系统弹窗、过小窗口和最小化窗口，因此这类窗口不会进入快照，也不会参与恢复。

## 维护建议

- 修改快照字段时，同时更新 `tap-agents/prompts/modules/Model.md`。
- 修改 profile 生成或屏幕识别逻辑时，同时更新 `tap-agents/prompts/modules/Core.md` 和 `tap-agents/prompts/module-map.md`。
- 如果新增了恢复兜底规则或明确发现新的失败边界，优先把限制写回本文件。
