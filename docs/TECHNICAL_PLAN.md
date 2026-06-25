# EchoFrame 技术方案

> 基于 `docs/EchoFrame_PRD_v0.5.md` v0.5 整理。本文作为产品需求到工程实现的主技术文档，后续阶段计划见 `docs/superpowers/plans/2026-06-25-echoframe-mvp.md`。

## 1. 背景与目标

声影 EchoFrame 是一款离线优先的本地音视频播放器。首期按 PRD 的 D7 决策集中做好 Android 端，iOS 与 HarmonyOS 延后；核心功能必须在完全无网络环境下可用，在线封面与歌词只作为可关闭的增强模块。

当前工程已完成 Flutter App 基础架构，并优先完成 Android 端本地媒体核心链路：媒体库浏览、MediaStore 扫描、本地 JSON 持久化、播放列表管理、Now Playing、Mini 播放器、基础设置、备份恢复与在线增强开关。Android 音视频播放已通过平台通道接入原生 `MediaPlayer`，视频画面使用 Flutter Texture 承载，并提供 Android PiP 入口、续播进度、自动连播、本地 `.srt` 字幕覆盖与样式设置、基础 `.ass/.ssa` 字幕解析、视频画面适应/拉伸/裁剪填充模式、全屏播放、横屏锁定、全屏同步控制器和基础手势控制；Android 音频焦点、耳机拔出暂停、基础媒体键处理、通知栏媒体控制、本地 `.lrc` 歌词同步、睡眠定时器渐弱淡出、系统 Equalizer 预设和自定义五段 EQ 已接入。Android 扫描包含/排除文件夹、音乐/视频文件夹浏览、最短音频时长过滤、文件大小排序、App 内批量加入队列/播放列表、播放列表批量移除、队列拖拽排序、播放列表条目拖拽排序、媒体文件详情和 Android 系统分享已接入；前台服务/锁屏完整展示、iOS 导入和 HarmonyOS 原生媒体库桥接仍按后续阶段推进。

## 2. 技术选型

| 模块 | 方案 | 说明 |
|---|---|---|
| 跨端框架 | Flutter 3.35.8-ohos-1.0.1 / Dart 3.9.2 | 与 PRD 推荐一致，使用已配置的 OHOS 兼容 Flutter 分支，便于统一音频/视频视觉语言，并为 iOS/HarmonyOS 预留 |
| 状态管理 | `ChangeNotifier`（当前）/ Riverpod（后续可迁移） | 当前阶段保持依赖最少，播放和媒体库状态集中在 `EchoAppState` |
| 本地存储 | App-local JSON（当前）/ Drift（后续可迁移） | 当前存媒体索引、播放列表、设置、播放状态与备份；后续可迁移到 SQLite |
| 音频播放 | Android 原生 `MediaPlayer` MethodChannel（当前）/ `audio_service`（后续） | 当前负责本地文件播放、暂停、恢复、seek、音频焦点、耳机拔出暂停、媒体键、通知栏控制、歌词同步、Equalizer 预设/自定义 EQ 和进度同步；前台服务/锁屏完整展示后续接入 |
| 视频播放 | Android 原生 `MediaPlayer` + Flutter Texture（当前） | Android 视频画面、基础控制、PiP 入口、续播、自动连播、本地 `.srt` 字幕与样式、基础 `.ass/.ssa` 字幕、视频画面缩放模式、全屏、横屏锁定、全屏同步控制器和基础手势已接入 |
| Android 媒体扫描 | MediaStore 平台通道 | 支持 Android 13+ 媒体权限、包含/排除文件夹、最短音频时长过滤、文件大小排序数据和快照恢复 |
| 在线增强 | 独立 `ArtworkLyricsEnhancer` 接口 | 运行时由设置开关决定是否注入真实实现；关闭后核心模块不调用网络 |

## 3. 架构分层

```text
lib/
├─ main.dart                      # App 入口、主题与 Shell
├─ app/
│  ├─ app_state.dart              # 当前阶段的轻量应用状态，接入平台扫描、存储与播放
│  ├─ seed_data.dart              # 首次启动/非 Android 平台的离线演示数据
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
│  └─ ohos_media_library_repository.dart
└─ online_enhancement/
   ├─ artwork_lyrics_enhancer.dart
   ├─ disabled_enhancer.dart
   └─ remote_enhancer.dart
```

## 4. 当前状态与问题定义

