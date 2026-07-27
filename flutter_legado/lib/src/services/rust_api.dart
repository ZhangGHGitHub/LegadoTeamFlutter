import 'dart:convert';

import 'package:http/http.dart' as http;

import '../bridge/rust_lib.dart' as bridge;
import '../models/models.dart';

/// Rust 后端桥接服务 — 所有后端操作的统一入口
///
/// 通过 flutter_rust_bridge 生成的 bindings 调用 Rust 后端。
///
/// FFI 函数使用 JSON string 传递复杂类型：
/// - Rust 侧返回 JSON 字符串
/// - Dart 侧用 jsonDecode 解析为 Flutter models
/// - 传入 Rust 时用 jsonEncode 序列化
class RustApi {
  RustApi();

  bool _initialized = false;

  /// 初始化 Rust 桥接运行时
  ///
  /// 必须先调用此方法初始化 frb runtime 和 tokio runtime。
  /// [dbPath] 可选，指定数据库路径，默认为 'legado.db'。
  Future<void> initialize({String? dbPath}) async {
    if (_initialized) return;
    try {
      await bridge.RustLib.init();
      await bridge.init();
      await bridge.dbOpen(path: dbPath ?? 'legado.db');
      _initialized = true;
    } catch (e) {
      throw RustApiException('Rust 初始化失败: $e');
    }
  }

  // ===== 书架 =====

  /// 获取书架上所有书籍
  Future<List<Book>> getBooks() async {
    try {
      final json = await bridge.bookshelfList();
      final list = jsonDecode(json) as List;
      return list
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取书架失败: $e');
    }
  }

  /// 添加书籍到书架，返回添加后的书籍信息
  Future<Book> addBook(Book book) async {
    try {
      final json = await bridge.bookshelfAdd(
          bookJson: jsonEncode(book.toJson()));
      return Book.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      throw RustApiException('添加书籍失败: $e');
    }
  }

  /// 更新书籍信息
  Future<void> updateBook(Book book) async {
    try {
      await bridge.bookshelfUpdate(bookJson: jsonEncode(book.toJson()));
    } catch (e) {
      throw RustApiException('更新书籍失败: $e');
    }
  }

  /// 按 bookUrl 删除书籍
  Future<void> deleteBook(String bookUrl) async {
    try {
      await bridge.bookshelfDelete(bookUrl: bookUrl);
    } catch (e) {
      throw RustApiException('删除书籍失败: $e');
    }
  }

  /// 按 bookUrl 获取书籍详情
  Future<Book?> getBook(String bookUrl) async {
    try {
      final json = await bridge.bookshelfGet(bookUrl: bookUrl);
      final decoded = jsonDecode(json);
      if (decoded == null) return null;
      return Book.fromJson(decoded as Map<String, dynamic>);
    } catch (e) {
      throw RustApiException('获取书籍详情失败: $e');
    }
  }

  // ===== 阅读进度 =====

  /// 更新阅读进度
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {
    try {
      await bridge.readerUpdateProgress(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        chapterPos: chapterPos,
      );
    } catch (e) {
      throw RustApiException('更新阅读进度失败: $e');
    }
  }

  // ===== 章节 =====

