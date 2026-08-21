# 忆光 Lumio macOS 端开发技术方案

> 状态：实施中（工程与核心主链路已落地，待真机媒体样本和 Developer ID 验收）
> 编制日期：2026-08-03
> 决策确认日期：2026-08-03
> 代码基线：`main` / `ef50a8e`
> 需求基线：[`Lumio_PRD_v0.5.md`](./Lumio_PRD_v0.5.md)
> 关联文档：[`TECHNICAL_PLAN.md`](./TECHNICAL_PLAN.md)、[`FEATURE_STATUS.md`](./FEATURE_STATUS.md)

## 1. 结论

当前设备和已安装工具链可以承担 macOS 端开发：Apple M4、16 GB 内存、macOS 26.5.2、Xcode 26.6、CocoaPods 1.17.0，Flutter 已识别 `macos` 目标设备。未安装 iOS Simulator Runtime 不影响 macOS 桌面端开发。

macOS 端不能只靠生成 `macos/` 工程目录完成。当前 Flutter UI 和领域状态可以复用，但媒体导入、沙盒文件授权、媒体扫描、持久化、音视频播放、系统媒体控制、视频纹理和桌面交互都需要单独适配。

推荐方案：

- 保持现有 Flutter UI、`LumioAppState`、领域模型和 Repository 抽象。
- 延续当前“每个平台实现原生能力”的结构，在 macOS Runner 中使用 Swift 实现三组既有 MethodChannel。
- 音视频首版采用 `AVFoundation` / `AVPlayer`，视频通过 `AVPlayerItemVideoOutput + FlutterTexture` 输出到现有 Flutter `Texture` 组件。
- 文件访问从 `NSOpenPanel` 开始，使用 security-scoped bookmark 保存用户授权，不申请全盘访问。
- UI 继续沿用现有 Lumio 品牌和 Material 视觉，仅增加响应式桌面布局、菜单、快捷键和鼠标交互，不整体替换为另一套 macOS UI 框架。
- 将 EQ、Crossfade、视频 PiP、冷门容器兼容列为后续能力，首版通过平台能力模型隐藏或禁用，避免“界面可操作但平台静默无效”。

### 1.1 2026-08-03 实施进度

已落地：

- 已生成 `macos/` Runner，Debug 构建成功；Release 已验证可生成 universal `arm64 + x86_64` App。
- 已实现 App Sandbox entitlement、security-scoped bookmark 来源存储、文件夹选择和来源管理。
- 已实现分区 JSON 状态、扫描快照、AVAsset 元数据、歌词/字幕、封面/视频首帧和文件重命名/移动。
- 已实现 AVPlayer、Flutter Texture、系统媒体控制、系统分享及 Flutter 播放事件同步。
- 已接入 macOS Repository、平台能力模型、媒体来源设置、扫描取消、桌面侧栏、菜单和快捷键。
- Release/Profile 已启用 Hardened Runtime；Bundle ID 为 `com.hxg.lumio`，最低版本为 macOS 13。

仍需外部或人工验收：

- 使用真实 MP3/AAC/M4A/WAV/FLAC、MP4/MOV/M4V 样本完成导入、重启授权、播放和视频纹理矩阵。
- 使用千级媒体目录完成性能和取消扫描验收。
- 配置 Apple Developer Team、Developer ID Application 证书和 notarytool keychain profile，完成首次签名、公证与 Gatekeeper 验收。
- 补齐桌面右键、多选、宽屏 Now Playing 双栏和显式备份文件导入/导出。

## 2. 问题定义

本方案要解决：在不破坏 Android/HarmonyOS 现有实现的前提下，为当前 Flutter 工程增加可独立构建、运行和发布的 macOS App，使用户可以授权本机媒体目录、建立离线媒体索引并完成音视频播放主链路。

该目标会调整 PRD D1“桌面端仅作远期预留”和原路线图 Phase 6 的优先级。本方案已确认；开始实施时应同步更新 PRD 决策记录和功能状态矩阵，避免需求基线与实施排期长期不一致。

本方案不解决：

- iOS 端适配。
- 用 AppKit/SwiftUI 重写整个 Flutter UI。
- 将现有分区 JSON/KV 全面迁移到 SQLite/Drift。
- 首版一次性实现 Android 所有系统特性和所有冷门音视频格式。
- 未经用户选择扫描整个磁盘或绕过 App Sandbox。
- 首版实现 EQ、Crossfade、视频 PiP、标签全格式写回和拖放导入。

成功标准：

