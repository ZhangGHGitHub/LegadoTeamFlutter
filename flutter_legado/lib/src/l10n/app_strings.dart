import 'dart:ui' show Locale, PlatformDispatcher;

/// 简单的国际化字符串管理
class AppStrings {
  static String _locale = 'zh'; // zh 或 en

  static void setLocale(String locale) {
    _locale = locale;
  }

  static String get locale => _locale;

  /// 系统语言 → AppStrings 支持的 zh/en。
  ///
  /// 对齐原版 `AppContextWrapper.getSetLocale` 的 else 分支（未显式选语言时
  /// 跟随系统）：`PlatformDispatcher.instance.locale.languageCode` 为 `zh`
  /// 时取中文，其余语言取英文（英文默认基座，与参考版 values/ 英文同义）。
  ///
  /// [systemLocaleOverride] 仅供测试注入系统 locale（生产路径传 null 即读
  /// `PlatformDispatcher.instance.locale`）。
  static String systemLocale([Locale? systemLocaleOverride]) {
    final locale = systemLocaleOverride ?? PlatformDispatcher.instance.locale;
    final code = locale.languageCode.toLowerCase();
    return code == 'zh' ? 'zh' : 'en';
  }

  /// 启动 locale 映射（批9a 项1 / P3-1）：把 `app_locale` 偏好值归一到
  /// AppStrings 支持的 zh/en。
  ///
  /// 口径与运行中切换（other_settings_screen 的语言选择）一致：
  /// - `system` → 跟随系统语言（[systemLocale]，中文环境 zh、其余 en）；
  /// - `zh` / `en` 直通；
  /// - 非 system/zh/en 的脏值（历史偏好/手工改库）→ `zh` 兜底，不抛异常。
  static String startupLocaleOf(String prefValue, {Locale? systemLocaleOverride}) {
    switch (prefValue) {
      case 'en':
        return 'en';
      case 'zh':
        return 'zh';
      case 'system':
        return systemLocale(systemLocaleOverride);
      default:
        // 未知脏值回落中文（安全侧）
        return 'zh';
    }
  }

  static String _get(String zh, String en) => _locale == 'zh' ? zh : en;

  // 通用
  static String get appTitle => _get('阅读', 'Legado');
  static String get bookshelf => _get('书架', 'Bookshelf');
  static String get search => _get('搜索', 'Search');
  static String get sources => _get('书源', 'Sources');
  static String get settings => _get('设置', 'Settings');
  static String get my => _get('我的', 'My');
  static String get rss => _get('订阅', 'RSS');
  static String get discover => _get('发现', 'Discover');
  static String get confirm => _get('确定', 'OK');
  static String get cancel => _get('取消', 'Cancel');
  static String get save => _get('保存', 'Save');
  static String get delete => _get('删除', 'Delete');
  static String get edit => _get('编辑', 'Edit');
  static String get loading => _get('加载中...', 'Loading...');
  static String get error => _get('错误', 'Error');
  static String get noData => _get('暂无数据', 'No data');
  static String get retry => _get('重试', 'Retry');

  /// 加载失败（对齐 HapeLee LoadMoreFooter error 态，M2）
  static String get loadFailed => _get('加载失败', 'Load failed');
  // 对齐原版 R.string.double_click_exit
  static String get doubleClickExit => _get('再按一次退出程序', 'Press again to exit');

  /// 列表触底提示（对齐原版 R.string.bottom_line）
  static String get bottomLine => _get('我是有底线的', "That's all");

  // 书架
  static String get startReading => _get('开始阅读', 'Start Reading');
  static String get addToBookshelf => _get('加入书架', 'Add to Bookshelf');
  static String get removeFromBookshelf => _get('移除', 'Remove');
  static String get updateToc => _get('更新目录', 'Update TOC');
  static String get searchHint => _get('搜索书名或作者', 'Search by title or author');
  static String get groupByNone => _get('不分组', 'No Group');
  static String get groupBySource => _get('按来源', 'By Source');
  static String get groupByTag => _get('按分组', 'By Tag');
  static String get updateAll => _get('更新目录', 'Update TOC');
  static String get manageBookshelf => _get('书架管理', 'Manage Bookshelf');
  static String get sourceManagement => _get('书源管理', 'Source Management');
  static String get groupByNoneLabel => _get('不分组', 'No Group');
  static String get groupBySourceLabel => _get('按来源分组', 'Group by Source');
  static String get groupByGroupLabel => _get('按分组分组', 'Group by Tag');
  static String get listView => _get('列表视图', 'List View');
  static String get gridView => _get('网格视图', 'Grid View');
  static String get addBook => _get('添加书籍', 'Add Book');
  static String get addLocalBook => _get('添加本地', 'Add Local Book');
  static String get emptyBookshelf => _get('书架还空着，先去搜索书籍或从发现里添加吧！', 'Bookshelf is empty, search or add from discover!');
  static String get loadingBookshelf => _get('加载书架...', 'Loading bookshelf...');
  static String get recentReading => _get('最近阅读', 'Recent Reading');
  static String get allBooks => _get('全部', 'All');
  static String get reading => _get('在读', 'Reading');
  static String get unread => _get('未读', 'Unread');
  static String get unknownChapter => _get('未知章节', 'Unknown Chapter');
  static String get pinToTop => _get('置顶', 'Pin to Top');
  static String get editInfo => _get('编辑信息', 'Edit Info');
  static String get group => _get('分组', 'Group');
  static String get deleteBook => _get('删除书籍', 'Delete Book');
  static String get checkingUpdate => _get('正在检查更新...', 'Checking for updates...');
  static String get selectLocalBook => _get('选择本地书籍文件', 'Select local book file');

  // 书架（阶段 1 抽取：bookshelf_screen / bookshelf_manage_screen）
  static String get selectAll => _get('全选', 'Select all');
  static String get invertSelection => _get('反选', 'Inverse');
  static String get markPrivate => _get('设为私密', 'Mark as private');
  static String get unmarkPrivate => _get('取消私密', 'Remove private mark');
  static String get privateGroup => _get('私密分组', 'Private group');
  static String get verifyAndView => _get('验证并查看', 'Verify and view');
  static String get verifyAndOpen => _get('验证后打开', 'Verify to open');
  static String get verifyToViewGroup => _get('验证后查看分组内容', 'Verify to show the books in this group');
  static String get privateContentMasked =>
      _get('匹配的书籍均为私密内容，验证后查看', 'All matching books are private. Verify to view.');
  static String get noMatchingBooks => _get('未找到匹配的书籍', 'No matching books');
  static String get noMatchingBooksShelf => _get('无匹配书籍', 'No matching books');
  static String get tryOtherKeywords => _get('试试其他关键词', 'Try other keywords');
  static String get addBooksFirst => _get('请先在书架添加书籍', 'Add books to the bookshelf first');
  static String get bookshelfEmpty => _get('书架为空', 'Bookshelf is empty');
  static String get bookGroupMenu => _get('分组菜单', 'Group menu');
  static String get manageGroups => _get('管理分组', 'Manage groups');
  static String get groupManagement => _get('分组管理', 'Group Management');
  static String get selectGroup => _get('选择分组', 'Select group');
  static String get selectGroupTitle => _get('选择分组', 'Select Group');
  static String get moveToGroup => _get('移动到分组', 'Move to group');
  static String get moveToGroupTitle => _get('移动分组', 'Move to Group');
  static String get movedToGroup => _get('已移动到分组', 'Moved to group');
  static String get ungrouped => _get('未分组', 'Ungrouped');
  static String get groupName => _get('分组', 'Group');
  static String get unnamedGroup => _get('未命名分组', 'Unnamed group');
  static String get unnamedBook => _get('未命名书籍', 'Unnamed book');
  static String get unknownAuthor => _get('未知作者', 'Unknown author');
  static String get deleteSourceFile => _get('删除源文件', 'Delete source file');
  static String get deleteCompleted => _get('删除完成', 'Deleted');
  static String get pinned => _get('已置顶', 'Pinned');
  static String get changeSource => _get('换源', 'Change source');
  static String get batchChangeSource => _get('批量换源', 'Batch source switching');
  static String get selectTargetSource => _get('选择目标书源', 'Select target source');
  static String get noAvailableSource => _get('暂无可用书源', 'No sources available');
  static String get noAvailableGroup =>
      _get('暂无可用分组，请先在分组管理创建', 'No groups available. Create one in group management first.');
  static String get noSourceForSelectedBooks => _get(
      '选中书籍无可换源目标（本地书/已是该源）',
      'No alternative source for the selected books (local books or already on that source)');
  static String get noSourceInShelf => _get(
      '当前书架没有使用网络书源的书籍', 'No books using online sources in the bookshelf');
  static String get sourceNotFound => _get('未找到对应书源（可能已删除）', 'Source not found (it may have been deleted)');
  static String get exportAllUsedSources => _get('导出所有使用书源', 'Export all sources in use');
  static String get tapTitleForBookInfo => _get('点击书名打开书籍信息', 'Tap a title to open book info');
  static String get searchBookNameHint => _get('搜索书名', 'Search title');
  static String get searchShelfHint => _get('搜索书架中的书名或作者', 'Search title or author in bookshelf');
  static String get layoutSettings => _get('布局设置', 'Layout settings');
  static String get selectionMode => _get('选择模式', 'Selection Mode');
  static String get remoteBooks => _get('远程书籍', 'Remote Books');
  static String get offlineCache => _get('离线缓存', 'Offline cache');
  static String get exportBookList => _get('导出书单', 'Export Book List');
  static String get importBookList => _get('导入书单', 'Import Book List');
  static String get addUrl => _get('添加网址', 'Add URL');
  static String get addUrlTitle => _get('添加网址', 'Add URL');
  static String get addUrlHint =>
      _get('输入书籍详情页 URL（多行可加多本）', 'Enter book detail page URLs (one per line)');
  static String get addUrlNameHint =>
      _get('书名（可选，无法获取详情时兑底）', 'Title (optional, fallback when details are unavailable)');
  static String get importBookListHint =>
      _get('输入书单 URL 或 JSON 数组', 'Enter a book list URL or JSON array');
  static String get selectFile => _get('选择文件（txt/json）', 'Select file (txt/json)');
  static String get webBook => _get('网页书籍', 'Web book');
  static String get moreActions => _get('更多', 'More');
  static String get exitSelection => _get('退出选择', 'Exit selection');
  static String get exitSearch => _get('退出搜索', 'Exit search');
  static String get backToGroups => _get('返回分组', 'Back to groups');
  static String get batchDownload => _get('批量下载', 'Batch download');
  static String get searchInBookshelf => _get('书架内搜索', 'Search in bookshelf');
  static String get bookTypeNovel => _get('小说', 'Novel');
  static String get bookTypeAudio => _get('音频', 'Audio');
  static String get bookTypeManga => _get('漫画', 'Manga');
  static String get bookTypeFile => _get('文件', 'File');
  static String get bookTypeLocal => _get('本地', 'Local');
  static String get sortNeedsListLayout =>
      _get('手动排序需使用列表布局，已临时切换为列表', 'Manual sorting needs list layout; switched to list temporarily');
  static String get sourceInfoLoadFailed =>
      _get('书源信息读取失败，已按默认方式打开', 'Failed to read source info; opened with defaults');
  static String get emptyBookshelfNoExport =>
      _get('书架为空，无可导出的书单', 'Bookshelf is empty; nothing to export');
  static String get noBooksToUpdate => _get('没有需要更新的书籍', 'No books need updating');
  static String get preparing => _get('准备中...', 'Preparing...');
  static String get localFilePickerHint => _get(
      'iOS 选择器显示全部文件，仅电子书格式（epub/txt/mobi/azw3/azw/pdf/umd/cbz）可导入',
      'iOS picker shows all files; only ebook formats (epub/txt/mobi/azw3/azw/pdf/umd/cbz) can be imported');
  static String get invalidBookListFormat =>
      _get('书单格式不对（应为 URL 或 JSON 数组）', 'Invalid book list format (expected a URL or JSON array)');
  static String get importLabel => _get('导入', 'Import');

  /// 分组内书籍数
  static String bookCount(int count) => _locale == 'zh' ? '$count 本' : '$count book(s)';

  /// 私密状态批量更新提示
  static String privateUpdated(int count) =>
      _locale == 'zh' ? '已更新 $count 本书的私密状态' : 'Private state updated for $count book(s)';

  static String privateUpdateFailed(String reason) =>
      _locale == 'zh' ? '设置私密状态失败：$reason' : 'Failed to set private state: $reason';

  static String verifyToViewGroupNamed(String name) =>
      _locale == 'zh' ? '验证后查看「$name」' : 'Verify to view "$name"';

  static String deleteFailed(String reason) =>
      _locale == 'zh' ? '删除失败：$reason' : 'Delete failed: $reason';

  static String selectedCount(int count) =>
      _locale == 'zh' ? '已选$count本' : '$count selected';

  static String selectedCountWithHidden(int count, int hidden) => _locale == 'zh'
      ? '已选$count本（另有$hidden本未显示，不会删除）'
      : '$count selected ($hidden hidden, not deleted)';

  static String deletedBooks(int count) =>
      _locale == 'zh' ? '已删除 $count 本书籍' : 'Deleted $count book(s)';

  static String deletedBooksWithMissing(int count, int missing) => _locale == 'zh'
      ? '已删除 $count 本书籍（$missing 本已不在书架）'
      : 'Deleted $count book(s) ($missing no longer on the shelf)';

  /// 删除结果 + 源文件未删警告（保留删除数前缀，与旧文案一致）
  static String partialSourceDeleteFailed(String deletedText, String warnings) =>
      _locale == 'zh'
          ? '$deletedText；部分源文件未删除：$warnings'
          : '$deletedText; some source files were not deleted: $warnings';

  static String localBookPersistFailed(String name, String error) => _locale == 'zh'
      ? '$name：本地书持久化失败（$error）'
      : '$name: failed to persist local book ($error)';

  static String importedBooks(int count) =>
      _locale == 'zh' ? '已导入 $count 本书籍' : 'Imported $count book(s)';

  static String importFailed(String detail, String more) =>
      _locale == 'zh' ? '导入失败：$detail$more' : 'Import failed: $detail$more';

  static String updatingProgress(int current, int total, String name) => _locale == 'zh'
      ? '正在更新 $current/$total：$name'
      : 'Updating $current/$total: $name';

  static String tocUpdateDone(int ok, int total, String limitNote) => _locale == 'zh'
      ? '目录更新完成：成功 $ok/$total 本$limitNote'
      : 'TOC update finished: $ok/$total succeeded$limitNote';

  static String tocUpdateLimit(int limit, int skipped) =>
      _locale == 'zh' ? '，限制 $limit 本（已跳过 $skipped 本）' : ' (limited to $limit, $skipped skipped)';

  static String addUrlDone(int ok, int skip, int fail) => _locale == 'zh'
      ? '添加网址完成：成功 $ok，跳过 $skip，失败 $fail'
      : 'Add URL finished: $ok succeeded, $skip skipped, $fail failed';

  static String fetchBookListFailed(String error) =>
      _locale == 'zh' ? '拉取书单失败: $error' : 'Failed to fetch book list: $error';

  static String importBookListDone(int ok, int skip, int fail) => _locale == 'zh'
      ? '书单导入完成：成功 $ok，跳过 $skip，失败 $fail'
      : 'Book list import finished: $ok succeeded, $skip skipped, $fail failed';

  static String batchChangeSourceDone(int success, int total) => _locale == 'zh'
      ? '批量换源完成：成功 $success/$total 本'
      : 'Batch source switch finished: $success/$total';

  static String changeSourceProgress(int done, int total, String name) =>
      _locale == 'zh' ? '换源 $done/$total：$name' : 'Switching $done/$total: $name';

  static String confirmSwitchSource(int count, String source) => _locale == 'zh'
      ? '确定将 $count 本书切换到「$source」吗？'
      : 'Switch $count book(s) to "$source"?';

  static String confirmDeleteBookNamed(String name) =>
      _locale == 'zh' ? '确定要删除《$name》吗？' : 'Delete "$name"?';

  static String confirmDeleteSelectedBooks(int count) =>
      _locale == 'zh' ? '确定要删除选中的 $count 本书吗？' : 'Delete the $count selected book(s)?';

  static String get clear => _get('清除', 'Clear');

  static String get deleteBooksTitle => _get('删除书籍', 'Delete Book');

  static String batchDownloadCount(int count) => _locale == 'zh'
      ? '批量下载 $count 本'
      : 'Batch download $count book(s)';

  static String moveGroupCount(int count) => _locale == 'zh'
      ? '移动分组 $count 本'
      : 'Move $count book(s) to a group';

  static String groupNamesLabel(String names) =>
      _locale == 'zh' ? '分组：$names' : 'Groups: $names';

  static String originLabel(String name) =>
      _locale == 'zh' ? '来源：$name' : 'Source: $name';

  static String exportSourcesFailed(String error) =>
      _locale == 'zh' ? '导出失败：$error' : 'Export failed: $error';

  static String loadGroupsFailed(String error) =>
      _locale == 'zh' ? '获取分组失败: $error' : 'Failed to load groups: $error';

  static String loadSourcesFailed(String error) =>
      _locale == 'zh' ? '获取书源失败: $error' : 'Failed to load sources: $error';

  static String deleteFailedShelf(String error) =>
      _locale == 'zh' ? '删除失败: $error' : 'Delete failed: $error';

  static String pendingUpdate(int count) =>
      _locale == 'zh' ? '待更新 $count' : '$count to update';

  static String visibleCountLabel(int count) =>
      _locale == 'zh' ? ' · 共 $count 本' : ' · $count total';

  static String failureCountSuffix(int count) =>
      _locale == 'zh' ? ' 等 $count 本' : ' and $count more';

  static String selectedCountManage(int count) =>
      _locale == 'zh' ? '已选 $count 本' : '$count selected';

  // 书源
  static String get importSources => _get('导入书源', 'Import Sources');
  static String get exportSources => _get('导出书源', 'Export Sources');
  static String get addSource => _get('添加书源', 'Add Source');
  static String get sourceName => _get('书源名称', 'Source Name');
  static String get sourceUrl => _get('书源地址', 'Source URL');
  static String get sourceType => _get('书源类型', 'Source Type');

  // 设置
  static String get themeMode => _get('主题模式', 'Theme');
  static String get themeSystem => _get('跟随系统', 'System');
  static String get themeLight => _get('浅色', 'Light');
  static String get themeDark => _get('深色', 'Dark');
  static String get language => _get('语言', 'Language');
  static String get langSystem => _get('跟随系统', 'Follow System');
  static String get langChinese => _get('中文', '中文');
  static String get langEnglish => _get('English', 'English');
  static String get backup => _get('备份', 'Backup');
  static String get restore => _get('恢复', 'Restore');
  static String get cloudSync => _get('云同步', 'Cloud Sync');
  static String get clearCache => _get('清除缓存', 'Clear Cache');
  static String get appearanceSettings => _get('外观设置', 'Appearance');
  static String get readingSettings => _get('阅读设置', 'Reading Settings');
  static String get networkSettings => _get('网络设置', 'Network');
  static String get dataManagement => _get('数据管理', 'Data Management');
  static String get otherSettings => _get('其他', 'Other');
  static String get aboutSettings => _get('关于', 'About');
  static String get defaultFontSize => _get('默认字体大小', 'Default Font Size');
  static String get defaultLineHeight => _get('默认行距', 'Default Line Height');
  static String get defaultBgColor => _get('默认背景色', 'Default Background');
  static String get whiteColor => _get('白色', 'White');
  static String get proxySettings => _get('代理设置', 'Proxy Settings');
  static String get noProxy => _get('不使用代理', 'No Proxy');
  static String get requestTimeout => _get('请求超时', 'Request Timeout');
  static String get seconds30 => _get('30 秒', '30 seconds');
  static String get secondsUnit => _get('秒', 's');
  static String get backupData => _get('备份数据', 'Backup Data');
  static String get backupDataDesc => _get('备份书架和书源到本地', 'Backup bookshelf and sources locally');
  static String get restoreData => _get('恢复数据', 'Restore Data');
  static String get restoreDataDesc => _get('从备份文件恢复', 'Restore from backup file');
  static String get clearCacheDesc => _get('清除临时文件和缓存数据', 'Clear temp files and cached data');
  static String get selectTheme => _get('选择主题模式', 'Select Theme Mode');
  static String get backupSuccess => _get('备份成功', 'Backup successful');
  static String get backupFailed => _get('备份失败', 'Backup failed');
  static String get restoreSuccess => _get('恢复成功', 'Restore successful');
  static String get restoreFailed => _get('恢复失败', 'Restore failed');
  static String get pasteBackupJson => _get('粘贴备份 JSON 数据', 'Paste backup JSON data');
  static String get confirmClearCache =>
      _get('确定要清除所有缓存数据吗？', 'Are you sure you want to clear all cached data?');
  static String get cacheCleared => _get('缓存已清除', 'Cache cleared');
  static String get version => _get('版本', 'Version');
  static String get license => _get('开源协议', 'License');
  static String get projectUrl => _get('项目地址', 'Project URL');
  static String get syncNow => _get('立即同步', 'Sync Now');
  static String get autoSync => _get('自动同步', 'Auto Sync');
  static String get autoSyncDesc => _get('定期同步书架数据', 'Periodically sync bookshelf data');
  static String get syncSuccess => _get('同步成功', 'Sync successful');
  static String get saveConfig => _get('保存配置', 'Save Config');
  static String get configSaved => _get('配置已保存', 'Config saved');
  static String get uploadBookshelf => _get('上传书架', 'Upload Bookshelf');
  static String get uploadBookshelfDesc => _get('将本地书架上传到 WebDAV', 'Upload local bookshelf to WebDAV');
  static String get downloadBookshelf => _get('下载书架', 'Download Bookshelf');
  static String get downloadBookshelfDesc =>
      _get('从 WebDAV 下载书架覆盖本地', 'Download bookshelf from WebDAV to overwrite local');
  static String get mergeSync => _get('合并同步', 'Merge Sync');
  static String get mergeSyncDesc => _get('双向合并本地与远程书架', 'Bidirectional merge of local and remote bookshelf');
  static String get webdavServerUrl => _get('WebDAV 服务器 URL', 'WebDAV Server URL');
  static String get username => _get('用户名', 'Username');
  static String get password => _get('密码', 'Password');
  static String get remoteDir => _get('远程目录', 'Remote Directory');
  static String get lastSync => _get('上次同步', 'Last sync');

