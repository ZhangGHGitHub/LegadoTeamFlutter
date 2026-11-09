// [UI-fix v2.0.5 | 2026-08-08] 偏好键常量：对齐原版 PreferKey/preference key，
// 便于后续行为接线与数据迁移（主题设置页 + 其他设置页） — Qoder

/// 原版偏好键常量（io.legado.app.constant.PreferKey 子集 + preference XML key）
///
/// 命名与原版完全一致，值即 SharedPreferences 键名。
/// 仅收录本次"主题设置页/其他设置页"对齐涉及的键，其余键仍在各自服务内维护。
class PrefKeys {
  PrefKeys._();

  // ===== 主题设置页（pref_config_theme.xml）=====

  /// 启动图标（仅 Android 生效，原版 launcherIcon）
  static const launcherIcon = 'launcherIcon';

  /// 沉浸式状态栏（仅 Android 生效，默认 true）
  static const transparentStatusBar = 'transparentStatusBar';

  /// 沉浸式导航栏（仅 Android 生效，默认 true）
  static const immNavigationBar = 'immNavigationBar';

  /// 导航栏阴影高度（原版 barElevation，0~32）
  static const barElevation = 'barElevation';

  /// 底部操作栏皮肤跟随背景（仅 Android 生效）
  static const bottomBarSkin = 'bottomBarSkin';

  /// 使用壁纸取色（Android 12+/iOS 动态色均可用——R1 接通 dynamic_color；
  /// 默认 false）
  static const wallpaperColorFollow = 'wallpaperColorFollow';

  /// 壁纸变化时自动更新取色（仅 Android 生效，默认 true）
  static const wallpaperColorAutoUpdate = 'wallpaperColorAutoUpdate';

  /// 日间主色调（ARGB int）
  static const cPrimary = 'colorPrimary';

  /// 日间强调色（ARGB int）
  static const cAccent = 'colorAccent';

  /// 日间背景色（ARGB int）
  static const cBackground = 'colorBackground';

  /// 日间底部操作栏颜色（ARGB int）
  static const cBBackground = 'colorBottomBackground';

  /// 夜间主色调（ARGB int）
  static const cNPrimary = 'colorPrimaryNight';

  /// 夜间强调色（ARGB int）
  static const cNAccent = 'colorAccentNight';

  /// 夜间背景色（ARGB int）
  static const cNBackground = 'colorBackgroundNight';

  /// 夜间底部操作栏颜色（ARGB int）
  static const cNBBackground = 'colorBottomBackgroundNight';

  /// 日间背景图片路径
  static const bgImage = 'backgroundImage';

  /// 夜间背景图片路径
  static const bgImageN = 'backgroundImageNight';

  /// 日间导航栏透明（仅 Android 生效，默认 false）
  static const transparentNavBar = 'transparentNavBar';

  /// 夜间导航栏透明（仅 Android 生效，默认 false）
  static const transparentNavBarNight = 'transparentNavBarNight';

  // ===== 容器外观（设置批2b-1a，键名逐字对齐参考版 PreferKey.kt:228,270-283）=====
  //
  // 容器背景图（大容器）/容器不透明度/背景图虚化同属「外观」设置。参考版
  // 把它们放在 `ThemeSettings`（`domain/model/settings/ThemeSettings.kt:27,
  // 54-57`）并经 `FeatureSettingsRepositories.kt:376,408-414` 读写。
  //
  // 备份归组口径（对齐参考版 `help/storage/BackupConfig.kt:263-317`）：
  // - `containerOpacity` / `bgImageBlurring` / `bgImageNBlurring` 在参考版
  //   themePrefKeys 内，随「忽略主题配置」过滤；
  // - `largeContainerBackgroundImageLight/Dark` **不在** themePrefKeys 内，
  //   任何忽略组合下都随 appPrefs 备份/恢复（恢复后图片缺失按缺失回落）。

  /// 容器卡面不透明度 0..100（参考版 containerOpacity，默认 100）
  static const containerOpacity = 'containerOpacity';

  /// 大容器背景图自身不透明度 0..100（参考版 appColumnBackgroundOpacity，
  /// 默认 100；仅乘在容器背景图 alpha 上，与 [containerOpacity] 卡面 scrim
  /// 独立叠加）
  ///
  /// 参考版 `ThemeSettings.kt:61` 默认 100，`AppContainerBackground.kt:61`
  /// 对 Large 图取 `value / 100f` 作为绘制 alpha。备份归组已核对参考版
  /// `BackupConfig.kt:263-317`：该键**不在** themePrefKeys 内，因此任何
  /// 忽略组合下都随 appPrefs 往返（与 [containerOpacity] 的归组不同）。
  static const appColumnBackgroundOpacity = 'appColumnBackgroundOpacity';

  /// 启用容器背景图（参考版 enableContainerBackgroundImage，默认 false）
  ///
  /// 关闭时保留已选图片路径但不渲染（参考版 `ThemeConfigScreen.kt:534-544`
  /// 为总开关 + 条件显隐图片行）；选择图片时由设置页/Notifier 自动置 true。
  /// 参考版 BackupConfig.themePrefKeys 未收录此键 → 随 appPrefs 始终往返。
  static const enableContainerBackgroundImage =
      'enableContainerBackgroundImage';

  /// 日间大容器背景图（参考版 largeContainerBackgroundImageLight，默认 null）
  ///
  /// 值为「相对应用 Support 目录的可迁移标识」（`theme_backgrounds/large_light/<md5>.<ext>`），
  /// 由 ThemeBackgroundImageStore 解析；旧备份/参考版备份可能携带绝对路径，
  /// 解析侧对绝对路径原样透传，文件不存在时按缺失回落。
  static const largeContainerBackgroundImageLight =
      'largeContainerBackgroundImageLight';

  /// 夜间大容器背景图（参考版 largeContainerBackgroundImageDark，默认 null）
  static const largeContainerBackgroundImageDark =
      'largeContainerBackgroundImageDark';

