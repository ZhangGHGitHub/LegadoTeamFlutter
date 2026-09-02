// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiReaderData mixin：书签 / 替换规则 / 阅读器 / 配置 / 词典 / 备份 / 阅读记录。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiReaderData on MockBookApiStore implements BookApi {
  // ========== 书签操作 ==========

  @override
  Future<List<Bookmark>> getBookmarks(String bookName) async =>
      _bookmarks.where((b) => b.bookName == bookName).toList();

  /// 按书名+作者获取书签（契约 §2.7，台账 §5.14-2，Task #65）
  ///
  /// Mock：短延迟后返回内存书签按 bookName + bookAuthor 双键过滤结果，
  /// 无命中返回空列表（对齐原版 bookmarkDao.getByBook） — Qoder
  @override
  Future<List<Bookmark>> getBookmarksByBook(
    String bookName,
    String bookAuthor,
  ) async {
    await Future.delayed(const Duration(milliseconds: 50));
    return _bookmarks
        .where((b) => b.bookName == bookName && b.bookAuthor == bookAuthor)
        .toList();
  }

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
  Future<List<Bookmark>> searchBookmarks(String keyword) async => _bookmarks
      .where((b) => b.content.contains(keyword) || b.bookText.contains(keyword))
      .toList();

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
    if (idx >= 0) {
      _replaceRules[idx] = _replaceRules[idx].copyWith(isEnabled: enabled);
    }
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
  Future<String> getChapterContentRaw(String bookUrl, int chapterIndex) async {
    // Mock 层不区分净化/raw，返回同一份缓存内容
    return _contentCache[bookUrl]?[chapterIndex] ?? '（暂无内容）';
  }

  @override
  Future<String> getChapterContentFull(String bookUrl, int chapterIndex) async {
    // Mock 层不区分本地/在线，统一返回缓存内容
    return _contentCache[bookUrl]?[chapterIndex] ?? '（Mock 模式：章节内容）';
  }

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return '（Mock 模式：网络章节内容）\n\n这是从网络获取的章节正文。';
  }

  // [Service-fix v2.0.3 | 2026-08-08] 写入/覆盖单章缓存正文（Mock：
  // 回写 _contentCache，后续 getChapterContent* 读到新内容） — QoderCN
  @override
  Future<bool> saveChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required String title,
    required String content,
  }) async {
    _contentCache.putIfAbsent(bookUrl, () => <int, String>{})[chapterIndex] =
        content;
    return true;
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
  Future<List<BookChapter>> refreshToc(
    String bookUrl,
    String sourceUrl,
  ) async => _chaptersCache[bookUrl] ?? [];

  /// 繁简转换类型 Mock 持久化键（与 Rust 侧配置键同名）
  static const _chineseConvertKey = 'chineseConverterType';

  @override
  Future<void> setChineseConvertType(int type) async {
    // 非法取值归一为 0，与 Rust 侧语义对齐
    final normalized = (type >= 0 && type <= 2) ? type : 0;
    _configs[_chineseConvertKey] = normalized.toString();
  }

  @override
  Future<int> getChineseConvertType() async {
    return int.tryParse(_configs[_chineseConvertKey] ?? '') ?? 0;
  }

  /// 章级「删除重复标题」opt-out 记录（契约 §2.9.10，Task #50）
  ///
  /// Mock 内存态：集合内存放「保留原标题」的 `${bookUrl}#$chapterIndex`。
  final Set<String> _sameTitleOptOut = {};

  @override
  Future<void> toggleSameTitleRemoved(
    String bookUrl,
    int chapterIndex,
    bool enable,
  ) async {
    // Mock：短延迟模拟 FFI 往返；enable=true 恢复全局默认，false 章级 opt-out
    await Future.delayed(const Duration(milliseconds: 50));
    final key = '$bookUrl#$chapterIndex';
    if (enable) {
      _sameTitleOptOut.remove(key);
    } else {
      _sameTitleOptOut.add(key);
    }
  }

  @override
  Future<bool> getSameTitleRemoved(String bookUrl, int chapterIndex) async {
    return !_sameTitleOptOut.contains('$bookUrl#$chapterIndex');
  }

  @override
  Future<bool> canRemoveSameTitle(
    String chapterTitle,
    String rawContent,
  ) async {
    if (chapterTitle.isEmpty || rawContent.isEmpty) return false;
    return rawContent.trimLeft().startsWith(chapterTitle);
  }

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

  // ========== 词典操作 ==========

  /// 内置 Mock 词典（占位数据，字段对齐 Rust `DictEntry`）
  static const _mockDict = <String, Map<String, dynamic>>{
    'chapter': {
      'word': 'chapter',
      'phonetic': '/ˈtʃæptə(r)/',
      'definitions': ['n. 章，章节', 'n. （人生的）一段时期'],
    },
    'novel': {
      'word': 'novel',
      'phonetic': '/ˈnɒvl/',
      'definitions': ['n. 长篇小说', 'adj. 新奇的，异常的'],
    },
    'library': {
      'word': 'library',
      'phonetic': '/ˈlaɪbrəri/',
      'definitions': ['n. 图书馆，藏书室', 'n. 文库，（软件）库'],
    },
  };

  @override
  Future<Map<String, dynamic>> dictLookup(String word) async {
    // 模拟查询延迟
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final key = word.trim().toLowerCase();
    final hit = _mockDict[key];
    if (hit != null) return hit;
    // 未收录词：返回空 definitions（非异常，对齐契约）
    return {'word': key, 'phonetic': '', 'definitions': <String>[]};
  }

  // ========== 备份操作 ==========

  @override
  Future<String> backup(String dirPath) async {
    return '$dirPath/legado_backup_mock.json';
  }

  @override
  Future<void> restore(String backupPath) async {}

  @override
  Future<List<String>> backupList(String dir) async => [];

  @override
  Future<String> importOldData(String dirPath) async {
    return jsonEncode({
      'books': 0,
      'bookSources': 0,
      'replaceRules': 0,
      'messages': <String>['mock: 未找到旧版备份文件'],
    });
  }

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

  @override
  Future<List<Map<String, dynamic>>> readRecordDailyList(int year) async => const [];
}
