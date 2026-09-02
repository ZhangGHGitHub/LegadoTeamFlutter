// rust_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 RustApiSearchRss mixin：搜索 / RSS 源 / 本地书籍 / TXT 全文搜索。
// RustApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 解码辅助来自 RustApiDecode（on 约束），同一 library 内私有成员可直接访问。
part of 'rust_api.dart';

mixin RustApiSearchRss on RustApiDecode implements BookApi {
  // ========== 搜索操作 ==========

  /// 搜索书籍
  ///
  /// [sourceUrls] 为空则搜索所有启用的书源。
  @override
  Future<List<SearchResult>> searchBooks(
    String keyword, {
    List<String>? sourceUrls,
  }) async {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    final json = await bridge.searchBooks(
      keyword: keyword,
      sourceUrlsJson: urlsJson,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) {
      final map = e as Map<String, dynamic>;
      return SearchResult.fromSearchBook(
        SearchBook.fromJson(map),
        hasReadRecord: map['hasReadRecord'] == true,
      );
    }).toList();
  }

  /// 精确搜索（对齐原版 `WebBook.preciseSearchAwait`）
  @override
  Future<SearchBook> preciseSearch(
    String name,
    String author, {
    List<String>? sourceUrls,
  }) async {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    final json = await bridge.preciseSearch(
      name: name,
      author: author,
      sourceUrlsJson: urlsJson,
    );
    final map = jsonDecode(json) as Map<String, dynamic>;
    return SearchBook.fromJson(map);
  }

  /// 多源并行搜索
  @override
  Future<List<Map<String, dynamic>>> searchMulti(
    String query, {
    List<String>? sourceUrls,
  }) async {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    final json = await bridge.searchMulti(
      query: query,
      sourceUrlsJson: urlsJson,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  /// 多源渐进式（流式）搜索
  ///
  /// 每完成一个书源即推送一个批次 Map（字段见 [BookApi.searchMultiStream]）。
  /// [page] — 页码透传（批次B G-B-01：同关键词翻页递增、新关键词重置为 1）。
  @override
  Stream<Map<String, dynamic>> searchMultiStream(
    String query, {
    List<String>? sourceUrls,
    int page = 1,
  }) {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    return bridge
        .searchMultiStream(query: query, sourceUrlsJson: urlsJson, page: page)
        .map((batch) => _decodeMap(batch, 'searchMultiStream'));
  }

  /// 取消搜索
  @override
  Future<void> cancelSearch() => bridge.searchCancel();

  /// 暂停正在进行的流式搜索（软挂起，批次B G-B-04）
  @override
  Future<void> pauseSearch() => bridge.searchPause();

  /// 恢复已暂停的流式搜索（批次B G-B-04）
  @override
  Future<void> resumeSearch() => bridge.searchResume();

  /// 搜索可替换的书源
  ///
  /// Rust 侧返回 SourceSwitchResponse { book_name, author, matches }，
  /// 兼容 Map（提取 matches 字段）和 List（直接使用）两种格式。
  /// [UI-fix v2.0.3 | 2026-08-06] 留项#12（Task #131）：新增 sourceUrls 可选参数，
  /// 编码为 sourceUrlsJson 传入 sourceSwitchSearch；null=搜全部启用源（兼容既有语义） — QoderCN
  @override
  Future<List<Map<String, dynamic>>> searchSource(
    String bookName,
    String author, {
    List<String>? sourceUrls,
    bool loadInfo = false,
    bool loadToc = false,
    bool loadWordCount = false,
    bool forceRefresh = false,
  }) async {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    final optionsJson = jsonEncode({
      'loadInfo': loadInfo,
      'loadToc': loadToc,
      'loadWordCount': loadWordCount,
      'forceRefresh': forceRefresh,
    });
    final json = await bridge.sourceSwitchSearch(
      bookName: bookName,
      author: author,
      sourceUrlsJson: urlsJson,
      optionsJson: optionsJson,
    );
    final decoded = jsonDecode(json);
    // Rust 侧返回 SourceSwitchResponse 对象，需提取 matches 字段
    final List<dynamic> list;
    if (decoded is Map<String, dynamic>) {
      list = (decoded['matches'] as List<dynamic>?) ?? [];
    } else if (decoded is List<dynamic>) {
      list = decoded;
    } else {
      list = [];
    }
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 搜索书籍封面候选列表
  ///
  /// Rust 侧复用多书源搜索提取封面 URL，返回 JSON 数组，
  /// 每项字段：`url` / `width` / `height`（未知尺寸填 0）。
  @override
  Future<List<Map<String, dynamic>>> searchCover(String bookName) async {
    final json = await bridge.searchCover(bookName: bookName);
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 切换书源
  @override
  Future<String> switchSource(
    String bookUrl,
    String newSourceUrl,
    String newBookUrl,
  ) => bridge.sourceSwitchApply(
    bookUrl: bookUrl,
    newSourceUrl: newSourceUrl,
    newBookUrl: newBookUrl,
  );

  /// 更新换源列表项用户评分（-1/0/1）
  @override
  Future<void> updateSearchBookScore(String bookUrl, int score) =>
      bridge.updateSearchBookScore(bookUrl: bookUrl, score: score);

  /// 删除换源列表项（按 bookUrl）
  @override
  Future<void> deleteSearchBook(String bookUrl) =>
      bridge.deleteSearchBook(bookUrl: bookUrl);

  // ========== RSS 源操作 ==========

  /// 获取所有 RSS 源
  @override
  Future<List<RssSource>> getRssSources() async {
    final json = await bridge.rssListSources();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => RssSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加 RSS 源
  @override
  Future<RssSource> addRssSource(RssSource source) async {
    final json = await bridge.rssAddSource(
      sourceJson: jsonEncode(source.toJson()),
    );
    return RssSource.fromJson(_decodeMap(json, 'bookApi'));
  }

  /// 更新 RSS 源（专用原子更新 FFI，按 sourceUrl 主键单条 UPDATE）
  ///
  /// 历史误接 sourceUpdate（按 BookSource 语义解析落 book_sources 表，
  /// 产生幽灵书源脏数据且 RSS 变更静默丢失），现已切换 rssUpdateSource。
  /// 源不存在时 Rust 侧报错；若返回载荷为 false（bool 语义兜底）则抛异常。 — QoderCN
  @override
  Future<void> updateRssSource(RssSource source) async {
    final json = await bridge.rssUpdateSource(
      sourceJson: jsonEncode(source.toJson()),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      decoded = json;
    }
    if (decoded == false) {
      throw StateError(
        'updateRssSource: RSS 源不存在（sourceUrl=${source.sourceUrl}）',
      );
    }
  }

  /// 删除 RSS 源
  @override
  Future<void> deleteRssSource(String sourceUrl) =>
      bridge.rssDeleteSource(sourceUrl: sourceUrl);

  /// 启用 RSS 源（复用书源启用接口）
  @override
  Future<void> enableRssSource(String sourceUrl) =>
      bridge.sourceEnable(sourceUrl: sourceUrl);

  /// 禁用 RSS 源（复用书源禁用接口）
  @override
  Future<void> disableRssSource(String sourceUrl) =>
      bridge.sourceDisable(sourceUrl: sourceUrl);

  /// 导入 RSS 源（契约 importRssSources）
  ///
  /// 历史误接 `sourceImport`（写入书源表）。现改为逐条 `rssAddSource`
  /// 全字段落 `rssSources`；待 FRB 生成 `rssImportSources` 后可改为批量 FFI。
  @override
  Future<int> importRssSources(String jsonArray) async {
    final decoded = jsonDecode(jsonArray);
    if (decoded is! List) {
      throw FormatException('importRssSources 期望 JSON 数组');
    }
    var count = 0;
    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      await addRssSource(RssSource.fromJson(map));
      count++;
    }
    return count;
  }

  /// 导出 RSS 源（契约 exportRssSources；勿走书源 sourceExport）
  @override
  Future<String> exportRssSources() async {
    final sources = await getRssSources();
    return jsonEncode(sources.map((s) => s.toJson()).toList());
  }

  /// 获取 RSS 文章列表
  @override
  Future<List<RssFeedArticle>> getRssArticles(String sourceUrl) async {
    final json = await bridge.rssFetchArticles(sourceUrl: sourceUrl);
    final list = _decodeList(json, 'bookApi');
    return list.map((e) {
      final m = e as Map<String, dynamic>;
      return RssFeedArticle(
        title: m['title'] as String? ?? '',
        url: m['link'] as String? ?? m['url'] as String? ?? '',
        description: m['description'] as String?,
        pubDate: m['pubDate'] as String?,
        imageUrl: m['image'] as String? ?? m['imageUrl'] as String?,
        content: m['content'] as String?,
      );
    }).toList();
  }

  /// 清空指定 RSS 源本地文章缓存
  @override
  Future<void> rssClearArticles(String sourceUrl) =>
      bridge.rssClearArticles(sourceUrl: sourceUrl);

  // ========== RSS 已读记录 ==========

  /// 标记 RSS 文章为已读
  @override
  Future<void> rssMarkRead(String origin, String title, [String? link]) =>
      bridge.rssMarkRead(origin: origin, title: title, link: link);

  /// 判断 RSS 文章是否已读（按 link）
  @override
  Future<bool> rssIsRead(String link) => bridge.rssIsRead(link: link);

  /// 判断 RSS 文章是否已读（按 origin + title）
  @override
  Future<bool> rssIsReadByTitle(String origin, String title) =>
      bridge.rssIsReadByTitle(origin: origin, title: title);

  /// 清空所有 RSS 已读记录
  @override
  Future<void> rssClearReadRecords() => bridge.rssClearReadRecords();

  /// 获取 RSS 已读记录总数
  @override
  Future<int> rssReadRecordCount() async =>
      (await bridge.rssReadRecordCount()).toInt();

  /// 获取 RSS 已读记录列表（按 readTime 降序）
  @override
  Future<List<Map<String, dynamic>>> rssListReadRecords([int? limit]) async {
    final json = await bridge.rssListReadRecords(limit: limit);
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> rssListReadRecordsByOrigin(
    String origin, [
    int? limit,
  ]) async {
    final json = await bridge.rssListReadRecordsByOrigin(
      origin: origin,
      limit: limit,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  // ========== 本地书籍操作 ==========

  /// 导入本地书籍
  @override
  Future<Book> importLocalBook(String filePath) async {
    final json = await bridge.importLocalBook(filePath: filePath);
    final result = _decodeMap(json, 'bookApi');
    final success = result['success'] as bool? ?? false;
    if (!success) {
      final error = result['error'] as String? ?? '未知导入错误';
      throw RustApiException(error, operation: 'importLocalBook');
    }
    final bookMap = result['book'] as Map<String, dynamic>?;
    if (bookMap == null) {
      throw RustApiException('导入成功但缺少书籍数据', operation: 'importLocalBook');
    }
    return Book.fromJson(bookMap);
  }

  /// 扫描本地书籍（扫描目录下的常见电子书格式）
  ///
  /// ⚠️ 死代码标注（批次3治理 Task #118）：此 Dart 纯实现 fallback 在全工程
  /// 已无任何调用点（本地导入已走 Rust FFI 管线：detectFormat/parseMetadata/
  /// importLocalBook）。仅为保持 [BookApi] 契约面不变而保留，勿删除；
  /// 后续如需清理须同步 book_api.dart / mock_book_api.dart 声明。
  @override
  Future<List<Map<String, dynamic>>> scanLocalBooks(String dirPath) async {
    const extensions = {'.txt', '.epub', '.mobi', '.pdf', '.azw3'};
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final results = <Map<String, dynamic>>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final ext = entity.path
            .substring(entity.path.lastIndexOf('.'))
            .toLowerCase();
        if (extensions.contains(ext)) {
          final stat = await entity.stat();
          results.add({
            'path': entity.path,
            'name': entity.uri.pathSegments.last,
            'size': stat.size,
            'lastModified': stat.modified.toIso8601String(),
          });
        }
      }
    }
    return results;
  }

  /// 检测书籍文件格式
  @override
  Future<String> detectFormat(String filePath) =>
      bridge.importDetectFormat(filePath: filePath);

  /// 解析书籍元数据
  @override
  Future<String> parseMetadata(String filePath) =>
      bridge.importParseMetadata(filePath: filePath);

  // ========== 本地 TXT 全文搜索（Task #98 缺口#4，加法式新增） ==========

  /// 搜索本地 TXT 文件内容（纯文本模式，章节感知）
  @override
  Future<List<Map<String, dynamic>>> txtSearch(
    String path,
    String query, {
    bool caseSensitive = false,
    int maxResults = 500,
  }) async {
    final json = await bridge.txtSearch(
      path: path,
      query: query,
      caseSensitive: caseSensitive,
      maxResults: maxResults,
    );
    return _decodeSearchResults(json);
  }

  /// 使用正则表达式搜索本地 TXT 文件内容
  @override
  Future<List<Map<String, dynamic>>> txtSearchRegex(
    String path,
    String pattern, {
    bool caseSensitive = false,
    int maxResults = 500,
  }) async {
    final json = await bridge.txtSearchRegex(
      path: path,
      pattern: pattern,
      caseSensitive: caseSensitive,
      maxResults: maxResults,
    );
    return _decodeSearchResults(json);
  }

  /// 在本地 TXT 文件指定章节内搜索
  @override
  Future<List<Map<String, dynamic>>> txtSearchInChapter(
    String path,
    String query,
    int chapterIndex, {
    bool caseSensitive = false,
    int maxResults = 50,
  }) async {
    final json = await bridge.txtSearchInChapter(
      path: path,
      query: query,
      chapterIndex: chapterIndex,
      caseSensitive: caseSensitive,
      maxResults: maxResults,
    );
    return _decodeSearchResults(json);
  }

  /// 统计本地 TXT 文件内关键词匹配总数
  @override
  Future<int> txtSearchCount(
    String path,
    String query, {
    bool caseSensitive = false,
  }) => bridge.txtSearchCount(
    path: path,
    query: query,
    caseSensitive: caseSensitive,
  );

  /// 解码 txt_search 系列返回的 JSON 数组（每项为 TxtSearchResult 对象）
  List<Map<String, dynamic>> _decodeSearchResults(String json) {
    final list = _decodeList(json, 'txtSearch');
    return list.map((e) => e as Map<String, dynamic>).toList();
  }
}
