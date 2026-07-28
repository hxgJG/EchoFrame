# 忆光 Lumio 技术方案

> 基于 `docs/Lumio_PRD_v0.5.md` v0.5 整理。本文作为产品需求到工程实现的主技术文档，后续阶段计划见 `docs/superpowers/plans/2026-06-25-lumio-mvp.md`。

## 1. 背景与目标

忆光 Lumio 是一款离线优先的本地音视频播放器。首期按 PRD 的 D7 决策集中做好 Android 端，iOS 与 HarmonyOS 延后；核心功能必须在完全无网络环境下可用，在线封面与歌词只作为可关闭的增强模块。

当前工程已完成 Flutter App 基础架构，并优先完成 Android 端本地媒体核心链路：媒体库浏览、MediaStore 异步扫描、分区轻量 KV 持久化、播放列表管理、Now Playing、Mini 播放器、基础设置和备份恢复。Android 音视频播放已升级到 `Media3 1.10.1`，ExoPlayer 与 MediaSession 由前台 `MediaSessionService` 持有，Activity 仅承载 Flutter 通道、视频 Texture、亮度和 PiP；播放列表提供可用格式的 Gapless，系统通知、锁屏、耳机/蓝牙媒体键和音频焦点由 Media3 统一处理。Android 还提供自动 PiP、续播、字幕、全屏手势、睡眠渐弱、Equalizer、真实 MediaStore 文件操作、封面/首帧懒加载和批量分享。在线增强默认关闭；开启后按需查询 LRCLIB、MusicBrainz 与 Cover Art Archive，并使用文件缓存而非数据库。HarmonyOS 已接入用户主动导入、AVMetadataExtractor、AVPlayer/Texture、应用状态持久化和应用内备份，并通过签名 HAP 构建；iOS 和 HarmonyOS 真机后台能力仍按后续阶段推进。

## 2. 技术选型

| 模块 | 方案 | 说明 |
|---|---|---|
| 跨端框架 | Flutter 3.35.8-ohos-1.0.1 / Dart 3.9.2 | 与 PRD 推荐一致，使用已配置的 OHOS 兼容 Flutter 分支，便于统一音频/视频视觉语言，并为 iOS/HarmonyOS 预留 |
| 状态管理 | `ChangeNotifier`（当前）/ Riverpod（后续可迁移） | 当前阶段保持依赖最少，播放和媒体库状态集中在 `LumioAppState` |
| 本地存储 | 分区轻量 KV + 文件快照 | Android 使用 MMKV 1.3.9，HarmonyOS 使用 Preferences；会话、媒体库、播放列表分区保存，备份使用 JSON 文件，不默认引入数据库 |
| 音视频播放 | Android Media3 1.10.1 ExoPlayer + MediaSessionService + Flutter Texture | Service 持有播放器和播放队列，统一后台、通知、锁屏、音频焦点和媒体键；Activity 保留 Texture、PiP、亮度与音量手势 |
| Android 媒体扫描 | MediaStore 平台通道 | 支持 Android 13+ 媒体权限、包含/排除文件夹、最短音频时长过滤、文件大小排序数据和快照恢复 |
| 在线增强 | 可插拔 Repository + 文件缓存 | 默认关闭且零请求；开启后 LRCLIB 获取歌词，MusicBrainz + Cover Art Archive 获取封面；串行频控、429 等待、失败静默降级 |

## 3. 架构分层

```text
lib/
├─ main.dart                      # App 入口、主题与 Shell
├─ app/
│  ├─ app_state.dart              # 当前阶段的轻量应用状态，接入平台扫描、存储与播放
│  ├─ seed_data.dart              # 空启动数据与历史演示数据清理 ID
│  └─ theme.dart                  # 品牌主题、浅深色配色
├─ core/
│  └─ models/                     # MediaItem、Playlist、Setting 等领域模型
├─ features/
│  ├─ music/                      # 音乐首页、列表、专辑/艺术家、播放列表、Now Playing
│  ├─ video/                      # 视频列表、文件夹入口与 Now Playing 跳转
│  ├─ search/                     # 全局本地搜索
│  └─ settings/                   # 主题、在线增强、扫描范围等设置入口
├─ platform/
│  ├─ app_storage/                # 本地状态、备份恢复抽象与 MethodChannel 实现
│  ├─ media_library/              # 媒体库扫描抽象与 MethodChannel 实现
│  ├─ online_enhancement/         # 在线歌词/封面、频控与文件缓存
│  └─ playback/                   # 音视频播放抽象与 MethodChannel 实现
└─ shared/
   └─ widgets/                    # 通用卡片、列表项、Mini 播放器、空状态
```

