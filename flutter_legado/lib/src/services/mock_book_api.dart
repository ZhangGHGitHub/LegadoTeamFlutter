import 'dart:convert';

import '../models/models.dart';
import 'book_api.dart';
import 'rust_api.dart';

/// Mock 书籍 API 实现
///
/// 纯 Dart 实现，无需 Rust DLL，供 UI 轨开发使用。
/// 所有数据存储在内存中，会话内可读写。
/// 用法：`flutter run -d windows --dart-define=USE_MOCK=true`
class MockBookApi implements BookApi {
  // ========== 内存数据存储 ==========

  final List<Book> _books = [];
  final List<BookSource> _sources = [];
  final List<RssSource> _rssSources = [];
  final List<Bookmark> _bookmarks = [];
  final List<ReplaceRule> _replaceRules = [];
  final List<BookGroup> _bookGroups = [];
  final List<SearchKeyword> _searchHistory = [];
  final List<ReadRecord> _readRecords = [];
  final List<RssStar> _rssStars = [];
  final List<HttpTts> _httpTtsList = [];
  final Map<String, String> _configs = {};
  final Map<String, List<BookChapter>> _chaptersCache = {};
  final Map<String, Map<int, String>> _contentCache = {};

  int _nextId = 1;

  MockBookApi() {
    _initMockData();
  }

  /// 初始化 Mock 数据
  void _initMockData() {
    // 3 本假书
    _books.addAll([
      Book(
        bookUrl: 'mock://book/1',
        name: '斗破苍穹',
        author: '天蚕土豆',
        coverUrl: 'https://via.placeholder.com/150x200?text=Book1',
        intro: '讲述了天才少年萧炎在创造了家族史上空前绝后的修炼纪录后突然成了废人，在药老的帮助下一步步走向巅峰的故事。',
        latestChapterTitle: '第一千六百四十八章 大结局',
        order: 0,
        group: 0,
        origin: 'mock://source/1',
        originName: '笔趣阁',
      ),
      Book(
        bookUrl: 'mock://book/2',
        name: '凡人修仙传',
        author: '忘语',
        coverUrl: 'https://via.placeholder.com/150x200?text=Book2',
        intro: '一个普通山村少年，偶然下进入了当地江湖小门派，成了一名记名弟子，从而踏上了漫漫的修仙之路。',
        latestChapterTitle: '第七百七十四章 飞升',
        order: 1,
        group: 0,
        origin: 'mock://source/2',
        originName: '起点中文网',
      ),
      Book(
        bookUrl: 'mock://book/3',
        name: '三体',
        author: '刘慈欣',
        coverUrl: null,
        intro: '文化大革命如火如荼进行的同时，军方探寻外星文明的绝秘计划"红岸工程"取得了突破性进展。',
        latestChapterTitle: '第三部 死神永生',
        order: 2,
        group: 1,
        origin: 'mock://source/3',
        originName: '科幻世界',
      ),
    ]);

    // 每本书 10 章假内容
    for (var i = 0; i < 3; i++) {
      final bookUrl = 'mock://book/${i + 1}';
      final chapters = <BookChapter>[];
      final contents = <int, String>{};
      for (var j = 0; j < 10; j++) {
        chapters.add(BookChapter(
          title: '第${j + 1}章 ${_mockChapterTitles[j]}',
          bookUrl: bookUrl,
          url: 'mock://chapter/$bookUrl/$j',
          index: j,
          start: j * 2000,
          end: (j + 1) * 2000,
        ));
        contents[j] = _generateMockContent(i, j);
      }
      _chaptersCache[bookUrl] = chapters;
      _contentCache[bookUrl] = contents;
    }

    // 3 个假书源
    _sources.addAll([
      BookSource(
        bookSourceUrl: 'mock://source/1',
        bookSourceName: '笔趣阁',
        bookSourceType: 0,
        enabled: true,
        exploreUrl: '玄幻::https://example.com/xuanhuan\n都市::https://example.com/dushi\n科幻::https://example.com/kehuan',
        customOrder: 0,
      ),
      BookSource(
        bookSourceUrl: 'mock://source/2',
        bookSourceName: '起点中文网',
        bookSourceType: 0,
        enabled: true,
        exploreUrl: '热门::https://example.com/hot\n新书::https://example.com/new',
        customOrder: 1,
      ),
      BookSource(
        bookSourceUrl: 'mock://source/3',
        bookSourceName: '科幻世界',
        bookSourceType: 0,
        enabled: false,
        exploreUrl: '',
        customOrder: 2,
      ),
    ]);

    // 2 个假 RSS 订阅源
    _rssSources.addAll([
      RssSource(
        sourceUrl: 'mock://rss/1',
        sourceName: '科技新闻',
        sourceIcon: 'https://via.placeholder.com/48?text=RSS1',
        enabled: true,
        customOrder: 0,
      ),
      RssSource(
        sourceUrl: 'mock://rss/2',
        sourceName: '文学周刊',
        sourceIcon: 'https://via.placeholder.com/48?text=RSS2',
        enabled: true,
        customOrder: 1,
      ),
    ]);

    // 默认分组
    _bookGroups.add(BookGroup(
      groupId: 1,
      groupName: '科幻',
      order: 0,
      show: true,
    ));
  }