  /// 日间项目（卡片）背景图（参考版 itemBackgroundImageLight，默认 null）
  ///
  /// [设置批2b-1b-2b] 参考版 `ThemeSettings.kt:58-59`：
  /// `itemBackgroundImageLight/Dark` 用于 GlassCard（含设置行 SettingCard）
  /// 卡面图片，值同样为 ThemeBackgroundImageStore 的相对可迁移标识
  /// （槽位 `item_light`/`item_dark`）。
  /// 参考版 `AppContainerBackground.kt:51-63` 与 Large 图共用
  /// `enableContainerBackgroundImage` 总开关；Alpha 取
  /// `glassCardBackgroundOpacity / 100f`。
  /// 备份归组已核对 `BackupConfig.kt:263-317`：该键**不在** themePrefKeys
  /// 内 → 任何忽略组合下都随 appPrefs 往返。
  static const itemBackgroundImageLight = 'itemBackgroundImageLight';

  /// 夜间项目（卡片）背景图（参考版 itemBackgroundImageDark，默认 null）
  static const itemBackgroundImageDark = 'itemBackgroundImageDark';

  /// 项目（卡片）背景图自身不透明度 0..100（参考版
  /// glassCardBackgroundOpacity，默认 100）
  ///
  /// [设置批2b-1b-2b] 参考版 `ThemeSettings.kt:62` 默认 100，
  /// `AppContainerBackground.kt:61-63` 对 Item 图取 `value / 100f` 作为
  /// 绘制 alpha。与 [containerOpacity]（卡面底色 alpha）、
  /// [appColumnBackgroundOpacity]（大容器图 alpha）三者相互独立。
  /// 参考版 BackupConfig.themePrefKeys 未收录此键 → 随 appPrefs 往返。
  static const glassCardBackgroundOpacity = 'glassCardBackgroundOpacity';

  /// 日间全局背景图虚化半径 0..100（参考版 bgImageBlurring="backgroundImageBlurring"，
  /// 默认 0；仅作用于全局壁纸，不影响内容/文字）
  static const bgImageBlurring = 'backgroundImageBlurring';

  /// 夜间全局背景图虚化半径 0..100（参考版 bgImageNBlurring=
  /// "backgroundImageNightBlurring"，默认 0）
  static const bgImageNBlurring = 'backgroundImageNightBlurring';

  // ===== 护眼模式（设置批2a-1，键名逐字对齐参考版 PreferKey.kt:489-495）=====
  //
  // 六键同属外观/主题偏好：参考版把它们放在 BackupConfig.themePrefKeys
  // （`help/storage/BackupConfig.kt:311-316`），因此我方也随「忽略主题配置」
  // 一并过滤，见 RestoreIgnorePrefs.themePrefKeys。

  /// 启用护眼模式（默认 false）
  static const eyeProtectionEnabled = 'eyeProtectionEnabled';

  /// 护眼强度/色温 0..100（默认 50；0=不改变颜色）
  static const colorTemperature = 'colorTemperature';

  /// 深色模式时自动开启（默认 false；跟随应用主题明暗）
  static const eyeProtectionAutoNight = 'eyeProtectionAutoNight';

  /// 定时开启（默认 false）
  static const eyeProtectionSchedule = 'eyeProtectionSchedule';

  /// 定时开始时间 HH:mm（默认 22:00）
  static const eyeProtectionStartTime = 'eyeProtectionStartTime';

  /// 定时结束时间 HH:mm（默认 07:00，结束时刻不含）
  static const eyeProtectionEndTime = 'eyeProtectionEndTime';

  // ===== UI 布局同步重构开关族（UI_SYNC_REFACTOR_PLAN_20260905.md，
  // key 名对齐参考仓 PreferKey，经 SharedPreferences 透存，Rust 不解释）=====

  /// 顶栏按钮样式：plain/tonal/outlined/glass/liquidGlass（参考仓默认 tonal）
  static const topBarButtonStyle = 'topBarButtonStyle';

  /// 顶栏按钮合并进胶囊容器（参考仓 mergeTopBarActions，默认 false）
  static const mergeTopBarActions = 'mergeTopBarActions';

  /// 使用 MediumFlexible 大顶栏形态（参考仓 useFlexibleTopAppBar，默认 true）
  static const useFlexibleTopAppBar = 'useFlexibleTopAppBar';

  /// 顶栏不透明度 0-100（参考仓 topBarOpacity，默认 100）
  static const topBarOpacity = 'topBarOpacity';

  /// 底栏 label 显示档位：auto/labeled/unlabeled（参考仓默认 auto）
  static const labelVisibilityMode = 'labelVisibilityMode';

  /// 底栏不透明度 0-100（参考仓 bottomBarOpacity，默认 100）
  static const bottomBarOpacity = 'bottomBarOpacity';

  /// 悬浮底栏（参考仓 useFloatingBottomBar，默认关）
  static const useFloatingBottomBar = 'useFloatingBottomBar';

  /// 显示底栏（参考仓 showBottomView，默认开）
  static const showBottomView = 'showBottomView';

  /// 平板/大屏导航形态：auto/always/landscape/off（参考仓默认 auto）
  static const tabletInterface = 'tabletInterface';

  /// 多栏布局模式：auto/landscape/always/off（参考版
  /// `PreferKey.multiPaneMode`，默认 auto）
  ///
  /// [设置批2b-2b] 判定只取当前窗口尺寸（见 `resolveMultiPane`），
  /// 与 [tabletInterface]（导航侧栏形态）相互独立。
  /// 备份归组已核对参考版 `BackupConfig.themePrefKeys`（263-317）：
  /// 该键**不在** themePrefKeys 内 → 任何忽略组合下都随 appPrefs 往返；
  /// 开关本身属窗口布局偏好，不随「忽略主题配置」过滤。
  static const multiPaneMode = 'multiPaneMode';

  /// 详情页跟随封面取色换肤（参考仓 bookInfoFollowCoverColor，默认开）
  static const bookInfoFollowCoverColor = 'bookInfoFollowCoverColor';

  /// 详情页网络封面背景三档：off/off_for_default/on（参考仓默认 on）
  static const bookInfoNetworkCoverBackground =
      'bookInfoNetworkCoverBackground';