  // 设置（阶段 1 抽取：settings_home_screen / settings_screen / other_settings_screen）
  static String get appearanceEntry => _get('外观', 'Theme Settings');
  static String get appearanceEntryDesc => _get('主题配色与显示模式', 'Theme colors and display mode');
  static String get advancedEntry => _get('高级', 'Advanced');
  static String get advancedEntryDesc => _get('功能相关的一些设置', 'Miscellaneous settings');
  static String get readingInterfaceEntry => _get('阅读界面', 'Reading Interface Settings');
  static String get readingInterfaceEntryDesc =>
      _get('屏幕/页面控制/阅读偏好', 'Screen, page controls and reading preferences');
  static String get coverSettingsEntry => _get('封面设置', 'Cover Config');
  static String get coverSettingsEntryDesc =>
      _get('默认封面、书名作者、描边与阴影', 'Default cover, title/author, stroke and shadow');
  static String get readAloudEntry => _get('朗读设置', 'Read Aloud Settings');
  static String get readAloudEntryDesc =>
      _get('朗读引擎、音色与播放行为', 'Speak engine, voice and playback behavior');
  static String get backupRestoreEntry => _get('备份与恢复', 'Backup and Restore');
  static String get backupRestoreEntryDesc =>
      _get('WebDav 设置/导入旧版本数据', 'WebDAV settings / import legacy data');
  static String get cacheManagementEntry => _get('缓存管理', 'Cache management');
  static String get cacheManagementEntryDesc =>
      _get('书籍下载任务与缓存进度', 'Book download tasks and cache progress');
  static String get sourcesEntryDesc =>
      _get('新建、导入、编辑或管理书源', 'Create, import, edit or manage book sources');
  static String get autoTasksEntry => _get('定时任务', 'Scheduled Tasks');
  static String get autoTasksEntryDesc =>
      _get('管理按计划执行的 JavaScript 任务', 'Manage scheduled JavaScript tasks');
  static String get privacy => _get('隐私', 'Privacy');
  static String get privacyEntryDesc => _get('应用锁与私密内容', 'App lock and private content');
  static String get aiSettingsEntry => _get('AI 设置', 'AI Settings');
  static String get translationSettingsEntry => _get('翻译设置', 'Translation Settings');
  static String get labSettingsEntry => _get('实验室', 'Lab');
  static String get notSupportedYet => _get('暂未支持', 'Not supported yet');
  static String get aboutEntryDesc => _get('版本、日志与开源许可', 'Version, logs and open-source licenses');
  static String get otherSettingsTitle => _get('其他设置', 'Other Settings');
  static String get mainInterfaceSection => _get('主界面', 'Main interface');
  static String get rulesSection => _get('规则', 'Rules');
  static String get servicesSection => _get('服务与工具', 'Services and tools');
  static String get otherSection => _get('其他', 'Other');
  static String get helpLabel => _get('帮助', 'Help');
  static String get exitLabel => _get('退出', 'Exit');
  static String get confirmExitReading => _get('确定退出阅读吗？', 'Exit reading?');
  static String get selectBookTitle => _get('选择书籍', 'Select book');
  static String get autoRefreshLabel => _get('自动刷新', 'Auto refresh');
  static String get autoRefreshLabelDesc =>
      _get('打开软件时自动更新书籍', 'Update books automatically when the app opens');
  static String get onlyUpdateReadLabel => _get('仅更新已读完', 'Only update finished books');
  static String get onlyUpdateReadLabelDesc =>
      _get('自动刷新时，只更新已读完的书籍', 'When auto refreshing, only update finished books');
  static String get defaultToReadLabel => _get('自动跳转最近阅读', 'Jump to last read');
  static String get defaultToReadLabelDesc => _get('默认打开书架', 'Open the bookshelf by default');
  static String get setLocalPasswordLabel => _get('设置本地密码', 'Set local password');
  static String get localPasswordSummary => _get(
      '本地密码用来对备份的敏感信息加密和解密,如需在不同设备之间同步,本地密码需一致.',
      'The local password encrypts and decrypts sensitive backup data. It must be identical across devices to sync.');
  static String get notSetLabel => _get('未设置', 'Not set');
  static String get isSetLabel => _get('已设置', 'Set');
  static String get userAgentLabel => _get('用户代理', 'User agent');
  static String get defaultLabel => _get('默认', 'Default');
  static String get customHostsLabel => _get('自定义Hosts', 'Custom Hosts');
  static String get domainToIpMapping => _get('域名到IP的映射', 'Domain to IP mapping');
  static String get webServiceWakeLockLabel => _get('Web 服务唤醒锁', 'Web service wake lock');
  static String get bookSaveLocationLabel => _get('书籍保存位置', 'Book save location');
  static String get bookSaveLocationLabelDesc =>
      _get('从其它应用打开的书籍保存位置', 'Save location for books opened from other apps');
  static String get sourceEditMaxLineLabel => _get('源编辑框最大行数', 'Max lines in source editor');
  static String get checkSettingsLabel => _get('校验设置', 'Check settings');
  static String get directLinkUploadRulesLabel => _get('直链上传规则', 'Direct link upload rules');
  static String get directLinkUploadRulesLabelDesc =>
      _get('用于导出书源书单时生成直链 URL', 'Generate direct-link URLs when exporting sources');
  static String get antiAliasLabel => _get('抗锯齿', 'Anti-aliasing');
  static String get antiAliasLabelDesc => _get('绘制图片时抗锯齿', 'Anti-alias when drawing images');
  static String get imageCacheLabel => _get('图片绘制缓存', 'Image draw cache');
  static String get imageCacheMbLabel => _get('图片绘制缓存（MB）', 'Image draw cache (MB)');
  static String get mangaRetainNone => _get('不清理已缓存图片（0=不清理）', 'Do not clear cached images (0 = never clear)');
  static String get mangaRetainCountLabel => _get('漫画保留数量', 'Manga retain count');
  static String get preDownloadLabel => _get('预下载', 'Pre-download');
  static String get preDownloadCountLabel => _get('预下载章节数量', 'Pre-download chapter count');
  static String get replacePurifyDefaultLabel => _get('默认启用替换净化', 'Enable replacement purify by default');
  static String get replacePurifyDefaultLabelDesc =>
      _get('新加入书架的书是否启用替换净化', 'Whether new bookshelf books enable replacement purify');
  static String get headsetKeysAlwaysLabel => _get('全程响应耳机按键', 'Always respond to headset keys');
  static String get headsetKeysAlwaysLabelDesc => _get(
      '退到后台（进程与 Flutter 引擎存活）时生效；结束应用后不生效',
      'Works while in background (process and Flutter engine alive); not after the app is closed');
  static String get headsetKeyReadAloudLabel => _get('耳机按键启动朗读', 'Start read aloud with headset key');
  static String get headsetKeyReadAloudLabelDesc => _get(
      '通过耳机按键来启动朗读（进程被系统回收后不生效）',
      'Start read aloud via headset key (not after the process is killed)');
  static String get autoClearExpiredSearchLabel =>
      _get('自动清除过期搜索数据', 'Auto clear expired search data');
  static String get autoClearExpiredSearchLabelDesc =>
      _get('超过一天的搜索数据', 'Search data older than one day');
  static String get promptAddToShelfOnBackLabel =>
      _get('返回时提示放入书架', 'Prompt to add to bookshelf on back');
  static String get promptAddToShelfOnBackLabelDesc => _get(
      '阅读未放入书架的书籍在返回时提示放入书架',
      'Prompt to add to the bookshelf when leaving a book that is not on it');
  static String get autoUpdateLabel => _get('自动更新', 'Auto update');
  static String get autoUpdateLabelDesc => _get('每天自动检查软件是否更新', 'Check for app updates daily');
  static String get mangaBrowseLabel => _get('漫画浏览', 'Manga browsing');
  static String get videoSettingsLabel => _get('视频设置', 'Video settings');
  static String get videoSettingsLabelDesc =>
      _get('自动播放、全屏播放等配置', 'Autoplay, fullscreen and other options');
  static String get webPortLabel => _get('Web 端口', 'Web port');
  static String get mcpPortLabel => _get('MCP 端口', 'MCP port');
  static String get webSourceTokenLabel => _get('Web 书源访问令牌', 'Web source access token');
  static String get configuredLabel => _get('已配置', 'Configured');

  static String configuredCount(int count) =>
      _locale == 'zh' ? '已配置 $count 条' : '$count entries configured';
  static String get webPortTitle => _get('Web 服务端口', 'Web service port');

  static String get notConfiguredLabel => _get('未配置（域名 → IP 映射）', 'Not configured (domain → IP)');
  static String get clearCacheTitle => _get('清理缓存', 'Clear cache');
  static String get clearCacheSummary => _get('清除章节缓存与书源缓存', 'Clear chapter and source caches');
  static String get clearWebViewDataLabel => _get('清除 WebView 数据', 'Clear WebView data');
  static String get clearWebViewDataLabelDesc =>
      _get('清除内置浏览器所有数据', 'Clear all data of the built-in browser');
  static String get blockSourceBrowserLabel => _get('拦截书源打开浏览器', 'Block sources from opening browsers');
  static String get blockSourceBrowserLabelDesc => _get(
      '开启后书源无法通过 java.startBrowser 等接口弹出浏览器',
      'When enabled, sources cannot pop up browsers via java.startBrowser etc.');
  static String get compressDatabaseLabel => _get('压缩数据库', 'Compress database');
  static String get compressDatabaseLabelDesc => _get('减小数据库文件的大小', 'Reduce the database file size');
  static String get threadCountLabel => _get('更新和搜索线程数（太多会卡顿）', 'Update and search thread count (too many causes lag)');
  static String get threadCountLabelDesc =>
      _get('搜索有效上限 32；离线缓存有效上限 8', 'Effective max 32 for search, 8 for offline cache');
  static String get threadCountShortLabel => _get('线程数量', 'Thread count');
  static String get processTextSearchLabel => _get('文字操作显示搜索', 'Show search in text actions');
  static String get recordLogLabel => _get('记录日志', 'Record log');
  static String get recordLogLabelDesc => _get('记录调试日志', 'Record debug log');
  static String get recordHttpLogLabel => _get('记录 HTTP 请求', 'Record HTTP requests');
  static String get recordHttpLogLabelDesc => _get(
      '在内存中保留最近 50 条已脱敏的请求与响应记录',
      'Keep the latest 50 redacted request/response records in memory');
  static String get recordHeapDumpLabel => _get('记录堆转储', 'Record heap dump');
  static String get recordHeapDumpLabelDesc =>
      _get('当应用发生OOM崩溃时保存堆转储', 'Save a heap dump when the app crashes with OOM');
  static String get localPasswordLabel => _get('本地密码', 'Local password');
  static String get localPasswordLabelHint =>
      _get('用于 Web 服务访问鉴权，留空清除', 'Used for Web service authentication; leave empty to clear');
  static String get browserUserAgentLabel => _get('浏览器标识（UserAgent）', 'Browser user agent');
  static String get browserUserAgentLabelHint =>
      _get('留空使用默认 UserAgent', 'Leave empty to use the default user agent');
  static String get chooseFolderLabel => _get('选择文件夹', 'Select a folder');
  static String get defaultBookSaveLocationLabel =>
      _get('默认书籍保存位置', 'Default book save location');
  static String get jsSourceApiTokenLabel => _get('JS 书源 API Token', 'JS source API token');
  static String get jsSourceApiTokenLabelDesc =>
      _get('用于 JS 书源调用外部 API 的令牌', 'Token used by JS sources to call external APIs');
  static String get tokenSaved => _get('Token 已保存', 'Token saved');
  static String get tokenCleared => _get('已清除 Token', 'Token cleared');
  static String get clearCacheConfirm => _get('清除章节缓存与书源缓存？', 'Clear chapter and source caches?');
  static String get clearLabelShort => _get('清理', 'Clear');
  static String get cacheClearedOk => _get('成功清理缓存', 'Cache cleared successfully');
  static String get clearWebViewConfirm =>
      _get('将清除 WebView Cookie。确定继续吗？', 'WebView cookies will be cleared. Continue?');
  static String get webViewCookiesCleared => _get('WebView Cookie 已清除', 'WebView cookies cleared');
  static String get confirmLabel => _get('确认', 'Confirm');
  static String get compressDatabaseConfirm => _get('压缩数据库？', 'Compress the database?');
  static String get compressingDatabase => _get('正在压缩数据库…', 'Compressing database…');
  static String get nothingToCompress => _get('无需压缩或压缩失败', 'Nothing to compress or compression failed');
  static String get checkSourceConfigLabel => _get('校验书源配置', 'Check source configuration');
  static String get checkSearchLabel => _get('校验搜索', 'Check search');
  static String get checkSearchLabelDesc => _get('搜索关键词并校验结果', 'Search a keyword and verify the result');
  static String get checkTocLabel => _get('校验目录', 'Check TOC');
  static String get checkTocLabelDesc => _get('依赖校验搜索结果', 'Depends on the search check result');
  static String get checkContentLabel => _get('校验正文', 'Check content');
  static String get checkContentLabelDesc => _get('依赖校验目录结果', 'Depends on the TOC check result');
  // 校验摘要用的裸步骤名（不带「校验」前缀；摘要统一加一次前缀，
  // 见 checkItemsSummary。批39 P1-1：摘要曾误用 checkXxxLabel 导致
  // 「校验校验搜索」与英文「Check Check search」）
  static String get checkStepSearch => _get('搜索', 'Search');
  static String get checkStepToc => _get('目录', 'TOC');
  static String get checkStepContent => _get('正文', 'Content');
  static String get checkCaptchaLabel => _get('验证码拦截检测', 'Captcha interception detection');
  static String get checkCaptchaLabelDesc => _get('识别疑似验证码页面并标记', 'Detect and mark suspected captcha pages');
  static String get checkRedirectLabel => _get('重定向检测', 'Redirect detection');
  static String get checkRedirectLabelDesc =>
      _get('识别登录/拦截重定向并标记', 'Detect and mark login/interception redirects');
  static String get mcpPortTitle => _get('MCP 服务端口', 'MCP service port');
  static String get customHostsTitle => _get('自定义 hosts', 'Custom hosts');
  static String get noStepsToCheck => _get('未设置校验步骤', 'No check steps configured');
  static String get configSavedNextCheck =>
      _get('配置已保存，下次校验时生效', 'Saved; takes effect on the next check');
  static String get checkTimeoutSecondsLabel => _get('校验超时（秒）', 'Check timeout (seconds)');
  static String get searchKeywordLabel => _get('搜索关键词', 'Search keyword');
  static String get checkTimeoutEmpty => _get('超时时间不能为空', 'Timeout cannot be empty');
  static String get checkTimeoutPositive =>
      _get('超时时间必须大于 0 秒', 'Timeout must be greater than 0 seconds');
  // 书源校验完成提示（批39 审查 P2-3：文案须与真实写回行为一致——
  // 失效源按原因写入各自分组，成功校验还会清掉旧失效分组，
  // 不再有「统一归入『失效』分组」这回事）
  static String checkDoneInvalid(int count) => _locale == 'zh'
      ? '校验完成：$count 个书源失效（已按原因写入分组）'
      : 'Check complete: $count source(s) failed (written to groups by cause)';
  static String get checkDoneAllOk => _get('校验完成：全部书源可用', 'Check complete: all sources usable');
  static String checkCancelled(int count) => _locale == 'zh'
      ? '已取消校验（完成 $count 个失效）'
      : 'Check cancelled ($count failure(s) so far)';
  static String get saveTokenDesc => _get(
      'MCP、纯 JS、书源写入、搜索和调试接口均需要',
      'Required by MCP, pure JS, source writing, search and debug APIs');
  static String get webServiceLabel => _get('Web 服务', 'Web service');
  static String get mcpServiceLabel => _get('MCP 服务', 'MCP service');
  static String get aiChatLabel => _get('AI 聊天', 'AI Chat');
  static String get bookmarksLabel => _get('书签', 'Bookmarks');
  static String get allBookmarksLabel => _get('所有书签', 'All bookmarks');
  static String get readRecordLabel => _get('阅读记录', 'Reading record');
  static String get readTimeRecordLabel => _get('阅读时间记录', 'Reading time record');
  static String get fileManagementLabel => _get('文件管理', 'File management');
  static String get fileManagementLabelDesc =>
      _get('管理私有文件夹的文件', 'Manage files in the private folder');
  static String get aboutLabel => _get('关于', 'About');
  static String get replacePurifyLabel => _get('替换净化', 'Replacement');
  static String get replacePurifyLabelDesc => _get('配置替换净化规则', 'Configure replacement rules');
  static String get txtTocRulesLabel => _get('TXT 目录规则', 'TXT TOC rules');
  static String get txtTocRulesLabelDesc => _get('配置 TXT 目录规则', 'Configure TXT TOC rules');
  static String get dictRulesLabel => _get('字典规则', 'Dictionary rules');
  static String get dictRulesLabelDesc =>
      _get('管理字典规则，查询词典释义', 'Manage dictionary rules and look up definitions');
  static String get highlightRulesLabel => _get('高亮标签规则', 'Highlight rules');
  static String get highlightRulesLabelDesc => _get('自动高亮标注规则', 'Auto highlight rules');
  static String get runScheduledTasksLabel => _get('运行定时任务', 'Run scheduled tasks');
  static String get runScheduledTasksLabelDesc => _get(
      '重启后保留计划；Android 可能延后实际执行时间',
      'Schedules persist after restart; Android may delay execution');
  static String get settingsEntryDesc =>
      _get('外观 / 高级 / 阅读界面 / 备份 / 缓存', 'Theme / Advanced / Reader / Backup / Cache');
  static String get copyAddressLabel => _get('复制地址', 'Copy address');
  static String get openInBrowserLabel => _get('在浏览器中打开', 'Open in browser');
  static String get addressCopied => _get('已复制访问地址', 'Access address copied');
  static String get cannotOpenBrowser => _get('无法打开浏览器', 'Cannot open browser');
  static String get browserSourceHint => _get('用浏览器写源或看书', 'Write sources or read books in a browser');
  static String get bookmarkIncomplete => _get('书签信息不完整，无法打开', 'Bookmark data incomplete; cannot open');
  static String get bookNotOnShelf => _get('该书已不在书架', 'This book is no longer on the bookshelf');
  static String get webServiceNotifyMissing => _get(
      '通知权限未授予：Web 服务前台通知不可见（局域网访问不受影响）',
      'Notification permission not granted: Web service foreground notification is invisible (LAN access unaffected)');
  static String get webServiceBackgroundHint =>
      _get('后台保活不可用，请保持 App 打开', 'Background keep-alive unavailable; keep the app open');
  static String get webServiceNotifyHint =>
      _get('通知权限未授予，前台通知不可见', 'Notification permission not granted; foreground notification invisible');
  static String get mcpServiceStopped =>
      _get('独立 MCP 服务已停止', 'Standalone MCP service stopped');
  static String get mcpPortSavedRestart =>
      _get('端口已保存，重启 Web 服务后生效', 'Port saved; takes effect after restarting the Web service');
  static String get mcpPortSavedSyncFailed => _get(
      '端口已保存（引擎同步失败，重启应用后生效）',
      'Port saved (engine sync failed; takes effect after restarting the app)');
  static String get threadCountSaved =>
      _get('线程数已保存，下次搜索/下载生效', 'Thread count saved; applies to the next search/download');
  static String get threadCountSavedSyncFailed => _get(
      '线程数已保存（引擎同步失败，重启应用后生效）',
      'Thread count saved (engine sync failed; applies after restart)');
  static String get customHostsCleared => _get('自定义 hosts 已清除', 'Custom hosts cleared');
  static String get invalidJsonNotSaved => _get('非法 JSON，未保存', 'Invalid JSON; not saved');
  static String get hostsMustBeJsonObject =>
      _get('须为 JSON 对象（域名 → IP），未保存', 'Must be a JSON object (domain → IP); not saved');
  static String get portRangeHint => _get('端口区间 1024~65530，0 表示停止', 'Port range 1024~65530; 0 means stop');
  static String get portRangeHintShort => _get('1024 ~ 65530，0 停止', '1024 ~ 65530, 0 to stop');
  static String numberRangeHint(int min, int max) =>
      _locale == 'zh' ? '请输入 $min ~ $max 之间的数字' : 'Enter a number between $min and $max';

  static String get stepTimeoutHint =>
      _get('单个校验步骤的超时时间', 'Timeout for each check step');

  static String get nonNegativeNumberHint =>
      _get('请输入非负数字（0 表示停止）', 'Enter a non-negative number (0 to stop)');
  static String get mcpStandalonePortDesc =>
      _get('独立 MCP 服务端口；', 'Standalone MCP service port (default 1236 as upstream);');
  static String get mcpStandalonePortDesc2 => _get(
      '留空或 0 停止独立服务，Web 端 /mcp/* 不受影响。',
      'Leave empty or 0 to stop the standalone service; Web /mcp/* is unaffected.');
  static String get customHostsJsonHint => _get(
      'JSON 对象格式：{"域名": "IP"} 或 {"域名": ["IP1","IP2"]}；',
      'JSON object format: {"domain": "IP"} or {"domain": ["IP1","IP2"]};');
  static String get customHostsSaveHint => _get(
      '保存后即时生效，空内容清除并恢复系统 DNS。',
      'Takes effect immediately; empty content clears and restores system DNS.');
  static String get mcpTokenRequiredHint => _get(
      '需先配置「Web 书源访问令牌」（设置 → 高级 → 其他设置）',
      'Configure the Web source access token first (Settings → Advanced → Other Settings)');
  static String get mcpTokenProtectedDesc =>
      _get('带令牌保护的书源开发工具', 'Token-protected source development tools');
  static String get processTextMenuUnsupported => _get(
      '当前构建未接入系统文字操作菜单，开关不可用',
      'This build has no system text action menu; the toggle is unavailable');
  static String get processTextMenuSystemLimited =>
      _get('系统限制，文字操作菜单设置未生效', 'System restriction; the text action menu setting did not take effect');
  static String get processTextMenuLabelNoSuffix =>
      _get('长按文字在操作菜单中显示阅读·搜索', 'Show Read/Search in the text action menu on long press');
  static String get androidOnlyLabel => _get('仅 Android 生效', 'Android only');
  static String get defaultMineLabel => _get('默认：我的', 'Default: My');

  static String saveFailedMsg(String error) =>
      _locale == 'zh' ? '保存失败：$error' : 'Save failed: $error';

  static String copyAddressFailedMsg(String error) =>
      _locale == 'zh' ? '复制地址失败: $error' : 'Failed to copy address: $error';

  static String webServiceStartUnknown(String error) => _locale == 'zh'
      ? 'Web 服务启动失败: 无法确认服务状态（$error）'
      : 'Failed to start Web service: cannot confirm status ($error)';

  static String webServiceStartBadStatus(String status) => _locale == 'zh'
      ? 'Web 服务启动失败: 服务状态异常（$status）'
      : 'Failed to start Web service: unexpected status ($status)';

  static String webServiceToggleFailed(String error) =>
      _locale == 'zh' ? 'Web 服务切换失败: $error' : 'Failed to toggle Web service: $error';

  static String mcpServiceToggleFailed(String error) =>
      _locale == 'zh' ? 'MCP 服务切换失败: $error' : 'Failed to toggle MCP service: $error';

  static String openBookFailed(String error) =>
      _locale == 'zh' ? '打开书籍失败：$error' : 'Failed to open book: $error';

  static String currentPort(int port) =>
      _locale == 'zh' ? '当前端口 $port' : 'Current port: $port';

  static String currentPortStopped(int port) =>
      _locale == 'zh' ? '当前端口 $port（已停止）' : 'Current port: $port (stopped)';

  static String currentImageCache(int mb) =>
      _locale == 'zh' ? '当前最大缓存 $mb MB' : 'Current max cache: $mb MB';

  static String mangaRetainSummary(int count) =>
      _locale == 'zh' ? '保留已读章节数量 $count' : 'Retain $count read chapters';

  static String preDownloadSummary(int count) =>
      _locale == 'zh' ? '预先下载 $count 章正文' : 'Pre-download $count chapters of content';

  static String mcpPortSaved(int port) => _locale == 'zh'
      ? 'MCP 端口已保存：$port（独立服务已重启）'
      : 'MCP port saved: $port (standalone service restarted)';

  static String mcpPortSaveFailed(String error) =>
      _locale == 'zh' ? 'MCP 端口设置失败: $error' : 'Failed to set MCP port: $error';

  static String replacePurifySyncFailed(String error) => _locale == 'zh'
      ? '替换净化配置同步失败：$error'
      : 'Failed to sync replacement settings: $error';

  static String prefsSavedNetworkSyncFailed(String error) => _locale == 'zh'
      ? '已保存偏好，但同步网络层失败：$error'
      : 'Preference saved, but network layer sync failed: $error';

  static String customHostsSaved(int count) =>
      _locale == 'zh' ? '自定义 hosts 已保存（$count 条）' : 'Custom hosts saved ($count entries)';

  static String customHostsSaveFailed(String error) => _locale == 'zh'
      ? '自定义 hosts 保存失败: $error'
      : 'Failed to save custom hosts: $error';

  static String customHostsClearFailed(String error) => _locale == 'zh'
      ? '自定义 hosts 清除失败: $error'
      : 'Failed to clear custom hosts: $error';

  static String compressDoneFreed(String freed) =>
      _locale == 'zh' ? '压缩完成，释放 $freed' : 'Compressed, freed $freed';

  static String compressFailed(String error) =>
      _locale == 'zh' ? '压缩失败: $error' : 'Compression failed: $error';

  static String clearFailed(String error) =>
      _locale == 'zh' ? '清理失败：$error' : 'Clear failed: $error';

  static String webViewClearFailed(String error) =>
      _locale == 'zh' ? '清除失败：$error' : 'Clear failed: $error';