  static const _mockChapterTitles = [
    '初入江湖',
    '风云际会',
    '暗流涌动',
    '绝地反击',
    '峰回路转',
    '真相大白',
    '生死一线',
    '破茧成蝶',
    '天下大势',
    '尘埃落定',
  ];

  /// 生成 Mock 章节正文（足够排版引擎分页）
  String _generateMockContent(int bookIndex, int chapterIndex) {
    final paragraphs = <String>[];
    final bookName = _books[bookIndex].name;
    paragraphs.add('    这是《$bookName》第${chapterIndex + 1}章的正文内容。');
    for (var i = 0; i < 15; i++) {
      paragraphs.add(
        '    第${i + 1}段：修炼之路漫漫其修远兮，吾将上下而求索。'
        '天地之间，灵气充沛，万物生长。'
        '少年立于山巅，俯瞰苍茫大地，心中豪情万丈。'
        '远处的云海翻涌如潮，金色的阳光穿透云层洒落人间。'
        '他深吸一口气，感受着体内真气的流转，每一步都踏得坚实有力。',
      );
    }
    return paragraphs.join('\n\n');
  }

  // ========== 初始化/版本 ==========

  @override
  Future<void> initialize() async {
    // Mock 模式无需初始化
  }

  @override
  Future<String> getVersion() async => 'mock-1.0.0';

  // ========== 书架操作 ==========

  @override
  Future<List<Book>> getBooks() async => List.from(_books);

  @override
  Future<Book> addBook(Book book) async {
    _books.add(book);
    return book;
  }

  @override
  Future<void> updateBook(Book book) async {
    final idx = _books.indexWhere((b) => b.bookUrl == book.bookUrl);
    if (idx >= 0) _books[idx] = book;
  }

  @override
  Future<void> deleteBook(String bookUrl) async {
    _books.removeWhere((b) => b.bookUrl == bookUrl);
  }

  @override
  Future<Book?> getBook(String bookUrl) async {
    try {
      return _books.firstWhere((b) => b.bookUrl == bookUrl);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> topBook(String bookUrl) async {
    final idx = _books.indexWhere((b) => b.bookUrl == bookUrl);
    if (idx >= 0) _books[idx] = _books[idx].copyWith(order: -1);
  }

  @override
  Future<void> unTopBook(String bookUrl) async {
    final idx = _books.indexWhere((b) => b.bookUrl == bookUrl);
    if (idx >= 0) _books[idx] = _books[idx].copyWith(order: 0);
  }

  @override
  Future<void> setBookGroup(String bookUrl, int groupId) async {
    final idx = _books.indexWhere((b) => b.bookUrl == bookUrl);
    if (idx >= 0) _books[idx] = _books[idx].copyWith(group: groupId);
  }

  // ========== 书源操作 ==========

  @override
  Future<List<BookSource>> getBookSources() async => List.from(_sources);

  @override
  Future<List<BookSource>> getEnabledBookSources() async =>
      _sources.where((s) => s.enabled).toList();

  @override
  Future<BookSource> addBookSource(BookSource source) async {
    _sources.add(source);
    return source;
  }

  @override
  Future<void> updateBookSource(BookSource source) async {
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == source.bookSourceUrl);
    if (idx >= 0) _sources[idx] = source;
  }

  @override
  Future<void> deleteBookSource(String sourceUrl) async {
    _sources.removeWhere((s) => s.bookSourceUrl == sourceUrl);
  }

  @override
  Future<void> enableBookSource(String sourceUrl) async {
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == sourceUrl);
    if (idx >= 0) _sources[idx] = _sources[idx].copyWith(enabled: true);
  }