1. `flutter run -d macos`、debug/release 构建成功，Android/HarmonyOS 构建行为不回退。
2. 用户可以添加和移除媒体目录；重启 App 后仍能访问已授权目录。
3. 可以扫描、恢复和刷新本地媒体索引，展示音频、视频、封面、歌词和字幕基础信息。
4. 支持音视频播放、暂停、seek、速度、上下曲、队列、循环、随机、续播和 Flutter 状态同步。
5. 窗口失焦或最小化后音频继续播放，键盘媒体键和系统播放控制可用。
6. 桌面宽屏布局、窗口缩放、菜单和常用快捷键可用，无明显移动端拉伸感。
7. 关闭在线增强后，导入、浏览和播放全部离线可用。
8. App Sandbox 下仅访问用户明确授权的目录，发布构建可以签名并进入公证流程。

## 3. 当前实现梳理

### 3.1 可复用部分

| 模块 | 当前实现 | macOS 复用策略 |
|---|---|---|
| UI 与主题 | `lib/main.dart`、`lib/features/`、`lib/shared/` | 保留页面和品牌主题，增加自适应 Shell 与桌面交互 |
| 应用状态 | `lib/app/app_state.dart` 中的 `LumioAppState` | 保留队列、播放状态、扫描状态、设置和分区保存流程 |
| 领域模型 | `MediaItem`、`Playlist`、`LumioSettings` | 保持 JSON 向后兼容，仅按需增加可选来源字段 |
| 歌词/字幕 | Dart LRC、SRT、ASS 解析器 | macOS 扫描侧返回原始文本，继续使用 Dart 解析和渲染 |
| 在线增强 | `FileOnlineEnhancementRepository` | 保持可关闭、文件缓存和失败静默降级 |
| 平台抽象 | app storage、media library、playback 三组 Repository | 将 `Platform.isMacOS` 纳入支持范围，新增 Swift 实现 |

### 3.2 当前平台通道

| 通道 | 当前方法 | 当前支持 | macOS 缺口 |
|---|---|---|---|
| `lumio/app_storage` | `loadPartition`、`savePartition`、`createBackup`、`restoreLatestBackup`、`latestBackup` | Android、HarmonyOS | 分区 JSON、原子写入、备份导入导出 |
| `lumio/media_library` | `scan`、`restoreLastScan`、`performFileOperation`、`loadArtwork` | Android、HarmonyOS 部分能力 | 文件夹授权、bookmark、扫描、元数据、封面、文件操作 |
| `lumio/playback` | 播放控制、队列模式、进度、EQ、Crossfade、PiP、亮度/音量、分享 | Android、HarmonyOS 部分能力 | AVPlayer、视频纹理、系统媒体控制、能力降级 |

当前三个 `Platform*Repository` 都只把 Android/HarmonyOS 视为受支持平台；macOS 即使启动 UI，也会返回不支持或直接不执行。

### 3.3 当前 UI 的移动端假设

- 根 Shell 固定使用底部 `NavigationBar`，宽屏空间利用不足。
- Mini Player 固定在底部导航上方，没有桌面侧栏/内容区结构。
- Now Playing 主要为纵向单列，桌面窗口下内容过宽、滚动距离较长。
- 全屏视频会设置移动设备方向和沉浸式 System UI；macOS 应改为窗口全屏语义。
- 视频手势左侧调亮度、右侧调音量属于移动端交互；macOS 不应修改系统屏幕亮度。
- 设置页通过手输路径配置包含/排除文件夹；macOS 应使用系统文件夹选择器。
- PiP、EQ、Crossfade 等入口没有统一的平台能力判断。

### 3.4 当前开发环境

| 项目 | 状态 |
|---|---|
| 设备 | MacBook Pro / Apple M4 / 16 GB |
| 系统 | macOS 26.5.2 / arm64 |
| Xcode | 26.6，Build 17F113，开发者目录已切换到完整 Xcode |
| CocoaPods | 1.17.0 |
| Flutter | 3.35.8-ohos-1.0.1 / Dart 3.9.2，OHOS 定制分支 |
| macOS 设备发现 | 已发现 `macos • darwin-arm64` |
| iOS Simulator Runtime | 未安装；不影响本方案 |
| 磁盘 | 当前约 43 GB 可用，release archive、符号和缓存增长前建议继续释放空间 |

## 4. 方案选型

### 4.1 方案 A：延续平台通道，Swift + AVFoundation（推荐）

做法：生成标准 Flutter macOS Runner，在 Runner 内注册 Swift 通道处理器；文件、播放、系统媒体和持久化走 Apple 原生框架，上层继续使用当前 Repository。

优点：