  /// 详情页默认封面背景三档（参考仓默认 on）
  static const bookInfoDefaultCoverBackground =
      'bookInfoDefaultCoverBackground';

  /// 覆写基础卡片圆角（参考仓 overrideBaseCardCornerRadius，默认关）
  static const overrideBaseCardCornerRadius = 'overrideBaseCardCornerRadius';

  /// 基础卡片圆角值 0-40（参考仓 baseCardCornerRadius，默认 16）
  ///
  /// [设置批2b-1b-1] 参考版滑杆范围 0f..40f（ThemeConfigScreen.kt:622-635）；
  /// 我方以整数 dp 存储，0 = 直角。
  static const baseCardCornerRadius = 'baseCardCornerRadius';

  /// 覆写基础卡片边框（参考仓 overrideBaseCardBorder，默认关）
  static const overrideBaseCardBorder = 'overrideBaseCardBorder';

  /// 基础卡片边框宽度 dp 0-5（参考仓 baseCardBorderWidth，默认 1）
  static const baseCardBorderWidth = 'baseCardBorderWidth';

  /// 日间基础卡片边框颜色 ARGB（参考仓 baseCardBorderColor，
  /// 0=跟随主题 outlineVariant）
  static const baseCardBorderColor = 'baseCardBorderColor';

  /// 夜间基础卡片边框颜色 ARGB（参考仓 baseCardBorderColorNight，
  /// 0=跟随主题 outlineVariant）
  static const baseCardBorderColorNight = 'baseCardBorderColorNight';

  /// 关闭拼接分组圆角（参考仓 disableSplicedColumnGroupCornerRadius，默认关）
  ///
  /// 开启后分组外角固定 0，优先级高于 [overrideBaseCardCornerRadius]
  /// （参考仓 SplicedColumnGroup.kt:50-53）。
  static const disableSplicedColumnGroupCornerRadius =
      'disableSplicedColumnGroupCornerRadius';

  /// 启用毛玻璃（参考仓 enableBlur，默认关——低端机掉帧保护）
  static const enableBlur = 'enableBlur';

  /// 顶栏模糊半径 dp（参考仓 topBarBlurRadius，默认 24）
  static const topBarBlurRadius = 'topBarBlurRadius';

  /// 顶栏模糊底色透明度 0-255（参考仓 topBarBlurAlpha，默认 73）
  static const topBarBlurAlpha = 'topBarBlurAlpha';

  /// 悬浮底栏模糊半径 dp（参考仓 bottomBarBlurRadius，默认 8）
  static const bottomBarBlurRadius = 'bottomBarBlurRadius';

  /// 悬浮底栏底色透明度 0-255（参考仓 bottomBarBlurAlpha，默认 40）
  static const bottomBarBlurAlpha = 'bottomBarBlurAlpha';

  /// 设置行分隔线开关（参考仓 enableItemDivider，默认关）
  static const enableItemDivider = 'enableItemDivider';

  /// 设置行分隔线宽度 dp 0-5（参考仓 itemDividerWidth，默认 1）
  static const itemDividerWidth = 'itemDividerWidth';

  /// 设置行分隔线长度百分比 30-100（参考仓 itemDividerLength，默认 80）
  ///
  /// 参考版换算为 `length / 100f` 后作为 `fillMaxWidth(fraction)` 使用
  /// （SettingItemDivider.kt:23-24），即占分组可用宽度的百分比，不是 dp。
  static const itemDividerLength = 'itemDividerLength';

  /// 设置行分隔线颜色 ARGB（参考仓 itemDividerColor，0=默认灰色 30%）
  static const itemDividerColor = 'itemDividerColor';

  /// 大屏侧栏展开态持久化（参考仓 navExtended）
  static const railExtended = 'railExtended';

  /// 主题引擎 paletteStyle（参考仓 paletteStyle，'none'=关闭参数化）
  static const themeStyle = 'themeStyle';

  /// 主题引擎对比度（参考仓 customContrast，'0.0'/'0.5'/'1.0'）
  static const themeContrastLevel = 'themeContrastLevel';

  /// AMOLED 纯黑（参考仓 pure_black/isAmoled，默认关）
  static const themeAmoled = 'themeAmoled';

  /// 阅读菜单亮度竖条开关（参考仓 showBrightnessView="2" 变体，默认关）
  ///
  /// [批1b-1] 停止消费：竖条显隐改由 ReaderAdvancedConfig.readBrightnessMode
  /// 三档承载（键 readBrightnessMode）；本键仅在迁移时读取一次旧值，
  /// 不再有任何消费方（保留常量供迁移代码引用）。
  static const readMenuBrightnessVertical = 'readMenuBrightnessVertical';

  /// 阅读菜单亮度竖条位置：left/right（参考仓 brightnessVwPos）
  ///
  /// [批1b-1] 停止消费：位置改由 readBrightnessVwPos（'0'=左/'1'=右）
  /// 承载；迁移时读取一次旧值（left→'0'/right→'1'），之后不再消费。
  static const readMenuBrightnessPos = 'readMenuBrightnessVwPos';

  /// 阅读器顶栏动作配置（批37）
  ///
  /// 参考版持久化在 SharedPreferences 文件 `title_bar_actions` 的 `actions`
  /// 键（`ReadButtonConfigDelegate.TITLE_BAR_ACTION_PREFS/KEY`），值格式
  /// `id,true;id,false`。Flutter 只有单一 prefs 存储，故以
  /// `文件名.键名` 拼接；随 Flutter JSON 备份 `appPrefs` 往返，并受
  /// 「忽略阅读配置」约束（RestoreIgnorePrefs.readPrefKeys）。
  static const readerTopBarActions = 'title_bar_actions.actions';

  // ===== [批3a] 阅读器菜单系统（键名逐字对齐参考版 PreferKey）=====
  //
  // 参考依据：`SystemMenuPage.kt`（全局/底栏布局/顶栏布局三子页）、
  // `ReadBookMenuBarBottom.kt`（图标网格/分页）、
  // `ReadBookMenuBarTitle.kt`（标题模式/胶囊/合并按钮/图标三态）、
  // `domain/model/settings/ReadSettings.kt` 默认值。
  // 全部随 Flutter JSON 备份 `appPrefs` 往返，并加入
  // `RestoreIgnorePrefs.readPrefKeys`（「忽略阅读配置」）。

