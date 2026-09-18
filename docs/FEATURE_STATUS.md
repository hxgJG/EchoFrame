# 忆光 Lumio 功能状态矩阵

> 基线：`docs/Lumio_PRD_v0.5.md` v0.5
> 核对日期：2026-08-03
> 状态口径：✅ 已完成；🟡 部分完成；⬜ 未实现；⏸ 待确认或依赖外部条件

## 1. 当前结论

当前产品处于“Android 本地播放可用版本 + HarmonyOS 可构建 spike + macOS 核心主链路实施”阶段。
Android 的媒体浏览、播放列表、音视频播放、搜索、续播、本地歌词/字幕、播放速度、
睡眠定时器、AB 循环、均衡器、自动 PiP、封面/首帧懒加载和批量分享等主链路已经可用。
应用状态已按会话、媒体库、播放列表分区持久化，Android 使用 MMKV，HarmonyOS 使用系统
Preferences，避免数据库和高频完整媒体库写入。iOS 仍是工程骨架；HarmonyOS 已有导入、
播放和持久化桥接，并已完成真机启动与首页渲染验证，但仍缺少完整播放回归与后台/锁屏能力。

## 2. 功能矩阵

| 领域 | PRD 功能 | 状态 | 当前实现 | 剩余工作 |
|---|---|---:|---|---|
| Android 媒体库 | MediaStore 扫描、包含/排除目录、最短时长 | ✅ | 已有权限申请、MediaStore 查询和 JSON 快照 | 后续补增量监听和大库压测 |
| 扫描性能 | 异步扫描、分批入库、千级媒体不卡顿 | 🟡 | Android MediaStore 查询、歌词/字幕读取和快照写入已移到单独线程 | 增量监听、分批更新和千/万级真机压测 |
| 媒体元数据 | 标题、艺术家、专辑、时长、大小、格式、分辨率 | 🟡 | 基础字段、Android 内嵌封面和视频首帧已接入 | 码率、编码信息、HarmonyOS 封面 |
| 封面与缩略图 | 内嵌封面、视频首帧、自定义封面 | 🟡 | Android 已懒加载内嵌封面/视频帧并做内存缓存，失败回退占位图 | 磁盘缓存、HarmonyOS、自定义封面编辑 |
| 音乐首页 | 快捷入口、本地推荐、最近艺术家 | ✅ | 已基于本地数据实现 | 用户名/头像个性化可后续扩展 |
| 音乐库 | Songs/Albums/Artists/Folders、排序、随机播放 | 🟡 | 四个页签、五种排序、歌曲列表/网格切换已实现 | 高级筛选、专辑/艺术家详情页 |
| 播放列表 | 创建、重命名、删除、批量添加/移除、拖拽排序 | ✅ | 队列与持久播放列表已区分 | 可补导入/导出单个播放列表 |
| 音频播放 | 播放、暂停、seek、循环、随机、上下曲 | ✅ | Android Media3 1.10.1 ExoPlayer + 原生队列已接入 | 真机补格式兼容回归 |
| Now Playing | 封面/歌词、同步滚动、左右切换、下滑收起 | ✅ | 自动滚动、左右滑动、下滑/过度滚动收起、队列跳转和真实 Android 封面已实现 | 平台封面能力单列跟进 |
| 本地歌词 | 同名 LRC、偏移调整、当前行高亮 | ✅ | 解析、高亮、偏移和当前行自动跟随已实现 | 可继续增强非 UTF-8 编码兼容 |
| macOS 桌面歌词 | 独立置顶、当前句/下一句、拖动、锁定穿透 | ✅ | 设置与“显示”菜单开关；复用 LRC 时间轴和偏移，暂停保留、视频隐藏；位置及开关由本机保存 | Android 悬浮歌词未实现 |
| 后台与锁屏 | 前台服务、通知栏、锁屏、媒体键、音频焦点 | ✅ | MediaSessionService 持有 ExoPlayer/MediaSession，Media3 管理前台通知、锁屏、音频焦点和媒体键 | 真机兼容回归 |
| 音频增强 | 速度、睡眠定时器、EQ、AB、Gapless/Crossfade | ✅ | 速度、渐弱睡眠、EQ、AB、Media3 Gapless；Crossfade 默认关闭，开启为 3 秒双播放器交叉渐变 | 真机听感与格式兼容回归 |
| 视频播放 | Texture、全屏、方向、手势、续播、自动连播 | ✅ | Android Media3 ExoPlayer + Flutter Texture 主链路已实现 | 格式兼容矩阵和真机回归 |
| Android PiP | 后台小窗播放 | ✅ | Android 8–11 离开应用自动进入，12+ 自动进入；已同步生命周期并提供上曲/播放/下曲动作 | 真机兼容回归 |
| 字幕 | SRT/ASS、字号、颜色、位置 | 🟡 | SRT 与基础 ASS/SSA 已实现 | 复杂 ASS 样式、动画和特效 |
| 搜索 | 歌曲/专辑/艺术家/视频统一搜索 | ✅ | 本地索引统一搜索已实现 | 可补搜索历史和高级筛选 |
| 文件操作 | 详情、分享、标签写回、删除/移动/重命名、铃声 | 🟡 | 删除仅从忆光隐藏且可恢复；Android 真实移动/重命名和 MP3 ID3 文本标签写回已实现 | MP3 自定义封面、WAV/FLAC/M4A 标签、铃声 |
| 批量操作 | 加歌单、删除、分享、重命名、移动 | ✅ | 批量加入队列/歌单、歌单移除、系统分享、列表隐藏及真实移动已实现 | 真机授权流程回归 |
| 主题 | 浅色/深色、主题色、动态取色 | 🟡 | 耳机影音 Logo 与 Android/iOS/macOS/HarmonyOS 图标已同步；浅色/深色、四种柔和主题色及音频薄荷绿/视频桃粉语义色已实现；兼容已有主题设置 | Material You 真正取色 |
| 设置 | 播放页、音频、图片、通知、个性化、关于 | 🟡 | 播放、音频、扫描、备份基础入口已实现 | 通知样式、控件个性化、反馈、真实版本信息 |
| 在线增强 | 可插拔封面/歌词、缓存、频控、静默降级 | ✅ | 默认关闭且零请求；开启后接入 LRCLIB、MusicBrainz、Cover Art Archive；User-Agent 使用 GitHub 项目主页，不包含邮箱 | 发布前复核服务条款 |
| 备份恢复 | 播放列表/设置导出与导入 | 🟡 | Android/HarmonyOS 均支持应用内创建和恢复最近备份 | 系统文件选择器、跨平台文件导入/导出 |
| Widget | 主屏幕播放小组件 | ⬜ | 无 | Android/iOS/HarmonyOS 分平台实现 |
| 多语言 | 中文/英文切换 | ⬜ | 当前界面文本以中文硬编码 | 引入 Flutter l10n 并迁移文案 |
| 无障碍 | 字体缩放、TalkBack 基本可用 | 🟡 | 大量使用标准 Material 控件 | 补语义标签并做 TalkBack/大字体验收 |
| iOS | 导入、索引、音视频、后台、PiP | ⬜ | 仅 Flutter/iOS 工程骨架 | 完整平台实现 |
| macOS 工程 | Runner、Sandbox、Debug/Release、universal | ✅ | macOS 13 Runner 已生成；Debug 构建和 universal Release 产物已验证，Release/Profile 启用 Hardened Runtime | 配置 Developer ID 后完成 Archive、公证和 Gatekeeper 验收 |
| macOS 媒体库 | 文件夹授权、持久来源、扫描、元数据、封面、歌词/字幕 | 🟡 | NSOpenPanel、security-scoped bookmark、来源管理、AVAsset 扫描和快照已接入 | 真实媒体矩阵、跨重启授权和千级媒体性能验收 |
| macOS 播放 | AVPlayer、Texture、系统媒体控制、分享 | 🟡 | 音视频播放桥接、FlutterTexture、Now Playing/Remote Command 和分享已接入 | 真媒体长播、seek/切换、视频缩放和媒体键验收 |
| macOS 桌面体验 | 侧栏、菜单、快捷键、能力降级 | 🟡 | 宽屏媒体架、紧凑底栏回退、原生菜单、快捷键和平台能力模型已接入 | Now Playing 双栏、右键、多选和完整窗口尺寸矩阵 |
| HarmonyOS | 导入、音视频、后台、持久化 | 🟡 | Picker、AVMetadataExtractor、AVPlayer、Texture、分区 Preferences 已接入；签名 HAP 构建、真机启动和首页渲染通过 | 完整播放回归、后台/锁屏、封面和平台操作 |
| HarmonyOS PiP | 小窗播放 | ⏸ | PRD 允许首发不支持 | 后续单独排期 |