  /// 列表连接分隔符：中文用顿号，英文用逗号加空格。
  ///
  /// 批39 P1-1：此前摘要里写死 `'、'`，英文 locale 下输出
  /// `Check Search、TOC、Content` 混排。
  static String get listSeparator => _locale == 'zh' ? '、' : ', ';

  /// 校验步骤摘要（前缀「校验/Check」只加一次，[items] 传入裸步骤名，
  /// 如 checkStepSearch）。
  static String checkItemsSummary(List<String> items) => _locale == 'zh'
      ? '校验${items.join(listSeparator)}'
      : 'Check ${items.join(listSeparator)}';

  static String timeoutItemSummary(int seconds, String item) =>
      _locale == 'zh' ? '超时 $seconds秒 · $item' : 'Timeout ${seconds}s · $item';

  static String mcpPortSubtitle(int port) => _locale == 'zh'
      ? '端口 $port（带令牌保护的书源开发工具）'
      : 'Port $port (token-protected source dev tools)';

  static String webServiceAddressLocal(String address) =>
      _locale == 'zh' ? '$address（本机）' : '$address (this device)';

  static String processTextMenuLabel(String suffix) => _locale == 'zh'
      ? '长按文字在操作菜单中显示阅读·搜索（$suffix）'
      : 'Show Read/Search in the text action menu on long press ($suffix)';

  // 搜索
  static String get searchBookHint => _get('搜索书名、作者...', 'Search by title, author...');
  static String get searching => _get('搜索中...', 'Searching...');
  static String get noResults => _get('未找到相关书籍', 'No books found');
  static String get noResultsHint => _get('换个关键词试试，或检查书源是否启用', 'Try different keywords, or check if sources are enabled');
  static String get searchBooks => _get('搜索书籍', 'Search Books');
  static String get searchBooksHint => _get('输入书名或作者名开始搜索', 'Enter a title or author to start searching');
  static String get searchHistory => _get('搜索历史', 'Search History');
  static String get clearHistory => _get('清空', 'Clear');
  static String get author => _get('作者', 'Author');
  static String get source => _get('来源', 'Source');
  static String get chapters => _get('章', 'chapters');
  static String get addedToBookshelf => _get('已加入书架', 'Added to bookshelf');

  // 搜索（阶段 1 抽取：search_screen / _builders / _scope_sheet）
  static String get searchScope => _get('搜索范围', 'Search scope');
  static String get searchScopeGroup => _get('分组', 'Groups');
  static String get searchScopeSource => _get('书源', 'Book sources');
  static String get searchSourceHint => _get('搜索书源', 'Search book sources');
  static String get noMatchingSource => _get('无匹配书源', 'No matching sources');
  static String get noGroupedSource => _get('无分组书源', 'No grouped sources');
  static String get allSources => _get('全部书源', 'All Sources');
  static String get currentSource => _get('当前书源', 'Current source');
  static String get designatedSource => _get('指定书源', 'Specified source');
  static String get searchResultFilter => _get('搜索结果过滤', 'Filter search results');
  static String get searchResultFilterOn =>
      _get('搜索结果过滤（已开启）', 'Filter search results (on)');
  static String get preciseSearch => _get('精准搜索', 'Precise search');
  static String get markReadBooks => _get('标识读过的书籍', 'Mark books as read');
  static String get stopSearch => _get('停止搜索', 'Stop search');
  static String get loadNextPage => _get('加载下一页', 'Load next page');
  static String get copyAllFailures => _get('复制全部失败详情', 'Copy all failure details');
  static String get noMatchingHistory => _get('无匹配的历史关键词', 'No matching keywords');
  static String get clearSearchHistory => _get('清空搜索历史', 'Clear search history');
  static String get confirmClearSearchHistory => _get(
      '确定要清空所有搜索历史吗？', 'Are you sure you want to clear all search history?');
  static String get searchResultEmpty => _get('搜索结果为空', 'No search results');
  static String get disablePreciseSearch => _get('关闭精准搜索', 'Disable precise search');
  static String get switchToAllGroups => _get('切换全部分组', 'Switch to all groups');
  static String get resultFilterTitle => _get('搜索结果屏蔽词', 'Search result blocked words');
  static String get resultFilterDesc => _get(
      '每行一个普通文本，匹配书名、作者或分类标签，忽略英文字母大小写',
      'One plain text per line, matching book title, author or category tags, case-insensitive');
  static String get resultFilterHint => _get('屏蔽词（每行一个）', 'Blocked words (one per line)');
  static String get noAlbum => _get('暂无专辑', 'No albums');
  static String get noIntro => _get('暂无简介', 'No summary');
  static String get searchScopeLabel => _get('搜索范围', 'Search scope');
  static String get searchBookKey => _get('搜索书名、作者', 'Search book name/author');
  static String get log => _get('日志', 'Log');

  /// 搜索进度胶囊（对齐参考版「结果 N · 进度 X/Y」）
  static String searchProgress(int resultCount, int searched, int total) =>
      _locale == 'zh'
          ? '结果 $resultCount · 进度 $searched/$total'
          : 'Results $resultCount · Progress $searched/$total';

  /// 有书源要求登录时的会话级轻提示
  static String loginRequiredToast(int count) => _locale == 'zh'
      ? '$count 个书源需要登录，请先在书源菜单中登录后重试'
      : '$count source(s) require login. Sign in from the source menu and retry.';

  /// 失败书源横幅：单条显示具体错误
  static String searchFailureSingle(String error) =>
      _locale == 'zh' ? '书源搜索失败：$error' : 'Source search failed: $error';

  /// 失败书源横幅：多条显示计数
  static String searchFailureMultiple(int count) => _locale == 'zh'
      ? '$count 个书源搜索失败，点击展开'
      : '$count sources failed. Tap to expand.';

  /// 已复制失败详情提示
  static String copiedFailureDetails(int count) => _locale == 'zh'
      ? '已复制 $count 条书源失败详情'
      : 'Copied $count failure detail(s)';

  /// 已选分组数（范围 chip）
  static String selectedGroupCount(int count) =>
      _locale == 'zh' ? '$count 分组' : '$count group(s)';

  /// 最新章节行（搜索结果项）
  static String latestChapter(String title) =>
      _locale == 'zh' ? '最新：$title' : 'Latest: $title';

  /// 书源列表加载失败提示
  static String sourceLoadFailed(String error) =>
      _locale == 'zh' ? '书源加载失败: $error' : 'Failed to load sources: $error';

  /// 删除单条历史关键词后的提示
  static String deletedKeyword(String keyword) =>
      _locale == 'zh' ? '已删除「$keyword」' : 'Deleted "$keyword"';

  /// 空结果引导：关闭精准搜索
  static String emptyScopeDisablePrecise(String scope) => _locale == 'zh'
      ? '$scope分组搜索结果为空，是否关闭精准搜索？'
      : 'No results in group $scope. Disable precise search?';

  /// 空结果引导：切换全部分组
  static String emptyScopeSwitchAll(String scope) => _locale == 'zh'
      ? '$scope分组搜索结果为空，是否切换到全部分组？'
      : 'No results in group $scope. Switch to all groups?';

  // 阅读
  static String get fontSize => _get('字体大小', 'Font Size');
  static String get lineHeight => _get('行距', 'Line Height');
  static String get flipMode => _get('翻页模式', 'Flip Mode');
  static String get scrollMode => _get('上下滚动', 'Scroll');
  static String get slideMode => _get('左右滑动', 'Slide');
  static String get simulateMode => _get('仿真翻页', 'Simulate');
  static String get noneMode => _get('无动画', 'None');
  static String get coverMode => _get('覆盖', 'Cover');
  static String get loadingChapter => _get('加载章节...', 'Loading chapter...');
  static String get noContent => _get('暂无内容', 'No content');
  static String get catalog => _get('目录', 'Catalog');
  static String get nightMode => _get('夜间', 'Night');
  static String get readAloud => _get('朗读', 'Read Aloud');
  static String get interfaceSetting => _get('界面', 'Interface');
  static String get readingSettingsTitle => _get('阅读设置', 'Reading Settings');
  static String get fontSizeLabel => _get('字体大小', 'Font Size');
  static String get fontSmall => _get('小', 'S');
  static String get fontLarge => _get('大', 'L');
  static String get lineHeightLabel => _get('行距', 'Line Height');
  static String get bgColor => _get('背景色', 'Background');
  static String get flipModeLabel => _get('翻页模式', 'Flip Mode');
  static String get previousChapter => _get('上一章', 'Previous');
  static String get nextChapter => _get('下一章', 'Next');
  static String get noChapters => _get('暂无章节', 'No chapters');

  // 阅读器（阶段 1 抽取：reader_screen / reader_config_panel / reader_menu_system_panel）
  static String get addToShelfTitle => _get('放入书架', 'Add to Bookshelf');
  static String get addToShelfFailedNoReason => _get('加入书架失败', 'Failed to add to bookshelf');
  static String get readAloudNoBook => _get('无法启动朗读：未打开书籍', 'Cannot start read aloud: no book opened');
  static String get bookmarkNoBook => _get('无法添加书签：未打开书籍', 'Cannot add bookmark: no book opened');
  static String get autoChangeSourceNoSource =>
      _get('自动换源：无可用替代书源', 'Auto source switch: no alternative source available');
  static String get tapActionNone => _get('无操作', 'None');
  static String get tapActionPrevPage => _get('上一页/章', 'Previous page/chapter');
  static String get tapActionNextPage => _get('下一页/章', 'Next page/chapter');
  static String get tapActionToggleControls => _get('切换工具栏', 'Toggle toolbars');
  static String get tapActionOpenCatalog => _get('打开目录', 'Open catalog');
  static String get defaultFont => _get('默认字体', 'Default font');
  static String get pageMargins => _get('页面边距', 'Page margins');
  static String get pageMarginsDesc =>
      _get('页眉 / 正文 / 页脚四向边距', 'Header / body / footer margins on all sides');
  static String get advancedReaderSettings => _get('高级阅读设置', 'Advanced reader settings');
  static String get readingTipInfo => _get('阅读提示信息', 'Reading tip info');
  static String get readingTipInfoDesc =>
      _get('页眉页脚提示项与标题样式', 'Header/footer tips and title style');
  static String get toolbarStyle => _get('工具栏样式', 'Toolbar style');
  static String get palette => _get('调色板', 'Palette');
  static String get colorSource => _get('颜色来源', 'Color source');
  static String get seedColor => _get('种子色', 'Seed color');
  static String get customThemeColor => _get('自定义主题色', 'Custom theme color');
  static String get seedColorDay => _get('种子色（日）', 'Seed color (day)');
  static String get seedColorNight => _get('种子色（夜）', 'Seed color (night)');
  static String get backgroundColorDay => _get('背景颜色（日）', 'Background color (day)');
  static String get backgroundColorNight => _get('背景颜色（夜）', 'Background color (night)');
  static String get accentColorDay => _get('强调色（日）', 'Accent color (day)');
  static String get accentColorNight => _get('强调色（夜）', 'Accent color (night)');
  static String get containerColorDay => _get('容器颜色（日）', 'Container color (day)');
  static String get containerColorNight => _get('容器颜色（夜）', 'Container color (night)');
  static String get textColorDay => _get('文字颜色（日）', 'Text color (day)');
  static String get textColorNight => _get('文字颜色（夜）', 'Text color (night)');
  static String get brightnessControl => _get('亮度调节控件', 'Brightness control');
  static String get notShown => _get('不显示', 'Hidden');
  static String get horizontal => _get('横排', 'Horizontal');
  static String get vertical => _get('竖排', 'Vertical');
  static String get brightnessBarPosition => _get('亮度条位置', 'Brightness bar position');
  static String get leftSide => _get('左侧', 'Left');
  static String get rightSide => _get('右侧', 'Right');
  static String get showBorder => _get('显示边框', 'Show border');
  static String get showBorderDesc =>
      _get('顶栏下边线 / 底栏整框', 'Top bar bottom line / bottom bar full frame');
  static String get borderWidth => _get('边框宽度', 'Border width');
  static String get borderColorDay => _get('边框颜色（日）', 'Border color (day)');
  static String get borderColorNight => _get('边框颜色（夜）', 'Border color (night)');
  static String get blurRadius => _get('模糊半径', 'Blur radius');
  static String get blurOpacity => _get('模糊透明度', 'Blur opacity');
  static String get blurBaseDay => _get('模糊底色（日）', 'Blur base color (day)');
  static String get blurBaseNight => _get('模糊底色（夜）', 'Blur base color (night)');
  static String get dayNightColorHint =>
      _get('日间/夜间颜色分别用于对应主题', 'Day/night colors apply to the corresponding themes');
  static String get showIconLabels => _get('显示图标文字', 'Show icon labels');
  static String get showIconLabelsDesc =>
      _get('图标下方显示按钮名称', 'Show button names below icons');
  static String get iconContainerStyle => _get('图标容器样式', 'Icon container style');
  static String get iconsPerRow => _get('每行图标数', 'Icons per row');
  static String get iconRows => _get('图标行数', 'Icon rows');
  static String get bottomBarRadius => _get('底栏圆角', 'Bottom bar corner radius');
  static String get floatingBottomBar => _get('浮动底栏', 'Floating bottom bar');
  static String get floatingBottomBarDesc =>
      _get('四周留边；关闭后贴底全宽', 'Margins on all sides; off = full width at bottom');
  static String get bottomBarBlur => _get('底栏模糊', 'Bottom bar blur');
  static String get translucentBlurDesc =>
      _get('半透明背景 + 背景模糊', 'Translucent background + background blur');
  static String get blurStyle => _get('模糊风格', 'Blur style');
  static String get liquidGlassBottomBar => _get('液态玻璃底栏', 'Liquid glass bottom bar');
  static String get liquidGlassBottomBarDesc =>
      _get('模糊 + 高光描边 + 镜面渐变（近似）', 'Blur + highlight stroke + mirror gradient (approximate)');
  static String get liquidGlassButtons => _get('液态玻璃按钮', 'Liquid glass buttons');
  static String get liquidGlassBottomBarButtonsDesc =>
      _get('底栏图标按钮半透明高光（近似）', 'Translucent highlight on bottom bar icon buttons (approximate)');
  static String get titleCapsuleLayout => _get('标题胶囊布局', 'Title capsule layout');
  static String get titleCapsuleLayoutDesc =>
      _get('返回键右侧显示书名 + 章名胶囊', 'Show title + chapter capsule right of the back button');
  static String get titleDisplayMode => _get('标题显示方式', 'Title display mode');
  static String get compactTitle => _get('紧凑标题', 'Compact title');
  static String get compactTitleDesc =>
      _get('顶栏只保留「更多」，其余动作移入菜单', 'Keep only More in the top bar; move other actions into the menu');
  static String get topBarBlur => _get('顶栏模糊', 'Top bar blur');
  static String get liquidGlassTopBarButtonsDesc =>
      _get('顶栏图标按钮半透明高光（近似）', 'Translucent highlight on top bar icon buttons (approximate)');
  static String get mergeTopBarButtons => _get('合并顶栏按钮', 'Merge top bar buttons');
  static String get mergeTopBarButtonsDesc =>
      _get('将顶栏操作按钮合并为一个胶囊', 'Merge top bar actions into a single capsule');
  static String get restoreNightDefaults => _get('恢复夜间默认', 'Restore night defaults');
  static String get restoreDayDefaults => _get('恢复日间默认', 'Restore day defaults');
  static String get barFollowSystem => _get('跟随系统', 'Follow system');
  static String get barFollowReadingBg => _get('跟随阅读背景', 'Follow reading background');
  static String get barCustom => _get('自定义', 'Custom');
  static String get iconStylePlain => _get('无底衬', 'No backing');
  static String get iconStyleTint => _get('色调', 'Tint');
  static String get iconStyleOutline => _get('描边', 'Outline');
  static String get titleModeTopBar => _get('顶栏显示', 'Show in top bar');
  static String get titleModeNewLine => _get('另起一行', 'New line');
  static String get titleModeChapterOnly => _get('仅章节', 'Chapter only');
  static String get titleModeHidden => _get('不显示', 'Hidden');
  static String get globalSection => _get('全局', 'Global');
  static String get bottomBarLayout => _get('底栏布局', 'Bottom bar layout');
  static String get topBarLayout => _get('顶栏布局', 'Top bar layout');
  static String get defaultLabelShort => _get('默认', 'Default');

  /// 加入书架失败（带原因）
  static String addToShelfFailed(String error) =>
      _locale == 'zh' ? '加入书架失败：$error' : 'Failed to add to bookshelf: $error';

  static String addToShelfConfirm(String name) =>
      _locale == 'zh' ? '是否将《$name》放入书架？' : 'Add "$name" to the bookshelf?';

  static String globalPageIndicator(int page, int total) =>
      _locale == 'zh' ? '全局页 $page / $total' : 'Global page $page / $total';

  static String bookmarkAdded(String chapter) =>
      _locale == 'zh' ? '已添加书签：$chapter' : 'Bookmark added: $chapter';

  static String bookmarkAddFailed(String error) =>
      _locale == 'zh' ? '添加书签失败：$error' : 'Failed to add bookmark: $error';

  static String autoChangeSourceDone(String source) => _locale == 'zh'
      ? '章节加载失败，已自动换源：$source'
      : 'Chapter failed to load; switched source to $source';

  static String autoChangeSourceFailed(String error) =>
      _locale == 'zh' ? '自动换源失败: $error' : 'Auto source switch failed: $error';

  // 听书
  static String get audioPlayer => _get('听书', 'Audio');
  static String get play => _get('播放', 'Play');
  static String get pause => _get('暂停', 'Pause');
  static String get prevChapterAudio => _get('上一章', 'Previous');
  static String get nextChapterAudio => _get('下一章', 'Next');