  /// 底栏图标是否显示文字（参考默认 false）
  static const readMenuIconShowText = 'readMenuIconShowText';

  /// 底栏每行图标数 2..8（参考默认 5）
  static const readMenuIconItemsPerRow = 'readMenuIconItemsPerRow';

  /// 底栏图标行数 1..2（参考默认 1）
  static const readMenuIconRowCount = 'readMenuIconRowCount';

  /// 底栏图标容器样式 0 无底衬 / 1 色调 / 2 描边（参考默认 0）
  static const readMenuIconStyle = 'readMenuIconStyle';

  /// 浮动底栏（参考默认 true）
  static const readMenuFloatingBottomBar = 'readMenuFloatingBottomBar';

  /// 底栏圆角 0..32（参考默认 32）
  static const readMenuBottomCornerRadius = 'readMenuBottomCornerRadius';

  /// 工具栏样式 0 跟随系统 / 1 跟随阅读背景 / 2 自定义（参考默认 1）
  static const readBarStyle = 'readBarStyle';

  /// 旧工具栏跟随页面布尔键（仅在新键缺失时一次性迁移：true→1/false→0）
  static const readBarStyleFollowPage = 'readBarStyleFollowPage';

  /// 菜单颜色来源 0 种子色 / 1 自定义主题色（参考默认 1）
  static const readMenuColorMode = 'readMenuColorMode';

  /// 菜单调色板（`''`=跟随系统，其余对齐 arrays.xml paletteStyle 值）
  static const readMenuPaletteStyle = 'readMenuPaletteStyle';

  /// 自定义菜单背景色（日/夜，ARGB，0=跟随/回落）
  static const readMenuBgColor = 'readMenuBgColor';
  static const readMenuBgColorNight = 'readMenuBgColorNight';

  /// 自定义菜单强调色（日/夜，ARGB，0=回落主题 primary）
  static const readMenuAccentColor = 'readMenuAccentColor';
  static const readMenuAccentColorNight = 'readMenuAccentColorNight';

  /// 自定义菜单容器色（日/夜，ARGB，0=回落背景色）
  static const readMenuContainerColor = 'readMenuContainerColor';
  static const readMenuContainerColorNight = 'readMenuContainerColorNight';

  /// 自定义菜单文字色（日/夜，ARGB，0=按背景对比色）
  static const readMenuTextColor = 'readMenuTextColor';
  static const readMenuTextColorNight = 'readMenuTextColorNight';

  /// 顶栏标题胶囊布局（参考默认 false）
  static const readMenuTopBarTitleCapsule = 'readMenuTopBarTitleCapsule';

  /// 顶栏标题显示方式 '0' 顶栏显示 / '1' 另起一行 / '2' 仅章节 / '3' 不显示
  static const titleBarMode = 'titleBarMode';

  /// 顶栏动作按钮合并为胶囊（参考默认 false）
  static const readMenuTopBarMergeButtons = 'readMenuTopBarMergeButtons';

  /// 顶栏图标容器样式 0 无底衬 / 1 色调 / 2 描边（参考默认 0）
  static const titleBarIconStyle = 'titleBarIconStyle';

  // ===== [批3b] 菜单模糊 / 边框 / 紧凑顶栏（键名逐字对齐参考版 PreferKey）=====

  /// 菜单边框宽度 0..4（0=关闭，参考默认 1）
  static const readMenuBorderWidth = 'readMenuBorderWidth';

  /// 菜单边框颜色（日/夜，ARGB，0=outlineVariant）
  static const readMenuBorderColor = 'readMenuBorderColor';
  static const readMenuBorderColorNight = 'readMenuBorderColorNight';

  /// 菜单模糊半径 0..32 dp（参考默认 24）
  static const readMenuBlurRadius = 'readMenuBlurRadius';

  /// 菜单背景透明度 0..100（参考默认 85，alpha/100）
  static const readMenuBlurAlpha = 'readMenuBlurAlpha';

  /// 菜单模糊底色（日/夜，ARGB，0=跟随菜单背景）
  static const readMenuBlurColor = 'readMenuBlurColor';
  static const readMenuBlurColorNight = 'readMenuBlurColorNight';

  /// 顶/底栏模糊模式 0 None / 1 LiquidGlass / 2 Haze（对齐参考）
  static const readMenuTopBarBlurMode = 'readMenuTopBarBlurMode';
  static const readMenuBottomBarBlurMode = 'readMenuBottomBarBlurMode';

  /// 顶/底栏模糊风格 0 Solid / 1 Progressive
  static const readMenuTopBarBlurStyle = 'readMenuTopBarBlurStyle';
  static const readMenuBottomBarBlurStyle = 'readMenuBottomBarBlurStyle';

  /// 顶/底栏图标液态玻璃（参考默认 false）
  static const readMenuTopBarLiquidGlassButtons =
      'readMenuTopBarLiquidGlassButtons';
  static const readMenuBottomBarLiquidGlassButtons =
      'readMenuBottomBarLiquidGlassButtons';

  /// 顶栏紧凑模式：仅保留「更多」动作（参考 titleBarCompact，默认 false）
  static const titleBarCompact = 'titleBarCompact';

  // ===== [批4a] 阅读器九宫格点击区域（键名逐字对齐参考 PreferKey）=====

  static const clickActionTopLeft = 'clickActionTopLeft';
  static const clickActionTopCenter = 'clickActionTopCenter';
  static const clickActionTopRight = 'clickActionTopRight';
  static const clickActionMiddleLeft = 'clickActionMiddleLeft';
  static const clickActionMiddleCenter = 'clickActionMiddleCenter';
  static const clickActionMiddleRight = 'clickActionMiddleRight';
  static const clickActionBottomLeft = 'clickActionBottomLeft';
  static const clickActionBottomCenter = 'clickActionBottomCenter';
  static const clickActionBottomRight = 'clickActionBottomRight';

