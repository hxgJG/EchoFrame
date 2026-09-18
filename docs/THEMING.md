# 主题架构

## 使用

设置 → 外观 → 明暗模式：日间、夜间或跟随系统。默认仍为日间，已有用户的模式与强调色不变。夜间采用炭灰背景、分层灰色容器、柔白正文和薄荷绿音频强调色；视频保留桃粉语义色。

## 分层

- `lib/app/theme_catalog.dart`：主题注册表。`LumioThemeDefinition` 使用稳定字符串 ID，包含名称、两套 `ColorScheme` 和两套媒体语义色。
- `lib/app/theme.dart`：将色板、用户强调色组合为 `ThemeData`，统一管理组件样式。页面通用颜色从 `Theme.of(context).colorScheme` 获取。
- `LumioMediaColors`：`ThemeExtension`，提供音频/视频强调色、容器色及容器上文字色，支持主题切换插值。页面通过 `LumioTheme` 的 context 取色函数访问，不判断主题 ID、不写死颜色。
- `LumioSettings`：`themeId` 选择方案，`themeMode` 决定明暗策略，`themeAccent` 决定通用强调色。三个维度互不覆盖。存储与备份沿用现有 settings 序列化。
- macOS 桌面歌词：接收 Flutter 已解析的背景、前景、边框及明暗状态，跟随手动切换和系统模式，不再维护另一套主题。

## 新增方案

1. 在 `LumioThemeCatalog.themes` 注册一个 `LumioThemeDefinition`，提供唯一、稳定 ID 与名称。
2. 配齐 light/dark 的文字、表面层级、边框、语义状态等 Material 色彩角色，以及 lightMedia/darkMedia。通用 primary/primaryContainer 由强调色设置统一生成；媒体语义色由方案提供。
3. 设置页自动从注册表生成方案选项；无需新增枚举分支或修改页面。若新增色彩角色，扩展 `LumioMediaColors` 的 `copyWith`/`lerp` 及消费方。
4. 校验两种亮度、四种强调色，尤其是正文、选中态、禁用态、播放器、歌词及弹层。普通文字对比度目标至少 4.5:1。真实封面、视频和字幕的可读性覆盖层不重染色。

旧配置缺少 themeId 时使用 `mint`。未知或已下架的 ID 在解析主题时回退到默认方案，原始值保留，避免降级版本破坏设置。未来修改方案名称不要修改 ID。

## 验收重点

- 日间/夜间切换不改变播放、进度、循环方式；主题、明暗模式、强调色重启后恢复。
- 跟随系统时，由 MaterialApp 解析实际亮度；桌面歌词消费同一已解析颜色。
- 手机窄屏和桌面宽屏均无溢出，设置选中态、按钮和文字保持对比度。
- 扫描、备份恢复及未知 themeId 不应影响主题解析。
