# Lumio Media3 与真实文件操作实施计划

**目标：** 在保持 Flutter 业务层和 HarmonyOS 现有能力稳定的前提下，将 Android 播放器迁移到 Media3 前台服务，并接入受系统授权保护的真实文件操作。

## 已确认边界

- Android 播放内核升级为 Media3。
- 播放器所有权移入 `MediaSessionService`，支持后台、锁屏和系统媒体控制。
- 删除只从忆光媒体库隐藏并可恢复，不删除源文件；真实移动、重命名和标签写回必须由用户主动触发并经过系统写授权。
- 在线增强同时支持完全离线和允许联网；关闭总开关时不得发起网络请求。
- iOS、Material You、多语言、Widget 和复杂 ASS 暂缓。
- 不迁移尚未产生的历史用户数据。

## Phase 1：协议与安全规则

- [x] 为播放队列平台负载编写失败测试。
- [x] 为文件操作目标与安全确认规则编写失败测试。
- [x] 扩展播放和媒体库 Repository，保持 Flutter UI 不依赖 Android 类型。

## Phase 2：Media3 前台播放

- [x] 引入 Media3 1.10.1 ExoPlayer 与 MediaSession Service。
- [x] 将播放、暂停、seek、速度、队列和音频焦点迁移到 Service。
- [x] Activity 只负责 Flutter MethodChannel、视频 Surface、亮度和 PiP。
- [x] 接入媒体通知、锁屏元数据、耳机/蓝牙按键和前台服务生命周期。
- [x] 保留 Equalizer、睡眠渐弱、视频 Texture 和 PiP。
- [x] 通过 Android debug APK 构建。

## Phase 3：Gapless 与 Crossfade

- [x] Flutter 将当前队列同步给 Media3。
- [x] 使用 Media3 播放列表实现可用格式的 Gapless。
- [x] Crossfade 默认关闭，开启后使用双 ExoPlayer 做 3 秒交叉渐变。

## Phase 4：真实文件操作

- [x] 单个/批量移除：持久化隐藏 ID，不调用 MediaStore 删除，设置中可恢复。
- [x] 重命名：更新 `DISPLAY_NAME`，成功后刷新索引。
- [x] 移动：更新 `RELATIVE_PATH`，成功后刷新索引。
- [x] 失败、取消或权限拒绝时保持 App 索引不变。
- [x] 首版实现 MP3 ID3 文本标签写回；WAV/FLAC/M4A 与自定义封面后续扩展。

## Phase 5：在线增强

- [x] 建立可替换的在线增强 Repository。
- [x] 总开关关闭时零网络请求。
- [x] 本地嵌入信息优先，其次缓存，最后才允许在线查询。
- [x] 使用 LRCLIB、MusicBrainz、Cover Art Archive，实现文件缓存、频控和静默降级。

## 验证

- [x] `dart format lib test`
- [x] `flutter test`
- [x] `flutter analyze`
- [x] `flutter build apk --debug`
- [ ] `flutter build hap --debug`
- [ ] 真机到位后补后台、锁屏、PiP、Crossfade、MP3 写授权与大库性能验证。