  @override
  Future<void> disableBookSource(String sourceUrl) async {
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == sourceUrl);
    if (idx >= 0) _sources[idx] = _sources[idx].copyWith(enabled: false);
  }

  @override
  Future<int> importBookSources(String jsonArray) async {
    final list = jsonDecode(jsonArray) as List<dynamic>;
    return list.length;
  }

  @override
  Future<String> exportBookSources() async =>
      jsonEncode(_sources.map((s) => s.toJson()).toList());

  @override
  Future<void> sortBookSources(int sortKey, bool ascending) async {
    _configs['source_sort_key'] = sortKey.toString();
    _configs['source_sort_ascending'] = ascending.toString();
  }

  // ========== 搜索操作 ==========

  @override
  Future<List<SearchResult>> searchBooks(
    String keyword, {
    List<String>? sourceUrls,
  }) async {
    // 固定返回 5 条假结果
    return List.generate(5, (i) {
      return SearchResult(
        sourceName: '书源${i + 1}',
        book: Book(
          bookUrl: 'mock://search/$keyword/$i',
          name: '$keyword 相关书籍${i + 1}',
          author: '作者${i + 1}',
          coverUrl: 'https://via.placeholder.com/150x200?text=S${i + 1}',
          intro: '这是搜索"$keyword"的第${i + 1}条结果简介。',
          latestChapterTitle: '最新章节',
          origin: 'mock://source/${i + 1}',
          originName: '书源${i + 1}',
        ),
      );
    });
  }

  @override
  Future<List<Map<String, dynamic>>> searchMulti(
    String query, {
    List<String>? sourceUrls,
  }) async {
    return List.generate(3, (i) => {
      'source': '书源${i + 1}',
      'count': 5,
      'results': <Map<String, dynamic>>[],
    });
  }

  @override
  Future<void> cancelSearch() async {}

  @override
  Future<List<Map<String, dynamic>>> searchSource(
    String bookName,
    String author,
  ) async {
    return List.generate(3, (i) => {
      'sourceUrl': 'mock://source/${i + 1}',
      'sourceName': '书源${i + 1}',
      'bookUrl': 'mock://switch/$bookName/$i',
      'matchScore': 90 - i * 10,
    });
  }

  @override
  Future<String> switchSource(
    String bookUrl,
    String newSourceUrl,
    String newBookUrl,
  ) async {
    return newBookUrl;
  }

  // ========== RSS 源操作 ==========

  @override
  Future<List<RssSource>> getRssSources() async => List.from(_rssSources);

  @override
  Future<RssSource> addRssSource(RssSource source) async {
    _rssSources.add(source);
    return source;
  }

  @override
  Future<void> updateRssSource(RssSource source) async {
    final idx = _rssSources.indexWhere((s) => s.sourceUrl == source.sourceUrl);
    if (idx >= 0) _rssSources[idx] = source;
  }

  @override
  Future<void> deleteRssSource(String sourceUrl) async {
    _rssSources.removeWhere((s) => s.sourceUrl == sourceUrl);
  }

  @override
  Future<void> enableRssSource(String sourceUrl) async {
    final idx = _rssSources.indexWhere((s) => s.sourceUrl == sourceUrl);
    if (idx >= 0) _rssSources[idx] = _rssSources[idx].copyWith(enabled: true);
  }

  @override
  Future<void> disableRssSource(String sourceUrl) async {
    final idx = _rssSources.indexWhere((s) => s.sourceUrl == sourceUrl);
    if (idx >= 0) _rssSources[idx] = _rssSources[idx].copyWith(enabled: false);
  }

  @override
  Future<int> importRssSources(String jsonArray) async {
    final list = jsonDecode(jsonArray) as List<dynamic>;
    return list.length;
  }

  @override
  Future<String> exportRssSources() async =>
      jsonEncode(_rssSources.map((s) => s.toJson()).toList());

  @override
  Future<List<RssFeedArticle>> getRssArticles(String sourceUrl) async {
    // 每源 5 篇假文章
    return List.generate(5, (i) {
      return RssFeedArticle(
        title: '文章标题 ${i + 1} - ${sourceUrl.contains('1') ? '科技' : '文学'}',
        url: 'mock://rss/article/$sourceUrl/$i',
        description: '这是第${i + 1}篇文章的摘要描述。',
        pubDate: DateTime.now().subtract(Duration(days: i)).toIso8601String(),
        imageUrl: 'https://via.placeholder.com/300x150?text=Article${i + 1}',
        content: '<p>这是第${i + 1}篇文章的正文内容。</p>' * 5,
      );
    });
  }

  // ========== 本地书籍操作 ==========

  @override
  Future<Book> importLocalBook(String filePath) async {
    final book = Book(
      bookUrl: 'file://$filePath',
      name: filePath.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'\.\w+$'), ''),
      author: '本地导入',
      bookType: BookType.local,
    );
    _books.add(book);
    return book;
  }

  @override
  Future<List<Map<String, dynamic>>> scanLocalBooks(String dirPath) async {
    return [
      {'path': '$dirPath/book1.txt', 'name': 'book1.txt', 'size': 102400, 'lastModified': DateTime.now().toIso8601String()},
      {'path': '$dirPath/book2.epub', 'name': 'book2.epub', 'size': 2048000, 'lastModified': DateTime.now().toIso8601String()},
    ];
  }

  @override
  Future<String> detectFormat(String filePath) async {
    if (filePath.endsWith('.epub')) return 'epub';
    if (filePath.endsWith('.pdf')) return 'pdf';
    return 'txt';
  }

  @override
  Future<String> parseMetadata(String filePath) async {
    return jsonEncode({'title': '未知书籍', 'author': '未知作者', 'format': 'txt'});
  }

  // ========== 书签操作 ==========

  @override
  Future<List<Bookmark>> getBookmarks(String bookName) async =>
      _bookmarks.where((b) => b.bookName == bookName).toList();

  @override
  Future<List<Bookmark>> getAllBookmarks() async => List.from(_bookmarks);

  @override
  Future<Bookmark> addBookmark(Bookmark bookmark) async {
    final bm = bookmark.copyWith(id: _nextId++);
    _bookmarks.add(bm);
    return bm;
  }

  @override
  Future<void> updateBookmark(Bookmark bookmark) async {
    final idx = _bookmarks.indexWhere((b) => b.id == bookmark.id);
    if (idx >= 0) _bookmarks[idx] = bookmark;
  }

  @override
  Future<void> deleteBookmark(int id) async {
    _bookmarks.removeWhere((b) => b.id == id);
  }

  @override
  Future<List<Bookmark>> searchBookmarks(String keyword) async =>
      _bookmarks.where((b) => b.content.contains(keyword) || b.bookText.contains(keyword)).toList();

  // ========== 替换规则操作 ==========

  @override
  Future<List<ReplaceRule>> getReplaceRules() async => List.from(_replaceRules);

  @override
  Future<List<ReplaceRule>> getEnabledReplaceRules() async =>
      _replaceRules.where((r) => r.isEnabled).toList();

  @override
  Future<ReplaceRule> addReplaceRule(ReplaceRule rule) async {
    final r = rule.copyWith(id: _nextId++);
    _replaceRules.add(r);
    return r;
  }

  @override
  Future<void> updateReplaceRule(ReplaceRule rule) async {
    final idx = _replaceRules.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) _replaceRules[idx] = rule;
  }

  @override
  Future<void> deleteReplaceRule(int id) async {
    _replaceRules.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> setReplaceRuleEnabled(int id, bool enabled) async {
    final idx = _replaceRules.indexWhere((r) => r.id == id);
    if (idx >= 0) _replaceRules[idx] = _replaceRules[idx].copyWith(isEnabled: enabled);
  }

  // ========== 阅读器操作 ==========

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async =>
      _chaptersCache[bookUrl] ?? [];

  @override
  Future<String> getChapterContent(String bookUrl, int chapterIndex) async {
    return _contentCache[bookUrl]?[chapterIndex] ?? '（暂无内容）';
  }

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return '（Mock 模式：网络章节内容）\n\n这是从网络获取的章节正文。';
  }

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {
    final idx = _books.indexWhere((b) => b.bookUrl == bookUrl);
    if (idx >= 0) {
      _books[idx] = _books[idx].copyWith(
        durChapterIndex: chapterIndex,
        durChapterPos: chapterPos,
      );
    }
  }

  @override
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl) async =>
      _chaptersCache[bookUrl] ?? [];

  // ========== 配置操作 ==========

  @override
  Future<String?> getConfig(String key) async => _configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    _configs[key] = value;
  }

  @override
  Future<void> deleteConfig(String key) async {
    _configs.remove(key);
  }

  @override
  Future<Map<String, String>> getAllConfigs() async => Map.from(_configs);

  // ========== 备份操作 ==========

  @override
  Future<String> backup(String dirPath) async {
    return '$dirPath/legado_backup_mock.json';
  }

  @override
  Future<void> restore(String backupPath) async {}

  // ========== 阅读记录 ==========

  @override
  Future<List<ReadRecord>> getReadRecords() async => List.from(_readRecords);

  @override
  Future<void> putReadRecord(ReadRecord record) async {
    _readRecords.removeWhere((r) => r.bookName == record.bookName);
    _readRecords.add(record);
  }

  @override
  Future<void> deleteReadRecord(String bookName) async {
    _readRecords.removeWhere((r) => r.bookName == bookName);
  }

  @override
  Future<void> clearReadRecords() async {
    _readRecords.clear();
  }

  // ========== RSS 收藏操作 ==========

  @override
  Future<List<RssStar>> getRssStars() async => List.from(_rssStars);

  @override
  Future<RssStar> addRssStar(RssStar star) async {
    _rssStars.add(star);
    return star;
  }

  @override
  Future<void> deleteRssStar(String link) async {
    _rssStars.removeWhere((s) => s.link == link);
  }

  @override
  Future<bool> isStarred(String link) async =>
      _rssStars.any((s) => s.link == link);

  // ========== 书籍分组 ==========

  @override
  Future<List<BookGroup>> getBookGroups() async => List.from(_bookGroups);

  @override
  Future<BookGroup> addBookGroup(BookGroup group) async {
    final g = group.copyWith(groupId: _nextId++);
    _bookGroups.add(g);
    return g;
  }

  @override
  Future<void> updateBookGroup(BookGroup group) async {
    final idx = _bookGroups.indexWhere((g) => g.groupId == group.groupId);
    if (idx >= 0) _bookGroups[idx] = group;
  }

  @override
  Future<void> deleteBookGroup(int groupId) async {
    _bookGroups.removeWhere((g) => g.groupId == groupId);
  }

  // ========== 搜索历史 ==========

  @override
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50}) async =>
      _searchHistory.take(limit).toList();

  @override
  Future<void> addSearchKeyword(String keyword, String bookName) async {
    _searchHistory.insert(0, SearchKeyword(word: keyword));
  }

  @override
  Future<void> deleteSearchKeyword(String keyword) async {
    _searchHistory.removeWhere((k) => k.word == keyword);
  }

  @override
  Future<void> clearSearchHistory() async {
    _searchHistory.clear();
  }

  // ========== 缓存管理 ==========

  @override
  Future<int> getCacheSize() async => 1024 * 1024 * 50; // 50MB

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheBookCount() async => 3;

  @override
  Future<int> getCacheChapterCount() async => 30;

  @override
  Future<void> clearCacheBefore(int beforeTimestampMs) async {}

  // ========== WebBook 操作 ==========

  @override
  Future<String> webbookSearch(String sourceJson, String query, int page) async =>
      jsonEncode([]);

  @override
  Future<String> webbookInfo(String sourceJson, String bookUrl) async =>
      jsonEncode({'name': 'Mock书籍', 'author': 'Mock作者'});

  @override
  Future<String> webbookChapters(String sourceJson, String bookUrl) async =>
      jsonEncode([]);

  @override
  Future<String> webbookContent(String sourceJson, String chapterJson) async =>
      '（Mock 章节内容）';

  // ========== 发现页操作 ==========

  @override
  Future<List<ExploreCategory>> exploreParseUrl(String exploreUrl) async {
    if (exploreUrl.isEmpty) return [];
    return exploreUrl.split('\n').where((l) => l.contains('::')).map((line) {
      final parts = line.split('::');
      return ExploreCategory(
        title: parts[0].trim(),
        url: parts.length > 1 ? parts[1].trim() : '',
      );
    }).toList();
  }

  @override
  Future<List<SearchBook>> exploreFetchBooks(
    String sourceJson,
    String url,
    int page,
  ) async {
    return List.generate(10, (i) {
      return SearchBook(
        bookUrl: 'mock://explore/$url/$page/$i',
        name: '发现书籍 ${(page - 1) * 10 + i + 1}',
        author: '作者${i + 1}',
        coverUrl: 'https://via.placeholder.com/150x200?text=E$i',
        intro: '发现页书籍简介',
        origin: 'mock://source/1',
        originName: '笔趣阁',
        latestChapterTitle: '最新章节',
      );
    });
  }

  // ========== 规则解析 ==========

  @override
  Future<String> parseRule(String content, String rule, String ruleType) async =>
      content;

  // ========== 网络操作 ==========

  @override
  Future<String> httpGet(String url) async => '{"status": "ok", "mock": true}';

  @override
  Future<String> httpPost(String url, String body) async =>
      '{"status": "ok", "mock": true}';

  // ========== JS 引擎 ==========

  @override
  Future<String> evalJs(String script) async => 'undefined';

  @override
  Future<String> getJsEngineVersion() async => 'mock-quickjs';

  // ========== 服务器管理 ==========

  @override
  Future<void> startServer({int port = 1122}) async {
    _configs['server_port'] = port.toString();
    _configs['server_running'] = 'true';
  }

  @override
  Future<void> stopServer() async {
    _configs['server_running'] = 'false';
  }

  @override
  Future<String> getServerStatus() async {
    if (_configs['server_running'] == 'true') {
      return 'running on port ${_configs['server_port'] ?? '1122'}';
    }
    return 'stopped';
  }

  @override
  Future<void> setServerPort(int port) async {
    _configs['server_port'] = port.toString();
  }

  // ========== 书籍格式解析 ==========

  @override
  Future<List<BookChapter>> parseTxt(String filePath) async {
    return List.generate(5, (i) => BookChapter(
      title: '第${i + 1}章',
      bookUrl: filePath,
      index: i,
      start: i * 1000,
      end: (i + 1) * 1000,
    ));
  }

  @override
  Future<List<BookChapter>> parseEpub(String filePath) async {
    return List.generate(8, (i) => BookChapter(
      title: 'Chapter ${i + 1}',
      bookUrl: filePath,
      index: i,
      start: i * 2000,
      end: (i + 1) * 2000,
    ));
  }

  @override
  Future<String> exportBook(String bookUrl, String format, String outDir) async {
    return '$outDir/export_mock.$format';
  }

  // ========== 阅读统计 ==========

  @override
  Future<ReadingStatsToday> getTodayReadingStats() async {
    return const ReadingStatsToday(
      totalSeconds: 3600,
      bookCount: 2,
      durationSeconds: 3600,
      wordCount: 15000,
      readingSpeed: 250.0,
    );
  }

  @override
  Future<Map<String, int>> getDailyReadingStats({required int days}) async {
    final result = <String, int>{};
    for (var i = 0; i < days; i++) {
      final date = DateTime.now().subtract(Duration(days: i));
      result['${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'] =
          (i + 1) * 600;
    }
    return result;
  }

  @override
  Future<Map<String, int>> getBookReadingStats() async {
    return {
      '斗破苍穹': 7200,
      '凡人修仙传': 5400,
      '三体': 3600,
    };
  }

  @override
  Future<Map<String, int>> getReadingHeatmap({required int days}) async {
    return getDailyReadingStats(days: days);
  }

  @override
  Future<void> recordReadingTime(String bookName, int seconds) async {}

  // ========== HTTP TTS ==========

  @override
  Future<List<HttpTts>> getHttpTts() async => List.from(_httpTtsList);

  @override
  Future<List<HttpTts>> getHttpTtsList() async => getHttpTts();

  @override
  Future<HttpTts> addHttpTts(HttpTts tts) async {
    final t = tts.copyWith(id: _nextId++);
    _httpTtsList.add(t);
    return t;
  }

  @override
  Future<void> updateHttpTts(HttpTts tts) async {
    final idx = _httpTtsList.indexWhere((t) => t.id == tts.id);
    if (idx >= 0) _httpTtsList[idx] = tts;
  }

  @override
  Future<void> deleteHttpTts(int id) async {
    _httpTtsList.removeWhere((t) => t.id == id);
  }

  @override
  Future<int> importHttpTts(String json) async {
    final list = jsonDecode(json) as List<dynamic>;
    return list.length;
  }

  @override
  Future<String> exportHttpTts() async =>
      jsonEncode(_httpTtsList.map((t) => t.toJson()).toList());

  // ========== 音频播放 ==========

  @override
  Future<void> audioSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceName,
  }) async {}

  @override
  Future<Map<String, dynamic>> getAudioChapterMedia(
    String bookUrl,
    int chapterIndex,
  ) async {
    final chapters = await getChapters(bookUrl);
    if (chapterIndex < 0 || chapterIndex >= chapters.length) {
      return {'error': 'Invalid chapter index'};
    }
    return {
      'chapterIndex': chapterIndex,
      'title': chapters[chapterIndex].title,
      'url': chapters[chapterIndex].url,
      'resourceUrl': chapters[chapterIndex].resourceUrl,
    };
  }

  @override
  Future<Map<String, dynamic>?> getAudioProgress(
    String bookUrl,
    int chapterIndex,
  ) async {
    return {'position': 0, 'chapterIndex': chapterIndex};
  }

  @override
  Future<void> saveAudioProgress(
    String bookUrl,
    int chapterIndex,
    int positionMs,
  ) async {}

  // ========== 用户管理 ==========

  @override
  Future<List<Map<String, dynamic>>> getUsers() async => [];

  @override
  Future<int> saveUser({
    required String username,
    required String password,
    required String sourceUrl,
  }) async => _nextId++;

  @override
  Future<bool> deleteUser(String username) async => true;

  @override
  Future<bool> userLogin({
    required String username,
    required String password,
  }) async => true;

  @override
  Future<bool> userLogout(String username) async => true;

  @override
  Future<bool> checkLoginStatus(String username) async => false;

  // ========== WebDAV 云同步 ==========

  @override
  Future<String> webdavListDir(String configJson, String path) async =>
      jsonEncode([]);

  @override
  Future<void> webdavUpload(String configJson, String path, String data) async {}

  @override
  Future<String> webdavDownload(String configJson, String path) async => '';

  @override
  Future<void> webdavDelete(String configJson, String path) async {}

  @override
  Future<String> webdavFullSync(
    String configJson,
    String localBooks,
    String localSources,
  ) async => '{"synced": true}';

  // ========== 下载管理器 ==========

  @override
  Future<String> downloadAddTask({
    required String bookUrl,
    required String chapterUrl,
    required String chapterTitle,
    required int chapterIndex,
    int priority = 0,
  }) async => 'mock-task-${_nextId++}';

  @override
  Future<String> downloadGetStats() async =>
      jsonEncode({'total': 0, 'completed': 0, 'failed': 0, 'pending': 0});

  @override
  Future<String> downloadListByBook(String bookUrl) async => jsonEncode([]);

  @override
  Future<void> downloadPauseAll() async {}

  @override
  Future<void> downloadResumeAll() async {}

  @override
  Future<void> downloadRemoveTask(String taskId) async {}

  @override
  Future<void> downloadUpdateProgress(String taskId, double progress) async {}

  // ========== 段评/章评 ==========

  @override
  Future<String> reviewGetByChapter(String bookUrl, int chapterIndex) async =>
      jsonEncode([]);

  @override
  Future<int> reviewAdd({
    required String bookUrl,
    required int chapterIndex,
    int paragraphIndex = -1,
    required String content,
    String author = '',
  }) async => _nextId++;

  @override
  Future<bool> reviewDelete(int id) async => true;

  @override
  Future<void> reviewLike(int id) async {}

  // ========== 书籍导出 ==========

  @override
  Future<Map<String, dynamic>> bookExport({
    required String bookUrl,
    required String format,
    required bool includeToc,
  }) async {
    final book = await getBook(bookUrl);
    if (book == null) {
      return {'success': false, 'error': '书籍不存在: $bookUrl'};
    }
    return {
      'success': true,
      'file_name': '${book.name}.$format',
      'data_base64': base64Encode(utf8.encode('Mock 导出内容')),
      'mime_type': 'text/plain',
    };
  }

  @override
  Future<Map<String, dynamic>> bookExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    final book = await getBook(bookUrl);
    if (book == null) {
      return {'success': false, 'error': '书籍不存在: $bookUrl'};
    }
    final chapters = await getChapters(bookUrl);
    return {
      'success': true,
      'file_name': '${book.name}.$format',
      'chapter_count': chapters.length.toString(),
    };
  }

  // ========== 自动任务 ==========

  @override
  Future<Map<String, dynamic>> autoTaskBuildBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
    required String name,
  }) async => {
    'id': 'mock-task-${_nextId++}',
    'name': name,
    'bookUrl': bookUrl,
    'bookName': bookName,
    'bookAuthor': bookAuthor,
    'cron': '0 0 8 * * *',
    'enabled': true,
  };

  @override
  Future<List<Map<String, dynamic>>> autoTaskUpdateCronBatch({
    required String rulesJson,
    required String idsJson,
    required String cron,
  }) async {
    final rules = (jsonDecode(rulesJson) as List<dynamic>)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final ids = (jsonDecode(idsJson) as List<dynamic>).map((e) => e.toString()).toList();
    for (final rule in rules) {
      if (ids.contains(rule['id']?.toString())) {
        rule['cron'] = cron;
      }
    }
    return rules;
  }

  @override
  Future<List<Map<String, dynamic>>> autoTaskPrepareImported({
    required String localTasksJson,
    required String importedJson,
  }) async {
    final imported = (jsonDecode(importedJson) as List<dynamic>)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    return imported;
  }

  @override
  Future<Map<String, dynamic>> autoTaskExecute({
    required String protocolJson,
  }) async => {'success': true, 'message': 'Mock 执行成功'};

  @override
  Future<Map<String, dynamic>> autoTaskExecuteWithId({
    required String protocolJson,
    required String taskId,
  }) async => {'success': true, 'taskId': taskId, 'message': 'Mock 执行成功'};

  @override
  Future<String> autoTaskNormalizeScript({required String script}) async {
    if (script.startsWith('@js:')) return script.substring(4);
    return script;
  }

  @override
  Future<bool> autoTaskCanRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  }) async {
    if (!respectCanUpdate) return true;
    return canUpdate;
  }

  @override
  Future<Map<String, dynamic>?> autoTaskFindBookUpdateTask({
    required String tasksJson,
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
  }) async => null;

  @override
  Future<int> autoTaskNextDueAt({
    required String cron,
    required int fromMs,
  }) async => fromMs + 86400000; // +24h

  // ========== 音频播放模式 ==========

  @override
  Future<String> audioWithPlayMode({
    String? readConfig,
    required int playMode,
  }) async {
    final config = readConfig != null && readConfig.isNotEmpty
        ? (jsonDecode(readConfig) as Map<String, dynamic>)
        : <String, dynamic>{};
    config['audioPlayMode'] = playMode;
    return jsonEncode(config);
  }

  @override
  Future<Map<String, dynamic>?> audioResolvePlayBook({
    String? requestedBookUrl,
    String? cachedBookJson,
  }) async {
    if (requestedBookUrl == null || requestedBookUrl.isEmpty) {
      if (cachedBookJson != null && cachedBookJson.isNotEmpty) {
        return jsonDecode(cachedBookJson) as Map<String, dynamic>;
      }
      return null;
    }
    final book = await getBook(requestedBookUrl);
    return book?.toJson();
  }

  // ========== 压缩包导入 ==========

  @override
  Future<Map<String, dynamic>> archiveImportZip({
    required String zipPath,
    required String outputDir,
  }) async => {
    'success': true,
    'imported_count': 2,
    'files': ['book1.txt', 'book2.epub'],
  };

  @override
  Future<Map<String, dynamic>> archiveImportRar({
    required String rarPath,
    required String outputDir,
    String? password,
  }) async => {
    'success': true,
    'imported_count': 1,
    'files': ['book1.txt'],
  };

  @override
  Future<List<String>> archiveListZipFiles({required String zipPath}) async =>
      ['book1.txt', 'book2.epub', 'readme.md'];

  @override
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  }) async => ['novel.txt'];

  @override
  Future<Map<String, dynamic>> archiveDetectEncoding({
    required String filePath,
  }) async => {
    'encoding': 'UTF-8',
    'has_bom': false,
    'confidence': 'high',
  };

  @override
  Future<Map<String, dynamic>> archiveConvertEncoding({
    required String filePath,
    required String fromEncoding,
    required String toEncoding,
  }) async => {
    'success': true,
    'output_path': '$filePath.converted',
  };

  @override
  Future<bool> archiveIsArchive({required String filePath}) async {
    return filePath.endsWith('.zip') ||
        filePath.endsWith('.rar') ||
        filePath.endsWith('.7z');
  }
}