  // ============== L10N 阶段 2：主题 / 朗读 / WebDAV / 订阅源 / 书源编辑 ==============
  static String get launcherIcon1 => _get('图标 1', 'Icon 1');
  static String get launcherIcon2 => _get('图标 2', 'Icon 2');
  static String get launcherIcon3 => _get('图标 3', 'Icon 3');
  static String get launcherIcon4 => _get('图标 4', 'Icon 4');
  static String get launcherIcon5 => _get('图标 5', 'Icon 5');
  static String get launcherIcon6 => _get('图标 6', 'Icon 6');
  static String get fontColorDynamicHint => _get('与动态取色同时使用时可能影响对比度', 'May affect contrast when used with dynamic color');
  static String get topBarStylePlain => _get('平面', 'Plain');
  static String get topBarStyleTonal => _get('Tonal（默认）', 'Tonal (default)');
  static String get topBarStyleGlass => _get('玻璃', 'Glass');
  static String get topBarStyleLiquidGlass => _get('液态玻璃', 'Liquid glass');
  static String get topBarButtonStyle => _get('顶栏按钮样式', 'Top Bar Button Style');
  static String get topBarOpacity => _get('顶栏不透明度', 'Top Bar Opacity');
  static String get bottomBarOpacity => _get('底栏不透明度', 'Bottom Bar Opacity');
  static String get tabletModeAuto => _get('自动（宽屏 ≥600dp）', 'Auto (wide screen ≥600dp)');
  static String get tabletModeAlways => _get('始终启用侧栏', 'Always use side bar');
  static String get tabletModeLandscape => _get('仅横屏启用', 'Landscape only');
  static String get tabletModeOff => _get('不启用', 'Disabled');
  static String get tabletNavMode => _get('大屏导航形态', 'Large screen navigation');
  static String get multiPaneAuto => _get('自动（宽窗口）', 'Auto (wide window)');
  static String get multiPaneLandscape => _get('横屏开启（宽窗口）', 'On in landscape (wide window)');
  static String get multiPaneAlways => _get('始终开启（空间足够时）', 'Always on (when space allows)');
  static String get modeOff => _get('关闭', 'Off');
  static String get multiPaneLayout => _get('多栏布局', 'Multi-column layout');
  static String get paletteNone => _get('关闭（内置色板）', 'Off (built-in palette)');
  static String get paletteTonalSpot => _get('Tonal Spot（默认）', 'Tonal Spot (default)');
  static String get colorStyle => _get('配色风格', 'Color style');
  static String get contrastMedium => _get('Medium（中）', 'Medium');
  static String get contrastHigh => _get('High（高）', 'High');
  static String get contrastDefault => _get('Default（默认）', 'Default');
  static String get contrast => _get('对比度', 'Contrast');
  static String get coverBlurOff => _get('显示封面（不模糊）', 'Show cover (no blur)');
  static String get coverBlurOffForDefault => _get('隐藏（仅默认封面档）', 'Hidden (default cover tier only)');
  static String get coverBlurOn => _get('模糊显示（默认）', 'Blurred (default)');
  static String get hideLabel => _get('隐藏', 'Hide');
  static String get coverBackground => _get('封面背景', 'Cover background');
  static String get floatingBottomBarBlur => _get('悬浮底栏模糊', 'Floating bottom bar blur');
  static String get themeEngine => _get('主题引擎', 'Theme engine');
  static String get trueBlackMode => _get('纯黑深色模式', 'True Black Mode');
  static String get trueBlackModeDesc => _get('暗色模式背景纯黑（省电护屏）', 'Pure black background in dark mode (saves power, easier on the eyes)');
  static String get changeIcon => _get('切换图标', 'Change Icon');
  static String get changeIconDesc => _get('切换软件显示在桌面的图标', 'Switch the software icon displayed on the desktop');
  static String get themeManagement => _get('主题管理', 'Theme Management');
  static String get themeManagementDesc => _get('使用、保存、导入或分享主题', 'Save, Import, Share theme');
  static String get fontSettings => _get('字体设置', 'Font Settings');
  static String get exportTheme => _get('导出主题', 'Export theme');
  static String get exportThemeDesc => _get('将当前配色导出为 JSON 文件', 'Export the current colors as a JSON file');
  static String get importTheme => _get('导入主题', 'Import theme');
  static String get importThemeDesc => _get('导入主题 JSON 文件并应用', 'Import a theme JSON file and apply it');
  static String get launchStyle => _get('启动界面样式', 'Launch interface style');
  static String get launchStyleDesc => _get('设定显示时间，更改背景图片，是否显示文字等', 'Set display duration, background image, whether to show text and more');
  static String get immersiveStatusBar => _get('沉浸式状态栏', 'Immersive status bar');
  static String get immersiveStatusBarDesc => _get('状态栏颜色透明', 'The status bar color becomes transparent');
  static String get immersiveNavBar => _get('沉浸式导航栏', 'Immersive navigation bar');
  static String get immersiveNavBarDesc => _get('导航栏颜色透明', 'The navigation bar becomes transparent');
  static String get navBarShadow => _get('导航栏阴影', 'Navigation bar shadow');
  static String get bottomBarAtlas => _get('底栏图集', 'Bottom bar icon pack');
  static String get bottomBarAtlasDesc => _get('导入 zip 自定义底栏图标', 'Import a zip to customize bottom bar icons');
  static String get wallpaperColors => _get('跟随壁纸配色', 'Use wallpaper colors');
  static String get wallpaperColorsDesc => _get('使用系统壁纸色板生成日间和夜间主题（Android 12+/iOS）', 'Generate day and night themes from the system wallpaper palette (Android 12+/iOS)');
  static String get wallpaperAutoUpdate => _get('壁纸变化时自动更新', 'Update automatically when wallpaper changes');
  static String get wallpaperAutoUpdateDesc => _get('系统壁纸变化后自动应用新色板', 'Apply the new palette automatically when the system wallpaper changes');
  static String get homeAndNavigation => _get('首页与导航', 'Home and navigation');
  static String get homeAndNavigationDesc => _get('设置首页、发现、订阅、默认主页和导航栏图标', 'Set home, discover, RSS, default start page and navigation bar icons');
  static String get topBarCapsuleDesc => _get('顶栏按钮收进胶囊容器', 'Place top bar buttons in a capsule container');
  static String get largeTopBar => _get('大顶栏形态', 'Large top bar');
  static String get largeTopBarDesc => _get('书架/我的等根页使用可折叠大标题', 'Root pages such as Bookshelf and My use a collapsible large title');
  static String get showBottomBar => _get('显示底栏', 'Show bottom bar');
  static String get showBottomBarDesc => _get('隐藏后仅侧栏/手势切页', 'When hidden, switch pages only via the side bar or gestures');
  static String get floatingBottomBarSection => _get('悬浮底栏', 'Floating Bottom Bar');
  static String get floatingBottomBarSectionDesc => _get('64dp 胶囊悬浮形态（ Experimental）', '64dp floating capsule style (Experimental)');
  static String get bookDetailPage => _get('书籍详情页', 'Book details');
  static String get uiColorFromCover => _get('界面颜色跟随封面取色', 'Use colors from book cover');
  static String get uiColorFromCoverDesc => _get('仅在显示背景封面时生效', 'Applied only while a background cover is visible');
  static String get networkCoverBackground => _get('网络封面背景设置', 'Network cover background');
  static String get defaultCoverBackground => _get('默认封面背景设置', 'Default cover background');
  static String get eyeProtection => _get('护眼模式', 'Eye Protection');
  static String get enableEyeProtection => _get('启用护眼模式', 'Enable Eye Protection');
  static String get enableEyeProtectionDesc => _get('使用暖色调降低蓝光', 'Reduce blue light via warm color tint');
  static String get eyeProtectionAutoDark => _get('深色模式时自动开启', 'Enable with dark reading mode');
  static String get eyeProtectionAutoDarkDesc => _get('跟随阅读界面的深色/浅色模式自动切换', 'Automatically follow the reader day/night mode');
  static String get eyeProtectionScheduled => _get('定时开启', 'Scheduled');
  static String get eyeProtectionScheduledDesc => _get('仅在设定的时间段内生效', 'Only apply during the configured time range');
  static String get startTime => _get('开始时间', 'Start Time');
  static String get endTime => _get('结束时间', 'End Time');
  static String get containerSection => _get('容器设置', 'Container');
  static String get containerBackground => _get('容器背景图', 'Container background');
  static String get containerBackgroundDesc => _get('大容器和项目卡面分别使用独立的日间/夜间图片', 'The container and item cards use separate day/night images');
  static String get containerBackgroundDay => _get('容器背景图片（日间）', 'Container background image (day)');
  static String get containerBackgroundNight => _get('容器背景图片（夜间）', 'Container background image (night)');
  static String get itemBackgroundDay => _get('项目背景图片（日间）', 'Item background image (day)');
  static String get itemBackgroundNight => _get('项目背景图片（夜间）', 'Item background image (night)');
  static String get containerImageOpacity => _get('大容器背景图透明度', 'Container image opacity');
  static String get containerImageOpacityHint => _get('0-100；仅作用于大容器背景图自身，与容器不透明度独立叠加（0=图片完全透明）', '0-100; applies only to the container background image itself and stacks independently of container opacity (0 = image fully transparent)');
  static String get itemImageOpacity => _get('项目背景图透明度', 'Item image opacity');
  static String get itemImageOpacityHint => _get('0-100；仅作用于设置页项目卡面图片自身，与容器不透明度独立叠加（0=图片完全透明）', '0-100; applies only to settings item card images and stacks independently of container opacity (0 = image fully transparent)');
  static String get containerOpacity => _get('容器不透明度', 'Container opacity');
  static String get containerOpacityHint => _get('0-100；作用于默认卡片（含自定义形状但未设色）与设置分组/设置首页卡面，越低底色越透（文字不受影响）', '0-100; applies to default cards (including custom-shaped cards without a color) and settings group/home cards; lower means a more transparent background (text is unaffected)');
  static String get backgroundBlurDay => _get('背景图虚化（日间）', 'Background image blur (day)');
  static String get backgroundBlurDesc => _get('仅作用于已设置的全局背景图，不影响内容/文字', 'Applies only to the configured global background image, not to content or text');
  static String get backgroundBlurNight => _get('背景图虚化（夜间）', 'Background image blur (night)');
  static String get disableGroupRadius => _get('关闭设置分组圆角', 'Disable setting group corner radius');
  static String get disableGroupRadiusDesc => _get('分组卡片外角置 0；优先于卡片圆角覆盖', 'Sets the outer corners of group cards to 0; takes precedence over the card radius override');
  static String get overrideCardRadius => _get('覆盖卡片圆角', 'Override card corner radius');
  static String get overrideCardRadiusDesc => _get('覆盖使用默认卡片样式的卡片；字典/首页/阅读器内面板等自定义形状卡片不覆盖', 'Overrides cards that use the default card style; cards with custom shapes such as dictionary, home and in-reader panels are not overridden');
  static String get cardRadius => _get('卡片圆角', 'Card corner radius');
  static String get cardRadiusDesc => _get('0-40dp；0 = 直角（参考版滑杆 0..40）', '0-40dp; 0 = square corners (reference slider range 0..40)');
  static String get overrideCardBorder => _get('覆盖卡片边框', 'Override card border');
  static String get overrideCardBorderDesc => _get('覆盖使用默认卡片样式的卡片边框（0 色跟随主题描边）；字典/首页/阅读器内面板等自定义形状卡片不覆盖', 'Overrides the border of cards using the default card style (color 0 follows the theme outline); cards with custom shapes such as dictionary, home and in-reader panels are not overridden');
  static String get cardBorderWidthDesc => _get('0-5dp；0 = 不绘制（不改变卡片尺寸）', '0-5dp; 0 = not drawn (card size is unchanged)');
  static String get dayBorderColor => _get('日间边框颜色', 'Day border color');
  static String get nightBorderColor => _get('夜间边框颜色', 'Night border color');
  static String get defaultFollowThemeBorder => _get('默认（跟随主题描边）', 'Default (follow theme outline)');
  static String get restoreDefault => _get('恢复默认', 'Restore default');
  static String get showDivider => _get('显示分隔线', 'Display divider');
  static String get showDividerDesc => _get('在分组行之间绘制；关闭保持 2dp 间距', 'Draw between group rows; when off, a 2dp gap is kept');
  static String get dividerWidth => _get('分隔线宽度', 'Divider width');
  static String get dividerWidthDesc => _get('0-5dp；0 = 不绘制', '0-5dp; 0 = not drawn');
  static String get dividerLength => _get('分隔线长度', 'Divider length');
  static String get raChunkRuleAi => _get('规则+AI', 'Rules + AI');
  static String get raChunkAi => _get('AI 理解', 'AI understanding');
  static String get raChunkAiUnsupported => _get('AI 分片暂未支持，实际按规则分片', 'AI segmentation is not supported yet; rules are used instead');
  static String get raChunkByRules => _get('按标点/段落规则分片', 'Split by punctuation/paragraph rules');
  static String get raLevelAuto => _get('自动', 'Auto');
  static String get raLevelLow => _get('低', 'Low');
  static String get raLevelMiddle => _get('中', 'Medium');
  static String get raLevelHigh => _get('高', 'High');
  static String get raLevelVeryHigh => _get('极高', 'Very high');
  static String get raLevelMaximum => _get('最高', 'Maximum');
  static String get raUnitParagraph => _get('整段', 'Whole paragraph');
  static String get raUnitPage => _get('整页', 'Whole page');
  static String get raUnitSymbol => _get('按符号', 'By punctuation');
  static String get raSplitByBlankLineDesc => _get('按空行分段落朗读（保留段内换行）', 'Read paragraph by paragraph on blank lines (line breaks within a paragraph are kept)');
  static String get raSplitByPageDesc => _get('按阅读器当前章分页朗读；切章回退整段', 'Read page by page within the current chapter; falls back to whole paragraph on chapter change');
  static String get raSplitBySymbolDesc => _get('按选中标点切分，连续标点同一单元', 'Split on selected punctuation; consecutive punctuation stays in one unit');
  static String get raSplitFollowRulesDesc => _get('跟随规则分片，当前按整段朗读', 'Follows rule segmentation; currently read as whole paragraphs');
  static String get raSystemDefault => _get('系统默认', 'System default');
  static String get raDefaultInterface => _get('默认朗读界面', 'Default read aloud interface');
  static String get raInterfaceClassic => _get('经典', 'Classic');
  static String get raInterfaceClassicDesc => _get('阅读器内朗读控制条', 'Read-aloud control bar inside the reader');
  static String get raInterfacePlayer => _get('播放器', 'Player');
  static String get raInterfacePlayerDesc => _get('启动朗读后进入听书播放器', 'Open the audio player when read aloud starts');
  static String get raPlayerBackground => _get('播放器背景', 'Player background');
  static String get raPlayerBgSolid => _get('纯色', 'Solid');
  static String get raPlayerBgSolidDesc => _get('跟随当前主题背景', 'Follow the current theme background');
  static String get raPlayerBgTransparent => _get('透明', 'Transparent');
  static String get raPlayerBgTransparentDesc => _get('露出全局背景图/壁纸', 'Reveal the global background image/wallpaper');
  static String get raPlayerBgBlur => _get('模糊', 'Blur');
  static String get raPlayerBgFlow => _get('流光', 'Flowing light');
  static String get raChapterSplitMode => _get('章节分片方式', 'Chapter segmentation');
  static String get raChapterSplitRulesOnly => _get('按标点/段落规则分片（当前唯一可用）', 'Split by punctuation/paragraph rules (currently the only option)');
  static String get raContentSplitMode => _get('内容划分方式', 'Content split');
  static String get raContentSplitBlankLine => _get('按空行分段落朗读', 'Read paragraph by paragraph on blank lines');
  static String get raContentSplitPage => _get('按阅读器当前章分页朗读', 'Read page by page within the current chapter');
  static String get raContentSplitSymbol => _get('按选中标点切分', 'Split on selected punctuation');
  static String get raKeepOneSymbol => _get('至少保留一个标点', 'Keep at least one punctuation mark');
  static String get raSwitchedToSystemTts => _get('已切换为系统 TTS', 'Switched to system TTS');
  static String get raEngineSwitched => _get('已切换朗读引擎', 'Read-aloud engine switched');
  static String get raFollowSystemTts => _get('跟随系统 TTS 设置', 'Follow system TTS settings');
  static String get raSystemTtsEngine => _get('系统 TTS 引擎', 'System TTS engine');
  static String get raEngineInitFailed => _get('引擎初始化失败', 'Engine initialization failed');
  static String get raSystemEngineFallback => _get('已切换系统引擎；原音色不可用，已回退系统默认', 'Switched to the system engine; the previous voice was unavailable, fell back to the system default');
  static String get raUsingSystemDefaultEngine => _get('已使用系统默认引擎', 'Using the system default engine');
  static String get raSystemEngineSwitched => _get('已切换系统引擎', 'Switched to the system engine');
  static String get raSystemTtsVoice => _get('系统 TTS 音色', 'System TTS voice');
  static String get raUsingSystemDefaultVoice => _get('已使用系统默认音色', 'Using the system default voice');
  static String get raSystemVoiceSwitched => _get('已切换系统音色', 'Switched to the system voice');
  static String get raOpenSystemSettingsHint => _get('无法打开系统设置，请手动进入「系统设置 → 文字转语音」', 'Could not open system settings; go to System Settings → Text-to-speech manually');
  static String get raOpenBatterySettingsHint => _get('无法打开电池优化设置，请手动在系统设置中关闭本应用电池优化', 'Could not open battery optimization settings; disable battery optimization for this app manually');
  static String get raCacheRetention => _get('缓存保留时间', 'Cache retention');
  static String get raCacheRetentionHint => _get('0 表示即听即焚：每段系统 TTS 播放完成/失败后立即删除；其余值在朗读开始时按修改时间清理过期缓存，正在播放的文件始终保留。HTTP 引擎（Rust）缓存不在此策略内。', '0 means delete right after playback: each system TTS segment is removed once it finishes or fails; other values clear expired cache by modification time when read aloud starts, and files being played are always kept. HTTP engine (Rust) cache is not covered by this policy.');
  static String get raFinished => _get('完成', 'Finished');
  static String get raTtsCache => _get('TTS 缓存', 'TTS cache');
  static String get raCacheExplain => _get('缓存仅用于加速重复段落朗读，清理后可随时重新生成。', 'The cache only speeds up repeated paragraphs; it can be regenerated at any time after clearing.');
  static String get raCacheClearHint => _get('清理不会删除正在播放的文件；HTTP 引擎（Rust）缓存不在此策略内。', 'Clearing never deletes files being played; HTTP engine (Rust) cache is not covered by this policy.');
  static String get raTabGeneral => _get('常规', 'General');
  static String get raTabEngine => _get('引擎与音色', 'Engine & voices');
  static String get raTabRoles => _get('角色与配乐', 'Roles & music');
  static String get raAndroidOnly => _get('仅 Android 支持', 'Android only');
  static String get raBatteryOptimized => _get('已忽略电池优化', 'Battery optimization ignored');
  static String get raBatteryNotOptimized => _get('未忽略电池优化，点击前往设置', 'Battery optimization not ignored; tap to open settings');
  static String get raBatterySettingsHint => _get('点击前往系统电池优化设置', 'Tap to open the system battery optimization settings');
  static String get raDefaultInterfaceDesc => _get('从阅读器启动朗读时进入的界面', 'The screen opened when read aloud starts from the reader');
  static String get raPlayerBackgroundDesc => _get('听书播放器页的背景样式', 'Background style of the audio player page');
  static String get raShowCapsule => _get('显示朗读胶囊', 'Show read-aloud capsule');
  static String get raAutoShrinkCapsule => _get('自动收缩朗读胶囊', 'Auto-shrink read-aloud capsule');
  static String get raResetCapsulePosition => _get('重置朗读胶囊位置', 'Reset capsule position');
  static String get raIgnoreAudioFocus => _get('忽略音频焦点', 'Ignore Audio Focus');
  static String get raIgnoreAudioFocusDesc => _get('允许与其他应用同时播放音频', 'Allow audio to be played at the same time as other applications');
  static String get raWakeLock => _get('朗读唤醒锁', 'Read-aloud wake lock');
  static String get raWakeLockDesc => _get('朗读期间保持 CPU 唤醒', 'Keep the CPU awake while reading aloud');
  static String get raPauseOnCall => _get('来电时暂停朗读', 'Pause read aloud on incoming call');
  static String get raPauseOnCallDesc => _get('需电话权限，暂未支持', 'Requires phone permission; not supported yet');
  static String get raKeepAloudAfterExit => _get('退出阅读时继续朗读', 'Keep reading aloud after exit');
  static String get raKeepAloudAfterExitDesc => _get('关闭时退出阅读器即停止本次朗读', 'When off, leaving the reader stops this read-aloud session');
  static String get raMediaKeyChapter => _get('媒体键上一首/下一首翻章', 'Media keys previous/next chapter');
  static String get raMediaKeyChapterDesc => _get('关闭时朗读按段落移动', 'When off, media keys move by paragraph instead of chapter');
  static String get raAndroidMediaCompat => _get('安卓媒体控制兼容', 'Android media control compatibility');
  static String get raStreamingReadAloud => _get('流式朗读', 'Streaming read aloud');
  static String get raBackgroundKeepAlive => _get('后台保活 / 电池优化', 'Background keep-alive / battery optimization');
  static String get raContentAnalysis => _get('内容分析', 'Content analysis');
  static String get raReasoningLevel => _get('推理级别', 'Reasoning level');
  static String get raReasoningLevelDesc => _get('仅 AI 分片时生效（暂未支持）', 'Only applies to AI segmentation (not supported yet)');
  static String get raSplitSymbols => _get('切分标点（可多选）', 'Split punctuation (multiple allowed)');
  static String get raSplitSymbolsDefault => _get('未选择时按句末标点 。！？… 划分', 'When nothing is selected, split on sentence-ending punctuation . ! ? …');
  static String get raSplitSymbolsConsecutive => _get('连续标点归入同一单元', 'Consecutive punctuation stays in one unit');
  static String get raParagraphIntervalDesc => _get('0 表示段间不额外等待；调整后下一次段落推进生效。', '0 means no extra wait between paragraphs; changes take effect on the next paragraph.');
  static String get raParagraphInterval => _get('段落间隔', 'Paragraph interval');
  static String get raCache => _get('缓存', 'Cache');
  static String get raCacheZeroHint => _get('0 = 即听即焚；超时缓存在朗读开始时清理', '0 = delete right after playback; expired cache is cleared when read aloud starts');
  static String get raSpeakEngine => _get('朗读引擎', 'Speak Engine');
  static String get raSystemTts => _get('系统 TTS', 'System tts');
  static String get raSystemTtsDesc => _get('使用系统内置语音引擎（无需网络）', 'Use the built-in system speech engine (no network needed)');
  static String get raPlatformSupportHint => _get('仅 Android/iOS/macOS 支持', 'Android/iOS/macOS only');
  static String get raManageEngines => _get('管理朗读引擎', 'Manage read-aloud engines');
  static String get raNoHttpEngine => _get('暂无 HTTP 引擎，点击添加', 'No HTTP engine yet; tap to add');
  static String get raHttpEngineDesc => _get('新增、编辑或删除 HTTP TTS 引擎', 'Add, edit or delete HTTP TTS engines');
  static String get raSystemEngineAndVoice => _get('系统引擎与音色', 'System engine & voice');
  static String get raSystemEngine => _get('系统引擎', 'System Engine');
  static String get raNoSystemTtsEngine => _get('系统未安装 TTS 引擎', 'No TTS engine installed on the system');
  static String get raPickSystemTtsEngine => _get('选择系统 TTS 引擎', 'Select system TTS engine');
  static String get raVoice => _get('音色', 'Voice');
  static String get raNoVoice => _get('无可用音色', 'No voice available');
  static String get raPickSystemVoice => _get('选择系统 TTS 音色', 'Select system TTS voice');
  static String get raSystemTtsSettings => _get('系统 TTS 设置', 'System tts Settings');
  static String get raOpenTtsSettings => _get('打开系统「文字转语音」设置', 'Open the system Text-to-speech settings');
  static String get raVoiceParams => _get('语音参数', 'Voice parameters');
  static String get raVoiceParamsHint => _get('音调/音量仅对系统 TTS 生效；HTTP 引擎当前仅语速生效（Rust 合成管线限制，已登记）。', 'Pitch and volume only apply to system TTS; HTTP engines currently only support speed (a known limitation of the Rust synthesis pipeline).');
  static String get raSpeed => _get('语速', 'Speed');
  static String get raPitch => _get('音调', 'Pitch');
  static String get raVolume => _get('音量', 'Volume');
  static String get raRole => _get('角色', 'Role');
  static String get raMultiSpeaker => _get('多角色朗读', 'Multi-speaker reading');
  static String get raRoleAssignment => _get('角色分配', 'Role assignment');
  static String get raCharacterVoices => _get('人物配音', 'Character voices');
  static String get raVoicePool => _get('声音池', 'Voice pool');
  static String get raMusic => _get('配乐', 'Music');
  static String get raBgmAssignment => _get('BGM 分配', 'BGM assignment');
  static String get raBgmPool => _get('BGM 池', 'BGM pool');
  static String get raChapterBgm => _get('本章 BGM', 'Chapter BGM');
  static String get raAiSceneDetection => _get('AI 场景识别', 'AI scene detection');
  static String get webdavKeepCount => _get('WebDAV 备份保留数量', 'WebDAV backups to keep');
  static String get webdavKeepCountDesc => _get('上传成功后保留最近几份备份；0 表示不自动清理（默认）。', 'Keep this many recent backups after a successful upload; 0 means no auto cleanup (default).');
  static String get webdavDisabled => _get('已关闭', 'Off');
  static String get webdavLocalAndRemote => _get('本地 + WebDAV', 'Local + WebDAV');
  static String get webdavLocalOnly => _get('仅本地', 'Local only');
  static String get webdavPickBackupDir => _get('选择备份路径', 'Select backup directory');
  static String get webdavBackingUp => _get('备份中…', 'Backing up…');
  static String get webdavConfirmSync => _get('确认同步吗？', 'Sync now?');
  static String get webdavSyncConfirmDesc => _get('将上传本地书架并覆盖远端备份（bookshelf.json），同时回写远端书源；不会覆盖本地阅读进度。如需从备份覆盖本地，请使用「恢复」中的本地恢复或网络恢复。', 'This uploads the local bookshelf to overwrite the remote backup (bookshelf.json) and writes the remote sources back. Local reading progress is not overwritten. To overwrite local data from a backup, use Local restore or Network restore under Restore.');
  static String get webdavSync => _get('同步', 'Sync');
  static String get webdavConfirmRestore => _get('确认恢复吗？', 'Restore confirmation');
  static String get webdavLocalRestoreConfirmDesc => _get('恢复书架会覆盖现有书架，包括已有书籍的阅读进度与书籍信息。确定继续吗？', 'Restoring the bookshelf overwrites the current bookshelf, including reading progress and book details of existing books. Continue?');
  static String get webdavRestore => _get('恢复', 'Restore');
  static String get webdavNotConfigured => _get('未配置 WebDAV，请先配置后再同步书库', 'WebDAV is not configured; configure it before syncing the library');
  static String get webdavNeedCredentials => _get('同步书库需要账号密码，请先在 WebDAV 设置中填写', 'Syncing the library needs an account and password; fill them in WebDAV settings first');
  static String get webdavSyncing => _get('同步中…', 'Syncing…');
  static String get webdavSyncComplete => _get('同步完成', 'Sync complete');
  static String get webdavPickLocalBackup => _get('选择本地备份文件（支持 .json 备份与 .zip 原版备份）', 'Select a local backup file (.json backups and .zip legacy backups are supported)');
  static String get webdavZipBypassUnsupported => _get('zip 备份暂不支持忽略项过滤（将按备份内容恢复）', 'Bypass list filtering is not supported for zip backups (everything in the backup is restored)');
  static String get webdavCheckingBackup => _get('检查备份…', 'Checking backup…');
  static String get webdavRestoring => _get('恢复中…', 'Restoring…');
  /// [P1-5] 部分服务器配置因备份密码缺失/错误而未恢复（已保留本机值）
  ///
  /// 恢复本身成功（其余数据已落库），但 `servers[].config` 解不开时保留
  /// 本机既有配置而非清空——必须如实提示，不能让用户以为凭据已恢复。
  static String restorePartialSkippedServerConfigs(int count) => _get(
    '恢复完成，但有 $count 个服务器配置因备份密码未提供或错误而未恢复（已保留本机配置）',
    'Restore finished, but $count server configuration(s) could not be restored '
        'because the backup password was missing or wrong (local settings kept)',
  );
  static String get webdavBusyHint => _get('正在备份或恢复，请稍候', 'A backup or restore is running; please wait');
  static String get webdavFetchingRemoteList => _get('获取远端备份列表…', 'Fetching remote backup list…');
  static String get webdavNoRemoteBackup => _get('未找到远端备份', 'No remote backup found');
  static String get webdavRemoteListFailed => _get('网络备份列表获取失败', 'Failed to fetch the remote backup list');
  static String get webdavRemoteListFailedAsk => _get('网络备份列表获取失败，是否改为本地恢复？', 'Failed to fetch the remote backup list. Restore from local instead?');
  static String get webdavRestoreLocal => _get('本地恢复', 'Restore from Local');
  static String get webdavEncryptedRemoteUnsupported => _get('暂不支持网络恢复密码备份，请使用本地恢复', 'Restoring a password-protected backup from the network is not supported; use Local restore');
  static String get webdavStillNeedsPassword => _get('备份仍要求密码', 'The backup still requires a password');
  static String get webdavFindingLocalBackup => _get('查找本地备份…', 'Looking for a local backup…');
  static String get webdavNoLocalBackup => _get('未找到本地备份', 'No local backup found');
  static String get webdavTooManyPasswordAttempts => _get('密码错误次数过多或备份文件损坏，已取消恢复', 'Too many wrong password attempts or the backup file is corrupted; restore cancelled');
  static String get webdavWrongPassword => _get('密码错误或备份已损坏，请重试', 'Wrong password or the backup is corrupted; try again');
  static String get webdavBackupCorrupted => _get('备份文件已损坏，无法恢复加密内容', 'The backup file is corrupted; encrypted content cannot be restored');
  static String get webdavRestoreBypassSaved => _get('已保存恢复忽略项', 'Restore bypass list saved');
  static String get webdavBackupBypass => _get('备份忽略', 'Backup bypass');
  static String get webdavBackupBypassDesc => _get('勾选后备份时跳过对应项，不写入备份文件；恢复忽略请单独设置。', 'Checked items are skipped when backing up and are not written to the backup file; the restore bypass list is configured separately.');
  static String get webdavSaveBackupBypassFailed => _get('保存备份忽略项失败', 'Failed to save the backup bypass list');
  static String get webdavBackupBypassSaved => _get('已保存备份忽略项', 'Backup bypass list saved');
  static String get webdavImporting => _get('导入中…', 'Importing…');
  static String get webdavPickLegacyDir => _get('选择旧版备份目录', 'Select the legacy backup directory');
  static String get webdavImportDone => _get('导入完成', 'Import completed');
  static String get webdavFillServerFirst => _get('请先填写服务器地址', 'Fill in the server address first');
  static String get webdavServerSchemeHint => _get('服务器地址需要以 http(s):// 开头', 'The server address must start with http(s)://');
  static String get webdavConnected => _get('连接成功', 'Connected');
  static String get webdavAuthFailed => _get('认证失败，请检查账号/密码', 'Authentication failed; check the account/password');
  static String get webdavConnectTimeout => _get('连接超时（5 秒内未响应）', 'Connection timed out (no response within 5 seconds)');
  static String get webdavNotTested => _get('未测试', 'Not tested');
  static String get webdavTesting => _get('测试中…', 'Testing…');
  static String get webdavConnectedCheck => _get('✓ 连接成功', '✓ Connected');
  static String get webdavFailedCross => _get('✗ 失败', '✗ Failed');
  static String get webdavImportLegacy => _get('导入旧版数据', 'Import Legacy Data');
  static String get webdavSyncLibraryMerge => _get('同步书库（合并）', 'Sync library (merge)');
  static String get webdavSettingsTitle => _get('WebDav 设置', 'WebDAV settings');
  static String get webdavServerAddress => _get('WebDAV 服务器地址', 'WebDAV server address');
  static String get webdavServerUrlHint => _get('输入你的服务器地址', 'Enter your server address');
  static String get webdavAccount => _get('WebDAV 账号', 'WebDAV account');
  static String get webdavAccountHint => _get('输入你的 WebDAV 账号', 'Enter your WebDAV account');
  static String get webdavPassword => _get('WebDAV 密码', 'WebDAV password');
  static String get webdavPasswordHint => _get('输入你的密码', 'Enter your password');
  static String get webdavSubDir => _get('子目录', 'Subdirectory');
  static String get webdavDeviceName => _get('设备名称', 'Device Name');
  static String get webdavDeviceNameDesc => _get('用于区分不同设备的备份', 'Used to tell backups from different devices apart');
  static String get webdavTestConfig => _get('测试配置', 'Test configuration');
  static String get webdavTestConfigDesc => _get('连接测试服务器地址与账号', 'Test the server address and account');
  static String get webdavKeepCountZero => _get('0（不自动清理）', '0 (no auto cleanup)');
  static String get webdavUploadAfterImport => _get('导入后自动上传本地书', 'Upload local books after import');
  static String get webdavUploadAfterImportDesc => _get('导入本地书后自动上传到 WebDAV 的 books 目录', 'Upload imported local books to the WebDAV books directory automatically');
  static String get webdavSyncProgress => _get('同步书籍进度', 'Sync reading progress');
  static String get webdavSyncProgressDesc => _get('在多设备间同步书籍阅读进度', 'Sync reading progress across devices');
  static String get webdavSyncProgressEnhanced => _get('同步书籍进度增强', 'Enhanced progress sync');
  static String get webdavSyncProgressEnhancedDesc => _get('同步更详细的阅读进度信息', 'Sync more detailed reading progress');
  static String get webdavBackupPath => _get('备份路径', 'Backup Dir');
  static String get webdavPickBackupPath => _get('请选择备份路径', 'Please select a backup path.');
  static String get webdavPickBackupMethod => _get('选择备份方式', 'Select backup method');
  static String get webdavPickRestoreMethod => _get('选择恢复方式', 'Select restore method');
  static String get webdavRestoreBypassList => _get('恢复忽略列表', 'Bypass List');
  static String get webdavRestoreBypassListDesc => _get('恢复时忽略一些内容不恢复，方便不同手机配置不同', 'Skip some content when restoring, so different phones can keep different settings');
  static String get webdavBackupBypassList => _get('备份忽略列表', 'Backup Bypass List');
  // C1：逐表备份忽略（对齐参考版 BackupConfig.dbIsNotIgnored）
  static String get backupContentTitle => _get('备份内容', 'Backup Content');
  static String get backupContentSaved => _get('已保存备份内容', 'Backup content saved');
  static String get backupContentSaveFailed => _get('保存备份内容失败', 'Failed to save backup content');
  static String get backupContentLoadFailed => _get('读取备份内容失败', 'Failed to load backup content');
  static String get webdavKeepLatestOnly => _get('仅保留最新备份', 'Keep Only the Latest Backup');
  static String get webdavKeepLatestOnlyDesc => _get('本地备份仅保留最新备份文件', 'Local backup keeps only the latest backup file');
  static String get webdavAutoBackup => _get('自动备份', 'Auto backup');
  static String get webdavAutoCheckNewBackup => _get('自动检查新备份', 'Auto-Check for New Backups');
  static String get webdavAutoCheckNewBackupDesc => _get('打开软件时检查是否有新备份，有新备份时提示是否更新', 'Check for new backups when opening the app, if new backups are found, prompt the user to update.');
  static String get webdavServerConfig => _get('服务器配置', 'Server Configuration');
  static String get webdavLoginInfo => _get('登录信息', 'Login information');
  static String get webdavSourceVariables => _get('书源运行变量', 'Book source runtime variables');
  static String get webdavEnterBackupPassword => _get('请输入备份密码', 'Enter the backup password');
  static String get webdavBackupPasswordHint => _get('输入备份密码', 'Enter backup password');
  static String get webdavEncryptedBackupHint => _get('该备份包含已加密的内容，请输入备份密码：', 'This backup contains encrypted content. Enter the backup password:');
  static String get webdavBackupPassword => _get('备份密码', 'Backup password');
  static String get webdavShowPassword => _get('显示密码', 'Show password');
  static String get webdavHidePassword => _get('隐藏密码', 'Hide password');
  static String get webdavPositiveIntHint => _get('请输入大于 0 的整数', 'Enter an integer greater than 0');
  static String get webdavEnableAutoBackup => _get('启用自动备份', 'Enable auto backup');
  static String get webdavEnableAutoBackupDesc => _get('启动或回到前台时检查，按间隔最多备份一次；手动备份不受影响', 'Checks on launch or when returning to the foreground, backing up at most once per interval; manual backups are unaffected');
  static String get webdavBackupIntervalDays => _get('备份间隔（天）', 'Backup interval (days)');
  static String get rssSearchHint => _get('搜索订阅源', 'Search RSS sources');
  static String get rssEnabled => _get('已启用', 'Enabled');
  static String get rssDisabled => _get('已禁用', 'Disabled');
  static String get rssNeedLogin => _get('需登录', 'Requires login');
  static String get rssUngrouped => _get('未分组', 'Ungrouped');
  static String get rssMoreOptions => _get('更多选项', 'More options');
  static String get rssAddSource => _get('新增订阅源', 'Add RSS source');
  static String get rssImportLocal => _get('本地导入', 'Import local');
  static String get rssImportOnline => _get('网络导入', 'Import online');
  static String get rssImportQr => _get('二维码导入', 'Import from QR code');
  static String get rssImportToken => _get('口令导入', 'Import by token');
  static String get rssImportDefaultRules => _get('导入默认规则', 'Import default rules');
  static String get rssRuleSubscription => _get('规则订阅', 'Rule subscription');
  static String get rssExitBatchMode => _get('退出批量模式', 'Exit batch mode');
  static String get rssEnableSelected => _get('启用选中', 'Enable selected');
  static String get rssDisableSelected => _get('禁用选中', 'Disable selected');
  static String get rssAddToGroup => _get('添加到分组', 'Add to group');
  static String get rssRemoveFromGroup => _get('移除分组', 'Remove from Groups');
  static String get rssPinSelected => _get('选中置顶', 'Pin selected');
  static String get rssUnpinSelected => _get('选中置底', 'Unpin selected');
  static String get rssExportSelected => _get('导出选中', 'Export selected');
  static String get rssShareSources => _get('分享源', 'Share sources');
  static String get rssSelectRange => _get('选择区间', 'Select range');
  static String get rssLoadingSources => _get('加载订阅源...', 'Loading RSS sources...');
  static String get rssNoSources => _get('暂无订阅源', 'No RSS sources');
  static String get rssNoMatchingSources => _get('没有匹配的订阅源', 'No matching RSS sources');
  static String get rssEmptyHint => _get('点击右上角菜单「新增订阅源」或导入订阅源', 'Use the "Add RSS source" menu in the top right, or import RSS sources');
  static String get rssMoveToBottom => _get('置底', 'To Bottom');
  static String get rssLogin => _get('登录', 'Login');
  static String get rssLoginSuccess => _get('登录成功', 'Login successful');
  static String get rssDeleteSource => _get('删除订阅源', 'Delete RSS source');
  static String get rssSelectSourcesFirst => _get('请先选择订阅源', 'Select RSS sources first');
  static String get rssEnabledSelected => _get('已启用所选订阅源', 'Selected RSS sources enabled');
  static String get rssDisabledSelected => _get('已禁用所选订阅源', 'Selected RSS sources disabled');
  static String get rssDeletedSelected => _get('已删除所选订阅源', 'Selected RSS sources deleted');
  static String get rssPinnedSelected => _get('已置顶所选订阅源', 'Selected RSS sources pinned to top');
  static String get rssUnpinnedSelected => _get('已置底所选订阅源', 'Selected RSS sources moved to bottom');
  static String get rssEnterGroupName => _get('输入分组名称', 'Enter group name');
  static String get rssNoGroupToRemove => _get('所选订阅源没有可移除的分组', 'The selected RSS sources have no groups to remove');
  static String get rssExportSources => _get('导出订阅源', 'Export RSS sources');
  static String get rssSelectAtLeastTwo => _get('请先选择两个以上的订阅源', 'Select at least two RSS sources first');
  static String get rssInvalidSourceArray => _get('不是有效的订阅源数组', 'Not a valid RSS source array');
  static String get rssInvalidSourceObject => _get('不是有效的订阅源对象', 'Not a valid RSS source object');
  static String get rssParseNoSource => _get('格式错误，未解析到订阅源', 'Invalid format; no RSS source could be parsed');
  static String get rssCannotGetFilePath => _get('无法获取文件路径', 'Unable to get the file path');
  static String get rssQrInvalid => _get('扫码内容不是可识别的订阅源数据', 'The scanned content is not recognizable RSS source data');
  static String get rssDefaultSynced => _get('默认订阅源已同步', 'Default RSS sources synced');
  static String get rssImportFromUrl => _get('从 URL 导入订阅源', 'Import RSS sources from URL');
  static String get rssSourceUrlHint => _get('输入订阅源 URL 地址', 'Enter the RSS source URL');
  static String get rssHistory => _get('历史记录', 'History');
  static String get sourceTypeText => _get('文本', 'Text');
  static String get sourceTypeAudio => _get('音频', 'Audio');
  static String get sourceTypeImage => _get('图片', 'Image');
  static String get sourceTypeFile => _get('文件', 'File');
  static String get sourceTypeVideo => _get('视频', 'Video');
  static String get sourceFieldBookSourceUrl => _get('源 URL（sourceUrl）', 'Source url(sourceUrl)');
  static String get sourceFieldBookSourceName => _get('源名称（sourceName）', 'Source Name(sourceName)');
  static String get sourceFieldBookSourceGroup => _get('源分组（sourceGroup）', 'Source group(sourceGroup)');
  static String get sourceFieldBookSourceComment => _get('源注释（sourceComment）', 'Source comment(sourceComment)');
  static String get sourceFieldLoginUrl => _get('登录 URL(loginUrl)', 'Log in URL(loginUrl)');
  static String get sourceFieldLoginUi => _get('登录 UI（loginUi）', 'Login UI(loginUi)');
  static String get sourceFieldLoginCheckJs => _get('登录检查 JS（loginCheckJs）', 'Login check js(loginCheckJs)');
  static String get sourceFieldCoverDecodeJs => _get('封面解密（coverDecodeJs）', 'Decode Cover Js(coverDecodeJs)');
  static String get sourceFieldBookUrlPattern => _get('书籍 URL 正则（bookUrlPattern）', 'Book URL pattern(bookUrlPattern)');
  static String get sourceFieldHeader => _get('请求头（header）', 'HTTP Header');
  static String get sourceJsonFormatHint => _get('JSON 格式', 'JSON format');
  static String get sourceFieldVariableComment => _get('变量说明(variableComment)', 'Variable Description (variableComment)');
  static String get sourceFieldConcurrentRate => _get('并发率（concurrentRate）', 'Concurrency rate(concurrentRate)');
  static String get sourceFieldSearchUrl => _get('搜索地址（url）', 'Search URL(url)');
  static String get sourceFieldSearchUrlHint => _get('例如：https://example.com/search?q=searchKey', 'e.g. https://example.com/search?q=searchKey');
  static String get sourceFieldCheckKeyWord => _get('校验关键字（checkKeyWord）', 'Check key word(checkKeyWord)');
  static String get sourceFieldBookList => _get('书籍列表规则（bookList）', 'Book list(bookList)');
  static String get sourceFieldName => _get('书名规则（name）', 'Book title(name)');
  static String get sourceFieldAuthor => _get('作者规则（author）', 'Author(author)');
  static String get sourceFieldKind => _get('分类规则（kind）', 'Classification(kind)');
  static String get sourceFieldWordCount => _get('字数规则（wordCount）', 'Word count(wordCount)');
  static String get sourceFieldLastChapter => _get('最新章节规则（lastChapter）', 'Last chapter(lastChapter)');
  static String get sourceFieldIntro => _get('简介规则（intro）', 'Intro(intro)');
  static String get sourceFieldCoverUrl => _get('封面规则（coverUrl）', 'CoverUrl(coverUrl)');
  static String get sourceFieldBookUrl => _get('详情页 URL 规则（bookUrl）', 'Details page URL(bookUrl)');
  static String get sourceFieldExploreUrl => _get('发现地址规则（url）', 'Discover URL(url)');
  static String get sourceFieldExploreUrlHint => _get('例如：分类名::https://example.com/sort\n或 url 形式', 'e.g. Category::https://example.com/sort\nor a plain url');
  static String get sourceFieldBookInfoInit => _get('预处理规则（bookInfoInit）', 'Book info init(bookInfoInit)');
  static String get sourceFieldTocUrl => _get('目录 URL 规则（tocUrl）', 'TOC URL(tocUrl)');
  static String get sourceFieldCanReName => _get('允许修改书名作者（canReName）', 'Can re name(canReName)');
  static String get sourceFieldDownloadUrls => _get('下载URL规则(downloadUrls)', 'Download URL rules(downloadUrls)');
  static String get sourceFieldPreUpdateJs => _get('更新之前 JS（preUpdateJs）', 'Js before update(preUpdateJs)');
  static String get sourceFieldChapterList => _get('目录列表规则（chapterList）', 'Chapter list(chapterList)');
  static String get sourceFieldChapterName => _get('章节名称规则（ChapterName）', 'Chapter name(chapterName)');
  static String get sourceFieldChapterUrl => _get('章节 URL 规则（chapterUrl）', 'Chapter URL(chapterUrl)');
  static String get sourceFieldFormatJs => _get('格式化规则(formatJs)', 'Format Rule (formatJs)');
  static String get sourceFieldIsVolume => _get('Volume 标识（isVolume）', 'Is volume(isVolume)');
  static String get sourceFieldChapterInfo => _get('章节信息（ChapterInfo）', 'Chapter info(ChapterInfo)');
  static String get sourceFieldIsVip => _get('VIP 标识（isVip）', 'Is vip(isVip)');
  static String get sourceFieldIsPay => _get('购买标识（isPay）', 'Is pay(isPay)');
  static String get sourceFieldNextTocUrl => _get('目录下一页规则（nextTocUrl）', 'Next toc URL(nextTocUrl)');
  static String get sourceFieldContent => _get('正文规则（content）', 'Content(content)');
  static String get sourceFieldNextContentUrl => _get('正文下一页 URL 规则（nextContentUrl）', 'Next content url(nextContentUrl)');
  static String get sourceFieldSubContent => _get('副文规则（subContent）', 'Sub content(subContent)');
  static String get sourceFieldReplaceRegex => _get('替换规则（replaceRegex）', 'Replace regex(replaceRegex)');
  static String get sourceFieldTitle => _get('标题（title）', 'Title(title)');
  static String get sourceFieldSourceRegex => _get('资源正则（sourceRegex）', 'Source regex(sourceRegex)');
  static String get sourceFieldImageStyle => _get('图片样式（imageStyle）', 'Image style(imageStyle)');
  static String get sourceFieldImageDecode => _get('图片解密（imageDecode）', 'Decode Image(imageDecode)');
  static String get sourceFieldPayAction => _get('购买操作（payAction）', 'Pay action(payAction)');
  static String get sourceFieldCallBackJs => _get('回调操作（callBackJs）', 'Callback action(callBackJs)');
  static String get sourceFieldReviewSummaryUrl => _get('段评统计 URL（reviewSummaryUrl）', 'Review summary URL(reviewSummaryUrl)');
  static String get sourceFieldSummaryListRule => _get('段评统计列表（summaryListRule）', 'Review summary list(summaryListRule)');
  static String get sourceFieldSummaryParagraphIndexRule => _get('段落索引（summaryParagraphIndexRule）', 'Paragraph index(summaryParagraphIndexRule)');
  static String get sourceFieldSummaryCountRule => _get('段评数量（summaryCountRule）', 'Review count(summaryCountRule)');
  static String get sourceFieldSummaryParagraphDataRule => _get('段落数据（summaryParagraphDataRule）', 'Paragraph data(summaryParagraphDataRule)');
  static String get sourceFieldReviewDetailUrl => _get('段评详情 URL（reviewDetailUrl）', 'Review detail URL(reviewDetailUrl)');
  static String get sourceFieldReviewDetailNextPageUrl => _get('段评下一页 URL（reviewDetailNextPageUrl）', 'Review next page URL(reviewDetailNextPageUrl)');
  static String get sourceFieldDetailListRule => _get('段评详情列表（detailListRule）', 'Review detail list(detailListRule)');
  static String get sourceFieldDetailIdRule => _get('段评 ID（detailIdRule）', 'Review ID(detailIdRule)');
  static String get sourceFieldDetailAvatarRule => _get('头像（detailAvatarRule）', 'Avatar(detailAvatarRule)');
  static String get sourceFieldDetailNameRule => _get('昵称（detailNameRule）', 'Nickname(detailNameRule)');
  static String get sourceFieldDetailBadgeRule => _get('徽章（detailBadgeRule）', 'Badge(detailBadgeRule)');
  static String get sourceFieldDetailContentRule => _get('评论内容协议（detailContentRule）', 'Comment content protocol(detailContentRule)');
  static String get sourceFieldReviewQuoteUrl => _get('段评回复URL（reviewQuoteUrl）', 'Paragraph comment replied to URL（reviewQuoteUrl）');
  static String get sourceFieldReplyListRule => _get('子评论列表（replyListRule）', 'Reply list(replyListRule)');
  static String get sourceFieldReplyIdRule => _get('子评论 ID（replyIdRule）', 'Reply ID(replyIdRule)');
  static String get sourceFieldReplyAvatarRule => _get('子评论头像（replyAvatarRule）', 'Reply avatar(replyAvatarRule)');
  static String get sourceFieldReplyNameRule => _get('子评论昵称（replyNameRule）', 'Reply nickname(replyNameRule)');
  static String get sourceFieldReplyBadgeRule => _get('子评论徽章（replyBadgeRule）', 'Reply badge(replyBadgeRule)');
  static String get sourceFieldReplyContentRule => _get('子评论内容协议（replyContentRule）', 'Reply content protocol(replyContentRule)');
  static String get sourceAdd => _get('新建书源', 'Add Book Source');
  static String get sourceEdit => _get('编辑书源', 'Edit Book source');
  static String get sourceEditContent => _get('编辑内容', 'Edit Content');
  static String get sourceDebug => _get('调试源', 'Debug source');
  static String get sourceBasicInfo => _get('基本信息', 'Basic info');
  static String get sourceSearchRules => _get('搜索规则', 'Search rules');
  static String get sourceExploreRules => _get('发现规则', 'Discover rules');
  static String get sourceInfoRules => _get('详情规则', 'Details rules');
  static String get sourceTocRules => _get('目录规则', 'TOC rules');
  static String get sourceContentRules => _get('正文规则', 'Content rules');
  static String get sourceReviewRules => _get('段评规则', 'Review rules');
  static String get sourceCreated => _get('书源已创建', 'Book source created');
  static String get sourceSaved => _get('书源已保存', 'Book source saved');
  static String get sourceClearCookie => _get('清除Cookie', 'Clear cookies');
  static String get sourceAutoComplete => _get('自动补全', 'Automatic completion');
  static String get sourceCopy => _get('拷贝源', 'Copy source');
  static String get sourcePaste => _get('粘贴源', 'Paste source');
  static String get sourceSetVariable => _get('设置源变量', 'Set source variable');
  static String get sourceQrShare => _get('二维码分享', 'QR code sharing');
  static String get sourceStringShare => _get('字符串分享', 'Strings sharing');
  static String get sourceAutoCompleteOn => _get('自动补全已开启', 'Automatic completion on');
  static String get sourceAutoCompleteOff => _get('自动补全已关闭', 'Automatic completion off');
  static String get sourceFillUrlFirst => _get('请先填写书源 URL', 'Fill in the book source URL first');
  static String get sourceCookieCleared => _get('Cookie 已清除', 'Cookies cleared');
  static String get sourceVariableHint => _get('源变量可在js中通过source.getVariable()获取', 'Source variables can be read in JS via source.getVariable()');
  static String get sourceVariableCleared => _get('源变量已清除', 'Source variable cleared');
  static String get sourceVariableSaved => _get('源变量已保存', 'Source variable saved');
  static String get sourceTooLongForQr => _get('内容过长，无法生成二维码，请使用字符串分享', 'Content is too long to generate a QR code; use string sharing instead');
  static String get sourceShare => _get('分享书源', 'Book sources sharing');
  static String get sourceCopied => _get('已复制到剪贴板', 'Copied to clipboard');
  static String get sourceClipboardEmpty => _get('剪贴板为空', 'Clipboard is empty');
  static String get sourceClipboardInvalid => _get('剪贴板内容不是有效的书源 JSON', 'The clipboard content is not valid book source JSON');
  static String get sourceShareTitle => _get('书源分享', 'Book source sharing');
  static String get sourceQrInvalid => _get('扫码内容不是有效的书源 JSON', 'The scanned content is not valid book source JSON');
  static String get sourceLegadoLinkHint => _get('legado 协议链接请使用「关联导入」页处理', 'Handle legado scheme links on the "Deep link import" page');
  static String get sourceUrlContentHint => _get('URL 内容请使用书源管理页的网络导入处理', 'Handle URL content via network import on the book source management page');
  static String get sourceFocusFieldFirst => _get('请先将光标放在要编辑的输入框', 'Place the cursor in the input field to edit first');
  static String get sourceReview => _get('段评', 'Review');
  static String get sourceEventListener => _get('事件监听', 'Event listener');
  static String get sourceCustomButton => _get('定制按钮', 'Custom button');
  static String get sourceTypePrefix => _get('类型：', 'Type: ');
  static String get sourceCodeEdit => _get('代码编辑', 'Code editing');
  static String get sourceVariableDialogHint => _get('输入源变量（空则清除）', 'Enter source variables (empty clears them)');
  static String get sourceQrGenerateFailed => _get('二维码生成失败', 'Failed to generate the QR code');
  static String get sourceShareImage => _get('分享图片', 'Share image');
  static String get sourceNotFoundHint => _get('未找到书源，可能已被删除', 'Book source not found; it may have been deleted');
  static String get sourceEnabledLabel => _get('启用', 'Enable');
  static String get sourceExploreLabel => _get('发现', 'Discover');

