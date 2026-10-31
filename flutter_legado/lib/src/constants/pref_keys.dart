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

  /// 基础卡片圆角值 4-28（参考仓 baseCardCornerRadius，默认 16）
  static const baseCardCornerRadius = 'baseCardCornerRadius';

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

  // ===== 其他设置页（pref_config_other.xml）=====

  /// 启动时自动刷新书架（默认 false）
  static const autoRefreshBook = 'auto_refresh';

  /// 仅更新已读书籍（默认 false，依赖 auto_refresh 可见）
  static const onlyUpdateRead = 'onlyUpdateRead';

  /// 打开书架书籍时默认进入阅读界面（默认 false）
  static const defaultToRead = 'defaultToRead';

  /// 显示发现（默认 true）
  static const showDiscovery = 'showDiscovery';

  /// 显示订阅/RSS（默认 true）
  static const showRss = 'showRss';

  /// 默认首页（bookshelf/explore/rss/my）
  static const defaultHomePage = 'defaultHomePage';

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

  /// 图片文件保留数量（默认 100，0~999）
  static const imageRetainNum = 'imageRetainNum';

  /// 预下载章节数量（默认 10，0~9999）
  static const preDownloadNum = 'preDownloadNum';

  /// 新增书籍默认启用替换净化（默认 true）
  static const replaceEnableDefault = 'replaceEnableDefault';

  /// 退出应用时中断朗读（媒体按钮，仅 Android 生效，默认 true）
  static const mediaButtonOnExit = 'mediaButtonOnExit';

  /// 媒体按钮触发朗读（仅 Android 生效，默认 false）
  static const readAloudByMediaButton = 'readAloudByMediaButton';

  /// 朗读时忽略音频焦点（仅 Android 生效，默认 false）
  static const ignoreAudioFocus = 'ignoreAudioFocus';

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
}
