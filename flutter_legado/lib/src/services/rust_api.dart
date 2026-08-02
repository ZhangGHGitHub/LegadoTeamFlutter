import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../bridge/rust_lib.dart' as bridge;
import '../models/models.dart';
import 'book_api.dart';

/// Rust FFI 统一访问层
///
/// 所有数据库操作通过 flutter_rust_bridge 生成的桥接函数调用 Rust 侧。
/// 尚未在 Rust FFI 中暴露的方法使用 Dart 侧 fallback 实现。
class RustApi implements BookApi {
  RustApi();

  bool _initialized = false;

  /// 初始化 Rust 运行时和数据库连接
  Future<void> initialize() async {
    if (_initialized) return;

    final lib = _resolveFfiLibrary();
    await bridge.RustLib.init(externalLibrary: lib);
    await bridge.init();

    final dbPath = await _defaultDbPath();
    await bridge.dbOpen(path: dbPath);

    _initialized = true;
  }

  /// 解析 FFI 动态库，支持多路径搜索
  ///
  /// flutter_rust_bridge 生成代码中的 ioDirectory 路径可能不正确（workspace 结构），
  /// 因此这里主动搜索 DLL 并传入 RustLib.init()。
  ExternalLibrary? _resolveFfiLibrary() {
    // Android/iOS 由系统加载，无需指定路径
    if (Platform.isAndroid || Platform.isIOS) return null;

    final String libName;
    if (Platform.isWindows) {
      libName = 'legado_ffi.dll';
    } else if (Platform.isMacOS) {
      libName = 'liblegado_ffi.dylib';
    } else {
      libName = 'liblegado_ffi.so';
    }

    final sep = Platform.pathSeparator;
    final searchPaths = <String>[];

    // 策略 1：exe 所在目录
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      searchPaths.add('$exeDir$sep$libName');
      // 从 exe 目录向上 5 级到 flutter_legado/，再找 rust/target
      final projectFromExe = File(Platform.resolvedExecutable)
          .parent.parent.parent.parent.parent.path;
      // debug 优先（匹配 flutter run 默认 debug 模式）
      searchPaths.add('$projectFromExe$sep..${sep}rust${sep}target${sep}debug$sep$libName');
      searchPaths.add('$projectFromExe$sep..${sep}rust${sep}target${sep}release$sep$libName');
    } catch (_) {}

    // 策略 2：当前工作目录（flutter run 时通常为 flutter_legado/）
    try {
      final cwd = Directory.current.path;
      searchPaths.add('$cwd$sep..${sep}rust${sep}target${sep}debug$sep$libName');
      searchPaths.add('$cwd$sep..${sep}rust${sep}target${sep}release$sep$libName');
      // 也检查 cwd 本身是否就是项目根目录
      searchPaths.add('$cwd${sep}rust${sep}target${sep}debug$sep$libName');
      searchPaths.add('$cwd${sep}rust${sep}target${sep}release$sep$libName');
    } catch (_) {}

    for (final path in searchPaths) {
      try {
        if (File(path).existsSync()) {
          return ExternalLibrary.open(path);
        }
      } catch (_) {
        // DLL 存在但加载失败（缺少依赖等），继续尝试下一个
        continue;
      }
    }

    // 找不到时返回 null，让 flutter_rust_bridge 使用默认加载逻辑
    return null;
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

  /// 置顶书籍（通过设置 order 为负值实现）
  Future<void> topBook(String bookUrl) async {
    final book = await getBook(bookUrl);
    if (book == null) return;
    await bridge.bookshelfUpdate(
      bookJson: jsonEncode(book.copyWith(order: -1).toJson()),
    );
  }

  /// 取消置顶（恢复 order 为 0）
  Future<void> unTopBook(String bookUrl) async {
    final book = await getBook(bookUrl);
    if (book == null) return;
    await bridge.bookshelfUpdate(
      bookJson: jsonEncode(book.copyWith(order: 0).toJson()),
    );
  }

  /// 设置书籍分组
  Future<void> setBookGroup(String bookUrl, int groupId) async {
    final book = await getBook(bookUrl);
    if (book == null) return;
    await bridge.bookshelfUpdate(
      bookJson: jsonEncode(book.copyWith(group: groupId).toJson()),
    );
  }

  /// 批量导入书籍，返回成功导入的数量
  Future<int> importBooks(String jsonArray) =>
      bridge.bookshelfImport(jsonArray: jsonArray);

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