  // ----- L10N 阶段 2：参数化文案 -----
  static String currentPercent(int value) =>
      _locale == 'zh' ? '当前 $value%' : 'Current $value%';
  static String blurRadiusValue(int value) =>
      _locale == 'zh' ? '模糊半径 ${value}dp' : 'Blur radius ${value}dp';
  static String blurAlphaValue(int value) =>
      _locale == 'zh' ? '底色透明度 $value/255' : 'Base opacity $value/255';
  static String navBarShadowValue(int value) =>
      _locale == 'zh' ? '当前阴影大小（elevation）：$value' : 'Current elevation: $value';
  static String raLoadFailed(String error) =>
      _locale == 'zh' ? '读取朗读设置失败：$error' : 'Failed to read read-aloud settings: $error';
  static String raCacheRetentionCurrent(String label) =>
      _locale == 'zh' ? '当前：$label' : 'Current: $label';
  static String raCacheStats(int count, String size) =>
      _locale == 'zh' ? '系统 TTS 合成缓存：$count 个文件，共 $size。\n缓存仅用于加速重复段落朗读，清理后可随时重新生成。' : 'System TTS cache: $count files, $size in total.\n''The cache only speeds up repeated paragraphs; it can be regenerated at any time after clearing.';
  static String raCacheRetentionInRow(String label) =>
      _locale == 'zh' ? '当前保留：$label（在「缓存保留时间」行设置）' : 'Currently keeping: $label (set in the Cache retention row)';
  static String raCacheCleared(int count) =>
      _locale == 'zh' ? '已清理 $count 个缓存文件' : 'Cleared $count cache files';
  static String raSplitSelected(int count) =>
      _locale == 'zh' ? '已选 $count 个标点；连续标点归入同一单元' : '$count punctuation marks selected; consecutive punctuation stays in one unit';
  static String raCacheSummary(int count, String size, String label) =>
      _locale == 'zh' ? '$count 个文件 · $size · 保留 $label' : '$count files · $size · keeping $label';
  static String webdavLoadConfigFailed(String error) =>
      _locale == 'zh' ? '加载 WebDAV 配置失败：$error' : 'Failed to load WebDAV settings: $error';
  static String webdavSaveConfigFailed(String error) =>
      _locale == 'zh' ? '保存 WebDAV 配置失败：$error' : 'Failed to save WebDAV settings: $error';
  static String webdavKeepCountInvalid(int max) =>
      _locale == 'zh' ? '请输入 0~$max 的整数' : 'Enter an integer between 0 and $max';
  static String webdavAutoBackupInterval(int days, String destination) =>
      _locale == 'zh' ? '每 $days 天自动备份（$destination）' : 'Auto backup every $days days ($destination)';
  static String backupFailedWithReason(String error) =>
      _locale == 'zh' ? '备份失败：$error' : 'Backup failed: $error';
  static String backupUploadedToWebDav(String name) =>
      _locale == 'zh' ? '备份成功：已上传 WebDAV：$name' : 'Backup successful: uploaded to WebDAV: $name';
  static String backupUploadedLocalOnly(String path) =>
      _locale == 'zh' ? '备份成功：$path' : 'Backup successful: $path';
  static String backupUploadedWithRemote(String path, String name) =>
      _locale == 'zh' ? '备份成功：$path\n已上传 WebDAV：$name' : 'Backup successful: $path\nUploaded to WebDAV: $name';
  static String backupUploadedWithError(String path, String error) =>
      _locale == 'zh' ? '备份成功：$path\nWebDAV 上传失败：$error' : 'Backup successful: $path\nWebDAV upload failed: $error';
  static String webdavUploadFailed(String error) =>
      _locale == 'zh' ? 'WebDAV 上传失败：$error' : 'WebDAV upload failed: $error';
  static String webdavUploaded(String name) =>
      _locale == 'zh' ? '已上传 WebDAV：$name' : 'Uploaded to WebDAV: $name';
  static String webdavInspectFailed(String error) =>
      _locale == 'zh' ? '检查备份失败：$error' : 'Failed to inspect the backup: $error';
  static String restoreFailedWithReason(String error) =>
      _locale == 'zh' ? '恢复失败：$error' : 'Restore failed: $error';
  static String checkedCount(int count) =>
      _locale == 'zh' ? '已勾选 $count 项' : '$count selected';
  static String legacyImportSummary(int books, int sources, int rules) =>
      _locale == 'zh' ? '书架 $books · 书源 $sources · 替换规则 $rules' : 'Books $books · Sources $sources · Replace rules $rules';
  static String webdavProbeFailedHttp(int code) =>
      _locale == 'zh' ? '连接失败（HTTP $code）' : 'Connection failed (HTTP $code)';
  static String webdavProbeFailed(String error) =>
      _locale == 'zh' ? '连接失败：$error' : 'Connection failed: $error';
  static String webdavKeepCountLabel(int count) =>
      _locale == 'zh' ? '$count（仅保留最近 $count 份）' : '$count (keep only the latest $count)';
  static String webdavLastSync(String label) =>
      _locale == 'zh' ? '上次同步：$label' : 'Last sync: $label';
  static String webdavRemoteRestoreConfirmDesc(String remoteName) =>
      _locale == 'zh' ? '将下载远端备份「$remoteName」并覆盖本地书架，包括已有书籍的阅读进度与书籍信息。确定继续吗？' : 'This downloads the remote backup "$remoteName" and overwrites the local bookshelf, including reading progress and book details of existing books. Continue?';
  static String rssSelectedCount(int count) =>
      _locale == 'zh' ? '已选择 $count 项' : '$count selected';
  static String rssSelectAllCount(int selected, int total) =>
      _locale == 'zh' ? '全选 $selected/$total' : 'Select all $selected/$total';
  static String rssToggleFailed(String error) =>
      _locale == 'zh' ? '切换启用状态失败：$error' : 'Failed to toggle the enabled state: $error';
  static String rssConfirmDeleteNamed(String name) =>
      _locale == 'zh' ? '确定要删除订阅源「$name」吗？' : 'Delete the RSS source "$name"?';
  static String rssDeleteFailed(String error) =>
      _locale == 'zh' ? '删除失败：$error' : 'Delete failed: $error';
  static String rssSaveOrderFailed(String error) =>
      _locale == 'zh' ? '保存排序失败：$error' : 'Failed to save the order: $error';
  static String rssOperationFailed(String error) =>
      _locale == 'zh' ? '操作失败：$error' : 'Operation failed: $error';
  static String rssConfirmDeleteSelected(int count) =>
      _locale == 'zh' ? '确定要删除选中的 $count 个订阅源吗？' : 'Delete the $count selected RSS sources?';
  static String rssGroupAdded(String name) =>
      _locale == 'zh' ? '已为所选订阅源添加分组「$name」' : 'Added group "$name" to the selected RSS sources';
  static String rssAddGroupFailed(String error) =>
      _locale == 'zh' ? '添加分组失败：$error' : 'Failed to add the group: $error';
  static String rssGroupRemoved(String name) =>
      _locale == 'zh' ? '已从所选订阅源移除分组「$name」' : 'Removed group "$name" from the selected RSS sources';
  static String rssRemoveGroupFailed(String error) =>
      _locale == 'zh' ? '移除分组失败：$error' : 'Failed to remove the group: $error';
  static String rssShareTitle(int count) =>
      _locale == 'zh' ? '订阅源分享（$count 个）' : 'Share RSS sources ($count)';
  static String shareFailed(String error) =>
      _locale == 'zh' ? '分享失败：$error' : 'Share failed: $error';
  static String rssImportFileFailed(String error) =>
      _locale == 'zh' ? '从文件导入失败：$error' : 'Failed to import from file: $error';
  static String rssFetchFailedHttp(int code) =>
      _locale == 'zh' ? '获取订阅源失败：HTTP $code' : 'Failed to fetch RSS sources: HTTP $code';
  static String rssFetchFailed(String error) =>
      _locale == 'zh' ? '获取订阅源失败：$error' : 'Failed to fetch RSS sources: $error';
  static String rssDefaultImported(int count) =>
      _locale == 'zh' ? '已导入 $count 条默认订阅源' : 'Imported $count default RSS sources';
  static String rssImportDefaultFailed(String error) =>
      _locale == 'zh' ? '导入默认规则失败：$error' : 'Failed to import default rules: $error';
  static String sourceSaveFailed(String error) =>
      _locale == 'zh' ? '保存失败：$error' : 'Save failed: $error';
  static String sourceOpenSearchFailed(String error) =>
      _locale == 'zh' ? '打开搜索失败：$error' : 'Failed to open search: $error';
  static String sourceClearCookieFailed(String error) =>
      _locale == 'zh' ? '清除 Cookie 失败：$error' : 'Failed to clear cookies: $error';
  static String sourceSetVariableFailed(String error) =>
      _locale == 'zh' ? '设置源变量失败：$error' : 'Failed to set the source variable: $error';
  static String sourcePasted(String name) =>
      _locale == 'zh' ? '已粘贴书源：$name' : 'Pasted book source: $name';
  static String sourceImported(String name) =>
      _locale == 'zh' ? '已导入书源：$name' : 'Imported book source: $name';
  static String sourceDebugFailed(String error) =>
      _locale == 'zh' ? '调试失败：$error' : 'Debug failed: $error';
  static String sourceSettingsSummary(String summary, bool expanded) =>
      _locale == 'zh' ? '设置, $summary, ${expanded ? '收起' : '展开'}' : 'Settings, $summary, ${expanded ? 'collapse' : 'expand'}';
  static String sourceFieldRequired(String label) =>
      _locale == 'zh' ? '请输入$label' : 'Enter $label';