- 与 Android Kotlin、HarmonyOS ArkTS 的现有结构一致。
- 不需要把 Android 播放架构迁移到第三方跨端插件。
- AVFoundation、App Sandbox、媒体键、签名和公证路径清晰。
- Flutter UI 和 Dart 业务代码复用度高，平台差异集中。

缺点：

- 需要维护一套 Swift 平台实现。
- AVFoundation 对 MKV、WebM、OGG 等容器/编码不保证支持。
- EQ、Crossfade 和视频 PiP 不能直接照搬 Android 行为。

### 4.2 方案 B：引入 `media_kit` 等桌面播放插件

做法：macOS 播放改用基于 mpv 的 Flutter 插件，文件选择和存储使用社区插件。

优点：格式覆盖通常优于 AVPlayer，桌面视频能力上手较快。

缺点：

- 当前使用 OHOS 定制 Flutter，需要逐个验证插件、原生二进制和 CocoaPods/Swift Package 兼容性。
- 会形成 Android 原生 Media3、HarmonyOS 原生 AVPlayer、macOS 第三方插件三套不同状态语义。
- 需要额外评估 libmpv/FFmpeg 的许可证、动态库签名、Hardened Runtime、App Sandbox 和公证。
- 系统媒体控制、队列、后台状态仍需补原生桥接。

适用条件：格式验收明确要求 MKV/WebM/AVI/OGG 首版完整覆盖，且方案 A 的格式 spike 不通过。

### 4.3 方案 C：AppKit/SwiftUI 原生重写 macOS 端

优点：桌面体验和 Apple 框架集成最直接。

缺点：UI、状态、业务逻辑和测试体系几乎全部重复，长期维护成本最高，不符合当前跨平台架构。

结论：不采用。

## 5. 目标架构

```text
Flutter UI / Responsive Shell / PlatformMenuBar / Shortcuts
                         │
                  LumioAppState
                         │
          PlatformCapabilities（新增）
                         │
        ┌────────────────┼────────────────┐
        │                │                │
 AppStorageRepository  MediaLibraryRepo  PlaybackRepository
        │                │                │
        └────────── Flutter MethodChannel ┘
                         │
 macOS Runner / Swift
 ├─ LumioAppStoragePlugin
 │  └─ Application Support / JSON / Backup
 ├─ LumioMediaLibraryPlugin
 │  ├─ NSOpenPanel
 │  ├─ SecurityScopedBookmarkStore
 │  ├─ MediaScanner / MetadataExtractor
 │  └─ ArtworkProvider / FileOperationService
 └─ LumioPlaybackPlugin
    ├─ AVPlayer（首版；AVQueuePlayer 后续评估）
    ├─ AVPlayerItemVideoOutput / FlutterTexture
    ├─ MPNowPlayingInfoCenter / MPRemoteCommandCenter
    └─ NSSharingServicePicker
```

设计约束：

- Dart 领域层不直接引用 AppKit/AVFoundation 类型。
- bookmark 原始数据只保存在 macOS 沙盒容器，不进入 Flutter 日志、备份或跨端 JSON。
- Android/HarmonyOS 现有通道名称和返回值保持兼容。
- 平台不支持的功能必须通过能力模型在 UI 上显式隐藏/禁用，不使用无提示的永久 no-op。
- 首版不引入数据库；只有性能基准证明分区 JSON 无法满足需求时再评估迁移。

## 6. 平台能力模型

新增不可变的 `PlatformCapabilities`，由平台类型和原生探测结果共同构造，至少包含：

```text
supportsFolderPicker
supportsPersistentFolderAccess
supportsFileRename
supportsFileMove
supportsTagWrite
supportsShare
supportsVideoTexture
supportsPictureInPicture
supportsBrightnessAdjustment
supportsEqualizer
supportsCrossfade
supportsSystemMediaControls
```

macOS 首版建议值：

| 能力 | 首版 | 说明 |
|---|---:|---|
| 文件夹选择和持久授权 | ✅ | NSOpenPanel + security-scoped bookmark |
| 重命名/移动 | 🟡 | 仅限用户授予读写权限的来源目录，操作前二次确认 |
| 标签写回 | ⬜ | 首版只编辑 App 内索引，不写源文件 |
| 系统分享 | ✅ | NSSharingServicePicker |
| 视频 Texture | ✅ | AVPlayerItemVideoOutput + FlutterTexture |
| 系统媒体控制 | ✅ | MPNowPlayingInfoCenter + MPRemoteCommandCenter |
| EQ | ⬜ | AVPlayer 无现成多段 EQ，设置入口禁用并说明 |
| Crossfade | ⬜ | 首版禁用；后续评估双播放器或 AVAudioEngine |
| PiP | ⬜ | Flutter Texture 路径下首版不承诺，后续单独 spike |
| 屏幕亮度手势 | ⬜ | 桌面端不修改系统亮度 |

