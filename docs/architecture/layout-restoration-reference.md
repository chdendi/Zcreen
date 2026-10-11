# 布局恢复维护参考

最后更新：2026-10-11

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
2. 对每组窗口用 `windowTitle`、`role`、`subrole`、`screenKey`、`screenName`、窗口尺寸做打分匹配。跳过非正分数配对；多窗口候选还会跳过低置信度配对。
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

`ScreenInfo.uniqueKey` 优先使用 `CGDisplayCreateUUIDFromDisplayID` 返回的 UUID；不可用时回退到 `vendorID-modelID-serialNumber`，再回退到 `display-<id>`。它能减少同型号、零序列号显示器被旧硬件组合键合并的问题。

加载当前 profile 时，如果只有旧硬件组合键快照，且每块显示器可唯一映射，会迁移 profile 与窗口的 `screenKey`，保留原文件。旧键存在歧义时不猜测映射。

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
- 所有非 begin 的重配回调（包括分辨率、镜像和无逐屏变化标志的完成回调）：静默 500 ms 后刷新当前 profile。新的 begin 会重置静默计时。

重配开始后阻止周期、手动和事件后的延迟保存，稳定后延迟 5 秒再开放保存。重复 begin 不重复捕获；新的重配和锁屏会使旧的保存任务、恢复重试和应用启动规则轮询失效。唤醒阶段另有自适应等待与冷却窗口。

## 保存与重试

- 快照先原子写盘，成功后才更新缓存和 profile 计数；失败传回调用方。
- AX 漏报整个应用时保留该应用的旧位置；明确排除的应用会从合并快照中移除。选屏规则管理的窗口仍保留历史尺寸供规则恢复。
- 恢复重试只处理仍在运行且尚未匹配的窗口，排除已经请求移动的 AX 窗口。最大重试三次，延迟为 0.4 / 0.8 / 1.6 秒。
- 切换到没有快照的 profile 也会取消旧恢复，避免旧布局在新组合中继续执行。

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

- 修改快照字段、profile 生成或屏幕识别逻辑时，同时更新本文件与对应回归测试。
- 如果新增了恢复兜底规则或明确发现新的失败边界，优先把限制写回本文件。