  // ----- L10N 阶段 2 补遗（主题尾部 / 订阅源 / 书源编辑） -----
  static String get dividerLengthDesc => _get('占分组可用宽度的百分比（30-100%）', 'Percentage of the group width available (30-100%)');
  static String get dividerColor => _get('分隔线颜色', 'Divider color');
  static String get dividerColorDefault => _get('默认（灰色半透明）', 'Default (translucent gray)');
  static String get blurEffectsSection => _get('模糊效果', 'Blur Effects');
  static String get enableBlur => _get('启用毛玻璃', 'Enable Blur');
  static String get enableBlurDesc => _get('低端设备开启可能掉帧', 'May drop frames on low-end devices');
  static String get enableBlurFirst => _get('需先启用毛玻璃', 'Enable blur first');
  static String get customThemeDay => _get('自定义主题 · 白天', 'Custom theme · Day');
  static String get customThemeNight => _get('自定义主题 · 夜间', 'Custom theme · Night');
  static String get primaryColor => _get('主色调', 'Primary');
  static String get accentColor => _get('强调色', 'Accent');
  static String get primaryTextColor => _get('主要字体色', 'Primary Text Color');
  static String get secondaryTextColor => _get('次要字体色', 'Secondary Text Color');
  static String get navBarColor => _get('底部操作栏颜色', 'NavBar color');
  static String get backgroundImages => _get('背景图片', 'Background Images');
  static String get transparentNavBar => _get('透明导航栏', 'Transparent navigation bar');
  static String get saveDayTheme => _get('保存白天主题', 'Save day theme');
  static String get saveDayThemeDesc => _get('将当前白天颜色保存到主题列表', 'Save the current day colors to the theme list');
  static String get saveNightTheme => _get('保存夜间主题', 'Save night theme');
  static String get saveNightThemeDesc => _get('将当前夜间颜色保存到主题列表', 'Save the current night colors to the theme list');
  static String get bgImageWallpaperFooter => _get('背景图片将作为全局窗口壁纸显示（分组列表卡片保持不透明底）', 'The background image is shown as a global window wallpaper (group list cards keep an opaque background)');
  static String get dayBgTooDark => _get('白天背景不能太暗', 'Day background can not be too dark!');
  static String get nightBgTooBright => _get('夜间背景不能太亮', 'Night background can not be too bright!');
  static String get launcherIcon => _get('启动图标', 'Launcher icon');
  static String get launcherIconChanged => _get('图标已切换，重启应用后生效', 'Icon changed; restart the app to apply');
  static String get launcherIconUnsupported => _get('当前平台或系统版本不支持更换图标', 'Changing the icon is not supported on this platform or system version');
  static String get noSavedThemes => _get('暂无保存的主题配置\n可在下方"保存白天/夜间主题"后于此切换', 'No saved themes yet\nSave a day/night theme below, then switch here');
  static String get unnamedTheme => _get('未命名', 'Untitled');
  static String get nightTheme => _get('夜间主题', 'Night theme');
  static String get dayTheme => _get('白天主题', 'Day theme');
  static String get exportThemePackage => _get('导出主题包', 'Export theme package');
  static String get rename => _get('重命名', 'Rename');
  static String get importThemePackage => _get('导入主题包', 'Import theme package');
  static String get themeName => _get('主题名称', 'Theme name');
  static String get themeApplied => _get('已应用主题', 'Theme applied');
  static String get themeSaved => _get('已保存主题', 'Theme saved');
  static String get exportThemePackageFailed => _get('导出主题包失败', 'Failed to export the theme package');
  static String get themePackageImported => _get('已导入主题包', 'Theme package imported');
  static String get importFailedShort => _get('导入失败', 'Import failed');
  static String get importFailedNoFile => _get('导入失败：无法选择文件', 'Import failed: no file selected');
  static String get exportFailed => _get('导出失败', 'Export failed');
  static String get importFailedBadFormat => _get('导入失败：主题文件格式不正确', 'Import failed: invalid theme file format');
  static String get themeImported => _get('主题已导入', 'Theme imported');
  static String get fontLoading => _get('正在加载字体…', 'Loading font…');
  static String get fontSystemDefault => _get('未设置（跟随系统默认字体）', 'Not set (follow the system default font)');
  static String get fontCustom => _get('自定义字体', 'Custom font');
  static String get fontApplied => _get('已设置', 'Set');
  static String get fontLoadFailed => _get('加载失败，已回退默认字体', 'failed to load, fell back to the default font');
  static String get pickFontFile => _get('选择字体文件', 'Select a font file');
  static String get clearFont => _get('清除字体', 'Clear font');
  static String get fontUpdated => _get('应用字体已更新', 'App font updated');
  static String get fontRestoredDefault => _get('已恢复默认字体', 'Default font restored');
  static String get pickImage => _get('选择图片', 'Select a picture');
  static String get pickBackgroundImage => _get('选择背景图片', 'Select background image');
  static String get fileMissingFallback => _get('文件缺失，已回落', 'file missing, fell back');
  static String get pickContainerBackgroundImage => _get('选择容器背景图片', 'Select container background image');
  static String get setContainerBackgroundFailed => _get('设置容器背景图失败', 'Failed to set the container background');
  static String get pickItemBackgroundImage => _get('选择项目背景图片', 'Select item background image');
  static String get setItemBackgroundFailed => _get('设置项目背景图失败', 'Failed to set the item background');
  static String get clearImage => _get('清除图片', 'Clear image');
  static String get fontScale => _get('字体缩放', 'Font scale');
  static String get renameTheme => _get('重命名主题', 'Rename theme');
  static String get rssEnable => _get('启用', 'Enable');
  static String get rssDisable => _get('禁用', 'Disable');
  static String get rssGroupMenu => _get('分组', 'Groups');
  static String get sourceExploreUrlHintExample => _get('例如：分类名::https://example.com/sort\n或 url 形式', 'e.g. Category::https://example.com/sort\nor a plain url');

  // ----- L10N 阶段 2 补遗：参数化文案 -----
  static String blurDetailValue(int radius, int alpha) =>
      _locale == 'zh' ? '半径 $radius dp · 底色 $alpha/255' : 'Radius $radius dp · Base $alpha/255';
  static String themeAppliedNamed(String name) =>
      _locale == 'zh' ? '已应用主题「$name」' : 'Applied theme "$name"';
  static String themeSavedNamed(String name) =>
      _locale == 'zh' ? '已保存主题「$name」' : 'Saved theme "$name"';
  static String exportThemePackageFailedWithReason(String error) =>
      _locale == 'zh' ? '导出主题包失败：$error' : 'Failed to export the theme package: $error';
  static String themePackageImportedNamed(String name) =>
      _locale == 'zh' ? '已导入主题包 $name' : 'Theme package $name imported';
  static String importFailedShortWithReason(String error) =>
      _locale == 'zh' ? '导入失败：$error' : 'Import failed: $error';
  static String exportFailedWithReason(String error) =>
      _locale == 'zh' ? '导出失败：$error' : 'Export failed: $error';
  static String fontAppliedWithFailure(String name) =>
      _locale == 'zh' ? '已设置：$name（加载失败，已回退默认字体）' : 'Set: $name (failed to load, fell back to the default font)';
  static String fontAppliedValue(String name) =>
      _locale == 'zh' ? '已设置：$name' : 'Set: $name';
  static String fileMissingNamed(String name) =>
      _locale == 'zh' ? '$name（文件缺失，已回落）' : '$name (file missing, fell back)';
  static String numberRangeInputHint(num min, num max) =>
      _locale == 'zh' ? '请输入 $min ~ $max 之间的数字' : 'Enter a number between $min and $max';
  static String currentFontSize(String size) =>
      _locale == 'zh' ? '当前字体大小: $size' : 'Current font size: $size';

  // ----- L10N 阶段 3：书籍详情 / 发现 / 字典 -----

  // 通用动作（多界面共用）
  static String get readAction => _get('阅读', 'Read');
  static String get shareAction => _get('分享', 'Share');
  static String get refreshAction => _get('刷新', 'Refresh');
  static String get customAction => _get('自定义', 'Custom');
  static String get loginAction => _get('登录', 'Login');
  static String get logLabel => _get('日志', 'Log');
  static String get noticeTitle => _get('提示', 'Notice');
  static String get goToSettings => _get('去设置', 'Go to settings');
  static String get doneLabel => _get('完成', 'Done');
  static String get queryAction => _get('查询', 'Look up');
  static String get collapseLabel => _get('收起', 'Collapse');
  static String get expandLabel => _get('展开', 'Expand');

  // 书籍详情：顶栏与溢出菜单
  static String get bookInfoEditTooltip => _get('编辑书籍信息', 'Edit book information');
  static String get bookInfoUnavailable =>
      _get('书籍信息暂不可用，请稍后重试', 'Book information is unavailable, please try again later');
  static String get bookNotExist => _get('书籍不存在', 'Book not found');
  static String get missingBookParams => _get('缺少书籍参数', 'Missing book parameters');
  static String get bookDisableReadRecord => _get('独立关闭阅读记录', 'Disable record for this book');
  static String get setBookVariable => _get('设置书籍变量', 'Set book variable');
  static String get copyBookUrl => _get('拷贝书籍URL', 'Copy book URL');
  static String get copyTocUrl => _get('拷贝目录URL', 'Copy chapters URL');
  static String get allowUpdate => _get('允许更新', 'Enable update');
  static String get deleteAlert => _get('删除提醒', 'Delete Alert');
  static String get uploadToRemote => _get('上传至远程', 'Upload');
  static String get createBookUpdateTask => _get('创建书籍更新任务', 'Create book update task');
  static String get groupSettings => _get('设置分组', 'Group settings');
  static String get splitLongChapter => _get('拆分长章节', 'Split extra-long chapters');
  static String get cacheDownloadQueue => _get('缓存下载队列', 'Download queue');
  static String get markAsPrivate => _get('标记为私密', 'Mark as private');
  static String get setPasswordFirst => _get('请先设置密码', 'Set a password first');

  // 书籍详情：私密锁定页
  static String get privateBookTitle => _get('私密书籍', 'Private book');
  static String get verifyToViewBookInfo =>
      _get('验证后查看书籍详情', 'Verify to view book details');
  static String get verifyToView => _get('验证后查看', 'Verify to view');

  // 书籍详情：自定义按钮 / 变量 / 上传 / 任务
  static String get callbackNotHandled =>
      _get('未配置回调或回调未接管', 'No callback configured or the callback did not take over');
  static String get splitLongChapterTakesEffectAfterShelf =>
      _get('拆分长章节将在加入书架后生效', 'Splitting extra-long chapters takes effect after adding to the bookshelf');
  static String get setPasswordInPrivacyFirst =>
      _get('请先在隐私设置中设置密码', 'Set a password in privacy settings first');
  static String get markedPrivate => _get('已标记为私密', 'Marked as private');
  static String get unmarkedPrivate => _get('已取消私密', 'Private mark removed');
  static String get sourceNotExist => _get('书源不存在', 'Book source not found');
  static String get uploadToRemoteLocalOnly =>
      _get('上传至远程仅支持本地书籍', 'Upload is only available for local books');
  static String get webdavUrlExistsConfirm =>
      _get('已存在远程 webDav 地址，继续上传？', 'Remote WebDAV URL exists, continue?');
  static String get uploadingToRemote => _get('正在上传至远程…', 'Uploading…');
  static String get uploadSavedRecordFailed =>
      _get('上传成功但保存记录失败，请重试', 'Uploaded but saving the record failed, please retry');
  static String get uploadToRemoteSuccess => _get('上传至远程成功', 'Uploaded successfully');
  static String get webdavNotConfiguredTitle => _get('未配置 WebDAV', 'WebDAV not configured');
  static String get webdavNotConfiguredDesc => _get(
      '上传至远程需要先配置 WebDAV 服务器信息',
      'Configure the WebDAV server before uploading');
  static String get bookVariableHint => _get(
      '书籍变量可在js中通过book.getVariable("custom")获取',
      'Book variables can be read in JS via book.getVariable("custom")');
  static String get addToShelfFirst => _get('请先加入书架', 'Add the book to the bookshelf first');
  static String get bookVariableSaved => _get('书籍变量已保存', 'Book variable saved');
  static String get bookVariableSaveFailed =>
      _get('保存书籍变量失败', 'Failed to save the book variable');
  static String get createTaskFailed => _get('创建任务失败', 'Failed to create the task');

  // 书籍详情：元信息区
  static String get finishedReading => _get('已读完', 'Finished');
  static String get downloadedLabel => _get('已下载', 'Downloaded');
  static String get inBookshelfLabel => _get('已在书架', 'In library');
  static String get addToShelfShort => _get('加书架', 'Add to shelf');
  static String get viewChapters => _get('查看目录', 'Chapters');
  static String get bookSourceLabel => _get('书源', 'Source');
  static String get charactersLabel => _get('角色', 'Characters');
  static String get relatedBooksLabel => _get('相关书籍', 'Related books');

  // 书籍详情：书架切换 / 缓存 / webFile
  static String get removeFromShelfTitle => _get('移出书架', 'Remove from bookshelf');
  static String get removeFromShelfFailedNoReason =>
      _get('移出书架失败', 'Failed to remove from bookshelf');
  static String get localBookNoSourceLogin =>
      _get('本地书籍不支持书源登录', 'Local books do not support source login');
  static String get sourceForBookNotFound =>
      _get('未找到本书对应的书源', 'No book source found for this book');
  static String get loginSuccess => _get('登录成功', 'Login successful');
  static String get tocEmpty => _get('目录为空', 'Chapters are empty');
  static String get downloadAndImportFile => _get('下载并导入文件', 'Download and import file');
  static String get invalidArchiveFormat =>
      _get('该文件不是有效的压缩包格式', 'The file is not a valid archive');

  // 发现页
  static String get exploreFilterSourcesHint => _get('筛选发现源', 'Filter discovery sources');
  static String get switchToSourceContent => _get('切换到源内容', 'Switch to source content');
  static String get exploreEmpty => _get('当前没有发现源！', 'Empty now!');
  static String get selectExploreCategory => _get('选择发现分类', 'Select a discovery category');
  static String get exploreCategoryHint => _get(
      '展开左侧书源并点击分类，在此浏览书籍',
      'Expand a source on the left and tap a category to browse books here');
  static String get uninstalled => _get('已卸载', 'Uninstalled');
  static String get noCategories => _get('无分类', 'No categories');

