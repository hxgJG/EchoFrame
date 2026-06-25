# EchoFrame MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first runnable Flutter MVP for EchoFrame with offline-first music/video navigation, local demo media state, settings, and a documented path to real Android scanning/playback.

**Architecture:** Start with a dependency-light Flutter app so the current OHOS Flutter SDK can analyze and run it without package downloads. Keep domain models and state separate from UI so Phase 2 can replace seed data with Drift + MediaStore and Phase 3 can replace simulated playback with `just_audio` + `audio_service`.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Material widgets, no third-party package in Phase 1.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 首期集中力量做好 Android 端，iOS 与 HarmonyOS 均可延后。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 在线封面/歌词是非核心增强功能，默认可关闭，关闭后核心模块不可调用网络实现。
- 前端首期不新增单元测试，除非用户明确要求。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Project Scaffold and Documentation

**Files:**
- Create: `pubspec.yaml`
- Create: `analysis_options.yaml`
- Create: `lib/main.dart`
- Create: `docs/TECHNICAL_PLAN.md`
- Create: `docs/superpowers/plans/2026-06-25-echoframe-mvp.md`

**Interfaces:**
- Produces: a Flutter app named `echoframe` with entrypoint `main()` and a technical plan.
- Consumes: `docs/EchoFrame_PRD_v0.5.md`.

- [x] **Step 1: Generate Flutter scaffold**

```bash
flutter create --project-name echoframe --org com.hxg.echoframe --platforms=android,ios,ohos --no-pub .
```

Expected: `pubspec.yaml`, `lib/main.dart`, platform folders, and analysis options exist.

- [x] **Step 2: Add technical plan**

Write `docs/TECHNICAL_PLAN.md` with architecture, phases, data model, platform strategy, online-enhancement isolation, and verification checklist.

- [x] **Step 3: Run dependency resolution**

```bash
flutter pub get --offline
```

Expected: succeeds using cached SDK dependencies because Phase 1 has no new third-party packages.

### Task 2: Domain Models and Offline State

**Files:**
- Create: `lib/core/models/media_item.dart`
- Create: `lib/core/models/playlist.dart`
- Create: `lib/core/models/echo_settings.dart`
- Create: `lib/app/seed_data.dart`
- Create: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `EchoAppState extends ChangeNotifier`
- Produces: `List<MediaItem> audioItems`, `List<MediaItem> videoItems`, `List<Playlist> playlists`
- Produces: actions `play(MediaItem item)`, `togglePlaying()`, `shuffleAll(MediaKind kind)`, `toggleFavorite(String mediaId)`, `toggleOnlineEnhancement(bool value)`, `setThemeMode(ThemeMode mode)`.

- [x] **Step 1: Define media model**

Implement `MediaKind`, `PlaybackView`, and immutable `MediaItem` with `copyWith`.

- [x] **Step 2: Define playlist and settings models**

Implement immutable `Playlist` and `EchoSettings` with `copyWith`.

- [x] **Step 3: Seed offline demo data**

Create local-only audio/video media with durations, artists, albums, lyric lines, folder paths, and video resolution.

- [x] **Step 4: Implement app state**

Use `ChangeNotifier` to track current item, playing flag, selected tab, selected playback view, favorites, settings, and derived filtered lists.

- [x] **Step 5: Verify syntax**

```bash
dart format lib/app lib/core
flutter analyze
```

Expected: no analyzer errors from model/state files.

### Task 3: Theme, Shell, and Shared Widgets

**Files:**
- Create: `lib/app/theme.dart`
- Modify: `lib/main.dart`
- Create: `lib/shared/widgets/media_tile.dart`
- Create: `lib/shared/widgets/section_header.dart`
- Create: `lib/shared/widgets/mini_player.dart`
- Create: `lib/shared/widgets/metric_card.dart`

**Interfaces:**
- Consumes: `EchoAppState`
- Produces: `EchoFrameApp`, `EchoFrameShell`, `EchoTheme.light`, `EchoTheme.dark`
- Produces shared widgets reusable by music/video/search/settings.

- [x] **Step 1: Build theme**

Create a restrained Retro Music inspired theme: brand blue, ink black, mist backgrounds, warm coral accent, rounded media thumbnails, accessible contrast.

- [x] **Step 2: Build app shell**

Wire `MaterialApp`, `AnimatedBuilder` for `EchoAppState`, bottom navigation, and persistent Mini Player above navigation.

- [x] **Step 3: Build shared widgets**

Create reusable media rows, section headers, mini player, and compact metric cards.

- [x] **Step 4: Verify layout compiles**

```bash
flutter analyze
```

Expected: no analyzer errors.

### Task 4: Music Experience

**Files:**
- Create: `lib/features/music/music_home_page.dart`
- Create: `lib/features/music/music_library_page.dart`
- Create: `lib/features/music/playlists_page.dart`
- Create: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Consumes: `EchoAppState`, `MediaItem`, `Playlist`
- Produces: For You, Songs/Albums/Artists tabs, playlist management surface, Now Playing with cover/lyrics views.

- [x] **Step 1: Implement For You**

Build welcome area, four quick action cards, suggestions, recent artists, and a recently added list using offline data.

- [x] **Step 2: Implement library tabs**