后续进入在线增强和更完整平台能力时新增：

```text
lib/platform/
├─ playback_background/
│  └─ android_media_session_service.dart
├─ platform_import/
│  ├─ ios_file_import_repository.dart
│  └─ ohos_platform_operation_repository.dart
└─ online_enhancement/
   ├─ artwork_lyrics_enhancer.dart
   ├─ disabled_enhancer.dart
   └─ remote_enhancer.dart
```

## 4. 当前状态与问题定义

当前仓库已经从 PRD 创建出 Flutter App，并按阶段接入 Android 媒体库异步扫描、分区持久化、扫描包含/排除文件夹、音乐/视频文件夹浏览、真实音视频播放、视频 Texture/自动 PiP、视频续播/自动连播、本地 `.srt` 字幕与样式设置、基础 `.ass/.ssa` 字幕解析、视频画面适应/拉伸/裁剪填充模式、视频全屏/横屏锁定/同步控制器/基础手势、备份恢复、本地 `.lrc` 歌词、睡眠定时器渐弱淡出、Android Equalizer 预设/自定义 EQ、文件大小排序、列表/网格切换、封面/首帧懒加载、批量媒体分享、队列/播放列表条目拖拽排序和媒体文件详情。HarmonyOS 已接入主动导入、基础音视频播放、Texture 与 Preferences 持久化。应用品牌已更新为「忆光 / Lumio」，Android/iOS/HarmonyOS 包名统一为 `com.hxg.lumio`；正式 Logo 与三端图标已落地，主题按 Logo 建立紫蓝青品牌色、音频金橙和视频青绿语义色。

当前阶段继续按 PRD 和阶段计划推进未完成能力，并保持 Android APK 与 HarmonyOS HAP 构建可验证。

当前仍未解决：MP3 自定义封面选择/写回、WAV/FLAC/M4A 等格式标签写回、iOS 导入、HarmonyOS 真机与后台能力验收、Material You 和复杂 `.ass` 字幕样式/特效还原。

成功标准：

- 仓库内有清晰技术方案和分阶段实施计划。
- App 可以通过 `flutter analyze` 做静态检查。
- App 首页、音乐列表、视频列表、Now Playing、独立搜索页、设置等核心导航可运行。
- 空媒体库、扫描入口和核心交互均离线可用；在线增强开关关闭时不影响任何界面。

## 5. 阶段规划

### Phase 1：Flutter MVP 骨架与离线核心界面

- 创建 Flutter Android/iOS/OHOS 兼容工程骨架。
- 建立应用主题、底部导航、音乐/视频模式切换、Mini 播放器。
- 默认不内置演示媒体，首页、音乐库、视频库、独立搜索页和设置页以空媒体库状态启动。
- 底部导航保留 首页/列表/歌单/视频/设置；搜索不占用底部标签，由首页、列表页、视频页顶部入口打开。
- 实现播放状态、收藏、播放次数、最近播放、随机播放、歌词视图切换等轻量状态。
- 设置页提供离线优先说明、主题模式切换、在线封面/歌词总开关、扫描过滤入口占位。

### Phase 2a：Android 媒体库扫描通道

- 通过 MethodChannel 接入 Android MediaStore 音频/视频扫描。
- 增加 Android 13+ `READ_MEDIA_AUDIO` / `READ_MEDIA_VIDEO` 与 Android 12 及以下 `READ_EXTERNAL_STORAGE` 权限。
- 设置页提供手动扫描入口，扫描结果写入本地媒体库。
- Android 以外平台返回明确 unsupported 状态，避免核心 UI 直接依赖 Android 类型。
- 空媒体库、权限拒绝、平台不支持均显示可理解状态，不影响离线 UI。

### Phase 2b：轻量持久化与扫描过滤