  /// 获取书籍的章节列表
  Future<List<BookChapter>> getChapters(String bookUrl) async {
    try {
      final json = await bridge.readerGetChapters(bookUrl: bookUrl);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final chaptersList = decoded['chapters'] as List? ?? [];
      return chaptersList
          .map((e) => BookChapter.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取章节列表失败: $e');
    }
  }

  /// 获取章节正文内容
  ///
  /// [chapterIndex] 章节在列表中的索引（从 0 开始）。
  Future<String> getChapterContent(String bookUrl, int chapterIndex) async {
    try {
      return await bridge.readerGetContent(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
      );
    } catch (e) {
      throw RustApiException('获取章节内容失败: $e');
    }
  }

  // ===== 书源 =====

  /// 获取所有书源列表
  Future<List<BookSource>> getBookSources() async {
    try {
      final json = await bridge.sourceList();
      final list = jsonDecode(json) as List;
      return list
          .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取书源列表失败: $e');
    }
  }

  /// 获取所有启用的书源
  Future<List<BookSource>> getEnabledBookSources() async {
    try {
      final json = await bridge.sourceListEnabled();
      final list = jsonDecode(json) as List;
      return list
          .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取启用书源失败: $e');
    }
  }

  /// 添加书源，返回添加后的书源信息
  Future<BookSource> addBookSource(BookSource source) async {
    try {
      final json = await bridge.sourceAdd(
          sourceJson: jsonEncode(source.toJson()));
      return BookSource.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      throw RustApiException('添加书源失败: $e');
    }
  }

  /// 更新书源
  Future<void> updateBookSource(BookSource source) async {
    try {
      await bridge.sourceUpdate(sourceJson: jsonEncode(source.toJson()));
    } catch (e) {
      throw RustApiException('更新书源失败: $e');
    }
  }

  /// 删除书源
  Future<void> deleteBookSource(String sourceUrl) async {
    try {
      await bridge.sourceDelete(sourceUrl: sourceUrl);
    } catch (e) {
      throw RustApiException('删除书源失败: $e');
    }
  }

  /// 启用书源
  Future<void> enableBookSource(String sourceUrl) async {
    try {
      await bridge.sourceEnable(sourceUrl: sourceUrl);
    } catch (e) {
      throw RustApiException('启用书源失败: $e');
    }
  }

  /// 禁用书源
  Future<void> disableBookSource(String sourceUrl) async {
    try {
      await bridge.sourceDisable(sourceUrl: sourceUrl);
    } catch (e) {
      throw RustApiException('禁用书源失败: $e');
    }
  }

  /// 批量导入书源，返回成功导入的数量
  Future<int> importBookSources(String jsonArray) async {
    try {
      return await bridge.sourceImport(jsonArray: jsonArray);
    } catch (e) {
      throw RustApiException('导入书源失败: $e');
    }
  }

  /// 导出所有书源为 JSON 数组字符串
  Future<String> exportBookSources() async {
    try {
      return await bridge.sourceExport();
    } catch (e) {
      throw RustApiException('导出书源失败: $e');
    }
  }

  // ===== 搜索 =====

  /// 搜索书籍
  Future<List<SearchResult>> searchBooks(
    String keyword, {
    List<String>? sourceUrls,
  }) async {
    try {
      final sourceUrlsJson =
          sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
      final json = await bridge.searchBooks(
        keyword: keyword,
        sourceUrlsJson: sourceUrlsJson,
      );
      final list = jsonDecode(json) as List;
      return list.map((e) {
        final map = e as Map<String, dynamic>;
        return SearchResult.fromJson(map);
      }).toList();
    } catch (e) {
      throw RustApiException('搜索书籍失败: $e');
    }
  }

  // ===== RSS =====

  /// 获取所有 RSS 源列表
  Future<List<RssSource>> getRssSources() async {
    try {
      final json = await bridge.rssListSources();
      final list = jsonDecode(json) as List;
      return list
          .map((e) => RssSource.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取 RSS 源失败: $e');
    }
  }

  /// 获取 RSS 源的文章列表
  Future<List<RssFeedArticle>> getRssArticles(String sourceUrl) async {
    try {
      final json = await bridge.rssFetchArticles(sourceUrl: sourceUrl);
      final list = jsonDecode(json) as List;
      return list.map((e) {
        final map = e as Map<String, dynamic>;
        return RssFeedArticle(
          title: map['title'] as String? ?? '',
          url: map['link'] as String? ?? '',
          description: map['description'] as String?,
          pubDate: map['pubDate'] as String?,
          imageUrl: map['imageUrl'] as String?,
          content: map['content'] as String?,
          sourceUrl: sourceUrl,
        );
      }).toList();
    } catch (e) {
      throw RustApiException('获取 RSS 文章失败: $e');
    }
  }

  /// 添加 RSS 源
  Future<RssSource> addRssSource(RssSource source) async {
    try {
      final json = await bridge.rssAddSource(
          sourceJson: jsonEncode(source.toJson()));
      return RssSource.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      throw RustApiException('添加 RSS 源失败: $e');
    }
  }

  /// 删除 RSS 源
  Future<void> deleteRssSource(String sourceUrl) async {
    try {
      await bridge.rssDeleteSource(sourceUrl: sourceUrl);
    } catch (e) {
      throw RustApiException('删除 RSS 源失败: $e');
    }
  }

  // ===== 书籍导入 =====

  /// 检测书籍文件格式
  Future<String> detectBookFormat(String filePath) async {
    try {
      return await bridge.importDetectFormat(filePath: filePath);
    } catch (e) {
      throw RustApiException('检测文件格式失败: $e');
    }
  }

  /// 解析书籍元数据
  Future<Map<String, dynamic>> parseBookMetadata(String filePath) async {
    try {
      final json = await bridge.importParseMetadata(filePath: filePath);
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (e) {
      throw RustApiException('解析书籍元数据失败: $e');
    }
  }

  /// 导入本地书籍到书架
  Future<Book> importLocalBook(String filePath) async {
    try {
      final json = await bridge.importLocalBook(filePath: filePath);
      return Book.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      throw RustApiException('导入本地书籍失败: $e');
    }
  }

  // ===== 书签 =====
  // TODO: 运行 flutter_rust_bridge codegen 后替换为 bridge.bookmarkXxx() 调用
  // Rust FFI 已实现: bookmark_get_all, bookmark_add, bookmark_delete, bookmark_search, bookmark_list
  // codegen 后对应: bridge.bookmarkGetAll(bookName:), bridge.bookmarkAdd(...), bridge.bookmarkDelete(bookmarkId:), bridge.bookmarkSearch(keyword:)

  /// 本地书签缓存（codegen 前的 fallback 实现）
  final List<Bookmark> _bookmarkCache = [];

  /// 获取书签列表（按书名）
  Future<List<Bookmark>> getBookmarks(String bookName) async {
    // TODO: codegen 后替换为:
    // final json = await bridge.bookmarkGetAll(bookName: bookName);
    // final list = jsonDecode(json) as List;
    // return list.map((e) => Bookmark.fromJson(e as Map<String, dynamic>)).toList();
    return _bookmarkCache
        .where((b) => b.bookName == bookName)
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  }

  /// 获取所有书签
  Future<List<Bookmark>> getAllBookmarks() async {
    // TODO: codegen 后替换为:
    // final json = await bridge.bookmarkList();
    // final list = jsonDecode(json) as List;
    // return list.map((e) => Bookmark.fromJson(e as Map<String, dynamic>)).toList();
    return List.from(_bookmarkCache)
      ..sort((a, b) => b.time.compareTo(a.time));
  }

  /// 添加书签
  Future<Bookmark> addBookmark(Bookmark bookmark) async {
    // TODO: codegen 后替换为:
    // final id = await bridge.bookmarkAdd(
    //   bookName: bookmark.bookName,
    //   bookAuthor: bookmark.bookAuthor,
    //   chapterIndex: bookmark.chapterIndex,
    //   chapterPos: bookmark.chapterPos,
    //   chapterName: bookmark.chapterName,
    //   bookText: bookmark.bookText,
    //   content: bookmark.content,
    // );
    // return bookmark.copyWith(id: id, time: DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final bm = bookmark.copyWith(
      id: DateTime.now().millisecondsSinceEpoch,
      time: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    _bookmarkCache.add(bm);
    return bm;
  }

  /// 删除书签
  Future<void> deleteBookmark(int id) async {
    // TODO: codegen 后替换为: await bridge.bookmarkDelete(bookmarkId: id);
    _bookmarkCache.removeWhere((b) => b.id == id);
  }

  /// 搜索书签
  Future<List<Bookmark>> searchBookmarks(String keyword) async {
    // TODO: codegen 后替换为:
    // final json = await bridge.bookmarkSearch(keyword: keyword);
    // final list = jsonDecode(json) as List;
    // return list.map((e) => Bookmark.fromJson(e as Map<String, dynamic>)).toList();
    final kw = keyword.toLowerCase();
    return _bookmarkCache
        .where((b) =>
            b.bookText.toLowerCase().contains(kw) ||
            b.content.toLowerCase().contains(kw) ||
            b.chapterName.toLowerCase().contains(kw))
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  }

  // ===== 替换规则 =====
  // TODO: 运行 flutter_rust_bridge codegen 后替换为 bridge.replaceRuleXxx() 调用
  // Rust FFI 已实现: replace_rule_list, replace_rule_add, replace_rule_update, replace_rule_delete, replace_rule_enabled, replace_rule_set_enabled

  /// 本地替换规则缓存（codegen 前的 fallback 实现）
  final List<ReplaceRule> _replaceRuleCache = [];

  /// 获取所有替换规则
  Future<List<ReplaceRule>> getReplaceRules() async {
    // TODO: codegen 后替换为:
    // final json = await bridge.replaceRuleList();
    // final list = jsonDecode(json) as List;
    // return list.map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>)).toList();
    return List.from(_replaceRuleCache)
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  /// 获取启用的替换规则
  Future<List<ReplaceRule>> getEnabledReplaceRules() async {
    // TODO: codegen 后替换为:
    // final json = await bridge.replaceRuleEnabled();
    // final list = jsonDecode(json) as List;
    // return list.map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>)).toList();
    return _replaceRuleCache.where((r) => r.isEnabled).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  /// 添加替换规则
  Future<ReplaceRule> addReplaceRule(ReplaceRule rule) async {
    // TODO: codegen 后替换为:
    // final id = await bridge.replaceRuleAdd(
    //   name: rule.name, pattern: rule.pattern, replacement: rule.replacement,
    //   isRegex: rule.isRegex, scope: rule.scope ?? '',
    // );
    // return rule.copyWith(id: id);
    final r = rule.copyWith(
      id: DateTime.now().millisecondsSinceEpoch,
    );
    _replaceRuleCache.add(r);
    return r;
  }

  /// 更新替换规则
  Future<void> updateReplaceRule(ReplaceRule rule) async {
    // TODO: codegen 后替换为:
    // await bridge.replaceRuleUpdate(
    //   ruleId: rule.id, name: rule.name, pattern: rule.pattern,
    //   replacement: rule.replacement, isRegex: rule.isRegex, isEnabled: rule.isEnabled,
    // );
    final idx = _replaceRuleCache.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) {
      _replaceRuleCache[idx] = rule;
    }
  }

  /// 删除替换规则
  Future<void> deleteReplaceRule(int id) async {
    // TODO: codegen 后替换为: await bridge.replaceRuleDelete(ruleId: id);
    _replaceRuleCache.removeWhere((r) => r.id == id);
  }

  /// 启用/禁用替换规则
  Future<void> setReplaceRuleEnabled(int id, bool enabled) async {
    // TODO: codegen 后替换为: await bridge.replaceRuleSetEnabled(ruleId: id, enabled: enabled);
    final idx = _replaceRuleCache.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      _replaceRuleCache[idx] = _replaceRuleCache[idx].copyWith(isEnabled: enabled);
    }
  }

  /// 对文本应用替换规则
  Future<String> applyReplaceRules(String text, String bookName) async {
    final rules = await getEnabledReplaceRules();
    var result = text;
    for (final rule in rules) {
      if (rule.pattern.isEmpty) continue;
      // 检查 scope 匹配
      if (rule.scope != null &&
          rule.scope!.isNotEmpty &&
          rule.scope != 'global' &&
          !rule.scope!.contains(bookName)) {
        continue;
      }
      if (rule.isRegex) {
        try {
          final re = RegExp(rule.pattern);
          result = result.replaceAllMapped(re, (_) => rule.replacement);
        } catch (_) {
          // 正则表达式无效，跳过
        }
      } else {
        result = result.replaceAll(rule.pattern, rule.replacement);
      }
    }
    return result;
  }

  // ===== 在线阅读（网络抓取） =====
  // TODO: 运行 flutter_rust_bridge codegen 后替换为 bridge.readerRefreshToc() / bridge.readerFetchContent()
  // Rust FFI 已实现: reader_refresh_toc(book_url, source_url), reader_fetch_content(book_url, chapter_url, source_url)

  /// 从网络刷新书籍目录
  ///
  /// [bookUrl] 书籍详情页 URL
  /// [sourceUrl] 书源 URL
  /// 返回章节列表（JSON 解析后的 BookChapter 列表）
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl) async {
    // TODO: codegen 后替换为:
    // final json = await bridge.readerRefreshToc(bookUrl: bookUrl, sourceUrl: sourceUrl);
    // final list = jsonDecode(json) as List;
    // return list.map((e) => BookChapter.fromJson(e as Map<String, dynamic>)).toList();
    try {
      final response = await http.post(
        Uri.parse('$_serverBaseUrl/api/reader/refresh-toc'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'book_url': bookUrl, 'source_url': sourceUrl}),
      );
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        return list
            .map((e) => BookChapter.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      throw RustApiException('刷新目录失败: ${response.statusCode}');
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('刷新目录失败: $e');
    }
  }

  /// 获取在线章节正文（网络抓取 + 缓存）
  ///
  /// [bookUrl] 书籍 URL
  /// [chapterUrl] 章节 URL
  /// [sourceUrl] 书源 URL
  /// 返回章节正文文本
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    // TODO: codegen 后替换为:
    // return await bridge.readerFetchContent(
    //   bookUrl: bookUrl, chapterUrl: chapterUrl, sourceUrl: sourceUrl,
    // );
    try {
      final response = await http.post(
        Uri.parse('$_serverBaseUrl/api/reader/fetch-content'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'book_url': bookUrl,
          'chapter_url': chapterUrl,
          'source_url': sourceUrl,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['content'] as String? ?? '';
      }
      throw RustApiException('获取章节内容失败: ${response.statusCode}');
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('获取章节内容失败: $e');
    }
  }

  // ===== 设置 =====

  /// 获取设置（Rust 侧暂未实现，预留接口）
  Future<Map<String, dynamic>> getSettings() async {
    return {};
  }

  /// 更新设置（Rust 侧暂未实现，预留接口）
  Future<void> updateSettings(Map<String, dynamic> settings) async {
    // 预留
  }

  // ===== 阅读统计 =====

  /// 获取今日阅读统计（时长秒数、字数、速度字/分钟）
  Future<ReadingStatsToday> getTodayReadingStats() async {
    try {
      final response = await http.get(
        Uri.parse('$_serverBaseUrl/api/stats/today'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return ReadingStatsToday.fromJson(data);
      }
      // 服务端未实现时返回空数据
      return const ReadingStatsToday();
    } catch (_) {
      return const ReadingStatsToday();
    }
  }

  /// 获取每日阅读时长列表（最近 N 天）
  ///
  /// 返回 Map：{ '2026-07-20': 3600, '2026-07-21': 1800, ... }（秒）
  Future<Map<String, int>> getDailyReadingStats({int days = 7}) async {
    try {
      final response = await http.get(
        Uri.parse('$_serverBaseUrl/api/stats/daily?days=$days'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  /// 获取各书籍阅读时长分布
  ///
  /// 返回 Map：{ '书名': 秒数, ... }
  Future<Map<String, int>> getBookReadingStats() async {
    try {
      final response = await http.get(
        Uri.parse('$_serverBaseUrl/api/stats/books'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  /// 获取阅读日历热力图数据（最近 30 天，每天秒数）
  Future<Map<String, int>> getReadingHeatmap({int days = 30}) async {
    try {
      final response = await http.get(
        Uri.parse('$_serverBaseUrl/api/stats/heatmap?days=$days'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  // ===== 听书音频 =====

  /// 本地服务器基础 URL
  String _serverBaseUrl = 'http://127.0.0.1:8080';

  /// 设置本地服务器 URL
  void setServerBaseUrl(String url) {
    _serverBaseUrl = url;
  }

  /// TTS 文本转语音（通过 HTTP 调用本地服务器）
  Future<Map<String, dynamic>> audioSpeak({
    required String text,
    required String engineUrl,
    double? speed,
    double? pitch,
    double? volume,
    String? voiceName,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverBaseUrl/api/audio/speak'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': text,
          'engine_url': engineUrl,
          'voice_name': voiceName,
          'speed': speed,
          'pitch': pitch,
          'volume': volume,
        }),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      throw RustApiException('TTS 请求失败: ${response.statusCode}');
    } catch (e) {
      throw RustApiException('TTS 调用失败: $e');
    }
  }

  /// 获取听书章节列表
  Future<List<Map<String, dynamic>>> audioGetChapters(String bookUrl) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverBaseUrl/api/audio/chapters'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'book_url': bookUrl}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final list = data['chapters'] as List? ?? [];
        return list.cast<Map<String, dynamic>>();
      }
      throw RustApiException('获取章节失败: ${response.statusCode}');
    } catch (e) {
      throw RustApiException('获取听书章节失败: $e');
    }
  }

  /// 播放控制
  Future<Map<String, dynamic>> audioPlayControl({
    required String action,
    String? bookUrl,
    int? jumpIndex,
    String? playMode,
  }) async {
    try {
      final Map<String, dynamic> body = {'action': action};
      if (bookUrl != null) body['book_url'] = bookUrl;
      if (jumpIndex != null) body['index'] = jumpIndex;
      if (playMode != null) body['mode'] = playMode;

      final response = await http.post(
        Uri.parse('$_serverBaseUrl/api/audio/play'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      throw RustApiException('播放控制失败: ${response.statusCode}');
    } catch (e) {
      throw RustApiException('播放控制调用失败: $e');
    }
  }
}

/// RustApi 调用异常
class RustApiException implements Exception {
  final String message;

  const RustApiException(this.message);

  @override
  String toString() => message;
}

/// 搜索结果
class SearchResult {
  final Book book;
  final String sourceUrl;
  final String sourceName;

  SearchResult({
    required this.book,
    required this.sourceUrl,
    required this.sourceName,
  });

  /// 从 FFI 返回的 JSON 构造。
  ///
  /// bridge 的 SearchResult JSON 格式：
  /// ```json
  /// {
  ///   "sourceUrl": "...",
  ///   "sourceName": "...",
  ///   "bookName": "...",
  ///   "author": "...",
  ///   "bookUrl": "...",
  ///   "latestChapter": "...",
  ///   "intro": "...",
  ///   "coverUrl": "..."
  /// }
  /// ```
  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      sourceUrl: json['sourceUrl'] as String? ?? '',
      sourceName: json['sourceName'] as String? ?? '',
      book: Book(
        name: json['bookName'] as String? ?? '',
        author: json['author'] as String? ?? '',
        bookUrl: json['bookUrl'] as String? ?? '',
        coverUrl: json['coverUrl'] as String?,
        intro: json['intro'] as String?,
        latestChapterTitle: json['latestChapter'] as String?,
      ),
    );
  }
}

/// RSS 文章（UI 层简化表示）
class RssFeedArticle {
  final String title;
  final String url;
  final String? description;
  final String? pubDate;
  final String? imageUrl;
  final String? content;
  final String sourceUrl;

  RssFeedArticle({
    required this.title,
    required this.url,
    this.description,
    this.pubDate,
    this.imageUrl,
    this.content,
    required this.sourceUrl,
  });
}

/// 今日阅读统计
class ReadingStatsToday {
  final int durationSeconds; // 阅读时长（秒）
  final int wordCount;       // 阅读字数
  final int readingSpeed;    // 阅读速度（字/分钟）

  const ReadingStatsToday({
    this.durationSeconds = 0,
    this.wordCount = 0,
    this.readingSpeed = 0,
  });

  factory ReadingStatsToday.fromJson(Map<String, dynamic> json) {
    return ReadingStatsToday(
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      wordCount: (json['wordCount'] as num?)?.toInt() ?? 0,
      readingSpeed: (json['readingSpeed'] as num?)?.toInt() ?? 0,
    );
  }
}