## 7. 媒体来源与沙盒权限

### 7.1 用户流程

1. 首次进入空媒体库，展示“添加媒体文件夹”。
2. 调用 `NSOpenPanel`，允许多选目录，默认不允许任意全盘扫描。
3. 为每个目录生成 app-scoped security-scoped bookmark。
4. 将 bookmark 存入 Application Support 下的 macOS 专用来源文件。
5. 扫描前解析 bookmark，并调用 `startAccessingSecurityScopedResource()`。
6. 扫描或播放完成后成对调用 `stopAccessingSecurityScopedResource()`；播放器持有资源期间保持访问租约。
7. bookmark 失效或变陈旧时，标记来源不可用，引导用户重新授权，不静默删除媒体索引。

### 7.2 来源模型

Dart 侧只暴露不敏感的来源摘要：

```json
{
  "id": "opaque-source-id",
  "displayName": "Music",
  "resolvedPath": "/Users/example/Music",
  "status": "available",
  "readOnly": false
}
```

bookmark 二进制、签名和安全作用域信息仅由 Swift `SecurityScopedBookmarkStore` 保存。

建议扩展 `MediaLibraryRepository`：

- `addSources()`：打开选择器并返回新增来源摘要。
- `listSources()`：列出已授权来源和可用状态。
- `removeSource(sourceId)`：撤销 App 内来源记录并刷新索引，不删除源文件。
- `scan(filter)`：仅扫描已授权来源。
- `cancelScan()`：大目录扫描时允许用户取消。

Android/HarmonyOS 对新增方法可返回 `unsupported`，不改变既有扫描流程。

### 7.3 Entitlements

首版同时更新 `Runner-DebugProfile.entitlements` 和 `Runner-Release.entitlements`：

- `com.apple.security.app-sandbox = true`
- `com.apple.security.files.user-selected.read-write = true`
- `com.apple.security.files.bookmarks.app-scope = true`
- `com.apple.security.network.client = true`，用于用户主动开启的在线增强

不申请全磁盘访问，不写死 Music/Movies/Downloads 全目录权限。若产品最终确认只读模式，将 `user-selected.read-write` 收紧为 `read-only`，并关闭重命名/移动能力。

## 8. 媒体扫描与元数据

### 8.1 扫描流程

```text
解析可用来源
  → 枚举文件（跳过隐藏文件、包目录和符号链接循环）
  → 扩展名预筛选
  → 读取文件标识、大小、修改时间
  → 与上次快照比较
  → 仅对新增/变化文件提取 AVAsset 元数据
  → 匹配同目录 LRC/SRT/ASS
  → 生成封面/视频首帧缓存
  → 批量返回索引并原子保存快照
```

实现要求：

- 文件枚举和元数据提取不占用主线程。
- 控制并发数，初始建议 4～8 个任务，按真机基准调整，避免同时打开过多 AVAsset。
- 快照比较至少使用 `sourceId + relativePath + fileSize + modificationDate`。
- 媒体 ID 优先采用稳定的文件资源标识；不可用时使用 `sourceId + relativePath` 的确定性哈希。
- 文件被移走、权限失效或损坏时保留可理解状态，不让整次扫描失败。
- 现有隐藏媒体 ID、收藏、播放次数和续播点继续在 Dart 层合并。
- `loadArtwork` 返回压缩后的有限尺寸数据；列表封面和大图使用不同缓存规格，避免 MethodChannel 传输原始大图。

### 8.2 元数据来源

| 数据 | 建议实现 |
|---|---|
| 时长、格式、轨道信息 | AVAsset 异步加载属性 |
| 标题、艺术家、专辑 | AVMetadataItem；缺失时回退文件名/未知字段 |
| 音频封面 | common metadata artwork |
| 视频分辨率 | 视频轨道 naturalSize + transform |
| 视频首帧 | AVAssetImageGenerator，失败回退占位图 |
| 文件大小、添加/修改时间 | URL resource values |
| 本地歌词/字幕 | 同目录同名文件读取，继续复用 Dart 解析器 |

### 8.3 数据模型兼容

如来源管理需要跨重启稳定定位，建议为 `MediaItem` 增加可选字段：

- `sourceId`
- `relativePath`
- `availability`

旧数据读取时字段默认为空，Android/HarmonyOS 不要求立即填充。持久化 `schemaVersion` 从 1 升到 2，并提供“缺失字段使用旧 path”迁移逻辑。bookmark 不属于 `MediaItem`，不进入备份。

