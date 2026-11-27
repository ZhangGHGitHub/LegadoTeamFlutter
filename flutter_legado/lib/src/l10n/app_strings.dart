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
  // 角色卡（R42 阶段 2A）：备份内容弹窗的只读告知行——产品决策上永不备份，
  // 故不出现在可勾选清单里（勾选项语义是「可选关闭」）。
  static String get backupContentCharactersExcluded => _get(
      '角色卡不纳入备份：换机或恢复备份后，已建的角色档案不会随之迁移（与参考版一致）。',
      'Character profiles are not included in backups: they will not be transferred when switching devices or restoring a backup (same as the reference app).');
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

  // ============== L10N 批 1 线 A：书架布局配置 / 阅读器组件 ==============
  static String get sortLabel => _get('排序', 'Sort');
  static String get bookshelfGroupStyle => _get('分组样式', 'Group style');
  static String get bookshelfGroupStyleTabs => _get('顶部标签', 'Top tabs');
  static String get bookshelfGroupStyleHidden => _get('隐藏标签', 'Hidden tabs');
  static String get bookshelfGroupStyleFolder => _get('文件夹', 'Folders');
  static String get hideEmptyGroups => _get('隐藏空分组', 'Hide empty groups');
  static String get bookshelfSortManualHint => _get('仅列表布局支持拖拽；网格会自动切换为列表，分组展示暂不支持', 'Drag reordering works in list layout only; grid switches to list automatically, and grouped display is not supported yet');
  static String get sortOrderLabel => _get('排序方向', 'Sort order');
  static String get bookshelfSectionLayout => _get('布局', 'Layout');
  static String get bookshelfFolderRoot => _get('文件夹根目录', 'Folder root');
  static String get folderLayoutMode => _get('文件夹布局模式', 'Folder layout mode');
  static String get landscapeLabel => _get('横屏', 'Landscape');
  static String get portraitLabel => _get('竖屏', 'Portrait');
  static String get layoutList => _get('列表', 'List');
  static String get layoutGrid => _get('网格', 'Grid');
  static String get bookshelfRowColumnCount => _get('行列数', 'Rows / columns');
  static String get bookshelfFolderListCoverWidthDesc => _get('文件夹列表模式封面宽度（与书架列表共用）', 'Cover width in folder list mode (shared with the bookshelf list)');
  static String get bookshelfListCoverWidth => _get('列表封面宽', 'List cover width');
  static String get folderListStyle => _get('文件夹列表样式', 'Folder list style');
  static String get compactList => _get('紧凑列表', 'Compact list');
  static String get horizontalCovers => _get('横排封面', 'Horizontal covers');
  static String get horizontalCoverCount => _get('横排封面数量', 'Horizontal cover count');
  static String get layoutMode => _get('布局模式', 'Layout mode');
  static String get bookshelfGridStyle => _get('网格样式', 'Grid style');
  static String get gridStyleStandard => _get('标准', 'Standard');
  static String get gridStyleCompact => _get('紧凑', 'Compact');
  static String get gridStyleCoverOnly => _get('仅封面', 'Cover only');
  static String get bookshelfTitleSmallFont => _get('书名小字体', 'Small title font');
  static String get bookshelfTitleCenter => _get('书名居中', 'Center title');
  static String get bookshelfGridCoverWidth => _get('网格封面宽', 'Grid cover width');
  static String get bookshelfDayCardColor => _get('日间卡片背景色', 'Day card background');
  static String get bookshelfNightCardColor => _get('夜间卡片背景色', 'Night card background');
  static String get compactDetails => _get('精简详情', 'Compact details');
  static String get compactDetailsDesc => _get('只保留书名、作者与未读数', 'Keep only title, author and unread count');
  static String get bookshelfMoreInfo => _get('更多信息', 'More info');
  static String get centerCoverVertically => _get('封面垂直居中', 'Center cover vertically');
  static String get centerCoverVerticallyDesc => _get('关闭后封面顶部对齐', 'When off, covers align to the top');
  static String get showLatestChapter => _get('显示最新章节', 'Show latest chapter');
  static String get showSynopsis => _get('显示简介', 'Show synopsis');
  static String get showSynopsisBelowContent => _get('简介显示在内容下方', 'Show synopsis below the content');
  static String get synopsisLines => _get('简介行数', 'Synopsis lines');
  static String get showAllSynopsis => _get('显示全部简介', 'Show the whole synopsis');
  static String get showTags => _get('显示标签', 'Show tags');
  static String get bookshelfTitleMaxLines => _get('书名最大行数', 'Max title lines');
  static String get coverShadow => _get('封面阴影', 'Cover shadow');
  static String get badgeSection => _get('角标', 'Badges');
  static String get showUnread => _get('显示未读标志', 'Show unread flag');
  static String get showUnreadNew => _get('显示新章节标志', 'Show new chapter flag');
  static String get showWaitUpCount => _get('显示等待更新数量', 'Show pending update count');
  static String get showGroupBookCount => _get('显示分组书籍数', 'Show group book count');
  static String get showBookCountFolderDesc => _get('在文件夹卡片、组菜单与组标题显示书籍数', 'Show the book count on folder cards, group menus and group titles');
  static String get showBookCountDesc => _get('文件夹模式下在分组卡片/组菜单显示书籍数', 'In folder mode, show the book count on group cards and group menus');
  static String get showLastUpdateTime => _get('显示上次更新时间', 'Show last updated time');
  static String get showTip => _get('显示书籍类型', 'Show book type');
  static String get bookshelfSearchDirect => _get('搜索直达', 'Search shortcut');
  static String get bookshelfSearchButtonHint => _get('开启：点击搜索，长按筛选；关闭：点击筛选，长按搜索。', 'On: tap to search, hold to filter. Off: tap to filter, hold to search.');
  static String get showBookshelfFastScroller => _get('显示快速滚动条', 'Show quick scroll bar');
  static String get showMoreGroupsButton => _get('显示更多分组', 'Show more groups');
  static String get showMoreGroupsButtonDesc => _get('在分组标签行尾显示组菜单按钮', 'Show the group menu button at the end of the group tab row');
  static String get bookshelfUpdateLimit => _get('更新数量限制', 'Update limit');
  static String get unlimitedLabel => _get('不限制', 'Unlimited');
  static String get bookshelfFolderRootHint => _get('文件夹根目录使用独立布局；点按分组卡片进入分组，返回先回到根目录。长按卡片可打开分组菜单。', 'The folder root uses its own layout. Tap a group card to enter the group; Back returns to the root first. Long press a card to open the group menu.');
  static String get resetLabel => _get('重置', 'Reset');
  static String get followTheme => _get('跟随主题', 'Follow theme');
  static String get customized => _get('已自定义', 'Customized');
  static String get resetFollowTheme => _get('恢复默认（跟随主题）', 'Restore default (follow theme)');
  static String get bookshelfTagCustom => _get('用户标签', 'User tags');
  static String get sourceCategories => _get('书源分类', 'Source categories');
  static String get bookshelfTagWordCount => _get('字数', 'Word count');
  static String get bookshelfTagContent => _get('标签显示内容', 'Tag display content');
  static String get bookshelfTagNone => _get('未选择显示内容', 'Nothing selected');
  static String get autoPageTurn => _get('自动翻页', 'Auto scroll');
  static String get autoPageSlower => _get('减慢翻页', 'Slower');
  static String get autoPageFaster => _get('加快翻页', 'Faster');
  static String get autoPageStop => _get('停止自动翻页', 'Stop auto scroll');
  static String get switchingSourceInProgress => _get('正在更换书源…', 'Switching source...');
  static String get singleChapterChangeSource => _get('单章换源', 'Change chapter source');
  static String get replaceCurrentChapterOnly => _get('仅替换当前章正文', 'Replace only this chapter\'s content');
  static String get changeBookSource => _get('换书源', 'Change book source');
  static String get changeBookSourceDesc => _get('切换整本书的书源', 'Switch the source for the whole book');
  static String get backToSourceList => _get('返回书源列表', 'Back to sources');
  static String get selectChapter => _get('选择章节', 'Select chapter');
  static String get filterSourceOrTitle => _get('筛选书源 / 书名', 'Filter sources / titles');
  static String get noSourcesAvailable => _get('没有可用书源', 'No sources available');
  static String get catalogEmpty => _get('目录为空', 'The catalog is empty');
  static String get effectiveReplaceRules => _get('有效替换规则', 'Effective replacement rules');
  static String get chineseConvertS2T => _get('繁简转换（简转繁）', 'Chinese conversion (Simplified to Traditional)');
  static String get chineseConvertT2S => _get('繁简转换（繁转简）', 'Chinese conversion (Traditional to Simplified)');
  static String get replaceDisabledForBook => _get('本书替换净化已关闭', 'Replacement is off for this book');
  static String get noEffectiveReplaceRules => _get('本章暂无生效替换规则', 'No replacement rules are active in this chapter');
  static String get reSegment => _get('重新分段', 'Re-segment');
  static String get unnamedRule => _get('（未命名规则）', '(Unnamed rule)');
  static String get closeLabel => _get('关闭', 'Close');
  static String get disableReSegmentFailed => _get('关闭重新分段失败，请重试', 'Failed to turn off re-segmenting. Please try again.');
  static String get noteNoBook => _get('无法保存笔记：未打开书籍', 'Cannot save the note: no book opened');
  static String get adjustInReadingSettings => _get('请在阅读设置中调整', 'Adjust it in reading settings');
  static String get note => _get('笔记', 'Note');
  static String get editNote => _get('编辑笔记', 'Edit note');
  static String get deleteNote => _get('删除笔记', 'Delete note');
  static String get deleteNoteConfirm => _get('删除笔记？', 'Delete this note?');
  static String get deleteNoteIrreversible => _get('删除后不可恢复。', 'This cannot be undone.');
  static String get noSelectedText => _get('（无选中文本）', '(No text selected)');
  static String get colorLabel => _get('颜色', 'Color');
  static String get effectLabel => _get('效果', 'Effect');
  static String get markingNoteLabel => _get('备注', 'Note');
  static String get noteHint => _get('输入备注…', 'Write a note...');
  static String get savingInProgress => _get('保存中…', 'Saving...');
  static String get effectSolid => _get('单实线', 'Solid line');
  static String get effectWave => _get('波浪线', 'Wavy line');
  static String get effectDashed => _get('虚线', 'Dashed line');
  static String get effectStrike => _get('删除线', 'Strikethrough');
  static String get effectHighlight => _get('荧光', 'Highlight');
  static String get effectBg => _get('背景色', 'Background');
  static String get effectText => _get('字体色', 'Text color');
  static String get sleepTimer => _get('定时停止', 'Sleep timer');
  static String get selectTtsEngine => _get('选择朗读引擎', 'Select speech engine');
  static String get ttsBookButton => _get('书', 'Book');
  static String get noChapterSelected => _get('未选择章节', 'No chapter selected');
  static String get finishThisChapter => _get('读完本章', 'Finish chapter');
  static String get collapseReadAloudPanel => _get('收起朗读面板', 'Collapse speech panel');
  static String get previousParagraph => _get('上一段', 'Previous paragraph');
  static String get nextParagraph => _get('下一段', 'Next paragraph');
  static String get stopReadAloud => _get('停止朗读', 'Stop');
  static String get readAloudSettings => _get('朗读设置', 'Speech settings');
  static String get speedFollowSystem => _get('语速:跟随系统', 'Speed: follow system');
  static String get speedManual => _get('语速:手动', 'Speed: manual');
  static String get moveToBackground => _get('转后台', 'Background');
  static String get speaking => _get('正在朗读', 'Speaking');
  static String get paused => _get('已暂停', 'Paused');
  static String get loadingShort => _get('加载中', 'Loading');
  static String get loadingLabel => _get('加载中', 'Loading');
  static String get readAloudError => _get('朗读出错', 'Speech error');
  static String get notStarted => _get('未开始', 'Not started');
  static String get editContent => _get('编辑内容', 'Edit content');
  static String get chapterContentSaved => _get('章节内容已保存', 'Chapter content saved');
  static String get chapterContentSaveFailed => _get('章节内容保存失败', 'Failed to save the chapter content');
  static String get replaceRuleOff => _get('已关闭替换规则', 'Replacement rules turned off');
  static String get replaceRuleOn => _get('已开启替换规则', 'Replacement rules turned on');
  static String get syncReadingProgress => _get('同步阅读进度', 'Sync reading progress');
  static String get jumpLabel => _get('跳转', 'Go');
  static String get localProgressUploaded => _get('本地进度较新，已上传到云端', 'Local progress is newer and was uploaded');
  static String get progressInSync => _get('进度已与云端一致', 'Progress already matches the cloud');
  static String get enableProgressSyncHint => _get('请先在 WebDAV 设置中开启「同步书籍进度」', 'Turn on "Sync book progress" in WebDAV settings first');
  static String get replaceRulesLabel => _get('替换规则', 'Replacement rules');
  static String get dayMode => _get('日间模式', 'Day mode');
  static String get nightModeLabel => _get('夜间模式', 'Night mode');
  static String get disableAutoBrightness => _get('关闭自动亮度', 'Turn off auto brightness');
  static String get autoBrightness => _get('自动亮度', 'Auto brightness');
  static String get searchContent => _get('全文搜索', 'Search content');
  static String get setCharset => _get('设置编码', 'Text encoding');
  static String get charsetHint => _get('如 UTF-8 / GBK', 'e.g. UTF-8 / GBK');
  static String get charsetRequired => _get('编码不能为空', 'Encoding cannot be empty');
  static String get localBookNoCache => _get('本地书籍无需缓存', 'Local books need no caching');
  static String get startChapterIndex => _get('起始章节序号', 'Start chapter');
  static String get invalidChapterRange => _get('章节范围无效', 'Invalid chapter range');
  static String get startCaching => _get('开始缓存', 'Start caching');
  static String get noImages => _get('暂无图片', 'No images');
  static String get imageLoadFailed => _get('图片加载失败', 'Failed to load the image');
  static String get noChapterContent => _get('本章无正文', 'No content in this chapter');
  static String get menuTab => _get('菜单', 'Menu');
  static String get infoTab => _get('信息', 'Info');
  static String get readingInterface => _get('阅读界面', 'Reading interface');
  static String get flipCover => _get('覆盖', 'Cover');
  static String get flipSlide => _get('滑动', 'Slide');
  static String get flipSimulate => _get('仿真', 'Simulation');
  static String get flipScroll => _get('滚动', 'Scroll');
  static String get flipNone => _get('无动画', 'None');
  static String get textSize => _get('字号', 'Text size');
  static String get customThemeNotApplied => _get('未应用主题（自定义）', 'Custom (no theme applied)');
  static String get themePreviewGlyph => _get('阅', 'Aa');
  static String get readingTheme => _get('阅读主题', 'Reading theme');
  static String get backgroundLabel => _get('背景', 'Background');
  static String get longPressToCustomize => _get('长按自定义', 'Long press to customize');
  static String get pageTurnAnimation => _get('翻页动画', 'Flip animation');
  static String get fontWeightLabel => _get('字重', 'Font weight');
  static String get fontWeightMedium => _get('中', 'Medium');
  static String get fontWeightBold => _get('粗', 'Bold');
  static String get fontWeightLight => _get('细', 'Light');
  static String get sharedLayout => _get('共用布局', 'Shared layout');
  static String get sharedLayoutOnDesc => _get('日夜共用边距与排版参数', 'Day and night share margins and typography');
  static String get sharedLayoutOffDesc => _get('日夜分别保存布局（切换主题自动切换）', 'Day and night keep separate layouts (switched with the theme)');
  static String get customColors => _get('自定义配色', 'Custom colors');
  static String get textColorLabel => _get('文字颜色', 'Text color');
  static String get backgroundColorLabel => _get('背景颜色', 'Background color');
  static String get followBodyFont => _get('跟随正文', 'Follow body font');
  static String get fontSection => _get('字体', 'Font');
  static String get selectFont => _get('选择字体', 'Select font');
  static String get bodyFont => _get('正文字体', 'Body font');
  static String get letterSpacingLabel => _get('正文字距', 'Letter spacing');
  static String get firstLineIndent => _get('首行缩进', 'First-line indent');
  static String get indentNone => _get('无缩进', 'No indent');
  static String get indent1 => _get('一字符', '1 character');
  static String get indent2 => _get('二字符', '2 characters');
  static String get indent3 => _get('三字符', '3 characters');
  static String get titleFontLabel => _get('标题字体', 'Title font');
  static String get titleFontDesc => _get('章节标题独立字体', 'Separate font for chapter titles');
  static String get italicLabel => _get('斜体', 'Italic');
  static String get italicDesc => _get('正文以斜体显示（测量与渲染同参）', 'Show body text in italic (measured and rendered the same way)');
  static String get chineseConversion => _get('简繁转换', 'Chinese conversion');
  static String get t2sShort => _get('繁→简', 'T to S');
  static String get s2tShort => _get('简→繁', 'S to T');
  static String get tipNone => _get('无', 'None');
  static String get bookNameTip => _get('书名', 'Title');
  static String get chapterNameTip => _get('章节名', 'Chapter name');
  static String get timeTip => _get('时间', 'Time');
  static String get batteryIconTip => _get('电量图标', 'Battery icon');
  static String get batteryPercentTip => _get('电量百分比', 'Battery %');
  static String get pageNumberTip => _get('页码', 'Page number');
  static String get readProgressTip => _get('阅读进度', 'Reading progress');
  static String get chapterProgressTip => _get('章节进度', 'Chapter progress');
  static String get pageAndProgressTip => _get('页码+进度', 'Page + progress');
  static String get timeAndBatteryTip => _get('时间+电量', 'Time + battery');
  static String get timeAndBatteryPercentTip => _get('时间+电量%', 'Time + battery %');
  static String get hideWhenStatusBarShown => _get('状态栏显示时隐藏', 'Hide when the status bar shows');
  static String get showLabel => _get('显示', 'Show');
  static String get bodyTitleLabel => _get('正文标题', 'Body title');
  static String get alignLeft => _get('居左', 'Left');
  static String get alignCenter => _get('居中', 'Center');
  static String get titleSizeLabel => _get('标题字号', 'Title font size');
  static String get titleTopSpacing => _get('标题上边距', 'Title top margin');
  static String get titleBottomSpacing => _get('标题下边距', 'Title bottom margin');
  static String get headerLabel => _get('页眉', 'Header');
  static String get headerDisplay => _get('页眉显示', 'Header display');
  static String get headerLeft => _get('页眉左', 'Header left');
  static String get headerMiddle => _get('页眉中', 'Header center');
  static String get headerRight => _get('页眉右', 'Header right');
  static String get footerLabel => _get('页脚', 'Footer');
  static String get footerDisplay => _get('页脚显示', 'Footer display');
  static String get footerLeft => _get('页脚左', 'Footer left');
  static String get footerMiddle => _get('页脚中', 'Footer center');
  static String get footerRight => _get('页脚右', 'Footer right');
  static String get legacyStatusBarHint => _get('兼容旧版：下方开关同步控制顶部状态条（隐藏工具栏时）', 'Legacy: the switches below also control the top status strip (when toolbars are hidden)');
  static String get showBattery => _get('显示电量', 'Show battery');
  static String get showTime => _get('显示时间', 'Show time');
  static String get showProgress => _get('显示进度', 'Show progress');
  static String get showChapterName => _get('显示章节名', 'Show chapter name');
  static String get tocRuleLocalTxtOnly => _get('TXT 目录规则仅适用于本地 TXT 书籍', 'TXT catalog rules apply to local TXT books only');
  static String get defaultRule => _get('默认规则', 'Default rule');
  static String get defaultRuleDesc => _get('自动识别常见章节标题（推荐）', 'Auto-detect common chapter titles (recommended)');
  static String get noEnabledTocRulesHint => _get('规则库暂无启用的规则，可在「管理规则」中导入或新增', 'No enabled rules yet. Import or add one in Manage rules.');
  static String get manageRules => _get('管理规则', 'Manage rules');
  static String get imageStyleLabel => _get('图片样式', 'Image style');
  static String get imageStyleDefault => _get('默认（文字旁显示图片）', 'Default (image beside text)');
  static String get imageStyleFull => _get('图片铺满宽度', 'Full-width image');
  static String get imageStyleText => _get('仅显示文字', 'Text only');
  static String get imageStyleSingle => _get('单独成页显示图片', 'Image on its own page');
  static String get simulatedReading => _get('模拟追读', 'Simulated reading');
  static String get enableSimulatedReading => _get('启用模拟追读', 'Enable simulated reading');
  static String get simulatedReadingDesc => _get('按日逐步释放章节，模拟追更体验', 'Release chapters day by day to mimic following an ongoing book');
  static String get dailyChapters => _get('每日更新章数', 'Chapters per day');
  static String get chapterPurchase => _get('章节购买', 'Chapter purchase');
  static String get editSource => _get('编辑源', 'Edit source');
  static String get disableSource => _get('禁用源', 'Disable source');
  static String get loginSource => _get('登录源', 'Log in to source');
  static String get purchaseSuccess => _get('购买成功', 'Purchase complete');
  static String get noPurchaseNeeded => _get('当前章节无需购买或书源未配置购买动作', 'This chapter needs no purchase, or the source has no purchase action');
  static String get noDuplicateTitleFound => _get('未找到可移除的重复标题', 'No duplicate title to remove');
  static String get duplicateTitleRemoved => _get('已去除重复标题', 'Duplicate title removed');
  static String get originalTitleKept => _get('该章已保留原标题', 'This chapter keeps its original title');
  static String get gotIt => _get('知道了', 'Got it');
  static String get chapterLinkCopied => _get('章节链接已复制', 'Chapter link copied');
  static String get chapterLink => _get('章节链接', 'Chapter link');
  static String get openWith => _get('打开方式', 'Open with');
  static String get openInAppBrowser => _get('内置浏览器打开', 'Open in in-app browser');
  static String get openInSystemBrowser => _get('系统浏览器打开', 'Open in system browser');
  static String get copyLink => _get('复制链接', 'Copy link');
  static String get cacheOffline => _get('缓存（离线缓存）', 'Cache (offline)');
  static String get removeRubyTags => _get('删除 Ruby 标签', 'Remove Ruby tags');
  static String get removeHTags => _get('删除 H 标签', 'Remove H tags');
  static String get coverCloudProgress => _get('覆盖云端进度', 'Overwrite cloud progress');
  static String get reverseContent => _get('反转内容', 'Reverse content');
  static String get removeDuplicateTitle => _get('删除重复标题', 'Remove duplicate title');
  static String get sourceBadge => _get('书源', 'Source');
  static String get scopeOnlineOnly => _get('仅在线书', 'Online books only');
  static String get scopeLocalOnly => _get('仅本地书', 'Local books only');
  static String get scopeLocalTxtOnly => _get('仅本地 TXT', 'Local TXT only');
  static String get downloadOffline => _get('下载（离线缓存）', 'Download (offline cache)');
  static String get refreshContent => _get('刷新正文', 'Refresh content');
  static String get interfaceSettings => _get('界面设置', 'Interface settings');
  static String get addBookmark => _get('添加书签', 'Add bookmark');
  static String get highlightRulesMenu => _get('高亮规则', 'Highlight rules');
  static String get dayNightToggle => _get('日/夜切换', 'Day / night');
  static String get topBarButtons => _get('顶栏按钮', 'Top bar buttons');
  static String get topBarOverLimitHint => _get('已超出上限，末尾动作不会显示在顶栏。', 'Over the limit: trailing actions are not shown in the top bar.');
  static String get topBarButtonsRestored => _get('已恢复默认顶栏按钮', 'Default top bar buttons restored');
  static String get supportsLongPress => _get('支持长按', 'Long press');
  static String get alwaysShown => _get('固定显示', 'Always shown');
  static String get limitReached => _get('已达上限', 'Limit reached');
  static String get moveUp => _get('上移', 'Move up');
  static String get moveDown => _get('下移', 'Move down');
  static String get noComments => _get('暂无评论', 'No comments');
  static String get anonymous => _get('匿名', 'Anonymous');
  static String get loadingDots => _get('加载中…', 'Loading...');
  static String get collapseReplies => _get('收起回复', 'Hide replies');
  static String get viewReplies => _get('查看回复', 'View replies');
  static String get bookmarkAddedSimple => _get('已添加书签', 'Bookmark added');
  static String get searchContentNoBook => _get('无法搜正文：未打开书籍', 'Cannot search the content: no book opened');
  static String get contentProcessing => _get('内容处理', 'Content processing');
  static String get noBookOpened => _get('未打开书籍', 'No book opened');
  static String get useReplacement => _get('使用替换净化', 'Use replacement');
  static String get useReplacementDesc => _get('关闭后本章不应用任何替换规则', 'When off, no replacement rules are applied to this chapter');
  static String get noReplaceRules => _get('暂无替换规则', 'No replacement rules');
  static String get noMatchingRules => _get('没有符合条件的规则', 'No matching rules');
  static String get regexLabel => _get('正则', 'Regex');
  static String get textLabel => _get('文本', 'Text');
  static String get noAiRecords => _get('暂无 AI 处理记录', 'No AI processing records');
  static String get aiContentProcessingUnsupported => _get('AI 内容处理暂未支持', 'AI content processing is not supported yet');
  static String get disabledLabel => _get('已停用', 'Disabled');
  static String get activeLabel => _get('生效', 'Active');
  static String get editSelectionMenu => _get('编辑选择菜单', 'Edit selection menu');
  static String get multilineDisplay => _get('多行展示', 'Multiline');
  static String get showIcons => _get('展示图标', 'Show icons');
  static String get primaryMenu => _get('一级菜单', 'Primary menu');
  static String get collapsedMenu => _get('折叠菜单', 'Collapsed menu');
  static String get hiddenItems => _get('已隐藏项目', 'Hidden items');
  static String get notAvailable => _get('暂无', 'None');
  static String get moveTo => _get('移动到', 'Move to');
  static String get moveToPrimary => _get('移至一级', 'Move to primary');
  static String get moveToCollapsed => _get('移至折叠', 'Move to collapsed');
  static String get moveToHidden => _get('移至隐藏', 'Move to hidden');
  static String get selectedText => _get('已选文本', 'Selected text');
  static String get highlightLabel => _get('高亮', 'Highlight');
  static String get manageSelectionMenu => _get('管理选择菜单', 'Manage selection menu');
  static String get highlightColor => _get('高亮颜色', 'Highlight color');
  static String get styleColor => _get('样式颜色', 'Style color');
  static String get noteOptional => _get('笔记（可选）', 'Note (optional)');
  static String get saveHighlight => _get('保存高亮', 'Save highlight');
  static String get highlightNoBook => _get('无法添加高亮：未打开书籍', 'Cannot add a highlight: no book opened');
  static String get highlightAdded => _get('已添加高亮', 'Highlight added');
  static String get highlightAndNoteAdded => _get('已添加高亮与笔记', 'Highlight and note added');
  static String get releaseToRemoveBookmark => _get('松手以取消书签', 'Release to remove the bookmark');
  static String get releaseToAddBookmark => _get('松手以添加书签', 'Release to add a bookmark');
  static String get manageReplaceRules => _get('管理替换规则', 'Manage replacement rules');
  static String get textProcessing => _get('文字处理', 'Text processing');
  static String get useReplaceRules => _get('使用替换规则', 'Use replacement rules');
  static String get viewCatalog => _get('查看目录', 'View catalog');
  static String get reverseTocDisplay => _get('目录显示反转', 'Reverse catalog display');
  static String get tocUpdatedShort => _get('目录已更新', 'Catalog updated');
  static String get updatingToc => _get('正在更新目录…', 'Updating catalog...');
  static String get localBookNoTocUpdate => _get('本地书籍无需更新目录', 'Local books need no catalog update');
  static String get refreshingContent => _get('正在刷新正文…', 'Refreshing content...');
  static String get contentRefreshed => _get('正文已刷新', 'Content refreshed');
  static String get noContentToReverse => _get('暂无正文可反转', 'No content to reverse');
  static String get contentReversed => _get('内容已反转', 'Content reversed');
  static String get reverseContentSaveFailed => _get('反转内容保存失败', 'Failed to save the reversed content');
  static String get progressUploaded => _get('进度上传成功', 'Progress uploaded');
  static String get exitReading => _get('退出阅读', 'Exit reading');
  static String get reSegmentOff => _get('已关闭重新分段', 'Re-segmenting turned off');
  static String get reSegmentOn => _get('已开启重新分段', 'Re-segmenting turned on');
  static String get simulatedReadingOn => _get('已开启模拟追读', 'Simulated reading turned on');
  static String get simulatedReadingOff => _get('已关闭模拟追读', 'Simulated reading turned off');
  static String get chapterPurchaseInProgress => _get('正在执行章节购买…', 'Purchasing the chapter...');
  static String get replaceRuleDataUnavailable => _get('替换规则数据暂不可用', 'Replacement rule data is unavailable');
  static String get selectionPanelHint => _get('提示：长按上方文本可精细调整选区，未选择时默认操作整段', 'Tip: long press the text above to fine-tune the selection; without a selection the whole paragraph is used');
  static String get tocRuleNotMatched => _get('规则未命中，已回退默认规则', 'The rule did not match; fell back to the default rule');
  static String get defaultTocRuleRestored => _get('已恢复默认目录规则', 'Default catalog rule restored');
  static String get tocRuleApplied => _get('已应用目录规则', 'Catalog rule applied');
  static String get toggleReplaceFailedRetry => _get('切换替换净化失败，请重试', 'Failed to toggle replacement. Please try again.');
  static String get deleteReplaceRuleConfirm => _get('删除替换规则？', 'Delete this replacement rule?');
  static String get paddingLeftLabel => _get('左边距', 'Left margin');
  static String get paddingRightLabel => _get('右边距', 'Right margin');
  static String get linkLeftRightMargins => _get('左右边距联动', 'Link left and right margins');
  static String get linkTopBottomMargins => _get('上下边距联动', 'Link top and bottom margins');
  static String get showHeaderDivider => _get('显示页眉分隔线', 'Show header divider');
  static String get showFooterDivider => _get('显示页脚分隔线', 'Show footer divider');
  static String get decreaseLabel => _get('减少', 'Decrease');
  static String get increaseLabel => _get('增加', 'Increase');

  static String recentlyReadBook(String name) => _locale == 'zh'
      ? '最近阅读：$name'
      : 'Recently read: $name';
  static String folderGridColumnsDesc(String orientation) => _locale == 'zh'
      ? '$orientation文件夹网格列数'
      : '$orientation folder grid columns';
  static String folderListColumnsDesc(String orientation) => _locale == 'zh'
      ? '$orientation文件夹列表列数'
      : '$orientation folder list columns';
  static String gridColumnsDesc(String orientation) => _locale == 'zh'
      ? '$orientation网格列数'
      : '$orientation grid columns';
  static String listColumnsDesc(String orientation) => _locale == 'zh'
      ? '$orientation列表列数'
      : '$orientation list columns';
  static String listColumnsExceedDesc(String orientation, String max) => _locale == 'zh'
      ? '$orientation列表列数；当前书架宽度最多 $max 列，超出将按 $max 列显示'
      : '$orientation list columns; the bookshelf is wide enough for $max columns, extra columns are capped to $max';
  static String synopsisLineCount(String lines) => _locale == 'zh'
      ? '显示 $lines 行'
      : 'Show $lines lines';
  static String bookshelfUpdateLimitDesc(String limit) => _locale == 'zh'
      ? '每次最多更新 $limit 本'
      : 'Update at most $limit books each time';
  static String matchScore(String score) => _locale == 'zh'
      ? '匹配 $score'
      : 'Match $score';
  static String secondsLabel(String seconds) => _locale == 'zh'
      ? '$seconds 秒'
      : '$seconds s';
  static String chapterContentReplaced(String source) => _locale == 'zh'
      ? '已替换本章正文（$source）'
      : 'Chapter content replaced ($source)';
  static String singleChapterSourceFailed(String error) => _locale == 'zh'
      ? '单章换源失败：$error'
      : 'Failed to change the chapter source: $error';
  static String reloadAfterSourceChangeFailed(String error) => _locale == 'zh'
      ? '更换书源后重载失败：$error'
      : 'Failed to reload after switching source: $error';
  static String reloadContentFailed(String error) => _locale == 'zh'
      ? '重新加载正文失败：$error'
      : 'Failed to reload the content: $error';
  static String disableReplaceRuleFailed(String error) => _locale == 'zh'
      ? '关闭替换规则失败：$error'
      : 'Failed to disable the replacement rule: $error';
  static String disableChineseConvertFailed(String error) => _locale == 'zh'
      ? '关闭繁简转换失败：$error'
      : 'Failed to turn off the Chinese conversion: $error';
  static String effectiveRuleCount(String count) => _locale == 'zh'
      ? '本章生效 $count 条'
      : '$count active in this chapter';
  static String saveNoteFailed(String error) => _locale == 'zh'
      ? '保存笔记失败：$error'
      : 'Failed to save the note: $error';
  static String deleteNoteFailed(String error) => _locale == 'zh'
      ? '删除笔记失败：$error'
      : 'Failed to delete the note: $error';
  static String sleepTimerRemaining(String time) => _locale == 'zh'
      ? '定时停止：剩余 $time'
      : 'Sleep timer: $time left';
  static String sleepTimerChapters(String chapters) => _locale == 'zh'
      ? '定时停止：读完 $chapters 章后停止'
      : 'Sleep timer: stop after $chapters chapters';
  static String get sleepTimerFinishChapter => _get('定时停止：读完本章后停止', 'Sleep timer: stop after this chapter');
  static String get noTtsEngineHint => _get('暂无朗读引擎，请到「朗读设置」添加 HTTP TTS 引擎', 'No speech engine yet. Add an HTTP TTS engine in Speech settings.');
  static String get noBookCannotSetEngine => _get('未打开书籍，无法设为本书引擎', 'No book opened; cannot set the engine for this book');
  static String ttsEngineLoadFailed(String error) => _locale == 'zh'
      ? '朗读引擎列表加载失败: $error'
      : 'Failed to load speech engines: $error';
  static String ttsEngineSwitched(String name) => _locale == 'zh'
      ? '已切换引擎：$name'
      : 'Engine switched to $name';
  static String engineSetForBook(String name) => _locale == 'zh'
      ? '已设为本书引擎：$name'
      : 'Engine set for this book: $name';
  static String engineSetGlobal(String name) => _locale == 'zh'
      ? '已设为全局引擎：$name'
      : 'Engine set globally: $name';
  static String paragraphProgress(String index, String total) => _locale == 'zh'
      ? '·段$index/$total'
      : '·para $index/$total';
  static String editChapterNamed(String title) => _locale == 'zh'
      ? '编辑：$title'
      : 'Edit: $title';
  static String chapterContentSaveFailedWith(String error) => _locale == 'zh'
      ? '章节内容保存失败：$error'
      : 'Failed to save the chapter content: $error';
  static String settingsSaveFailedWith(String error) => _locale == 'zh'
      ? '设置保存失败: $error'
      : 'Failed to save settings: $error';
  static String cloudProgressNewer(String chapter, String title) => _locale == 'zh'
      ? '云端进度更新（第 $chapter 章「$title」）。\n是否跳转到云端进度？'
      : 'Cloud progress is newer (chapter $chapter "$title").\nJump to the cloud progress?';
  static String syncProgressFailed(String error) => _locale == 'zh'
      ? '同步进度失败：$error'
      : 'Failed to sync progress: $error';
  static String charsetApplied(String charset) => _locale == 'zh'
      ? '已设置编码：$charset'
      : 'Encoding set to $charset';
  static String setCharsetFailed(String error) => _locale == 'zh'
      ? '设置编码失败：$error'
      : 'Failed to set the encoding: $error';
  static String endChapterIndex(String total) => _locale == 'zh'
      ? '结束章节序号（共 $total 章）'
      : 'End chapter (of $total)';
  static String cacheQueued(String count) => _locale == 'zh'
      ? '已加入缓存队列：$count 章（可在书籍菜单「缓存管理」查看进度）'
      : 'Queued for caching: $count chapters (see Cache management in the book menu)';
  static String cacheStartFailed(String error) => _locale == 'zh'
      ? '缓存启动失败：$error'
      : 'Failed to start caching: $error';
  static String bookmarkOperationFailed(String error) => _locale == 'zh'
      ? '书签操作失败：$error'
      : 'Bookmark operation failed: $error';
  static String chineseConversionFailed(String error) => _locale == 'zh'
      ? '简繁转换设置失败: $error'
      : 'Failed to set the Chinese conversion: $error';
  static String applyTocRuleReloadFailed(String error) => _locale == 'zh'
      ? '应用目录规则后重载失败：$error'
      : 'Failed to reload after applying the catalog rule: $error';
  static String setTocRuleFailed(String error) => _locale == 'zh'
      ? '设置目录规则失败: $error'
      : 'Failed to set the catalog rule: $error';
  static String customTocRuleInUse(String rule) => _locale == 'zh'
      ? '当前书使用规则库之外的规则：$rule'
      : 'This book uses a rule outside the library: $rule';
  static String loadRulesFailed(String error) => _locale == 'zh'
      ? '规则加载失败：$error'
      : 'Failed to load rules: $error';
  static String uploadProgressFailed(String error) => _locale == 'zh'
      ? '上传进度失败：$error'
      : 'Failed to upload progress: $error';
  static String updateTocFailed(String error) => _locale == 'zh'
      ? '更新目录失败: $error'
      : 'Failed to update the catalog: $error';
  static String reverseContentFailed(String error) => _locale == 'zh'
      ? '反转内容失败: $error'
      : 'Failed to reverse the content: $error';
  static String sourceDisabled(String name) => _locale == 'zh'
      ? '已禁用书源：$name'
      : 'Source disabled: $name';
  static String disableSourceFailed(String error) => _locale == 'zh'
      ? '禁用书源失败: $error'
      : 'Failed to disable the source: $error';
  static String chapterPurchaseFailed(String error) => _locale == 'zh'
      ? '章节购买失败: $error'
      : 'Chapter purchase failed: $error';
  static String toggleOffNamed(String label) => _locale == 'zh'
      ? '已关闭$label'
      : '$label turned off';
  static String toggleOnNamed(String label) => _locale == 'zh'
      ? '已开启$label'
      : '$label turned on';
  static String settingFailedWith(String error) => _locale == 'zh'
      ? '设置失败: $error'
      : 'Failed to apply the setting: $error';
  static String effectiveReplaceCountDesc(String count) => _locale == 'zh'
      ? '当前已启用替换规则 $count 条（全局启用计数；原版为当前章节生效规则列表，章级数据待 FFI 契约补齐）'
      : '$count replacement rules enabled (global count; chapter-level data awaits the FFI contract)';
  static String cannotOpenLink(String url) => _locale == 'zh'
      ? '无法打开链接：$url'
      : 'Cannot open the link: $url';
  static String refreshContentFailed(String error) => _locale == 'zh'
      ? '刷新正文失败：$error'
      : 'Failed to refresh the content: $error';
  static String topBarButtonsDesc(String max) => _locale == 'zh'
      ? '选择与排序阅读器顶栏的动作，最多显示 $max 个（含固定的「更多」）。已达上限时需先关闭其它动作才能开启新的；未显示的动作仍可在「更多」菜单中使用。'
      : 'Choose and reorder the reader top bar actions; up to $max are shown (including the fixed More). At the limit, turn another action off before enabling a new one. Actions not shown remain available in the More menu.';
  static String topBarEnabledCount(String enabled, String max) => _locale == 'zh'
      ? '已开启 $enabled/$max'
      : '$enabled of $max enabled';
  static String charCount(String count) => _locale == 'zh'
      ? '$count 字'
      : '$count chars';
  static String openBrowserFailed(String error) => _locale == 'zh'
      ? '打开浏览器失败：$error'
      : 'Failed to open the browser: $error';
  static String updateReplaceRuleFailed(String error) => _locale == 'zh'
      ? '更新替换规则失败：$error'
      : 'Failed to update the replacement rule: $error';
  static String deleteReplaceRuleFailed(String error) => _locale == 'zh'
      ? '删除替换规则失败：$error'
      : 'Failed to delete the replacement rule: $error';
  static String addHighlightFailed(String error) => _locale == 'zh'
      ? '添加高亮失败：$error'
      : 'Failed to add the highlight: $error';

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
  static String get confirmTextDefault => _get('确认', 'Confirm');

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

  // ============== L10N 批 2 组 B：screens 第二批（17 个页面） ==============

  // ----- 通用补充 -----
  static String get exportAction => _get('导出', 'Export');
  static String get disableLabel => _get('停用', 'Disable');
  static String get copyRulesAction => _get('复制规则', 'Copy rules');
  static String get pasteRulesAction => _get('粘贴规则', 'Paste rules');
  static String get useRegexLabel =>
      _get('使用正则表达式', 'Use regular expression');
  static String get saveFailedRetry => _get('保存失败，请重试', 'Failed to save, please retry');
  static String get testFailedLabel => _get('测试失败', 'Test failed');
  static String get unknownValue => _get('未知', 'Unknown');
  static String get markingLabel => _get('标注', 'Annotations');
  static String operationFailedColon(String error) =>
      _locale == 'zh' ? '操作失败: $error' : 'Operation failed: $error';
  static String loadFailedColon(String error) =>
      _locale == 'zh' ? '加载失败: $error' : 'Failed to load: $error';
  static String exportSuccessColon(String path) =>
      _locale == 'zh' ? '导出成功: $path' : 'Exported: $path';
  static String exportFailedColon(String error) =>
      _locale == 'zh' ? '导出失败: $error' : 'Export failed: $error';
  static String updateFailedColon(String error) =>
      _locale == 'zh' ? '更新失败: $error' : 'Update failed: $error';

  // ----- 阅读器九宫格点击区域（click_action_config_sheet） -----
  static String get clickActionSheetTitle =>
      _get('点击区域设置', 'Screen Touch Control');
  static String get clickActionPickTitle => _get('选择动作', 'Select action');

  // ----- 更换封面（change_cover_screen） -----
  static String get changeCoverTitle => _get('更换封面', 'Change cover');
  static String get changeCoverPickDialogTitle =>
      _get('选择封面图片', 'Select a cover image');
  static String get changeCoverSaveFailed =>
      _get('保存封面失败，请重试', 'Failed to save the cover, please retry');
  static String get changeCoverLocalPickedHint => _get(
      '已选择本地图片，点击底部按钮确认',
      'Local image selected; tap the button below to confirm');
  static String get changeCoverPickFailed =>
      _get('选择封面失败，请重试', 'Failed to select the cover, please retry');
  static String get changeCoverUseThis => _get('使用该封面', 'Use this cover');
  static String get changeCoverNetworkSection =>
      _get('网络封面', 'Online covers');
  static String get changeCoverNewSelected => _get('已选择新封面', 'New cover selected');
  static String get changeCoverCurrent => _get('当前封面', 'Current cover');
  static String get changeCoverHint => _get(
      '从下方选择网络封面，或点击右上角「本地」从相册选取。',
      'Pick an online cover below, or tap "Local" at the top right to choose from your gallery.');
  static String get changeCoverSearchHint =>
      _get('输入书名搜索封面', 'Enter a book title to search covers');
  static String get changeCoverNoCandidates =>
      _get('暂无候选封面', 'No candidate covers');

  // ----- 缓存下载队列（cache_download_screen） -----
  static String get downloadStatusRunning => _get('下载中', 'Downloading');
  static String get downloadStatusCompleted => _get('已完成', 'Completed');
  static String get downloadStatusCancelled => _get('已取消', 'Cancelled');
  static String get downloadStatusFailed => _get('失败', 'Failed');
  static String get downloadStatusNotFound => _get('已失效', 'Expired');
  static String get cacheCancelFailed => _get('取消失败', 'Failed to cancel');
  static String get cacheDownloadEmpty =>
      _get('暂无缓存下载任务', 'No cache download tasks');
  static String get cacheDownloadEmptyHint => _get(
      '阅读页顶栏「缓存」按钮可发起批量缓存下载',
      'Use the "Cache" button in the reader top bar to start batch caching downloads');
  static String failedCountSuffix(int count) =>
      _locale == 'zh' ? ' · 失败 $count' : ' · Failed $count';

  // ----- cURL ↔ AnalyzeUrl（curl_analyze_url_sheet） -----
  static String get curlErrorEmptyInput => _get('输入不能为空', 'Input cannot be empty');
  static String get curlErrorInvalid =>
      _get('不是有效的 cURL 命令', 'Not a valid cURL command');
  static String get curlErrorMissingUrl => _get('缺少 URL', 'Missing URL');
  static String get curlErrorInvalidAnalyzeUrl =>
      _get('AnalyzeUrl 格式无效', 'Invalid AnalyzeUrl format');
  static String get curlErrorUnsupportedMethod =>
      _get('不支持的 HTTP 方法', 'Unsupported HTTP method');
  static String get curlErrorUnsupportedOption =>
      _get('含不支持的选项', 'Contains unsupported options');
  static String curlConvertFailed(String error) =>
      _locale == 'zh' ? '转换失败：$error' : 'Conversion failed: $error';
  static String get curlNoResultToCopy =>
      _get('没有可复制的结果', 'No result to copy');
  static String get curlNoResultToInsert =>
      _get('没有可插入的结果', 'No result to insert');
  static String get curlConvertAction => _get('转换', 'Convert');
  static String get curlCommandLabel => _get('cURL 命令', 'cURL command');
  static String get curlInsertAction => _get('插入', 'Insert');

  // ----- 网页登录（webview_login_screen） -----
  static String get loginCheckDone => _get('登录检测完成', 'Login check complete');
  static String loginRedirectOtherApp(String url) => _locale == 'zh'
      ? '即将跳转到其他应用打开：$url'
      : 'Redirecting to another app: $url';
  static String webviewLoadFailed(String reason) =>
      _locale == 'zh' ? '页面加载失败：$reason' : 'Failed to load the page: $reason';
  static String get loginDetectingCookie => _get('正在检测 Cookie…', 'Detecting cookies…');
  static String get loginCheckTooltip => _get('检测', 'Check');
  static String get loginManualEditCookie =>
      _get('手动编辑 Cookie', 'Edit cookie manually');

  // ----- 发现展示（explore_show_screen） -----
  static String get exploreShowNoBooks =>
      _get('没有已加载的书籍', 'No books loaded');
  static String exploreShowAddedCount(int count) =>
      _locale == 'zh' ? '已加入书架 $count 本' : 'Added $count to bookshelf';
  static String get exploreShowParamError => _get('参数错误', 'Invalid parameters');
  static String get exploreShowMissingCategoryParam =>
      _get('缺少发现分类参数', 'Missing discovery category parameters');
  static String get exploreShowFilter => _get('筛选', 'Filter');
  static String exploreShowFilterOn(String keyword) => _locale == 'zh'
      ? '筛选（已开启：$keyword）'
      : 'Filter (on: $keyword)';
  static String get exploreShowSwitchComfort =>
      _get('切换为舒适', 'Switch to comfortable');
  static String get exploreShowSwitchCompact =>
      _get('切换为紧凑', 'Switch to compact');
  static String get exploreShowFilterDesc => _get(
      '按关键字过滤已加载的书籍（匹配书名或作者，忽略英文字母大小写）',
      'Filter loaded books by keyword (matches title or author, case-insensitive for Latin letters)');
  static String get exploreShowFilterHint =>
      _get('关键字（留空=不过滤）', 'Keyword (empty = no filtering)');

  // ----- 底栏皮肤（bottom_bar_skin_screen） -----
  static String get bottomBarSkinTitle => _get('底部操作栏皮肤', 'Bottom bar skin');
  static String get bottomBarSkinSection => _get('皮肤', 'Skin');
  static String get bottomBarSkinImportHint => _get(
      '导入 zip 后进入分配页：为书架/发现/订阅/我的各选「选中」图（「未选」可空）。若文件名已是 bookshelf_selected 等，将自动预填。',
      'After importing a zip you reach the assignment page: pick the "selected" image for Bookshelf/Discover/RSS/My ("unselected" is optional). If filenames already match bookshelf_selected etc., they are filled in automatically.');
  static String bottomBarSkinSaved(String name) =>
      _locale == 'zh' ? '已保存并启用：$name' : 'Saved and enabled: $name';
  static String get bottomBarSkinExportSubject =>
      _get('导出底栏皮肤', 'Export bottom bar skin');
  static String bottomBarSkinUpdated(String name) =>
      _locale == 'zh' ? '已更新：$name' : 'Updated: $name';
  static String bottomBarSkinEditFailed(String error) =>
      _locale == 'zh' ? '无法编辑：$error' : 'Unable to edit: $error';
  static String get bottomBarSkinDeleteTitle => _get('删除皮肤', 'Delete skin');
  static String bottomBarSkinDeleteConfirm(String name) =>
      _locale == 'zh' ? '确定删除「$name」？' : 'Delete "$name"?';

  // ----- 离线缓存（offline_cache_screen） -----
  static String offlineCacheChapterUnknown(String label) => _locale == 'zh'
      ? '$label章节数未知，无法缓存'
      : '$label: chapter count unknown, cannot cache';
  static String offlineCacheNoChaptersToCache(String label) =>
      _locale == 'zh' ? '$label无可缓存的章节' : '$label: no chapters to cache';
  static String offlineCacheQueued(String label) =>
      _locale == 'zh' ? '$label已加入缓存队列' : '$label added to the cache queue';
  static String offlineCacheStartFailedWith(String error) =>
      _locale == 'zh' ? '缓存启动失败：$error' : 'Failed to start caching: $error';
  static String offlineCacheStoppedDownload(String label) =>
      _locale == 'zh' ? '已停止$label下载' : 'Stopped downloading $label';
  static String offlineCacheStopFailed(String error) =>
      _locale == 'zh' ? '停止失败：$error' : 'Failed to stop: $error';
  static String get offlineCacheNoCacheableBooks =>
      _get('书架无可缓存的书籍', 'No cacheable books on the bookshelf');
  static String get offlineCacheAllAfterTitle =>
      _get('缓存所有书籍当前章节之后', 'Cache all books after the current chapter');
  static String get offlineCacheAllTitle => _get('缓存所有书籍', 'Cache all books');
  static String offlineCacheAllConfirm(int count, {required bool afterCurrent}) =>
      _locale == 'zh'
          ? '将缓存书架全部 $count 本书${afterCurrent ? '（当前章节之后）' : ''}，是否继续？'
          : 'Cache all $count books on the bookshelf${afterCurrent ? ' (after the current chapter)' : ''}. Continue?';
  static String offlineCacheQueuedCount(int count) =>
      _locale == 'zh' ? '已加入缓存队列：$count 本书' : 'Added $count books to the cache queue';
  static String get offlineCacheStartFailed => _get('缓存启动失败', 'Failed to start caching');
  static String get offlineCacheNoActiveDownloads =>
      _get('当前没有进行中的下载', 'No downloads in progress');
  static String offlineCacheStoppedTasks(int count) =>
      _locale == 'zh' ? '已停止 $count 个下载任务' : 'Stopped $count download tasks';
  static String offlineCacheExported(String name) =>
      _locale == 'zh' ? '已导出 $name' : 'Exported $name';
  static String get offlineCacheOps => _get('缓存操作', 'Cache actions');
  static String get offlineCacheDownloadAll => _get('全部缓存', 'Cache all');
  static String get offlineCacheDownloadAfter =>
      _get('缓存当前章节之后', 'Cache after the current chapter');
  static String get offlineCacheStopAll => _get('停止全部下载', 'Stop all downloads');
  static String get offlineCacheDownloadQueue => _get('下载队列', 'Download queue');
  static String get offlineCacheShelfEmpty => _get('书架暂无书籍', 'No books on the bookshelf');
  static String get offlineCacheShelfEmptyHint => _get(
      '在书架添加书籍后，可在此缓存离线阅读',
      'Add books to the bookshelf to cache them here for offline reading');
  static String get offlineCacheLocalBook => _get('本地书籍', 'Local book');
  static String offlineCacheDownloading(int completed, int total) => _locale == 'zh'
      ? '下载中 $completed/$total'
      : 'Downloading $completed/$total';
  static String offlineCacheCachedOfTotal(int cached, int total) =>
      _locale == 'zh' ? '已缓存 $cached/$total' : 'Cached $cached/$total';
  static String offlineCacheCached(int cached) =>
      _locale == 'zh' ? '已缓存 $cached' : 'Cached $cached';
  static String get offlineCacheStopDownload => _get('停止下载', 'Stop download');

  // ----- 二维码（qrcode_screen） -----
  static String get qrPickDialogTitle => _get('选择二维码图片', 'Select a QR code image');
  static String get qrNoCodeFound =>
      _get('未识别到图片中的二维码', 'No QR code found in the image');
  static String get qrImageRecognized => _get(
      '已识别图片二维码，请确认后使用', 'QR code recognized from the image; confirm to use it');
  static String get qrImageReadFailed => _get('图片读取失败', 'Failed to read the image');
  static String get qrTypeLegadoLink => _get('Legado 导入链接', 'Legado import link');
  static String get qrTypeHttpRss => _get('HTTP 订阅地址', 'HTTP RSS address');
  static String get qrTypeSourceJson => _get('书源 JSON', 'Book source JSON');
  static String get qrTypePassphrase => _get('口令 / 文本', 'Passphrase / text');
  static String get qrScanTitle => _get('扫描二维码', 'Scan QR code');
  static String get qrImportFromGallery => _get('从图库导入', 'Import from gallery');
  static String get qrManualInput => _get('手动输入', 'Manual input');
  static String get qrManualHint => _get(
      '粘贴或输入二维码内容：书源 URL / legado:// 链接 / 书源 JSON / 口令',
      'Paste or enter QR code content: book source URL / legado:// link / book source JSON / passphrase');
  static String get qrPasteFromClipboard => _get('从剪贴板粘贴', 'Paste from clipboard');
  static String get qrUseThisContent => _get('使用该内容', 'Use this content');
  static String get qrCameraFailed => _get('相机启动失败', 'Failed to start the camera');
  static String get qrCameraUnsupported =>
      _get('当前平台未启用相机扫码', 'Camera scanning is not enabled on this platform');
  static String get qrCameraHint => _get(
      '可使用右上角图库按钮导入二维码图片，或下方手动输入',
      'Use the gallery button at the top right to import a QR image, or enter it manually below');
  static String get qrResultTitle => _get('识别结果', 'Result');
  static String qrSourceCount(int count) =>
      _locale == 'zh' ? '包含 $count 个源' : 'Contains $count sources';
  static String get qrSingleSource => _get('单个源', 'Single source');
  static String qrSourceNamed(String name) =>
      _locale == 'zh' ? '源：$name' : 'Source: $name';

  // ----- 压缩包导入（archive_import_dialog） -----
  static String get archiveNoTxtSelected =>
      _get('没有选中的 TXT 文件需要检测编码', 'No selected TXT files need encoding detection');
  static String archiveExtractFailed(String error) =>
      _locale == 'zh' ? '解压失败: $error' : 'Extraction failed: $error';
  static String get archiveDetectFailed => _get('检测失败', 'Detection failed');
  static String archiveEncodingDetectFailed(String error) =>
      _locale == 'zh' ? '编码检测失败: $error' : 'Encoding detection failed: $error';
  static String archiveNoImportableFiles(int selected) => _locale == 'zh'
      ? '压缩包内未解压出可导入文件（已选 $selected 本）'
      : 'No importable files extracted from the archive ($selected selected)';
  static String archiveNothingImported(int selected) => _locale == 'zh'
      ? '未导入任何文件（已选 $selected 本）'
      : 'Nothing imported ($selected selected)';
  static String archiveImportedCount(int count) =>
      _locale == 'zh' ? '成功导入 $count 本书籍' : 'Imported $count books';
  static String archiveMoreFailed(int count) =>
      _locale == 'zh' ? '（另有 $count 本）' : ' ($count more)';
  static String archiveImportFailedDetail(String detail) =>
      _locale == 'zh' ? '导入失败：$detail' : 'Import failed: $detail';
  static String archivePartialImport(int done, int failed, String detail) =>
      _locale == 'zh'
          ? '成功导入 $done 本，$failed 本失败：$detail'
          : 'Imported $done, $failed failed: $detail';
  static String archiveKeptFilesNote(String summary) => _locale == 'zh'
      ? '$summary（解压文件保留在应用文档/archive_import 目录，可重试）'
      : '$summary (extracted files are kept in the app documents/archive_import folder for retries)';
  static String archiveEncodingConvertFailed(String fileName) =>
      _locale == 'zh' ? '$fileName：编码转换失败' : '$fileName: encoding conversion failed';
  static String get archiveImportTitle => _get('压缩包导入', 'Import archive');
  static String get archiveRarPassword =>
      _get('RAR 密码（可选）', 'RAR password (optional)');
  static String archiveImportInProgress(int processed, int total) =>
      _locale == 'zh' ? '导入中 $processed/$total' : 'Importing $processed/$total';
  static String archiveImportCount(int count) =>
      _locale == 'zh' ? '导入 ($count)' : 'Import ($count)';
  static String get archiveNoBooksInArchive =>
      _get('压缩包内没有可导入的书籍文件', 'No importable book files in the archive');
  static String archiveEncodingLabel(String encoding) =>
      _locale == 'zh' ? '编码: $encoding' : 'Encoding: $encoding';
  static String get archiveTxtEncoding => _get('TXT 编码', 'TXT encoding');
  static String get archiveDetectEncoding => _get('检测编码', 'Detect encoding');

  // ----- 直链上传配置（direct_link_upload_settings_sheet） -----
  static String get directLinkInvalidFallback => _get(
      '已保存的直链规则无效，已回退默认规则',
      'The saved direct-link rules are invalid; falling back to the default rules');
  static String directLinkReadRulesFailed(String error) =>
      _locale == 'zh' ? '读取直链上传规则失败：$error' : 'Failed to read direct-link upload rules: $error';
  static String directLinkReadDefaultFailed(String error) =>
      _locale == 'zh' ? '读取默认规则失败：$error' : 'Failed to read the default rules: $error';
  static String directLinkDefaultSuffix(String summary) =>
      _locale == 'zh' ? '$summary（默认）' : '$summary (default)';
  static String directLinkDefaultImported(String summary) =>
      _locale == 'zh' ? '已导入默认规则「$summary」' : 'Imported the default rule "$summary"';
  static String get directLinkRulesCopied =>
      _get('规则已复制到剪贴板', 'Rules copied to the clipboard');
  static String directLinkClipboardReadFailed(String error) =>
      _locale == 'zh' ? '读取剪贴板失败：$error' : 'Failed to read the clipboard: $error';
  static String get directLinkClipboardInvalid =>
      _get('剪贴板为空或格式不正确', 'The clipboard is empty or malformed');
  static String directLinkPasted(String summary) =>
      _locale == 'zh' ? '已粘贴规则「$summary」' : 'Pasted the rule "$summary"';
  static String get directLinkTestResult => _get('测试结果', 'Test result');
  static String get directLinkSaved =>
      _get('已保存直链上传规则', 'Direct-link upload rules saved');
  static String directLinkSaveFailed(String error) =>
      _locale == 'zh' ? '保存失败：$error' : 'Save failed: $error';
  static String get directLinkConfigTitle =>
      _get('直链上传配置', 'Direct link upload configuration');
  static String get directLinkMoreMenu => _get('更多菜单', 'More menu');
  static String get directLinkUploadUrl => _get('上传 URL', 'Upload URL');
  static String get directLinkUploadUrlHelper =>
      _get('支持 url,{选项 JSON} 形式', 'Supports the url,{options JSON} form');
  static String get directLinkDownloadRule =>
      _get('下载 URL 规则', 'Download URL rule');
  static String get directLinkDownloadRuleHelper =>
      _get('JSONPath / 正则 / @js: 级联', 'JSONPath / regex / @js: cascade');
  static String get directLinkComment => _get('注释', 'Comment');
  static String get directLinkCompress => _get('是否压缩', 'Compressed or not');
  static String get directLinkCompressDesc =>
      _get('上传前压缩为 zip', 'Compress to zip before uploading');
  static String get directLinkSecurityNote => _get(
      '安全提示：规则可能来自网络，上传内容与下载链接由所填服务器处理；下载规则支持 JS 脚本，请确认来源可信后再使用。',
      'Security note: rules may come from the network, and uploaded content and download links are handled by the server you enter; download rules support JS scripts, so make sure the source is trustworthy before use.');
  static String get directLinkTesting => _get('测试中', 'Testing');
  static String get directLinkCopyResult => _get('复制结果', 'Copy result');
  static String directLinkCopyFailed(String error) =>
      _locale == 'zh' ? '复制失败：$error' : 'Copy failed: $error';

  // ----- 替换规则编辑（replace_rule_edit_screen） -----
  static String get replaceRuleEmptyPattern =>
      _get('匹配规则不能为空', 'The pattern cannot be empty');
  static String get replaceRuleInvalidRegex =>
      _get('正则语法错误或不支持', 'Invalid or unsupported regular expression');
  static String get replaceRuleFocusFirst =>
      _get('请先聚焦到要编辑的输入框', 'Focus the input field to edit first');
  static String get replaceRuleCopied =>
      _get('规则已复制到剪贴板', 'Rule copied to the clipboard');
  static String get replaceRuleInvalidJson =>
      _get('剪贴板内容不是有效的替换规则 JSON', 'The clipboard is not valid replacement-rule JSON');
  static String replaceRulePasted(String name) => _locale == 'zh'
      ? '已粘贴规则「$name」'
      : 'Pasted the rule "$name"';
  static String get replaceRulePreviewFailed =>
      _get('预览执行失败（输入不合法）', 'Preview failed (invalid input)');
  static String get replaceRuleEditTitle => _get('编辑替换规则', 'Edit replacement rule');
  static String get replaceRuleAddTitle => _get('添加替换规则', 'Add replacement rule');
  static String get replaceRuleFullscreenEdit => _get('全屏编辑', 'Full-screen editing');
  static String get replaceRulePattern => _get('匹配规则', 'Match Pattern');
  static String get replaceRulePatternHint =>
      _get('正则表达式或文本', 'Regular expression or text');
  static String get replaceRuleReplacement => _get('替换为', 'Replace With');
  static String get replaceRuleScope => _get('特定范围', 'Specific Scope');
  static String get replaceRuleScopeHint =>
      _get('留空为全局，输入书名为特定书籍', 'Leave empty for global; enter a book title to scope it');
  static String get replaceRuleExclude => _get('排除范围', 'Exclude Scope');
  static String get replaceRuleExcludeHint =>
      _get('输入书名，多个用逗号分隔', 'Enter book titles, separated by commas');
  static String get replaceRuleNoGroup => _get('（无分组）', '(No group)');
  static String get replaceRuleCustomGroup => _get('自定义…', 'Custom…');
  static String get replaceRuleGroupName => _get('输入分组名', 'Enter a group name');
  static String get replaceRuleGroupHint =>
      _get('多个分组用逗号分隔', 'Separate multiple groups with commas');
  static String get replaceRuleTitleField => _get('标题', 'Title');
  static String get replaceRuleScopeDesc => _get(
      '点选规则生效的内容范围；未选范围不受该规则影响',
      'Select the content scopes the rule applies to; unselected scopes are unaffected');
  static String get replaceRuleTimeout => _get('超时时间（毫秒）', 'Timeout (ms)');
  static String get replaceRuleTimeoutDesc => _get(
      '匹配/替换执行超时，空或非法输入回退 3000 毫秒',
      'Match/replace execution timeout; empty or invalid input falls back to 3000 ms');
  static String get replaceRulePreviewInput => _get('预览输入', 'Preview input');
  static String get replaceRulePreviewOutput => _get('预览输出', 'Preview output');
  static String get replaceRulePreviewLive =>
      _get('（随输入实时更新）', '(Updates live as you type)');

  // ----- 封面相册管理（cover_album_manage_screen） -----
  static String get coverAlbumNew => _get('新建相册', 'Create album');
  static String coverAlbumCreated(String name) =>
      _locale == 'zh' ? '已创建相册「$name」' : 'Created the album "$name"';
  static String coverAlbumCreateFailed(String error) =>
      _locale == 'zh' ? '新建相册失败：$error' : 'Failed to create the album: $error';
  static String get coverAlbumRename => _get('重命名相册', 'Rename album');
  static String coverAlbumRenamed(String name) =>
      _locale == 'zh' ? '已重命名为「$name」' : 'Renamed to "$name"';
  static String coverAlbumRenameFailed(String error) =>
      _locale == 'zh' ? '重命名失败：$error' : 'Rename failed: $error';
  static String get coverAlbumDeleteTitle => _get('删除相册', 'Delete album');
  static String coverAlbumDeleteConfirm(String name) => _locale == 'zh'
      ? '确定删除相册「$name」？相册内图片会一并删除。'
      : 'Delete the album "$name"? Images in it will be deleted too.';
  static String coverAlbumDeleted(String name) =>
      _locale == 'zh' ? '已删除相册「$name」' : 'Deleted the album "$name"';
  static String coverAlbumDeleteFailed(String error) =>
      _locale == 'zh' ? '删除失败：$error' : 'Delete failed: $error';
  static String coverAlbumSetDefault(String name) =>
      _locale == 'zh' ? '已将「$name」设为默认封面' : 'Set "$name" as the default cover';
  static String coverAlbumSetDefaultFailed(String error) =>
      _locale == 'zh' ? '设置默认封面失败：$error' : 'Failed to set the default cover: $error';
  static String get coverAlbumTitle => _get('封面相册', 'Cover albums');
  static String get coverAlbumEmpty => _get('暂无封面相册', 'No cover albums');
  static String get coverAlbumEmptyDesc => _get(
      '点击右上角新建相册，导入日间/夜间封面图',
      'Tap create album at the top right to import day/night cover images');
  static String get coverAlbumNameHint => _get('相册名称', 'Album name');
  static String coverAlbumCounts(int light, int dark) =>
      _locale == 'zh' ? '日间 $light · 夜间 $dark' : 'Day $light · Night $dark';
  static String get coverAlbumInUse => _get('当前使用', 'In use');
  static String get coverAlbumOps => _get('相册操作', 'Album actions');
  static String get coverAlbumCurrentDefault =>
      _get('当前默认封面', 'Current default cover');
  static String get coverAlbumSetDefaultAction =>
      _get('设为默认封面', 'Set as default cover');
  static String coverAlbumReadFailed(String name, String error) =>
      _locale == 'zh' ? '$name：读取失败（$error）' : '$name: read failed ($error)';
  static String coverAlbumImported(int count) =>
      _locale == 'zh' ? '已导入 $count 张' : 'Imported $count';
  static String coverAlbumDuplicates(int count) => _locale == 'zh'
      ? '$count 张图片已存在，未重复导入'
      : '$count images already exist and were skipped';
  static String coverAlbumSkipped(int count, String first) =>
      _locale == 'zh' ? '$count 张跳过：$first' : '$count skipped: $first';
  static String get coverAlbumDeleteImageTitle => _get('删除图片', 'Delete image');
  static String get coverAlbumDeleteImageConfirm =>
      _get('确定从相册中删除这张图片吗？', 'Delete this image from the album?');
  static String get coverAlbumImageDeleted => _get('已删除 1 张图片', 'Deleted 1 image');
  static String coverAlbumDeleteImageFailed(String error) =>
      _locale == 'zh' ? '删除图片失败：$error' : 'Failed to delete the image: $error';
  static String get coverAlbumMissing =>
      _get('相册不存在或已删除', 'The album does not exist or was deleted');
  static String get coverAlbumImportImage => _get('导入图片', 'Import image');
  static String get coverAlbumDay => _get('日间', 'Day');
  static String get coverAlbumNoImages =>
      _get('暂无图片，点击右上角导入', 'No images; tap import at the top right');

  // ----- 隐私设置（privacy_settings_screen） -----
  static String get privacyReadFailedRetry =>
      _get('无法读取隐私设置，请重试', 'Unable to read privacy settings, please retry');
  static String get privacyEnterToOpen =>
      _get('输入当前隐私密码以进入隐私设置', 'Enter the current privacy password to open privacy settings');
  static String get privacyPrivateUnavailable => _get(
      '私密标记暂不可用，当前按未锁定显示；请稍后重试或检查数据库。',
      'Private markers are unavailable; content shows as unlocked. Retry later or check the database.');
  static String get privacyCredentialSection => _get('凭据', 'Credentials');
  static String get privacyEnableFeature => _get('启用私密功能', 'Enable private content');
  static String get privacyEnableFeatureDesc =>
      _get('保护私密分组与私密书籍', 'Protect private groups and private books');
  static String get privacyChangePassword => _get('修改密码', 'Change password');
  static String get privacySetPassword => _get('设置密码', 'Set password');
  static String get privacyChangePasswordDesc =>
      _get('修改前需验证当前密码', 'Verify the current password before changing');
  static String get privacySetPasswordDesc =>
      _get('设置后才能开启私密功能', 'Set a password to enable private content');
  static String get privacyClearPassword => _get('清除密码', 'Clear password');
  static String get privacyClearPasswordDesc =>
      _get('需验证当前密码', 'Requires the current password');
  static String get privacyBiometricUnlock => _get('生物快捷解锁', 'Biometric unlock');
  static String get privacyVerifyTiming => _get('验证时机', 'When to verify');
  static String get privacyVerifyOnPrivateGroup =>
      _get('进入私密分组时验证', 'Verify when opening a private group');
  static String get privacyVerifyOnPrivateBook =>
      _get('打开私密书籍时验证', 'Verify when opening a private book');
  static String get privacyVerifyOnStartup => _get('启动应用时验证', 'Verify on app start');
  static String get privacyVerifyOnStartupDesc =>
      _get('下次启动应用时需要密码', 'A password is required on the next app start');
  static String get privacyVerifyFrequency => _get('验证频率', 'Verification frequency');
  static String get privacyVerifyFrequencyDesc => _get(
      '「每次进入」仅作用于私密分组与书籍',
      '"Every time" applies only to private groups and books');
  static String get privacyGraceAfterLeave => _get('离开后宽限', 'Grace period after leaving');
  static String get privacyGraceAfterLeaveDesc => _get(
      '离开应用超过该时长后重新验证', 'Re-verify after leaving the app for this long');
  static String get privacySessionNote => _get(
      '「应用会话内」在本次应用运行期间只验证一次，离开后台不失效；「离开后台后」离开超过宽限时间后才需要重新验证。',
      '"Within the app session" verifies once per app run and survives backgrounding; "After leaving background" requires re-verification only after the grace period.');
  static String get privacyNotesSection => _get('说明', 'Notes');
  static String get privacyNoteLocalOnly => _get(
      '隐私密码凭据仅保存在本机，不随应用内备份或书籍导出。启用私密功能后，忘记密码将无法访问私密内容。启动应用验证只在下次启动应用时触发；私密书籍与分组在书架、详情与阅读器中均按验证状态脱敏或放行。',
      'The privacy password credential is stored only on this device and is not included in in-app backups or book exports. If you forget the password after enabling private content, you cannot access private content. Startup verification triggers only on the next app start; private books and groups are masked or allowed according to verification state on the bookshelf, details, and reader.');
  static String get privacyNoteBackup => _get(
      '私密内容不会从本地与 WebDAV 备份（含自动上传）、书籍导出、进度同步或 Web 服务中排除。如需彻底保护，请勿分享备份文件、不要在不可信网络开启 Web 服务；开启后同一网络内任何设备均可访问。',
      'Private content is not excluded from local and WebDAV backups (including auto-upload), book exports, progress sync, or the Web service. For full protection, do not share backup files and do not enable the Web service on untrusted networks; once enabled, any device on the same network can access it.');
  static String get privacyNoteCloudBackup => _get(
      '隐私密码凭据（加盐校验值）与私密标记保存在应用数据库内，可能随 Android 系统云备份一起迁移到其他设备。',
      'The privacy password credential (salted hash) and private markers are stored in the app database and may migrate to other devices with Android system cloud backup.');
  static String get privacySetPasswordFirst =>
      _get('请先设置隐私密码', 'Set a privacy password first');
  static String get privacyPasswordChanged => _get('密码已修改', 'Password changed');
  static String get privacyPasswordSet => _get('密码已设置', 'Password set');
  static String get privacyFeatureOff => _get('私密功能已关闭', 'Private content turned off');
  static String get privacyPasswordCleared => _get('密码已清除', 'Password cleared');
  static String get privacyBiometricUnavailable => _get(
      '已开启；当前生物识别不可用，可关闭',
      'On; biometrics are currently unavailable and can be turned off');
  static String get privacyBiometricOn =>
      _get('已开启，解锁时可使用指纹或面容', 'On; fingerprint or face unlock is available');
  static String get privacyBiometricReading =>
      _get('正在读取生物识别状态', 'Reading biometric status');
  static String get privacyBiometricHint =>
      _get('使用指纹或面容快速解锁', 'Unlock quickly with fingerprint or face');
  static String get closeFailedRetry => _get('关闭失败，请重试', 'Failed to turn off, please retry');
  static String get privacyEnterCurrentPassword =>
      _get('请输入当前密码', 'Enter the current password');
  static String get privacyNewPasswordEmpty =>
      _get('新密码不能为空', 'The new password cannot be empty');
  static String get privacyNewPasswordTooLong =>
      _get('新密码不能超过 128 个字符', 'The new password cannot exceed 128 characters');
  static String get privacyPasswordMismatch =>
      _get('两次输入的密码不一致', 'The passwords do not match');
  static String get privacyNewPasswordInvalid =>
      _get('新密码不能为空或超过 128 个字符', 'The new password must be non-empty and at most 128 characters');
  static String get privacySetPasswordFailed =>
      _get('设置密码失败，请重试', 'Failed to set the password, please retry');
  static String get privacyCurrentPassword => _get('当前密码', 'Current password');
  static String get privacyNewPassword => _get('新密码', 'New password');
  static String get privacyConfirmNewPassword =>
      _get('确认新密码', 'Confirm new password');
  static String get privacyClearConfirm => _get(
      '清除后私密内容将不再要求密码。确定清除吗？',
      'After clearing, private content will no longer require a password. Clear it?');
  static String get privacyClearFailed =>
      _get('清除失败，请重试', 'Failed to clear, please retry');

  // ----- 订阅源编辑（rss_source_edit_screen）字段标签 -----
  static String get rssFieldSourceName => _get('源名称', 'Source name');
  static String get rssFieldSourceUrl => _get('源 URL', 'Source URL');
  static String get rssFieldSourceIcon => _get('图标', 'Icon');
  static String get rssFieldIconUrl => _get('图标 URL', 'Icon URL');
  static String get rssFieldSourceGroup => _get('源分组', 'Source group');
  static String get rssFieldGroupHint =>
      _get('多个分组用逗号分隔', 'Separate multiple groups with commas');
  static String get rssFieldSourceComment => _get('源注释', 'Source comment');
  static String get rssFieldSortUrl => _get('分类 URL', 'Category URL');
  static String get rssFieldSortUrlHint => _get('分类名::规则', 'Category name::rule');
  static String get rssFieldLoginUrl => _get('登录 URL', 'Login URL');
  static String get rssFieldLoginUi => _get('登录界面', 'Login UI');
  static String get rssFieldLoginCheckJs => _get('登录检测 JS', 'Login check JS');
  static String get rssFieldCoverDecodeJs => _get('封面解码 JS', 'Cover decode JS');
  static String get rssFieldHeader => _get('请求头', 'Request headers');
  static String get rssFieldVariableComment =>
      _get('源变量注释', 'Source variable comment');
  static String get rssFieldConcurrentRate => _get('并发率', 'Concurrency rate');
  static String get rssFieldConcurrentRateHint => _get('如：16/s', 'e.g. 16/s');
  static String get rssFieldJsLib => _get('JS 库', 'JS library');
  static String get rssFieldJsLibHint =>
      _get('源使用的 JavaScript 库', 'JavaScript library used by the source');
  static String get rssFieldStartHtml => _get('初始 HTML', 'Initial HTML');
  static String get rssFieldStartStyle => _get('初始样式', 'Initial style');
  static String get rssFieldStartJs => _get('初始 JS', 'Initial JS');
  static String get rssFieldPreloadJs => _get('预加载 JS', 'Preload JS');
  static String get rssFieldArticles => _get('文章列表规则', 'Article list rule');
  static String get rssFieldArticlesHint =>
      _get('ruleArticles，如 item 或 //item', 'ruleArticles, e.g. item or //item');
  static String get rssFieldNextPage => _get('下一页规则', 'Next page rule');
  static String get rssFieldTitle => _get('标题规则', 'Title rule');
  static String get rssFieldPubDate => _get('日期规则', 'Date rule');
  static String get rssFieldDescription => _get('描述规则', 'Description rule');
  static String get rssFieldImage => _get('图片规则', 'Image rule');
  static String get rssFieldLink => _get('链接规则', 'Link rule');
  static String get rssFieldContent => _get('内容规则', 'Content rule');
  static String get rssFieldStyle => _get('样式', 'Style');
  static String get rssFieldStyleHint => _get('文章页面 CSS', 'Article page CSS');
  static String get rssFieldInjectJs => _get('注入 JS', 'Inject JS');
  static String get rssFieldContentWhitelist =>
      _get('内容白名单', 'Content whitelist');
  static String get rssFieldContentBlacklist =>
      _get('内容黑名单', 'Content blacklist');
  static String get rssFieldUrlInterceptor => _get('URL 拦截', 'URL interception');
  static String get rssTypeWeb => _get('网页', 'Web page');
  static String get rssStyleSingle => _get('单列', 'Single column');
  static String get rssStyleDouble => _get('双列', 'Two columns');
  static String get rssStyleWaterfall => _get('瀑布', 'Waterfall');
  static String get rssStyleTriple => _get('三列', 'Three columns');
  static String get rssSourceNameRequired =>
      _get('请输入源名称', 'Enter the source name');
  static String get rssSourceUrlRequired => _get('请输入源 URL', 'Enter the source URL');
  static String get rssSourceUpdated => _get('订阅源已更新', 'RSS source updated');
  static String get rssSourceAdded => _get('订阅源已添加', 'RSS source added');
  static String get rssSourceUnsavedTitle => _get('未保存的修改', 'Unsaved changes');
  static String get rssSourceUnsavedDesc =>
      _get('修改尚未保存，确定要放弃修改并退出吗？', 'Changes are not saved. Discard them and exit?');
  static String get rssSourceDiscard => _get('放弃', 'Discard');
  static String get rssSourceEnterUrlFirst => _get('请先输入源 URL', 'Enter the source URL first');
  static String get rssSourceTestNoArticles => _get(
      '连接成功，但未获取到文章（可能需要配置规则）',
      'Connected but no articles were fetched (rules may need configuration)');
  static String get rssSourceUntitled => _get('(无标题)', '(Untitled)');
  static String rssSourceTestSuccess(int count, String titles) => _locale == 'zh'
      ? '成功获取 $count 篇文章：\n$titles'
      : 'Fetched $count articles:\n$titles';
  static String rssSourceTestFailed(String error) =>
      _locale == 'zh' ? '测试失败：$error' : 'Test failed: $error';
  static String get rssSourceCopied =>
      _get('已复制订阅源到剪贴板', 'RSS source copied to the clipboard');
  static String rssSourceShareSubject(String name) =>
      _locale == 'zh' ? '订阅源分享：$name' : 'RSS source share: $name';
  static String get rssSourceFillUrlFirst => _get('请先填写源 URL', 'Fill in the source URL first');
  static String rssSourceClearCookieFailed(String error) =>
      _locale == 'zh' ? '清除 Cookie 失败：$error' : 'Failed to clear cookies: $error';
  static String get rssSourceNotRssJson =>
      _get('不是订阅源 JSON', 'Not RSS source JSON');
  static String get rssSourcePasted =>
      _get('已从剪贴板粘贴订阅源', 'RSS source pasted from the clipboard');
  static String rssSourcePasteFailed(String error) => _locale == 'zh'
      ? '粘贴失败，剪贴板不是有效的订阅源 JSON：$error'
      : 'Paste failed; the clipboard is not valid RSS source JSON: $error';
  static String get rssSourceEditTitle => _get('编辑订阅源', 'Edit RSS source');
  static String get rssSourceNewTitle => _get('新建订阅源', 'Add RSS source');
  static String get rssSourceTabBasic => _get('基本', 'Basic');
  static String get rssSourceTabPreprocess => _get('预处理', 'Preprocessing');
  static String get rssSourceTabListRules => _get('列表规则', 'List rules');
  static String get rssSourceCopy => _get('复制源', 'Copy source');
  static String get rssSourceShareText => _get('分享文本', 'Share text');
  static String get rssSourceOptions => _get('选项', 'Options');
  static String get rssSourceSingleUrl => _get('单 URL', 'Single URL');
  static String get rssSourcePreload => _get('预加载', 'Preload');
  static String get rssSourceTypeLabel => _get('类型', 'Type');
  static String get rssSourceEnableJs => _get('启用 JS', 'Enable JS');
  static String get rssSourceLoadWithBaseUrl =>
      _get('以 base URL 加载', 'Load with base URL');
  static String get rssSourceShowWebLog => _get('显示网页日志', 'Show web page log');
  static String get rssSourceCacheFirst => _get('缓存优先', 'Cache first');

  // ----- 目录 / 书签 / 标注（toc_screen） -----
  static String get reparseToc => _get('重新解析目录', 'Reparse chapters');
  static String get reverseToc => _get('倒序目录', 'Reverse chapters');
  static String get loadCharCount => _get('加载字数', 'Load word count');
  static String get exportMarkdown => _get('导出 Markdown', 'Export Markdown');
  static String get tocEmptyHint =>
      _get('目录为空（可尝试其它规则）', 'The chapter list is empty (try other rules)');
  static String reparseFailed(String error) =>
      _locale == 'zh' ? '重新解析目录失败: $error' : 'Failed to reparse chapters: $error';
  static String reparseDone(int count) =>
      _locale == 'zh' ? '已重新解析目录（共 $count 章）' : 'Chapters reparsed ($count total)';
  static String get noBookmarksToExport =>
      _get('暂无书签可导出', 'No bookmarks to export');
  static String get closeSearch => _get('关闭搜索', 'Close search');
  static String get locateCurrentChapter =>
      _get('定位至当前阅读', 'Jump to current reading position');
  static String get scrollToTop => _get('移至顶部', 'Move to top');
  static String get scrollToBottom => _get('移至底部', 'Move to bottom');
  static String get cacheFromCurrent => _get('一键缓存', 'Cache all');
  static String get tocNoCacheable => _get('无可缓存的章节', 'No chapters to cache');
  static String get tocQueuedFromCurrent =>
      _get('已从当前章加入缓存队列', 'Added to the cache queue from the current chapter');
  static String tocCacheStartFailed(String error) =>
      _locale == 'zh' ? '缓存启动失败：$error' : 'Failed to start caching: $error';
  static String tocChapterQueued(String title, {required bool retry}) => _locale == 'zh'
      ? '「$title」${retry ? '已加入重新下载队列' : '已加入缓存队列'}'
      : '"$title" ${retry ? 'added to the re-download queue' : 'added to the cache queue'}';
  static String tocChapterIndexQueued(int index, {required bool retry}) => _locale == 'zh'
      ? '第 $index 章${retry ? '已加入重新下载队列' : '已加入缓存队列'}'
      : 'Chapter $index ${retry ? 'added to the re-download queue' : 'added to the cache queue'}';
  static String tocRedownloadStartFailed(String error) =>
      _locale == 'zh' ? '重新下载启动失败：$error' : 'Failed to start re-downloading: $error';
  static String get tocNoMatchingChapters =>
      _get('未找到匹配的章节', 'No matching chapters');
  static String get redownloadChapter => _get('重新下载本章', 'Re-download this chapter');
  static String get downloadChapter => _get('下载本章', 'Download this chapter');
  static String get noBookmarks => _get('暂无书签', 'No bookmarks');
  static String get tocNoMatchingBookmarks =>
      _get('未找到匹配的书签', 'No matching bookmarks');
  static String bookmarkNote(String content) =>
      _locale == 'zh' ? '备注: $content' : 'Note: $content';
  static String get deleteBookmark => _get('删除书签', 'Delete bookmark');
  static String deleteBookmarkConfirm(String chapterName) => _locale == 'zh'
      ? '确定删除「$chapterName」的书签吗？'
      : 'Delete the bookmark for "$chapterName"?';
  static String get noMarkings => _get('暂无标注', 'No annotations');
  static String get tocNoMatchingMarkings =>
      _get('未找到匹配的标注', 'No matching annotations');
  static String markingLoadFailed(String error) =>
      _locale == 'zh' ? '笔记加载失败：$error' : 'Failed to load notes: $error';
  static String chapterIndexLabel(int index) =>
      _locale == 'zh' ? '第$index章' : 'Chapter $index';
  static String markingNote(String note) =>
      _locale == 'zh' ? '备注: $note' : 'Note: $note';
  static String get noteSaved => _get('已保存笔记', 'Note saved');
  static String noteUpdateFailed(String error) =>
      _locale == 'zh' ? '更新笔记失败：$error' : 'Failed to update the note: $error';
  static String tocNoteLine(String note) =>
      _locale == 'zh' ? '笔记: $note' : 'Note: $note';

  // ----- 高亮规则（highlight_rules_screen） -----
  static String highlightBatchSuffix(int count) =>
      _locale == 'zh' ? ' 等 $count 条' : ' and $count more';
  static String highlightBatchFailed(String action, String head, String suffix) =>
      _locale == 'zh' ? '$action失败：$head$suffix' : '$action failed: $head$suffix';
  static String get highlightSelectRulesFirst =>
      _get('请先选择规则', 'Select rules first');
  static String get highlightDeleteTitle => _get('删除高亮规则', 'Delete highlight rules');
  static String highlightDeleteConfirm(int count) => _locale == 'zh'
      ? '确定删除选中的 $count 条规则吗？'
      : 'Delete the $count selected rules?';
  static String highlightGroupOpFailed(String error) =>
      _locale == 'zh' ? '分组操作失败：$error' : 'Group operation failed: $error';
  static String highlightDeleteOneConfirm(String name) =>
      _locale == 'zh' ? '确定删除吗？\n$name' : 'Delete this?\n$name';
  static String highlightOpFailed(String error) =>
      _locale == 'zh' ? '操作失败: $error' : 'Operation failed: $error';
  static String get noHighlightRules => _get('暂无高亮规则', 'No highlight rules');
  static String get exportHighlightRules => _get('导出高亮规则', 'Export highlight rules');
  static String get loadingHighlightRules =>
      _get('加载高亮规则...', 'Loading highlight rules...');
  static String get noHighlightRulesDesc => _get(
      '点击右上角「+」新增自动高亮规则',
      'Tap "+" at the top right to add an automatic highlight rule');
  static String get groupNoRules => _get('该分组暂无规则', 'No rules in this group');
  static String get exitBatch => _get('退出批量', 'Exit batch mode');
  static String highlightSelectedCount(int count) =>
      _locale == 'zh' ? '已选 $count 项' : '$count selected';
  static String highlightSelectedCountBusy(int count) =>
      _locale == 'zh' ? '已选 $count 项 · 处理中…' : '$count selected · Working…';
  static String get highlightDisableSelected =>
      _get('停用选中', 'Disable selected');
  static String get batchManage => _get('批量管理', 'Batch manage');
  static String get exportRules => _get('导出规则', 'Export rules');
  static String highlightScopeLabel(String scope) =>
      _locale == 'zh' ? '范围：$scope' : 'Scope: $scope';
  static String get highlightGlobalScope => _get('全局生效', 'Applies globally');
  static String highlightGroupLabel(String group) =>
      _locale == 'zh' ? '分组：$group' : 'Group: $group';
  static String highlightBatchErrorList(String action, List<String> errors) =>
      _locale == 'zh'
          ? '$action失败 ${errors.length} 条：${errors.take(3).join('；')}'
          : '$action failed for ${errors.length}: ${errors.take(3).join('; ')}';
  static String highlightBatchErrorJoined(String action, List<String> errors) =>
      _locale == 'zh'
          ? '$action失败：${errors.join('；')}'
          : '$action failed: ${errors.join('; ')}';
  static String get highlightGroupNameRequired =>
      _get('分组名称不能为空', 'The group name cannot be empty');
  static String get highlightReservedGroupName =>
      _get('分组名称不可使用保留名', 'The group name cannot be a reserved name');
  static String highlightDeleteGroupConfirm(String group, int count) => _locale == 'zh'
      ? '确定删除分组「$group」吗？\n$count 条规则将变为未分组（规则本身保留）。'
      : 'Delete the group "$group"? $count rules become ungrouped (the rules themselves are kept).';
  static String highlightRuleCount(int count) =>
      _locale == 'zh' ? '$count 条规则' : '$count rules';
  static String get highlightEmptyPattern =>
      _get('匹配模式不能为空', 'The pattern cannot be empty');
  static String get highlightInvalidRegex =>
      _get('正则表达式无效，请检查', 'Invalid regular expression, please check');
  static String get highlightFollowTextColor =>
      _get('跟随文字色', 'Follow text color');
  static String get highlightNewTitle => _get('新增高亮规则', 'Add highlight rule');
  static String get highlightEditTitle => _get('编辑高亮规则', 'Edit highlight rule');
  static String get highlightRuleNameOptional =>
      _get('规则名称（可选）', 'Rule name (optional)');
  static String get highlightPatternRequired => _get('匹配模式 *', 'Pattern *');
  static String get highlightPatternHint =>
      _get('要自动高亮的文本或正则表达式', 'Text or regular expression to highlight automatically');
  static String get highlightApplyToTitle => _get('应用到标题', 'Apply to title');
  static String get highlightScopeOptional => _get('生效范围（可选）', 'Scope (optional)');
  static String get highlightScopeHint => _get(
      '书名或书源名，留空为全局生效',
      'Book title or source name; leave empty to apply globally');
  static String get highlightGroupOptional => _get('分组（可选）', 'Group (optional)');
  static String get highlightGroupHint => _get('留空为未分组', 'Leave empty to keep ungrouped');
  static String get highlightBackgroundFill => _get('背景填充', 'Background fill');
  static String get effectUnderline => _get('下划线', 'Underline');
  static String get highlightLineStyle => _get('线型', 'Line style');
  static String get highlightLineWidth => _get('线宽', 'Line width');
  static String get highlightPreview => _get('高亮效果预览', 'Highlight preview');
  static String get lineStyleWavy => _get('波浪', 'Wavy');
  static String get lineStyleDotted => _get('点线', 'Dotted');
  static String get lineStyleDouble => _get('双线', 'Double');
  static String get lineStyleSolid => _get('实线', 'Solid');

  // ============== L10N 批 2 组 D：screens 第三批（17 个页面） ==============

  // ----- 通用补充 -----
  static String get open => _get('打开', 'Open');
  static String get load => _get('加载', 'Load');
  static String get paste => _get('粘贴', 'Paste');
  static String get stop => _get('停止', 'Stop');
  static String get back => _get('返回', 'Back');
  static String get reload => _get('重新加载', 'Reload');
  static String get moreMenu => _get('更多菜单', 'More menu');
  static String get noReadRecords => _get('暂无阅读记录', 'No reading records');
  static String get thumbUp => _get('赞', 'Like');
  static String get thumbDown => _get('踩', 'Dislike');
  static String get currentLabel => _get('当前', 'Current');
  static String get unknownSource => _get('未知书源', 'Unknown source');
  static String get onLabel => _get('开启', 'On');
  static String get offLabel => _get('关闭', 'Off');
  static String get exploreEnabled => _get('发现已启用', 'Discovery on');
  static String get exploreDisabled => _get('发现已禁用', 'Discovery off');
  static String get enableExplore => _get('启用发现', 'Enable discovery');
  static String get disableExplore => _get('禁用发现', 'Disable discovery');
  static String get enableSelectedSources =>
      _get('启用所选', 'Enable selected');
  static String get disableSelectedSources =>
      _get('禁用所选', 'Disable selected');
  static String get removeGroup => _get('移除分组', 'Remove group');
  static String get deletedLabel => _get('已删除', 'Deleted');
  static String get updatedLabel => _get('已更新', 'Updated');
  static String get addedLabel => _get('已添加', 'Added');
  static String get exportAll => _get('导出全部', 'Export all');
  static String get exportSelectedItems =>
      _get('导出所选', 'Export selected');
  static String get exportCurrentSelection =>
      _get('导出当前选中', 'Export current selection');
  static String get exportToClipboard =>
      _get('导出到剪贴板', 'Export to clipboard');
  static String get loadMore => _get('加载更多', 'Load more');
  static String get loadMoreFailed => _get('加载更多失败', 'Failed to load more');
  static String get noMoreContent => _get('已经到底了~', 'No more content');
  static String get refreshSort => _get('刷新排序', 'Refresh sorts');
  static String get switchLayout => _get('切换布局', 'Switch layout');
  static String get switchLabel => _get('切换', 'Switch');
  static String get fullscreen => _get('全屏', 'Fullscreen');
  static String get exitFullscreen => _get('退出全屏', 'Exit fullscreen');
  static String get searchFilter => _get('搜索筛选', 'Search filter');
  static String get searchAgain => _get('重新搜索', 'Search again');
  static String get advancedOptions => _get('高级选项', 'Advanced options');
  static String get refreshList => _get('刷新列表', 'Refresh list');
  static String get checkAuthor => _get('校验作者', 'Check author');
  static String get loadWordCount => _get('加载字数', 'Load word count');
  static String get loadInfo => _get('加载信息', 'Load info');
  static String get loadToc => _get('加载目录', 'Load TOC');
  static String get scrollToTopOfList => _get('滚到顶部', 'Scroll to top');
  static String get scrollToBottomOfList =>
      _get('滚到底部', 'Scroll to bottom');
  static String get sourceGroup => _get('源分组', 'Source group');
  static String get currentSourceLabel => _get('当前书源', 'Current source');
  static String get filterBySourceName =>
      _get('按书源名称筛选', 'Filter by source name');
  static String get sortDescending => _get('降序', 'Descending');
  static String get sortManual => _get('手动排序', 'Manual');
  static String get sortAutoWeight => _get('自动排序（权重）', 'Auto (weight)');
  static String get sortByName => _get('按名称', 'By name');
  static String get sortByUrl => _get('按 URL', 'By URL');
  static String get sortByUpdateTime => _get('按更新时间', 'By update time');
  static String get sortByEnabledState => _get('按启用状态', 'By enabled state');
  static String get sortByResponseTime => _get('按响应时间', 'By response time');
  static String get resumeRefresh => _get('继续刷新', 'Resume refreshing');
  static String get stopRefresh => _get('停止刷新', 'Stop refreshing');
  static String get cancelChangeSource => _get('取消换源', 'Cancel source switch');
  static String get groupByDomain => _get('按域名分组显示', 'Group by domain');
  static String get groupByDomainOn =>
      _get('按域名分组显示 ✓', 'Group by domain ✓');
  static String get showBookshelfCount =>
      _get('显示书籍数量', 'Show bookshelf count');
  static String get customGroup => _get('自定义分组', 'Custom group');
  static String get customSourceGroup => _get('自定义源分组', 'Custom source group');
  static String get keepOriginalName => _get('保留原名', 'Keep original name');
  static String get keepGroup => _get('保留分组', 'Keep group');
  static String get keepEnabledState => _get('保留启用状态', 'Keep enabled state');
  static String get showSourceComment =>
      _get('显示源注释', 'Show source comments');
  static String get selectNewSources => _get('选中新增源', 'Select new sources');
  static String get selectUpdatedSources =>
      _get('选中更新源', 'Select updated sources');
  static String get pinSelectedTop => _get('置顶所选', 'Move selected to top');
  static String get pinSelectedBottom =>
      _get('置底所选', 'Move selected to bottom');
  static String get shareSelectedSources =>
      _get('分享选中源', 'Share selected sources');
  static String get checkSelected => _get('校验所选', 'Check selected');
  static String get selectSelectedRange =>
      _get('选中所选区间', 'Select the selected range');
  static String get closeCheckResult =>
      _get('关闭校验结果', 'Close check result');
  static String get loadingSources => _get('加载书源...', 'Loading sources...');
  static String get loadingArticles => _get('加载文章...', 'Loading articles...');
  static String get noSources => _get('暂无书源', 'No sources');
  static String get noSourcesHint => _get(
      '点击右上角菜单「新建书源」新建，或导入书源',
      'Use the "Add source" menu at the top right, or import sources');
  static String get noArticles => _get('暂无文章', 'No articles');
  static String get noArticlesHint =>
      _get('下拉刷新获取最新内容', 'Pull down to refresh');
  static String get readLabel => _get('已读', 'Read');
  static String get articleDetail => _get('文章详情', 'Article');
  static String get searchSourcesHint => _get('搜索书源', 'Search sources');
  static String get searchKeywordInputHint =>
      _get('输入搜索关键词', 'Enter a search keyword');
  static String get enterGroupName => _get('输入分组名称', 'Enter a group name');
  static String get checkKeywordHint =>
      _get('输入校验关键词', 'Enter the check keyword');
  static String get startCheck => _get('开始校验', 'Start check');
  static String get checkSelectedSourcesTitle =>
      _get('校验所选书源', 'Check selected sources');
  static String get selectSourcesToCheckFirst =>
      _get('请先选择要校验的书源', 'Select the sources to check first');
  static String get checkInProgressCancelFirst => _get(
      '校验进行中，请先取消当前校验', 'A check is in progress; cancel it first');
  static String get selectSourceFirst =>
      _get('请先选择书源', 'Select a source first');
  static String get formatErrorParen => _get('(格式错误)', '(Invalid format)');
  static String get chooseImportFile =>
      _get('选择导入文件', 'Choose import file');
  static String get contentUrl => _get('内容地址', 'Content URL');
  static String get pleaseEnterContentUrl =>
      _get('请先输入内容地址', 'Enter a content URL first');
  static String get fromFile => _get('从文件', 'From file');
  static String get fromClipboard => _get('从剪贴板', 'From clipboard');
  static String get go => _get('访问', 'Go');
  static String get goBackLabel => _get('后退', 'Back');
  static String get goForwardLabel => _get('前进', 'Forward');
  static String get openExternally => _get('外部打开', 'Open externally');
  static String get clearResult => _get('清空结果', 'Clear result');
  static String get executeResult => _get('执行结果', 'Result');
  static String get executeResultHint =>
      _get('将控制台输出粘贴到此处', 'Paste the console output here');
  static String get builtInBrowser => _get('内置浏览器', 'Built-in browser');
  static String get browserUrlHint =>
      _get('输入网址，如 https://example.com', 'Enter a URL, e.g. https://example.com');
  static String get browserEmptyTitle =>
      _get('输入网址开始浏览', 'Enter a URL to start browsing');
  static String get browserEmptyDesc => _get(
      '页面将在系统浏览器中打开，\n可配合 JS 提取助手抓取结果',
      'The page opens in the system browser;\nuse the JS extraction helper to capture results');
  static String get jsExtractHelper =>
      _get('JavaScript 提取助手', 'JavaScript extraction helper');
  static String get jsExtractHelperDesc => _get(
      '复制脚本 → 在外部浏览器控制台（F12）执行 → 将结果粘贴到下方',
      'Copy the script → run it in the external browser console (F12) → paste the result below');
  static String get jsSnippetPageTitle => _get('获取页面标题', 'Get page title');
  static String get jsSnippetBodyText => _get('获取正文文本', 'Get body text');
  static String get jsSnippetAllLinks => _get('获取所有链接', 'Get all links');
  static String get jsSnippetChapterList =>
      _get('获取章节列表', 'Get chapter list');
  static String get jsSnippetImageUrls =>
      _get('获取图片地址', 'Get image URLs');
  static String get appLogTitle => _get('应用日志', 'App log');
  static String get logTabMessage => _get('消息', 'Messages');
  static String get logTabCrash => _get('崩溃', 'Crashes');
  static String get logTabHttp => _get('HTTP', 'HTTP');
  static String get logActions => _get('日志操作', 'Log actions');
  static String get clearAllLogs => _get('清空全部', 'Clear all');
  static String get clearCurrentLevel => _get('清空当前级别', 'Clear current level');
  static String get clearAllLogsTitle => _get('清空全部日志', 'Clear all logs');
  static String get clearCurrentLevelLogsTitle =>
      _get('清空当前级别日志', 'Clear current level logs');
  static String get clearAllLogsConfirm => _get(
      '将清空 message/crash/http 全部级别日志，确定吗？',
      'This clears message/crash/http logs at all levels. Continue?');
  static String get clearCurrentLevelLogsConfirm =>
      _get('确定清空当前级别的日志吗？', 'Clear the logs at the current level?');
  static String get logsClearedAll => _get('已清空全部日志', 'All logs cleared');
  static String get logsClearedCurrentLevel =>
      _get('已清空当前级别日志', 'Current level logs cleared');
  static String get noLogsToExport => _get('暂无日志可导出', 'No logs to export');
  static String get sourceDebugTitle => _get('书源调试', 'Source debug');
  static String get clearLog => _get('清空日志', 'Clear log');
  static String get sourceUrlLabel => _get('书源 URL', 'Source URL');
  static String get sourceDebugUrlHint =>
      _get('输入要调试的书源地址', 'Enter the source URL to debug');
  static String get sourceDebugKeywordHint =>
      _get('关键词 / URL / ++目录 / --正文', 'Keyword / URL / ++toc / --content');
  static String get sourceDebugEmptyHint => _get(
      '输入书源 URL 和关键词后点击"调试"开始',
      'Enter a source URL and keyword, then tap "Debug"');
  static String get noMatchingLogEntries =>
      _get('没有匹配的日志条目', 'No matching log entries');
  static String get debugLevelSuccess => _get('成功', 'Success');
  static String get sourceDebugErrorUrlRequired =>
      _get('错误：请输入书源 URL', 'Error: enter a source URL');
  static String get sourceDebugErrorKeywordRequired =>
      _get('错误：请输入搜索关键词', 'Error: enter a search keyword');
  static String get sourceDebugStart => _get('⇒开始调试', '⇒ Debugging started');
  static String get jsScriptEmpty =>
      _get('脚本不能为空', 'The script cannot be empty');
  static String get syntaxError => _get('语法错误', 'Syntax error');
  static String get syntaxCheckPassed => _get('语法检查通过', 'Syntax check passed');
  static String get syntaxCheck => _get('语法检查', 'Syntax check');
  static String get curlConvert => _get('cURL 转换', 'cURL convert');
  static String get jsSourceTitle => _get('JS 书源', 'JS source');
  static String get jsSourceNewTitle => _get('新建 JS 书源', 'New JS source');
  static String get jsSourceEditTitle => _get('编辑 JS 书源', 'Edit JS source');
  static String get jsSourceConfigMissing => _get(
      '配置缺少 bookSourceUrl 或 bookSourceName',
      'The config is missing bookSourceUrl or bookSourceName');
  static String get jsSourceEditorHint =>
      _get('在此编写 JS 书源脚本…', 'Write the JS source script here…');
  static String get fontSerif => _get('衬线体 (Serif)', 'Serif');
  static String get fontMonospace => _get('等宽体 (Monospace)', 'Monospace');
  static String get fontYaHei => _get('微软雅黑', 'Microsoft YaHei');
  static String get fontSimSun => _get('宋体', 'SimSun');
  static String get fontKaiTi => _get('楷体', 'KaiTi');
  static String get fontSimHei => _get('黑体', 'SimHei');
  static String get fontSourceHanSerif => _get('思源宋体', 'Source Han Serif');
  static String get fontSourceHanSans => _get('思源黑体', 'Source Han Sans');
  static String get fontNotoSerif => _get('Noto 宋体', 'Noto Serif');
  static String get fontManagement => _get('字体管理', 'Font management');
  static String get importFontTooltip =>
      _get('导入 .ttf / .otf 字体', 'Import .ttf / .otf font');
  static String get systemFonts => _get('系统字体', 'System fonts');
  static String get fontPreviewSample =>
      _get('阅读字体预览 Aa 汉', 'Reading font preview Aa 汉');
  static String get videoPlayTitle => _get('视频播放', 'Video');
  static String get videoVolumeNoPlayUrl =>
      _get('当前为卷标题，无播放地址', 'This is a volume title; there is no playback URL');
  static String get videoChapterNoPlayUrl =>
      _get('章节未解析出视频地址', 'No video URL was parsed for this chapter');
  static String get videoPrivateNeedsVerify => _get(
      '私密视频需先在应用内验证，再转入悬浮窗',
      'Verify this private video in the app before moving it to the floating window');
  static String get videoOverlayPermissionHint => _get(
      '请允许「显示在其他应用上层」后重试',
      'Allow "display over other apps" and try again');
  static String get videoReturnToAppHint =>
      _get('请回到应用内后重试', 'Return to the app and try again');
  static String get videoFloatStartFailed =>
      _get('悬浮窗启动失败，请重试', 'Failed to start the floating window; try again');
  static String get videoInvalidUrl => _get('无效的视频地址', 'Invalid video URL');
  static String get videoPlaybackFinished => _get('已播放完', 'Playback finished');
  static String get videoPrevEpisode => _get('上一集', 'Previous episode');
  static String get videoNextEpisode => _get('下一集', 'Next episode');
  static String get videoLoadFailed => _get('视频加载失败', 'Failed to load the video');
  static String get videoLoading => _get('正在加载视频...', 'Loading video...');
  static String get danmakuHide => _get('关弹幕', 'Hide danmaku');
  static String get danmakuShow => _get('开弹幕', 'Show danmaku');
  static String get videoEpisodes => _get('选集', 'Episodes');
  static String get importReplaceRulesTitle =>
      _get('导入替换规则', 'Import replacement rules');
  static String get noReplaceRulesParsed => _get(
      '格式错误，未解析到替换规则', 'Invalid format; no replacement rules were parsed');
  static String get importStatusNew => _get('新增', 'New');
  static String get importStatusUpdate => _get('更新', 'Update');
  static String get importStatusExists => _get('已有', 'Existing');
  static String get importStatusExistsLong => _get('已存在', 'Already exists');
  static String get importTypeAutoDetectHint => _get(
      '导入类型由内容格式自动识别：书源 / RSS 源 / 替换规则 / 主题配置 / HTTP TTS / 字典规则 / TXT 目录规则 / 高亮规则 / 自动任务',
      'The import type is detected from the content format: book sources / RSS sources / replacement rules / theme config / HTTP TTS / dictionary rules / TXT TOC rules / highlight rules / auto tasks');
  static String get rssContentFallbackNotice => _get(
      '正文加载失败，已显示文章自带内容',
      "Failed to load the content; showing the article's own content");
  static String get rssStarred => _get('已收藏', 'Starred');
  static String get rssUnstarred => _get('已取消收藏', 'Unstarred');
  static String get rssStarAction => _get('收藏', 'Star');
  static String get rssUnstar => _get('取消收藏', 'Unstar');
  static String get switchToPlainText => _get('切换为纯文本', 'Switch to plain text');
  static String get switchToWebView => _get('切换为 WebView', 'Switch to WebView');
  static String get rssContentLoading => _get('正在加载正文…', 'Loading content…');
  static String get rssContentLoadFailed =>
      _get('加载正文失败', 'Failed to load the content');
  static String get viewOriginalInBrowser =>
      _get('在浏览器中查看原文', 'View original in browser');
  static String get viewOriginalLink => _get('查看原文链接', 'View original link');
  static String get webViewLoadFailed =>
      _get('WebView 加载失败', 'Failed to load the WebView');
  static String get webViewUnsupportedFallback => _get(
      '当前平台不支持 WebView，已降级为纯文本显示',
      'WebView is not supported on this platform; showing plain text instead');
  static String get invalidArticleLink => _get('无效的文章链接', 'Invalid article link');
  static String get sourceLoginNotConfigured =>
      _get('源未配置登录', 'This source has no login configured');
  static String get noSpecifiedSourceFound =>
      _get('未找到指定源', 'The specified source was not found');
  static String get noReplaceableSourceFound =>
      _get('未找到可替换的书源', 'No replaceable source found');
  static String get enableMoreSourcesAndRetry => _get(
      '请确认已启用足够的书源后重试',
      'Make sure enough sources are enabled and try again');
  static String get noSourcesParsed =>
      _get('格式错误，未解析到书源', 'Invalid format; no sources were parsed');
  static String get scannedNotRecognizableSource => _get(
      '扫码内容不是可识别的书源数据',
      'The scanned content is not recognizable source data');
  static String get sourceGroupAll => _get('源分组：全部', 'Source group: All');
  static String deleteSourceConfirmNamed(String name) =>
      _locale == 'zh' ? '确定要删除书源「$name」吗？' : 'Delete the book source "$name"?';
  static String deleteSelectedSourcesConfirm(int count) => _locale == 'zh'
      ? '确定要删除选中的 $count 个书源吗？'
      : 'Delete the $count selected sources?';
  static String confirmDeleteSourceNamed(String name) =>
      _locale == 'zh' ? '确定删除「$name」吗？' : 'Delete "$name"?';
  static String groupSearchEmptySwitchAll(String group) => _locale == 'zh'
      ? '$group分组搜索结果为空，是否切换到全部分组'
      : 'No search results in the $group group. Switch to all groups?';
  static String get switchSourceTitle => _get('切换书源', 'Switch source');
  static String switchSourceConfirm(String name) => _locale == 'zh'
      ? '确定要将本书切换到「$name」吗？\n切换后将重新获取目录与章节内容。'
      : 'Switch this book to "$name"?\nThe table of contents and chapters will be fetched again.';
  static String switchedToSource(String name) =>
      _locale == 'zh' ? '已切换到「$name」' : 'Switched to "$name"';
  static String changeSourceFailed(String error) =>
      _locale == 'zh' ? '换源失败: $error' : 'Failed to switch the source: $error';
  static String sourceGroupNamed(String group) =>
      _locale == 'zh' ? '源分组：$group' : 'Source group: $group';
  static String rateFailed(String error) =>
      _locale == 'zh' ? '评分失败: $error' : 'Rating failed: $error';
  static String disableFailed(String error) =>
      _locale == 'zh' ? '禁用失败: $error' : 'Failed to disable: $error';
  static String matchedSourcesCount(int count) => _locale == 'zh'
      ? '找到 $count 个匹配书源'
      : 'Found $count matching sources';
  static String latestChapterLabel(String title) =>
      _locale == 'zh' ? '最新：$title' : 'Latest: $title';
  static String respondTimeMs(int ms) =>
      _locale == 'zh' ? '耗时 ${ms}ms' : 'Took ${ms}ms';
  static String sourceCountSuffix(int count) =>
      _locale == 'zh' ? ' $count 个书源' : ' $count sources';
  static String searchingWithWait(String sourceText, int seconds) => _locale == 'zh'
      ? '正在搜索$sourceText… 已等待 $seconds 秒'
      : 'Searching$sourceText… waited $seconds s';
  static String groupAddedToSelectedSources(String group) => _locale == 'zh'
      ? '已为所选书源添加分组「$group」'
      : 'Added group "$group" to the selected sources';
  static String groupRemovedFromSelectedSources(String group) => _locale == 'zh'
      ? '已从所选书源移除分组「$group」'
      : 'Removed group "$group" from the selected sources';
  static String shareSourcesCount(int count) =>
      _locale == 'zh' ? '书源分享（$count 个）' : 'Share book sources ($count)';
  static String get importSourceFromUrlTitle =>
      _get('从 URL 导入书源', 'Import sources from URL');
  static String get importSourceUrlHint =>
      _get('输入书源 URL 地址', 'Enter the source URL');
  static String sourceFetchFailedWithReason(String error) =>
      _locale == 'zh' ? '获取书源失败：$error' : 'Failed to fetch sources: $error';
  static String selectedCountLabel(int count) =>
      _locale == 'zh' ? '已选择 $count 项' : '$count selected';
  static String selectAllCount(int selected, int total) =>
      _locale == 'zh' ? '全选（$selected/$total）' : 'Select all ($selected/$total)';
  static String deselectAllCount(int selected, int total) => _locale == 'zh'
      ? '取消全选（$selected/$total）'
      : 'Deselect all ($selected/$total)';
  static String confirmWithCount(int count) =>
      _locale == 'zh' ? '确认（$count）' : 'Confirm ($count)';
  static String checkingProgress(int done, int total, String name) => _locale == 'zh'
      ? '校验中 $done/$total：$name'
      : 'Checking $done/$total: $name';
  static String checkFinished(int done, int total, int invalid) => _locale == 'zh'
      ? '校验结束：$done/$total，失效 $invalid 个'
      : 'Check finished: $done/$total, $invalid invalid';
  static String bookshelfCountLabel(int count) =>
      _locale == 'zh' ? '书架：$count 本' : 'Bookshelf: $count';
  static String get exploreBadgeOn => _get('标志:发现已启用', 'Flag: discovery on');
  static String get exploreBadgeOff =>
      _get('标志:发现未启用', 'Flag: discovery off');
  static String savedAt(String path) =>
      _locale == 'zh' ? '已保存: $path' : 'Saved: $path';
  static String savedToDocumentsDir(String path) => _locale == 'zh'
      ? '已保存到文档目录: $path'
      : 'Saved to the documents directory: $path';
  static String get saveImageTitle => _get('保存图片', 'Save image');
  static String get imageDataInvalid => _get('图片数据无效', 'Invalid image data');
  static String get imageEmpty => _get('图片为空', 'The image is empty');
  static String saveImageFailed(String error) =>
      _locale == 'zh' ? '保存图片失败：$error' : 'Failed to save the image: $error';
  static String get svgUnsupportedHint => _get(
      '当前平台不支持直接查看 SVG 图片，可点击右上角保存',
      'Viewing SVG images directly is not supported on this platform; use the save button at the top right');
  static String saveSourceVariableFailed(String error) => _locale == 'zh'
      ? '保存源变量失败：$error'
      : 'Failed to save the source variable: $error';
  static String saveLayoutFailed(String error) =>
      _locale == 'zh' ? '布局保存失败：$error' : 'Failed to save the layout: $error';
  static String get clearArticlesConfirm => _get(
      '将清空本源本地缓存的文章列表，确定继续吗？',
      'This clears the locally cached article list of this source. Continue?');
  static String get sourceArticleCacheCleared =>
      _get('本源文章缓存已清空', 'The article cache of this source was cleared');
  static String clearArticlesFailed(String error) =>
      _locale == 'zh' ? '清空失败：$error' : 'Failed to clear: $error';
  static String get recordReadHistory =>
      _get('记录阅读历史', 'Record reading history');
  static String get clearReadRecordsTitle =>
      _get('清空阅读记录', 'Clear reading records');
  static String get clearReadRecordsConfirm => _get(
      '确定清空当前源的全部阅读记录？',
      'Clear all reading records of the current source?');
  static String clearSucceededRefreshFailed(String error) => _locale == 'zh'
      ? '清空成功，但刷新记录失败：$error'
      : 'Cleared successfully, but refreshing the records failed: $error';
  static String get raDeleteEngineTitle => _get('删除朗读引擎', 'Delete engine');
  static String raDeleteEngineConfirm(String name) =>
      _locale == 'zh' ? '确定要删除「$name」吗？' : 'Delete "$name"?';
  static String get raEngineSetForBook =>
      _get('已设为本书引擎', "Set as this book's engine");
  static String get raEngineSetGlobal =>
      _get('已设为全局引擎', 'Set as the global engine');
  static String get raNoEnginesToExport =>
      _get('暂无可导出的朗读引擎', 'No read-aloud engines to export');
  static String get raExportEngines =>
      _get('导出朗读引擎', 'Export read-aloud engines');
  static String get raCannotExportSystemTts =>
      _get('无法导出系统tts', 'Cannot export the system TTS');
  static String get raAddEngine => _get('添加引擎', 'Add engine');
  static String get raNoEngines => _get('暂无朗读引擎', 'No read-aloud engines');
  static String get raNoEnginesHint => _get(
      '点击右下角按钮添加 HTTP TTS 引擎',
      'Tap the button at the bottom right to add an HTTP TTS engine');
  static String get raEditEngineTitle =>
      _get('编辑朗读引擎', 'Edit read-aloud engine');
  static String get raAddEngineTitle =>
      _get('添加朗读引擎', 'Add read-aloud engine');
  static String get raEngineNameLabel => _get('名称 *', 'Name *');
  static String get raEngineNameHint => _get('例如：Edge TTS', 'e.g. Edge TTS');
  static String get raEngineNameRequired => _get('请输入名称', 'Enter a name');
  static String get raEngineUrlLabel => _get('URL *', 'URL *');
  static String get raEngineUrlRequired => _get('请输入 URL', 'Enter a URL');
  static String get raEngineUrlSchemeRequired =>
      _get('URL 必须以 http(s) 开头', 'The URL must start with http(s)');
  static String get raContentTypeHint =>
      _get('可选，例如 audio/mpeg', 'Optional, e.g. audio/mpeg');
  static String get raHeaderLabel =>
      _get('请求头 (JSON)', 'Request headers (JSON)');
  static String get raHeaderHint => _get(
      '可选，例如 {"Authorization":"Bearer xxx"}',
      'Optional, e.g. {"Authorization":"Bearer xxx"}');
  static String get customPageKey => _get('自定义翻页键', 'Custom page-turn keys');
  static String get prevPageKey => _get('上一页按键', 'Page up button');
  static String get nextPageKey => _get('下一页按键', 'Page down button');
  static String get pageKeySetHint =>
      _get('按下要设置的按键（可多个）', 'Press the keys to assign (multiple allowed)');
  static String get readBooksPending => _get('已读 — 本', 'Read — books');
  static String readBooksCount(int count) =>
      _locale == 'zh' ? '已读 $count 本' : '$count books read';
  static String get readTotalPending => _get('累计 —', 'Total —');
  static String readTotalMasked(String total) => _locale == 'zh'
      ? '累计 $total（不含未解锁内容）'
      : 'Total $total (excluding locked content)';
  static String readTotal(String total) =>
      _locale == 'zh' ? '累计 $total' : 'Total $total';
  static String get dayGroupToday => _get('今天', 'Today');
  static String get dayGroupYesterday => _get('昨天', 'Yesterday');
  static String get dayGroupEarlier => _get('更早', 'Earlier');
  static String get readStatsPreparing =>
      _get('正在准备阅读统计…', 'Preparing reading stats…');
  static String get readStatsPrivateMasked => _get(
      '私密书籍未验证，暂不显示每日阅读时长',
      'Private books not verified; daily reading time is hidden');
  static String loadFailedWithReason(String reason) =>
      _locale == 'zh' ? '加载失败：$reason' : 'Failed to load: $reason';
  static String noLogsForLevel(String level) => _locale == 'zh'
      ? '暂无 $level 级别日志'
      : 'No $level level logs';
  static String logsCopiedToClipboard(int length) => _locale == 'zh'
      ? '日志已复制到剪贴板（$length 字符）'
      : 'Logs copied to clipboard ($length characters)';
  static String logCountRatio(int shown, int total) =>
      _locale == 'zh' ? '$shown / $total 条' : '$shown / $total entries';
  static String exceptionWithMessage(String message) =>
      _locale == 'zh' ? '异常: $message' : 'Exception: $message';
  static String syntaxWarning(String message) =>
      _locale == 'zh' ? '语法警告：$message' : 'Syntax warning: $message';
  static String syntaxWarningWithLine(int line, String message) => _locale == 'zh'
      ? '语法警告 L$line：$message'
      : 'Syntax warning at line $line: $message';
  static String syntaxCheckFailed(String error) => _locale == 'zh'
      ? '语法检查失败：$error'
      : 'Syntax check failed: $error';
  static String savedNamed(String name) =>
      _locale == 'zh' ? '已保存：$name' : 'Saved: $name';
  static String jsTemplateLoadFailed(String error) => _locale == 'zh'
      ? '加载已有脚本失败，已回退模板：$error'
      : 'Failed to load the existing script; fell back to the template: $error';
  static String fontFilesMissing(String files) => _locale == 'zh'
      ? '部分自定义字体文件缺失，未加载：$files'
      : 'Some custom font files are missing and were not loaded: $files';
  static String fontImportedNamed(String name) =>
      _locale == 'zh' ? '已导入字体「$name」' : 'Imported font "$name"';
  static String fontUpdatedNamed(String name) =>
      _locale == 'zh' ? '已更新字体「$name」' : 'Updated font "$name"';
  static String fontImportFailedWithReason(String error) =>
      _locale == 'zh' ? '字体导入失败: $error' : 'Font import failed: $error';
  static String currentTitleFont(String label) =>
      _locale == 'zh' ? '当前标题字体：$label' : 'Current title font: $label';
  static String currentFont(String label) =>
      _locale == 'zh' ? '当前字体：$label' : 'Current font: $label';
  static String pageLoadFailedWithReason(String reason) => _locale == 'zh'
      ? '页面加载失败：$reason'
      : 'Failed to load the page: $reason';
  static String pageLoadFailedHttp(int status) => _locale == 'zh'
      ? '页面加载失败：HTTP $status'
      : 'Failed to load the page: HTTP $status';
  static String cannotOpenUrl(String url) =>
      _locale == 'zh' ? '无法打开: $url' : 'Unable to open: $url';
  static String snippetCopied(String name) => _locale == 'zh'
      ? '已复制「$name」脚本，粘贴到浏览器控制台执行'
      : 'Copied the "$name" script; paste it into the browser console to run';
  static String bookAlreadyInShelf(String name) =>
      _locale == 'zh' ? '《$name》已在书架' : '"$name" is already in the bookshelf';
  static String addedToBookshelfNamed(String name) =>
      _locale == 'zh' ? '已加入书架：《$name》' : 'Added to bookshelf: "$name"';
  static String noMatchingSourceWithUrl(String url) => _locale == 'zh'
      ? '未找到匹配书源：$url'
      : 'No matching source found: $url';
  static String rssStarActionFailed(String error) => _locale == 'zh'
      ? '收藏操作失败：$error'
      : 'Star action failed: $error';
  static String raEngineListLoadFailed(String error) => _locale == 'zh'
      ? '加载朗读引擎失败: $error'
      : 'Failed to load read-aloud engines: $error';
  static String get selectedSourcesEnabled =>
      _get('已启用所选书源', 'Selected sources enabled');
  static String get selectedSourcesDisabled =>
      _get('已禁用所选书源', 'Selected sources disabled');
  static String get selectedSourcesExploreEnabled =>
      _get('已启用所选书源发现', 'Discovery enabled for the selected sources');
  static String get selectedSourcesExploreDisabled =>
      _get('已禁用所选书源发现', 'Discovery disabled for the selected sources');
  static String get selectedSourcesPinnedTop =>
      _get('已置顶所选书源', 'Selected sources moved to the top');
  static String get selectedSourcesPinnedBottom =>
      _get('已置底所选书源', 'Selected sources moved to the bottom');
  static String get selectedSourcesDeleted =>
      _get('已删除所选书源', 'Selected sources deleted');
  static String get noRemovableGroupForSelectedSources => _get(
      '所选书源没有可移除的分组', 'The selected sources have no removable group');

  // ─── L10N 批 2 组 A：阅读器配置 / 主题 / 设置页 ───
  static String get enableAutoPageTurn => _get('启用自动翻页', 'Enable auto page turn');
  static String get pageTurnDirection => _get('翻页方向', 'Direction');
  static String get nineGridZonesHint =>
      _get('9 个区域（3×3 九宫格）', '9 zones (3x3 grid)');
  static String get pageKeysNotSet =>
      _get('未设置（仅 Android 生效）', 'Not set (Android only)');
  static String get keyLongPressPageTurn =>
      _get('按键长按翻页', 'Press and hold a key to turn page');
  static String get keyLongPressPageTurnHint => _get(
      '关闭时长按不连续翻页，且 600 毫秒内只翻一页',
      'When off, holding a key does not turn pages continuously and only one page turns per 600 ms');
  static String get selectionMenuLabel => _get('选择菜单', 'Selection menu');
  static String get selectionMenuHint => _get(
      '一级 / 折叠 / 隐藏项、多行展示与图标',
      'Primary / collapsed / hidden items, multiline display and icons');
  static String get swipeDownAddBookmark =>
      _get('下滑添加书签', 'Swipe down to add bookmark');
  static String get swipeDownAddBookmarkHint => _get(
      '分页模式在正文向下拖动 80dp 后松手',
      'In paged mode, drag down 80dp in the content and release');
  static String get bookmarkBadgeSize => _get('角标大小', 'Badge size');
  static String get bookmarkBadge => _get('书签角标', 'Bookmark badge');
  static String get customImage => _get('自定义图片', 'Custom image');
  static String get selectLabel => _get('选择', 'Select');
  static String get changeLabel => _get('更换', 'Change');
  static String get resetBookmarkBadge =>
      _get('恢复默认书签角标', 'Reset bookmark badge');
  static String get vibrateSlider =>
      _get('滑动进度条时震动', 'Vibrate while sliding the progress bar');
  static String get vibrateSelectText =>
      _get('选择文本时震动', 'Vibrate when selecting text');
  static String get pickBookmarkBadgeImage =>
      _get('选择书签角标图片', 'Select bookmark badge image');
  static String get paragraphSpacing => _get('段落间距', 'Paragraph spacing');
  static String get typography => _get('字体与排版', 'Font and typography');
  static String get readingFont => _get('阅读字体', 'Reading font');
  static String get letterSpacingShort => _get('字距', 'Letter spacing');
  static String get topBarButtonsHint => _get(
      '选择、排序阅读器顶栏动作（最多 6 个，可恢复默认）',
      'Choose and reorder top bar actions (up to 6; defaults can be restored)');
  static String get moreConfig => _get('更多配置', 'More settings');
  static String get convertNone => _get('不转换', 'None');
  static String get textJustify => _get('两端对齐', 'Justify');
  static String get textJustifyHint => _get(
      '正文行尾对齐（末行除外）', 'Align line ends (except the last line)');
  static String get screenOrientationLabel => _get('屏幕方向', 'Screen orientation');
  static String get orientationAutoSensor => _get('自动(传感器)', 'Auto (sensor)');
  static String get orientationPortraitReverse =>
      _get('反向竖屏', 'Reverse portrait');
  static String get orientationLandscapeReverse =>
      _get('反向横屏', 'Reverse landscape');
  static String get keepScreenAwake => _get('保持亮屏', 'Keep screen on');
  static String get minutes1 => _get('1 分钟', '1 min');
  static String get minutes5 => _get('5 分钟', '5 min');
  static String get minutes10 => _get('10 分钟', '10 min');
  static String get keepAlways => _get('常亮', 'Always on');
  static String get hideStatusBarLabel => _get('隐藏状态栏', 'Hide status bar');
  static String get hideStatusBarHint =>
      _get('阅读时隐藏系统状态栏', 'Hide the system status bar while reading');
  static String get hideNavigationBarLabel =>
      _get('隐藏导航栏', 'Hide navigation bar');
  static String get hideNavigationBarHint => _get(
      '阅读时隐藏系统导航栏', 'Hide the system navigation bar while reading');
  static String get progressBarBehaviorLabel =>
      _get('进度条行为', 'Progress bar behavior');
  static String get progressBarPage => _get('调章内页', 'Adjust page in chapter');
  static String get progressBarChapter => _get('调章节', 'Adjust chapter');
  static String get autoChangeSourceLabel => _get('自动换源', 'Auto change source');
  static String get autoChangeSourceHint => _get(
      '章节加载失败时自动切换书源',
      'Switch to another source when a chapter fails to load');
  static String get selectTextLongPressLabel =>
      _get('长按选择文本', 'Long press to select text');
  static String get selectTextLongPressHint => _get(
      '长按正文段落弹出选择面板',
      'Long press a paragraph to open the selection panel');
  static String get noAnimScrollPageLabel =>
      _get('滚动翻页无动画', 'No animation when scrolling');
  static String get noAnimScrollPageHint => _get(
      '点击/自动翻页直接切换不带动画',
      'Tap and auto page turns switch instantly without animation');
  static String get clickImageActionLabel => _get('点击图片方式', 'Image tap action');
  static String get showTitleAdditionLabel =>
      _get('显示标题附加区', 'Show title addition');
  static String get showTitleAdditionHint => _get(
      '顶栏书名后显示当前章名', 'Show the current chapter name after the title');
  static String get toolbarFollowPageLabel =>
      _get('工具栏跟随页面', 'Toolbars follow the page');
  static String get toolbarFollowPageHint => _get(
      '顶/底栏配色跟随阅读页背景',
      'Top and bottom bars follow the reading page colors');
  static String get extendToCutoutLabel => _get('扩展到刘海', 'Extend to cutout');
  static String get extendToCutoutHint => _get(
      '正文延伸到刘海区域（仅 Android 生效）',
      'Extend the content into the cutout area (Android only)');
  static String get fillDisplayCutoutLabel =>
      _get('填充刘海区域', 'Fill display cutout');
  static String get fillDisplayCutoutHint => _get(
      '页面边距避开刘海区域（仅 Android 生效）',
      'Keep page margins clear of the cutout area (Android only)');
  static String get dualPageHorizontalLabel =>
      _get('平板/横屏双页', 'Tablet/Landscape dual page');
  static String get dualPageGlobalSingle =>
      _get('全局单页', 'Single page everywhere');
  static String get dualPageGlobalDouble => _get('全局双页', 'Dual page everywhere');
  static String get dualPageLandscapeDouble =>
      _get('横屏双页', 'Dual page in landscape');
  static String get useZhLayoutLabel =>
      _get('使用自定义中文分行', 'Custom Chinese line breaks');
  static String get useZhLayoutHint => _get(
      '开启后启用中文避头尾与更优断行',
      'Enable Chinese line-breaking rules and better wrapping');
  static String get hangingPunctuationLabel =>
      _get('段首标点悬挂', 'Hanging punctuation');
  static String get hangingPunctuationHint => _get(
      '段首引号等标点悬挂于缩进内，使正文首字与其他段落对齐',
      'Hang leading punctuation inside the indent so the first character aligns with other paragraphs');
  static String get mouseWheelPageLabel =>
      _get('鼠标滚轮翻页', 'Mouse wheel to turn page');
  static String get mouseWheelPageHint => _get(
      '分页模式下滚轮上下滚动翻页',
      'Scroll the wheel to turn pages in paged mode');
  static String get volumeKeyPageOnPlayLabel =>
      _get('朗读时音量键翻页', 'Volume keys to turn page while reading aloud');
  static String get pageTouchSlopLabel =>
      _get('滑动翻页阈值', 'Sliding page threshold');
  static String get pageTouchSlopDialogTitle => _get(
      '滑动翻页阈值（0 = 系统默认值）',
      'Sliding page turn threshold (0 = system default)');
  static String get edgeClickThresholdLabel =>
      _get('边缘点击阈值', 'Edge tap threshold');
  static String get brightnessControlSection =>
      _get('亮度控制', 'Brightness control');
  static String get brightnessUnsupported => _get(
      '此设备不支持亮度调节', 'This device does not support brightness control');
  static String get autoBrightnessHint =>
      _get('根据环境光自动调节', 'Adjust automatically to ambient light');
  static String get dualPageSingle => _get('单页', 'Single page');
  static String get dualPageDouble => _get('双页', 'Dual page');
  static String get progressBarPageAdjust =>
      _get('调整本章页数', 'Adjust the page within the chapter');
  static String get progressBarChapterAdjust =>
      _get('调整章节位置', 'Adjust the chapter position');
  static String get newTheme => _get('新建主题', 'New theme');
  static String get themeSaveAsHint => _get(
      '以当前阅读样式另存为', 'Save the current reading style as a new theme');
  static String get renameFailed => _get('重命名失败', 'Rename failed');
  static String get deleteTheme => _get('删除主题', 'Delete theme');
  static String get restoreDefaultTheme =>
      _get('恢复默认主题', 'Restore default theme');
  static String get restoreDefaultThemeConfirm => _get(
      '将删除全部自建主题，并把阅读样式恢复为内置「预设1」，是否继续？',
      'All custom themes will be deleted and the reading style reset to the built-in "Preset 1". Continue?');
  static String get readFileFailed => _get('读取文件失败', 'Failed to read the file');
  static String get clipboardNoThemeJson =>
      _get('剪贴板没有主题 JSON', 'No theme JSON in the clipboard');
  static String get applyingTheme => _get('正在应用主题…', 'Applying the theme...');
  static String get builtInTheme => _get('内置主题', 'Built-in theme');
  static String get customThemeLabel => _get('自建主题', 'Custom theme');
  static String get exportJson => _get('导出 JSON', 'Export JSON');
  static String get shareJson => _get('分享 JSON', 'Share JSON');
  static String get switchToList => _get('切换为列表', 'Switch to list');
  static String get switchToGrid => _get('切换为网格', 'Switch to grid');
  static String get gridColumnsLabel => _get('网格列数', 'Grid columns');
  static String get manageThemes => _get('管理主题', 'Manage themes');
  static String get importFromFile => _get('从文件导入', 'Import from file');
  static String get importFromClipboard =>
      _get('从剪贴板导入', 'Import from clipboard');
  static String get noMatchingTheme => _get('没有匹配的主题', 'No matching themes');
  static String get clearSearch => _get('清除搜索', 'Clear search');
  static String get locateCurrent => _get('定位当前', 'Locate current');
  static String get backToTop => _get('回到顶部', 'Back to top');
  static String get backToBottom => _get('回到底部', 'Back to bottom');
  static String get screenSection => _get('屏幕', 'Screen');
  static String get pageControl => _get('页面控制', 'Page control');
  static String get notEnabled => _get('未启用', 'Not enabled');
  static String get brightnessBarMode => _get('亮度条模式', 'Brightness bar mode');
  static String get textFullJustifyLabel => _get('文字两端对齐', 'Text justified');
  static String get noAnimScrollClick =>
      _get('禁用滚动点击动画', 'Disable scroll click animation');
  static String get showTitleAdditionArea =>
      _get('展示顶部工具栏附加区域', 'Show top toolbar addition area');
  static String get disableReturnKey => _get('禁用返回键', 'Disable return key');
  static String get maxLengthNoToc =>
      _get('无目录时每章字数', 'Characters per chapter without a catalog');
  static String get maxLengthNoTocHint => _get(
      '对本地 TXT 无目录规则分章生效；对新导入/重新解析生效',
      'Applies to local TXT files split without catalog rules; takes effect for newly imported or re-parsed books');
  static String get onlyWifi => _get('仅 WiFi', 'Wi-Fi only');
  static String get onlyWifiHint =>
      _get('仅在 WiFi 下加载网络封面', 'Load network covers only on Wi-Fi');
  static String get coverRuleHint => _get(
      '进入详情页时使用封面规则重新获取封面',
      'Use the cover rule to fetch the cover when opening details');
  static String get alwaysUseDefaultCover =>
      _get('总是使用默认封面', 'Always use the default cover');
  static String get alwaysUseDefaultCoverHint => _get(
      '总是显示默认封面（不显示网络封面）',
      'Always show the default cover (no network cover)');
  static String get defaultCover => _get('默认封面', 'Default cover');
  static String get builtInCover => _get('应用内置封面', 'Built-in default cover');
  static String get showFontShadow => _get('显示字体阴影', 'Show font shadow');
  static String get showFontStroke => _get('显示字体描边', 'Show font stroke');
  static String get useDefaultFontColor =>
      _get('使用默认字体颜色', 'Use the default font color');
  static String get useDefaultFontColorHint => _get(
      '使用主题次要色绘制书名与作者',
      'Draw the title and author with the theme secondary color');
  static String get restrictCoverRatio =>
      _get('限制封面比例', 'Restrict cover ratio');
  static String get restrictCoverRatioHint => _get(
      '开启时封面固定 5:7 显示；关闭后搜索、发现与书籍详情页封面按原图宽高比自适应',
      'When on, covers are fixed at 5:7; when off, covers in search, discovery and book details follow the original aspect ratio');
  static String get networkBookBadge => _get('网络书籍角标', 'Network book badge');
  static String get networkBookBadgeSetting =>
      _get('网络书籍角标设置', 'Network book badge settings');
  static String get notImplementedYet =>
      _get('另立项，暂不生效', 'Planned separately; not active yet');
  static String get showAllLabel => _get('全部显示', 'Show all');
  static String get dayLabel => _get('白天', 'Day');
  static String get coverTextColorDay => _get('正文颜色（白天）', 'Text color (day)');
  static String get shadowLabel => _get('阴影', 'Shadow');
  static String get shadowColorDay =>
      _get('阴影颜色（白天）', 'Shadow color (day)');
  static String get showNameLabel => _get('显示书名', 'Show name');
  static String get showNameHint =>
      _get('封面上显示书名', 'Show the book title on the cover');
  static String get showAuthorLabel => _get('显示作者', 'Show author');
  static String get showAuthorHint =>
      _get('封面上显示作者', 'Show the author on the cover');
  static String get coverTextColorNight =>
      _get('正文颜色（夜间）', 'Text color (night)');
  static String get shadowColorNight =>
      _get('阴影颜色（夜间）', 'Shadow color (night)');
  static String get coverInfoOrientation =>
      _get('封面信息方向', 'Cover info orientation');
  static String get coverOrientationPortrait => _get('竖向', 'Portrait');
  static String get coverOrientationLandscape => _get('横向', 'Landscape');
  static String get sortAndSettings => _get('排序与设置', 'Sort and settings');
  static String get sortByNameLabel => _get('按书名排序', 'Sort by title');
  static String get sortByReadTime => _get('按阅读时长', 'By reading time');
  static String get sortByLastRead => _get('按最后阅读', 'By last read');
  static String get enableReadRecord =>
      _get('启用阅读记录', 'Enable reading records');
  static String get byBook => _get('按书', 'By book');
  static String get byDay => _get('按天', 'By day');
  static String get loadingReadRecords =>
      _get('加载阅读记录...', 'Loading reading records...');
  static String get noMatchingRecords =>
      _get('未找到匹配的记录', 'No matching records');
  static String get readingHeatmap => _get('阅读热力图', 'Reading heatmap');
  static String get heatmapSubtitle =>
      _get('近一年每日阅读情况', 'Daily reading over the past year');
  static String get privateBookUnlockFirst => _get(
      '该书为私密内容，请先在书架解锁后再打开',
      'This book is private. Unlock it on the bookshelf first.');
  static String get deleteAllAuthorsRecordsConfirm => _get(
      '将删除本书全部作者的阅读记录，确定吗？',
      'All reading records for this book (every author) will be deleted. Continue?');
  static String get clearAllRecordsConfirm =>
      _get('确定删除全部阅读记录吗？', 'Delete all reading records?');
  static String get readRecordDeleted =>
      _get('已删除阅读记录', 'Reading record deleted');
  static String get durationZero => _get('0秒', '0s');
  static String get byDurationLabel => _get('按时长', 'By duration');
  static String get byCount => _get('按本数', 'By books');
  static String get contributors => _get('开发人员', 'Contributors');
  static String get contributorsSummary => _get(
      'gedoor、Invinciblelee 和 Xwite 等，详情请在 GitHub 中查看',
      'gedoor, Invinciblelee, Xwite and others. See GitHub for details.');
  static String get updateLog => _get('更新日志', "What's new");
  static String get versionPlaceholder => _get('版本 …', 'Version ...');
  static String get checkUpdate => _get('检查更新', 'Check for updates');
  static String get crashLog => _get('崩溃日志', 'Crash log');
  static String get saveLogs => _get('保存日志', 'Save logs');
  static String get createHeapDump => _get('创建堆转储', 'Create heap dump');
  static String get privacyPolicy =>
      _get('用户隐私与协议', 'User privacy and agreement');
  static String get licenseLabel => _get('开源许可', 'License');
  static String get disclaimer => _get('免责声明', 'Disclaimer');
  static String get updateLogPlaceholder => _get(
      '更新日志正文尚未打包进 Flutter 资产（对标 Android assets/updateLog.md）。\n请前往 GitHub Releases 查看完整变更说明。',
      'The changelog is not bundled in the Flutter assets yet (matches Android assets/updateLog.md).\nSee GitHub Releases for the full changelog.');
  static String get disclaimerPlaceholder => _get(
      '免责声明正文尚未打包进 Flutter 资产（对标 Android assets/disclaimer.md）。\n本软件为开源阅读工具，使用者须遵守当地法律法规与网站服务条款。',
      'The disclaimer is not bundled in the Flutter assets yet (matches Android assets/disclaimer.md).\nThis is an open-source reading tool; users must follow local laws and each website\'s terms of service.');
  static String get logRecordingDisabled => _get(
      '未开启日志记录，请去其他设置里打开记录日志',
      'Log recording is off. Turn it on in Other settings first.');
  static String get heapDumpRecordingDisabled => _get(
      '未开启堆转储记录，请去其他设置里打开记录堆转储',
      'Heap dump recording is off. Turn it on in Other settings first.');
  static String get creatingHeapDump =>
      _get('开始创建堆转储', 'Creating heap dump...');
  static String get heapDumpFile => _get('堆转储文件', 'Heap dump file');
  static String get heapDumpShareText =>
      _get('应用堆转储（诊断用）', 'App heap dump (for diagnostics)');
  static String get heapDumpUnsupported => _get(
      '当前平台不支持创建堆转储', 'Heap dumps are not supported on this platform');
  static String get labelModeSelected => _get('选中时显示', 'Show when selected');
  static String get labelModeAlways => _get('常驻', 'Always');
  static String get defaultHomePageLabel => _get('默认主页', 'Default home page');
  static String get defaultHomePageHint => _get(
      '启动应用时优先打开的页签（仅显示可见项）',
      'Tab opened first at launch (visible tabs only)');
  static String get bottomBarLabels => _get('底栏文字', 'Bottom bar labels');
  static String get navLabelMode =>
      _get('导航栏标签显示方式', 'Navigation bar label mode');
  static String get navBarIcons => _get('导航栏图标', 'Navigation bar icons');
  static String get usingDefaultIcons =>
      _get('使用默认图标', 'Using default icons');
  static String get navItems => _get('导航项', 'Navigation items');
  static String get navItemsHint => _get(
      '拖动左侧把手调整顺序；开关控制首页/发现/订阅是否显示；书架与我的始终显示。',
      'Drag the handle on the left to reorder. Switches control whether Home, Discover and RSS are shown; Bookshelf and My are always shown.');
  static String get alwaysVisible => _get('始终显示', 'Always visible');
  static String get resetNavConfirmTitle =>
      _get('恢复默认导航设置？', 'Restore the default navigation settings?');
  static String get resetNavConfirmBody => _get(
      '将重置导航项显隐、顺序、默认首页、底栏文字和自定义图标。',
      'Navigation visibility, order, default home page, bottom bar labels and custom icons will be reset.');
  static String get navResetDone =>
      _get('已恢复默认导航设置', 'Default navigation settings restored');
  static String get navIconsHint => _get(
      '可为每个页签分别选择未选中/选中图标；留空使用内置图标。',
      'Pick an unselected and a selected icon per tab; leave empty to use the built-in icons.');
  static String get unselectedLabel => _get('未选中', 'Unselected');
  static String get selectedLabel => _get('选中', 'Selected');
  static String get replaceIcon => _get('替换图标', 'Replace icon');
  static String get deleteIcon => _get('删除图标', 'Delete icon');
  static String get pickNavIcon => _get('选择导航图标', 'Select navigation icon');
  static String get navIconUnsupported => _get(
      '当前平台不支持自定义导航图标',
      'Custom navigation icons are not supported on this platform');
  static String get navIconSaveFailed =>
      _get('图标保存失败，请重试', 'Failed to save the icon. Please try again.');
  static String get pickWelcomeBackground =>
      _get('选择欢迎页背景', 'Select the welcome page background');
  static String get welcomePageStyle => _get('欢迎页样式', 'Welcome page style');
  static String get displayDuration => _get('显示时长', 'Display duration');
  static String get splashDurationHint => _get(
      '设为 0 则跳过闪屏直接进入主页', 'Set to 0 to skip the splash and go straight home');
  static String get customWelcomeLabel =>
      _get('自定义欢迎页', 'Customize the welcome page');
  static String get customWelcomeHint => _get(
      '启用后可设置日/夜背景图', 'When enabled, day and night backgrounds can be set');
  static String get showWelcomeText => _get('显示文字', 'Display text');
  static String get welcomeSlogan => _get(
      '阅读 / 享受美好时光 / 品读万千故事',
      'Read / Enjoy the moment / Discover countless stories');
  static String get showIconLabel => _get('显示图标', 'Show icon');
  static String get defaultBookIcon => _get('默认书本图标', 'Default book icon');
  static String get welcomeFooterHint => _get(
      '闪屏结构对齐原版 WelcomeActivity；背景图仅在开启「自定义欢迎页」时生效。',
      'The splash matches the original WelcomeActivity; backgrounds apply only when "Customize the welcome page" is on.');
  static String get importRssSources => _get('导入订阅源', 'Import RSS sources');
  static String get searchContentTitle => _get('搜索内容', 'Search content');
  static String get searchOptions => _get('搜索选项', 'Search options');
  static String get replaceAction => _get('替换', 'Replace');
  static String get scopeCurrentChapter => _get('仅当前章', 'Current chapter only');
  static String get scopeCachedBook => _get('仅本书（已缓存）', 'This book (cached)');
  static String get scopeBookNetwork => _get('本书 + 网络', 'This book + network');
  static String get thisBookOnly => _get('仅本书', 'This book only');
  static String get resultsTruncated => _get('（已截断）', '(truncated)');
  static String get searchContentEmptyHint =>
      _get('输入关键词开始搜索正文', 'Enter a keyword to search the content');
  static String get searchHistoryByBookUnsupported => _get(
      '按书搜索历史待后续版本支持',
      'Per-book search history is not supported yet');
  static String get remoteImport => _get('远程导入', 'Remote import');
  static String get scanningFiles => _get('扫描文件...', 'Scanning files...');
  static String get noImportableBooks =>
      _get('当前目录没有可导入的书籍', 'No importable books in this folder');
  static String get noImportableBooksHint => _get(
      '切换格式过滤或返回上级目录', 'Change the format filter or go up one level');
  static String get selectStorageDir =>
      _get('选择存储目录', 'Select a storage folder');
  static String get noBooksSelected => _get('未选择书籍', 'No books selected');
  static String get fileActions => _get('文件操作', 'File actions');
  static String get fileManageFilterHint =>
      _get('筛选 · 文件管理', 'Filter · File manager');
  static String get loadingFiles => _get('加载文件...', 'Loading files...');
  static String get currentDirEmpty => _get('当前目录为空', 'This folder is empty');
  static String get unknownSourceLabel => _get('未知来源', 'Unknown source');
  static String get rssFavorites => _get('RSS 收藏', 'RSS Favorites');
  static String get loadingFavorites => _get('加载收藏...', 'Loading favorites...');
  static String get noFavoriteArticles =>
      _get('暂无收藏文章', 'No favorite articles yet');
  static String get noFavoriteArticlesHint => _get(
      '浏览 RSS 文章时点亮星标即可收藏',
      'Tap the star while browsing RSS articles to save them');
  static String get untitledLabel => _get('（无标题）', '(Untitled)');
  static String get rssSourceDebug => _get('RSS 源调试', 'RSS source debug');
  static String get rssSourceUrlLabel => _get('RSS 源 URL', 'RSS source URL');
  static String get rssSourceUrlDebugHint =>
      _get('输入要调试的 RSS 源地址', 'Enter the RSS source URL to debug');
  static String get runningLabel => _get('运行中', 'Running');
  static String get debugTapToStart =>
      _get('点击「调试」开始执行', 'Tap "Debug" to start');
  static String get debugNoLogsForFilter =>
      _get('当前过滤条件下无日志', 'No logs match the current filters');
  static String get aiChatUnsupported =>
      _get('AI 聊天暂未支持', 'AI chat is not supported yet');
  static String get aiChatComingSoon => _get(
      '待 Rust 能力接入后开放', 'Coming once the Rust capability is available');
  static String get debugErrorNoUrl =>
      _get('错误：请先输入 RSS 源地址', 'Error: enter the RSS source URL first');
  static String get debugStartHeader =>
      _get('=== 开始调试 RSS 源 ===', '=== Starting RSS source debug ===');
  static String get debugQueryingSources => _get(
      '[1/2] 正在查询已注册的 RSS 源...', '[1/2] Looking up registered RSS sources...');
  static String get debugSourceNotRegistered => _get(
      '未在书架注册该 RSS 源，将直接按 URL 抓取',
      'This RSS source is not registered on the bookshelf; fetching directly by URL');
  static String get debugFetchingArticles =>
      _get('[2/2] 正在抓取文章列表...', '[2/2] Fetching the article list...');
  static String get debugNoArticles => _get(
      '未获取到文章（可能需要配置规则或源不可达）',
      'No articles fetched (a rule may be missing or the source is unreachable)');
  static String get debugDoneHeader =>
      _get('=== 调试完成 ===', '=== Debug finished ===');

  // ─── L10N 批 2 组 A：参数化文案 ───
  static String autoPageTurnIntervalLabel(String seconds) =>
      _locale == 'zh' ? '间隔 $seconds 秒' : 'Interval: ${seconds}s';
  static String pageKeysSummary(String prev, String next) =>
      _locale == 'zh' ? '上一页 $prev / 下一页 $next' : 'Previous $prev / Next $next';
  static String bookmarkBadgeSaveFailed(String error) => _locale == 'zh'
      ? '书签角标图保存失败：$error'
      : 'Failed to save the bookmark badge image: $error';
  static String chineseConvertFailed(String error) => _locale == 'zh'
      ? '简繁转换设置失败: $error'
      : 'Failed to set Chinese conversion: $error';
  static String themeAppliedQuote(String name) =>
      _locale == 'zh' ? '已应用「$name」' : 'Applied "$name"';
  static String applyThemeFailed(String error) =>
      _locale == 'zh' ? '应用主题失败：$error' : 'Failed to apply the theme: $error';
  static String themeDefaultName(int index) =>
      _locale == 'zh' ? '主题$index' : 'Theme $index';
  static String themeCreated(String name) =>
      _locale == 'zh' ? '已新建「$name」' : 'Created "$name"';
  static String themeRenamed(String name) =>
      _locale == 'zh' ? '已重命名为「$name」' : 'Renamed to "$name"';
  static String deleteThemesConfirm(int count) => _locale == 'zh'
      ? '确定删除选中的 $count 个主题？内置主题不受影响。'
      : 'Delete the $count selected themes? Built-in themes are not affected.';
  static String themesDeleted(int count) =>
      _locale == 'zh' ? '已删除 $count 个主题' : 'Deleted $count themes';
  static String themeDefaultsRestored(String name) => _locale == 'zh'
      ? '已恢复默认主题，阅读样式已应用「$name」'
      : 'Default theme restored; reading style set to "$name"';
  static String themesImported(int count) =>
      _locale == 'zh' ? '已导入 $count 个主题' : 'Imported $count themes';
  static String themeExported(String name) =>
      _locale == 'zh' ? '已导出「$name」' : 'Exported "$name"';
  static String searchThemeHint(int count) => _locale == 'zh'
      ? '搜索主题（共 $count 个）'
      : 'Search themes ($count total)';
  static String themesSelected(int count) =>
      _locale == 'zh' ? '已选 $count' : '$count selected';
  static String coverAlbumSummary(String name, int light, int dark) =>
      _locale == 'zh'
      ? '$name · 日间 $light · 夜间 $dark'
      : '$name · Day $light · Night $dark';
  static String deleteNamedAllAuthorsRecordsConfirm(String name) => _locale == 'zh'
      ? '将删除「$name」该书全部作者的阅读记录，确定吗？'
      : 'All reading records for "$name" (every author) will be deleted. Continue?';
  static String durationDays(int days) =>
      _locale == 'zh' ? '$days天' : '${days}d';
  static String durationHours(int hours) =>
      _locale == 'zh' ? '$hours小时' : '${hours}h';
  static String durationMinutes(int minutes) =>
      _locale == 'zh' ? '$minutes分钟' : '${minutes}m';
  static String durationSeconds(int seconds) =>
      _locale == 'zh' ? '$seconds秒' : '${seconds}s';
  static String lastReadAt(String text) =>
      _locale == 'zh' ? '最后阅读：$text' : 'Last read: $text';
  static String readingDuration(String text) =>
      _locale == 'zh' ? '阅读时长：$text' : 'Reading time: $text';
  static String dailyDurationLoadFailed(String error) => _locale == 'zh'
      ? '每日时长加载失败：$error'
      : 'Failed to load daily reading time: $error';
  static String versionLabel(String version) =>
      _locale == 'zh' ? '版本 $version' : 'Version $version';
  static String latestVersion(String version) => _locale == 'zh'
      ? '当前已是最新版本 v$version'
      : 'You are on the latest version v$version';
  static String versionIgnoredNamed(String tag) =>
      _locale == 'zh' ? '已忽略版本 $tag' : 'Version $tag is ignored';
  static String checkUpdateError(String error) =>
      _locale == 'zh' ? '检查更新\n$error' : 'Check for updates\n$error';
  static String logsExported(String path) =>
      _locale == 'zh' ? '日志已导出：$path' : 'Logs exported: $path';
  static String saveLogFailed(String error) =>
      _locale == 'zh' ? '保存日志失败：$error' : 'Failed to save the logs: $error';
  static String heapDumpCreated(String path) =>
      _locale == 'zh' ? '堆转储已生成：$path' : 'Heap dump created: $path';
  static String heapDumpFailed(String error) => _locale == 'zh'
      ? '创建堆转储失败：$error'
      : 'Failed to create the heap dump: $error';
  static String navIconsCustomized(int count) =>
      _locale == 'zh' ? '已自定义 $count 个图标' : '$count custom icons';
  static String splashDurationMs(int ms) =>
      _locale == 'zh' ? '启动闪屏停留 $ms 毫秒' : 'Splash stays for $ms ms';
  static String scanningChapters(int done, int total) => _locale == 'zh'
      ? '扫描章节 $done / $total ...'
      : 'Scanning chapters $done / $total ...';
  static String noContentMatches(String query) =>
      _locale == 'zh' ? '未找到「$query」相关内容' : 'No content matches "$query"';
  static String matchesFound(int count) =>
      _locale == 'zh' ? '共 $count 处匹配' : '$count matches';
  static String addToShelfCount(int count) =>
      _locale == 'zh' ? '放入书架 ($count)' : 'Add to bookshelf ($count)';
  static String importingProgress(int done, int total) =>
      _locale == 'zh' ? '正在导入 $done / $total ...' : 'Importing $done / $total ...';
  static String cannotOpenFile(String error) =>
      _locale == 'zh' ? '无法打开文件: $error' : 'Unable to open the file: $error';
  static String deleteFileConfirm(String name) => _locale == 'zh'
      ? '确定删除「$name」吗？此操作不可恢复。'
      : 'Delete "$name"? This cannot be undone.';
  static String fileDeleteFailed(String error) =>
      _locale == 'zh' ? '删除失败: $error' : 'Delete failed: $error';
  static String debugSourceUrlEcho(String url) =>
      _locale == 'zh' ? '源地址: $url' : 'Source URL: $url';
  static String debugSourceNameEcho(String name) =>
      _locale == 'zh' ? '源名称: $name' : 'Source name: $name';
  static String debugFetchedArticles(int count) =>
      _locale == 'zh' ? '抓取完成，共 $count 篇文章' : 'Fetch complete: $count articles';
  static String debugLinkLine(String url) =>
      _locale == 'zh' ? '      链接: $url' : '      Link: $url';
  static String debugMoreOmitted(int count) =>
      _locale == 'zh' ? '  ...（其余 $count 篇省略）' : '  ...($count more omitted)';
  static String debugException(String error) =>
      _locale == 'zh' ? '异常: $error' : 'Exception: $error';
  static String get importSkipLabel => _get('跳过', 'Skipped');

  // ============== L10N 批 2 组 C：定时任务 / 替换规则 / 听书 / 规则订阅 /
  // TXT 目录规则 / 远程书籍 / 漫画阅读 / 分组 / 代码编辑 / 订阅 / 首页 /
  // 书签 / 书籍信息编辑 / 底栏图标分配 / 书源登录 / 封面相册 / 设置占位 ==============

  // ----- 通用补充 -----
  static String get unknownLabel => _get('未知', 'Unknown');
  static String get nameLabel => _get('名称', 'Name');
  static String get typeLabel => _get('类型', 'Type');
  static String get backLabel => _get('返回', 'Back');
  static String get addAction => _get('添加', 'Add');
  static String get createAction => _get('创建', 'Create');
  static String get stopAction => _get('停止', 'Stop');
  static String get hoursUnit => _get('小时', 'hours');
  static String get unnamedParen => _get('(未命名)', '(Untitled)');
  static String get commaJoinSeparator => _locale == 'zh' ? '，' : ', ';
  static String get semicolonJoinSeparator => _locale == 'zh' ? '；' : '; ';
  static String chapterNumberLabel(int index) =>
      _locale == 'zh' ? '第 $index 章' : 'Chapter $index';

  // ----- 设置占位页（settings_placeholder_screen） -----
  static String notSupportedNamed(String title) =>
      _locale == 'zh' ? '$title暂未支持' : '$title is not supported yet';
  static String get aiSettingsUnavailableDesc => _get(
      '待 Rust AI 能力接入后开放',
      'Available once Rust AI capabilities are integrated');
  static String get translationSettingsUnavailableDesc => _get(
      '待 Rust 翻译能力接入后开放',
      'Available once Rust translation capabilities are integrated');
  static String get labSettingsUnavailableDesc => _get(
      '待后续实验能力接入后开放',
      'Available once experimental features are integrated');

  // ----- 封面相册选择（cover_album_select_sheet） -----
  static String get coverAlbumSelectTitle =>
      _get('选择封面相册', 'Select cover album');
  static String get manageAlbums => _get('管理相册', 'Manage albums');
  static String get builtinCoverAlbum =>
      _get('应用内置封面', 'Built-in default cover');
  static String get builtinCoverAlbumDesc =>
      _get('使用应用内置默认封面', 'Use the app built-in default cover');
  static String coverAlbumDayNightCount(int day, int night) => _locale == 'zh'
      ? '日间 $day · 夜间 $night'
      : 'Day $day · Night $night';

  // ----- 定时任务（auto_task_screen） -----
  static String get autoTaskEditUnavailable => _get(
      '暂时无法编辑该任务，请稍后重试',
      'This task cannot be edited right now. Please try again later');
  static String get autoTaskNotFound =>
      _get('未找到对应的定时任务', 'Scheduled task not found');
  static String autoTaskCreated(String name) =>
      _locale == 'zh' ? '已创建任务: $name' : 'Task created: $name';
  static String autoTaskUpdated(String name) =>
      _locale == 'zh' ? '已更新任务: $name' : 'Task updated: $name';
  static String get autoTaskImportLocal =>
      _get('导入本地任务', 'Import local tasks');
  static String get autoTaskImportOnline =>
      _get('导入线上任务', 'Import online tasks');
  static String get autoTaskExportTasks => _get('导出任务', 'Export tasks');
  static String get autoTasksEmpty => _get('暂无定时任务', 'No scheduled tasks');
  static String get autoTasksEmptyHint => _get(
      '点击右下角按钮添加新任务', 'Tap the button in the bottom right to add a task');
  static String autoTaskLastRun(String time, String result) =>
      _locale == 'zh' ? '上次运行: $time · $result' : 'Last run: $time · $result';
  static String get autoTaskAddTitle => _get('添加定时任务', 'Add scheduled task');
  static String get autoTaskEditTitle =>
      _get('编辑定时任务', 'Edit scheduled task');
  static String get taskNameLabel => _get('任务名称', 'Task name');
  static String get taskNameHint => _get('例如：每日刷新', 'e.g. Daily refresh');
  static String get taskTypeLabel => _get('任务类型', 'Task type');
  static String get taskTypeRefreshToc => _get('刷新目录', 'Refresh TOC');
  static String get taskTypeUpdateSources => _get('更新书源', 'Update sources');
  static String get cronLabel => _get('Cron 表达式', 'Cron expression');
  static String get cronHelper => _get('标准5位 cron 表达式（分 时 日 月 周）',
      'Standard 5-field cron expression (minute hour day month weekday)');
  static String autoTaskAdded(String name) =>
      _locale == 'zh' ? '已添加任务: $name' : 'Task added: $name';
  static String get autoTaskRunNow => _get('立即运行', 'Run now');
  static String autoTaskRunning(String name) =>
      _locale == 'zh' ? '正在运行: $name' : 'Running: $name';
  static String get autoTaskDebugDesc =>
      _get('执行并查看结果日志', 'Run and view the result log');
  static String get autoTaskEditTask => _get('编辑任务', 'Edit task');
  static String get autoTaskDeleteTask => _get('删除任务', 'Delete task');
  static String get localFileLabel => _get('本地文件', 'Local file');
  static String get onlineLabel => _get('线上', 'Online');
  static String readFileFailedWith(String error) => _locale == 'zh'
      ? '读取文件失败: $error'
      : 'Failed to read the file: $error';
  static String get autoTaskFetchingConfig =>
      _get('正在获取任务配置…', 'Fetching task configuration…');
  static String downloadFailedHttp(int code) =>
      _locale == 'zh' ? '下载失败: HTTP $code' : 'Download failed: HTTP $code';
  static String downloadFailedWith(String error) =>
      _locale == 'zh' ? '下载失败: $error' : 'Download failed: $error';
  static String get importFailedJsonInvalid =>
      _get('导入失败：JSON 格式无效', 'Import failed: invalid JSON');
  static String get importFailedNoTaskData =>
      _get('导入失败：未找到任务数据', 'Import failed: no task data found');
  static String get importFailedTaskDataInvalid =>
      _get('导入失败：任务数据无效', 'Import failed: invalid task data');
  static String importFailedWithDetails(String details) => _locale == 'zh'
      ? '导入失败：$details'
      : 'Import failed: $details';
  static String get autoTaskMissingName =>
      _get('缺少任务名称', 'Missing task name');
  static String autoTaskInvalidCron(String name) => _locale == 'zh'
      ? '「$name」请输入有效的五段 Cron 计划'
      : '"$name": enter a valid 5-field cron schedule';
  static String autoTaskMissingScript(String name) => _locale == 'zh'
      ? '「$name」请输入 JavaScript 任务脚本'
      : '"$name": enter a JavaScript task script';
  static String get autoTaskImportTitle => _get('导入任务', 'Import tasks');
  static String autoTaskImportConfirm(String source, int count) => _locale == 'zh'
      ? '从$source发现 $count 个任务，是否导入？'
      : 'Found $count task(s) from $source. Import them?';
  static String get autoTaskNoTasksToExport =>
      _get('暂无任务可导出', 'No tasks to export');
  static String get autoTaskExportSubject =>
      _get('导出定时任务', 'Export scheduled tasks');
  static String autoTaskConfirmDeleteNamed(String name) => _locale == 'zh'
      ? '确定要删除任务「$name」吗？'
      : 'Delete the task "$name"?';
  static String autoTaskDeleted(String name) =>
      _locale == 'zh' ? '已删除任务: $name' : 'Task deleted: $name';
  static String get cronInvalidFormat => _get(
      'Cron 表达式无效，请检查格式', 'Invalid cron expression. Check the format.');
  static String get editBookUpdateTask =>
      _get('编辑书籍更新任务', 'Edit book update task');
  static String get autoTaskBookUpdateDesc => _get(
      '到期后自动刷新该书目录并提示更新',
      'Refreshes this book TOC when due and notifies about updates');
  static String get autoTaskUnnamed => _get('未命名任务', 'Unnamed task');
  static String get autoTaskWriteFailed => _get('写入失败', 'Write failed');
  static String get autoTaskNoneImported =>
      _get('未导入任何任务', 'No tasks imported');
  static String autoTaskImportedCount(int count) =>
      _locale == 'zh' ? '已导入 $count 个任务' : 'Imported $count task(s)';
  static String autoTaskSkippedInvalid(int count) => _locale == 'zh'
      ? '跳过 $count 个无效任务'
      : 'Skipped $count invalid task(s)';
  static String autoTaskWriteFailures(int count, String first, String more) =>
      _locale == 'zh'
          ? '$count 个写入失败：$first$more'
          : '$count failed to save: $first$more';
  static String autoTaskWriteFailuresMore(int count) =>
      _locale == 'zh' ? '（另有 $count 个）' : ' ($count more)';
  static String autoTaskLabeledReason(String label, String reason) =>
      _locale == 'zh' ? '$label：$reason' : '$label: $reason';

  // ----- 替换规则（replace_rules_screen） -----
  static String get replaceRuleGroupFilter => _get('分组筛选', 'Filter by group');
  static String get replaceRuleUngrouped => _get('无分组', 'Ungrouped');
  static String get batchActions => _get('批量操作', 'Batch actions');
  static String get replaceRuleEmptyAddHint =>
      _get('点击右上角 + 添加规则', 'Tap + in the top right to add a rule');
  static String replaceRuleNoMatch(String filter) => _locale == 'zh'
      ? '未找到匹配「$filter」的规则'
      : 'No rules match "$filter"';
  static String get replaceRuleSubsetReorderHint => _get(
      '筛选/搜索状态下暂不支持拖拽排序',
      'Drag reordering is not available while filtering or searching');
  static String get sortSaveFailedNoReason =>
      _get('排序保存失败', 'Failed to save the order');
  static String get replaceRuleExportSubject =>
      _get('导出替换规则', 'Export replacement rules');
  static String get replaceRuleQrInvalid => _get(
      '扫码内容不是可识别的替换规则数据',
      'The scanned content is not recognizable replacement rule data');
  static String replaceRuleFetchFailedHttp(int code) => _locale == 'zh'
      ? '获取替换规则失败：HTTP $code'
      : 'Failed to fetch replacement rules: HTTP $code';
  static String replaceRuleFetchFailed(String error) => _locale == 'zh'
      ? '获取替换规则失败：$error'
      : 'Failed to fetch replacement rules: $error';
  static String get replaceRuleParseFailed => _get(
      '格式错误，未解析到替换规则', 'Invalid format: no replacement rules found');
  static String replaceRuleImportedCount(int count) => _locale == 'zh'
      ? '导入完成（$count 条）'
      : 'Import complete ($count items)';
  static String replaceRuleConfirmDeleteNamed(String name) =>
      _locale == 'zh' ? '确定删除「$name」吗？' : 'Delete "$name"?';
  static String get replaceRuleDeleted => _get('规则已删除', 'Rule deleted');
  static String get dragToReorder => _get('拖动排序', 'Drag to reorder');
  static String replaceRulePatternSummary(
    String type,
    String pattern,
    String replacement,
  ) => _locale == 'zh'
      ? '$type: $pattern → $replacement'
      : '$type: $pattern → $replacement';
  static String replaceRuleScopeLabel(String scope) =>
      _locale == 'zh' ? '范围: $scope' : 'Scope: $scope';
  static String get replaceRuleImportUrlTitle =>
      _get('从 URL 导入替换规则', 'Import replacement rules from URL');
  static String get replaceRuleImportUrlHint =>
      _get('输入替换规则 URL 地址', 'Enter the replacement rules URL');

  // ----- 听书（audio_screen） -----
  static String get ttsSystemNoEngine =>
      _get('系统 TTS（未检测到可用引擎）', 'System TTS (no engine available)');
  static String ttsEnginePartialFailed(String label) => _locale == 'zh'
      ? '$label（部分引擎加载失败）'
      : '$label (some engines failed to load)';
  static String get ttsEngineLoadFailedRetry => _get(
      '朗读引擎加载失败，点击重试', 'Failed to load speech engines. Tap to retry');
  static String get ttsNoEngineAvailable =>
      _get('未检测到可用语音引擎', 'No speech engine available');
  static String get raSystemDefaultEngineDesc => _get(
      '跟随系统「文字转语音」设置', 'Follows the system text-to-speech settings');
  static String get ttsHttpEngineSection => _get('HTTP 引擎', 'HTTP engines');
  static String raEngineSwitchedTo(String name) =>
      _locale == 'zh' ? '已切换朗读引擎：$name' : 'Switched speech engine: $name';
  static String raSystemEngineSwitchedTo(String name) => _locale == 'zh'
      ? '已切换系统引擎：$name'
      : 'Switched to the system engine: $name';
  static String get audioCopyPlayUrl =>
      _get('复制播放地址', 'Copy playback URL');
  static String get audioCacheRangeTitle =>
      _get('缓存章节范围', 'Cache chapter range');
  static String get audioClearChapterCache =>
      _get('清除本章缓存', 'Clear this chapter cache');
  static String get audioWakeLock => _get('唤醒锁定', 'Wake lock');
  static String get audioSkipCredits => _get('跳过片头片尾', 'Skip intro/outro');
  static String get audioTimerStopSet =>
      _get('定时停止（已设置）', 'Sleep timer (set)');
  static String audioStopByChapters(int remaining) => _locale == 'zh'
      ? '按章停止 剩余 $remaining 章'
      : 'Stop after chapters: $remaining left';
  static String audioStopIn(String countdown) =>
      _locale == 'zh' ? '定时停止 $countdown' : 'Sleep timer $countdown';
  static String get audioStopAfterChapter =>
      _get('定时停止 读完本章后停止', 'Sleep timer: stop after this chapter');
  static String get audioCacheTitle => _get('音频缓存', 'Audio cache');
  static String audioCacheProgress(
    String name,
    int done,
    int total,
    int failed,
  ) => _locale == 'zh'
      ? '《$name》已缓存 $done/$total，失败 $failed'
      : '"$name" cached $done/$total, $failed failed';
  static String get audioBookLabel => _get('音频书', 'Audiobook');
  static String get audioReadAloudSettingsDesc => _get(
      '引擎/音色/语速与朗读行为', 'Engine, voice, speed and read-aloud behavior');
  static String get audioBackgroundEnabled => _get(
      '后台播放已启用，支持媒体按钮控制',
      'Background playback is on; media buttons are supported');
  static String get audioBackgroundSupported => _get(
      '支持后台播放，切换应用后音频将继续播放',
      'Background playback is supported; audio keeps playing when you switch apps');
  static String get audioPlayModeSequential =>
      _get('顺序播放', 'Sequence play');
  static String get audioPlayModeSingleLoop =>
      _get('单曲循环', 'Loop single');
  static String get audioPlayModeShuffle => _get('随机播放', 'Random play');
  static String get audioNoSourceCannotLogin => _get(
      '本书无关联书源，无法登录', 'This book has no linked source; cannot log in');
  static String get audioSourceNotFound =>
      _get('未找到当前书源', 'Current source not found');
  static String get audioCannotGetPlayUrl =>
      _get('无法获取播放地址', 'Unable to get the playback URL');
  static String get audioNoPlayUrlForChapter =>
      _get('当前章节无播放地址', 'This chapter has no playback URL');
  static String get audioPlayUrlCopied =>
      _get('播放地址已复制', 'Playback URL copied');
  static String get audioNoLinkedSource =>
      _get('本书无关联书源', 'This book has no linked source');
  static String get chapterUnit => _get('章', 'Chapter');
  static String get audioRangeTo => _get('至', 'to');
  static String get errorScopeInput =>
      _get('请输入正确的范围', 'Please enter a valid range');
  static String get audioCacheTaskRunning =>
      _get('已有缓存任务在运行', 'A cache task is already running');
  static String get audioCacheQueued =>
      _get('已加入音频缓存队列', 'Added to the audio cache queue');
  static String get audioChapterCacheCleared =>
      _get('已清除本章缓存', 'This chapter cache cleared');
  static String get audioChapterNoCache =>
      _get('本章没有缓存', 'This chapter has no cache');
  static String audioIntroSeconds(int seconds) =>
      _locale == 'zh' ? '片头 $seconds 秒' : 'Intro $seconds s';
  static String audioOutroSeconds(int seconds) =>
      _locale == 'zh' ? '片尾 $seconds 秒' : 'Outro $seconds s';
  static String get audioCreditsSaved =>
      _get('已保存片头片尾设置', 'Intro/outro settings saved');

  // ----- 规则订阅（rule_sub_screen） -----
  static String get ruleSubAdd => _get('新增订阅', 'Add subscription');
  static String get ruleSubLoading =>
      _get('加载订阅...', 'Loading subscriptions...');
  static String get ruleSubEmpty => _get('暂无订阅', 'No subscriptions');
  static String get ruleSubEmptyHint => _get(
      '点击右上角「新增订阅」添加书源/订阅源/替换规则订阅',
      'Tap "Add subscription" in the top right to add a book source, RSS source or replacement rule subscription');
  static String get ruleSubCheckUpdate => _get('检查更新', 'Check for updates');
  static String get ruleSubApplyUpdate => _get('应用更新', 'Apply update');
  static String ruleSubCheckUpdateFailed(String error) => _locale == 'zh'
      ? '检查更新失败：$error'
      : 'Failed to check for updates: $error';
  static String ruleSubNewVersion(String version) =>
      _locale == 'zh' ? '发现新版本：$version' : 'New version found: $version';
  static String get ruleSubNewVersionNoNumber =>
      _get('发现新版本', 'New version found');
  static String get ruleSubUpToDate => _get('已是最新版本', 'Already up to date');
  static String ruleSubApplyUpdateFailed(String error) => _locale == 'zh'
      ? '应用更新失败：$error'
      : 'Failed to apply the update: $error';
  static String ruleSubUpdateDone(
    String added,
    String updated,
    String removed,
  ) => _locale == 'zh'
      ? '更新完成：新增 $added、更新 $updated、移除 $removed'
      : 'Update complete: $added added, $updated updated, $removed removed';
  static String get ruleSubDeleteTitle => _get('删除订阅', 'Delete subscription');
  static String ruleSubConfirmDeleteNamed(String name) => _locale == 'zh'
      ? '确定要删除订阅「$name」吗？'
      : 'Delete the subscription "$name"?';
  static String ruleSubUrlExists(String name) =>
      _locale == 'zh' ? 'URL 已存在（$name）' : 'URL already exists ($name)';
  static String ruleSubUnknownType(String type) =>
      _locale == 'zh' ? '未知订阅类型：$type' : 'Unknown subscription type: $type';
  static String ruleSubFetchBookSourcesFailed(String error) => _locale == 'zh'
      ? '获取书源失败：$error'
      : 'Failed to fetch book sources: $error';
  static String get ruleSubParseNoBookSource =>
      _get('格式错误，未解析到书源', 'Invalid format: no book sources found');
  static String get ruleSubImportDone => _get('导入完成', 'Import complete');
  static String ruleSubFetchRssFailed(String error) => _locale == 'zh'
      ? '获取订阅源失败：$error'
      : 'Failed to fetch RSS sources: $error';
  static String get ruleSubParseNoRss =>
      _get('格式错误，未解析到订阅源', 'Invalid format: no RSS sources found');
  static String ruleSubFetchReplaceFailed(String error) => _locale == 'zh'
      ? '获取替换规则失败：$error'
      : 'Failed to fetch replacement rules: $error';
  static String get ruleSubParseNoReplace => _get(
      '格式错误，未解析到替换规则', 'Invalid format: no replacement rules found');
  static String ruleSubImportedReplace(int count) => _locale == 'zh'
      ? '已导入 $count 条替换规则'
      : 'Imported $count replacement rule(s)';
  static String get ruleSubUrlRequired =>
      _get('URL 不能为空', 'URL cannot be empty');
  static String get ruleSubSilentUpdate => _get('静默更新', 'Silent update');
  static String get ruleSubUpdateInterval =>
      _get('更新间隔', 'Update interval');

  // ----- TXT 目录规则（txt_toc_rules_screen） -----
  static String get txtTocRulesEmpty => _get('暂无目录规则', 'No TOC rules');
  static String get txtTocRulesEmptyHint => _get(
      '点击右下角 + 添加识别章节标题的正则规则',
      'Tap + in the bottom right to add a regex rule that detects chapter titles');
  static String get txtTocExportRules => _get('导出规则', 'Export rules');
  static String get txtTocNoRulesToExport =>
      _get('暂无可导出的目录规则', 'No TOC rules to export');
  static String get txtTocExportSubject =>
      _get('导出目录规则', 'Export TOC rules');
  static String txtTocImportedDefault(int count) => _locale == 'zh'
      ? '已导入 $count 条原版默认 TXT 目录规则'
      : 'Imported $count default TXT TOC rules';
  static String txtTocConfirmDeleteNamed(String name) =>
      _locale == 'zh' ? '确定删除「$name」吗？' : 'Delete "$name"?';
  static String get editRule => _get('编辑规则', 'Edit rule');
  static String get regexPattern => _get('正则表达式', 'Regex pattern');
  static String get txtTocReplaceWith =>
      _get('替换为（可选）', 'Replace with (optional)');
  static String get txtTocExampleText =>
      _get('示例文本（可选）', 'Sample text (optional)');
  static String get rulePatternRequired =>
      _get('正则表达式不能为空', 'The regex pattern cannot be empty');
  static String txtTocTestTitle(String name) =>
      _locale == 'zh' ? '测试规则：$name' : 'Test rule: $name';
  static String get txtTocMatchText => _get('待匹配文本', 'Text to match');
  static String txtTocMatchResults(int count) =>
      _locale == 'zh' ? '匹配结果（$count）' : 'Matches ($count)';
  static String txtTocRegexError(String error) =>
      _locale == 'zh' ? '正则错误：$error' : 'Regex error: $error';
  static String get txtTocNoMatches => _get('无匹配项', 'No matches');
  static String txtTocRegexPrefix(String pattern) =>
      _locale == 'zh' ? '正则:$pattern' : 'Regex: $pattern';

  // ----- 远程书籍（remote_book_screen） -----
  static String get sortByTime => _get('按时间', 'By time');
  static String get defaultWebdavSettings =>
      _get('默认 WebDAV 设置', 'Default WebDAV settings');
  static String get backToParent => _get('返回上级', 'Back to parent folder');
  static String get remoteBookFilterHint =>
      _get('筛选 • 远程书籍', 'Filter • remote books');
  static String get remoteBookNoFiles => _get('没有文件', 'No files');
  static String get remoteBookImporting => _get('导入中…', 'Importing…');
  static String addToBookshelfCount(int count) =>
      _locale == 'zh' ? '加入书架 ($count)' : 'Add to Bookshelf ($count)';
  static String get remoteBookDefaultServerDesc => _get(
      '使用备份设置中的 WebDAV（books/）',
      'Use the WebDAV from backup settings (books/)');
  static String get remoteBookServerInvalid =>
      _get('配置无效（请编辑修复）', 'Invalid configuration (edit to fix)');
  static String get remoteBookConfirmDeleteServer =>
      _get('确认删除该服务器？', 'Delete this server?');
  static String get remoteBookNameUrlRequired =>
      _get('名称和地址不能为空', 'Name and URL cannot be empty');
  static String get remoteBookAddServer => _get('添加服务器', 'Add server');
  static String get remoteBookEditServer => _get('编辑服务器', 'Edit server');

  // ----- 漫画阅读（reader_comic_screen） -----
  static String get comicBookNotFound =>
      _get('未找到书籍信息', 'Book information not found');
  static String get comicNoImagesInContent =>
      _get('正文没有图片', 'No images in the content');
  static String get comicNoImageData =>
      _get('无法获取图片数据', 'Unable to get the image data');
  static String imageSavedTo(String path) =>
      _locale == 'zh' ? '已保存: $path' : 'Saved: $path';
  static String imageSavedToDocuments(String path) => _locale == 'zh'
      ? '已保存到文档目录: $path'
      : 'Saved to documents: $path';
  static String imageSaveFailed(String error) => _locale == 'zh'
      ? '保存图片失败: $error'
      : 'Failed to save the image: $error';
  static String get comicImageShareSubject => _get('漫画图片', 'Manga image');
  static String shareImageFailed(String error) =>
      _locale == 'zh' ? '分享失败: $error' : 'Share failed: $error';
  static String get comicImageLinkCopied =>
      _get('已复制图片链接', 'Image link copied');
  static String get copyFailedShort => _get('复制失败', 'Copy failed');
  static String get comicLoading => _get('加载漫画中...', 'Loading manga...');
  static String get comicReadingTitle => _get('漫画阅读', 'Manga reading');
  static String comicPageCount(int page, int total) =>
      _locale == 'zh' ? '页数 $page/$total' : 'Page $page/$total';

  // ----- 分组管理（book_group_screen） -----
  static String get editGroup => _get('编辑分组', 'Edit group');
  static String get newGroup => _get('新建分组', 'New group');
  static String get groupCoverUrlHint =>
      _get('封面图片 URL（可选）', 'Cover image URL (optional)');
  static String get setAsPrivateGroup =>
      _get('设为隐私分组', 'Set as private group');
  static String get groupPrivateHint => _get(
      '组内书籍在公开书架中隐藏，进入分组需验证',
      'Books in this group are hidden from the public shelf; opening the group requires verification');
  static String get disablePrivateGroup =>
      _get('关闭私密分组', 'Turn off private group');
  static String get disablePrivateGroupHint => _get(
      '关闭后，本组书籍可能在公开书架中显示',
      'Once off, books in this group may appear on the public shelf');
  static String groupConfirmDeletePrivate(String name) => _locale == 'zh'
      ? '确定要删除分组「$name」吗？组内非私密书籍将回到公开书架。'
      : 'Delete the group "$name"? Non-private books will return to the public shelf.';
  static String groupConfirmDelete(String name) => _locale == 'zh'
      ? '确定要删除分组「$name」吗？分组内的书籍不会被删除。'
      : 'Delete the group "$name"? Books in the group will not be deleted.';
  static String groupUpdateFailed(String error) =>
      _locale == 'zh' ? '更新失败：$error' : 'Update failed: $error';
  static String groupReorderFailed(String error) =>
      _locale == 'zh' ? '排序失败：$error' : 'Failed to sort: $error';
  static String get sortMethod => _get('排序方式', 'Sort by');
  static String get groupSortByOrder => _get('按排序值', 'By order value');
  static String get groupSortByBookCount => _get('按书籍数量', 'By book count');
  static String get groupLoading => _get('加载分组...', 'Loading groups...');
  static String get groupEmpty => _get('还没有分组', 'No groups yet');
  static String get groupEmptyHint => _get(
      '点击右下角按钮创建第一个分组',
      'Tap the button in the bottom right to create your first group');
  static String groupBookCount(int count) =>
      _locale == 'zh' ? '$count 本书' : '$count book(s)';
  static String get groupShowOnShelf => _get('在书架显示', 'Shown on bookshelf');
  static String get groupHideOnShelf =>
      _get('在书架隐藏', 'Hidden from bookshelf');
  static String get assignBooks => _get('分配书籍', 'Assign books');
  static String get bookshelfEmptyNoBooks =>
      _get('书架暂无书籍', 'No books on the bookshelf');
  static String groupAssignTitle(String name) =>
      _locale == 'zh' ? '分配书籍到「$name」' : 'Assign books to "$name"';
  static String groupAssignHiddenHint(int count) => _locale == 'zh'
      ? '已隐藏 $count 本私密书籍'
      : '$count private book(s) hidden';
  static String groupAssignUpdated(String name) =>
      _locale == 'zh' ? '已更新「$name」的书籍' : 'Updated the books in "$name"';
  static String groupAssignFailed(String error) =>
      _locale == 'zh' ? '分配失败：$error' : 'Assignment failed: $error';

  // ----- 代码编辑（code_edit_screen） -----
  static String get codeEditUnsavedConfirm =>
      _get('内容尚未保存，确定退出？', 'Unsaved changes. Exit anyway?');
  static String get codeEditNotFound => _get('未找到', 'Not found');
  static String get codeEditCopiedAll => _get('已复制全部', 'Copied all');
  static String get codeEditFind => _get('查找', 'Find');
  static String get codeEditCurlConvert => _get('cURL 转换', 'cURL convert');
  static String get codeEditCopyAll => _get('复制全部', 'Copy all');
  static String get codeEditFindHint => _get('查找…', 'Find…');
  static String get codeEditNext => _get('下一个', 'Next');

  // ----- 订阅页（rss_screen） -----
  static String get rssDeleteRssSource => _get('删除 RSS 源', 'Delete RSS source');
  static String get rssFavoritesLabel => _get('收藏', 'Favorites');
  static String get rssFeedManagement =>
      _get('订阅源管理', 'RSS Feed Management');
  static String get rssLoadingRssSources =>
      _get('加载 RSS 源...', 'Loading RSS sources...');
  static String get rssNoSourcesNow =>
      _get('当前没有订阅源！', 'No RSS sources yet!');
  static String get rssNoSourcesInGroup =>
      _get('当前分组暂无订阅源', 'No RSS sources in this group');
  static String rssCannotOpenLink(String url) =>
      _locale == 'zh' ? '无法打开链接：$url' : 'Unable to open the link: $url';
  static String get rssConfirmClearAllRecords =>
      _get('确定清空全部阅读记录？', 'Clear all reading records?');
  static String get rssRecordReadHistory =>
      _get('记录阅读历史', 'Record reading history');
  static String get rssNoReadingRecords =>
      _get('暂无阅读记录', 'No reading records');
  static String get rssUntitled => _get('(无标题)', '(Untitled)');

  // ----- 首页（home_tab_screen） -----
  static String get homeTodayGoal =>
      _get('今日阅读目标', "Today's Reading Goal");
  static String homeMinutesValue(int minutes) =>
      _locale == 'zh' ? '$minutes 分钟' : '$minutes min';
  static String get homeTabTitle => _get('首页', 'Home');
  static String get homeTotalReadBooks => _get('累计阅读', 'Books Read');
  static String get homeTotalReadingTime => _get('阅读时长', 'Reading Time');
  static String homeBooksCount(int count) =>
      _locale == 'zh' ? '$count 本' : '$count book(s)';
  static String get homeBooksPlaceholder => _get('— 本', '— books');
  static String get homeHoursPlaceholder => _get('— 小时', '— hours');
  static String homeHoursValue(String hours) =>
      _locale == 'zh' ? '$hours 小时' : '$hours h';
  static String get homeMinutesUnit => _get('分钟', 'min');
  static String get homePrivateHiddenHint =>
      _get('内容已隐藏，解锁后查看', 'Content hidden. Unlock to view.');
  static String get homePrivateUnlockFirst => _get(
      '该书为私密内容，请先在书架解锁后再打开',
      'This book is private. Unlock it on the bookshelf first.');
  static String get homeBookNotOnShelf =>
      _get('书籍已不在书架中', 'The book is no longer on the bookshelf');
  static String get homeOpenFailedRetry =>
      _get('打开失败，请稍后重试', 'Failed to open. Please try again later.');
  static String get homeEditGoal => _get('编辑目标', 'Edit goal');

  // ----- 书签（bookmark_screen） -----
  static String get bookmarkDeleteTitle => _get('删除书签', 'Delete bookmark');
  static String get bookmarkConfirmDeleteLocked =>
      _get('确定删除本书的书签吗？', 'Delete this bookmark from the book?');
  static String bookmarkConfirmDeleteNamed(String chapter) => _locale == 'zh'
      ? '确定删除「$chapter」的书签吗？'
      : 'Delete the bookmark for "$chapter"?';
  static String get bookmarkDeleted => _get('书签已删除', 'Bookmark deleted');
  static String get bookmarkSearchTitle => _get('搜索书签', 'Search bookmarks');
  static String get bookmarkSearchHint =>
      _get('输入关键词搜索书签', 'Enter a keyword to search bookmarks');

  // ----- 书籍信息编辑（edit_book_info_screen） -----
  static String get bookInfoEditTitle =>
      _get('书籍信息编辑', 'Edit book information');
  static String get bookNameRequired =>
      _get('书名不能为空', 'The book title cannot be empty');
  static String get coverUrlLabel => _get('封面地址', 'Cover URL');
  static String get coverUrlHint =>
      _get('输入封面图片 URL', 'Enter the cover image URL');
  static String get bookIntroLabel => _get('简介', 'Description');
  static String get bookInfoEditHint =>
      _get('修改后点击保存生效', 'Changes take effect after saving');
  static String get bookInfoSaved =>
      _get('书籍信息已保存', 'Book information saved');
  static String bookInfoSaveFailed(String error) =>
      _locale == 'zh' ? '保存失败: $error' : 'Save failed: $error';

  // ----- 底栏图标分配（bottom_bar_skin_assign_screen） -----
  static String get skinStagingNoImages =>
      _get('暂存中无可用图片', 'No images available in staging');
  static String get skinSelectAtLeastOneSelected => _get(
      '请至少为一项选择「选中」图标',
      'Choose a "selected" icon for at least one item');
  static String get skinAssignIconTitle => _get('分配图标', 'Assign icons');
  static String get skinAlbumNameHint => _get('图集名称', 'Album name');
  static String get skinSlotsSection => _get('槽位', 'Slots');
  static String get skinSlotSelected => _get('选中', 'Selected');
  static String get skinSlotNormal => _get('未选', 'Normal');
  static String get skinAssignFooter => _get(
      '点选缩略图从压缩包图片中分配。每个底栏项至少需要「选中」图；「未选」可空（运行时用选中图半透明近似）。',
      'Tap a thumbnail to assign an image from the archive. Each bottom bar item needs at least a "selected" image; "normal" may be empty (the selected image is shown semi-transparent at runtime).');

  // ----- 书源登录（source_login_screen） -----
  static String get sourceLoginNoUrl =>
      _get('该书源未配置登录链接', 'This source has no login URL configured');
  static String get sourceLoginInvalidUrl =>
      _get('登录链接无效', 'Invalid login URL');
  static String get sourceLoginCannotOpenUrl =>
      _get('无法打开登录链接', 'Unable to open the login URL');
  static String get sourceLoginCookieNameRequired =>
      _get('Cookie 名称不能为空', 'The cookie name cannot be empty');
  static String get sourceLoginHeaderNameRequired =>
      _get('Header 名称不能为空', 'The header name cannot be empty');
  static String get sourceLoginSaved =>
      _get('登录信息已保存', 'Login information saved');
  static String get sourceLoginSaveFailedRetry =>
      _get('保存失败，请重试', 'Failed to save. Please try again.');
  static String sourceLoginTitle(String name) =>
      _locale == 'zh' ? '登录 - $name' : 'Login - $name';
  static String get sourceLoginManualTab => _get('手动输入', 'Manual input');
  static String get sourceLoginUrlTab => _get('登录链接', 'Login URL');
  static String get sourceLoginSave =>
      _get('保存登录信息', 'Save login information');
  static String get sourceLoginTokenOptional =>
      _get('Token（可选）', 'Token (optional)');
  static String get sourceLoginHeadersOptional =>
      _get('Headers（可选）', 'Headers (optional)');
  static String get sourceLoginUrlTabHint => _get(
      '在浏览器完成登录后，复制 Cookie 并切换到「手动输入」标签页粘贴。',
      'After logging in via the browser, copy the cookie and switch to the "Manual input" tab to paste it.');

  // ----- 分享文本 / 深链导入（deep_link_service） -----
  static String get shareTooLargeTitle =>
      _get('分享内容过大', 'Shared content too large');
  static String shareTooLargeMessage(int mib) => _locale == 'zh'
      ? '分享内容超过 $mib MiB，无法解析导入，请改用文件导入。'
      : 'The shared content exceeds $mib MiB and cannot be parsed for import. Use file import instead.';
  static String get shareJsonTooDeepTitle =>
      _get('JSON 层级过深', 'JSON nesting too deep');
  static String shareJsonTooDeepMessage(int depth) => _locale == 'zh'
      ? '分享的 JSON 嵌套超过 $depth 层，无法安全解析，请确认来源后重试。'
      : 'The shared JSON is nested deeper than $depth levels and cannot be parsed safely. Check the source and try again.';
  static String get shareUnsupportedTitle =>
      _get('不支持的内容', 'Unsupported content');
  static String get shareUnsupportedMessage => _get(
      '分享内容不是分享口令、http(s) 链接、legado:// 导入链接或可导入的 JSON。',
      'The shared content is not a share passphrase, an http(s) link, a legado:// import link, or importable JSON.');
  static String get unsupportedFileTitle => _get('提醒', 'Notice');
  static String unsupportedFileContinue(String name) => _locale == 'zh'
      ? '文件 $name 不受支持，是否继续打开？'
      : 'Continue to open although $name is not supported?';
  static String get importAnyway => _get('仍然导入', 'Import anyway');
  static String importBookFailed(String error) =>
      _locale == 'zh' ? '导入书籍失败：$error' : 'Failed to import the book: $error';
  static String get importNotReady =>
      _get('导入功能未就绪，请稍后重试', 'Import is not ready yet. Please try again later.');
  static String get importLocalBookTitle =>
      _get('导入本地书籍', 'Import local book');
  static String get importLocalBookConfirm =>
      _get('是否导入该书并加入书架？', 'Import this book and add it to the bookshelf?');

  // ----- 平台桥（platform_bridge_service） -----
  static String get ttsCacheCleared =>
      _get('已清除朗读缓存', 'Read-aloud cache cleared');
  static String invalidLinkWith(String url) =>
      _locale == 'zh' ? '无效的链接：$url' : 'Invalid link: $url';
  static String cannotOpenUrlWith(String url) =>
      _locale == 'zh' ? '无法打开：$url' : 'Unable to open: $url';
  static String get videoPrivateVerifyBeforePlay => _get(
      '私密视频需先在应用内验证后再播放',
      'Verify this private video in the app before playing');

  // ----- 私密闸门页标题（routes） -----
  static String get privateComicTitle => _get('私密漫画', 'Private comic');
  static String get privateComicDesc =>
      _get('验证后继续阅读本漫画', 'Verify to continue reading this comic');
  static String get privateAudioTitle => _get('私密音频', 'Private audio');
  static String get privateAudioDesc =>
      _get('验证后继续收听本书', 'Verify to continue listening to this book');
  static String get verifyAndListen => _get('验证并收听', 'Verify and listen');
  static String get privateVideoTitle => _get('私密视频', 'Private video');
  static String get privateVideoDesc =>
      _get('验证后继续播放本视频', 'Verify to continue playing this video');
  static String get verifyAndPlay => _get('验证并播放', 'Verify and play');

  // ----- 书源登录提示（source_login_prompt） -----
  static String get loginRequiredTitle => _get('需要登录', 'Login required');
  static String get sourceLoginRequiredHint => _get(
      '书源需要登录，请先在书源菜单中登录后重试',
      'This source requires login. Sign in from the source menu and retry.');

  // ----- 桌面图标切换失败原因（launcher_icon_service） -----
  static String get launcherIconPlatformUnsupported =>
      _get('当前平台不支持运行时换图标', 'Changing the icon at runtime is not supported on this platform');
  static String get launcherIconInstallUnsupported => _get(
      '当前安装方式不支持切换图标（仅 App Store / 企业签名安装可用）',
      'Changing the icon is not supported for this installation type (only App Store or enterprise-signed installs)');
  static String launcherIconChannelMissing(String message) => _locale == 'zh'
      ? '原生图标通道未注册：$message'
      : 'The native icon channel is not registered: $message';
  static String get launcherIconNativeRejected =>
      _get('原生侧拒绝切换图标', 'The native side rejected the icon change');

  // ----- 系统另存通道（file_save_channel） -----
  static String get saveChannelUnavailable => _get(
      '系统保存通道不可用，请更新应用版本后重试',
      'The system save channel is unavailable. Update the app and try again.');

  // ----- RSS 登录（rss_source_login） -----
  static String get rssLoginNotConfigured => _get(
      '该订阅源未配置登录（loginUrl / loginUi 均为空）',
      'This RSS source has no login configured (loginUrl and loginUi are both empty)');

  // ----- 书籍工具（book_open_utils） -----
  static String webFileAuthorFallback(String name, String author) =>
      _locale == 'zh' ? '$name 作者：$author' : '$name · $author';
  static String webFileInvalidDownloadUrl(String url) =>
      _locale == 'zh' ? '无效的下载地址：$url' : 'Invalid download URL: $url';
  static String webFileDownloadHttpFailed(int status) => _locale == 'zh'
      ? '下载失败：HTTP $status'
      : 'Download failed: HTTP $status';
  static String get webFileDownloadEmpty =>
      _get('下载失败：文件为空', 'Download failed: the file is empty');

  // ----- 封面相册导入失败（cover_album_store） -----
  static String coverAlbumImportItemFailed(String error) =>
      _locale == 'zh' ? '导入失败：$error' : 'Import failed: $error';
  static String get coverAlbumNameRequired =>
      _get('相册名称不能为空', 'The album name cannot be empty');
  static String get coverAlbumNotFound =>
      _get('相册不存在或已删除', 'The album does not exist or has been deleted');
  static String get coverAlbumInvalidId =>
      _get('相册标识非法', 'Invalid album identifier');
  static String get coverAlbumAlreadyDeleted =>
      _get('相册已删除', 'The album has been deleted');
  static String get coverAlbumImageInvalidId =>
      _get('图片标识非法', 'Invalid image identifier');
  static String get coverAlbumDirUnavailable =>
      _get('封面相册目录不可用', 'The cover album directory is unavailable');
  static String get coverAlbumImageEmpty =>
      _get('图片内容为空', 'The image content is empty');
  static String coverAlbumTooManyImages(int max) => _locale == 'zh'
      ? '单次最多导入 $max 张图片'
      : 'You can import at most $max images at a time';
  static String coverAlbumBatchTooLarge(int mb) => _locale == 'zh'
      ? '本次选择图片总大小超过 ${mb}MB'
      : 'The selected images exceed the $mb MB total size limit';
  static String get coverAlbumSaveImageFailed =>
      _get('保存图片失败', 'Failed to save the image');
  static String get coverAlbumPickerUnsupported =>
      _get('Web 端不支持封面相册', 'Cover albums are not supported on the web');
  static String get coverAlbumPickerOpenFailed =>
      _get('无法打开系统图片选择器，请重试', 'Unable to open the system image picker. Try again.');
  static String get coverAlbumPickerFailed =>
      _get('选择图片失败，请重试', 'Failed to pick images. Try again.');
  static String coverAlbumReadImageFailed(String name) => _locale == 'zh'
      ? '无法读取所选图片：$name'
      : 'Unable to read the selected image: $name';
  static String coverAlbumImageUndecodable(String name) => _locale == 'zh'
      ? '不是可解码的图片：$name'
      : 'Not a decodable image: $name';
  static String coverAlbumSaveFailed(String error) =>
      _locale == 'zh' ? '保存封面相册失败：$error' : 'Failed to save the cover album: $error';

  // ----- 封面相册图片过大（cover_album_image_picker） -----
  static String coverAlbumImageTooLarge(int mb) => _locale == 'zh'
      ? '图片过大（上限 ${mb}MB）'
      : 'The image is too large (limit $mb MB)';

  // ----- 漫画菜单 tooltip（reader_comic/manga_menu） -----
  static String get autoReadShort => _get('自动', 'Auto');
  static String get mangaPageSettings => _get('翻页设置', 'Page settings');

  // ----- MD3 调色板显示名（md3_colors 的 label 为引擎数据值，UI 走本映射） -----
  static String md3PaletteName(String id) => switch (id) {
        'wh' => _get('黑白', 'Black & White'),
        'gr' => _get('草野', 'Grassland'),
        'lemon' => _get('柠檬', 'Lemon'),
        'koharu' => _get('春', 'Spring'),
        'yuuka' => _get('千禧年', 'Millennium'),
        'phoebe' => _get('隐海修会', 'Hidden Sea Order'),
        'sora' => _get('晴空', 'Clear Sky'),
        'august' => _get('八月', 'August'),
        'carlotta' => _get('新浪潮', 'New Wave'),
        'mujika' => _get('乐队', 'Band'),
        'elink' => _get('电子书', 'Elink'),
        'transparent' => _get('透明', 'Transparent'),
        _ => _get('默认', 'Default'),
      };

  // ----- 角色卡（契约 §2.56，R42 阶段 2A） -----
  static String get roleMaleLead => _get('男主', 'Male Lead');
  static String get roleFemaleLead => _get('女主', 'Female Lead');
  static String get roleMaleSupporting => _get('男配', 'Male Supporting');
  static String get roleFemaleSupporting => _get('女配', 'Female Supporting');
  static String get characterManageTitle => _get('角色管理', 'Manage Characters');
  static String get characterAddTitle => _get('新增角色', 'Add Character');
  static String get characterEditTitle => _get('编辑角色', 'Edit Character');
  static String get characterNameLabel => _get('角色名', 'Name');
  static String get characterNameRequired => _get('请输入角色名', 'Name is required');
  static String get characterRoleLabel => _get('定位', 'Role');
  static String get characterRoleUnset => _get('未设置', 'Not set');
  static String get characterAliasesLabel => _get('别名', 'Aliases');
  static String get characterAliasesHint =>
      _get('多个别名用「、」分隔', 'Separate aliases with "、"');
  static String get characterTagsLabel => _get('标签', 'Tags');
  static String get characterTagsHint =>
      _get('多个标签用「|」分隔', 'Separate tags with "|"');
  static String get characterPersonalityLabel => _get('性格', 'Personality');
  static String get characterSummaryLabel => _get('简介', 'Summary');
  static String get characterEmptyHint => _get('还没有人物档案', 'No character profiles yet');
  static String get characterLoadFailed => _get('角色加载失败', 'Failed to load characters');
  static String get characterSaveFailed => _get('保存失败', 'Failed to save');
  static String get characterDeleteFailed => _get('删除失败', 'Failed to delete');
  static String characterDeleteConfirm(String name) =>
      _get('确定删除角色「$name」？', 'Delete character "$name"?');
  static String get characterManageEntryDesc =>
      _get('手动建档，详情页展示角色卡', 'Add characters manually; shown on book details');

  // ----- L10N 批1：关联导入 / 主题包 / 书源导入 / 应用字体 / 阅读主题 / 定时任务 -----

  // 关联导入（association_notifier）
  static String associationHttpStatusFailed(int code) => _locale == 'zh'
      ? 'HTTP 请求失败：状态码 $code'
      : 'HTTP request failed: status code $code';
  static String associationLoadFromUrlFailed(String error) => _locale == 'zh'
      ? '从 URL 加载失败：$error'
      : 'Failed to load from the URL: $error';
  static String associationFileNotExist(String path) => _locale == 'zh'
      ? '文件不存在：$path'
      : 'File not found: $path';
  static String associationReadFileFailed(String error) => _locale == 'zh'
      ? '读取文件失败：$error'
      : 'Failed to read the file: $error';
  static String get associationContentEmpty => _get('内容为空', 'Content is empty');
  static String associationReadClipboardFailed(String error) => _locale == 'zh'
      ? '读取剪贴板失败：$error'
      : 'Failed to read the clipboard: $error';
  static String get associationExpectedJsonArrayOrObject => _get(
      '格式错误：期望 JSON 数组或对象',
      'Invalid format: expected a JSON array or object');
  static String associationJsonParseFailed(String error) => _locale == 'zh'
      ? 'JSON 解析错误：$error'
      : 'JSON parse error: $error';
  static String get associationNoValidEntries =>
      _get('格式错误，未解析到有效条目', 'Invalid format: no valid entries parsed');
  static String get associationFormatInvalid => _get('格式不对', 'Invalid format');
  static String get associationUnitBookSource => _get('书源', 'Book source');
  static String get associationUnitRssSource => _get('RSS 源', 'RSS source');
  static String get associationUnitReplaceRule =>
      _get('替换规则', 'Replacement rule');
  static String get associationUnitTheme => _get('主题配置', 'Theme config');
  static String get associationUnitHttpTts => _get('HTTP TTS', 'HTTP TTS');
  static String get associationUnitDictRule => _get('字典规则', 'Dictionary rule');
  static String get associationUnitTxtTocRule =>
      _get('TXT 目录规则', 'TXT TOC rule');
  static String get associationUnitHighlightRule =>
      _get('高亮规则', 'Highlight rule');
  static String get associationUnitAutoTask =>
      _get('自动任务', 'Scheduled task');
  static String get associationMissingName => _get('缺少名称', 'Missing name');
  static String associationImportReplaceRuleFailed(String name, String error) =>
      _locale == 'zh'
          ? '导入替换规则「$name」失败：$error'
          : 'Failed to import replacement rule "$name": $error';
  static String associationImportThemeFailed(String error) => _locale == 'zh'
      ? '导入主题配置失败：$error'
      : 'Failed to import the theme config: $error';
  static String get associationMissingNameOrRegex =>
      _get('缺少名称或正则', 'Missing name or regex pattern');
  static String associationImportDictRuleFailed(String name, String error) =>
      _locale == 'zh'
          ? '导入字典规则「$name」失败：$error'
          : 'Failed to import dictionary rule "$name": $error';
  static String associationImportTxtTocRuleFailed(String name, String error) =>
      _locale == 'zh'
          ? '导入 TXT 规则「$name」失败：$error'
          : 'Failed to import TXT rule "$name": $error';
  static String get associationUuidInvalid => _get('uuid 非法', 'Invalid uuid');
  static String get associationPatternEmpty =>
      _get('匹配模式为空', 'Match pattern is empty');
  static String associationInvalidRegex(String pattern) => _locale == 'zh'
      ? '正则表达式无效: $pattern'
      : 'Invalid regular expression: $pattern';
  static String get associationUuidDuplicate =>
      _get('uuid 重复', 'Duplicate uuid');
  static String associationImportHighlightRuleFailed(
          String name, String error) =>
      _locale == 'zh'
          ? '导入高亮规则「$name」失败：$error'
          : 'Failed to import highlight rule "$name": $error';
  static String associationSaveHighlightRulesFailed(String error) =>
      _locale == 'zh'
          ? '写入高亮规则失败：$error'
          : 'Failed to save the highlight rules: $error';
  static String get associationImportAutoTaskMissingName => _get(
      '导入自动任务失败：缺少任务名称',
      'Failed to import scheduled task: missing task name');
  static String associationImportAutoTaskInvalidCron(String name) =>
      _locale == 'zh'
          ? '导入自动任务「$name」失败：请输入有效的五段 Cron 计划'
          : 'Failed to import scheduled task "$name": enter a valid 5-field cron schedule';
  static String associationImportAutoTaskMissingScript(String name) =>
      _locale == 'zh'
          ? '导入自动任务「$name」失败：请输入 JavaScript 任务脚本'
          : 'Failed to import scheduled task "$name": enter a JavaScript task script';
  static String associationImportAutoTaskFailed(String name, String error) =>
      _locale == 'zh'
          ? '导入自动任务「$name」失败：$error'
          : 'Failed to import scheduled task "$name": $error';

  // 主题包导入/导出（theme_package_service）
  static String themePackageEntryTooLarge(String entry) => _locale == 'zh'
      ? '主题包条目过大：$entry（上限 32MB）'
      : 'Theme package entry too large: $entry (limit 32MB)';
  static String get themePackageContentTooLarge => _get(
      '主题包内容过大（上限 512MB）',
      'Theme package content too large (limit 512MB)');
  static String themePackageReadFailed(String error) => _locale == 'zh'
      ? '无法读取主题包：$error'
      : 'Unable to read the theme package: $error';
  static String get themePackageUnreadable => _get(
      '无法读取主题包（文件格式不正确）',
      'Unable to read the theme package (invalid file format)');
  static String get themePackageFileEmpty =>
      _get('主题包文件为空', 'The theme package file is empty');
  static String get themePackageFileTooLarge => _get(
      '主题包文件过大（上限 512MB）',
      'Theme package file too large (limit 512MB)');
  static String get themePackageMultiVolumeUnsupported => _get(
      '不支持分卷主题包', 'Multi-volume theme packages are not supported');
  static String get themePackageManifestTooLarge => _get(
      '主题包清单过大（上限 4MB）',
      'Theme package manifest too large (limit 4MB)');
  static String get themePackageTooManyEntries => _get(
      '主题包条目过多（上限 4096）',
      'Too many entries in the theme package (limit 4096)');
  static String themePackageIllegalPath(String path) => _locale == 'zh'
      ? '主题包包含非法路径：$path'
      : 'The theme package contains an illegal path: $path';
  static String themePackageSymlinkEntry(String entry) => _locale == 'zh'
      ? '主题包包含符号链接条目：$entry'
      : 'The theme package contains a symbolic link entry: $entry';
  static String themePackageEncryptedEntry(String entry) => _locale == 'zh'
      ? '主题包包含加密条目：$entry'
      : 'The theme package contains an encrypted entry: $entry';
  static String themePackageEntryHeaderCorrupt(String entry) => _locale == 'zh'
      ? '无法读取主题包（$entry 头部损坏）'
      : 'Unable to read the theme package ($entry has a corrupt header)';
  static String themePackageCompressionUnsupported(String entry) =>
      _locale == 'zh'
          ? '主题包压缩方式不支持：$entry'
          : 'Unsupported compression method in the theme package: $entry';
  static String get themePackageManifestIncomplete => _get(
      '主题包清单不完整', 'The theme package manifest is incomplete');
  static String themePackageVersionUnsupported(int? version) => _locale == 'zh'
      ? '不支持的主题包版本: ${version ?? '未知'}'
      : 'Unsupported theme package version: ${version ?? 'unknown'}';
  static String themePackageExtractFailed(String entry) => _locale == 'zh'
      ? '无法读取主题包（$entry 解压失败）'
      : 'Unable to read the theme package (failed to extract $entry)';
  static String get themePackageBackgroundTooLarge => _get(
      '背景图片过大（上限 32MB）', 'Background image too large (limit 32MB)');

  // 书源导入（source_import_service）
  static String get sourceImportInvalidJsonFormat => _get(
      '无效的 JSON 格式：期望数组或对象',
      'Invalid JSON format: expected an array or object');
  static String sourceImportItemNotObject(int index) => _locale == 'zh'
      ? '第 $index 项不是有效的 JSON 对象'
      : 'Item $index is not a valid JSON object';
  static String sourceImportItemValidationFailed(int index, String errors) =>
      _locale == 'zh'
          ? '第 $index 项校验失败：$errors'
          : 'Item $index failed validation: $errors';
  static String sourceImportNoValidSource(int failed, String? firstError) =>
      _locale == 'zh'
          ? '未解析到有效书源（失败 $failed 项）${firstError == null ? '' : '：$firstError'}'
          : 'No valid book source parsed ($failed item(s) failed)${firstError == null ? '' : ': $firstError'}';
  static String get sourceImportUnknownSourceName =>
      _get('未知书源', 'Unknown book source');
  static String sourceImportNamedSourceFailed(String name, String error) =>
      _locale == 'zh'
          ? '导入「$name」失败：$error'
          : 'Failed to import "$name": $error';
  static String sourceImportJsonParseFailed(String error) => _locale == 'zh'
      ? 'JSON 解析错误：$error'
      : 'JSON parse error: $error';
  static String sourceImportHttpStatusFailed(int code) => _locale == 'zh'
      ? 'HTTP 请求失败：状态码 $code'
      : 'HTTP request failed: status code $code';
  static String sourceImportTimeout(String error) => _locale == 'zh'
      ? '网络请求超时：$error'
      : 'Network request timed out: $error';
  static String sourceImportFromUrlFailed(String error) => _locale == 'zh'
      ? '从 URL 导入失败：$error'
      : 'Failed to import from the URL: $error';
  static String sourceImportReadFileFailed(String error) => _locale == 'zh'
      ? '读取文件失败：$error'
      : 'Failed to read the file: $error';
  static String sourceImportFileNotExist(String path) => _locale == 'zh'
      ? '文件不存在：$path'
      : 'File not found: $path';
  static String sourceImportMissingField(String field) => _locale == 'zh'
      ? '缺少 $field'
      : 'Missing $field';
  static String sourceImportSummary(int total, String unit, String parts) =>
      _locale == 'zh'
          ? '共 $total 个$unit：$parts'
          : 'Total $total $unit(s): $parts';
  static String sourceImportPartSuccess(int count) =>
      _locale == 'zh' ? '成功 $count' : 'Success $count';
  static String sourceImportPartFailed(int count) =>
      _locale == 'zh' ? '失败 $count' : 'Failed $count';
  static String sourceImportPartSkipped(int count) =>
      _locale == 'zh' ? '跳过 $count' : 'Skipped $count';
  static String get sourceImportUnitBookSource => _get('书源', 'Book source');

  // 应用字体（app_font_store）
  static String get appFontUnsupportedPlatform => _get(
      '当前平台不支持自定义应用字体',
      'Custom app fonts are not supported on this platform');
  static String get appFontPickerOpenFailed => _get(
      '无法打开系统文件选择器，请重试',
      'Unable to open the system file picker. Please try again');
  static String get appFontFileEmpty => _get('字体文件为空', 'The font file is empty');
  static String appFontFileTooLarge(int mb) => _locale == 'zh'
      ? '字体文件过大（上限 ${mb}MB）'
      : 'Font file too large (limit ${mb}MB)';
  static String get appFontUnsupportedFormat => _get(
      '不支持的字体格式（仅支持 TTF / OTF / TTC）',
      'Unsupported font format (TTF / OTF / TTC only)');
  static String get appFontNotSet => _get('未设置应用字体', 'No app font set');
  static String get appFontFileMissingFallback => _get(
      '自定义字体文件缺失，已回退默认字体',
      'Custom font file is missing; fell back to the default font');
  static String get appFontFileCorruptFallback => _get(
      '自定义字体文件已损坏，已回退默认字体',
      'Custom font file is corrupted; fell back to the default font');
  static String get appFontReadFailedFallback => _get(
      '自定义字体读取失败，已回退默认字体',
      'Failed to read the custom font; fell back to the default font');
  static String get appFontLoadTimeoutFallback => _get(
      '自定义字体加载超时，已回退默认字体',
      'Timed out loading the custom font; fell back to the default font');
  static String get appFontLoadFailedFallback => _get(
      '自定义字体加载失败，已回退默认字体',
      'Failed to load the custom font; fell back to the default font');
  static String get appFontCannotReadPicked => _get(
      '无法读取所选字体文件', 'Unable to read the selected font file');
  static String get appFontFallbackSuffix =>
      _locale == 'zh' ? '，已回退默认字体' : ', fell back to the default font';
  static String appFontWithFallback(String message) =>
      '$message$appFontFallbackSuffix';
  static String get appFontFileInvalidOrCorrupt => _get(
      '字体文件内容无效或已损坏', 'The font file is invalid or corrupted');
  static String get appFontTtcInvalidOrCorrupt => _get(
      '字体集合（TTC）内容无效或已损坏',
      'The font collection (TTC) is invalid or corrupted');
  static String get appFontNotValidFont => _get(
      '不是有效的 TTF / OTF / TTC 字体文件',
      'Not a valid TTF / OTF / TTC font file');

  // 阅读主题（reader_theme）
  static String readerThemeColorUnparsable(String raw) => _locale == 'zh'
      ? '无法解析颜色：$raw'
      : 'Unable to parse the color: $raw';
  static String readerThemeColorTypeInvalid(String type) => _locale == 'zh'
      ? '颜色字段类型非法：$type'
      : 'Invalid color field type: $type';
  static String readerThemeFieldShouldBeNumber(String key) => _locale == 'zh'
      ? '$key 应为数字'
      : '$key must be a number';
  static String readerThemeFieldShouldBeInt(String key) => _locale == 'zh'
      ? '$key 应为整数'
      : '$key must be an integer';
  static String readerThemeFieldShouldBeBool(String key) => _locale == 'zh'
      ? '$key 应为布尔值'
      : '$key must be a boolean';
  static String readerThemeFieldShouldBeString(String key) => _locale == 'zh'
      ? '$key 应为字符串'
      : '$key must be a string';
  static String get readerThemeNameMissing =>
      _get('主题名称缺失或为空', 'Theme name is missing or empty');
  static String get readerThemeStyleMissing =>
      _get('缺少 style 样式对象', 'Missing style object');
  static String readerThemeInvalidJson(String error) => _locale == 'zh'
      ? '不是有效的 JSON：$error'
      : 'Invalid JSON: $error';
  static String get readerThemeListEmpty =>
      _get('主题列表为空', 'The theme list is empty');
  static String get readerThemeListNonObjectEntry => _get(
      '主题列表中存在非对象条目',
      'The theme list contains a non-object entry');
  static String get readerThemeJsonTopLevelInvalid => _get(
      'JSON 顶层应为对象或数组',
      'The JSON top level must be an object or array');
  static String get readerThemeDefaultName =>
      _get('阅读主题', 'Reading theme');
  // 内置阅读主题名：`kBuiltInReaderThemes` 必须保持 const（测试与
  // `ReaderThemeState` 的 const 构造依赖），故此处只能提供编译期常量，
  // 无法走 _get 运行时切换；D5=B 口径下保持中文。
  static const String readerThemeBuiltinWechat = '微信读书';
  static const String readerThemeBuiltinPreset1 = '预设1';
  static const String readerThemeBuiltinPreset2 = '预设2';
  static const String readerThemeBuiltinPreset3 = '预设3';
  static const String readerThemeBuiltinPreset4 = '预设4';

  // 定时任务错误态（auto_task_notifier）
  static String get autoTaskFfiUnavailableLoad => _get(
      'FFI 不可用，无法加载定时任务',
      'FFI is unavailable; cannot load scheduled tasks');
  static String autoTaskLoadFailed(String error) => _locale == 'zh'
      ? '加载任务失败: $error'
      : 'Failed to load tasks: $error';
  static String get autoTaskFfiUnavailableCreate => _get(
      'FFI 不可用，无法创建任务',
      'FFI is unavailable; cannot create the task');
  static String autoTaskCreateFailed(String error) => _locale == 'zh'
      ? '创建任务失败: $error'
      : 'Failed to create the task: $error';
  static String autoTaskUpdateInvalidJson(String error) => _locale == 'zh'
      ? '更新任务失败: 规则 JSON 无效: $error'
      : 'Failed to update the task: invalid rule JSON: $error';
  static String get autoTaskUpdateMissingId => _get(
      '更新任务失败: 缺少任务 id', 'Failed to update the task: missing task id');
  static String get autoTaskFfiUnavailableUpdate => _get(
      'FFI 不可用，无法更新任务',
      'FFI is unavailable; cannot update the task');
  static String autoTaskUpdateFailed(String error) => _locale == 'zh'
      ? '更新任务失败: $error'
      : 'Failed to update the task: $error';
  static String get autoTaskFfiUnavailableDelete => _get(
      'FFI 不可用，无法删除任务',
      'FFI is unavailable; cannot delete the task');
  static String autoTaskDeleteFailed(String error) => _locale == 'zh'
      ? '删除任务失败: $error'
      : 'Failed to delete the task: $error';
  static String get autoTaskFfiUnavailableRun => _get(
      'FFI 不可用，无法运行任务',
      'FFI is unavailable; cannot run the task');
  static String autoTaskRunFailed(String error) => _locale == 'zh'
      ? '运行任务失败: $error'
      : 'Failed to run the task: $error';
  static String get autoTaskRunSuccess => _get('成功', 'Success');
  static String get autoTaskRunFailure => _get('失败', 'Failed');

  // ----- L10N 批2：朗读音频（audio_notifier / system_tts_service） -----
  static String get audioNoUsableEngineHint => _get(
      '未配置可用朗读引擎，将按估算节奏朗读',
      'No usable speech engine is configured; reading aloud at the estimated pace');
  static String get audioNowPlaying => _get('正在播放', 'Now playing');
  static String audioSegmentPlayFailed(String error) => _locale == 'zh'
      ? '音频分段播放失败：$error'
      : 'Audio segment playback failed: $error';
  static String get audioNoResourceLink =>
      _get('未获取到资源链接', 'Failed to obtain the resource link');
  static String get audioNoPlayableChapter =>
      _get('无可播放章节', 'No playable chapters');
  static String audioChapterContentUnavailable(String error) => _locale == 'zh'
      ? '章节正文获取失败，无法朗读：$error'
      : 'Failed to load the chapter content; cannot read aloud: $error';
  static String get audioTtsNoAudioFile => _get(
      'TTS 合成未返回音频文件（引擎或缓存异常）',
      'TTS synthesis returned no audio file (engine or cache error)');
  static String audioPlaybackFallback(String failure) => _locale == 'zh'
      ? '朗读音频不可用，本段按估算时长继续：$failure'
      : 'Read-aloud audio is unavailable; continuing this segment with the estimated duration: $failure';
  static String get audioSystemTtsNoAudioFile => _get(
      '系统 TTS 未返回音频文件', 'System TTS returned no audio file');
  static String audioSystemTtsFallback(String failure) => _locale == 'zh'
      ? '系统 TTS 朗读失败，本段按估算时长继续：$failure'
      : 'System TTS read-aloud failed; continuing this segment with the estimated duration: $failure';
  static String systemTtsVoiceUnavailable(String voice) => _locale == 'zh'
      ? '音色不可用：$voice'
      : 'Voice unavailable: $voice';
  static String get systemTtsVoiceFallbackForEngine => _get(
      '原音色在当前引擎不可用，已回退系统默认音色',
      'The previous voice is unavailable on the current engine; fell back to the system default voice');
  static String get systemTtsVoiceFallback => _get(
      '音色不可用，已回退系统默认音色',
      'Voice unavailable; fell back to the system default voice');
  static String get systemTtsTextEmpty =>
      _get('朗读文本为空', 'The read-aloud text is empty');
  static String get systemTtsEngineMissing => _get(
      '系统未安装可用的 TTS 引擎',
      'No usable TTS engine is installed on the system');
  static String get systemTtsSynthesisCancelled =>
      _get('系统 TTS 合成已取消', 'System TTS synthesis cancelled');
  static String get systemTtsEngineSwitchCancelled =>
      _get('系统 TTS 引擎切换已取消', 'System TTS engine switch cancelled');
  static String get systemTtsNoGeneratedFile => _get(
      '系统 TTS 未生成音频文件', 'System TTS did not generate an audio file');
  static String systemTtsSynthesisTimeout(int seconds) => _locale == 'zh'
      ? '系统 TTS 合成超时（${seconds}s）'
      : 'System TTS synthesis timed out (${seconds}s)';
  static String systemTtsSynthesisFailed(String error) => _locale == 'zh'
      ? '系统 TTS 合成失败：$error'
      : 'System TTS synthesis failed: $error';
  static String get systemTtsEngineInitTimeout => _get(
      '系统 TTS 引擎初始化超时',
      'System TTS engine initialization timed out');

  // ----- L10N 批2：阅读器正文/目录重载（reader_notifier） -----
  static String get readerReloadCharsetFailureHint =>
      _get('编码或文件不可读', 'The encoding or file is unreadable');
  static String get readerReloadTocRuleFailureHint => _get(
      '目录规则未命中或文件不可读',
      'The TOC rule did not match or the file is unreadable');
  static String readerTocLoadFailed(String hint) => _locale == 'zh'
      ? '目录加载失败（$hint）'
      : 'Failed to load the TOC ($hint)';
  static String get readerNoBookOrToc => _get('没有书籍或目录', 'No book or TOC');
  static String get readerLocalBookNoContentRefresh => _get(
      '本地书不支持刷新正文', 'Local books do not support content refresh');
  static String get readerInvalidChapterIndex =>
      _get('无效章节索引', 'Invalid chapter index');
  static String get readerContentRefreshInProgress =>
      _get('正文刷新进行中', 'Content refresh in progress');
  static String get readerContentFetchEmpty =>
      _get('正文抓取为空', 'The fetched content is empty');
  static String get readerNoBook => _get('没有书籍', 'No book');
  static String get readerSourceChangeInProgress =>
      _get('更换书源进行中', 'Changing the book source is in progress');
  static String get readerReadBookRecordFailed =>
      _get('读取书籍记录失败', 'Failed to read the book record');
  static String get readerNewSourceNoToc => _get(
      '目录加载失败（新源无目录）',
      'Failed to load the TOC (the new source has no TOC)');
  static String readerContentRefreshFailed(String error) => _locale == 'zh'
      ? '正文刷新失败：$error'
      : 'Failed to refresh the content: $error';

  // ----- L10N 批2：九宫格点击动作标签（reader_tap_action） -----
  static String get readerTapMenu => _get('菜单', 'Menu');
  static String get readerTapNextPage => _get('下一页', 'Next page');
  static String get readerTapPreviousPage => _get('上一页', 'Previous page');
  static String get readerTapPreviousParagraph =>
      _get('朗读上一段', 'Read the previous paragraph');
  static String get readerTapNextParagraph =>
      _get('朗读下一段', 'Read the next paragraph');
  static String get readerTapToggleReplace =>
      _get('替换开关', 'Toggle replacement');
  static String get readerTapToggleReadAloud =>
      _get('朗读暂停继续', 'Pause/resume read-aloud');

  // ----- L10N 批2：正文选择菜单标签（selection_menu_config） -----
  static String get selectionMenuCopy => _get('复制', 'Copy');
  static String get selectionMenuShare => _get('分享', 'Share');
  static String get selectionMenuBrowser => _get('浏览器', 'Browser');
  static String get selectionMenuBookmark => _get('书签', 'Bookmark');
  static String get selectionMenuDict => _get('字典', 'Dictionary');
  static String get selectionMenuReplace => _get('替换', 'Replace');
  static String get selectionMenuAiClean => _get('AI 净化', 'AI clean');
  static String get selectionMenuAiRewrite => _get('AI 改写', 'AI rewrite');
  static String get selectionMenuInsertBgmBefore =>
      _get('插入背景音乐（前）', 'Insert background music (before)');
  static String get selectionMenuInsertBgmAfter =>
      _get('插入背景音乐（后）', 'Insert background music (after)');

  // ----- L10N 批2：备份忽略项标题（backup_content_service） -----
  static String get backupContentBookmark =>
      _get('书签与划线笔记', 'Bookmarks and highlights/notes');
  static String get backupContentBookGroup =>
      _get('书籍分组', 'Book groups');
  static String get backupContentRssSource => _get('RSS 源', 'RSS sources');
  static String get backupContentReplaceRule =>
      _get('替换规则', 'Replacement rules');
  static String get backupContentSourceSubscription =>
      _get('订阅源', 'Subscription sources');
  static String get backupContentHttpTts =>
      _get('在线朗读引擎', 'Online speech engines');
  static String get backupContentKeyboardAssists =>
      _get('键盘辅助', 'Keyboard assists');
  static String get backupContentDictRule =>
      _get('词典规则', 'Dictionary rules');

  // ----- L10N 批2：直链上传规则（direct_link_upload_rule_service） -----
  static String directLinkFieldMustBeString(String field) => _locale == 'zh'
      ? '字段 $field 必须是字符串'
      : 'Field $field must be a string';
  static String get directLinkCompressMustBeBool => _get(
      '字段 compress 必须是布尔值', 'Field compress must be a boolean');
  static String get directLinkUploadUrlRequired =>
      _get('上传Url不能为空', 'The upload URL cannot be empty');
  static String get directLinkUploadUrlInvalid => _get(
      '上传Url不是有效的 http(s) 地址',
      'The upload URL is not a valid http(s) address');
  static String get directLinkDownloadRuleRequired =>
      _get('下载Url规则不能为空', 'The download URL rule cannot be empty');
  static String get directLinkSummaryRequired =>
      _get('注释不能为空', 'The summary cannot be empty');
  static String get directLinkBuiltinNotJson => _get(
      '内置直链上传规则不是有效的 JSON',
      'The built-in direct-link upload rules are not valid JSON');
  static String get directLinkBuiltinNotArray => _get(
      '内置直链上传规则必须是 JSON 数组',
      'The built-in direct-link upload rules must be a JSON array');
  static String get directLinkBuiltinEntryNotObject => _get(
      '内置直链上传规则条目必须是 JSON 对象',
      'Each built-in direct-link upload rule must be a JSON object');
  static String get directLinkBuiltinEmpty =>
      _get('内置直链上传规则为空', 'The built-in direct-link upload rules are empty');
  static String get directLinkRuleEmpty =>
      _get('规则内容为空', 'The rule content is empty');
  static String get directLinkRuleNotJson =>
      _get('规则不是有效的 JSON', 'The rule is not valid JSON');
  static String get directLinkRuleNotObject =>
      _get('规则必须是 JSON 对象', 'The rule must be a JSON object');

  // ----- L10N 批2：RSS 图片 data URI（image_data_uri） -----
  static String imageDataTooLarge(String limit) => _locale == 'zh'
      ? '图片数据过大（超过 $limit）'
      : 'The image data is too large (over $limit)';
  static String get imageDataMissingComma => _get(
      'data URI 缺少逗号分隔符', 'The data URI is missing the comma separator');
  static String get imageDataMissingMime => _get(
      'data URI 未声明图片类型', 'The data URI does not declare an image type');
  static String imageDataNotImage(String mimeType) => _locale == 'zh'
      ? '不是图片类型：$mimeType'
      : 'Not an image type: $mimeType';
  static String get imageDataMissingBase64 => _get(
      'data URI 缺少 base64 编码', 'The data URI is missing base64 encoding');
  static String get imageDataEmpty => _get('图片数据为空', 'The image data is empty');
  static String get imageDataBase64Invalid =>
      _get('base64 数据无效', 'Invalid base64 data');

  // ----- L10N 批2：生物识别快捷解锁（privacy_biometric_service） -----
  static String get privacyNoPassword =>
      _get('请先设置隐私密码', 'Set a privacy password first');
  static String get privacyBiometricNotConfigured => _get(
      '生物快捷解锁未开启或已失效，请改用密码',
      'Biometric quick unlock is off or expired; use the password instead');
  static String get privacyBiometricUnsupported =>
      _get('当前系统不支持生物识别', 'This system does not support biometrics');
  static String get privacyBiometricNoHardware => _get(
      '设备不支持指纹或面容识别',
      'This device does not support fingerprint or face recognition');
  static String get privacyBiometricNotEnrolled => _get(
      '尚未录入指纹或面容，请先在系统设置中添加',
      'No fingerprint or face is enrolled; add one in the system settings first');
  static String get privacyBiometricLockedOut => _get(
      '生物识别暂时锁定，请稍后重试或改用密码',
      'Biometrics are temporarily locked; try again later or use the password');
  static String get privacyBiometricPermanentlyLockedOut => _get(
      '生物识别已被系统锁定，请改用密码，并在解锁后重新开启快捷解锁',
      'Biometrics are locked by the system; use the password, then re-enable quick unlock after unlocking');
  static String get privacyBiometricKeyInvalidated => _get(
      '指纹或面容已变更，生物快捷解锁已关闭，请改用密码并重新开启',
      'The fingerprint or face changed; biometric quick unlock was disabled; use the password and re-enable it');
  static String get privacyBiometricCancelled =>
      _get('已取消生物识别', 'Biometric authentication cancelled');
  static String get privacyBiometricTimeout => _get(
      '生物识别超时，请重试或改用密码',
      'Biometric authentication timed out; try again or use the password');
  static String get privacyBiometricFailed => _get(
      '生物识别失败，请重试或改用密码',
      'Biometric authentication failed; try again or use the password');

  // ----- L10N 批2：远程服务器行解析（server_service） -----
  static String serverRowIdShapeMismatch(Object? value) => _locale == 'zh'
      ? 'servers 行 id 形态不符: $value'
      : 'servers row id has an unexpected type: $value';
  static String serverRowNameShapeMismatch(Object? value) => _locale == 'zh'
      ? 'servers 行 name 形态不符: $value'
      : 'servers row name has an unexpected type: $value';
  static String serverRowSortNumberShapeMismatch(Object? value) =>
      _locale == 'zh'
      ? 'servers 行 sortNumber 形态不符: $value'
      : 'servers row sortNumber has an unexpected type: $value';
  static String serverRowTypeShapeMismatch(Object? value) => _locale == 'zh'
      ? 'servers 行 type 形态不符: $value'
      : 'servers row type has an unexpected type: $value';
  static String serverListNotJsonArray(Object? raw) => _locale == 'zh'
      ? 'webdavServersList 返回非 JSON 数组: $raw'
      : 'webdavServersList did not return a JSON array: $raw';
  static String serverListItemNotObject(int index, Object? item) =>
      _locale == 'zh'
      ? 'webdavServersList 第 $index 项不是 JSON 对象: $item'
      : 'webdavServersList item $index is not a JSON object: $item';

  // ----- L10N 批2：FFI 初始化失败页（main.dart） -----
  static String get ffiInitFailedTitle =>
      _get('Rust 引擎初始化失败', 'Rust engine initialization failed');
  static String get ffiFixHintAndroidHashMismatch => _get(
      'Android 上 Rust .so 与当前 Dart 桥接代码不同步（content hash 失配）。\n\n'
      '请在仓库根目录执行：\n'
      '.\\rust\\scripts\\build-android.ps1 -Mode debug -Targets "aarch64,x86_64"\n\n'
      '或使用统一入口：\n'
      '.\\flutter_legado\\scripts\\build-apk.ps1\n\n'
      '然后重新构建并安装 APK。',
      'The Rust .so on Android is out of sync with the current Dart bridge code (content hash mismatch).\n\n'
      'Run this from the repository root:\n'
      '.\\rust\\scripts\\build-android.ps1 -Mode debug -Targets "aarch64,x86_64"\n\n'
      'Or use the unified entry point:\n'
      '.\\flutter_legado\\scripts\\build-apk.ps1\n\n'
      'Then rebuild and reinstall the APK.');
  static String get ffiFixHintAndroidBuild => _get(
      '请确认已构建 Android Rust FFI 动态库：\n'
      '.\\rust\\scripts\\build-android.ps1 -Mode debug\n'
      '然后执行 flutter build apk --debug 并重新安装。',
      'Make sure the Android Rust FFI library is built:\n'
      '.\\rust\\scripts\\build-android.ps1 -Mode debug\n'
      'Then run flutter build apk --debug and reinstall.');
  static String get ffiFixHintWindows => _get(
      '请使用开发脚本启动（会自动重编译 DLL）：\n'
      '.\\flutter_legado\\scripts\\run-windows.ps1\n\n'
      '或手动：cd rust && cargo build -p legado-ffi --features quickjs',
      'Launch via the development script (it rebuilds the DLL automatically):\n'
      '.\\flutter_legado\\scripts\\run-windows.ps1\n\n'
      'Or manually: cd rust && cargo build -p legado-ffi --features quickjs');
  static String get ffiFixHintGeneric => _get(
      '请确认已构建 Rust FFI 动态库，然后重新运行应用。\n'
      '纯 UI 开发可使用：flutter run --dart-define=USE_MOCK=true',
      'Make sure the Rust FFI library is built, then run the app again.\n'
      'For pure UI development use: flutter run --dart-define=USE_MOCK=true');

  // ----- L10N 批3：图片文件存储（nav_icon_store / theme_background_image_store） -----
  static String get imageContentEmpty =>
      _get('图片内容为空', 'The image content is empty');
  static String imageTooLarge(int mb) => _locale == 'zh'
      ? '图片过大（上限 ${mb}MB）'
      : 'The image is too large (limit $mb MB)';
  static String imageUndecodable(String name) => _locale == 'zh'
      ? '不是可解码的图片：$name'
      : 'Not a decodable image: $name';
  static String get navIconPathEmpty =>
      _get('图片路径为空', 'The image path is empty');
  static String get navIconWebUnsupported => _get(
      'Web 端不支持自定义导航图标',
      'Custom navigation icons are not supported on the web');
  static String get containerBackgroundWebUnsupported => _get(
      'Web 端不支持容器背景图',
      'Container background images are not supported on the web');

  // ----- L10N 批3：漫画翻页模式标签（manga_scroll_mode） -----
  static String get mangaScrollPagedLtr =>
      _get('单页式（从左到右）', 'Paged (left to right)');
  static String get mangaScrollPagedRtl =>
      _get('单页式（从右到左）', 'Paged (right to left)');
  static String get mangaScrollPagedTtb =>
      _get('单页式（从上到下）', 'Paged (top to bottom)');
  static String get mangaScrollWebtoon => _get('条漫', 'Webtoon');
  static String get mangaScrollWebtoonGap =>
      _get('条漫（页面有空隙）', 'Webtoon (with gaps)');
  static String get mangaScrollLtr => _get('从左到右', 'Left to right');
  static String get mangaScrollRtl => _get('从右到左', 'Right to left');
  static String get mangaScrollTtb => _get('从上到下', 'Top to bottom');
  static String get mangaScrollWebtoonInterval =>
      _get('条漫（间隔）', 'Webtoon (with gap)');

  // ----- L10N 批3：漫画页面适配标签（manga_page_scale_type） -----
  static String get mangaScaleStretch => _get('拉伸', 'Stretch');
  static String get mangaScaleFitWidth => _get('适配宽度', 'Fit width');
  static String get mangaScaleFitHeight => _get('适配高度', 'Fit height');
  static String get mangaScaleOriginal => _get('原始大小', 'Original size');
  static String get mangaScaleSmart => _get('智能适配', 'Smart fit');
  static String get mangaScaleFitScreen => _get('全屏适配', 'Fit screen');

  // ----- L10N 批3：关联导入标题（association_state） -----
  static String get associationImportTitle =>
      _get('关联导入', 'Deep link import');
  static String get importRssSourceTitle =>
      _get('导入 RSS 源', 'Import RSS source');
  static String get importThemeConfigTitle =>
      _get('导入主题配置', 'Import theme config');
  static String get importHttpTtsTitle => _get('导入 HTTP TTS', 'Import HTTP TTS');
  static String get importDictRuleTitle =>
      _get('导入字典规则', 'Import dictionary rules');
  static String get importTxtTocRuleTitle =>
      _get('导入 TXT 目录规则', 'Import TXT TOC rules');
  static String get importHighlightRuleTitle =>
      _get('导入高亮规则', 'Import highlight rules');
  static String get importAutoTaskTitle =>
      _get('导入自动任务', 'Import scheduled tasks');

  // ----- L10N 批3：隐私解锁频率/宽限标签（privacy_state） -----
  static String get privacyUnlockScopeEveryTime =>
      _get('每次进入', 'Every time');
  static String get privacyUnlockScopeAppSession =>
      _get('应用会话内', 'Per app session');
  static String get privacyUnlockScopeUntilBackground =>
      _get('离开后台后', 'Until leaving background');
  static String get privacyGraceNoWait => _get('不等待', 'No wait');
  static String get privacyGraceMinutes2 => _get('2 分钟', '2 minutes');
  static String get privacyGraceMinutes3 => _get('3 分钟', '3 minutes');
  static String privacyGraceSeconds(int seconds) =>
      _locale == 'zh' ? '$seconds 秒' : '$seconds seconds';

  // ----- L10N 批3：相对时间（time_utils） -----
  static String get timeAgoSuffix => _get('前', ' ago');
  static String get timeLaterSuffix => _get('后', ' later');
  static String timeAgoSeconds(int value) =>
      _locale == 'zh' ? '$value秒' : '$value seconds';
  static String timeAgoMinutes(int value) =>
      _locale == 'zh' ? '$value分钟' : '$value minutes';
  static String timeAgoHours(int value) =>
      _locale == 'zh' ? '$value小时' : '$value hours';
  static String timeAgoDays(int value) =>
      _locale == 'zh' ? '$value天' : '$value days';
  static String timeAgoWeeks(int value) =>
      _locale == 'zh' ? '$value周' : '$value weeks';
  static String timeAgoMonths(int value) =>
      _locale == 'zh' ? '$value月' : '$value months';
  static String timeAgoYears(int value) =>
      _locale == 'zh' ? '$value年' : '$value years';

  // ----- L10N 批3：书架排序标签（bookshelf_sort） -----
  static String get bookshelfSortByReadTime =>
      _get('按阅读时间', 'By reading time');
  static String get bookshelfSortByName => _get('按书名', 'By title');
  static String get bookshelfSortComprehensive =>
      _get('综合排序', 'Comprehensive');
  static String get bookshelfSortByAuthor => _get('按作者', 'By author');
  static String get bookshelfSortAscending => _get('升序', 'Ascending');

  // ----- L10N 批3：错误文案归一（error_message） -----
  static String get errorConnectionRefused =>
      _get('无法连接服务器', 'Unable to connect to the server');
  static String get errorConnectionReset =>
      _get('连接被服务器中断', 'The connection was interrupted by the server');
  static String get errorConnectionTimeout =>
      _get('网络连接超时', 'Network connection timed out');
  static String get errorPermissionDenied => _get(
      '没有写入权限，请换一个保存位置',
      'No write permission; choose another save location');

  // ----- L10N 批3：正文图片点击方式标签（click_img_way） -----
  static String get clickImgDefault =>
      _get('默认行为', 'Default behavior');
  static String get clickImgPreview => _get('预览图片', 'Preview image');
  static String get clickImgCompat =>
      _get('兼容旧版', 'Legacy compatibility');
  static String get clickImgDisabled => _get('关闭点击', 'Disable tap');
  static String get clickImgDoubleTap => _get('双击生效', 'Double tap');

  // ----- L10N 批3：标记效果标签（book_marking_style） -----
  static String get markingEffectSolid =>
      _get('单实线', 'Solid underline');
  static String get markingEffectWave => _get('波浪线', 'Wavy underline');
  static String get markingEffectDashed =>
      _get('虚线', 'Dashed underline');
  static String get markingEffectStrike => _get('删除线', 'Strikethrough');
  static String get markingEffectHighlight => _get('荧光', 'Highlight');
  static String get markingEffectBackground =>
      _get('背景色', 'Background color');
  static String get markingEffectTextColor => _get('字体色', 'Text color');

  // ----- L10N 批3：视频悬浮窗提示（video_float_window） -----
  static String get videoFloatPlaybackError => _get(
      '悬浮窗播放出错', 'Floating-window playback error');
  static String get videoFloatStopped =>
      _get('悬浮窗已停止', 'The floating window has stopped');
  static String videoFloatAdvanceFailed(String error) => _locale == 'zh'
      ? '连播失败：$error'
      : 'Continuous playback failed: $error';

  // ----- L10N 批3：导出保存提示（export_file_service） -----
  static String exportSaveDialogTitle(String name) =>
      _locale == 'zh' ? '保存 $name' : 'Save $name';
  static String exportSavedName(String name) =>
      _locale == 'zh' ? '已保存：$name' : 'Saved: $name';
  static String exportSavedToDirectory(String directory, String name) =>
      _locale == 'zh'
      ? '已保存到「$directory」：$name'
      : 'Saved to "$directory": $name';
  static String exportSavedToDownloadDirectory(String name) => _locale == 'zh'
      ? '已保存到下载目录：$name'
      : 'Saved to the Downloads folder: $name';
  static String exportSavedToLocation(String location) =>
      _locale == 'zh' ? '已保存到：$location' : 'Saved to: $location';

  // ----- L10N 批3：远程书库错误（remote_book_notifier） -----
  static String get remoteBookServerMissing => _get(
      '服务器不存在或已被删除', 'The server does not exist or has been deleted');
  static String get remoteBookDefaultServerHint => _get(
      '请先在备份设置中配置默认 WebDAV，或在「服务器配置」中添加服务器',
      'Configure the default WebDAV in the backup settings first, or add a server in "Server configuration"');
  static String get remoteBookDirListFormatError =>
      _get('目录列表格式错误', 'Invalid directory listing format');
  static String get remoteBookSelectBooksFirst =>
      _get('请先选择要导入的书籍', 'Select the books to import first');
  static String get remoteBookWebdavNotConfigured =>
      _get('WebDAV 未配置', 'WebDAV is not configured');

  // ----- L10N 批3：RSS 列表解析错误（rss_notifier） -----
  static String get rssPayloadNotObject => _get(
      'RSS 列表载荷期望 JSON 对象',
      'The RSS list payload must be a JSON object');
  static String get rssArticlesNotArray => _get(
      'RSS 列表 articles 期望 JSON 数组',
      'The RSS list "articles" field must be a JSON array');
  static String get rssListEntryNotObject => _get(
      'RSS 列表项期望 JSON 对象', 'Each RSS list entry must be a JSON object');

  // ----- L10N 批3：书源校验结果（check_source_notifier） -----
  static String checkSourceSearchFailed(String suffix) => _locale == 'zh'
      ? '搜索失败$suffix'
      : 'Search failed$suffix';
  static String checkSourceTocFailed(String suffix) =>
      _locale == 'zh' ? '目录失效$suffix' : 'TOC failed$suffix';
  static String checkSourceContentFailed(String suffix) =>
      _locale == 'zh' ? '正文失效$suffix' : 'Content failed$suffix';
  static String get checkSourceSuccess => _get('校验成功', 'Check passed');
  static String checkSourceCaptchaSuffix(String text) => _locale == 'zh'
      ? '$text（疑似验证码拦截）'
      : '$text (possible CAPTCHA block)';

  // ----- L10N 批3：WebDAV 同步状态（sync_notifier） -----
  static String get syncBookProgressDisabled => _get(
      '未开启「同步书籍进度」', 'Book progress sync is not enabled');
  static String get webdavServerInfoRequired => _get(
      '请先配置 WebDAV 服务器信息',
      'Configure the WebDAV server information first');
  static String webdavBackupFailed(String error) =>
      _locale == 'zh' ? '备份失败: $error' : 'Backup failed: $error';
  static String webdavSyncRestoredSources(int count) => _locale == 'zh'
      ? '同步完成，回写 $count 条书源'
      : 'Sync complete; $count book sources were written back';
  static String webdavSyncFailed(String error) =>
      _locale == 'zh' ? '同步失败: $error' : 'Sync failed: $error';

  // ----- L10N 批3：servers 表解析（webdav_server_service） -----
  static String serverRowConfigShapeMismatch(Object? value) => _locale == 'zh'
      ? 'servers 行 config 形态不符: $value'
      : 'servers row config has an unexpected type: $value';
  static String serversConfigNotObject(Object? value) => _locale == 'zh'
      ? 'servers.config 非 JSON 对象: $value'
      : 'servers.config is not a JSON object: $value';
  static String serversSaveIdMismatch(int id, int expected) => _locale == 'zh'
      ? 'servers 保存返回 id=$id，期望 $expected'
      : 'servers save returned id=$id; expected $expected';

  // ============== L10N 批4：长尾文件文案（收尾） ==============

  // ----- 朗读缓存保留时间（read_aloud_timer_settings） -----
  static String get raCacheRetentionInstant =>
      _get('即听即焚', 'Delete right after playback');
  static String raCacheRetentionDays(int days) =>
      _locale == 'zh' ? '$days 天' : '$days days';
  static String raCacheRetentionHours(int hours) =>
      _locale == 'zh' ? '$hours 小时' : '$hours hours';

  // ----- 启动自动检查备份（auto_check_new_backup_scheduler） -----
  static String autoCheckRestorePartial(int skipped) => _locale == 'zh'
      ? '恢复完成，但有 $skipped 个服务器配置未恢复（已保留本机配置）'
      : 'Restore finished, but $skipped server configs were not restored (local config kept)';
  static String get autoCheckPasswordRequired => _get(
      '该备份需要密码，请在备份恢复页手动恢复',
      'This backup requires a password; restore it manually on the backup restore page');

  // ----- 应用更新（app_update_service） -----
  static String get appUpdateVersionUnavailable =>
      _get('无法读取应用版本号', 'Unable to read the app version');
  static String get appUpdateFetchFailed =>
      _get('获取新版本出错', 'Failed to fetch the new version');
  static String appUpdateFetchFailedWithCode(int code) => _locale == 'zh'
      ? '获取新版本出错($code)'
      : 'Failed to fetch the new version ($code)';

  // ----- WebDAV 同步时间（sync_state） -----
  static String get syncNeverSynced => _get('从未同步', 'Never synced');
  static String get syncJustNow => _get('刚刚', 'Just now');
  static String syncMinutesAgo(int minutes) =>
      _locale == 'zh' ? '$minutes 分钟前' : '$minutes min ago';
  static String syncHoursAgo(int hours) =>
      _locale == 'zh' ? '$hours 小时前' : '$hours h ago';
  static String syncDaysAgo(int days) =>
      _locale == 'zh' ? '$days 天前' : '$days d ago';

  // ----- 阅读背景预设（reader_state） -----
  static String get readerBgGreen => _get('绿色', 'Green');
  static String get readerBgBrown => _get('棕色', 'Brown');
  static String get readerBgEyeProtect => _get('护眼', 'Eye comfort');

  // ----- 隐私策略解析（privacy_notifier） -----
  static String privacyPolicyTypeMismatch(String key, Object? value) =>
      _locale == 'zh'
          ? '隐私策略 $key 类型不符：$value'
          : 'Privacy policy $key has an unexpected type: $value';

  // ----- 发现页（explore_notifier） -----
  static String exploreLoadSourcesFailed(String error) =>
      _locale == 'zh' ? '加载书源失败：$error' : 'Failed to load sources: $error';
  static String exploreDeleteFailed(String error) =>
      _locale == 'zh' ? '卸载失败：$error' : 'Uninstall failed: $error';

  // ----- 远端备份恢复（webdav_restore_service） -----
  static String get webdavRemoteBackupNameInvalid =>
      _get('远端备份文件名无效', 'Invalid remote backup file name');

  // ----- 本地备份（local_backup_service） -----
  static String get backupJsonNotObject => _get(
      '备份 JSON 顶层不是对象', 'The backup JSON top level is not an object');
  static String get backupFilterLocalBooksFailed => _get(
      '备份本地书过滤失败，已取消本次备份',
      'Failed to filter local books; this backup was cancelled');

  // ----- iOS 桌面图标自检（launcher_icon_service） -----
  static String launcherIconDiagnostics({
    required String version,
    required String canSetMark,
    required int carCount,
    required String looseFiles,
    required String carReadableMark,
    required String modernDecl,
  }) =>
      _locale == 'zh'
          ? 'iOS $version / 声明$canSetMark / '
              'car $carCount/6 / 散文件$looseFiles / '
              'car可读$carReadableMark / 现代声明$modernDecl'
          : 'iOS $version / declared $canSetMark / '
              'car $carCount/6 / loose $looseFiles / '
              'car readable $carReadableMark / modern decl $modernDecl';
  static String get launcherIconSelfCheckUnavailable =>
      _get('自检不可用', 'Self-check unavailable');

  // ----- 远程书库批量导入结果（remote_book_state） -----
  static String remoteBookImportedCount(int ok) =>
      _locale == 'zh' ? '成功导入 $ok 本' : 'Imported $ok book(s)';
  static String remoteBookImportedMore(int count) =>
      _locale == 'zh' ? '（另有 $count 本）' : ' ($count more)';
  static String remoteBookImportFailedDetail(String detail) =>
      _locale == 'zh' ? '导入失败：$detail' : 'Import failed: $detail';
  static String remoteBookImportPartial(int ok, int failed, String detail) =>
      _locale == 'zh'
          ? '成功导入 $ok 本，$failed 本失败：$detail'
          : 'Imported $ok book(s); $failed failed: $detail';

  // ----- 平台通道通知（platform_channel） -----
  static String downloadNotificationTitle(String bookName) =>
      _locale == 'zh' ? '正在下载：$bookName' : 'Downloading: $bookName';
  static String get foregroundServiceTitle =>
      _get('阅读服务', 'Reading service');
  static String get foregroundServiceContent =>
      _get('正在后台运行', 'Running in the background');

  // ----- 导出格式（export_service） -----
  static String exportUnsupportedFormatWith(String format) => _locale == 'zh'
      ? '不支持的导出格式：$format'
      : 'Unsupported export format: $format';

  // ----- 堆转储（crash_log_service） -----
  static String get heapDumpNoPath =>
      _get('堆转储未返回文件路径', 'The heap dump returned no file path');

  // ----- 封面相册（cover_album_store） -----
  static String get coverAlbumWebUnsupported => _get(
      'Web 端不支持封面相册', 'Cover albums are not supported on the web');
  static String get coverAlbumSaveFailedInjected => _get(
      '保存封面相册失败（测试注入）',
      'Failed to save the cover album (test injection)');

  // ----- 书签角标图（bookmark_badge_image_store） -----
  static String get bookmarkBadgeWebUnsupported => _get(
      'Web 端不支持书签角标图',
      'Bookmark badge images are not supported on the web');

  // ----- 自动刷新书架结果（auto_refresh_book_scheduler） -----
  static String autoRefreshBooksUpdated(int count) => _locale == 'zh'
      ? '已更新 $count 本书的目录'
      : 'Updated the TOC of $count book(s)';
  static String autoRefreshNewChapters(int count) =>
      _locale == 'zh' ? '，新增 $count 章' : '; $count new chapter(s)';
  static String autoRefreshSuperseded(int count) => _locale == 'zh'
      ? '（$count 本被同书新刷新取代）'
      : ' ($count superseded by a newer refresh of the same book)';

  // ----- 欢迎页（welcome_screen） -----
  static String get welcomeTagline =>
      _get('品读万千故事', 'Discover countless stories');
  static String get welcomeTitleVertical => _get('阅\n读', 'Read');
  static String get welcomeSubtitleVertical =>
      _get('享\n受\n美\n好\n时\n光', 'Enjoy\nthe\nmoment');

  // ----- 换源进度（change_source_state） -----
  static String changeSourceProgressWithName(
    int resultCount,
    int done,
    int total,
    String name,
  ) =>
      _locale == 'zh'
          ? '结果 $resultCount，进度 $done/$total：$name'
          : 'Results $resultCount, progress $done/$total: $name';
  static String changeSourceProgressNoName(
    int resultCount,
    int done,
    int total,
  ) =>
      _locale == 'zh'
          ? '结果 $resultCount，进度 $done/$total'
          : 'Results $resultCount, progress $done/$total';
  static String changeSourceSearching(int resultCount) => _locale == 'zh'
      ? '结果 $resultCount，搜索中…'
      : 'Results $resultCount, searching...';

  // ----- 备份探测（backup_inspect_info） -----
  static String backupInspectUnknownFormat(Object? raw) => _locale == 'zh'
      ? 'backupInspect 返回未知的备份格式: $raw'
      : 'backupInspect returned an unknown backup format: $raw';
  static String backupInspectPasswordRequiredNotBool(Object? value) =>
      _locale == 'zh'
          ? 'backupInspect 返回的 passwordRequired 不是布尔值: $value'
          : 'backupInspect passwordRequired is not a boolean: $value';
  static String backupInspectPasswordFilesNotList(Object? value) =>
      _locale == 'zh'
          ? 'backupInspect 返回的 passwordProtectedFiles 不是数组: $value'
          : 'backupInspect passwordProtectedFiles is not an array: $value';
  static String backupInspectPasswordFileNotString(int index, Object? value) =>
      _locale == 'zh'
          ? 'backupInspect 返回的 passwordProtectedFiles 第 $index 项不是字符串: $value'
          : 'backupInspect passwordProtectedFiles item $index is not a string: $value';
  static String backupInspectJsonDecodeFailed(String? message) =>
      _locale == 'zh'
          ? 'backupInspect 返回的 JSON 无法解析: $message'
          : 'backupInspect JSON could not be decoded: $message';
  static String backupInspectJsonNotObject(Object? value) => _locale == 'zh'
      ? 'backupInspect 返回的 JSON 不是对象: $value'
      : 'backupInspect JSON is not an object: $value';

  // ----- 本地书籍导入（rust_api_search_rss.part） -----
  static String get importLocalBookUnknownError =>
      _get('未知导入错误', 'Unknown import error');
  static String get importLocalBookMissingBookData =>
      _get('导入成功但缺少书籍数据', 'Import succeeded but the book data is missing');

  // ----- RSS 宿主桥信封（rss_web_bridge） -----
  static String get rssBridgeEnvelopeInvalidJson =>
      _get('宿主信封不是合法 JSON', 'The host envelope is not valid JSON');
  static String get rssBridgeEnvelopeNotObject =>
      _get('宿主信封必须是 JSON 对象', 'The host envelope must be a JSON object');

  // ----- 字体导入（app_font_notifier） -----
  static String get appFontImportFailedRetry =>
      _get('字体导入失败，请重试', 'Font import failed. Please try again');

  // ----- 搜索范围（search_notifier） -----
  static String get searchNoValidSourcesInScope => _get(
      '所选筛选范围内无有效书源，请调整筛选条件',
      'No valid sources in the selected scope; adjust the filters');

  // ----- 段评（review_detail_sheet） -----
  static String reviewSectionTitle(int count) =>
      _locale == 'zh' ? '段评 · $count' : 'Comments · $count';

  // ----- RSS 登录脚本（rss_source_login） -----
  static String get rssLoginInvalidEnvelope => _get(
      'RSS 登录脚本返回非法信封',
      'The RSS login script returned an invalid envelope');
  static String get rssLoginScriptFailed =>
      _get('登录脚本执行失败', 'The login script failed');

  // ----- WebDAV 远端列目录（webdav_backup_candidates） -----
  static String get webdavListDirNotArray => _get(
      'webdavListDir 返回的不是数组', 'webdavListDir did not return an array');

  // ----- 书源打开浏览器拦截（source_browser_block） -----
  static String get sourceBrowserBlocked => _get(
      '已阻止书源打开浏览器', 'Blocked the source from opening a browser');

  // ----- 书签导出（bookmark_export） -----
  static String get bookmarkExportPickDirectory =>
      _get('选择书签导出目录', 'Choose the bookmark export folder');

  // ----- 漫画目录（manga_catalog_sheet） -----
  static String mangaCatalogTitle(int count) =>
      _locale == 'zh' ? '目录($count)' : 'Contents ($count)';

  // ----- 字体预览（font_screen） -----
  static String get fontPreviewBody => _get(
      '天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。\n'
          'The quick brown fox jumps over the lazy dog. 0123456789',
      'The quick brown fox jumps over the lazy dog. 0123456789');

  // ----- 旧规则迁移失败（txt_toc_rules / dict） -----
  static String txtTocRulesMigrateFailed(String error) => _locale == 'zh'
      ? 'TXT 目录规则迁移失败：$error'
      : 'TXT TOC rule migration failed: $error';
  static String dictRulesMigrateFailed(String error) => _locale == 'zh'
      ? '词典规则迁移失败：$error'
      : 'Dictionary rule migration failed: $error';

  // ----- 高亮规则批量删除（highlight_rules_notifier） -----
  static String highlightRuleDeleteNotEffective(String name) => _locale == 'zh'
      ? '$name: 删除未生效'
      : '$name: deletion did not take effect';

  // ----- 标记笔记（book_marking_notifier） -----
  static String get bookMarkingEmptySelection => _get(
      '选中文本为空，无法保存笔记',
      'The selected text is empty; cannot save the note');

  // ----- 订阅内容解析（rule_sub_screen） -----
  static String get ruleSubContentNotJson =>
      _get('订阅内容不是 JSON 数组或对象', 'The subscription content is not JSON');

  // ----- 主导航页签（main_tab） -----
  static String get mainTabHome => _get('首页', 'Home');

  // ----- 恢复/备份忽略项标题（settings_service / restore_ignore_dialog） -----
  static List<String> get restoreIgnoreTitles => [
        _get('阅读界面配置', 'Reader display settings'),
        _get('主题模式', 'Theme mode'),
        _get('主题配置', 'Theme config'),
        _get('封面规则', 'Cover rules'),
        _get('书架布局', 'Bookshelf layout'),
        _get('显示订阅', 'Show RSS'),
        _get('线程数', 'Thread count'),
        _get('本地书籍', 'Local books'),
      ];
}
