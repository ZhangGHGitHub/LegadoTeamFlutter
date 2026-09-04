/// 简单的国际化字符串管理
class AppStrings {
  static String _locale = 'zh'; // zh 或 en

  static void setLocale(String locale) {
    _locale = locale;
  }

  static String get locale => _locale;

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

  // 听书
  static String get audioPlayer => _get('听书', 'Audio');
  static String get play => _get('播放', 'Play');
  static String get pause => _get('暂停', 'Pause');
  static String get prevChapterAudio => _get('上一章', 'Previous');
  static String get nextChapterAudio => _get('下一章', 'Next');
}