跨平台备份首版只保证设置、会话和同平台媒体索引恢复；不同平台的绝对路径和授权不能直接迁移。恢复时若来源不可用，应保留设置和播放列表结构，丢弃不可解析的当前播放项，并提示重新授权来源。

## 9. 音视频播放

### 9.1 首版引擎

使用 `AVPlayer` 统一音频和视频主链路：

- `play` 创建或切换 `AVPlayerItem`，按请求恢复 position。
- `pause`、`resume`、`seek`、`setSpeed`、`setVolumeScale` 映射到 AVPlayer。
- Flutter 继续持有业务队列、循环和随机状态；系统上一首/下一首事件回调 Dart，再由 Dart 决定目标媒体。
- 周期性进度由原生时间观察者或现有 Dart `position()` 轮询同步，必须避免重复注册观察者。
- 播放完成、失败、系统播放/暂停、媒体切换继续复用现有 `PlaybackEvent` 语义。
- 睡眠定时、AB 循环、歌词/字幕时间轴继续由 Dart 控制。

### 9.2 视频渲染

推荐保持现有 Flutter `Texture` UI：

1. 为当前 `AVPlayerItem` 添加 `AVPlayerItemVideoOutput`。
2. 实现 macOS `FlutterTexture`，从输出复制 `CVPixelBuffer`。
3. 在有新帧时调用 texture registry 通知 Flutter。
4. 播放项切换或释放时注销 texture、观察者和 display link。
5. Flutter 继续处理 fit/stretch/crop、字幕覆盖和控制栏。

Phase 0 必须验证：窗口持续缩放、全屏、暂停/seek、音视频切换、Retina 比例、长时间播放和退出释放均无黑帧、花屏或明显内存增长。

### 9.3 系统媒体控制

- 使用 `MPNowPlayingInfoCenter` 发布标题、艺术家、封面、时长、进度和播放速率。
- 使用 `MPRemoteCommandCenter` 响应播放、暂停、切换、上一首、下一首和 position change。
- 原生收到命令后通过现有事件通知 Dart，`LumioAppState` 仍是业务状态真源。
- 窗口最小化、隐藏或切换到其他 App 后保持音频播放；用户退出 App 时停止并释放。

### 9.4 格式策略

首版以当前系统 AVFoundation 实际可播放结果为准，不仅依据扩展名宣布支持。Phase 0 建立样本矩阵：

| 类别 | 首轮重点验证 | 非首版承诺 |
|---|---|---|
| 音频 | MP3、AAC/M4A、WAV、FLAC | OGG 及异常封装 |
| 视频 | MP4、MOV/M4V，H.264/HEVC 常见编码 | MKV、AVI、WebM 和冷门编码 |

不支持时在媒体详情和播放入口展示明确原因。若产品确认 MKV/WebM/AVI/OGG 是 macOS 首发硬性要求，再启动 `media_kit/libmpv` 备选 spike，并在引入前完成许可证、二进制签名、App Sandbox、公证、体积和系统媒体控制评估。

## 10. 桌面 UI 与交互

### 10.1 响应式布局

建议按可用宽度而不是仅按 `Platform.isMacOS` 分支：

- `< 840 px`：保留现有底部导航，便于窄窗口和未来其他平台复用。
- `840～1199 px`：左侧 `NavigationRail`，右侧单内容区，Mini Player 固定在内容区底部。
- `>= 1200 px`：展开侧栏，可在音乐库/播放列表使用主从双栏。
- 设置页和详情页设置内容最大宽度，避免控件横向无限拉伸。
- Now Playing 在宽屏采用封面/视频与歌词/控制器双栏，窄屏回退现有单列。

### 10.2 菜单和快捷键

使用 Flutter `PlatformMenuBar`、`Shortcuts` 和 `Actions`，避免新增窗口插件依赖。建议首版：

| 操作 | 快捷键 |
|---|---|
| 添加媒体文件夹 | `⌘O` |
| 搜索 | `⌘F` |
| 播放/暂停 | `Space` |
| 上一首/下一首 | `⌘←` / `⌘→` |
| 快退/快进 | `←` / `→`，输入控件聚焦时不触发 |
| 静音 | `⌘⇧M` |
| 进入/退出窗口全屏 | 使用系统标准菜单和 `⌃⌘F` |

菜单至少包含“文件、播放、显示、窗口、帮助”。菜单操作和页面按钮必须调用同一 AppState action，不复制业务逻辑。

### 10.3 桌面行为

