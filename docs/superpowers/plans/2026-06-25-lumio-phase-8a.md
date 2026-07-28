# Lumio Phase 8a Local LRC Lyrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load same-folder local `.lrc` lyrics and synchronize Now Playing lyrics highlighting.

**Architecture:** Android MediaStore scan returns optional LRC file text for audio items when a same-name `.lrc` file exists next to the media file. Dart parses the LRC text into `LyricLine` values during platform media mapping and stores them in the existing app-local JSON state. Now Playing highlights the line whose timestamp matches the current playback position plus the persisted lyric offset.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MediaStore bridge, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 在线封面/歌词是非核心增强功能，默认可关闭；本阶段只做本地 `.lrc`，不接入网络。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- 保持最小改动，避免无关重构和格式噪音。

---

### Task 1: Dart LRC Parser

**Files:**
- Create: `lib/core/lyrics/lrc_parser.dart`
- Modify: `lib/platform/media_library/platform_media_library_repository.dart`

**Interfaces:**
- Produces: `parseLrc(String text) -> List<LyricLine>`
- Consumes: Android scan field `lyricsText`

- [x] **Step 1: Add parser for `[mm:ss.xx]` and repeated timestamp lines**
- [x] **Step 2: Sort parsed lines by timestamp and drop empty lyric lines**
- [x] **Step 3: Attach parsed lyrics to `MediaItem` during scan mapping**

### Task 2: Android LRC Discovery

**Files:**
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: `lyricsText` for audio scan rows when same-name `.lrc` exists.

- [x] **Step 1: Look for `.lrc` beside audio file path**
- [x] **Step 2: Read small UTF-8 LRC files defensively**
- [x] **Step 3: Include `lyricsText` in audio row map only when non-empty**

### Task 3: Synchronized Lyrics UI

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `lib/features/music/now_playing_page.dart`
- Modify: `lib/features/settings/settings_page.dart`

**Interfaces:**
- Produces: `LumioAppState.currentLyricIndex`
- Produces: `LumioAppState.adjustLyricOffset(Duration delta)`

- [x] **Step 1: Compute current lyric index from position plus offset**
- [x] **Step 2: Highlight current lyric line in Now Playing**
- [x] **Step 3: Add lyric offset controls in Settings**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
