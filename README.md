# 忆光 Lumio

离线优先的本地音视频播放器，Flutter 实现，无账号体系。核心播放、媒体库浏览和歌单管理在完全断网时可用；在线封面/歌词增强默认关闭，关闭时不发起任何网络请求。

> 仓库目录名沿用历史项目名 `EchoFrame`，产品名为「忆光 / Lumio」。Dart 包名 `lumio`，应用 ID `com.hxg.lumio`。安装包发布在独立仓库 [hxgJG/Lumio-Releases](https://github.com/hxgJG/Lumio-Releases)，本仓库只保留源码与文档。

## 平台状态

| 平台 | 状态 | 当前能力 | 主要缺口 |
|---|---|---|---|
| Android | ✅ 主发布平台 | MediaStore 扫描、Media3 1.10.1 后台服务播放、PiP、均衡器、Crossfade、MP3 标签写回、批量分享、应用内更新 | 增量扫描、真机格式矩阵回归 |
| macOS | 🟡 可用 | AVPlayer + FlutterTexture、沙盒书签授权、字幕工作台（编辑/校准/烧录导出）、桌面歌词、WebDAV 备份、Sparkle 应用内更新 | 临时签名未公证、桌面右键/多选、真实媒体矩阵验收 |
| HarmonyOS | ⏸ 暂停 | 主动导入、AVPlayer/Texture 播放、Preferences 分区持久化、签名 HAP | 暂停原因：开发机缺少 DevEco Studio / HarmonyOS SDK，改动无法编译验证；恢复前需先补齐工具链 |
| iOS | 🟡 可用 | 文档选择器主动导入、AVAsset 扫描、内嵌封面/首帧、AVPlayer + FlutterTexture 播放、分区状态持久化 | 后台与锁屏媒体控制、PiP、文件操作、真机回归 |

功能状态的完整矩阵、决策记录和遗留问题见 [docs/FEATURE_STATUS.md](docs/FEATURE_STATUS.md)。

## 功能概览

- **媒体库**：本地扫描/导入、文件夹包含与排除、最短时长过滤、五种排序、列表/网格切换、隐藏与恢复（不删除源文件）。
- **播放**：队列、播放模式（顺序/列表循环/单曲循环/随机加权）、Gapless/Crossfade、倍速、AB 循环、睡眠定时器渐弱、均衡器、续播、PiP、系统媒体控制。
- **歌词**：同名 LRC 解析、偏移校准、逐句打轴、歌词库与歌词包、导出、macOS 桌面歌词与频谱。
- **字幕**：同名 SRT / ASS 覆盖；macOS 工作台支持导入、编辑、整体校准、预览与烧录导出 MP4。
- **数据**：分区持久化（会话/媒体库/歌单）；Android 与 macOS 支持 v2 跨端备份 ZIP 与 WebDAV 云端备份恢复。
- **设备互传**：局域网 NSD 发现、固定安全码 + Ed25519 身份、TLS 传输、接收入库（仅 Android 与 macOS）。
- **在线增强**：LRCLIB 歌词、MusicBrainz + Cover Art Archive 封面，串行频控与文件缓存，失败静默降级。
- **更新**：Ed25519 签名清单、断点续传、Android 覆盖安装、macOS Sparkle 安装与重启。

## 技术栈

| 层 | 方案 |
|---|---|
| 跨端 | Flutter 3.35.8-ohos-1.0.1（OHOS 兼容分支）/ Dart 3.9.2 |
| 状态 | `ChangeNotifier`，`LumioAppState` 为业务状态唯一真源 |
| 持久化 | 分区 JSON + 轻量 KV：Android MMKV 1.3.9、HarmonyOS Preferences、macOS 应用支持目录；不引入数据库 |
| Android 播放 | Media3 1.10.1 ExoPlayer + `MediaSessionService` + Flutter Texture |
| macOS 播放 | AVFoundation / AVPlayer + `FlutterTexture` |
| 加密与网络 | Ed25519（`cryptography`）、TLS、`http`、`nsd` |

## 目录结构

```text
lib/
├─ main.dart        应用入口、Shell、快捷键、平台菜单
├─ app/             应用状态（app_state + 备份/歌词库/互传扩展）、主题
├─ core/            领域模型、歌词、字幕、备份格式、互传协议、更新清单
├─ platform/        平台仓储抽象与 MethodChannel 实现、平台能力模型
├─ features/        页面：音乐、视频、搜索、设置、互传、字幕工作台
└─ shared/widgets/  通用组件

android/  Kotlin：MediaStore 扫描、Media3 播放服务、互传/备份/更新插件
macos/    Swift：媒体库、播放、字幕工作台、桌面歌词、Sparkle 更新
ohos/     ArkTS：导入、播放、持久化
ios/      Swift：应用状态存储、媒体导入与扫描、AVPlayer 播放

test/     单元与集成测试；tool/ 发版与诊断脚本；docs/ 设计与状态文档
```

## 本地开发

要求：Flutter（OHOS 分支，见上表）、Android SDK 与 JDK 17（Android）、Xcode 26 + CocoaPods（macOS）。鸿蒙构建另需 DevEco / HarmonyOS SDK。

```bash
flutter pub get
flutter run -d <device-id>
```

**已知环境问题**：在当前 OHOS 分支 Flutter 上，未设置 `HOS_SDK_HOME` 时 `flutter pub get` 会在依赖解析完成后以退出码 1 结束，并输出 `No Hmos SDK found`。这不影响已解析的依赖；设置 `HOS_SDK_HOME` 后即可消除，或对后续命令统一追加 `--no-pub`。

### Android Release 签名

Release 构建必须使用仓库外的正式签名，缺配置会直接构建失败（不允许回退 debug 签名）：

```properties
# ~/.lumio-release/android-signing.properties
storeFile=/绝对路径/android-release.p12
storePassword=...
keyPassword=...
keyAlias=lumio
```

可通过 `LUMIO_RELEASE_CONFIG` 指向其他路径。更新清单的私钥与 Android 签名密钥相互独立，均由 `tool/release_keys.dart` 一次性生成到 `~/.lumio-release`，不得提交到仓库。

## 校验与测试

```bash
dart run tool/check.dart          # 格式 + 静态分析 + 单元测试
dart run tool/check.dart --build  # 再追加 Android / macOS debug 构建
```

等价的单条命令：

```bash
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze --no-pub
flutter test --no-pub
cd android && ./gradlew testDebugUnitTest   # Kotlin 单测
```

CI 定义在 [.github/workflows/ci.yml](.github/workflows/ci.yml)：格式检查、静态分析、Dart 单元测试、Android debug 构建与 Kotlin 单测。HarmonyOS HAP 与 macOS 构建不在 CI 内（分别需要 HarmonyOS SDK 与 macOS runner），由发版前的本地构建覆盖。

## 构建与发布

1. 更新 `pubspec.yaml` 的 `version: x.y.z+n`，并在 `tool/release_notes/x.y.z.md` 写更新说明。
2. 提交源码，保证工作区干净（正式发布脚本会校验）。
3. 生成发布附件（脚本会重新构建 apk 与 macos，校验签名、写入 SHA-256 与 Sparkle 签名）：

   ```bash
   dart run tool/prepare_release.dart tool/release_notes/x.y.z.md
   ```

   仅本地验收可用 `--local-preview`（不重新构建，也不能上传）。

4. 上传草稿 → 校验 → 公开发布：

   ```bash
   dart run tool/publish_release.dart draft   build/releases/vx.y.z-n
   dart run tool/publish_release.dart verify  build/releases/vx.y.z-n
   dart run tool/publish_release.dart publish build/releases/vx.y.z-n
   ```

产物位于 `build/releases/v<版本>-<构建号>/`：Android universal APK、macOS universal ZIP、`update-manifest.json` 与 `.sig`、`RELEASE_NOTES.md`、`INSTALL.md`。

`prepare_release.dart` 需要通过 `ANDROID_SDK_ROOT` 或 `ANDROID_HOME` 找到 build-tools 来校验 APK 签名，`publish_release.dart` 需要已登录的 `gh` CLI。二者都会校验源码提交与工作区状态，失败即中止，不会覆盖已有发布附件。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/Lumio_PRD_v0.5.md](docs/Lumio_PRD_v0.5.md) | 需求基线 |
| [docs/TECHNICAL_PLAN.md](docs/TECHNICAL_PLAN.md) | 总体技术方案与阶段规划 |
| [docs/FEATURE_STATUS.md](docs/FEATURE_STATUS.md) | 功能状态矩阵、决策与遗留问题 |
| [docs/MACOS_TECHNICAL_PLAN.md](docs/MACOS_TECHNICAL_PLAN.md) | macOS 端方案与验收口径 |
| [docs/CROSS_PLATFORM_BACKUP.md](docs/CROSS_PLATFORM_BACKUP.md) | 备份格式、恢复匹配与 WebDAV |
| [docs/DEVICE_TRANSFER_SAFETY_CODE_PLAN.md](docs/DEVICE_TRANSFER_SAFETY_CODE_PLAN.md) | 设备互传与固定安全码 |
| [docs/APP_UPDATE_PLAN.md](docs/APP_UPDATE_PLAN.md) | 发布、检查更新与安装边界 |
| [docs/SUBTITLE_WORKBENCH_GUIDE.md](docs/SUBTITLE_WORKBENCH_GUIDE.md) | macOS 字幕工作台 |
| [docs/IOS_SMOKE_TEST.md](docs/IOS_SMOKE_TEST.md) | iOS 冒烟清单与已知未实现项 |
| [docs/BRAND_GUIDE.md](docs/BRAND_GUIDE.md) / [docs/THEMING.md](docs/THEMING.md) | 品牌与主题 |

## 开发约定

见 [AGENTS.md](AGENTS.md)：本项目不使用 `test-driven-development` skill，前端改动默认不新增单元测试，以静态检查、现有测试、构建和真机验证为准。