  /// 书源排序（将排序偏好存入配置）
  Future<void> sortBookSources(int sortKey, bool ascending) async {
    await bridge.configSet(
      key: 'source_sort_key',
      value: sortKey.toString(),
    );
    await bridge.configSet(
      key: 'source_sort_ascending',
      value: ascending.toString(),
    );
  }

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

  /// 多源渐进式（流式）搜索
  ///
  /// 每完成一个书源即推送一个批次 Map（字段见 [BookApi.searchMultiStream]）。
  @override
  Stream<Map<String, dynamic>> searchMultiStream(
    String query, {
    List<String>? sourceUrls,
  }) {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    return bridge
        .searchMultiStream(query: query, sourceUrlsJson: urlsJson)
        .map((batch) => jsonDecode(batch) as Map<String, dynamic>);
  }

  /// 取消搜索
  Future<void> cancelSearch() => bridge.searchCancel();

  /// 搜索可替换的书源
  ///
  /// Rust 侧返回 SourceSwitchResponse { book_name, author, matches }，
  /// 兼容 Map（提取 matches 字段）和 List（直接使用）两种格式。
  Future<List<Map<String, dynamic>>> searchSource(
    String bookName,
    String author,
  ) async {
    final json = await bridge.sourceSwitchSearch(
      bookName: bookName,
      author: author,
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

  /// 更新 RSS 源（复用书源更新接口）
  Future<void> updateRssSource(RssSource source) =>
      bridge.sourceUpdate(sourceJson: jsonEncode(source.toJson()));

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

  // ========== RSS 已读记录 ==========

  /// 标记 RSS 文章为已读
  Future<void> rssMarkRead(String origin, String title, [String? link]) =>
      bridge.rssMarkRead(origin: origin, title: title, link: link);

  /// 判断 RSS 文章是否已读（按 link）
  Future<bool> rssIsRead(String link) => bridge.rssIsRead(link: link);

  /// 判断 RSS 文章是否已读（按 origin + title）
  Future<bool> rssIsReadByTitle(String origin, String title) =>
      bridge.rssIsReadByTitle(origin: origin, title: title);

  /// 清空所有 RSS 已读记录
  Future<void> rssClearReadRecords() => bridge.rssClearReadRecords();

  /// 获取 RSS 已读记录总数
  Future<int> rssReadRecordCount() async =>
      (await bridge.rssReadRecordCount()).toInt();

  /// 获取 RSS 已读记录列表（按 readTime 降序）
  Future<List<Map<String, dynamic>>> rssListReadRecords([int? limit]) async {
    final json = await bridge.rssListReadRecords(limit: limit);
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  // ========== 本地书籍操作 ==========

  /// 导入本地书籍
  Future<Book> importLocalBook(String filePath) async {
    final json = await bridge.importLocalBook(filePath: filePath);
    final result = jsonDecode(json) as Map<String, dynamic>;
    final success = result['success'] as bool? ?? false;
    if (!success) {
      final error = result['error'] as String? ?? '未知导入错误';
      throw RustApiException(error, operation: 'importLocalBook');
    }
    final bookMap = result['book'] as Map<String, dynamic>?;
    if (bookMap == null) {
      throw RustApiException('导入成功但缺少书籍数据',
          operation: 'importLocalBook');
    }
    return Book.fromJson(bookMap);
  }

  /// 扫描本地书籍（扫描目录下的常见电子书格式）
  Future<List<Map<String, dynamic>>> scanLocalBooks(String dirPath) async {
    const extensions = {'.txt', '.epub', '.mobi', '.pdf', '.azw3'};
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final results = <Map<String, dynamic>>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final ext = entity.path.substring(entity.path.lastIndexOf('.')).toLowerCase();
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

  /// 更新书签（删除后重新添加）
  Future<void> updateBookmark(Bookmark bookmark) async {
    await bridge.bookmarkDelete(bookmarkId: bookmark.id);
    await bridge.bookmarkAdd(
      bookName: bookmark.bookName,
      bookAuthor: bookmark.bookAuthor,
      chapterIndex: bookmark.chapterIndex,
      chapterPos: bookmark.chapterPos,
      chapterName: bookmark.chapterName,
      bookText: bookmark.bookText,
      content: bookmark.content,
    );
  }

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
    final decoded = jsonDecode(json);
    // Rust 侧返回 ChapterListResponse { total, chapters }，兼容 Map 和 List 两种格式
    final List<dynamic> list;
    if (decoded is Map<String, dynamic>) {
      list = (decoded['chapters'] as List<dynamic>?) ?? [];
    } else if (decoded is List<dynamic>) {
      list = decoded;
    } else {
      list = [];
    }
    return list
        .map((e) => BookChapter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取章节正文内容（本地书籍直接返回正文）
  Future<String> getChapterContent(String bookUrl, int chapterIndex) =>
      bridge.readerGetContent(bookUrl: bookUrl, chapterIndex: chapterIndex);

  /// 获取章节正文内容（不应用替换规则，用于内容搜索）
  ///
  /// 取正文流程与 [getChapterContent] 相同，但净化时关闭替换规则，
  /// 与 Android 书内搜索默认行为（replaceEnabled=false）对齐。
  Future<String> getChapterContentRaw(String bookUrl, int chapterIndex) =>
      bridge.readerGetContentRaw(bookUrl: bookUrl, chapterIndex: chapterIndex);

  /// 一次调用获取章节正文（合并 getChapterContent + fetchChapterContent）
  ///
  /// 本地书籍直接解析返回；在线书籍自动从网络抓取并返回净化后的正文。
  /// 始终返回纯正文字符串，不返回 JSON 元数据。
  Future<String> getChapterContentFull(String bookUrl, int chapterIndex) =>
      bridge.readerGetContentFull(bookUrl: bookUrl, chapterIndex: chapterIndex);

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
  ///
  /// Rust 侧返回 ChapterListResponse { total, chapters }，
  /// 兼容 Map（提取 chapters 字段）和 List（直接使用）两种格式。
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl) async {
    final json = await bridge.readerRefreshToc(bookUrl: bookUrl, sourceUrl: sourceUrl);
    final decoded = jsonDecode(json);
    // Rust 侧返回 ChapterListResponse { total, chapters }，兼容 Map 和 List 两种格式
    final List<dynamic> list;
    if (decoded is Map<String, dynamic>) {
      list = (decoded['chapters'] as List<dynamic>?) ?? [];
    } else if (decoded is List<dynamic>) {
      list = decoded;
    } else {
      list = [];
    }
    return list
        .map((e) => BookChapter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

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

  /// 删除配置（设置为空字符串）
  Future<void> deleteConfig(String key) async {
    await bridge.configSet(key: key, value: '');
  }

  /// 获取所有配置
  Future<Map<String, String>> getAllConfigs() async {
    final json = await bridge.configGetAll();
    final m = jsonDecode(json) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, v.toString()));
  }

  // ========== 备份操作 ==========

  /// 备份数据（收集所有数据写入 JSON 文件）
  Future<String> backup(String dirPath) async {
    final books = await getBooks();
    final bookmarks = await getAllBookmarks();
    final sources = await getBookSources();
    final rules = await getReplaceRules();
    final rssSources = await getRssSources();
    final httpTtsList = await getHttpTts();
    final backupData = {
      'version': 2,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'books': books.map((e) => e.toJson()).toList(),
      'bookmarks': bookmarks.map((e) => e.toJson()).toList(),
      'sources': sources.map((e) => e.toJson()).toList(),
      'rssSources': rssSources.map((e) => e.toJson()).toList(),
      'replaceRules': rules.map((e) => e.toJson()).toList(),
      'httpTts': httpTtsList.map((e) => e.toJson()).toList(),
    };
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final fileName =
        'legado_backup_${DateTime.now().millisecondsSinceEpoch}.json';
    final filePath = '$dirPath${Platform.pathSeparator}$fileName';
    final file = File(filePath);
    await file.writeAsString(jsonEncode(backupData));
    return filePath;
  }

  /// 恢复数据（从备份文件导入）
  Future<void> restore(String backupPath) async {
    final file = File(backupPath);
    if (!await file.exists()) {
      throw RustApiException('Backup file not found: $backupPath',
          operation: 'restore');
    }
    final content = await file.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;

    // 恢复书源
    final sources = data['sources'] as List<dynamic>? ?? [];
    if (sources.isNotEmpty) {
      await bridge.sourceImport(jsonArray: jsonEncode(sources));
    }

    // 恢复 RSS 源
    final rssSources = data['rssSources'] as List<dynamic>? ?? [];
    for (final rs in rssSources) {
      await bridge.rssAddSource(sourceJson: jsonEncode(rs));
    }

    // 恢复书籍
    final books = data['books'] as List<dynamic>? ?? [];
    for (final b in books) {
      await bridge.bookshelfAdd(bookJson: jsonEncode(b));
    }

    // 恢复替换规则
    final rules = data['replaceRules'] as List<dynamic>? ?? [];
    for (final r in rules) {
      final m = r as Map<String, dynamic>;
      await bridge.replaceRuleAdd(
        name: m['name'] as String? ?? '',
        pattern: m['pattern'] as String? ?? '',
        replacement: m['replacement'] as String? ?? '',
        isRegex: m['isRegex'] as bool? ?? true,
        scope: m['scope'] as String? ?? '',
      );
    }

    // 恢复 HTTP TTS
    final ttsList = data['httpTts'] as List<dynamic>? ?? [];
    for (final t in ttsList) {
      final m = t as Map<String, dynamic>;
      await bridge.httpTtsAdd(
        name: m['name'] as String? ?? '',
        url: m['url'] as String? ?? '',
      );
    }
  }

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

  /// 按前缀搜索历史关键词（用于搜索联想）
  Future<List<String>> searchHistoryByPrefix(String prefix, {int limit = 20}) async {
    final json = await bridge.searchHistoryByPrefix(prefix: prefix, limit: limit);
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e.toString()).toList();
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

  /// 获取缓存书籍数量
  Future<int> getCacheBookCount() async {
    final count = await bridge.cacheGetBookCount();
    return count.toInt();
  }

  /// 获取缓存章节数量
  Future<int> getCacheChapterCount() async {
    final count = await bridge.cacheGetChapterCount();
    return count.toInt();
  }

  /// 清除指定时间之前的缓存
  Future<void> clearCacheBefore(int beforeTimestampMs) async {
    await bridge.cacheClearBefore(beforeTimestampMs: beforeTimestampMs);
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

  // ========== 发现页操作 ==========

  /// 解析 exploreUrl 为分类列表
  ///
  /// 返回 `List<ExploreCategory>`，每项包含 title 和 url。
  /// 对标 Android BookSourceExtensions.exploreKinds()
  Future<List<ExploreCategory>> exploreParseUrl(String exploreUrl) async {
    final json = await bridge.exploreParseUrl(exploreUrl: exploreUrl);
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => ExploreCategory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 抓取发现分类的书籍列表
  ///
  /// [sourceJson] — BookSource JSON 字符串
  /// [url] — 分类 URL
  /// [page] — 页码（从 1 开始）
  ///
  /// 返回 `List<SearchBook>`，对标 Android WebBook.exploreBookAwait
  Future<List<SearchBook>> exploreFetchBooks(
    String sourceJson,
    String url,
    int page,
  ) async {
    final json = await bridge.exploreFetchBooks(
      sourceJson: sourceJson,
      url: url,
      page: page,
    );
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => SearchBook.fromJson(e as Map<String, dynamic>))
        .toList();
  }

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

  /// 获取 JS 引擎版本（通过 jsEval 查询）
  Future<String> getJsEngineVersion() async {
    try {
      return await bridge.jsEval(script: 'typeof QuickJS !== "undefined" ? QuickJS.version : "quickjs-ng"');
    } catch (_) {
      return 'unknown';
    }
  }

  // ========== 服务器管理 ==========

  /// 启动服务器（待 FFI 实现，当前将状态存入配置）
  Future<void> startServer({int port = 1122}) async {
    await bridge.configSet(key: 'server_port', value: port.toString());
    await bridge.configSet(key: 'server_running', value: 'true');
  }

  /// 停止服务器（待 FFI 实现，当前更新配置状态）
  Future<void> stopServer() async {
    await bridge.configSet(key: 'server_running', value: 'false');
  }

  /// 获取服务器状态
  Future<String> getServerStatus() async {
    final running = await bridge.configGet(key: 'server_running');
    final port = await bridge.configGet(key: 'server_port');
    if (running == 'true') {
      return 'running on port ${port.isEmpty ? '1122' : port}';
    }
    return 'stopped';
  }

  /// 设置服务器端口
  Future<void> setServerPort(int port) async {
    await bridge.configSet(key: 'server_port', value: port.toString());
  }

  // ========== 书籍格式解析 ==========

  /// 解析 TXT 文件（按章节标题模式分割）
  Future<List<BookChapter>> parseTxt(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw RustApiException('File not found: $filePath', operation: 'parseTxt');
    }
    final content = await file.readAsString();
    final lines = content.split('\n');
    final chapterPattern = RegExp(
      r'^\s*(第[\d零一二三四五六七八九十百千万]+[章节回卷集部篇]|[\d]+[\.、]|[Chapter]+\s*[\d]+)',
      caseSensitive: false,
    );
    final chapters = <BookChapter>[];
    var currentTitle = '序章';
    var startIndex = 0;
    for (var i = 0; i < lines.length; i++) {
      if (chapterPattern.hasMatch(lines[i])) {
        if (i > startIndex) {
          chapters.add(BookChapter(
            title: currentTitle,
            bookUrl: filePath,
            index: chapters.length,
            start: startIndex,
            end: i,
          ));
        }
        currentTitle = lines[i].trim();
        startIndex = i;
      }
    }
    // 添加最后一章
    chapters.add(BookChapter(
      title: currentTitle,
      bookUrl: filePath,
      index: chapters.length,
      start: startIndex,
      end: lines.length,
    ));
    return chapters;
  }

  /// 解析 EPUB 文件（通过 importLocalBook 解析后获取章节）
  Future<List<BookChapter>> parseEpub(String filePath) async {
    // 先导入书籍，然后获取章节列表
    final bookJson = await bridge.importLocalBook(filePath: filePath);
    final resultMap = jsonDecode(bookJson) as Map<String, dynamic>;
    final bookMap = resultMap['book'] as Map<String, dynamic>?;
    final bookUrl = bookMap?['bookUrl'] as String? ?? filePath;
    final chaptersJson = await bridge.readerGetChapters(bookUrl: bookUrl);
    final decodedChapters = jsonDecode(chaptersJson);
    // 兼容 Rust 侧返回 ChapterListResponse { total, chapters } 对象格式
    final List<dynamic> list;
    if (decodedChapters is Map<String, dynamic>) {
      list = (decodedChapters['chapters'] as List<dynamic>?) ?? [];
    } else if (decodedChapters is List<dynamic>) {
      list = decodedChapters;
    } else {
      list = [];
    }
    return list
        .map((e) => BookChapter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 导出书籍（将章节内容写入文件）
  Future<String> exportBook(String bookUrl, String format, String outDir) async {
    final book = await getBook(bookUrl);
    final bookName = book?.name ?? 'export';
    final chapters = await getChapters(bookUrl);
    final dir = Directory(outDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final fileName = '$bookName.${format == 'txt' ? 'txt' : 'json'}';
    final filePath = '$outDir${Platform.pathSeparator}$fileName';
    final file = File(filePath);
    if (format == 'txt') {
      final buffer = StringBuffer();
      for (final chapter in chapters) {
        buffer.writeln(chapter.title);
        buffer.writeln();
        try {
          final content = await getChapterContent(bookUrl, chapter.index);
          buffer.writeln(content);
        } catch (_) {
          buffer.writeln('[内容获取失败]');
        }
        buffer.writeln();
      }
      await file.writeAsString(buffer.toString());
    } else {
      final data = {
        'book': book?.toJson(),
        'chapters': chapters.map((e) => e.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(data));
    }
    return filePath;
  }

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

  /// 记录阅读时长（通过 readRecordUpsert 实现）
  Future<void> recordReadingTime(String bookName, int seconds) async {
    await bridge.readRecordUpsert(bookName: bookName, readTime: seconds);
  }

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

  /// 导入 HTTP TTS 配置（解析 JSON 数组并逐条添加）
  Future<int> importHttpTts(String json) async {
    final list = jsonDecode(json) as List<dynamic>;
    var count = 0;
    for (final item in list) {
      final m = item as Map<String, dynamic>;
      final name = m['name'] as String? ?? '';
      final url = m['url'] as String? ?? '';
      if (name.isNotEmpty && url.isNotEmpty) {
        await bridge.httpTtsAdd(name: name, url: url);
        count++;
      }
    }
    return count;
  }

  /// 导出 HTTP TTS 配置（返回 JSON 数组）
  Future<String> exportHttpTts() async {
    final list = await getHttpTts();
    return jsonEncode(list.map((e) => e.toJson()).toList());
  }

  // ========== 音频播放 ==========

  /// TTS 朗读（通过 HTTP 请求 TTS 引擎，待 FFI 实现本地播放）
  Future<void> audioSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceName,
  }) async {
    // 将参数填充到 engineUrl 模板中
    var url = engineUrl
        .replaceAll('{{text}}', Uri.encodeComponent(text))
        .replaceAll('{{speed}}', speed.toString())
        .replaceAll('{{pitch}}', pitch.toString())
        .replaceAll('{{volume}}', volume.toString());
    if (voiceName != null) {
      url = url.replaceAll('{{voice}}', Uri.encodeComponent(voiceName));
    }
    // 发起请求验证可达性（实际播放需平台音频播放器）
    await http.get(Uri.parse(url));
  }

  /// 获取章节媒体信息（待 FFI 实现，当前返回基本信息）
  Future<Map<String, dynamic>> getAudioChapterMedia(
    String bookUrl,
    int chapterIndex,
  ) async {
    final chapters = await getChapters(bookUrl);
    if (chapterIndex < 0 || chapterIndex >= chapters.length) {
      return {'error': 'Invalid chapter index'};
    }
    final chapter = chapters[chapterIndex];
    return {
      'chapterIndex': chapterIndex,
      'title': chapter.title,
      'url': chapter.url,
      'resourceUrl': chapter.resourceUrl,
    };
  }

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

  // ========== 用户管理 ==========

  /// 获取所有用户
  Future<List<Map<String, dynamic>>> getUsers() async {
    final json = await bridge.userGetAll();
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 保存用户，返回用户 ID
  Future<int> saveUser({
    required String username,
    required String password,
    required String sourceUrl,
  }) async {
    final id = await bridge.userSave(
      username: username,
      password: password,
      sourceUrl: sourceUrl,
    );
    return id.toInt();
  }

  /// 删除用户
  Future<bool> deleteUser(String username) =>
      bridge.userDelete(username: username);

  /// 用户登录
  Future<bool> userLogin({
    required String username,
    required String password,
  }) =>
      bridge.userLogin(username: username, password: password);

  /// 用户登出
  Future<bool> userLogout(String username) =>
      bridge.userLogout(username: username);

  /// 检查登录状态
  Future<bool> checkLoginStatus(String username) =>
      bridge.userCheckLogin(username: username);

  // ========== WebDAV 云同步 ==========

  /// WebDAV 列出远程目录
  Future<String> webdavListDir(String configJson, String path) =>
      bridge.webdavListDir(configJson: configJson, path: path);

  /// WebDAV 上传文件
  Future<void> webdavUpload(
          String configJson, String path, String data) =>
      bridge.webdavUpload(
          configJson: configJson, path: path, data: data);

  /// WebDAV 下载文件
  Future<String> webdavDownload(String configJson, String path) =>
      bridge.webdavDownload(configJson: configJson, path: path);

  /// WebDAV 删除远程文件
  Future<void> webdavDelete(String configJson, String path) =>
      bridge.webdavDelete(configJson: configJson, path: path);

  /// WebDAV 全量同步
  Future<String> webdavFullSync(
          String configJson, String localBooks, String localSources) =>
      bridge.webdavFullSync(
          configJson: configJson,
          localBooks: localBooks,
          localSources: localSources);

  // ========== 下载管理器 ==========

  /// 添加下载任务
  Future<String> downloadAddTask({
    required String bookUrl,
    required String chapterUrl,
    required String chapterTitle,
    required int chapterIndex,
    int priority = 0,
  }) =>
      bridge.downloadAddTask(
        bookUrl: bookUrl,
        chapterUrl: chapterUrl,
        chapterTitle: chapterTitle,
        chapterIndex: chapterIndex,
        priority: priority,
      );

  /// 获取下载统计信息
  Future<String> downloadGetStats() => bridge.downloadGetStats();

  /// 获取指定书籍的下载任务
  Future<String> downloadListByBook(String bookUrl) =>
      bridge.downloadListByBook(bookUrl: bookUrl);

  /// 暂停所有下载
  Future<void> downloadPauseAll() => bridge.downloadPauseAll();

  /// 恢复所有下载
  Future<void> downloadResumeAll() => bridge.downloadResumeAll();

  /// 移除下载任务
  Future<void> downloadRemoveTask(String taskId) =>
      bridge.downloadRemoveTask(taskId: taskId);

  /// 更新下载进度
  Future<void> downloadUpdateProgress(String taskId, double progress) =>
      bridge.downloadUpdateProgress(taskId: taskId, progress: progress);

  // ========== 段评/章评 ==========

  /// 获取指定章节的所有评论（JSON 数组）
  Future<String> reviewGetByChapter(String bookUrl, int chapterIndex) =>
      bridge.reviewGetByChapter(
          bookUrl: bookUrl, chapterIndex: chapterIndex);

  /// 添加评论，返回评论 ID
  Future<int> reviewAdd({
    required String bookUrl,
    required int chapterIndex,
    int paragraphIndex = -1,
    required String content,
    String author = '',
  }) async {
    final id = await bridge.reviewAdd(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      paragraphIndex: paragraphIndex,
      content: content,
      author: author,
    );
    return id.toInt();
  }

  /// 删除评论
  Future<bool> reviewDelete(int id) =>
      bridge.reviewDelete(id: id);

  /// 点赞评论
  Future<void> reviewLike(int id) => bridge.reviewLike(id: id);

  // ========== 书籍导出 ==========

  /// 导出书籍（返回 ExportResult JSON）
  /// 
  /// # 参数
  /// - `bookUrl`: 书籍 URL
  /// - `format`: 导出格式（txt/epub/html）
  /// - `includeToc`: 是否包含目录
  Future<Map<String, dynamic>> bookExport({
    required String bookUrl,
    required String format,
    required bool includeToc,
  }) async {
    final json = await bridge.bookExport(
      bookUrl: bookUrl,
      format: format,
      includeToc: includeToc,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 获取导出预览信息（返回 ExportResult JSON）
  Future<Map<String, dynamic>> bookExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    final json = await bridge.bookExportInfo(
      bookUrl: bookUrl,
      format: format,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  // ========== 自动任务（auto_task FFI） ==========

  /// 构建书籍更新定时任务（返回 AutoTaskRule JSON）
  ///
  /// 对应 Kotlin `AutoTask.buildBookUpdateTask`。
  Future<Map<String, dynamic>> autoTaskBuildBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
    required String name,
  }) async {
    final json = await bridge.autoTaskBuildBookUpdate(
      bookUrl: bookUrl,
      bookName: bookName,
      bookAuthor: bookAuthor,
      name: name,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 批量更新 cron 表达式（返回更新后的 AutoTaskRule 数组）
  ///
  /// [rules] 为现有规则列表 JSON，[ids] 为待更新任务 ID 列表。
  Future<List<Map<String, dynamic>>> autoTaskUpdateCronBatch({
    required String rulesJson,
    required String idsJson,
    required String cron,
  }) async {
    final json = await bridge.autoTaskUpdateCronBatch(
      rulesJson: rulesJson,
      idsJson: idsJson,
      cron: cron,
    );
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 准备导入任务（合并本地运行时状态，返回合并后的任务数组）
  Future<List<Map<String, dynamic>>> autoTaskPrepareImported({
    required String localTasksJson,
    required String importedJson,
  }) async {
    final json = await bridge.autoTaskPrepareImported(
      localTasksJson: localTasksJson,
      importedJson: importedJson,
    );
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 执行任务协议（返回 TaskResult JSON）
  ///
  /// [protocolJson] 为 TaskProtocol 序列化字符串。
  Future<Map<String, dynamic>> autoTaskExecute({
    required String protocolJson,
  }) async {
    final json = await bridge.autoTaskExecute(protocolJson: protocolJson);
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 带任务 ID 执行任务协议（返回 TaskResult JSON）
  Future<Map<String, dynamic>> autoTaskExecuteWithId({
    required String protocolJson,
    required String taskId,
  }) async {
    final json = await bridge.autoTaskExecuteWithId(
      protocolJson: protocolJson,
      taskId: taskId,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 规范化脚本（去除 `@js:` 前缀或 `<js></js>` 包裹）
  Future<String> autoTaskNormalizeScript({required String script}) =>
      bridge.autoTaskNormalizeScript(script: script);

  /// 判断书籍是否允许刷新目录
  Future<bool> autoTaskCanRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  }) =>
      bridge.autoTaskCanRefreshToc(
        canUpdate: canUpdate,
        respectCanUpdate: respectCanUpdate,
      );

  /// 查找书籍更新任务（返回匹配的 AutoTaskRule JSON，未找到返回 null）
  Future<Map<String, dynamic>?> autoTaskFindBookUpdateTask({
    required String tasksJson,
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
  }) async {
    final json = await bridge.autoTaskFindBookUpdate(
      tasksJson: tasksJson,
      bookUrl: bookUrl,
      bookName: bookName,
      bookAuthor: bookAuthor,
    );
    if (json.isEmpty || json == 'null') return null;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 解析 cron 表达式计算下次执行时间（Unix 毫秒，无法解析返回 -1）
  Future<int> autoTaskNextDueAt({
    required String cron,
    required int fromMs,
  }) async {
    final result = await bridge.autoTaskNextDueAt(
      cron: cron,
      fromMs: fromMs,
    );
    return result.toInt();
  }

  // ========== 自动任务数据库 CRUD ==========

  /// 列出所有自动任务规则（按 customOrder 排序）
  Future<List<Map<String, dynamic>>> autoTaskListRules() async {
    final json = await bridge.autoTaskListRules();
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 创建自动任务规则（返回任务 ID）
  Future<String> autoTaskCreateRule({required String ruleJson}) async {
    return await bridge.autoTaskCreateRule(ruleJson: ruleJson);
  }

  /// 更新自动任务规则
  Future<void> autoTaskUpdateRule({required String ruleJson}) async {
    await bridge.autoTaskUpdateRule(ruleJson: ruleJson);
  }

  /// 删除自动任务规则
  Future<void> autoTaskDeleteRule({required String id}) async {
    await bridge.autoTaskDeleteRule(id: id);
  }

  /// 根据 ID 查询自动任务规则
  Future<Map<String, dynamic>?> autoTaskFindRuleById({required String id}) async {
    final json = await bridge.autoTaskFindRuleById(id: id);
    if (json.isEmpty || json == 'null') return null;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  // ========== 音频播放模式（audio FFI） ==========

  /// 将播放模式写入 readConfig JSON（返回更新后的 JSON）
  ///
  /// 对应 Kotlin `String?.withAudioPlayMode`。
  Future<String> audioWithPlayMode({
    String? readConfig,
    required int playMode,
  }) =>
      bridge.audioWithPlayMode(readConfig: readConfig, playMode: playMode);

  /// 解析听书书籍（返回 Book JSON，未找到返回 null）
  ///
  /// 请求 URL 为空时返回缓存书籍；缓存匹配时直接返回；否则按 URL 查库。
  Future<Map<String, dynamic>?> audioResolvePlayBook({
    String? requestedBookUrl,
    String? cachedBookJson,
  }) async {
    final json = await bridge.audioResolvePlayBook(
      requestedBookUrl: requestedBookUrl,
      cachedBookJson: cachedBookJson,
    );
    if (json.isEmpty || json == 'null') return null;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  // ========== 压缩包导入 ==========

  /// 导入 ZIP 压缩包中的书籍文件
  ///
  /// 解压 ZIP 文件，提取其中的书籍文件到 [outputDir]。
  /// 返回 ArchiveImportResult JSON 解析后的 Map。
  Future<Map<String, dynamic>> archiveImportZip({
    required String zipPath,
    required String outputDir,
  }) async {
    final json = await bridge.archiveImportZip(
      zipPath: zipPath,
      outputDir: outputDir,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 导入 RAR 压缩包中的书籍文件（支持加密）
  ///
  /// 解压 RAR 文件，提取其中的书籍文件到 [outputDir]。
  /// [password] 为可选密码，用于加密 RAR 文件。
  Future<Map<String, dynamic>> archiveImportRar({
    required String rarPath,
    required String outputDir,
    String? password,
  }) async {
    final json = await bridge.archiveImportRar(
      rarPath: rarPath,
      outputDir: outputDir,
      password: password,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 列出 ZIP 压缩包中的书籍文件名（不解压）
  ///
  /// 返回压缩包内符合书籍格式的文件名列表。
  Future<List<String>> archiveListZipFiles({required String zipPath}) async {
    final json = await bridge.archiveListZipFiles(zipPath: zipPath);
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e.toString()).toList();
  }

  /// 列出 RAR 压缩包中的书籍文件名（不解压）
  ///
  /// [password] 为可选密码，用于加密 RAR 文件。
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  }) async {
    final json = await bridge.archiveListRarFiles(
      rarPath: rarPath,
      password: password,
    );
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e.toString()).toList();
  }

  /// 检测 TXT 文件编码
  ///
  /// 返回 EncodingResult JSON 解析后的 Map，包含：
  /// - encoding: 编码名称
  /// - has_bom: 是否通过 BOM 确定
  /// - confidence: 置信度（high/medium/low）
  Future<Map<String, dynamic>> archiveDetectEncoding({
    required String filePath,
  }) async {
    final json = await bridge.archiveDetectEncoding(filePath: filePath);
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 转换 TXT 文件编码
  ///
  /// 将文件从 [fromEncoding] 转换为 [toEncoding]，输出为新文件。
  /// 返回 ConvertResult JSON 解析后的 Map。
  Future<Map<String, dynamic>> archiveConvertEncoding({
    required String filePath,
    required String fromEncoding,
    required String toEncoding,
  }) async {
    final json = await bridge.archiveConvertEncoding(
      filePath: filePath,
      fromEncoding: fromEncoding,
      toEncoding: toEncoding,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 判断文件是否为压缩包格式
  ///
  /// 支持 .zip / .rar / .7z 等格式判断。
  Future<bool> archiveIsArchive({required String filePath}) =>
      bridge.archiveIsArchive(filePath: filePath);
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
