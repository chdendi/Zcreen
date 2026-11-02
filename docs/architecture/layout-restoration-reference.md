# 布局恢复维护参考

最后更新：2026-11-01

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

1. 用 `bundleId` 对快照窗口和运行中窗口分组，只枚举快照里出现过的 app 的窗口。
2. 先按窗口身份配对：本次运行期间保存某个 profile 时，`LayoutSnapshotStore` 会在内存里记住每个条目来自哪个 AX 窗口元素。屏幕插拔通常不会重启 app，同一个窗口元素即使标题变了、被 macOS 挪走或缩小，也能精确配对。身份不持久化，Zcreen 或 app 重启后为空。
3. 剩下的窗口用 `windowTitle`、`role`、`subrole`、`screenKey`、`screenName`、窗口尺寸做打分匹配。跳过非正分数配对；分组内有多个候选时还会跳过低置信度配对（按身份配对前的组大小判断）。`screenKey` 一致加分，不一致不扣分：屏幕变化后运行中窗口所在的屏幕只是 macOS 挤过去的位置，扣分会把正确配对压到阈值以下。
4. 如果 `screenKey` 和 `relativeFrame` 能命中当前物理屏幕，则按相对坐标恢复。
5. 如果当前环境无法解析目标物理屏幕，则退回保存时的绝对 `frame`。
6. 已经在目标位置 2pt 以内的窗口不再移动，避免重复设置触发 app 重排和闪动。
7. 重试结束后约 1 秒复查移动过的窗口；偏离目标超过 10pt 的再移动一次，仍不到位的记为 drifted。

### 应用规则与历史布局

- 配置了选屏规则的应用也参与快照保存，手动调整和 Snap Bar 吸附后的尺寸会更新历史记录。
- 规则负责选择目标屏幕；`RuleApplyService` 从当前 `profileKey` 的快照中匹配该应用的窗口，优先恢复保存的几何信息。已在目标屏幕上的窗口也会恢复尺寸。
- 目标屏幕与历史屏幕相同，继续使用物理屏幕 key 和相对坐标；规则改到另一块屏幕时，保留历史尺寸，并把窗口限制在目标屏幕范围内。
- 没有当前屏幕组合的历史记录，或多出来的窗口无法配对时，沿用 `moveWindowToScreen` 的比例映射兜底。不使用其他屏幕组合的快照替代。
- 规则应用同样先按窗口身份配对，并跳过已在目标位置的窗口。
- 快照恢复后的规则应用带重试：规则 app 正在运行但 AX 暂时看不到窗口时，按 0.4 / 0.8 / 1.6 秒重试，屏幕再次变化或锁屏时取消。手动"应用规则"不重试。
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

- `beginConfigurationFlag`：显示器重配即将开始，用于在系统重新排窗前保存快照。这次保存和 WindowServer 存在竞争：抓取完成后会直接向 CoreGraphics 查询当前活动显示器（排除硬件镜像），与检测器缓存的屏幕对比，不一致就丢弃这次结果，避免把挤到一半的窗口写进旧组合。
- 所有非 begin 的重配回调（包括分辨率、镜像和无逐屏变化标志的完成回调）：静默 500 ms 后刷新当前 profile。新的 begin 会重置静默计时。

重配开始后阻止周期、手动和事件后的延迟保存，稳定后延迟 5 秒再开放保存。重复 begin 不重复捕获；新的重配和锁屏会使旧的保存任务、恢复重试、规则重试和应用启动规则轮询失效。"重配中"标记在最后一次重配事件 30 秒后仍未解除时，下一次保存尝试会强制解除并记 warning。重配或唤醒期间启动的 app，其启动规则会暂存（最多 20 个），稳定后重放。

`ScreenDetector.topologyFingerprint` 在 profile key 之外还包含每块屏的 frame。同一组物理显示器在分辨率、排列或主屏变化后 profile key 不变，但指纹会变。

### 唤醒

- 进入锁屏或屏幕休眠时，如果没有正在进行的重配，会先保存一次当前布局，再关闭保存。同时记下挂起前的 profile key 和指纹。
- 唤醒后进入 wake-settle 窗口：等到挂起前的 profile 出现就立即恢复；出现挂起前没有的显示器时只等 2 秒静默；否则最多等 8 秒静默再按当前 profile 恢复。
- 如果挂起期间和唤醒后都没有任何显示器事件，且 profile 和指纹都与挂起前相同，说明窗口没被系统挪动，跳过恢复。
- 首次恢复后进入 4 秒冷却期，期间的事件被吸收（漂回挂起前的 profile 除外）。冷却结束时，如果 profile 或指纹与上次恢复时不同，或者上次恢复被 begin 事件打断（重试或规则重试未完成），会再恢复一次，否则退出窗口。