- 列表项增加 hover、右键菜单和多选键盘语义。
- 滚轮/触控板滚动不触发移动端下滑关闭手势。
- 视频全屏使用 macOS 窗口全屏，不设置设备方向。
- macOS 隐藏亮度手势和 PiP 按钮；音量使用播放器音量，不修改系统全局音量。
- 首版窗口建议初始尺寸 1180×760、最小尺寸 900×600；具体值在视觉验收后调整。
- 保留 Lumio 现有 Material 品牌，不引入 `macos_ui` 做整体重构。

## 11. 持久化与备份

### 11.1 分区持久化

保持现有 `session`、`library`、`playlists` 三分区协议，在 Swift 中写入 App Sandbox 的 Application Support：

```text
Application Support/Lumio/
├─ state/session.json
├─ state/library.json
├─ state/playlists.json
├─ media_sources.json            # bookmark 与来源状态，仅 macOS 本机
├─ scan_snapshot.json
├─ cache/artwork/
└─ backups/
```

要求：

- 使用串行队列或 actor 协调同一分区写入。
- 先写临时文件，再原子替换正式文件。
- 解析失败时隔离损坏文件并回退空分区，不覆盖其他正常分区。
- bookmark 文件不进入通用 backup。
- 封面二进制继续放文件缓存，不进入分区 JSON。

### 11.2 备份

- `createBackup` 首版先保持“创建最近备份”语义。
- 增加显式“导出备份”时使用 `NSSavePanel`；“导入备份”使用 `NSOpenPanel`。
- 导入前校验 schema 和平台字段，并显示将覆盖的范围。
- 恢复来源授权必须由用户重新选择，不从备份恢复 bookmark。

## 12. 工程与发布配置

### 12.1 工程骨架

环境验证后执行：

```bash
flutter create --platforms=macos .
```

生成前后必须检查 `.metadata`、`pubspec.yaml`、iOS/Android 配置和自定义 OHOS Flutter 生成差异，避免命令产生无关覆盖。

建议配置：

- Bundle ID：沿用 `com.hxg.lumio`。
- Product Name：`Lumio`，显示名：`忆光`。
- 最低系统版本：macOS 13。
- 开发阶段先验证 arm64；正式发布产出 universal `arm64 + x86_64`，并验证当前 OHOS Flutter SDK 的双架构产物。
- 使用现有品牌 master icon 生成完整 macOS AppIcon 集。

### 12.2 发布路径

- 从第一天保留 App Sandbox，不以关闭沙盒作为开发捷径。
- 首个正式版本采用 Developer ID 直接分发，启用 Hardened Runtime，完成签名和 Apple notarization。
- 首版不以 Mac App Store 上架为交付目标，但代码和权限继续保留 App Sandbox 兼容性，为后续商店发布预留空间。
- 安装包形式和自动更新机制不纳入当前方案，发布阶段另行评审；首版至少交付已签名、公证且可独立安装运行的产物。

Developer ID 首次发布前的人工配置：

1. 在 Apple Developer 账号创建或下载安装到钥匙串的 `Developer ID Application` 证书。
2. 在 Xcode Runner Target 的 Signing & Capabilities 选择对应 Team，保持 Bundle ID `com.hxg.lumio`、App Sandbox 和 Hardened Runtime。
3. 使用 Xcode Archive 导出 Developer ID App，或在 CI 中以显式证书身份对所有嵌套 Framework 和 App 自内向外签名。
4. 使用 `xcrun notarytool store-credentials` 将公证凭据保存为钥匙串 profile，不在仓库或脚本中保存密码/API 私钥。
5. 提交公证并等待成功，随后对 App 执行 stapling；最后用 `codesign --verify --deep --strict --verbose=2`、`spctl --assess --type execute --verbose=4` 验证。

当前仓库不写入 Team ID、证书名称和公证凭据，避免个人或组织签名资产被硬编码。未配置证书时，普通 `flutter build macos --release` 仍可用于本机工程验证，但其 ad-hoc 签名产物不能作为正式直分发包。

## 13. 预期影响文件

| 路径 | 计划改动 |
|---|---|
| `macos/` | 新增 Flutter Runner、配置、图标、entitlements 和 Swift 平台实现 |
| `lib/main.dart` | 响应式 Shell、菜单和快捷键入口 |
| `lib/app/app_state.dart` | 媒体来源 action、能力暴露、扫描取消/状态处理 |
| `lib/core/models/media_item.dart` | 可选来源/可用状态字段和向后兼容解析 |
| `lib/platform/platform_capabilities.dart` | 新增平台能力模型 |
| `lib/platform/app_storage/` | 将 macOS 纳入支持范围，保持分区协议 |
| `lib/platform/media_library/` | 来源模型、选择/移除来源、macOS 扫描和文件操作契约 |
| `lib/platform/playback/` | macOS payload、能力降级和事件兼容 |
| `lib/features/settings/settings_page.dart` | macOS 文件夹选择、来源列表、禁用能力说明 |
| `lib/features/music/now_playing_page.dart` | 双栏布局、桌面全屏、能力控制 |
| `lib/shared/widgets/` | 宽屏 Mini Player、hover/右键与内容宽度约束 |
| `pubspec.yaml` / `pubspec.lock` | 原则上不新增播放依赖；如 spike 引入插件则单独评审 |
| `docs/FEATURE_STATUS.md` | 实施后更新 macOS 功能矩阵，不在方案阶段提前标记完成 |

