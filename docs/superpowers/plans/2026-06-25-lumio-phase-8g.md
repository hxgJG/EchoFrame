# Lumio Phase 8g Equalizer Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline audio equalizer presets that persist in settings and apply to Android playback.

**Architecture:** Store a preset enum in `LumioSettings` and expose an `LumioAppState.setEqualizerPreset` facade. Dart sends the selected preset name through the existing playback MethodChannel. Android attaches a system `Equalizer` to the active `MediaPlayer` audio session and maps presets to simple per-band gains; unsupported/non-Android platforms no-op.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Kotlin `android.media.audiofx.Equalizer`, app-local JSON persistence, no new third-party package.

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
- Produces: `EqualizerPreset { off, bassBoost, vocal, rock, classical }`
- Produces: `LumioAppState.setEqualizerPreset(EqualizerPreset preset)`

- [x] **Step 1: Add equalizer preset enum with persisted JSON field `equalizerPreset`**
- [x] **Step 2: Add AppState setter that persists and applies the preset**
- [x] **Step 3: Apply restored preset after loading persisted state**

### Task 2: Playback Platform Bridge

**Files:**
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

**Interfaces:**
- Produces: `PlaybackRepository.setEqualizerPreset(String presetName)`
- Consumes: MethodChannel method `setEqualizerPreset`

- [x] **Step 1: Add Dart playback repository method**
- [x] **Step 2: Implement Android Equalizer lifecycle and preset application**
- [x] **Step 3: Reapply current preset when a new MediaPlayer starts**

### Task 3: Settings UI

**Files:**
- Modify: `lib/features/settings/settings_page.dart`

**Interfaces:**
- Consumes: `LumioAppState.setEqualizerPreset`

- [x] **Step 1: Add equalizer preset segmented control in Audio settings**
- [x] **Step 2: Show the current preset label**

### Task 4: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update technical plan current-state notes**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [x] **Step 5: Run `flutter build hap --debug`**

---

## Phase 8k Extension: Custom Five-Band EQ

**Goal:** Extend the equalizer from presets to a persisted custom five-band EQ.

**Architecture:** Reuse the existing Equalizer bridge and add a `custom` preset plus five gain values in settings. Android receives both preset name and custom gain list, then maps the five configured values to the device's actual Equalizer band count.

### Task 5: Custom EQ Model and Bridge

**Files:**
- Modify: `lib/core/models/lumio_settings.dart`
- Modify: `lib/app/app_state.dart`
- Modify: `lib/platform/playback/playback_repository.dart`
- Modify: `lib/platform/playback/platform_playback_repository.dart`
- Modify: `android/app/src/main/kotlin/com/hxg/lumio/lumio/MainActivity.kt`

- [x] **Step 1: Add `EqualizerPreset.custom` and persisted `customEqualizerGains`**
- [x] **Step 2: Send custom gain list through the playback bridge**
- [x] **Step 3: Apply custom gains on Android Equalizer**

### Task 6: Custom EQ Settings UI and Validation

**Files:**
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `docs/TECHNICAL_PLAN.md`

- [x] **Step 1: Add custom EQ segmented option and five sliders**
- [x] **Step 2: Update technical plan current-state notes**
- [x] **Step 3: Run `dart format lib`**
- [x] **Step 4: Run `flutter analyze`**
- [x] **Step 5: Run `flutter build apk --debug`**
- [x] **Step 6: Run `flutter build hap --debug`**
