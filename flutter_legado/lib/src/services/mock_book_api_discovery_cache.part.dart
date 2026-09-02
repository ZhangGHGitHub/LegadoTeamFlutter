// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiDiscoveryCache mixin：RSS 收藏 / 分组 / 搜索历史 / 缓存 / 章节购买 / WebBook / 发现页。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiDiscoveryCache on MockBookApiStore implements BookApi {
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

  @override
  Future<bool> bookGroupSetShow(int groupId, bool show) async => true;

  // ========== 搜索历史 ==========

  @override
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50}) async =>
      _searchHistory.take(limit).toList();

  @override
  Future<List<String>> searchHistoryByPrefix(
    String prefix, {
    int limit = 20,
  }) async {
    return _searchHistory
        .where((k) => k.word.startsWith(prefix))
        .take(limit)
        .map((k) => k.word)
        .toList();
  }

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
  Future<int> clearBookCache(String bookUrl) async => 0;

  @override
  Future<int> getCacheBookCount() async => 3;

  @override
  Future<int> getCacheChapterCount() async => 30;

  @override
  Future<void> clearCacheBefore(int beforeTimestampMs) async {}

  /// 压缩数据库（契约 §2.16.6，Task #50）
  ///
  /// Mock：短延迟模拟 VACUUM 耗时，固定返回 10MB 释放量。
  @override
  Future<int> shrinkDatabase() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return 10 * 1024 * 1024;
  }

  @override
  Future<String> getCachedChapter(String bookUrl, int chapterIndex) async =>
      '（mock 缓存正文：$bookUrl 第 $chapterIndex 章）';

  // [UI-fix v2.0.6 | 2026-08-08] Task #22：mock 返回空集（目录页云图标均未缓存态） — Qoder
  @override
  Future<List<String>> listCachedChapterUrls(String bookUrl) async =>
      const <String>[];

  @override
  Future<int> cacheDownloadStart(
    String bookUrl,
    int startChapter,
    int endChapter,
  ) async => 1;

  @override
  Future<String> cacheDownloadProgress(int taskId) async =>
      '{"taskId":$taskId,"status":"completed","total":0,"completed":0,"failed":0}';

  @override
  Future<bool> cacheDownloadCancel(int taskId) async => true;

  @override
  Future<String> cacheDownloadList() async => '[]';

  // ========== 章节购买 ==========

  @override
  Future<({String kind, String value})> chapterPayAction({
    required String bookUrl,
    required int chapterIndex,
  }) async => (kind: 'none', value: '');

  @override
  Future<Map<String, dynamic>> sourceCallBackBtn({
    required String event,
    required String bookUrl,
    int? chapterIndex,
    String? result,
    int bookType = 0,
  }) async => {
    'invoked': false,
    'jsTrue': false,
    'raw': '',
    'actions': <dynamic>[],
  };

  // ========== WebBook 操作 ==========

  @override
  Future<String> webbookSearch(
    String sourceJson,
    String query,
    int page,
  ) async => jsonEncode([]);

  @override
  Future<String> webbookInfo(String sourceJson, String bookUrl) async =>
      jsonEncode({'name': 'Mock书籍', 'author': 'Mock作者'});

  @override
  Future<String> webbookChapters(
    String sourceJson,
    String bookUrl, {
    String tocUrl = '',
    String bookName = '',
  }) async => jsonEncode([]);

  @override
  Future<String> webbookContent(String sourceJson, String chapterJson) async =>
      '（Mock 章节内容）';

  @override
  Stream<Map<String, dynamic>> debugBookSourceStream(
    String sourceUrl,
    String key,
  ) async* {
    yield {'state': 1, 'msg': '[00:00.000] ⇒开始搜索关键字:$key'};
    yield {'state': 1, 'msg': '[00:00.010] 书源 URL: $sourceUrl'};
    yield {'state': 1000, 'msg': '[00:00.020] ︽Mock 调试完成'};
  }

  @override
  Future<void> cancelDebugBookSource() async {}

  // ========== 发现页操作 ==========

  @override
  Future<List<ExploreCategory>> exploreParseUrl(
    String exploreUrl, {
    String sourceJson = '',
  }) async {
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
        coverUrl: 'https://www.biquge.com.cn/files/article/image/${i + 1}.jpg',
        intro: '发现页书籍简介',
        origin: 'https://www.biquge.com.cn',
        originName: '笔趣阁',
        latestChapterTitle: '最新章节',
      );
    });
  }

  final Map<String, Map<String, String>> _exploreInfoMaps = {};

  @override
  Future<void> exploreInfoMapPut(
    String sourceUrl,
    String key,
    String value,
  ) async {
    _exploreInfoMaps.putIfAbsent(sourceUrl, () => {})[key] = value;
  }

  @override
  Future<void> exploreInfoMapEnsureDefault(
    String sourceUrl,
    String key,
    String defaultValue,
  ) async {
    final map = _exploreInfoMaps.putIfAbsent(sourceUrl, () => {});
    map.putIfAbsent(key, () => defaultValue);
  }

  @override
  Future<String> exploreInfoMapSnapshot(String sourceUrl) async =>
      jsonEncode(_exploreInfoMaps[sourceUrl] ?? const <String, String>{});

  @override
  Future<Map<String, dynamic>> exploreEvalAction({
    required String sourceJson,
    required String actionJs,
  }) async {
    return {
      'raw': '',
      'actions': <dynamic>[],
      'refreshExplore': actionJs.contains('refreshExplore'),
    };
  }

  @override
  Future<String> exploreEvalUiJs({
    required String sourceJson,
    required String jsStr,
  }) async => jsStr;
}