## 14. 分阶段实施计划

### Phase 0：工程与高风险 spike

目标：先证明定制 Flutter SDK、Xcode 26.6 和 Apple 播放链路可行，不进入大规模 UI 修改。

- 生成 `macos/` 工程，完成空壳 debug/release 构建。
- 验证 `path_provider_foundation`、CocoaPods 和当前 OHOS Flutter 分支兼容。
- 验证 `NSOpenPanel + security-scoped bookmark` 跨重启访问。
- 验证 AVPlayer 音频、视频、seek 和速度。
- 验证 `AVPlayerItemVideoOutput + FlutterTexture`。
- 建立格式样本矩阵并记录结果。
- 验证 arm64 release 和 universal 构建；若当前 SDK 无法产出双架构包，记录为正式发布阻塞项。

退出条件：构建、bookmark、核心音频和视频纹理四项全部通过。任何一项不通过，先调整技术选型，不继续堆业务功能。

### Phase 1：平台基础与媒体库

- 实现 macOS app storage 三分区和应用内最近备份。
- 实现来源选择、持久授权、来源管理和失效重授权。
- 实现异步扫描、增量快照、元数据、歌词/字幕、封面和视频首帧。
- 扩展 Repository 支持 macOS，完成空库、取消、权限失效和损坏文件提示。
- 更新设置页为系统文件夹选择流程。

退出条件：重启后可恢复授权和媒体索引，千级媒体扫描不阻塞 UI。

### Phase 2：播放主链路

- 实现 AVPlayer 播放控制、错误和完成事件。
- 实现视频 Texture 生命周期和窗口缩放。
- 接通队列、循环、随机、上下曲、续播、睡眠和 AB 循环。
- 接入系统媒体信息、媒体键和窗口后台播放。
- 实现系统分享；不支持能力通过 capabilities 明确关闭。

退出条件：音频/视频主链路稳定，原生和 Flutter 状态一致，长时间播放无明显资源泄漏。

### Phase 3：桌面体验与文件能力

- 实现 NavigationRail/侧栏、宽屏双栏、内容最大宽度。
- 实现菜单、快捷键、hover、右键菜单和键盘多选。
- 改造视频窗口全屏，移除桌面端移动方向/亮度交互。
- 在用户授权范围内实现重命名、移动及操作后重扫。
- 完善备份导入/导出和错误恢复。

退出条件：不同窗口宽度下无溢出，鼠标/键盘/触控板主流程完整。

### Phase 4：发布准备

- 完成格式、性能、离线、权限、异常媒体和回归矩阵。
- 验证 Release entitlements、Hardened Runtime、签名和 notarization。
- 验证 macOS 13 最低版本、universal 产物和 Developer ID 直接分发链路。
- 更新功能矩阵、安装说明和已知限制。

## 15. 验证与回归清单

### 15.1 自动检查

- `flutter analyze`
- `flutter test`
- `flutter build macos --debug`
- `flutter build macos --release`
- Android debug APK 构建回归。
- HarmonyOS HAP 构建回归；若环境耗时较高，可按现有项目发布门槛执行。

遵循项目约定：不为纯前端桌面布局新增 Widget 单元测试；对新增纯 Dart 数据转换、能力判断、路径校验和分区迁移补充针对性测试。

### 15.2 媒体库

- 首次授权、取消选择、多目录选择、移除来源。
- 退出并重启后重新解析 bookmark。
- 目录移动、重命名、离线磁盘、权限撤销和 bookmark stale。
- 空目录、损坏媒体、零字节文件、符号链接循环、超长路径和中文文件名。
- 1,000 个文件基础性能；再用 10,000 个文件观察峰值内存和增量扫描时间。
- 扫描过程中取消、关闭窗口和退出 App。

### 15.3 播放