- 当前采用分区轻量 KV 持久化媒体索引、播放列表、播放状态和设置：Android MMKV、HarmonyOS Preferences。
- 会话、媒体库、播放列表分区独立更新；设置、队列等高频操作不会构造或写入完整媒体库。
- 视频续播点每 30 秒或退出/暂停时持久化，降低大媒体库下的序列化与写放大。
- 支持包含/排除文件夹、最短音频时长过滤、文件大小排序和手动刷新。
- 支持扫描快照和应用状态恢复；后续优先做文件变化增量比对，不以数据库迁移为默认方向。

### Phase 3：Android Media3 播放闭环

- 当前通过 Media3 1.10.1 ExoPlayer 接入本地音视频播放、暂停/恢复、seek、播放速度、完成回调和进度同步。
- 实现播放队列、循环/随机、进度条拖拽、睡眠定时器、AB 循环和 Mini 播放器/Now Playing 状态同步。
- ExoPlayer 与 MediaSession 已移入 MediaSessionService，由 Media3 管理前台通知、锁屏、音频焦点、耳机拔出和媒体键。
- Flutter 队列同步到 Media3 播放列表，可用格式支持 Gapless；Android Crossfade 默认关闭，开启后使用双 ExoPlayer 做 3 秒交叉淡入淡出，关闭或暂停时不运行轮询。
- 当前已实现本地 `.lrc` 匹配、解析、歌词偏移和同步高亮；在线歌词仍归入后续增强。

### Phase 4：Android 视频模式

- 当前通过 Android Media3 ExoPlayer + Flutter Texture 接入本地视频画面。
- 当前提供 Android 8–11 离开应用自动 PiP、Android 12+ 自动 PiP、PiP 控制动作和 Flutter 生命周期同步，并支持文件夹浏览、视频续播进度、自动连播、同目录同名 `.srt` 字幕覆盖与样式设置、同目录同名 `.ass/.ssa` 基础纯文本字幕解析、视频画面适应/拉伸/裁剪填充模式、全屏播放、横屏锁定、全屏同步控制器和基础手势调亮度/音量/进度。

### Phase 5：在线增强与高级离线能力

- 已实现可插拔在线封面/歌词增强模块，默认关闭；关闭时零网络请求。
- 已接入 LRCLIB、MusicBrainz 与 Cover Art Archive，增加串行请求、文件缓存、429 等待和失败静默降级。
- 当前已补齐 Android/HarmonyOS 应用内备份恢复、睡眠定时器和渐弱淡出、播放速度、AB 循环、Android 系统 Equalizer 预设/自定义五段 EQ、App 内索引元数据编辑、批量加入队列/播放列表、播放列表批量移除、队列/播放列表条目拖拽排序、媒体文件详情和 Android 单个/批量系统分享。
- Android 删除采用“仅从忆光媒体库隐藏”，源文件不变，隐藏 ID 进入轻量会话分区并可在设置中恢复；真实移动、重命名和 MP3 ID3 文本标签写回通过 MediaStore 系统写授权完成。
- WAV/FLAC/M4A 等标签格式按后续阶段逐步增加，不在首版一次引入重量级全格式实现。

### Phase 6：iOS 与 HarmonyOS

- iOS：文件选择器主动导入、沙盒索引、AVKit PiP。
- HarmonyOS：用户主动导入、元数据提取、音视频播放、Texture 和应用状态持久化 spike 已接入；下一步是真机、后台/锁屏验收，PiP 按 PRD D9 后续补。

## 6. 数据模型

首期 Dart 领域模型：

- `MediaKind`：`audio` / `video`
- `MediaItem`：媒体 ID、标题、艺术家、专辑、时长、路径、封面色、添加时间、播放次数、收藏状态、歌词行、视频分辨率；标题/艺术家/专辑支持 App 内索引编辑并随媒体库分区持久化。
- `Playlist`：播放列表 ID、名称、媒体 ID 列表。
- `PlaybackState`：当前媒体、播放中状态、进度、循环模式、随机状态、歌词/封面视图。
- `LumioSettings`：主题模式、允许在线增强、默认播放页视图、最短音频时长、动态取色开关。

持久化分区：