  /// 旧三区 → 九宫格一次性迁移标记（设备级，仅备份排除、恢复侧不拦截）
  static const clickActionMigratedV2 = 'clickActionMigratedV2';

  // ===== [批4b] 自定义翻页键（键名逐字对齐参考 PreferKey）=====

  /// 上一页自定义 keyCode 串（逗号分隔，默认 ''）
  static const prevKeyCodes = 'prevKeyCodes';

  /// 下一页自定义 keyCode 串（逗号分隔，默认 ''）
  static const nextKeyCodes = 'nextKeyCodes';

  // ===== [批4c] 正文选择菜单（键名逐字对齐参考 PreferKey）=====

  /// 选择菜单 JSON 配置（空=全部一级）
  static const textSelectMenuConfig = 'textSelectMenuConfig';

  /// 多行展示（默认 false）
  static const expandTextMenu = 'expandTextMenu';

  /// 展示图标（默认 true）
  static const showSelectMenuIcon = 'showSelectMenuIcon';

  // ===== [批4d] 滑动书签/角标（键名逐字对齐参考 PreferKey）=====

  /// 下滑添加/取消书签（默认 false）
  static const swipeToAddBookmark = 'swipeToAddBookmark';

  /// 书签角标自定义图（应用内相对标识，空=默认琥珀书签带）
  static const bookmarkBadgeImage = 'bookmarkBadgeImage';

  /// 书签角标大小（dp，参考默认 10，范围 0..50）
  static const bookmarkBadgeSize = 'bookmarkBadgeSize';

  // ===== 欢迎页样式（pref_config_welcome.xml / WelcomeConfigFragment）=====

  /// 欢迎页显示时长（毫秒，原版默认 500，范围 0~800）
  static const welcomeShowTime = 'welcomeShowTime';

  /// 自定义欢迎页（默认 false）
  static const customWelcome = 'customWelcome';

  /// 白天欢迎背景图路径（PreferKey.welcomeImage = welcomeImagePath）
  static const welcomeImage = 'welcomeImagePath';

  /// 夜间欢迎背景图路径
  static const welcomeImageDark = 'welcomeImagePathDark';

  /// 欢迎页显示文字（白天，默认 true）
  static const welcomeShowText = 'welcomeShowText';

  /// 欢迎页显示文字（夜间，默认 true）
  static const welcomeShowTextDark = 'welcomeShowTextDark';

  /// 欢迎页显示图标（白天，默认 true）
  static const welcomeShowIcon = 'welcomeShowIcon';

  /// 欢迎页显示图标（夜间，默认 true）
  static const welcomeShowIconDark = 'welcomeShowIconDark';

  // ===== 封面设置（pref_config_cover.xml）=====

  /// 仅 Wifi 加载封面（默认 false）
  static const loadCoverOnlyWifi = 'loadCoverOnlyWifi';

  /// 优先使用默认封面（默认 false）
  static const useDefaultCover = 'useDefaultCover';

  /// 默认封面显示书名（默认 true）
  static const coverShowName = 'coverShowName';

  /// 默认封面显示作者（默认 true）
  static const coverShowAuthor = 'coverShowAuthor';

  /// 限制封面比例（批39，默认 true）
  ///
  /// 键名逐字对齐参考版 `PreferKey.coverRestrictRatio`：开启（默认）时
  /// 书架/搜索/发现/详情封面固定 5:7；关闭后按封面原图宽高比自适应。
  /// 随 Flutter JSON 备份 `appPrefs` 往返，并受「忽略封面配置」约束
  /// （RestoreIgnorePrefs.coverPrefKeys）。
  static const coverRestrictRatio = 'coverRestrictRatio';

  // ===== [设置批6b-1] 封面设置补充键（键名逐字对齐参考版 PreferKey）=====

  /// 封面外阴影 + 字体阴影（默认 false）
  static const coverShowShadow = 'coverShowShadow';

  /// 字体描边（默认 true）
  static const coverShowStroke = 'coverShowStroke';

  /// 使用默认字体颜色（主题 secondary，默认 true）
  static const coverDefaultColor = 'coverDefaultColor';

  /// 日间正文色（默认 0xFF000000）
  static const coverTextColor = 'coverTextColor';

  /// 夜间正文色（参考版键名 coverTextColorN，默认 0xFFFFFFFF）
  static const coverTextColorN = 'coverTextColorN';

  /// 日间阴影色（默认 0xFF000000）
  static const coverShadowColor = 'coverShadowColor';

  /// 夜间阴影色（参考版键名 coverShadowColorN，默认 0xFFFFFFFF）
  static const coverShadowColorN = 'coverShadowColorN';

  /// 夜间显示书名（默认 true）
  static const coverShowNameN = 'coverShowNameN';

  /// 夜间显示作者（默认 true）
  static const coverShowAuthorN = 'coverShowAuthorN';

  /// 封面信息方向：0 竖排 / 1 横排（默认 "0"）
  static const coverInfoOrientation = 'coverInfoOrientation';

  /// 默认封面图集 ID（参考版键名 defaultCover；6b-2 相册接入）
  static const coverDefaultAlbumId = 'defaultCover';

  /// 默认夜间封面图集 ID（参考版键名 defaultCoverDark；6b-2 相册接入）
  static const coverDefaultAlbumIdDark = 'defaultCoverDark';

  /// 封面相册旧路径迁移完成标记（参考版 LocalPreferencesKeys
  /// `cover_album_migrated`；设置批6b-2，设备级一次性状态，不随备份往返）
  static const coverAlbumMigrated = 'cover_album_migrated';

  /// 网络书籍角标过滤状态（参考版键名 explore_filter_state；本批只持久化）
  static const exploreFilterState = 'explore_filter_state';

  // ===== 其他设置页（pref_config_other.xml）=====

  /// 启动时自动刷新书架（默认 false）
  static const autoRefreshBook = 'auto_refresh';

  /// 仅更新已读书籍（默认 false，依赖 auto_refresh 可见）
  static const onlyUpdateRead = 'onlyUpdateRead';

  /// 打开书架书籍时默认进入阅读界面（默认 false）
  static const defaultToRead = 'defaultToRead';