  // 字典查询页
  static String get cannotOpenOnlineDict =>
      _get('无法打开在线词典', 'Unable to open the online dictionary');
  static String get dictLookupTitle => _get('字典查询', 'Dictionary');
  static String get dictRulesManageTitle => _get('词典规则管理', 'Dictionary rules');
  static String get ruleManagement => _get('规则管理', 'Rules');
  static String get dictSearchHint => _get('输入单词查询释义', 'Enter a word to look up');
  static String get dictStartHint => _get('输入单词开始查询', 'Enter a word to start looking up');
  static String get dictOnlineFallbackHint =>
      _get('未收录的词可跳转在线词典', 'Words not found here can be looked up online');
  static String get localDictionary => _get('本地词典', 'Local dictionary');
  static String get dictUseOnlineBelow =>
      _get('可使用下方在线词典查询', 'Use the online dictionaries below');
  static String get onlineDictionary => _get('在线词典', 'Online dictionaries');
  static String get noDictRulesTapManage =>
      _get('暂无词典规则，点击右上角管理添加', 'No dictionary rules yet; add them via the top-right menu');
  static String get noRulesTapAddBelow =>
      _get('暂无规则，点击下方按钮添加', 'No rules yet; add one with the button below');
  static String get importDefaultAction => _get('导入默认', 'Import default');
  static String get addRuleAction => _get('添加规则', 'Add rule');
  static String get addDictionaryRule => _get('添加词典规则', 'Add dictionary rule');
  static String get dictRuleName => _get('规则名称', 'Rule name');
  static String get dictRuleQueryUrl => _get('查询地址', 'Lookup URL');
  static String get dictWordPlaceholderHint =>
      _get('使用 {{key}} 作为单词占位符', 'Use {{key}} as the word placeholder');

  // 字典规则管理页
  static String get deleteRuleTitle => _get('删除规则', 'Delete rules');
  static String get exportDictRules => _get('导出字典规则', 'Export dictionary rules');
  static String get addDictRuleEntry => _get('添加字典规则', 'Add dictionary rule');
  static String get editDictRule => _get('编辑字典规则', 'Edit dictionary rule');
  static String get importLocalAction => _get('本地导入', 'Import local');
  static String get importOnlineAction => _get('在线导入', 'Import online');
  static String get importQrAction => _get('扫码导入', 'Scan to import');
  static String get importPassphraseAction => _get('口令导入', 'Passphrase import');
  static String get qrContentMissing => _get('未获取到扫码内容', 'No scanned content received');
  static String get invalidHttpUrl => _get('请输入有效的 http(s) 地址', 'Enter a valid http(s) URL');
  static String get newRuleAction => _get('新增规则', 'Add rule');
  static String get dictRuleManagement => _get('字典规则管理', 'Dictionary rules');
  static String get moreOptions => _get('更多操作', 'More actions');
  static String get exitMultiSelect => _get('退出多选', 'Exit selection');
  static String get deselectAll => _get('取消全选', 'Deselect all');
  static String get enableSelected => _get('启用选中', 'Enable selected');
  static String get disableSelected => _get('禁用选中', 'Disable selected');
  static String get exportSelected => _get('导出选中', 'Export selected');
  static String get deleteSelected => _get('删除选中', 'Delete selected');
  static String get loadingDictRules => _get('加载字典规则...', 'Loading dictionary rules...');
  static String get noDictRules => _get('暂无字典规则', 'No dictionary rules');
  static String get noDictRulesHint =>
      _get('点击右下角按钮添加，或从右上角菜单导入', 'Tap the button below to add, or import from the top-right menu');
  static String get queryUrlNotConfigured => _get('（未配置查询地址）', '(Lookup URL not configured)');
  static String get ruleNameRequired => _get('规则名称不能为空', 'Rule name cannot be empty');
  static String get dictRuleQueryUrlLabel => _get('查询地址（urlRule）', 'Lookup URL(urlRule)');
  static String get dictRuleShowRuleLabel =>
      _get('显示规则（showRule，可选）', 'Display rule(showRule, optional)');
  static String get dictRuleShowRuleHint => _get(
      'CSS/XPath/JsonPath 或 @js: 规则，留空直接展示原文',
      'CSS/XPath/JsonPath or @js: rule; leave empty to show the raw text');
  static String get dictLocalImportHint => _get(
      '粘贴 JSON（对象数组或单对象，字段 name/urlRule/showRule，enabled/sortNumber 可选）',
      'Paste JSON (an array of objects or a single object; fields name/urlRule/showRule, enabled/sortNumber optional)');

  // ----- L10N 阶段 3：参数化文案 -----
  static String customButtonFailedWith(String error) => _locale == 'zh'
      ? '自定义按钮执行失败: $error'
      : 'Custom button failed: $error';
  static String operationFailedWith(String reason) =>
      _locale == 'zh' ? '操作失败：$reason' : 'Operation failed: $reason';
  static String get bookUrlCopied => _get('已拷贝书籍URL', 'Book URL copied');
  static String get tocUrlCopied => _get('已拷贝目录URL', 'Chapters URL copied');
  static String featureSupportedLater(String feature) => _locale == 'zh'
      ? '「$feature」后续版本支持'
      : '"$feature" will be supported in a later version';
  static String get bookReadRecordDisabled =>
      _get('已关闭本书阅读记录', 'Read record disabled for this book');
  static String get bookReadRecordRestored =>
      _get('已恢复本书阅读记录', 'Read record restored for this book');
  static String uploadFailedWith(String error) =>
      _locale == 'zh' ? '上传失败: $error' : 'Upload failed: $error';
  static String updateTaskName(String name) =>
      _locale == 'zh' ? '更新 $name' : 'Update $name';
  static String readChapters(int count) =>
      _locale == 'zh' ? '已读 $count 章' : '$count chapters read';
  static String totalChapters(int count) =>
      _locale == 'zh' ? '共 $count 章' : '$count chapters';
  static String readingWithTitle(String title) =>
      _locale == 'zh' ? '在读 · $title' : 'Reading · $title';
  static String latestWithTitle(String title) =>
      _locale == 'zh' ? '最新 · $title' : 'Latest · $title';
  static String tocUpdated(int count) => _locale == 'zh'
      ? '目录已更新，共 $count 章'
      : 'Chapters updated, $count in total';
  static String updateFailedWith(String error) =>
      _locale == 'zh' ? '更新失败: $error' : 'Update failed: $error';
  static String confirmRemoveFromShelf(String name) => _locale == 'zh'
      ? '确定将《$name》移出书架吗？'
      : 'Remove "$name" from the bookshelf?';
  static String removeFromShelfFailedWith(String error) =>
      _locale == 'zh' ? '移出书架失败：$error' : 'Failed to remove from bookshelf: $error';
  static String removedFromShelf(String name) =>
      _locale == 'zh' ? '《$name》已移出书架' : '"$name" removed from the bookshelf';
  static String addToShelfFailedWith(String error) =>
      _locale == 'zh' ? '加入书架失败：$error' : 'Failed to add to bookshelf: $error';
  static String addedToShelf(String name) =>
      _locale == 'zh' ? '《$name》已加入书架' : '"$name" added to the bookshelf';
  static String pinFailedWith(String error) =>
      _locale == 'zh' ? '置顶失败: $error' : 'Failed to pin to top: $error';
  static String chapterCacheCleared(int count) => _locale == 'zh'
      ? '已清除 $count 条章节缓存'
      : 'Cleared $count chapter cache entries';
  static String clearCacheFailedWith(String error) =>
      _locale == 'zh' ? '清除缓存失败: $error' : 'Failed to clear the cache: $error';
  static String fileTypeUnsupported(String name) =>
      _locale == 'zh' ? '文件类型不支持：$name' : 'Unsupported file type: $name';
  static String importedToShelf(String name) =>
      _locale == 'zh' ? '《$name》已导入书架' : '"$name" imported to the bookshelf';
  static String dictWordNotFound(String word) => _locale == 'zh'
      ? '本地词典未收录「$word」'
      : '"$word" is not in the local dictionary';
  static String defaultDictRulesImported(int count) => _locale == 'zh'
      ? '已导入 $count 条原版默认词典规则'
      : 'Imported $count default dictionary rules';
  static String saveFailedWith(String error) =>
      _locale == 'zh' ? '保存失败：$error' : 'Save failed: $error';
  static String toggleRuleFailedWith(String error) =>
      _locale == 'zh' ? '启用/禁用失败：$error' : 'Failed to toggle the rule: $error';
  static String reorderSaveFailedWith(String error) =>
      _locale == 'zh' ? '排序保存失败：$error' : 'Failed to save the order: $error';
  static String rulesToggled(bool enabled, int count) => _locale == 'zh'
      ? '已${enabled ? '启用' : '禁用'} $count 条规则'
      : '${enabled ? 'Enabled' : 'Disabled'} $count rules';
  static String batchToggleFailedWith(bool enabled, String error) => _locale == 'zh'
      ? '批量${enabled ? '启用' : '禁用'}失败：$error'
      : 'Failed to ${enabled ? 'enable' : 'disable'} the selected rules: $error';
  static String confirmDeleteDictRules(int count, String names) => _locale == 'zh'
      ? '确定删除选中的 $count 条字典规则吗？\n（$names）'
      : 'Delete the $count selected dictionary rules?\n($names)';
  static String rulesDeleted(int count) =>
      _locale == 'zh' ? '已删除 $count 条规则' : 'Deleted $count rules';
  static String ruleAddedNamed(String name) =>
      _locale == 'zh' ? '已添加规则「$name」' : 'Rule "$name" added';
  static String ruleUpdatedNamed(String name) =>
      _locale == 'zh' ? '已更新规则「$name」' : 'Rule "$name" updated';
  static String dictRulesImported(int count) =>
      _locale == 'zh' ? '已导入 $count 条字典规则' : 'Imported $count dictionary rules';
  static String importFailedWith(String error) =>
      _locale == 'zh' ? '导入失败：$error' : 'Import failed: $error';
  static String defaultDictRuleRulesImported(int count) => _locale == 'zh'
      ? '已导入 $count 条默认字典规则'
      : 'Imported $count default dictionary rules';
  static String importDefaultFailedWith(String error) =>
      _locale == 'zh' ? '导入默认失败：$error' : 'Failed to import defaults: $error';
  static String selectedItemsCount(int count) =>
      _locale == 'zh' ? '已选 $count 项' : '$count selected';

  // ============== L10N 批 1 线 B：widgets 根层 + privacy/manga/help/navigation ==============

  // ----- 通用按钮 / 标签 -----
  static String get dialogClose => _get('关闭', 'Close');
  static String get imageLoadFailedLabel =>
      _get('图片加载失败', 'Failed to load the image');
  static String get listLayoutLabel => _get('列表', 'List');
  static String get gridLayoutLabel => _get('网格', 'Grid');
  static String get loadingSemantics => _get('加载中', 'Loading');
  static String get allLabel => _get('全部', 'All');
  static String get searchPlaceholder => _get('搜索...', 'Search...');
  static String get copyAction => _get('复制', 'Copy');
  static String get copiedLabel => _get('已复制', 'Copied');
  static String get copyErrorLabel => _get('复制错误', 'Copy error');
  static String get originalErrorLabel => _get('原始错误：', 'Original error: ');
  static String get testAction => _get('测试', 'Test');
  static String get previewAction => _get('预览', 'Preview');
  static String get downloadAction => _get('下载', 'Download');
  static String get verifyAction => _get('验证', 'Verify');
  static String get unlockAction => _get('解锁', 'Unlock');
  static String get startAction => _get('开始', 'Start');
  static String get hiddenLabel => _get('已隐藏', 'Hidden');
  static String get unknownTime => _get('未知时间', 'Unknown time');
  static String get unknownError => _get('未知错误', 'Unknown error');
  static String get noneLabel => _get('（无）', '(None)');
  static String get noUpdateLog => _get('（无更新说明）', '(No changelog)');
  static String get uncategorized => _get('未分类', 'Uncategorized');
  static String get selectOperation => _get('选择操作', 'Select action');
  static String get goLogin => _get('去登录', 'Log in');
  static String get notNow => _get('暂不', 'Not now');
  static String get confirmTextDefault => _get('确认', 'Confirm');
  static String get cancelTextDefault => _get('取消', 'Cancel');

  // ----- 通用参数化 -----
  static String unreadChapters(int count) =>
      _locale == 'zh' ? '$count 章未读' : '$count unread chapters';
  static String failureWithReason(String action, String error) =>
      _locale == 'zh' ? '$action失败：$error' : '$action failed: $error';
  static String copiedLink(String url) =>
      _locale == 'zh' ? '已复制链接：$url' : 'Link copied: $url';
  static String loginDialogTitle(String name) =>
      _locale == 'zh' ? '登录 - $name' : 'Log in - $name';
  static String loginTitleWithSource(String name) =>
      _locale == 'zh' ? '登录 $name' : 'Log in to $name';

  // ----- 漫画阅读设置（manga/manga_config_sheet） -----
  static String get mangaReadingSettings =>
      _get('漫画阅读设置', 'Manga Reading Settings');
  static String get mangaReadingMode => _get('阅读模式', 'Reading strategy');
  static String get mangaPageScale => _get('页面适配', 'Page fit');
  static String get mangaSidePadding => _get('侧边留白', 'Side margin');
  static String get mangaAutoReadDesc => _get(
      '单页式定时翻页；条漫定时滚动',
      'Timed page turning in paged mode; timed scrolling in webtoon mode');
  static String get mangaAutoRead => _get('自动翻页', 'Auto scroll');
  static String get mangaAlignCenter => _get('居中', 'Center');
  static String get copyLinkLabel => _get('复制链接', 'Copy link');
  static String get mangaAutoSpeed => _get('自动速度', 'Auto speed');
  static String mangaSpeedLevel(int level) =>
      _locale == 'zh' ? '$level 档' : 'Level $level';
  static String get mangaDisplayEffects => _get('显示效果', 'Display');
  static String get mangaGrayscale => _get('灰度', 'Grayscale');
  static String get mangaEInk => _get('电子纸', 'E-ink');
  static String get mangaEInkDesc =>
      _get('灰度近似；阈值已持久化', 'Approximate grayscale; the threshold is saved');
  static String get mangaEInkThreshold => _get('电子纸阈值', 'E-ink threshold');
  static String get mangaColorFilter => _get('色彩滤镜', 'Color filter');
  static String get brightnessLabel => _get('亮度', 'Brightness');
  static String get mangaFooterSettings => _get('页脚设置', 'Footer');
  static String get mangaTapAreas => _get('点击区域', 'Tap areas');
  static String get mangaFilterEntry => _get('滤镜', 'Filter');
  static String get mangaFollowGlobal => _get('跟随全局', 'Follow global');
  static String get mangaThisBook => _get('本书', 'This book');
  static String get mangaAlignLeft => _get('左对齐', 'Left aligned');
  static String get mangaHideFooter => _get('隐藏页脚', 'Hide footer');
  static String get mangaFooterHidden => _get('页脚已隐藏', 'Footer hidden');
  static String get mangaFooterEmpty =>
      _get('（页脚内容为空）', '(Footer content is empty)');
  static String get mangaPageCount => _get('页数', 'Page');
  static String get mangaChapterLabel => _get('章节', 'Chapter');
  static String get mangaProgressLabel => _get('总进度', 'Progress');
  static String get mangaBgColor => _get('背景颜色', 'Background color');
  static String get mangaClickActionHint =>
      _get('点击格子循环切换该区域动作', 'Tap a cell to cycle the action for that area');
  static String get mangaDisableClickScroll =>
      _get('禁用点击翻页', 'Disable Tap to Turn Page');
  static String get mangaDisableScale => _get('禁用漫画缩放', 'Disable Manga Zoom');
  static String get mangaDisablePageAnim =>
      _get('禁用翻页动画', 'Disable Page Turn Animation');
  static String get mangaHideTitle => _get('隐藏漫画列表标题', 'Hide Manga List Titles');
  static String get mangaVolumeKey => _get('音量键翻页', 'Volume Keys to Turn Page');
  static String get mangaReverseVolumeKey =>
      _get('反转音量键翻页方向', 'Reverse Volume-Key Page Turn Direction');
  static String get mangaLongPressSave =>
      _get('长按保存图片', 'Long press to save image');
  static String get mangaDisableFadeIn =>
      _get('禁用加载淡入动画', 'Disable Loading Fade-In Animation');
  static String get mangaSampleChapter => _get('第三话', 'Ep-3');

  // ----- 朗读定时（read_aloud_timer_sheet） -----
  static String get readAloudTimerTitle => _get('定时停止', 'Stop timer');
  static String get minutesTab => _get('分钟', 'Minutes');
  static String get chaptersTab => _get('章节', 'Chapters');
  static String readAloudTimerMinutes(int minutes) =>
      _locale == 'zh' ? '$minutes 分钟' : '$minutes min';
  static String readAloudTimerChapters(int chapters) =>
      _locale == 'zh' ? '$chapters 章' : '$chapters chapters';
  static String readAloudTimerRemaining(String countdown) =>
      _locale == 'zh' ? '剩余 $countdown' : '$countdown left';
  static String readAloudTimerChaptersRemaining(int chapters) =>
      _locale == 'zh' ? '剩余 $chapters 章' : '$chapters chapters left';
  static String get readAloudTimerFinishChapterStop =>
      _get('读完本章后停止', 'Stop after finishing this chapter');
  static String get readAloudTimerFinishChapter =>
      _get('读完本章再停', 'Finish the current chapter first');
  static String get readAloudTimerFinishChapterDesc => _get(
      '到点后继续读完当前章，再在章末停止',
      'When the timer ends, finish the current chapter and stop at its end');
  static String get readAloudTimerChapterModeHint => _get(
      '章节模式会在读完设定章数后的章末停止，无需「读完本章再停」。',
      'Chapter mode stops at the end of the chapter after the set number of chapters, so "finish the current chapter first" is not needed.');
  static String get readAloudTimerStop => _get('停止定时', 'Stop timer');
  static String get readAloudTimerOff => _get('关闭定时', 'Turn timer off');

  // ----- 导出对话框（export_dialog） -----
  static String exportBookTitle(String name) =>
      _locale == 'zh' ? '导出$name' : 'Export $name';
  static String get exportFormat => _get('导出格式', 'Export format');
  static String get exportEncoding => _get('字符编码', 'Character encoding');
  static String get exportFileNameTemplate => _get('文件名模板', 'File name template');
  static String get exportFileNameVars =>
      _get('可用变量：{name} {author}', 'Available variables: {name} {author}');
  static String get exportChapterRange => _get('章节范围', 'Chapter range');
  static String get exportChapterRangeHint => _get(
      '索引从 0 起；留空表示全部章节', 'Index starts at 0; leave empty for all chapters');
  static String get exportRangeStart => _get('起始', 'Start');
  static String get exportRangeEnd => _get('结束', 'End');
  static String get exportPath => _get('导出路径', 'Export path');
  static String get exportPickDirectory =>
      _get('点击选择导出目录', 'Tap to choose the export folder');
  static String get exportChooseDirectory =>
      _get('选择导出目录', 'Choose export folder');
  static String get exportIncludeToc => _get('包含目录', 'Include chapters');
  static String get exportIncludeTocDesc =>
      _get('导出时包含书籍的目录结构', "Include the book's chapter list in the export");
  static String get exportUploadWebdav => _get('上传到 WebDAV', 'Upload to WebDAV');
  static String get exportUploadWebdavDesc =>
      _get('导出完成后自动上传到远程服务器', 'Upload to the remote server after exporting');
  static String exportPreviewFailed(String error) =>
      _locale == 'zh' ? '获取预览信息失败：$error' : 'Failed to load the preview: $error';
  static String exportChapterCount(int count) =>
      _locale == 'zh' ? '章节数：$count' : 'Chapters: $count';
  static String get exportInProgress => _get('正在导出...', 'Exporting...');
  static String get exportUnsupportedFormat =>
      _get('不支持的导出格式', 'Unsupported export format');
  static String get exportPickPathFirst =>
      _get('请先选择导出目录', 'Choose an export folder first');
  static String get exportStarting => _get('开始导出...', 'Starting export...');
  static String get exportWritingFile =>
      _get('导出完成，正在写入文件...', 'Export finished, writing the file...');
  static String exportWriteFailed(String error) =>
      _locale == 'zh' ? '文件写入失败：$error' : 'Failed to write the file: $error';
  static String get exportUploadingToWebdav =>
      _get('上传到 WebDAV...', 'Uploading to WebDAV...');
  static String get exportUploadDone =>
      _get('导出并上传成功！', 'Exported and uploaded successfully!');
  static String get exportUploadFailedAfter => _get(
      '导出成功，但 WebDAV 上传失败', 'Exported successfully, but the WebDAV upload failed');
  static String exportSavedTo(String path) =>
      _locale == 'zh' ? '已保存：$path' : 'Saved: $path';
  static String get exportSuccess => _get('导出成功！', 'Export successful!');

  // ----- 导出目标 Sheet（export_file_sheet） -----
  static String exportUploadSuccessWith(String url) =>
      _locale == 'zh' ? '上传成功：$url' : 'Uploaded: $url';
  static String get exportUploadFailedTitle => _get('上传失败', 'Upload failed');
  static String get exportSaveFailedTitle => _get('保存失败', 'Save failed');
  static String get exportSaving => _get('正在保存…', 'Saving…');
  static String get exportUploading => _get('正在上传…', 'Uploading…');
  static String get exportSaveToLocal => _get('保存到本地', 'Save to local');
  static String get exportSystemSaveDialogDesc => _get(
      '通过系统保存对话框选择保存位置', 'Choose the location in the system save dialog');
  static String get exportFirstSaveHint => _get(
      '首次保存需选择保存文件夹，之后沿用', 'Choose a folder on first save; it is reused afterwards');
  static String exportSavedToFolder(String directory) =>
      _locale == 'zh' ? '保存到「$directory」' : 'Saved to "$directory"';
  static String get exportChangeSaveLocation =>
      _get('换个保存位置', 'Change save location');
  static String get exportChooseFolderDesc =>
      _get('选择文件保存到哪个文件夹', 'Choose the folder to save the file in');
  static String exportCurrentFolder(String directory) => _locale == 'zh'
      ? '当前：$directory · 点击重新选择文件夹'
      : 'Current: $directory · tap to choose another folder';
  static String get exportUploadDirect => _get('上传直链', 'Upload direct link');
  static String get exportUploadDirectDesc => _get(
      '按直链上传规则上传，返回可分享的下载链接',
      'Upload using the direct-link rules and get a shareable download link');
  static String exportFileLabel(String name) =>
      _locale == 'zh' ? '导出文件：$name' : 'File: $name';
  static String get exportFolderSelected => _get('已选文件夹', 'Folder selected');
  static String get exportUploadSuccessTitle => _get('上传成功', 'Uploaded');
  static String get exportCopyPassphrase => _get('复制口令', 'Copy passphrase');
  static String get exportCopyPassphraseDesc => _get(
      '生成可粘贴到阅读「口令导入」的分享口令，可设置有效期',
      'Generate a passphrase for "Passphrase import" in Legado, with an optional expiry');
  static String get exportChangePosition => _get('换个位置', 'Change location');
  static String get exportUseLegacyDialog =>
      _get('改用系统另存对话框', 'Use the system save-as dialog');
  static String copyFailedWith(String error) =>
      _locale == 'zh' ? '复制失败：$error' : 'Copy failed: $error';