当前仓库已经从 PRD 创建出 Flutter App，并按阶段接入 Android 媒体库扫描、本地持久化、扫描包含/排除文件夹、音乐/视频文件夹浏览、真实音视频播放、视频 Texture/PiP 入口、视频续播/自动连播、本地 `.srt` 字幕与样式设置、基础 `.ass/.ssa` 字幕解析、视频画面适应/拉伸/裁剪填充模式、视频全屏/横屏锁定/同步控制器/基础手势、备份恢复、本地 `.lrc` 歌词、睡眠定时器渐弱淡出、Android Equalizer 预设/自定义 EQ、文件大小排序、App 内批量媒体操作、队列/播放列表条目拖拽排序、媒体文件详情和 Android 系统分享。

当前阶段继续按 PRD 和阶段计划推进未完成能力，并保持 Android APK 与 HarmonyOS HAP 构建可验证。

当前仍未解决：前台服务/锁屏完整展示、iOS 导入、HarmonyOS 原生媒体库桥接、在线数据源接入、复杂 `.ass` 字幕样式/特效还原、真实文件标签写回和真实文件批量删除/移动/重命名操作。

成功标准：

- 仓库内有清晰技术方案和分阶段实施计划。
- App 可以通过 `flutter analyze` 做静态检查。
- App 首页、音乐列表、视频列表、Now Playing、搜索、设置等核心导航可运行。
- 所有当前演示数据和交互均离线可用；在线增强开关关闭时不影响任何界面。

## 5. 阶段规划

### Phase 1：Flutter MVP 骨架与离线核心界面

- 创建 Flutter Android/iOS/OHOS 兼容工程骨架。
- 建立应用主题、底部导航、音乐/视频模式切换、Mini 播放器。
- 使用离线 seed 数据实现 For You、Songs、Albums、Artists、Folders、Playlists、Now Playing、Videos、Search、Settings。
- 实现播放状态、收藏、播放次数、最近播放、随机播放、歌词视图切换等轻量状态。
- 设置页提供离线优先说明、主题模式切换、在线封面/歌词总开关、扫描过滤入口占位。

### Phase 2a：Android 媒体库扫描通道

- 通过 MethodChannel 接入 Android MediaStore 音频/视频扫描。
- 增加 Android 13+ `READ_MEDIA_AUDIO` / `READ_MEDIA_VIDEO` 与 Android 12 及以下 `READ_EXTERNAL_STORAGE` 权限。
- 设置页提供手动扫描入口，扫描结果替换 seed 媒体库。
- Android 以外平台返回明确 unsupported 状态，避免核心 UI 直接依赖 Android 类型。
- 空媒体库、权限拒绝、平台不支持均显示可理解状态，不影响离线 UI。

### Phase 2b：本地持久化与扫描过滤

- 当前采用 app-local JSON 持久化媒体索引、播放列表、播放状态和设置。
- 支持包含/排除文件夹、最短音频时长过滤、文件大小排序和手动刷新。
- 支持扫描快照和应用状态恢复，后续可迁移 Drift/SQLite 做增量比对。

### Phase 3：Android 音频播放闭环

- 当前通过 Android 原生 `MediaPlayer` 接入本地音频播放、暂停/恢复、seek、播放速度、完成回调和进度同步。
- 实现播放队列、循环/随机、进度条拖拽、睡眠定时器、AB 循环和 Mini 播放器/Now Playing 状态同步。
- 当前接入 Android 音频焦点、耳机拔出暂停、基础 MediaSession 媒体键和通知栏媒体控制。
- 后续接入前台服务和锁屏完整展示。
- 当前已实现本地 `.lrc` 匹配、解析、歌词偏移和同步高亮；在线歌词仍归入后续增强。

### Phase 4：Android 视频模式

- 当前通过 Android 原生 `MediaPlayer` + Flutter Texture 接入本地视频画面。
- 当前提供 Android PiP 入口、文件夹浏览、视频续播进度、自动连播、同目录同名 `.srt` 字幕覆盖与样式设置、同目录同名 `.ass/.ssa` 基础纯文本字幕解析、视频画面适应/拉伸/裁剪填充模式、全屏播放、横屏锁定、全屏同步控制器和基础手势调亮度/音量/进度。

### Phase 5：在线增强与高级离线能力

- 实现可插拔在线封面/歌词增强模块，默认可关闭。
- 增加请求频控、本地缓存、失败静默降级。
- 当前已补齐 Android app 专属目录 JSON 备份恢复、睡眠定时器和渐弱淡出、播放速度、AB 循环、Android 系统 Equalizer 预设/自定义五段 EQ、App 内索引元数据编辑、批量加入队列/播放列表、播放列表批量移除、队列/播放列表条目拖拽排序、媒体文件详情和 Android 系统分享。
- 后续补齐真实媒体文件标签写回、真实文件批量删除/移动/重命名。

### Phase 6：iOS 与 HarmonyOS