  // ===== [设置批2b-2a] 首页与导航（键名逐字对齐参考版 PreferKey）=====

  /// 显示首页（参考版 PreferKey.showHome，默认 true）
  static const showHome = 'showHome';

  /// 显示发现（参考版 PreferKey.showDiscovery，默认 true）
  static const showDiscovery = 'showDiscovery';

  /// 显示订阅/RSS（参考版 PreferKey.showRss，默认 true）
  static const showRss = 'showRss';

  /// 默认首页（home/bookshelf/explore/rss/my，默认 bookshelf）
  static const defaultHomePage = 'defaultHomePage';

  /// 主导航顺序（逗号分隔 route，参考版 PreferKey.mainNavigationOrder；
  /// 默认 home,bookshelf,explore,rss,my）
  static const mainNavigationOrder = 'mainNavigationOrder';

  /// 主导航自定义图标（未选中态，值为本地图片路径；空=内置图标）
  /// 10 个键名逐字对齐参考版 PreferKey：5 个未选中 + 5 个选中
  static const navIconHome = 'navIconHome';
  static const navIconBookshelf = 'navIconBookshelf';
  static const navIconExplore = 'navIconExplore';
  static const navIconRss = 'navIconRss';
  static const navIconMy = 'navIconMy';
  static const navIconHomeSelected = 'navIconHomeSelected';
  static const navIconBookshelfSelected = 'navIconBookshelfSelected';
  static const navIconExploreSelected = 'navIconExploreSelected';
  static const navIconRssSelected = 'navIconRssSelected';
  static const navIconMySelected = 'navIconMySelected';

  /// 本地密码（用于 Web 服务鉴权）
  static const localPassword = 'localPassword';

  /// 浏览器标识 UserAgent
  static const userAgent = 'userAgent';

  /// Web 服务唤醒锁（仅 Android 生效，默认 false）
  static const webServiceWakeLock = 'webServiceWakeLock';

  /// 默认书籍保存位置
  static const defaultBookTreeUri = 'defaultBookTreeUri';

  /// 源编辑框最大行数（默认 99）
  static const sourceEditMaxLine = 'sourceEditMaxLine';

  /// 图片抗锯齿（默认 false）
  static const antiAlias = 'antiAlias';

  /// 图片解码缓存大小 MB（默认 50，1~1024）
  static const bitmapCacheSize = 'bitmapCacheSize';

  /// 图片文件保留数量（默认 0 = 不清理，0~999；对齐原版
  /// `AppConfig.imageRetainNum`。随备份 `appPrefs` 往返——参考版
  /// `BackupConfig.readPrefKeys` 未收录，任何忽略组合下均恢复）
  static const imageRetainNum = 'imageRetainNum';

  /// 预下载章节数量（默认 10，0~9999）
  static const preDownloadNum = 'preDownloadNum';

  /// 新增书籍默认启用替换净化（默认 true）
  static const replaceEnableDefault = 'replaceEnableDefault';

  /// 退到后台（进程与 Flutter 引擎存活）时仍响应耳机媒体键
  ///
  /// 仅 Android 生效，默认 true（对齐原版 `AppConfig.mediaButtonOnExit`）。
  /// 注意语义是「后台仍响应」而非「退出时中断朗读」；进程或 Flutter 引擎
  /// 销毁后不生效（未做 headless 冷启动拉起）。
  static const mediaButtonOnExit = 'mediaButtonOnExit';

  /// 耳机媒体键启动/恢复朗读（仅 Android 生效，默认 false；
  /// 对齐原版 `AppConfig.readAloudByMediaButton`）
  static const readAloudByMediaButton = 'readAloudByMediaButton';

  /// 朗读时忽略音频焦点（仅 Android 生效，默认 false）
  ///
  /// [设置批5a-1 | 2026-11-04] 入口由「其他设置」迁入「朗读设置 → 常规」，
  /// 键名与消费端（[AudioNotifier]）保持不变。
  static const ignoreAudioFocus = 'ignoreAudioFocus';

  // ===== 朗读设置（设置批5a-1，对齐参考版 ReadAloudConfigContent）=====

  /// 默认朗读界面：`classic`（阅读器经典朗读条）/ `player`（听书播放器）
  ///
  /// 默认 `classic`（对齐参考版默认「经典」）。从阅读器启动朗读时按该值
  /// 决定是否自动进入听书页。
  static const defaultReadAloudInterface = 'defaultReadAloudInterface';

  /// 朗读唤醒锁（仅 Android 生效，默认 false；对齐原版
  /// `PreferKey.readAloudWakeLock` / `AppConfig`，TTS 朗读期间持
  /// PARTIAL_WAKE_LOCK）
  static const readAloudWakeLock = 'readAloudWakeLock';

  /// 退出阅读时继续朗读（默认 false；对齐参考版
  /// `keepReadAloudOnExit`——关闭时退出阅读器即停止本次朗读）
  static const keepReadAloudOnExit = 'keepReadAloudOnExit';

  /// 耳机上一首/下一首键翻章（仅 Android 生效，默认 false；对齐原版
  /// `PreferKey.mediaButtonPerNext`——false 时 TTS 按段落移动）
  static const mediaButtonPerNext = 'mediaButtonPerNext';

  /// 听书播放器背景：`solid`（纯色，默认）/ `transparent`（透明，露出壁纸）
  static const readAloudPlayerBackground = 'readAloudPlayerBackground';

  // ===== 朗读内容分析（设置批5b，对齐参考版 ReadAloudSettings）=====

  /// 内容划分方式：`default`（默认，运行时归一为整段）/ `paragraph`（整段）/
  /// `page`（按阅读器分页）/ `symbols`（按选中标点）。键名对齐参考版
  /// `PreferKey.readAloudContentSplitMode`。
  static const readAloudContentSplitMode = 'readAloudContentSplitMode';

  /// 「按符号」划分选中的标点（存储串，按展示顺序拼接）。
  ///
  /// 空串表示未显式选择 → 运行时回退句末标点 `。！？…`（对齐参考版
  /// `ReadAloudSplitSymbol.sentenceEnds`）。键名对齐参考版
  /// `PreferKey.readAloudContentSplitSymbols`。
  static const readAloudContentSplitSymbols = 'readAloudContentSplitSymbols';

