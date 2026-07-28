# Lumio Phase 8d Local SRT Subtitles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load same-folder local `.srt` subtitles for videos and render the current subtitle line on the video stage.

**Architecture:** Android MediaStore scan returns optional SRT text for videos when a same-name `.srt` file exists next to the media file. Dart parses SRT blocks into subtitle cues stored in `MediaItem`, then Now Playing overlays the cue matching the current playback position.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin MediaStore bridge, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 本阶段只做本地 `.srt` 基础解析，不解析 `.ass` 样式，不接入在线字幕。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Dart SRT Parser and Model

**Files:**
- Modify: `lib/core/models/media_item.dart`
- Create: `lib/core/subtitles/srt_parser.dart`
- Modify: `lib/platform/media_library/platform_media_library_repository.dart`

**Interfaces:**
- Produces: `SubtitleCue(start, end, text)`
- Produces: `parseSrt(String text) -> List<SubtitleCue>`
- Consumes: Android scan field `subtitleText`

- [x] **Step 1: Add subtitle cue model and JSON persistence**
- [x] **Step 2: Parse SRT time ranges and multiline cue text**
- [x] **Step 3: Attach parsed subtitles to scanned video items**

### Task 2: Android SRT Discovery

**Files:**
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: `subtitleText` for video scan rows when same-name `.srt` exists.

- [x] **Step 1: Look for `.srt` beside video file path**
- [x] **Step 2: Read small UTF-8 subtitle files defensively**
- [x] **Step 3: Include `subtitleText` in video row map only when non-empty**

### Task 3: Video Subtitle Overlay

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Produces: `LumioAppState.currentSubtitleText`

- [x] **Step 1: Compute current subtitle cue from playback position**
- [x] **Step 2: Overlay current subtitle text on video stage**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