Build Songs list, Albums grid, Artists grid, sorting controls, and shuffle FAB behavior.

- [x] **Step 3: Implement playlists surface**

Show playlists, queue distinction, and list contents from seed data.

- [x] **Step 4: Implement Now Playing**

Build cover/lyrics toggle, progress presentation, title/artist, controls, favorite, queue button, and collapse behavior.

- [x] **Step 5: Verify interactions compile**

```bash
flutter analyze
```

Expected: no analyzer errors.

### Task 5: Video, Search, and Settings

**Files:**
- Create: `lib/features/video/video_page.dart`
- Create: `lib/features/search/search_page.dart`
- Create: `lib/features/settings/settings_page.dart`

**Interfaces:**
- Consumes: `EchoAppState`
- Produces: video list/player placeholder, global local search, settings with offline-first controls.

- [x] **Step 1: Implement video page**

Build Videos and Folders tabs, video rows with duration/resolution, and a player-style detail surface with PiP marked as Android Phase 4.

- [x] **Step 2: Implement search page**

Search across audio and video titles, artists, albums, and folders using local data only.

- [x] **Step 3: Implement settings page**

Add theme mode control, online artwork/lyrics toggle, scan filters preview, backup/restore placeholder, and about information.

- [x] **Step 4: Verify**

```bash
dart format lib
flutter analyze
```

Expected: no analyzer errors.

### Task 6: Final Validation

**Files:**
- Modify only files touched by previous tasks if validation finds issues.

**Interfaces:**
- Produces: a runnable Phase 1 app and clear next-phase scope.

- [x] **Step 1: Run static analysis**

```bash
flutter analyze
```

Expected: `No issues found!`

- [x] **Step 2: Inspect generated files**

```bash
find lib -type f | sort
```

Expected: feature, app, core, and shared files are present.

- [x] **Step 3: Record follow-up scope**

Update final response with completed Phase 1 scope and remaining Phase 2+ tasks.

### Task 7: Android MediaStore Scan Bridge

**Files:**
- Create: `lib/platform/media_library/media_library_repository.dart`
- Create: `lib/platform/media_library/platform_media_library_repository.dart`
- Modify: `lib/app/app_state.dart`
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/features/music/music_home_page.dart`
- Modify: `lib/features/music/music_library_page.dart`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/src/main/kotlin/com/hxg/echoframe/echoframe/MainActivity.kt`

**Interfaces:**
- Produces: `MediaLibraryRepository.scan()`
- Produces: `MediaLibraryScanResult` with `completed`, `permissionDenied`, `unsupported`, and `failed` statuses.
- Produces: Android MethodChannel `echoframe/media_library` method `scan`.
- Produces: Android MethodChannel `echoframe/media_library` method `restoreLastScan`.

- [x] **Step 1: Add Dart scan abstraction**

Create a repository interface and platform MethodChannel implementation that maps Android media rows into existing `MediaItem` models.

- [x] **Step 2: Add Android MediaStore bridge**

Add media read permissions, runtime permission request, and MediaStore audio/video queries in `MainActivity.kt`.

- [x] **Step 3: Wire settings scan action**

Add a settings row that triggers `EchoAppState.scanMediaLibrary()`, shows scanning state, and replaces seed data with scan results.

- [x] **Step 4: Harden empty media states**

Ensure home and music library screens do not assume scanned devices always contain audio files.

- [x] **Step 5: Add lightweight scan snapshot restore**

Persist the latest Android scan metadata to app-local JSON and restore it on next launch before the user manually rescans. This stores metadata only, not media file contents.

- [x] **Step 6: Verify**

```bash
dart format lib
flutter analyze
flutter build apk --debug
flutter build hap --debug
```

Expected: Dart analysis passes. Android/HAP builds may require local SDK signing/toolchain configuration; record exact blocker if present.

### Task 8: HarmonyOS HAP Build Signing

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify: `docs/superpowers/plans/2026-06-25-echoframe-mvp.md`
- DevEco may modify: `ohos/build-profile.json5`

**Interfaces:**
- Produces: a verified unsigned HAP build for toolchain validation.
- Produces: official DevEco signing path for signed debug HAP.

- [x] **Step 1: Reproduce signed HAP blocker**

```bash
flutter build hap --debug
```

Observed: Flutter stops before Hvigor signing with `请通过DevEco Studio打开ohos工程后配置调试签名(File -> Project Structure -> Signing Configs 勾选Automatically generate signature)`.

- [x] **Step 2: Validate non-signing OHOS build chain**

```bash
flutter build hap --debug --no-codesign
```

Observed: succeeds and generates `ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`.

- [x] **Step 3: Record official signing path**

Document that DevEco Studio must generate project-specific debug signing material because the profile binds bundleName and device UDID.

- [x] **Step 4: Generate debug signing in DevEco Studio**

Open `ohos` in DevEco Studio, then `File > Project Structure... > Project > Signing Configs`; select `Support HarmonyOS` and `Automatically generate signature`, sign in with HUAWEI ID, wait for DevEco to write signing config, then click `OK`.

- [x] **Step 5: Verify signed debug HAP**

```bash
flutter build hap --debug
```

Observed: succeeds and emits `ohos/entry/build/default/outputs/default/entry-default-signed.hap`.