  /// 段落间隔毫秒（0–5000，默认 0；对齐参考版 `ttsParagraphInterval`）
  static const ttsParagraphInterval = 'ttsParagraphInterval';

  /// 章节分片方式：`rule`（规则，默认）/ `rule_with_ai` / `ai_understanding`。
  ///
  /// 本批仅实现规则分片；AI 取值只保留/展示置灰，不参与运行时。
  static const speechAnalysisMode = 'speechAnalysisMode';

  /// AI 推理级别（默认 `OFF`；仅 AI 分片时有意义，本批固定不参与运行时）
  static const speechAnalysisReasoningLevel = 'speechAnalysisReasoningLevel';

  /// 系统 TTS 语速（参考刻度 0–80；1.0x = 5、2.0x = 15、3.0x = 25，
  /// 映射见 `system_tts_service.dart` 的 [ttsSpeechRateFromSpeed]）
  static const ttsSpeechRate = 'ttsSpeechRate';

  /// 系统 TTS 音调（参考刻度 5–20，即 0.5–2.0；默认 10 = 1.0）
  static const ttsPitch = 'ttsPitch';

  /// 系统 TTS 音量（参考刻度 0–100，即 0–1；默认 100）
  static const ttsVolume = 'ttsVolume';

  /// 系统 TTS 引擎包名（空 = 系统默认引擎）
  static const systemTtsEngine = 'systemTtsEngine';

  /// 系统 TTS 音色名（空 = 系统默认音色；完整 locale 经
  /// [systemTtsVoiceLocale] 配套保存）
  static const systemTtsVoice = 'systemTtsVoice';

  /// 系统 TTS 音色 locale（与 [systemTtsVoice] 成对，供 setVoice 精确定位）
  static const systemTtsVoiceLocale = 'systemTtsVoiceLocale';

  // ===== 朗读定时（设置批5c，对齐参考版 ReadAloudTimerSheet）=====

  /// 定时模式：`minute`（分钟倒计时，默认）/ `chapter`（按章停止）
  ///
  /// 键名对齐参考版 `PreferKey.readAloudTimerMode`。两模式互斥；仅保存
  /// 用户设置值用于 Sheet 回显，**不在启动时恢复运行中的倒计时**。
  static const readAloudTimerMode = 'readAloudTimerMode';

  /// 分钟定时预设值（0–180，0 = 关闭）。键名对齐参考版
  /// `PreferKey.ttsTimer`。
  static const readAloudTimerMinutes = 'ttsTimer';

  /// 按章停止预设值（0–50，0 = 关闭；对齐参考版
  /// `PreferKey.readAloudTimerChapters`）
  static const readAloudTimerChapters = 'readAloudTimerChapters';

  /// 分钟到点后是否读完本章再停（默认 false；对齐参考版
  /// `PreferKey.finishCurrentChapterAfterTimer`）
  static const finishCurrentChapterAfterTimer =
      'finishCurrentChapterAfterTimer';

  /// 系统 TTS 合成缓存保留时间（分钟，0–10080，默认 10；0 = 即听即焚）
  ///
  /// 仅作用于 Flutter 侧系统 TTS 缓存目录（`system_tts/*.wav`）；
  /// Rust HTTP TTS 缓存不在本策略内（登记为既有边界）。键名对齐参考版
  /// `PreferKey.audioCacheCleanTime`。
  static const readAloudCacheRetentionMinutes = 'audioCacheCleanTime';

  /// 自动清除过期搜索数据（默认 true）
  static const autoClearExpired = 'autoClearExpired';

  /// 显示添加书架提示（默认 true）
  static const showAddToShelfAlert = 'showAddToShelfAlert';

  /// 自动更新到最佳变种版本（仅 Android 生效，默认 true）
  static const autoUpdateVariant = 'autoUpdateVariant';

  /// 显示漫画界面（默认 true）
  static const showMangaUi = 'showMangaUi';

  /// Web 服务端口（默认 1122，1024~60000）
  static const webPort = 'webPort';

  /// 更新/搜索/下载线程数（默认 16，UI 1~256；批9b-2）
  ///
  /// SharedPreferences 为 UI 真源，保存与启动/恢复时同步 Rust caches
  /// `config:threadCount`（运行期：搜索有效上限 32、批量下载夹逼 1~8，
  /// 且同时只准入 1 本书下载）。
  static const threadCount = 'threadCount';

  /// 文本操作菜单显示应用（仅 Android 生效，默认 true）
  static const processText = 'process_text';

  /// 拦截书源打开浏览器（批39，默认 false）
  ///
  /// 键名逐字对齐参考版 `OtherSettings.blockSourceBrowser`：开启后书源经
  /// `java.openUrl` / `java.showBrowser` / `java.startBrowser` 发起的内置/
  /// 外部浏览器跳转一律拦截并提示（`legado:/yuedu:` 关联导入仍走站内）。
  /// 随 Flutter JSON 备份 `appPrefs` 往返。
  static const blockSourceBrowser = 'blockSourceBrowser';

  // [UI-fix v2.0.5 | 2026-08-08] 注：以下三个日志键与 Android 原版
  // AppConfig 同名，但当前桌面端日志开关真源为 CrashLogService
  // （crash_record_* 键），本组键预留未来对齐 Android AppConfig 用，
  // 暂未接线，请勿与 CrashLogService 键名双轨混用 — Qoder

  /// 记录日志（预留键，暂未接线；当前真源为 CrashLogService 的
  /// crash_record_log 键）
  static const recordLog = 'recordLog';

  /// 记录 HTTP 请求日志（预留键，暂未接线；当前真源为 CrashLogService
  /// 的 crash_record_http_log 键）
  static const recordHttpLog = 'recordHttpLog';

  /// 记录内存堆转储（预留键，暂未接线；当前真源为 CrashLogService
  /// 的 crash_record_heap_dump 键）
  static const recordHeapDump = 'recordHeapDump';

  // ===== 书源管理（BookSourceActivity）=====

