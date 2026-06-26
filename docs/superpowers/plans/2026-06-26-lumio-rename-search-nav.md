# Lumio Rename and Search Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the app to 忆光 / Lumio, update application identifiers, localize the home tab label, and move search out of the bottom navigation into standalone pages reachable from top bars.

**Architecture:** Keep existing Flutter state management and feature pages. Rename visible app labels and platform identifiers across Android, iOS, and HarmonyOS; update MethodChannel names with the product namespace so Dart and Android stay aligned. Replace the search bottom tab with route-based navigation opened from Home/List/Video app bars.

**Tech Stack:** Flutter 3.35.8-ohos-1.0.1, Dart 3.9.2, Android Gradle, iOS Xcode project, HarmonyOS project JSON5, no new third-party dependency.

## Global Constraints

- 默认使用中文进行沟通、说明和总结。
- Flutter 版本目标：`Flutter 3.35.8-ohos-1.0.1 / Dart 3.9.2`。
- HarmonyOS HAP 构建必须继续通过 `flutter build hap --debug`。
- 不新增第三方依赖。
- 不提交本机签名材料、`local.properties`、构建产物或缓存。

---

### Task 1: Rename Product and Package IDs

**Files:**
- Modify: `pubspec.yaml`
- Modify: `README.md`
- Modify: `lib/main.dart`
- Modify: `lib/features/music/music_home_page.dart`
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `android/app/build.gradle`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Move/Modify: `android/app/src/main/kotlin/com/hxg/lumio/MainActivity.kt`
- Modify: `ohos/AppScope/app.json5`
- Modify: `ohos/AppScope/resources/base/element/string.json`
- Modify: `ohos/entry/src/main/resources/*/element/string.json`
- Modify: `ios/Runner/Info.plist`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: visible app name `忆光`
- Produces: English product name `Lumio`
- Produces: Android/iOS/HarmonyOS package/bundle id `com.hxg.lumio`

- [x] **Step 1: Replace visible app name and English docs title**
- [x] **Step 2: Update Android namespace/applicationId and Kotlin package path**
- [x] **Step 3: Update HarmonyOS bundleName and app labels**
- [x] **Step 4: Update iOS bundle identifiers and display names**

### Task 2: Search Navigation

**Files:**
- Modify: `lib/app/app_state.dart`
- Modify: `lib/main.dart`
- Modify: `lib/features/music/music_home_page.dart`
- Modify: `lib/features/music/music_library_page.dart`
- Modify: `lib/features/music/playlists_page.dart`
- Modify: `lib/features/video/video_page.dart`
- Modify: `lib/features/search/search_page.dart`

**Interfaces:**
- Removes: `AppSection.search` as a bottom navigation destination
- Produces: standalone `SearchPage` route opened from Home/List/Video top-bar search buttons

- [x] **Step 1: Remove search from bottom navigation**
- [x] **Step 2: Change For You label to Chinese**
- [x] **Step 3: Open search page via Navigator route from Home/List/Video**
- [x] **Step 4: Keep search page behavior unchanged**

### Task 3: Documentation and Validation

**Files:**
- Modify: `docs/TECHNICAL_PLAN.md`
- Modify: `docs/EchoFrame_PRD_v0.5.md`
- Modify only touched code if verification finds issues.

- [x] **Step 1: Update docs for 忆光 / Lumio and navigation**
- [x] **Step 2: Run `dart format lib`**
- [x] **Step 3: Run `flutter analyze`**
- [x] **Step 4: Run `flutter build apk --debug`**
- [ ] **Step 5: Run `flutter build hap --debug`**

  Result: blocked at `:entry:default@SignHap` because the generated DevEco SigningConfigs still match the previous bundle identifier while `ohos/AppScope/app.json5` now uses `com.hxg.lumio`. Re-run DevEco automatic signing/Fix for the new bundle name, then retry `flutter build hap --debug`.
