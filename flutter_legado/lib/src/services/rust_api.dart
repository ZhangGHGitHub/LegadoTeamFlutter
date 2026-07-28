import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// 更新单本书的阅读配置
  ///
  /// 获取书籍 → 更新 readConfig 字段 → 调用 bookshelfUpdate 保存。
  Future<void> updateReadConfig(
    String bookUrl,
    Map<String, dynamic> config,
  ) async {
    try {
      final book = await getBook(bookUrl);
      if (book == null) {
        throw RustApiException('书籍不存在: $bookUrl');
      }
      final updated = book.copyWith(readConfig: ReadConfig.fromJson(config));
      await bridge.bookshelfUpdate(bookJson: jsonEncode(updated.toJson()));
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('更新阅读配置失败: $e');
    }
  }

  /// 获取单本书的阅读配置
  ///
  /// 返回 readConfig 的 Map 表示；书籍无自定义配置时返回默认值。
  Future<Map<String, dynamic>> getReadConfig(String bookUrl) async {
    try {
      final book = await getBook(bookUrl);
      if (book == null) {
        throw RustApiException('书籍不存在: $bookUrl');
      }
      return (book.readConfig ?? const ReadConfig()).toJson();
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('获取阅读配置失败: $e');
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

  /// 检查书籍更新（对比本地章节数与网络最新章节数）
  ///
  /// 返回 Map：{'hasUpdate': bool, 'newChapterCount': int, 'latestChapter': String}
  /// 注：Rust 侧尚未提供 bookshelf_check_update 单一 FFI，当前通过组合调用实现。
  Future<Map<String, dynamic>> checkUpdate(String bookUrl) async {
    try {
      final book = await getBook(bookUrl);
      if (book == null) {
        return {'hasUpdate': false, 'newChapterCount': 0, 'latestChapter': ''};
      }
      final sourceUrl = book.origin;
      if (sourceUrl.isEmpty || sourceUrl == 'loc_book') {
        return {'hasUpdate': false, 'newChapterCount': 0, 'latestChapter': ''};
      }
      final jsonStr = await bridge.readerRefreshToc(
        bookUrl: bookUrl,
        sourceUrl: sourceUrl,
      );
      final chapters = jsonDecode(jsonStr) as List;
      final localCount = book.totalChapterNum;
      final remoteCount = chapters.length;
      final hasUpdate = remoteCount > localCount;
      final latestChapter = chapters.isNotEmpty
          ? ((chapters.last as Map<String, dynamic>)['title'] as String? ?? '')
          : '';
      return {
        'hasUpdate': hasUpdate,
        'newChapterCount': remoteCount - localCount,
        'latestChapter': latestChapter,
      };
    } catch (e) {
      throw RustApiException('检查更新失败: $e');
    }
  }

  /// 批量检查书籍更新
  ///
  /// 逐本调用 [checkUpdate]，返回每本书的更新结果列表。
  /// 单本失败不影响其他书籍，失败项返回 hasUpdate=false 并附带 error 字段。
  Future<List<Map<String, dynamic>>> batchCheckUpdate(
    List<String> bookUrls,
  ) async {
    final results = <Map<String, dynamic>>[];
    for (final url in bookUrls) {
      try {
        final result = await checkUpdate(url);
        results.add({'bookUrl': url, ...result});
      } catch (e) {
        results.add({
          'bookUrl': url,
          'hasUpdate': false,
          'newChapterCount': 0,
          'latestChapter': '',
          'error': e.toString(),
        });
      }
    }
    return results;
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

  /// 获取章节正文（缓存优先）
  ///
  /// 先检查本地文件缓存，命中则直接返回；
  /// 未命中则通过 FFI 获取并存入缓存。
  Future<String> getBookContent(String bookUrl, int chapterIndex) async {
    try {
      // 1. 检查缓存
      final cached = await getChapterCache(bookUrl, chapterIndex);
      if (cached != null && cached.isNotEmpty) {
        return cached;
      }
      // 2. 缓存未命中，通过 FFI 获取
      final content = await bridge.readerGetContent(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
      );
      // 3. 写入缓存
      if (content.isNotEmpty) {
        final safeName = bookUrl.replaceAll(RegExp(r'[^\w]'), '_');
        final dir = Directory('$_cacheDir/$safeName');
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final file = File('$_cacheDir/$safeName/chapter_$chapterIndex.txt');
        await file.writeAsString(content);
      }
      return content;
    } catch (e) {
      if (e is RustApiException) rethrow;
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

  /// 导出单个书源为 JSON 数组字符串（用于分享）
  Future<String> exportBookSource(String sourceUrl) async {
    try {
      final sources = await getBookSources();
      final match =
          sources.where((s) => s.bookSourceUrl == sourceUrl).toList();
      if (match.isEmpty) {
        throw RustApiException('书源不存在: $sourceUrl');
      }
      return jsonEncode(match.map((e) => e.toJson()).toList());
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('导出书源失败: $e');
    }
  }

  /// 发现页浏览：获取书源的发现/探索结果
  ///
  /// 通过书源的 exploreUrl 发起 HTTP 请求，返回原始响应内容。
  /// UI 层可根据书源 ruleExplore 规则进一步解析。
  Future<String> exploreBookSource(String sourceUrl, int page) async {
    try {
      final sources = await getBookSources();
      final source = sources.cast<BookSource?>().firstWhere(
            (s) => s!.bookSourceUrl == sourceUrl,
            orElse: () => null,
          );
      if (source == null) {
        throw RustApiException('书源不存在: $sourceUrl');
      }
      final exploreUrl = source.exploreUrl;
      if (exploreUrl == null || exploreUrl.isEmpty) {
        throw RustApiException('该书源无发现页配置');
      }
      // 替换页码占位符
      final url = exploreUrl.replaceAll('{{page}}', page.toString());
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        return response.body;
      }
      throw RustApiException('发现页请求失败: ${response.statusCode}');
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('发现页浏览失败: $e');
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

  /// 导出单个 RSS 源为 JSON 数组字符串（用于分享）
  Future<String> exportRssSource(String sourceUrl) async {
    try {
      final sources = await getRssSources();
      final match = sources.where((s) => s.sourceUrl == sourceUrl).toList();
      if (match.isEmpty) {
        throw RustApiException('RSS 源不存在: $sourceUrl');
      }
      return jsonEncode(match.map((e) => e.toJson()).toList());
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('导出 RSS 源失败: $e');
    }
  }

  /// 获取 RSS 文章正文内容
  ///
  /// 通过 HTTP GET 获取文章链接的 HTML 内容，提取 body 文本。
  Future<String> getRssContent(String sourceUrl, String link) async {
    try {
      final response = await http.get(Uri.parse(link));
      if (response.statusCode == 200) {
        return response.body;
      }
      throw RustApiException('获取 RSS 正文失败: ${response.statusCode}');
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('获取 RSS 正文失败: $e');
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

  /// 获取书签列表（按书名）
  Future<List<Bookmark>> getBookmarks(String bookName) async {
    try {
      final jsonStr = await bridge.bookmarkGetAll(bookName: bookName);
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取书签失败: $e');
    }
  }

  /// 获取所有书签
  Future<List<Bookmark>> getAllBookmarks() async {
    try {
      final jsonStr = await bridge.bookmarkList();
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取所有书签失败: $e');
    }
  }

  /// 添加书签，返回带 ID 的书签
  Future<Bookmark> addBookmark(Bookmark bookmark) async {
    try {
      final id = await bridge.bookmarkAdd(
        bookName: bookmark.bookName,
        bookAuthor: bookmark.bookAuthor,
        chapterIndex: bookmark.chapterIndex,
        chapterPos: bookmark.chapterPos,
        chapterName: bookmark.chapterName,
        bookText: bookmark.bookText,
        content: bookmark.content,
      );
      return bookmark.copyWith(
        id: id,
        time: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    } catch (e) {
      throw RustApiException('添加书签失败: $e');
    }
  }

  /// 删除书签
  Future<void> deleteBookmark(int id) async {
    try {
      await bridge.bookmarkDelete(bookmarkId: id);
    } catch (e) {
      throw RustApiException('删除书签失败: $e');
    }
  }

  /// 搜索书签
  Future<List<Bookmark>> searchBookmarks(String keyword) async {
    try {
      final jsonStr = await bridge.bookmarkSearch(keyword: keyword);
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('搜索书签失败: $e');
    }
  }

  // ===== 替换规则 =====

  /// 获取所有替换规则
  Future<List<ReplaceRule>> getReplaceRules() async {
    try {
      final jsonStr = await bridge.replaceRuleList();
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取替换规则失败: $e');
    }
  }

  /// 获取启用的替换规则
  Future<List<ReplaceRule>> getEnabledReplaceRules() async {
    try {
      final jsonStr = await bridge.replaceRuleEnabled();
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取启用替换规则失败: $e');
    }
  }

  /// 添加替换规则，返回带 ID 的规则
  Future<ReplaceRule> addReplaceRule(ReplaceRule rule) async {
    try {
      final id = await bridge.replaceRuleAdd(
        name: rule.name,
        pattern: rule.pattern,
        replacement: rule.replacement,
        isRegex: rule.isRegex,
        scope: rule.scope ?? '',
      );
      return rule.copyWith(id: id);
    } catch (e) {
      throw RustApiException('添加替换规则失败: $e');
    }
  }

  /// 更新替换规则
  Future<void> updateReplaceRule(ReplaceRule rule) async {
    try {
      await bridge.replaceRuleUpdate(
        ruleId: rule.id,
        name: rule.name,
        pattern: rule.pattern,
        replacement: rule.replacement,
        isRegex: rule.isRegex,
        isEnabled: rule.isEnabled,
      );
    } catch (e) {
      throw RustApiException('更新替换规则失败: $e');
    }
  }

  /// 删除替换规则
  Future<void> deleteReplaceRule(int id) async {
    try {
      await bridge.replaceRuleDelete(ruleId: id);
    } catch (e) {
      throw RustApiException('删除替换规则失败: $e');
    }
  }

  /// 启用/禁用替换规则
  Future<void> setReplaceRuleEnabled(int id, bool enabled) async {
    try {
      await bridge.replaceRuleSetEnabled(ruleId: id, enabled: enabled);
    } catch (e) {
      throw RustApiException('设置替换规则启用状态失败: $e');
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

  /// 从网络刷新书籍目录
  ///
  /// [bookUrl] 书籍详情页 URL
  /// [sourceUrl] 书源 URL
  /// 返回章节列表（JSON 解析后的 BookChapter 列表）
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl) async {
    try {
      final jsonStr = await bridge.readerRefreshToc(
        bookUrl: bookUrl,
        sourceUrl: sourceUrl,
      );
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => BookChapter.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
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
    try {
      return await bridge.readerFetchContent(
        bookUrl: bookUrl,
        chapterUrl: chapterUrl,
        sourceUrl: sourceUrl,
      );
    } catch (e) {
      throw RustApiException('获取正文失败: $e');
    }
  }

  // ===== 设置 =====

  /// 获取设置（Rust 侧暂未实现，返回默认配置）
  Future<Map<String, dynamic>> getSettings() async {
    return {
      'theme': 'system',
      'fontSize': 18.0,
      'lineSpacing': 1.5,
      'autoCheckUpdate': true,
    };
  }

  /// 更新设置（Rust 侧暂未实现，预留接口）
  Future<void> updateSettings(Map<String, dynamic> settings) async {
    // 预留
  }

  // ===== 备份与恢复 =====
  // 注：Rust 侧尚未提供 backup/restore FFI，当前通过组合已有 FFI 调用实现。

  // ===== 阅读记录 =====
  // 注：Rust 侧尚未提供 read_record FFI，暂用 SharedPreferences 本地持久化。
  static const _kReadRecordKey = 'read_record_list';

  /// 获取阅读记录列表
  ///
  /// 返回按 readTime 降序排列的记录列表，每项含 bookUrl/bookName/readTime。
  Future<List<Map<String, dynamic>>> getReadRecord() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kReadRecordKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];
      final list = (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
      list.sort((a, b) =>
          (b['readTime'] as int? ?? 0).compareTo(a['readTime'] as int? ?? 0));
      return list;
    } catch (e) {
      throw RustApiException('获取阅读记录失败: $e');
    }
  }

  /// 添加/更新阅读记录
  ///
  /// 同一 bookUrl 的记录会被覆盖（取最新 readTime）。
  Future<void> putReadRecord({
    required String bookUrl,
    required String bookName,
    required int readTime,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getReadRecord();
      list.removeWhere((e) => e['bookUrl'] == bookUrl);
      list.add({'bookUrl': bookUrl, 'bookName': bookName, 'readTime': readTime});
      await prefs.setString(_kReadRecordKey, jsonEncode(list));
    } catch (e) {
      throw RustApiException('保存阅读记录失败: $e');
    }
  }

  /// 删除指定书籍的阅读记录
  Future<void> deleteReadRecord(String bookUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getReadRecord();
      list.removeWhere((e) => e['bookUrl'] == bookUrl);
      await prefs.setString(_kReadRecordKey, jsonEncode(list));
    } catch (e) {
      throw RustApiException('删除阅读记录失败: $e');
    }
  }

  /// 清空所有阅读记录
  Future<void> clearReadRecord() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kReadRecordKey);
    } catch (e) {
      throw RustApiException('清空阅读记录失败: $e');
    }
  }

  // ===== RSS 收藏 =====
  // 注：Rust 侧尚未提供 rss_star FFI，暂用 SharedPreferences 本地持久化。
  static const _kRssStarKey = 'rss_star_list';

  /// 获取 RSS 收藏/订阅文章列表
  Future<List<Map<String, dynamic>>> getRssStars() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kRssStarKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];
      return (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      throw RustApiException('获取 RSS 订阅失败: $e');
    }
  }

  /// 添加 RSS 订阅文章
  Future<void> addRssStar(Map<String, dynamic> star) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getRssStars();
      list.add(star);
      await prefs.setString(_kRssStarKey, jsonEncode(list));
    } catch (e) {
      throw RustApiException('添加 RSS 订阅失败: $e');
    }
  }

  /// 删除 RSS 订阅文章（按 origin + sort 匹配）
  Future<void> deleteRssStar(String origin, String sort) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getRssStars();
      list.removeWhere(
        (e) => e['origin'] == origin && e['sort'] == sort,
      );
      await prefs.setString(_kRssStarKey, jsonEncode(list));
    } catch (e) {
      throw RustApiException('删除 RSS 订阅失败: $e');
    }
  }

  // ===== 书籍分组 =====
  // 注：Rust 侧尚未提供 book_group FFI，暂用 SharedPreferences 本地持久化。
  static const _kBookGroupKey = 'book_group_list';

  /// 获取所有书籍分组
  Future<List<Map<String, dynamic>>> getBookGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kBookGroupKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];
      return (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      throw RustApiException('获取书籍分组失败: $e');
    }
  }

  /// 添加书籍分组
  Future<void> addBookGroup(Map<String, dynamic> group) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getBookGroups();
      list.add(group);
      await prefs.setString(_kBookGroupKey, jsonEncode(list));
    } catch (e) {
      throw RustApiException('添加书籍分组失败: $e');
    }
  }

  /// 删除书籍分组（按 groupId）
  Future<void> deleteBookGroup(int groupId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getBookGroups();
      list.removeWhere((e) => e['groupId'] == groupId);
      await prefs.setString(_kBookGroupKey, jsonEncode(list));
    } catch (e) {
      throw RustApiException('删除书籍分组失败: $e');
    }
  }

  /// 更新书籍分组（按 groupId 匹配替换）
  Future<void> updateBookGroup(Map<String, dynamic> group) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getBookGroups();
      final idx = list.indexWhere((e) => e['groupId'] == group['groupId']);
      if (idx >= 0) {
        list[idx] = group;
        await prefs.setString(_kBookGroupKey, jsonEncode(list));
      }
    } catch (e) {
      throw RustApiException('更新书籍分组失败: $e');
    }
  }

  /// 获取书架分组显示状态列表
  ///
  /// 返回 [{'groupId': 1, 'show': true}, ...]
  Future<List<Map<String, dynamic>>> getBookGroupShows() async {
    try {
      final groups = await getBookGroups();
      return groups
          .map((g) => {
                'groupId': g['groupId'] ?? 0,
                'show': g['show'] ?? true,
              })
          .toList();
    } catch (e) {
      throw RustApiException('获取分组显示状态失败: $e');
    }
  }

  /// 设置分组是否在书架显示
  Future<void> setBookGroupShow(int groupId, bool show) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getBookGroups();
      final idx = list.indexWhere((e) => e['groupId'] == groupId);
      if (idx >= 0) {
        list[idx] = {...list[idx], 'show': show};
        await prefs.setString(_kBookGroupKey, jsonEncode(list));
      }
    } catch (e) {
      throw RustApiException('设置分组显示状态失败: $e');
    }
  }

  // ===== 搜索历史 =====
  static const _kSearchHistoryKey = 'search_history';
  static const _kSearchHistoryMax = 20;

  /// 获取搜索历史（最近 20 条，最新在前）
  Future<List<String>> getSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_kSearchHistoryKey) ?? [];
    } catch (e) {
      throw RustApiException('获取搜索历史失败: $e');
    }
  }

  /// 添加搜索历史（去重，新词置顶，超过 20 条截断）
  Future<void> addSearchHistory(String keyword) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_kSearchHistoryKey) ?? [];
      list.remove(keyword);
      list.insert(0, keyword);
      if (list.length > _kSearchHistoryMax) {
        list.removeRange(_kSearchHistoryMax, list.length);
      }
      await prefs.setStringList(_kSearchHistoryKey, list);
    } catch (e) {
      throw RustApiException('保存搜索历史失败: $e');
    }
  }

  /// 清空搜索历史
  Future<void> clearSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSearchHistoryKey);
    } catch (e) {
      throw RustApiException('清空搜索历史失败: $e');
    }
  }

  // ===== 缓存管理 =====

  /// 缓存根目录（可通过 [setCacheDir] 配置）
  String _cacheDir = 'cache';

  /// 设置缓存目录路径
  void setCacheDir(String path) {
    _cacheDir = path;
  }

  /// 获取缓存大小（字节）
  Future<int> getCacheSize() async {
    try {
      final dir = Directory(_cacheDir);
      if (!await dir.exists()) return 0;
      var size = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          size += await entity.length();
        }
      }
      return size;
    } catch (e) {
      throw RustApiException('获取缓存大小失败: $e');
    }
  }

  /// 清空缓存目录
  Future<void> clearCache() async {
    try {
      final dir = Directory(_cacheDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      throw RustApiException('清空缓存失败: $e');
    }
  }

  /// 获取章节缓存内容（不存在返回 null）
  Future<String?> getChapterCache(String bookUrl, int chapterIndex) async {
    try {
      final safeName = bookUrl.replaceAll(RegExp(r'[^\w]'), '_');
      final file = File('$_cacheDir/$safeName/chapter_$chapterIndex.txt');
      if (await file.exists()) {
        return await file.readAsString();
      }
      return null;
    } catch (e) {
      throw RustApiException('读取章节缓存失败: $e');
    }
  }

  /// 获取书籍缓存文件列表
  ///
  /// 返回 [{'name': 'chapter_0.txt', 'size': 1234}, ...]
  Future<List<Map<String, dynamic>>> getCacheBookFiles(String bookUrl) async {
    try {
      final safeName = bookUrl.replaceAll(RegExp(r'[^\w]'), '_');
      final dir = Directory('$_cacheDir/$safeName');
      if (!await dir.exists()) return [];
      final files = <Map<String, dynamic>>[];
      await for (final entity in dir.list()) {
        if (entity is File) {
          files.add({
            'name': entity.uri.pathSegments.last,
            'size': await entity.length(),
          });
        }
      }
      files.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      return files;
    } catch (e) {
      throw RustApiException('获取缓存文件列表失败: $e');
    }
  }

  /// 创建备份：将书架、书签、替换规则、TTS 引擎导出为 JSON 文件
  Future<void> backupCreate(String path) async {
    try {
      final books = await getBooks();
      final bookmarks = await getAllBookmarks();
      final rules = await getReplaceRules();
      final ttsList = await getHttpTts();
      final backup = {
        'version': 1,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'books': books.map((e) => e.toJson()).toList(),
        'bookmarks': bookmarks.map((e) => e.toJson()).toList(),
        'replaceRules': rules.map((e) => e.toJson()).toList(),
        'httpTts': ttsList.map((e) => e.toJson()).toList(),
      };
      final file = File(path);
      await file.writeAsString(jsonEncode(backup));
    } catch (e) {
      throw RustApiException('创建备份失败: $e');
    }
  }

  /// 恢复备份：从 JSON 文件读取并还原数据
  Future<void> backupRestore(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw RustApiException('备份文件不存在: $path');
      }
      final content = await file.readAsString();
      final backup = jsonDecode(content) as Map<String, dynamic>;

      // 还原书架
      final books = backup['books'] as List? ?? [];
      for (final item in books) {
        final book = Book.fromJson((item as Map).cast<String, dynamic>());
        await addBook(book);
      }

      // 还原书签
      final bookmarks = backup['bookmarks'] as List? ?? [];
      for (final item in bookmarks) {
        final bm = Bookmark.fromJson((item as Map).cast<String, dynamic>());
        await addBookmark(bm);
      }

      // 还原替换规则
      final rules = backup['replaceRules'] as List? ?? [];
      for (final item in rules) {
        final rule = ReplaceRule.fromJson((item as Map).cast<String, dynamic>());
        await addReplaceRule(rule);
      }

      // 还原 TTS 引擎
      final ttsList = backup['httpTts'] as List? ?? [];
      if (ttsList.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final existing = await getHttpTts();
        for (final item in ttsList) {
          final tts = HttpTts.fromJson((item as Map).cast<String, dynamic>());
          existing.add(tts);
        }
        await prefs.setString(
          _kHttpTtsKey,
          jsonEncode(existing.map((e) => e.toJson()).toList()),
        );
      }
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('恢复备份失败: $e');
    }
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

  // 注：Rust 侧尚未提供 http_tts FFI，暂用 SharedPreferences 本地持久化。
  static const _kHttpTtsKey = 'http_tts_list';

  /// 获取所有 HTTP TTS 朗读引擎
  Future<List<HttpTts>> getHttpTts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kHttpTtsKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => HttpTts.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw RustApiException('获取 HTTP TTS 失败: $e');
    }
  }

  /// 添加 HTTP TTS 朗读引擎
  Future<HttpTts> addHttpTts(HttpTts tts) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getHttpTts();
      final newTts = tts.copyWith(
        id: DateTime.now().millisecondsSinceEpoch,
      );
      list.add(newTts);
      await prefs.setString(
        _kHttpTtsKey,
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
      return newTts;
    } catch (e) {
      throw RustApiException('添加 HTTP TTS 失败: $e');
    }
  }

  /// 删除 HTTP TTS 朗读引擎
  Future<void> deleteHttpTts(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getHttpTts();
      list.removeWhere((e) => e.id == id);
      await prefs.setString(
        _kHttpTtsKey,
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      throw RustApiException('删除 HTTP TTS 失败: $e');
    }
  }

  /// 更新 HTTP TTS 朗读引擎
  Future<void> updateHttpTts(HttpTts tts) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getHttpTts();
      final idx = list.indexWhere((e) => e.id == tts.id);
      if (idx >= 0) {
        list[idx] = tts;
        await prefs.setString(
          _kHttpTtsKey,
          jsonEncode(list.map((e) => e.toJson()).toList()),
        );
      }
    } catch (e) {
      throw RustApiException('更新 HTTP TTS 失败: $e');
    }
  }

  /// 批量导入 HTTP TTS 朗读引擎，返回成功导入数量
  Future<int> importTts(String jsonArray) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getHttpTts();
      final imported = jsonDecode(jsonArray) as List;
      var count = 0;
      for (final item in imported) {
        final tts = HttpTts.fromJson(
          (item as Map).cast<String, dynamic>(),
        );
        list.add(tts.copyWith(
          id: DateTime.now().millisecondsSinceEpoch + count,
        ));
        count++;
      }
      await prefs.setString(
        _kHttpTtsKey,
        jsonEncode(list.map((e) => e.toJson()).toList()),
      );
      return count;
    } catch (e) {
      throw RustApiException('导入 HTTP TTS 失败: $e');
    }
  }

  /// 导出所有 HTTP TTS 朗读引擎为 JSON 数组字符串
  Future<String> exportTts() async {
    try {
      final list = await getHttpTts();
      return jsonEncode(list.map((e) => e.toJson()).toList());
    } catch (e) {
      throw RustApiException('导出 HTTP TTS 失败: $e');
    }
  }

  /// TTS 预览：直接调用朗读引擎 URL 获取音频数据
  ///
  /// 通过 HTTP GET 请求引擎 URL（非 legado-server），返回音频字节流。
  Future<List<int>> ttsPreview({
    required String text,
    required String engineUrl,
    String? voiceName,
    double? speed,
    double? pitch,
    double? volume,
  }) async {
    try {
      final params = <String, String>{'text': text};
      if (voiceName != null) params['name'] = voiceName;
      if (speed != null) params['speed'] = speed.toString();
      if (pitch != null) params['pitch'] = pitch.toString();
      if (volume != null) params['volume'] = volume.toString();
      final uri = Uri.parse(engineUrl).replace(queryParameters: params);
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      throw RustApiException('TTS 预览失败: ${response.statusCode}');
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('TTS 预览失败: $e');
    }
  }

  /// TTS 朗读：调用引擎 URL 获取音频字节流
  ///
  /// 简化版接口，用于听书播放场景。
  Future<List<int>> ttsSpeak(
    String text,
    String engineUrl, {
    String? voiceName,
  }) async {
    try {
      final params = <String, String>{'text': text};
      if (voiceName != null) params['name'] = voiceName;
      final uri = Uri.parse(engineUrl).replace(queryParameters: params);
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      throw RustApiException('TTS 朗读失败: ${response.statusCode}');
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('TTS 朗读失败: $e');
    }
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

  /// 获取听书章节媒体信息（音频 URL、时长、标题等）
  Future<Map<String, dynamic>> audioGetChapterMedia(
    String bookUrl,
    int chapterIndex,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverBaseUrl/api/audio/chapter-media'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'book_url': bookUrl, 'index': chapterIndex}),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      throw RustApiException('获取章节媒体失败: ${response.statusCode}');
    } catch (e) {
      if (e is RustApiException) rethrow;
      throw RustApiException('获取章节媒体失败: $e');
    }
  }

  // ===== 听书进度 =====
  static const _kAudioProgressPrefix = 'audio_progress_';

  /// 获取听书进度
  ///
  /// 返回 {'index': int, 'position': int}；无进度时返回默认值。
  Future<Map<String, dynamic>> audioGetProgress(String bookUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('$_kAudioProgressPrefix$bookUrl');
      if (jsonStr == null || jsonStr.isEmpty) {
        return {'index': 0, 'position': 0};
      }
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      throw RustApiException('获取听书进度失败: $e');
    }
  }

  /// 保存听书进度
  Future<void> audioSaveProgress(
    String bookUrl,
    int index,
    int position,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_kAudioProgressPrefix$bookUrl',
        jsonEncode({'index': index, 'position': position}),
      );
    } catch (e) {
      throw RustApiException('保存听书进度失败: $e');
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