  // ----- 源规则帮助（source_rule_help_sheet） -----
  static String get sourceRuleHelpTitle => _get('规则语法帮助', 'Rule syntax help');
  static String get sourceRuleHelpSubtitle => _get(
      '书源规则速查：各规则含义、@ 前缀语法与 jsLib 常用函数。',
      'Quick reference for book source rules: what each rule does, the @ prefix syntax, and common jsLib functions.');
  static String get sourceRuleSection30 =>
      _get('阅读 3.0 源规则说明', 'Legado 3.0 source rules');
  static String get sourceRuleCode30 => _get(
      '搜索: searchUrl   发现: exploreUrl\n详情: bookInfoRule   目录: tocRule   正文: contentRule',
      'Search: searchUrl   Discover: exploreUrl\nDetails: bookInfoRule   TOC: tocRule   Content: contentRule');
  static String get sourceRuleSearchDesc => _get(
      'searchUrl：列表页请求地址，{{key}} 表示关键词、{{page}} 表示页码。',
      'searchUrl: request URL of the list page; {{key}} is the keyword and {{page}} is the page number.');
  static String get sourceRuleExploreDesc => _get(
      'exploreUrl：发现页的分类/榜单地址，可用规则生成分类与子列表。',
      'exploreUrl: category/ranking URL for the Discover page; rules can generate categories and sub-lists.');
  static String get sourceRuleInfoDesc => _get(
      'bookInfoRule：从详情页解析书名、作者、封面、简介与目录页链接。',
      'bookInfoRule: parse title, author, cover, summary and the TOC URL from the details page.');
  static String get sourceRuleTocDesc => _get(
      'tocRule：从目录页解析章节名与章节链接列表（含分卷结构）。',
      'tocRule: parse chapter names and links from the TOC page (including volume structure).');
  static String get sourceRuleContentDesc => _get(
      'contentRule：从章节页解析正文内容，可用 ## 做正则替换清洗。',
      'contentRule: parse the content from the chapter page; ## can be used for regex replacement.');
  static String get sourceRulePrefixSection => _get('@规则语法', '@ rule syntax');
  static String get sourceRulePrefixDesc => _get(
      '规则前缀决定解析方式；不加前缀时默认按 HTML 规则解析。'
          '常用组合：|| 取首个非空、&& 合并、%% 交错、## 正则替换。',
      'The rule prefix decides how to parse; without a prefix HTML rules are used. '
          'Common combinations: || first non-empty, && merge, %% interleave, ## regex replace.');
  static String get sourceRuleJsLibSection =>
      _get('jsLib 与内置变量', 'jsLib and built-in variables');
  static String get sourceRuleJsLibDesc => _get(
      'jsLib 中定义的函数可被 search / getChapters / getContent 复用'
          '（JS 书源即 mainJs 顶层函数）。常用内置对象与函数：',
      'Functions defined in jsLib can be reused by search / getChapters / getContent '
          '(for JS sources these are top-level functions in mainJs). Common built-in objects and functions:');
  static String get sourceRuleCssDesc => _get(
      '按 CSS 选择器从 HTML 中取文本或属性。',
      'Extract text or attributes from HTML with a CSS selector.');
  static String get sourceRuleJsonDesc => _get(
      '按 JSONPath 从 JSON 响应中取值。', 'Extract values from a JSON response with JSONPath.');
  static String get sourceRuleJsDesc => _get(
      '交给 JavaScript 处理上一步结果并返回最终值。',
      'Pass the previous result to JavaScript and return the final value.');
  static String get sourceRuleXPathDesc =>
      _get('按 XPath 从 HTML/XML 中取值。', 'Extract values from HTML/XML with XPath.');
  static String get sourceRuleAjaxDesc => _get(
      '发起 HTTP 请求并返回响应文本（自动携带 Cookie 与请求头）。',
      'Send an HTTP request and return the response text (cookies and headers are included automatically).');
  static String get sourceRuleBase64Desc => _get(
      '对 Base64 字符串解码并返回原始文本。',
      'Decode a Base64 string and return the original text.');
  static String get sourceRuleBookDesc => _get(
      '当前书籍对象，含 bookUrl / name / author / tocUrl 等字段。',
      'The current book object with fields such as bookUrl / name / author / tocUrl.');
  static String get sourceRuleBaseUrlDesc =>
      _get('当前规则对应的页面地址。', 'The page URL the current rule applies to.');
  static String get sourceRuleChapterDesc => _get(
      '当前章节对象，含 url / title 等字段。',
      'The current chapter object with fields such as url / title.');
  static String get sourceRuleResultDesc => _get(
      '上一步规则的输出结果（链式规则中继续处理时使用）。',
      'Output of the previous rule (used when chaining rules).');
  static String sourceRuleExample(String description, String sample) =>
      _locale == 'zh' ? '$description 例：$sample' : '$description e.g. $sample';

  // ----- 分组管理（group_manage_dialog 及三域薄包装） -----
  static String get groupManageTitle => _get('分组管理', 'Group Management');
  static String get addGroup => _get('添加分组', 'Add group');
  static String get groupNameLabel => _get('分组名称', 'Group name');
  static String get renameGroup => _get('重命名分组', 'Rename group');
  static String get renameGroupHint => _get('输入新分组名称', 'Enter a new group name');
  static String get deleteGroup => _get('删除分组', 'Delete group');
  static String get noGroups => _get('暂无分组', 'No groups');
  static String get rssSourceNoun => _get('订阅源', 'RSS source');
  static String groupExists(String name) =>
      _locale == 'zh' ? '分组「$name」已存在' : 'Group "$name" already exists';
  static String noUngroupedItems(String noun) => _locale == 'zh'
      ? '没有未分组的$noun可归入该分组'
      : 'No ungrouped $noun to add to this group';
  static String get addGroupFailedNoReason =>
      _get('添加分组失败', 'Failed to add the group');
  static String confirmDeleteGroup(String group, String noun) => _locale == 'zh'
      ? '确定要删除分组「$group」吗？分组内$noun将移出该分组。'
      : 'Delete the group "$group"? Its $noun will be removed from the group.';
  static String get customGroupNameTitle =>
      _get('输入自定义源分组名称', 'Enter the custom source group name');
  static String get customGroupNameDesc =>
      _get('关闭替换分组 / 开启添加分组', 'Off: replace group / On: add group');
  static String get operationFailedNoReason => _get('操作失败', 'Operation failed');

  // ----- 隐私（privacy/） -----
  static String get privacySpace => _get('隐私空间', 'Private space');
  static String get privacyEnterPassword =>
      _get('输入隐私密码以继续', 'Enter the privacy password to continue');
  static String get privacyPasswordLabel => _get('隐私密码', 'Privacy password');
  static String get useBiometrics => _get('使用生物识别', 'Use biometrics');
  static String get exitApp => _get('退出应用', 'Exit app');
  static String get enterPassword => _get('请输入密码', 'Enter the password');
  static String get wrongPassword => _get('密码错误', 'Wrong password');
  static String get wrongPasswordRetry =>
      _get('密码错误，请重试', 'Wrong password, please try again');
  static String get privacyPolicyReadFailed =>
      _get('无法读取隐私设置', 'Unable to read privacy settings');
  static String get privacyPolicyReadFailedDesc => _get(
      '为保护私密内容，隐私设置恢复前不会显示应用内容。请重试。',
      'To protect private content, app content is hidden until the privacy settings load. Please retry.');
  static String get privacyCredentialReadFailed =>
      _get('无法读取隐私凭据', 'Unable to read privacy credentials');
  static String get privacyCredentialReadFailedDesc => _get(
      '为保护私密内容，凭据恢复前不会显示应用内容。请重试。',
      'To protect private content, app content is hidden until the credentials load. Please retry.');
  static String get privacyNotSet =>
      _get('未设置隐私密码', 'No privacy password set');
  static String get privacyNotSetDesc => _get(
      '私密内容需要隐私密码。请先在隐私设置中设置密码后再验证。',
      'Private content requires a privacy password. Set one in privacy settings before verifying.');
  static String get verifyPrivacyPassword =>
      _get('验证隐私密码', 'Verify privacy password');
  static String get privacyScopeEveryTime => _get(
      '验证后仅放行当前内容，离开即重新锁定',
      'Only the current content is unlocked; it locks again when you leave');
  static String get privacyScopeAppSession => _get(
      '验证后本次应用内不再重复验证', 'No further verification until the app is closed');
  static String get privacyScopeUntilBackground => _get(
      '验证后离开后台超过宽限时间需重新验证',
      'Verification is required again after being in the background beyond the grace period');
  static String get privateContent => _get('私密内容', 'Private content');
  static String get verifyToContinue => _get('验证后继续', 'Verify to continue');
  static String get verifyAndContinue => _get('验证并继续', 'Verify and continue');
  static String get verifyToViewContent =>
      _get('验证后查看内容', 'Verify to view the content');
  static String get verifyAndViewContent => _get('验证并查看', 'Verify and view');
  static String get goSetPassword => _get('去设置密码', 'Set a password');
  static String get verifyToRead => _get('验证后阅读', 'Verify to read');
  static String get verifyToReadBook => _get('验证后阅读本书', 'Verify to read this book');
  static String get verifyAndRead => _get('验证并阅读', 'Verify and read');

  // ----- 帮助（help/） -----
  static String get helpSourceCode => _get('源码', 'Source code');
  static String get helpToc => _get('目录', 'Contents');
  static String helpLoadFailed(String error) =>
      _locale == 'zh' ? '加载帮助失败：$error' : 'Failed to load help: $error';
  static String cannotOpenLinkWith(String href) =>
      _locale == 'zh' ? '无法打开链接：$href' : 'Unable to open the link: $href';

  // ----- 侧栏导航（navigation/） -----
  static String get myPaneEmptyHint =>
      _get('选择左侧项目', 'Select an item on the left');
  static String get collapseSidebar => _get('收起侧栏', 'Collapse sidebar');
  static String get expandSidebar => _get('展开侧栏', 'Expand sidebar');
  static String get bookshelfGroups => _get('书架分组', 'Book Groups');
  static String get collapseSearch => _get('收起搜索', 'Collapse search');
  static String get expandSearch => _get('展开搜索', 'Expand search');

  // ----- 备份 / 恢复（backup_*.dart） -----
  static String get webdavConfigureFirst =>
      _get('请先配置 WebDAV', 'Configure WebDAV first');
  static String get webdavNotConfiguredAbort =>
      _get('未配置 WebDAV，已取消备份', 'WebDAV is not configured; backup cancelled');
  static String get backupToLocal => _get('备份至本地', 'Backup to Local');
  static String get backupToNetwork => _get('备份至网络', 'Backup to Network');
  static String get backupToLocalAndNetwork =>
      _get('备份至本地与网络', 'Backup to Local & Network');
  static String get restoreFromNetwork => _get('网络恢复', 'Restore from Network');
  static String get restoreLatestLocal => _get('本地最新', 'Latest local');
  static String get restoreLatestRemote => _get('远端最新', 'Latest remote');
  static String get webdavNewerBackupConfirm => _get(
      'WebDAV 备份比本地新，是否恢复？',
      'The WebDAV backup is newer than the local one. Restore it?');
  static String get backupContentSubtitle => _get(
      '勾选后备份时不写入该表；恢复该备份时本机这些表保持原值。',
      'Checked tables are skipped when backing up; restoring keeps the local tables unchanged.');
  static String get restoreIgnoreTitle => _get('恢复忽略', 'Restore exclusions');
  static String get restoreIgnoreSubtitle => _get(
      '恢复时跳过对应项；备份忽略请单独设置。',
      'Skipped items are excluded when restoring; backup exclusions are configured separately.');
  static String get selectRemoteBackup => _get('选择远端备份', 'Select a remote backup');

  // ----- 崩溃日志（crash_log_dialog） -----
  static String get crashOccurred =>
      _get('上次运行发生崩溃', 'The app crashed on the last run');
  static String crashTimeLabel(String time) =>
      _locale == 'zh' ? '崩溃时间: $time' : 'Crash time: $time';
  static String get showDetails => _get('查看详情', 'View details');
  static String get hideDetails => _get('收起详情', 'Hide details');

  // ----- 护眼（eye_protection_config_sheet） -----
  static String get eyeProtectionIntensity =>
      _get('护眼强度', 'Eye protection intensity');
  static String get eyeProtectionCurrentIntensity =>
      _get('当前强度', 'Current intensity');
  static String get colorTemperature => _get('色温', 'Color temperature');
  static String get colorTemperatureCurrent =>
      _get('当前色温', 'Current color temperature');

  // ----- 视频（video_settings_dialog / video_float_window_button） -----
  static String get videoPlaybackSettings => _get('播放设置', 'Playback settings');
  static String get videoAutoPlay => _get('自动播放', 'Auto play');
  static String get videoDefaultFloatWindow =>
      _get('默认悬浮窗播放', 'Play in a floating window by default');
  static String get videoAutoFullscreen => _get('自动全屏', 'Auto fullscreen');
  static String get videoFullscreenProgressBar =>
      _get('全屏底栏进度条', 'Fullscreen bottom progress bar');
  static String get videoLongPressSpeed => _get('长按倍速', 'Long-press speed');
  static String get videoFloatWindow => _get('悬浮窗', 'Floating window');
  static String get videoNormalSpeed => _get('倍速', 'Speed');
  static String videoSpeedTip(String speed) =>
      _locale == 'zh' ? '$speed倍播放中' : 'Playing at ${speed}x';
  static String videoLongPressSpeedTip(String speed) =>
      _locale == 'zh' ? '$speed倍速播放中' : 'Playing at ${speed}x (long press)';
  static String videoEpisodesTitle(int count) =>
      _locale == 'zh' ? '选集（$count）' : 'Episodes ($count)';

  // ----- 更新对话框（update_dialog） -----
  static String get ignoreThisVersion => _get('忽略此版本', 'Ignore this version');
  static String get versionIgnored => _get('已忽略此版本', 'This version is ignored');
  static String get backupDownload => _get('备用下载', 'Alternative download');
  static String get openInBrowser => _get('浏览器打开', 'Open in browser');

  // ----- 打开链接确认（open_url_confirm_dialog） -----
  static String get openUrlConfirmTitle => _get('跳转确认', 'Confirm navigation');
  static String get openUrlConfirmContent => _get(
      '正在请求跳转链接/应用，是否跳转？',
      'A link or app is requesting to open. Continue?');
  static String get openUrlAction => _get('跳转', 'Open');
  static String get cannotOpenLinkShort =>
      _get('无法打开链接', 'Unable to open the link');
  static String get openLinkFailed => _get('打开链接失败', 'Failed to open the link');

  // ----- 口令（passphrase_import / source_share_passphrase_dialog） -----
  static String get passphraseNotShare =>
      _get('不是分享口令', 'Not a share passphrase');
  static String get passphraseInvalid => _get('口令无效', 'Invalid passphrase');
  static String get passphraseExpired => _get('口令已过期', 'Passphrase expired');
  static String get passphraseLabel => _get('口令', 'Passphrase');
  static String get passphraseExpiryDays => _get('有效期（天）', 'Valid for (days)');
  static String get passphraseExpiryInvalid =>
      _get('请输入有效期天数', 'Enter the number of days');
  static String passphraseExpiryRange(int maxDays) => _locale == 'zh'
      ? '有效期需为 0~$maxDays 天'
      : 'Validity must be between 0 and $maxDays days';
  static String passphraseExpiryHelper(int maxDays) => _locale == 'zh'
      ? '0 表示永久有效，最长 $maxDays 天'
      : '0 means no expiry; maximum $maxDays days';
  static String get passphraseWarning => _get(
      '口令包含分享直链，仅发送给可信的人；过期后无法导入。',
      'The passphrase contains a direct link. Send it only to people you trust; it cannot be imported after it expires.');
  static String passphrasePrefixMissing(String prefix) => _locale == 'zh'
      ? '未识别到「$prefix」前缀，请确认已完整复制。'
      : 'The "$prefix" prefix was not found; make sure the whole passphrase was copied.';
  static String passphraseMalformed(String prefix) => _locale == 'zh'
      ? '请先复制分享口令（以「$prefix」开头）。'
      : 'Copy a share passphrase first (it starts with "$prefix").';
  static String get passphraseFormatInvalid => _get(
      '口令格式或分享链接无效，可能复制不完整，请重新复制。',
      'The passphrase or share link is invalid. The copy may be incomplete; please copy it again.');
  static String get passphraseExpiredDesc => _get(
      '该口令已超过分享有效期，请联系分享者重新生成。',
      'This passphrase has expired. Ask the sender to generate a new one.');

  // ----- 验证码（verification_code_listener） -----
  static String get disableBookSource => _get('禁用书源', 'Disable book source');
  static String get deleteBookSource => _get('删除书源', 'Delete book source');
  static String get captchaImageLoadFailed =>
      _get('验证码图片加载失败', 'Failed to load the CAPTCHA image');
  static String get captchaHint => _get('输入验证码', 'Enter the CAPTCHA');
  static String get enterCaptcha => _get('请输入验证码', 'Please enter the CAPTCHA');
  static String captchaRequiredFor(String name) =>
      _locale == 'zh' ? '「$name」需要验证码' : '"$name" requires a CAPTCHA';

  // ----- 登录（classic_login_dialog / login_v2_dialog） -----
  static String get loginHeader => _get('登录头', 'Login header');
  static String get viewLoginHeader => _get('查看登录头', 'View login header');
  static String get deleteLoginHeader => _get('删除登录头', 'Delete login header');
  static String get clearLoginInfo => _get('清除登录信息', 'Clear login info');
  static String get loginHeaderDeleted =>
      _get('登录头已删除', 'Login header deleted');
  static String get loginInfoCleared => _get('登录信息已清除', 'Login info cleared');
  static String get loginFailed => _get('登录失败', 'Login failed');
  static String get loginFormParseFailed =>
      _get('登录表单解析失败', 'Failed to parse the login form');
  static String get loginFormNotConfigured =>
      _get('该书源未配置登录表单', 'This source has no login form configured');
  static String get loginActionFailed => _get('动作执行失败', 'Action failed');
  static String get loginErrorOccurred => _get('登录出错', 'Login error');

  // ----- 封面规则（cover_rule_config_dialog） -----
  static String get coverPreview => _get('封面预览', 'Cover preview');
  static String get coverRules => _get('封面规则', 'Cover rules');
  static String get coverSearchUrl => _get('搜索 URL', 'Search URL');
  static String get coverSearchUrlHint =>
      _get('支持 {{key}} 模板', 'Supports the {{key}} template');
  static String get coverExtractRule => _get('封面提取规则', 'Cover extraction rule');
  static String get coverTestByTitle => _get('按书名测试', 'Test by title');
  static String get coverTitleHint => _get('输入书名', 'Enter a title');
  static String get coverTitleRequired => _get('请输入书名', 'Enter a title');
  static String get coverRulesRequired => _get(
      '搜索url和cover规则不能为空', 'The search URL and cover rule cannot be empty');
  static String get coverNoCandidates => _get(
      '未搜到候选封面（无启用规则或全部失败）',
      'No candidate covers found (no enabled rules or all failed)');
  static String get coverUrlCopied => _get('封面 URL 已复制', 'Cover URL copied');
  static String get loadFailedNoReason => _get('加载失败', 'Failed to load');
  static String get searchFailedNoReason => _get('搜索失败', 'Search failed');
  static String get saveFailedNoReason => _get('保存失败', 'Failed to save');
  static String get deleteFailedNoReason => _get('删除失败', 'Failed to delete');

  // ----- 颜色输入（container_color_dialog） -----
  static String get colorInputHint =>
      _get('#AARRGGBB 或 #RRGGBB', '#AARRGGBB or #RRGGBB');
  static String get colorInputInvalid =>
      _get('请输入 6/8 位十六进制颜色', 'Enter a 6- or 8-digit hex color');

  // ----- 字典（dict_dialog） -----
  static String get dictLocalTab => _get('本地', 'Local');
  static String get dictNotInLocal =>
      _get('本地词典未收录', 'Not found in the local dictionary');
  static String get openOnlineDict => _get('打开在线词典', 'Open online dictionary');
  static String dictQueryInRule(String rule, String word) =>
      _locale == 'zh' ? '在 $rule 中查询「$word」' : 'Look up "$word" in $rule';

  // ----- 发现 / 搜索筛选（explore_*.dart / search_filter_panel） -----
  static String get sourceRequiresLogin =>
      _get('书源需要登录', 'This source requires login');
  static String get loginToBrowseCategory =>
      _get('登录后即可浏览该分类内容', 'Log in to browse this category');
  static String get loadingPleaseWait =>
      _get('正在加载，请稍候再刷新', 'Loading, please refresh again later');
  static String get loadingPleaseWaitToJump => _get(
      '正在加载，请加载完成后再跳页', 'Loading, please wait before jumping to a page');
  static String get noBooks => _get('暂无书籍', 'No books');
  static String get noBooksInCategory =>
      _get('该分类下没有找到书籍', 'No books found in this category');
  static String get noBooksAfterFilter =>
      _get('筛选后无匹配书籍', 'No books match the filter');
  static String filteredNoMatch(String keyword) => _locale == 'zh'
      ? '已加载的书籍中没有匹配「$keyword」'
      : 'None of the loaded books match "$keyword"';
  static String get prevPageLoadFailed => _get(
      '上一页加载失败，点击重试', 'Failed to load the previous page; tap to retry');
  static String get pullToLoadPrevPage =>
      _get('下拉加载上一页', 'Pull down to load the previous page');
  static String get loadFailedTapToRetry =>
      _get('加载失败，点击重试', 'Failed to load; tap to retry');
  static String get exploreKindLoadFailed =>
      _get('发现分类加载失败', 'Failed to load discovery categories');
  static String get selectCategory => _get('选择分类', 'Select category');
  static String get searchCategory => _get('搜索分类', 'Search categories');
  static String get noMatchingCategory =>
      _get('没有匹配的分类', 'No matching categories');
  static String get refreshActionLabel => _get('刷新', 'Refresh');
  static String pageNumberLabel(String page) =>
      _locale == 'zh' ? '第 $page 页' : 'Page $page';
  static String get jumpToPage => _get('跳转到页码', 'Jump to page');
  static String jumpToPageHint(String maxPage) => _locale == 'zh'
      ? '输入目标页码（1-$maxPage），跳转后列表从该页开始加载'
      : 'Enter the target page (1-$maxPage); the list loads from that page';
  static String get pageNumberHint =>
      _get('页码（最多 4 位）', 'Page number (up to 4 digits)');
  static String get searchThisSource => _get('搜索该书源', 'Search this source');
  static String get backToSourceListLabel =>
      _get('返回源列表', 'Back to source list');
  static String get selectSource => _get('选择书源', 'Select source');
  static String get sourceHasNoCategories =>
      _get('该源没有可用分类', 'This source has no categories');
  static String get sourceNoCategoriesDesc => _get(
      '书源发现规则未解析出可浏览的分类',
      'The discovery rules did not produce any browsable categories');
  static String get reparse => _get('重新解析', 'Parse again');
  static String get categoryMissingUrl => _get('分类缺少地址', 'Category has no URL');
  static String get categoryMissingUrlDesc => _get(
      '请选择其他分类或刷新书源发现规则',
      'Choose another category or refresh the discovery rules');
  static String get categoryParseFailed =>
      _get('分类解析失败', 'Failed to parse the category');
  static String get searchSourceByHint =>
      _get('搜索书源（名称/地址）', 'Search sources (name/URL)');
  static String get noMatchingSourcesLabel =>
      _get('没有匹配的书源', 'No matching sources');
  static String get decreaseColumns => _get('减少列数', 'Fewer columns');
  static String get increaseColumns => _get('增加列数', 'More columns');
  static String columnsCount(int count) =>
      _locale == 'zh' ? '$count 列' : '$count columns';
  static String get searchOneSourceSelected =>
      _get('已选择 1 个书源', '1 source selected');
  static String get searchNoSourceSelected =>
      _get('未选择书源（搜索全部）', 'No source selected (search all)');

  // ----- 其他零散组件（调试 / 热力图） -----
  static String get debugLabel => _get('调试', 'Debug');
  static String get rerun => _get('重新运行', 'Run again');
  static String get heatmapLess => _get('少', 'Less');
  static String get heatmapMoreDuration =>
      _get('多（格 = 当日阅读时长）', 'More (cell = reading time that day)');
  static String get heatmapMoreBooks =>
      _get('多（格 = 当日阅读书籍数）', 'More (cell = books read that day)');
  static String heatmapSeconds(int seconds) =>
      _locale == 'zh' ? '$seconds 秒' : '$seconds s';
  static String heatmapMinutes(int minutes) =>
      _locale == 'zh' ? '$minutes 分钟' : '$minutes min';
  static String heatmapHoursMinutes(int hours, int minutes) =>
      _locale == 'zh' ? '$hours 小时 $minutes 分' : '${hours}h ${minutes}m';
  static String heatmapDayBooks(int month, int day, int count) =>
      _locale == 'zh' ? '$month/$day · $count 本' : '$month/$day · $count books';
}
