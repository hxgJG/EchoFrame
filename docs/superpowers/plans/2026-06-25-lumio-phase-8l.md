# Lumio Phase 8l Video Scale Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline video scale modes for fit, stretch, and crop-fill playback.

**Architecture:** Persist the selected video scale mode in `LumioSettings`, expose an AppState setter, and render the existing Flutter Texture through one reusable widget that applies the selected `BoxFit`. Embedded and fullscreen video reuse the same behavior.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, app-local JSON persistence, no new third-party package.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- 核心播放、媒体库浏览、播放列表管理必须离线可用。
- 不新增第三方依赖，避免影响当前 OHOS Flutter SDK 构建链路。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。

---

### Task 1: Settings Model and App State

**Files:**
- Modify: `lib/core/models/lumio_settings.dart`
- Modify: `lib/app/app_state.dart`

**Interfaces:**
- Produces: `VideoScaleMode { fit, stretch, crop }`
- Produces: `LumioAppState.setVideoScaleMode(VideoScaleMode mode)`

- [x] **Step 1: Add video scale enum and persisted setting**
- [x] **Step 2: Add AppState setter with no-op guard**

### Task 2: Settings UI

**Files:**
- Modify: `lib/features/settings/settings_page.dart`

**Interfaces:**
- Consumes: `LumioAppState.setVideoScaleMode`

- [x] **Step 1: Add video scale mode segmented control under Now Playing**
- [x] **Step 2: Add Chinese labels for fit, stretch, and crop-fill**

### Task 3: Video Rendering

**Files:**
- Modify: `lib/features/music/now_playing_page.dart`

**Interfaces:**
- Consumes: `LumioSettings.videoScaleMode`

- [x] **Step 1: Add reusable texture stage widget that maps scale mode to BoxFit**
- [x] **Step 2: Apply it to embedded video playback**
- [x] **Step 3: Apply it to fullscreen video playback**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**
