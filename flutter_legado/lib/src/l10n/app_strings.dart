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
  static String get emptyBookshelfHint =>
      _get('', '');
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
  static String get confirmDeleteBook =>
      _get('确定要从书架中删除', 'Are you sure you want to delete');
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
      ? '批量下载 $count 本（对标原版批量下载）'
      : 'Batch download $count book(s)';

  static String moveGroupCount(int count) => _locale == 'zh'
      ? '移动分组 $count 本（对标原版 GroupSelectSheet）'
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
  static String get readingSettings => _get('阅读设置', 'Reading');
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
  static String get advancedEntry => _get('高级', 'Other Settings');
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
  static String get configuredCountPlaceholder => _get('', '');

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
      _get('独立 MCP 服务端口（对齐原版默认 1236）；', 'Standalone MCP service port (default 1236 as upstream);');
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

  static String checkItemsSummary(String items) =>
      _locale == 'zh' ? '校验$items' : 'Check $items';

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
}