## 保存与重试

- 快照先原子写盘，成功后才更新缓存和 profile 计数；失败传回调用方。
- AX 漏报整个应用时保留该应用的旧位置；明确排除的应用会从合并快照中移除。选屏规则管理的窗口仍保留历史尺寸供规则恢复。
- 恢复重试只处理仍在运行且尚未匹配的窗口，排除已经请求移动的 AX 窗口。最大重试三次，延迟为 0.4 / 0.8 / 1.6 秒。
- 切换到没有快照的 profile 也会取消旧恢复，避免旧布局在新组合中继续执行。
- 恢复（含重试和复查）进行中，自动保存直接跳过；手动保存不受影响。

### 恢复保护（restore guard）

恢复结束后 `LayoutSnapshotStore` 回报 `RestoreOutcome`：没放到位的窗口（drifted）、仍未找到窗口的快照条目（unresolved），以及这些 app 中没配上的运行窗口（orphans）。`SnapshotService` 据此建立保护：

- 后续自动保存中，这些窗口只要还停在恢复结束时的位置（2pt 以内），就不写入它们的当前位置，而是保留对应的快照条目。
- 用户挪动后视为确认，正常保存新位置；drifted 窗口的旧条目随之移除。
- 窗口关闭后解除对它的保护；整个 app 本次没抓到时视为 AX 漏报，继续保护。
- 受保护窗口都处理完后解除保护；只剩未找到窗口的条目时最多保留 2 分钟。手动保存、新的恢复都会清除保护。保护只在内存里，Zcreen 重启后不保留。

### 定时保存的开销

- 定时保存每 15 秒检查一次（容差 3 秒），只有自上次抓取以来有过任何键盘或鼠标输入才会遍历窗口。屏幕变化、唤醒、Snap Bar 和应用启动各有自己的保存，不受影响。
- 遍历是对每个 app 的 AX 查询，不截屏，也不需要录屏权限。AX 调用超时设为 1 秒，超时的 app 60 秒内跳过；移动窗口时首个调用超时会放弃这个窗口，避免卡死的 app 拖住主线程。

### 历史版本

每次覆盖快照前，旧文件会复制到 `~/.config/zcreen/snapshots/history/<profile 哈希>/<时间戳>.json`。自动保存最多每 10 分钟归档一次；手动保存会同时归档被替换的版本和新版本。每个屏幕组合保留最近 30 个版本。目前没有界面入口，需要回滚时手动把历史文件复制回 `snapshots/` 下同名的 `<profile 哈希>.json`，然后重启 Zcreen。

## 坐标与恢复策略

- AppKit 全局坐标用主屏左下为原点。
- Accessibility 坐标用主屏左上为原点。
- `CoordinateConverter` 统一负责两套坐标系的换算。
- `relativeFrame` 记录的是窗口在所在屏幕整块 frame（含菜单栏和程序坞区域，换算成 AX 坐标）中的归一化矩形，不是 `visibleFrame`。菜单栏高度或程序坞位置不同的情况下，按比例换算可能让窗口顶部略微压到菜单栏区域，由 macOS 自行下推。
- 恢复时会先把当前 `ScreenInfo.frame` 转成 AX 屏幕矩形，再把 `relativeFrame` 投影回实际坐标。

这套设计的目的是让同一块屏幕在主屏变化、上下堆叠或方向变化后，窗口仍尽量回到对应屏幕的合理区域。

## 已知限制

- 必须有 macOS Accessibility 权限；没有权限时无法枚举和移动窗口。
- 只能恢复 Accessibility API 能返回的窗口。若应用仍在运行但 AX 返回 0 个窗口，会记录日志并进入重试。
- 多窗口匹配主要依赖标题、角色和尺寸。如果应用窗口标题频繁变化或多个窗口标题完全相同，仍可能出现低置信度匹配。
- 相对恢复依赖 `screenKey` 命中当前物理屏幕；如果扩展坞、转接器或系统上报导致硬件 ID 变化，会退回绝对坐标兜底。
- 默认会过滤对话框、浮窗、系统弹窗、过小窗口和最小化窗口，因此这类窗口不会进入快照，也不会参与恢复。
- 待实测确认：AX 一般只返回当前桌面（Space）的窗口，而合并逻辑按 app 判断"是否抓到"。同一 app 在其他桌面的窗口可能在保存时被当作已关闭而丢弃。
- 窗口身份只在本次运行期间有效；Zcreen 或 app 重启后，第一次恢复仍依赖标题和尺寸打分。

## 维护建议

- 修改快照字段、profile 生成或屏幕识别逻辑时，同时更新本文件与对应回归测试。
- 如果新增了恢复兜底规则或明确发现新的失败边界，优先把限制写回本文件。
