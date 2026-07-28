import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../bridge/rust_lib.dart' as bridge;
import '../models/models.dart';

/// Rust FFI 统一访问层
///
/// 所有数据库操作通过 flutter_rust_bridge 生成的桥接函数调用 Rust 侧。
/// 尚未在 Rust FFI 中暴露的方法抛出 [UnimplementedError]。
class RustApi {
  RustApi();

  bool _initialized = false;

  /// 初始化 Rust 运行时和数据库连接
  Future<void> initialize() async {
    if (_initialized) return;

    await bridge.RustLib.init();
    await bridge.init();

    final dbPath = await _defaultDbPath();
    await bridge.dbOpen(path: dbPath);

    _initialized = true;
  }

  /// 获取默认数据库路径
  Future<String> _defaultDbPath() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}${Platform.pathSeparator}legado.db';
    }
    return '${Directory.current.path}${Platform.pathSeparator}legado.db';
  }

  /// 获取 Rust 引擎版本号
  Future<String> getVersion() => bridge.version();

  // ========== 书架操作 ==========

  /// 获取书架上所有书籍
  Future<List<Book>> getBooks() async {
    final json = await bridge.bookshelfList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => Book.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书籍到书架
  Future<Book> addBook(Book book) async {
    final json = await bridge.bookshelfAdd(bookJson: jsonEncode(book.toJson()));
    return Book.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// 更新书籍信息
  Future<void> updateBook(Book book) =>
      bridge.bookshelfUpdate(bookJson: jsonEncode(book.toJson()));

  /// 从书架删除书籍
  Future<void> deleteBook(String bookUrl) =>
      bridge.bookshelfDelete(bookUrl: bookUrl);

  /// 按 bookUrl 获取书籍详情
  Future<Book?> getBook(String bookUrl) async {
    final json = await bridge.bookshelfGet(bookUrl: bookUrl);
    if (json.isEmpty || json == 'null') return null;
    return Book.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// 置顶书籍（FFI 尚未暴露）
  Future<void> topBook(String bookUrl) =>
      throw UnimplementedError('bookshelf_top FFI not yet exposed');

  /// 取消置顶（FFI 尚未暴露）
  Future<void> unTopBook(String bookUrl) =>
      throw UnimplementedError('bookshelf_un_top FFI not yet exposed');

  /// 设置书籍分组（FFI 尚未暴露）
  Future<void> setBookGroup(String bookUrl, int groupId) =>
      throw UnimplementedError('bookshelf_set_group FFI not yet exposed');

  // ========== 书源操作 ==========

  /// 获取所有书源
  Future<List<BookSource>> getBookSources() async {
    final json = await bridge.sourceList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取所有启用的书源
  Future<List<BookSource>> getEnabledBookSources() async {
    final json = await bridge.sourceListEnabled();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书源
  Future<BookSource> addBookSource(BookSource source) async {
    final json =
        await bridge.sourceAdd(sourceJson: jsonEncode(source.toJson()));
    return BookSource.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// 更新书源
  Future<void> updateBookSource(BookSource source) =>
      bridge.sourceUpdate(sourceJson: jsonEncode(source.toJson()));

  /// 删除书源
  Future<void> deleteBookSource(String sourceUrl) =>
      bridge.sourceDelete(sourceUrl: sourceUrl);

  /// 启用书源
  Future<void> enableBookSource(String sourceUrl) =>
      bridge.sourceEnable(sourceUrl: sourceUrl);

  /// 禁用书源
  Future<void> disableBookSource(String sourceUrl) =>
      bridge.sourceDisable(sourceUrl: sourceUrl);

  /// 批量导入书源，返回成功导入的数量
  Future<int> importBookSources(String jsonArray) =>
      bridge.sourceImport(jsonArray: jsonArray);

  /// 导出所有书源为 JSON 数组
  Future<String> exportBookSources() => bridge.sourceExport();

  /// 书源排序（FFI 尚未暴露）
  Future<void> sortBookSources(int sortKey, bool ascending) =>
      throw UnimplementedError('book_source_sort FFI not yet exposed');

  // ========== 搜索操作 ==========

  /// 搜索书籍
  ///
  /// [sourceUrls] 为空则搜索所有启用的书源。
  Future<List<SearchResult>> searchBooks(
    String keyword, {
    List<String>? sourceUrls,
  }) async {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    final json = await bridge.searchBooks(
      keyword: keyword,
      sourceUrlsJson: urlsJson,
    );
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => SearchResult.fromSearchBook(
              SearchBook.fromJson(e as Map<String, dynamic>),
            ))
        .toList();
  }

  /// 多源并行搜索
  Future<List<Map<String, dynamic>>> searchMulti(
    String query, {
    List<String>? sourceUrls,
  }) async {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    final json = await bridge.searchMulti(
      query: query,
      sourceUrlsJson: urlsJson,
    );
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  /// 取消搜索
  Future<void> cancelSearch() => bridge.searchCancel();

  /// 搜索可替换的书源
  Future<List<Map<String, dynamic>>> searchSource(
    String bookName,
    String author,
  ) async {
    final json = await bridge.sourceSwitchSearch(
      bookName: bookName,
      author: author,
    );
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  /// 切换书源
  Future<String> switchSource(
    String bookUrl,
    String newSourceUrl,
    String newBookUrl,
  ) =>
      bridge.sourceSwitchApply(
        bookUrl: bookUrl,
        newSourceUrl: newSourceUrl,
        newBookUrl: newBookUrl,
      );

  // ========== RSS 源操作 ==========

  /// 获取所有 RSS 源
  Future<List<RssSource>> getRssSources() async {
    final json = await bridge.rssListSources();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => RssSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加 RSS 源
  Future<RssSource> addRssSource(RssSource source) async {
    final json =
        await bridge.rssAddSource(sourceJson: jsonEncode(source.toJson()));
    return RssSource.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// 更新 RSS 源（FFI 尚未暴露）
  Future<void> updateRssSource(RssSource source) =>
      throw UnimplementedError('rss_source_update FFI not yet exposed');

  /// 删除 RSS 源
  Future<void> deleteRssSource(String sourceUrl) =>
      bridge.rssDeleteSource(sourceUrl: sourceUrl);

  /// 启用 RSS 源（复用书源启用接口）
  Future<void> enableRssSource(String sourceUrl) =>
      bridge.sourceEnable(sourceUrl: sourceUrl);

  /// 禁用 RSS 源（复用书源禁用接口）
  Future<void> disableRssSource(String sourceUrl) =>
      bridge.sourceDisable(sourceUrl: sourceUrl);

  /// 导入 RSS 源
  Future<int> importRssSources(String jsonArray) =>
      bridge.sourceImport(jsonArray: jsonArray);

  /// 导出 RSS 源
  Future<String> exportRssSources() => bridge.sourceExport();

  /// 获取 RSS 文章列表
  Future<List<RssFeedArticle>> getRssArticles(String sourceUrl) async {
    final json = await bridge.rssFetchArticles(sourceUrl: sourceUrl);
    final list = jsonDecode(json) as List<dynamic>;
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

  // ========== 本地书籍操作 ==========

  /// 导入本地书籍
  Future<Book> importLocalBook(String filePath) async {
    final json = await bridge.importLocalBook(filePath: filePath);
    return Book.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  /// 扫描本地书籍（FFI 尚未暴露）
  Future<List<Map<String, dynamic>>> scanLocalBooks(String dirPath) =>
      throw UnimplementedError('local_book_scan FFI not yet exposed');

  /// 检测书籍文件格式
  Future<String> detectFormat(String filePath) =>
      bridge.importDetectFormat(filePath: filePath);

  /// 解析书籍元数据
  Future<String> parseMetadata(String filePath) =>
      bridge.importParseMetadata(filePath: filePath);

  // ========== 书签操作 ==========

  /// 获取某本书的所有书签
  Future<List<Bookmark>> getBookmarks(String bookName) async {
    final json = await bridge.bookmarkGetAll(bookName: bookName);
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取所有书签
  Future<List<Bookmark>> getAllBookmarks() async {
    final json = await bridge.bookmarkList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书签
  Future<Bookmark> addBookmark(Bookmark bookmark) async {
    final id = await bridge.bookmarkAdd(
      bookName: bookmark.bookName,
      bookAuthor: bookmark.bookAuthor,
      chapterIndex: bookmark.chapterIndex,
      chapterPos: bookmark.chapterPos,
      chapterName: bookmark.chapterName,
      bookText: bookmark.bookText,
      content: bookmark.content,
    );
    return bookmark.copyWith(id: id);
  }

  /// 更新书签（FFI 尚未暴露）
  Future<void> updateBookmark(Bookmark bookmark) =>
      throw UnimplementedError('bookmark_update FFI not yet exposed');

  /// 删除书签
  Future<void> deleteBookmark(int id) =>
      bridge.bookmarkDelete(bookmarkId: id);

  /// 搜索书签
  Future<List<Bookmark>> searchBookmarks(String keyword) async {
    final json = await bridge.bookmarkSearch(keyword: keyword);
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ========== 替换规则操作 ==========

  /// 获取所有替换规则
  Future<List<ReplaceRule>> getReplaceRules() async {
    final json = await bridge.replaceRuleList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取启用的替换规则
  Future<List<ReplaceRule>> getEnabledReplaceRules() async {
    final json = await bridge.replaceRuleEnabled();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加替换规则
  Future<ReplaceRule> addReplaceRule(ReplaceRule rule) async {
    final id = await bridge.replaceRuleAdd(
      name: rule.name,
      pattern: rule.pattern,
      replacement: rule.replacement,
      isRegex: rule.isRegex,
      scope: rule.scope ?? '',
    );
    return rule.copyWith(id: id);
  }

  /// 更新替换规则
  Future<void> updateReplaceRule(ReplaceRule rule) =>
      bridge.replaceRuleUpdate(
        ruleId: rule.id,
        name: rule.name,
        pattern: rule.pattern,
        replacement: rule.replacement,
        isRegex: rule.isRegex,
        isEnabled: rule.isEnabled,
      );

  /// 删除替换规则
  Future<void> deleteReplaceRule(int id) =>
      bridge.replaceRuleDelete(ruleId: id);

  /// 启用/禁用替换规则
  Future<void> setReplaceRuleEnabled(int id, bool enabled) =>
      bridge.replaceRuleSetEnabled(ruleId: id, enabled: enabled);

  // ========== 阅读器操作 ==========

  /// 获取书籍的章节列表
  Future<List<BookChapter>> getChapters(String bookUrl) async {
    final json = await bridge.readerGetChapters(bookUrl: bookUrl);
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => BookChapter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取章节正文内容（本地书籍直接返回正文）
  Future<String> getChapterContent(String bookUrl, int chapterIndex) =>
      bridge.readerGetContent(bookUrl: bookUrl, chapterIndex: chapterIndex);

  /// 从网络获取章节正文（带 DB 缓存）
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) =>
      bridge.readerFetchContent(
        bookUrl: bookUrl,
        chapterUrl: chapterUrl,
        sourceUrl: sourceUrl,
      );

  /// 更新阅读进度
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) =>
      bridge.readerUpdateProgress(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        chapterPos: chapterPos,
      );

  /// 从网络刷新书籍目录
  Future<String> refreshToc(String bookUrl, String sourceUrl) =>
      bridge.readerRefreshToc(bookUrl: bookUrl, sourceUrl: sourceUrl);

  // ========== 配置操作 ==========

  /// 获取配置值
  Future<String?> getConfig(String key) async {
    final v = await bridge.configGet(key: key);
    return v.isEmpty ? null : v;
  }

  /// 设置配置值
  Future<void> setConfig(String key, String value) async {
    await bridge.configSet(key: key, value: value);
  }

  /// 删除配置（FFI 尚未暴露）
  Future<void> deleteConfig(String key) =>
      throw UnimplementedError('config_delete FFI not yet exposed');

  /// 获取所有配置
  Future<Map<String, String>> getAllConfigs() async {
    final json = await bridge.configGetAll();
    final m = jsonDecode(json) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v.toString()));
  }

  // ========== 备份操作（FFI 尚未暴露） ==========

  /// 备份数据
  Future<String> backup(String dirPath) =>
      throw UnimplementedError('backup FFI not yet exposed');

  /// 恢复数据
  Future<void> restore(String backupPath) =>
      throw UnimplementedError('restore FFI not yet exposed');

  // ========== 阅读记录 ==========

  /// 获取所有阅读记录
  Future<List<ReadRecord>> getReadRecords() async {
    final json = await bridge.readRecordList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => ReadRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 更新阅读记录
  Future<void> putReadRecord(ReadRecord record) async {
    await bridge.readRecordUpsert(
      bookName: record.bookName,
      readTime: record.readTime,
    );
  }

  /// 删除阅读记录
  Future<void> deleteReadRecord(String bookName) async {
    await bridge.readRecordDelete(bookName: bookName);
  }

  /// 清空阅读记录
  Future<void> clearReadRecords() async {
    await bridge.readRecordClear();
  }

  // ========== RSS 收藏操作 ==========

  /// 获取所有 RSS 收藏
  Future<List<RssStar>> getRssStars() async {
    final json = await bridge.rssStarList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => RssStar.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加 RSS 收藏
  Future<RssStar> addRssStar(RssStar star) async {
    await bridge.rssStarAdd(
      sourceUrl: star.origin,
      title: star.title,
      link: star.link,
    );
    return star;
  }

  /// 删除 RSS 收藏
  Future<void> deleteRssStar(String link) async {
    await bridge.rssStarDelete(link: link);
  }

  /// 判断是否已收藏
  Future<bool> isStarred(String link) => bridge.rssStarIsStarred(link: link);

  // ========== 书籍分组 ==========

  /// 获取所有书籍分组
  Future<List<BookGroup>> getBookGroups() async {
    final json = await bridge.bookGroupList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => BookGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书籍分组
  Future<BookGroup> addBookGroup(BookGroup group) async {
    final id = await bridge.bookGroupAdd(
      groupName: group.groupName,
      cover: group.cover ?? '',
      order: group.order,
    );
    return group.copyWith(groupId: id.toInt());
  }

  /// 更新书籍分组
  Future<void> updateBookGroup(BookGroup group) async {
    await bridge.bookGroupUpdate(
      id: group.groupId,
      groupName: group.groupName,
      cover: group.cover ?? '',
      order: group.order,
    );
  }

  /// 删除书籍分组
  Future<void> deleteBookGroup(int groupId) async {
    await bridge.bookGroupDelete(id: groupId);
  }

  // ========== 搜索历史 ==========

  /// 获取搜索历史
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50}) async {
    final json = await bridge.searchHistoryList(limit: limit);
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => SearchKeyword.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加搜索关键词
  Future<void> addSearchKeyword(String keyword, String bookName) async {
    await bridge.searchHistoryAdd(keyword: keyword, bookName: bookName);
  }

  /// 删除搜索关键词
  Future<void> deleteSearchKeyword(String keyword) async {
    await bridge.searchHistoryDelete(keyword: keyword);
  }

  /// 清空搜索历史
  Future<void> clearSearchHistory() async {
    await bridge.searchHistoryClear();
  }

  // ========== 缓存管理 ==========

  /// 获取缓存大小
  Future<int> getCacheSize() async {
    final size = await bridge.cacheGetSize();
    return size.toInt();
  }

  /// 清除缓存
  Future<void> clearCache() async {
    await bridge.cacheClear();
  }

  // ========== WebBook 操作 ==========

  /// 搜索书籍（书源规则驱动）
  Future<String> webbookSearch(
    String sourceJson,
    String query,
    int page,
  ) =>
      bridge.webbookSearch(sourceJson: sourceJson, query: query, page: page);

  /// 获取书籍详情
  Future<String> webbookInfo(String sourceJson, String bookUrl) =>
      bridge.webbookInfo(sourceJson: sourceJson, bookUrl: bookUrl);

  /// 获取章节列表
  Future<String> webbookChapters(String sourceJson, String bookUrl) =>
      bridge.webbookChapters(sourceJson: sourceJson, bookUrl: bookUrl);

  /// 获取章节正文
  Future<String> webbookContent(String sourceJson, String chapterJson) =>
      bridge.webbookContent(sourceJson: sourceJson, chapterJson: chapterJson);

  // ========== 规则解析 ==========

  /// 使用规则解析内容
  Future<String> parseRule(
    String content,
    String rule,
    String ruleType,
  ) =>
      bridge.parseRule(content: content, rule: rule, ruleType: ruleType);

  // ========== 网络操作 ==========

  /// HTTP GET 请求
  Future<String> httpGet(String url) => bridge.httpGet(url: url);

  /// HTTP POST 请求
  Future<String> httpPost(String url, String body) =>
      bridge.httpPost(url: url, body: body);

  // ========== JS 引擎 ==========

  /// 执行 JS 脚本
  Future<String> evalJs(String script) => bridge.jsEval(script: script);

  /// 获取 JS 引擎版本（FFI 尚未暴露）
  Future<String> getJsEngineVersion() =>
      throw UnimplementedError('js_engine_version FFI not yet exposed');

  // ========== 服务器管理（FFI 尚未暴露） ==========

  /// 启动服务器
  Future<void> startServer({int port = 1122}) =>
      throw UnimplementedError('server_start FFI not yet exposed');

  /// 停止服务器
  Future<void> stopServer() =>
      throw UnimplementedError('server_stop FFI not yet exposed');

  /// 获取服务器状态
  Future<String> getServerStatus() =>
      throw UnimplementedError('server_status FFI not yet exposed');

  /// 设置服务器端口
  Future<void> setServerPort(int port) =>
      throw UnimplementedError('server_set_port FFI not yet exposed');

  // ========== 书籍格式解析（FFI 尚未暴露） ==========

  /// 解析 TXT 文件
  Future<List<BookChapter>> parseTxt(String filePath) =>
      throw UnimplementedError('book_parse_txt FFI not yet exposed');

  /// 解析 EPUB 文件
  Future<List<BookChapter>> parseEpub(String filePath) =>
      throw UnimplementedError('book_parse_epub FFI not yet exposed');

  /// 导出书籍
  Future<String> exportBook(String bookUrl, String format, String outDir) =>
      throw UnimplementedError('book_export FFI not yet exposed');

  // ========== 阅读统计 ==========

  /// 获取今日阅读统计
  Future<ReadingStatsToday> getTodayReadingStats() async {
    final json = await bridge.statsToday();
    final m = jsonDecode(json) as Map<String, dynamic>;
    return ReadingStatsToday(
      totalSeconds: m['totalSeconds'] as int? ?? 0,
      bookCount: m['bookCount'] as int? ?? 0,
      durationSeconds: m['durationSeconds'] as int? ?? 0,
      wordCount: m['wordCount'] as int? ?? 0,
      readingSpeed: (m['readingSpeed'] as num? ?? 0).toDouble(),
    );
  }

  /// 获取每日阅读统计
  Future<Map<String, int>> getDailyReadingStats({required int days}) async {
    final json = await bridge.statsDaily(days: days);
    final list = jsonDecode(json) as List<dynamic>;
    final result = <String, int>{};
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      result[m['date'] as String? ?? ''] = m['seconds'] as int? ?? 0;
    }
    return result;
  }

  /// 获取书籍阅读统计
  Future<Map<String, int>> getBookReadingStats() async {
    final json = await bridge.statsByBook();
    final list = jsonDecode(json) as List<dynamic>;
    final result = <String, int>{};
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      result[m['bookName'] as String? ?? ''] = m['seconds'] as int? ?? 0;
    }
    return result;
  }

  /// 获取阅读热力图
  Future<Map<String, int>> getReadingHeatmap({required int days}) async {
    final json = await bridge.statsHeatmap(days: days);
    final list = jsonDecode(json) as List<dynamic>;
    final result = <String, int>{};
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      result[m['date'] as String? ?? ''] = m['seconds'] as int? ?? 0;
    }
    return result;
  }

  /// 记录阅读时长（FFI 尚未暴露）
  Future<void> recordReadingTime(String bookName, int seconds) =>
      throw UnimplementedError('reading_stats_record FFI not yet exposed');

  // ========== HTTP TTS ==========

  /// 获取所有 HTTP TTS 配置
  Future<List<HttpTts>> getHttpTts() async {
    final json = await bridge.httpTtsList();
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => HttpTts.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取所有 HTTP TTS 配置（别名）
  Future<List<HttpTts>> getHttpTtsList() => getHttpTts();

  /// 添加 HTTP TTS 配置
  Future<HttpTts> addHttpTts(HttpTts tts) async {
    final id = await bridge.httpTtsAdd(name: tts.name, url: tts.url);
    return tts.copyWith(id: id.toInt());
  }

  /// 更新 HTTP TTS 配置
  Future<void> updateHttpTts(HttpTts tts) async {
    await bridge.httpTtsUpdate(id: tts.id, name: tts.name, url: tts.url);
  }

  /// 删除 HTTP TTS 配置
  Future<void> deleteHttpTts(int id) async {
    await bridge.httpTtsDelete(id: id);
  }

  /// 导入 HTTP TTS 配置（FFI 尚未暴露）
  Future<int> importHttpTts(String json) =>
      throw UnimplementedError('http_tts_import FFI not yet exposed');

  /// 导出 HTTP TTS 配置（FFI 尚未暴露）
  Future<String> exportHttpTts() =>
      throw UnimplementedError('http_tts_export FFI not yet exposed');

  // ========== 音频播放 ==========

  /// TTS 朗读（FFI 尚未暴露）
  Future<void> audioSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceName,
  }) =>
      throw UnimplementedError('audio_speak FFI not yet exposed');

  /// 获取章节媒体信息（FFI 尚未暴露）
  Future<Map<String, dynamic>> getAudioChapterMedia(
    String bookUrl,
    int chapterIndex,
  ) =>
      throw UnimplementedError('audio_get_chapter_media FFI not yet exposed');

  /// 获取音频播放进度
  Future<Map<String, dynamic>?> getAudioProgress(
    String bookUrl,
    int chapterIndex,
  ) async {
    final pos = await bridge.audioGetProgress(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
    );
    return {'position': pos.toInt(), 'chapterIndex': chapterIndex};
  }

  /// 保存音频播放进度
  Future<void> saveAudioProgress(
    String bookUrl,
    int chapterIndex,
    int positionMs,
  ) async {
    await bridge.audioSaveProgress(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      position: positionMs,
    );
  }

  // ========== 用户管理（FFI 尚未暴露） ==========

  /// 获取所有用户
  Future<List<Map<String, dynamic>>> getUsers() =>
      throw UnimplementedError('user_get_all FFI not yet exposed');

  /// 保存用户
  Future<Map<String, dynamic>> saveUser(Map<String, dynamic> user) =>
      throw UnimplementedError('user_save FFI not yet exposed');

  /// 删除用户
  Future<void> deleteUser(String username) =>
      throw UnimplementedError('user_delete FFI not yet exposed');

  /// 检查登录状态
  Future<bool> checkLoginStatus(String sourceUrl) =>
      throw UnimplementedError('login_check_status FFI not yet exposed');

  /// 登录
  Future<String> login(String sourceUrl, String username, String password) =>
      throw UnimplementedError('login FFI not yet exposed');

  /// 退出登录
  Future<void> logout(String sourceUrl) =>
      throw UnimplementedError('logout FFI not yet exposed');
}

/// 搜索结果包装
class SearchResult {
  final Book book;
  final String sourceName;

  const SearchResult({required this.book, this.sourceName = ''});

  factory SearchResult.fromSearchBook(SearchBook sb) {
    return SearchResult(
      sourceName: sb.originName,
      book: Book(
        bookUrl: sb.bookUrl,
        tocUrl: sb.tocUrl,
        origin: sb.origin,
        originName: sb.originName,
        name: sb.name,
        author: sb.author,
        kind: sb.kind,
        coverUrl: sb.coverUrl,
        intro: sb.intro,
        bookType: sb.bookType,
        latestChapterTitle: sb.latestChapterTitle,
        wordCount: sb.wordCount,
        originOrder: sb.originOrder,
      ),
    );
  }
}

/// RSS 文章（用于 UI 展示）
class RssFeedArticle {
  final String title;
  final String url;
  final String? description;
  final String? pubDate;
  final String? imageUrl;
  final String? content;

  const RssFeedArticle({
    required this.title,
    required this.url,
    this.description,
    this.pubDate,
    this.imageUrl,
    this.content,
  });
}

/// 今日阅读统计
class ReadingStatsToday {
  final int totalSeconds;
  final int bookCount;
  final int durationSeconds;
  final int wordCount;
  final double readingSpeed;

  const ReadingStatsToday({
    this.totalSeconds = 0,
    this.bookCount = 0,
    this.durationSeconds = 0,
    this.wordCount = 0,
    this.readingSpeed = 0,
  });
}

/// RustApi 调用异常
class RustApiException implements Exception {
  final String message;
  final String? operation;

  const RustApiException(this.message, {this.operation});

  @override
  String toString() =>
      'RustApiException: $message${operation != null ? ' (operation: $operation)' : ''}';
}