- `session`：设置、队列、当前媒体、排序/循环/随机模式、播放位置等小而高频的数据。
- `library`：音频和视频索引，低频整体更新。
- `playlists`：持久播放列表，与临时播放队列分离。
- `backup`：完整状态 JSON，仅由用户主动创建。

## 7. 权限与平台能力

Android MVP 后续需要：

- Android 13+：`READ_MEDIA_AUDIO`、`READ_MEDIA_VIDEO`。
- Android 12 及以下：`READ_EXTERNAL_STORAGE`，配合 Scoped Storage 兼容策略。
- 当前 Android 扫描实现读取 MediaStore 元数据，不发起网络请求，也不上传媒体文件。
- 当前 Android 音视频播放通过本地文件路径交给 Media3 ExoPlayer。
- 后台播放：MediaSessionService、前台媒体通知、锁屏控制和系统媒体键已接入。
- PiP：Manifest、手动入口、后台自动进入、生命周期同步和上曲/播放/下曲控制动作已接入。

iOS 不进入首期开发；HarmonyOS 已进入 spike。业务 UI 仍通过平台仓储调用，避免直接依赖 Android 或 ArkTS 类型。

### HarmonyOS HAP 构建与签名

- `flutter build hap --debug --no-codesign` 已验证可生成未签名 HAP，产物路径为 `ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`。这说明 OHOS 工程、Hvigor、SDK 与 Flutter 编译链路本身可用。
- DevEco Studio 自动签名已完成，`flutter build hap --debug` 可生成签名 HAP，产物路径为 `ohos/entry/build/default/outputs/default/entry-default-signed.hap`。
- 若迁移到新设备或更换 bundle/signing 配置，需要重新按 DevEco Studio 官方流程处理：打开 `ohos` 工程，进入 `File > Project Structure... > Project > Signing Configs`，勾选 `Support HarmonyOS` 与 `Automatically generate signature`，登录华为帐号，等待 DevEco 写回调试签名配置后再执行 `flutter build hap --debug`。
- DevEco 自动生成的 `.p7b/.p12/.cer` 与 profile 会绑定 bundleName 和调试设备 UDID，不能复用其他项目签名材料，也不应把个人证书或密码硬编码为团队默认配置。
- 未签名 HAP 只用于验证构建链路，不能作为真机调试/安装产物；真机调试必须使用 DevEco 生成的调试签名或正式发布签名。

## 8. 在线增强隔离

在线模块必须满足：

- 本地嵌入信息优先，命中本地不联网。
- 设置关闭时 Repository 直接返回，不创建任何网络请求。
- 网络失败不弹阻塞错误，不影响媒体浏览和播放。
- 只上传最小必要元数据查询，不上传用户媒体文件。
- 可整体裁剪或替换数据源。

## 9. 风险与回滚

| 风险 | 影响 | 缓解 |
|---|---|---|
| 当前 Flutter 为 OHOS 分支 | Android/iOS 插件生态可能与官方 stable 有差异 | Phase 1 避免第三方依赖，后续接插件前逐个验证 |
| Android MMKV 与 HarmonyOS Preferences 后端不同 | 两端实现细节可能漂移 | 统一 MethodChannel 分区协议，并用 Dart 回归测试固定分区边界 |
| MediaStore 权限差异 | Android 不同版本扫描行为不同 | 平台仓储隔离，权限失败给可操作空状态 |
| 视频 PiP 与播放器选型绑定 | 影响视频引擎替换成本 | 默认选择系统播放器路径，控制层自定义 |
| 在线歌词/封面接口或合规变化 | 接口失效或版权风险 | 模块独立、默认可关、文件缓存、正式发布前复核服务条款与客户端标识 |

## 10. 验证清单

- `flutter analyze` 无错误。
- `flutter test` 通过。
- Android debug APK 与签名 HarmonyOS debug HAP 构建通过。
- App 能在模拟器/设备运行并看到音乐首页。
- 切换音乐/视频/搜索/设置页面不崩溃。
- 点击歌曲后 Mini 播放器与 Now Playing 展示同一媒体。
- 在线增强开关关闭后，界面仍保持完整可用。
- 深色/浅色主题切换可用。
- 无网络环境下无需任何请求即可进入应用、查看空状态并发起本机媒体扫描。
