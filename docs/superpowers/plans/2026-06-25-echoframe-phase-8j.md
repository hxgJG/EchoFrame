# EchoFrame Phase 8j Subtitle Style Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline subtitle style settings for local SRT rendering: font size, color, and vertical position.

**Architecture:** Persist subtitle style options in `EchoSettings` and expose AppState setters. The video stage and fullscreen video route read the current settings when rendering subtitle overlays. This keeps SRT parsing unchanged and avoids ASS style parsing or third-party dependencies.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 本阶段只做本地 SRT 字幕显示样式，不解析 `.ass` 样式。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Settings Model and App State

**Files:**
- Modify: `lib/core/models/echo_settings.dart`
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `SubtitleTextColor { white, yellow, cyan }`
- Produces: `SubtitlePosition { low, middle, high }`
- Produces: `EchoAppState.setSubtitleFontSize(double size)`
- Produces: `EchoAppState.setSubtitleTextColor(SubtitleTextColor color)`
- Produces: `EchoAppState.setSubtitlePosition(SubtitlePosition position)`

- [x] **Step 1: Add subtitle style enums and persisted settings fields**
- [x] **Step 2: Add AppState setters with clamped font size**

### Task 2: Settings UI

**Files:**
- Modify: `lib/features/settings/settings_page.dart`

**Interfaces:**
- Consumes: AppState subtitle style setters

- [x] **Step 1: Add subtitle style section controls**
- [x] **Step 2: Add font size slider, color selector, and position selector**

### Task 3: Video Subtitle Rendering

**Files:**
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Consumes: `EchoAppState.settings.subtitleFontSize`
- Consumes: `EchoAppState.settings.subtitleTextColor`
- Consumes: `EchoAppState.settings.subtitlePosition`

- [x] **Step 1: Apply configured subtitle color and font size**
- [x] **Step 2: Apply configured subtitle vertical position in embedded and fullscreen video**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