- 各格式样本的打开、播放、seek、速度、暂停、完成和错误。
- 音频/视频连续切换、上一首/下一首、随机和三种循环模式。
- 视频尺寸、旋转信息、窗口缩放、全屏、Retina 和多显示器。
- 字幕、歌词、续播点、AB 循环和睡眠渐弱。
- 键盘媒体键、系统控制、最小化、隐藏和切换前台 App。
- 播放中文路径、外接磁盘文件和授权失效文件。
- 连续播放 2 小时观察 CPU、内存、句柄和温度。

### 15.4 UI 与发布

- 浅色/深色和四套主题色。
- 900×600 最小窗口、常规窗口、超宽窗口和全屏。
- 鼠标、触控板、键盘焦点和 VoiceOver 基础可用性。
- 完全断网启动；在线增强关闭时零请求。
- DebugProfile/Release entitlements 一致性。
- 签名产物在另一台未配置开发环境的 Mac 上启动验证。

## 16. 风险与缓解

| 风险 | 影响 | 缓解与决策门槛 |
|---|---|---|
| OHOS 定制 Flutter 与 Xcode 26.6/macOS 引擎不完全兼容 | 无法生成或发布 macOS 产物 | Phase 0 先做 debug/release 空壳；不直接切换官方 Flutter，避免破坏 OHOS |
| AVFoundation 格式覆盖不足 | MKV/WebM/AVI/OGG 无法播放 | 样本矩阵先验收；硬性要求不满足时再评审 media_kit/libmpv |
| security-scoped bookmark 失效 | 重启后媒体不可访问 | 保存来源状态、检测 stale、引导重新授权，不删除用户数据 |
| Texture 路径出现黑帧、色彩或资源泄漏 | 视频主链路不可用 | Phase 0 独立 spike；必要时评估 macOS PlatformView/AVPlayerLayer 备选 |
| 大媒体库一次性 MethodChannel 返回过大 | 扫描耗时和内存峰值过高 | 增量快照、封面文件缓存；超过基准时增加分页/事件流协议 |
| 移动端 UI 直接拉伸 | 桌面体验差 | 按宽度适配 Shell、Now Playing 和设置页，保留同一品牌体系 |
| 平台功能静默 no-op | 用户误以为 EQ/PiP 已生效 | 引入 PlatformCapabilities，隐藏或禁用并显示原因 |
| 跨平台备份含无效绝对路径 | 恢复后媒体全部失效 | 来源授权本机化；跨平台恢复过滤 library/current item |
| App Store 与直接分发权限不同 | 临近发布返工 | 从首版保留 Sandbox；两条发布路径共同需要的限制优先 |
| 当前磁盘余量偏紧 | archive、缓存或符号生成失败 | 开发前继续释放空间，定期清理无用 DerivedData 和旧构建产物 |

## 17. 兼容与回滚

- macOS 原生实现集中在新 `macos/` 目录，Android/HarmonyOS 原生代码不改语义。
- 新模型字段均为可选，旧 JSON 可读取；发现迁移问题时可回退使用现有 `path`。
- 新增通道方法对其他平台提供 unsupported 默认实现，避免强迫同步开发。
- 平台能力开关允许暂时关闭 macOS 单项能力，不阻塞浏览和基础播放。
- 若 AVPlayer 视频纹理方案失败，可在 Phase 0 回滚到 PlatformView 或第三方播放器评估，不影响媒体库和持久化成果。
- 不自动升级或替换当前 OHOS Flutter SDK；工具链调整必须单独评审并同时验证 APK/HAP。

## 18. 已确认决策

2026-08-03 确认按推荐方案实施：

1. 最低系统版本为 macOS 13。
2. 首个正式版本采用 Developer ID 直接分发；保留 App Sandbox 兼容性，后续再评估 Mac App Store。
3. 首版采用 AVPlayer 支持矩阵；MKV/WebM/AVI/OGG 不作为首发硬性承诺，格式 spike 不通过时再评审 `media_kit/libmpv`。
4. EQ、Crossfade、PiP、标签写回延后，优先完成基础播放、系统媒体控制和桌面体验。
5. 仅对用户主动选择的媒体目录申请读写权限；移动和重命名必须二次确认。
6. 开发阶段优先 arm64，正式发布产出 universal `arm64 + x86_64`。

若后续变更上述决策，需要同步更新本节、影响阶段和验证矩阵，不在实施中静默扩大范围。

## 19. 参考资料

- [Flutter：为现有项目增加桌面平台](https://docs.flutter.dev/platform-integration/desktop)
- [Flutter：构建 macOS App、Entitlements 与 App Sandbox](https://docs.flutter.dev/platform-integration/macos/building)
- [Apple：App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple：在 macOS App Sandbox 中访问文件](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple：Security-Scoped Bookmark 和 URL Access](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
- [Apple：MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)
- [Apple：AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput)