## 3. 本轮实施边界

本轮已经实现且可在当前仓库验证的功能：

1. Now Playing 左右切换、下滑收起、歌词自动跟随和 PiP 页面同步。
2. 音乐库列表/网格视图切换、Android 封面/视频首帧懒加载与批量分享。
3. 正式 Logo、Android/iOS/macOS/HarmonyOS 图标、四种品牌主题色及音频薄荷绿/视频桃粉语义色；未接入的动态取色入口明确禁用。
4. Android 扫描移出主线程，补充 MediaSession 元数据、音频焦点恢复和自动 PiP 控制。
5. 持久化按会话/媒体库/播放列表分区：Android MMKV、HarmonyOS Preferences；
   高频写入不再构造或传输完整媒体库，视频续播落盘节流为 30 秒。
6. HarmonyOS 应用内备份/恢复，并通过签名 HAP 构建验证。
7. Android 播放器升级为 Media3 1.10.1 MediaSessionService，队列支持可用格式的 Gapless。
8. Android 媒体隐藏/恢复、MediaStore 真实移动/重命名、MP3 ID3 标签写回及音乐、视频操作入口。
9. 可完全关闭的在线增强：LRCLIB 歌词、MusicBrainz + Cover Art Archive 封面和文件缓存。

## 4. 持久化技术决策