  /// 书源列表显示书架书籍数量（对齐原版 `AppConfig.showSourceBookshelfCount`，
  /// `AppConfig.kt:41-43` / `PreferKey.showSourceBookshelfCount`，默认关；
  /// 批31 接线，键名与原版逐字一致，随 Flutter JSON 备份 `appPrefs` 往返）
  static const showSourceBookshelfCount = 'showSourceBookshelfCount';

  // ===== 书架管理（BookshelfManageActivity）=====

  /// 点击书名打开书籍信息（对齐原版 openBookInfoByClickTitle，默认 false）
  static const openBookInfoByClickTitle = 'openBookInfoByClickTitle';

  // ===== RSS 阅读记录（ReadRecordDialog / AppConfig）=====

  /// 记录 RSS 阅读历史（对齐原版 `AppConfig.enableRssReadRecord`，
  /// `AppConfig.kt:631-635`，默认 true；关闭后不新增记录，已有记录保留）
  static const enableRssReadRecord = 'enableRssReadRecord';

  // ===== 检查更新（LocalConfig）=====

  /// 忽略的更新版本号（对齐 LocalConfig.ignoreUpdateVersion）
  static const ignoreUpdateVersion = 'ignoreUpdateVersion';

  /// 上次自动检查更新时间戳（毫秒，对齐原版 LocalConfig.lastCheckUpdate；
  /// 批9a 项5 自动更新「每日最多一次」判定。设备级键，不随备份往返——
  /// 见 RestoreIgnorePrefs.alwaysIgnoreKeys，随备份恢复会让每日判定
  /// 基于旧设备的时间）
  static const lastCheckUpdate = 'lastCheckUpdate';

  // ===== 备份与恢复（pref_config_backup.xml）=====

  /// 本地备份仅保留最新备份文件（默认 true）
  static const onlyLatestBackup = 'onlyLatestBackup';

  /// 打开软件时自动检查新备份（默认 true）
  static const autoCheckNewBackup = 'autoCheckNewBackup';

  // ===== WebDAV 备份族（批40，键名逐字对齐原版 PreferKey）=====

  /// WebDAV 上保留的备份份数（**字符串**偏好；默认 "0" = 不自动清理，
  /// 正整数生效，填 1 即只保留最新一份）。对齐原版
  /// `AppConfig.webDavBackupKeepCount`（`getPrefString(...).toIntOrNull()`）。
  /// 随 Flutter JSON 备份 `appPrefs` 往返。
  static const webDavBackupKeepCount = 'webDavBackupKeepCount';

  /// 导入后自动上传本地书（默认 false，对齐原版
  /// `AppConfig.webDavBookAutoUpload`）。随备份 `appPrefs` 往返。
  static const webDavBookAutoUpload = 'webDavBookAutoUpload';

  /// 自动备份开关（默认 true，对齐原版 `AppConfig.autoBackup`）。
  static const autoBackup = 'autoBackup';

  /// 自动备份同时上传 WebDAV（默认 true，对齐原版
  /// `AppConfig.autoBackupWebDav`）。
  static const autoBackupWebDav = 'autoBackupWebDav';

  /// 自动备份间隔天数（默认 1；读取时 `coerceAtLeast(1)`，对齐原版
  /// `AppConfig.autoBackupIntervalDays`）。
  static const autoBackupIntervalDays = 'autoBackupIntervalDays';

  /// 上次本地备份成功时间（毫秒时间戳，对齐原版 `LocalConfig.lastBackup`）。
  ///
  /// **设备级状态**：原版存于独立 `local` 偏好文件、不随备份往返；我方
  /// 加入 `RestoreIgnorePrefs.alwaysIgnoreKeys` 排除，避免恢复旧备份后
  /// 误触发/抑制自动备份。
  static const lastBackup = 'lastBackup';

  // ===== 阅读设置页（批1a/1b-3，键名对齐参考版 PreferKey）=====

  /// 无目录规则时每章字数（默认 3000，范围 3000..100000，对齐参考版
  /// `ReadConfigViewModel` coerceIn 与 `ReadSettings.maxLengthWithNoToc`）。
  /// SharedPreferences 镜像 + caches `config:maxLengthWithNoToc` 真源
  /// （Rust 本地 TXT 无目录规则时按该字数分章，批1b-3）。
  static const maxLengthWithNoToc = 'maxLengthWithNoToc';

  // ===== 隐私与应用锁（批9b，键名逐字对齐参考版 PreferKey）=====
  //
  // 密码凭据（salt/verifier）由 Rust 存 caches `config:private_password_*`，
  // 不落 SharedPreferences、不随备份往返；本组仅保存策略与开关。
  // 参考版把 `private_enabled` 视为设备级配置（BackupConfig alwaysIgnore），
  // 我方同样加入 `RestoreIgnorePrefs.alwaysIgnoreKeys`：恢复旧备份不得
  // 在目标设备上凭空开启应用锁或覆盖本机验证策略。

  /// 启用私密功能（默认 false；开启前必须已有隐私密码）
  static const privateEnabled = 'private_enabled';

  /// 进入私密分组时验证（默认 true）
  static const privateVerifyOnEnterGroup = 'private_verify_on_enter_group';

  /// 打开私密书籍时验证（默认 true）
  static const privateVerifyOnOpenBook = 'private_verify_on_open_book';

  /// 启动应用时验证（默认 false）
  static const privateVerifyOnAppStart = 'private_verify_on_app_start';

  /// 解锁频率（every_time / app_session / until_background，默认 app_session）
  static const privateUnlockScope = 'private_unlock_scope';

  /// 离开后台宽限秒数（0/30/120/180/300，默认 0；仅 until_background 生效）
  static const privateBackgroundGraceSeconds =
      'private_background_grace_seconds';

  /// 隐私策略键集合（备份恢复忽略与设置页持久化共用）
  static const privatePolicyKeys = <String>{
    privateEnabled,
    privateVerifyOnEnterGroup,
    privateVerifyOnOpenBook,
    privateVerifyOnAppStart,
    privateUnlockScope,
    privateBackgroundGraceSeconds,
  };
}