- iOS：文件选择器主动导入、沙盒索引、AVKit PiP。
- HarmonyOS：先做媒体库扫描、音频后台播放、视频播放桥接 spike；PiP 按 PRD D9 后续补。

## 6. 数据模型

首期 Dart 领域模型：

- `MediaKind`：`audio` / `video`
- `MediaItem`：媒体 ID、标题、艺术家、专辑、时长、路径、封面色、添加时间、播放次数、收藏状态、歌词行、视频分辨率；标题/艺术家/专辑支持 App 内索引编辑并随 JSON 状态持久化。
- `Playlist`：播放列表 ID、名称、媒体 ID 列表。
- `PlaybackState`：当前媒体、播放中状态、进度、循环模式、随机状态、歌词/封面视图。
- `EchoSettings`：主题模式、允许在线增强、默认播放页视图、最短音频时长、动态取色开关。

后续 Drift 表：

- `media_items`
- `playlists`
- `playlist_entries`
- `play_history`
- `settings`
- `artwork_lyrics_cache`
- `excluded_folders`

## 7. 权限与平台能力

Android MVP 后续需要：

- Android 13+：`READ_MEDIA_AUDIO`、`READ_MEDIA_VIDEO`。
- Android 12 及以下：`READ_EXTERNAL_STORAGE`，配合 Scoped Storage 兼容策略。
- 当前 Android 扫描实现读取 MediaStore 元数据，不发起网络请求，也不上传媒体文件。
- 当前 Android 音视频播放通过本地文件路径交给原生 `MediaPlayer`。
- 后台播放：基础媒体会话和通知栏媒体控制已接入；前台服务和锁屏完整展示后续补齐。
- PiP：Manifest 声明和手动进入 PiP 入口已接入；后台自动进入、生命周期同步和 PiP 控制按钮后续补齐。

iOS/HarmonyOS 不进入首期开发，但接口从一开始保持平台可替换，避免业务 UI 直接调用 Android 类型。

### HarmonyOS HAP 构建与签名

- `flutter build hap --debug --no-codesign` 已验证可生成未签名 HAP，产物路径为 `ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`。这说明 OHOS 工程、Hvigor、SDK 与 Flutter 编译链路本身可用。
- DevEco Studio 自动签名已完成，`flutter build hap --debug` 可生成签名 HAP，产物路径为 `ohos/entry/build/default/outputs/default/entry-default-signed.hap`。
- 若迁移到新设备或更换 bundle/signing 配置，需要重新按 DevEco Studio 官方流程处理：打开 `ohos` 工程，进入 `File > Project Structure... > Project > Signing Configs`，勾选 `Support HarmonyOS` 与 `Automatically generate signature`，登录华为帐号，等待 DevEco 写回调试签名配置后再执行 `flutter build hap --debug`。
- DevEco 自动生成的 `.p7b/.p12/.cer` 与 profile 会绑定 bundleName 和调试设备 UDID，不能复用其他项目签名材料，也不应把个人证书或密码硬编码为团队默认配置。
- 未签名 HAP 只用于验证构建链路，不能作为真机调试/安装产物；真机调试必须使用 DevEco 生成的调试签名或正式发布签名。

## 8. 在线增强隔离

在线模块必须满足：

- 本地嵌入信息优先，命中本地不联网。
- 设置关闭时不实例化真实网络实现。
- 网络失败不弹阻塞错误，不影响媒体浏览和播放。
- 只上传最小必要元数据查询，不上传用户媒体文件。
- 可整体裁剪或替换数据源。

## 9. 风险与回滚

| 风险 | 影响 | 缓解 |
|---|---|---|
| 当前 Flutter 为 OHOS 分支 | Android/iOS 插件生态可能与官方 stable 有差异 | Phase 1 避免第三方依赖，后续接插件前逐个验证 |
| MediaStore 权限差异 | Android 不同版本扫描行为不同 | 平台仓储隔离，权限失败给可操作空状态 |
| 视频 PiP 与播放器选型绑定 | 影响视频引擎替换成本 | 默认选择系统播放器路径，控制层自定义 |
| 在线歌词/封面合规不确定 | 接口失效或版权风险 | 模块独立、默认可关、数据源延后确认 |

## 10. 验证清单

- `flutter analyze` 无错误。
- App 能在模拟器/设备运行并看到音乐首页。
- 切换音乐/视频/搜索/设置页面不崩溃。
- 点击歌曲后 Mini 播放器与 Now Playing 展示同一媒体。
- 在线增强开关关闭后，界面仍保持完整可用。
- 深色/浅色主题切换可用。
- 无网络环境下无需任何请求即可浏览演示媒体。