- 不引入 SQLite、Drift 等关系型数据库；当前数据以键值读取和整块媒体索引为主，没有复杂联表查询。
- Android 使用 `MMKV 1.3.9` 保存分区 JSON，利用 mmap 降低频繁小状态写入开销。
- HarmonyOS 使用系统 `Preferences` 保存相同分区协议，避免引入尚未在当前 Flutter OHOS 工程验证的第三方桥接。
- `session` 保存设置、队列和播放会话；`library` 保存低频媒体索引；`playlists` 独立保存。
- 常规设置/队列更新只序列化 `session`，不会再遍历全部媒体；媒体库只在扫描、收藏、
  播放统计、元数据或续播点变化时写入，视频续播写入间隔为 30 秒。
- 封面等二进制资源不进入 KV；当前使用内存缓存，后续如增加磁盘缓存则使用文件缓存目录。
- 只有出现复杂关联查询、局部索引更新无法满足性能且有基准数据证明时，才重新评估数据库。

## 5. 2026-07-27 决策记录

| 原编号 | 决策 | 后续动作 |
|---|---|---|
| Q1 | 在线增强必须同时支持“完全离线”和“允许联网”两种模式 | 保留总开关；关闭时零网络请求，开启后按需使用已选数据源 |
| Q2 | 允许真实标签写回、移动和重命名；删除决策已被 Q12 覆盖 | 源文件变更使用系统写授权；删除只从忆光媒体库隐藏 |
| Q3/Q4 | 同意升级 Media3，并落地前台播放 Service | 先迁移播放器所有权和媒体会话，再实现 Gapless/Crossfade |
| Q5 | iOS 暂不进入下一步 | 保留工程骨架和平台接口 |
| Q6 | Android/HarmonyOS 真机后续提供 | 当前以自动测试和 APK/HAP 构建为准 |
| Q7/Q8/Q9 | Material You、多语言、Widget、复杂 ASS 暂不考虑 | 保留状态，不进入近期排期 |
| Q10 | 允许联网下载依赖并核对官方资料 | 已采用 Media3 1.10.1；在线源暂定 LRCLIB、MusicBrainz、Cover Art Archive |
| Q11 | Crossfade 默认关闭，开启后默认 3 秒 | Android 使用双 ExoPlayer 交叉渐变；关闭或暂停时不轮询 |
| Q12 | 删除仅从当前列表移除，不永久删除 | 持久化隐藏 ID，扫描不会重现；设置中可恢复，源文件不变 |
| Q13 | 标签写回优先 MP3，再扩展 WAV/FLAC/M4A | 首版使用轻量 MP3 ID3 写回；其他格式保留扩展点 |
| Q14 | 在线客户端主页为 `https://github.com/hxgJG/EchoFrame`，不提供或显示邮箱 | User-Agent 仅包含应用版本和项目主页 |

## 6. 已确认问题台账

| 编号 | 问题 | 暂缓原因 | 最终需要确认 |
|---|---|---|---|
| Q1 | 在线服务正式客户端标识 | 使用 `https://github.com/hxgJG/EchoFrame`，不显示邮箱 | ✅ 已确认 |
| Q2 | Android 删除策略 | 只从忆光媒体库隐藏，可恢复，不删除设备源文件 | ✅ 已确认 |
| Q3 | Crossfade 默认行为 | 默认关闭，开启后固定 3 秒 | ✅ 已确认 |
| Q4 | 标签/封面写回格式范围 | 优先 MP3，之后逐步增加 WAV/FLAC/M4A | ✅ 已确认 |
| Q5 | HarmonyOS 设置页在窄屏下存在约 4.8px 横向溢出 | 不影响启动和首页，本轮先保持白屏修复最小化 | 后续统一优化设置项的窄屏自适应布局 |

## 7. 验证口径

- 测试策略按改动风险和项目实际决定；前端改动默认不新增单元测试。
- 不新增 Widget 单元测试，遵循项目全局约定。
- 每批完成后执行 `dart format`、`flutter test` 和 `flutter analyze`。
- 最终执行 Android debug APK 和签名 HarmonyOS debug HAP 构建；真机验证受设备状态阻塞时记录原始问题。
- 自动化验证不会操作真实用户媒体；移动、重命名和 MP3 标签写回只从用户主动操作入口触发并经过系统写授权。
