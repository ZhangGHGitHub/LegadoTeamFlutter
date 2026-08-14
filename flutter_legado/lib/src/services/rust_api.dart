import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;
import 'bridge_http.dart';
import 'package:path_provider/path_provider.dart';

import '../bridge/rust_lib.dart' as bridge;
import '../models/models.dart';
import 'book_api.dart';
import 'platform_bridge_service.dart';

/// Rust FFI 统一访问层
///
/// 所有数据库操作通过 flutter_rust_bridge 生成的桥接函数调用 Rust 侧。
/// 尚未在 Rust FFI 中暴露的方法使用 Dart 侧 fallback 实现。
class RustApi implements BookApi {
  RustApi();

  bool _initialized = false;

  /// 初始化 Rust 运行时和数据库连接
  @override
  Future<void> initialize() async {
    if (_initialized) return;

    final lib = _resolveFfiLibrary();
    await bridge.RustLib.init(externalLibrary: lib);
    await bridge.init();

    final dbPath = await _defaultDbPath();
    await bridge.dbOpen(path: dbPath);

    // [UI-fix v2.0.2 | 2026-08-06] TTS 缓存目录初始化接线 — QoderCN
    await _initTtsCacheDir();

    _initialized = true;
  }

  /// 设置 TTS 音频缓存目录（应用初始化时调用）— QoderCN
  ///
  /// Rust 默认落系统临时目录（Android 可能不可写），改指向应用支持目录
  /// 下的 tts_cache 子目录；取不到路径时保留默认并仅记日志，不阻断初始化。
  Future<void> _initTtsCacheDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir =
          Directory('${base.path}${Platform.pathSeparator}tts_cache');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final ok = await bridge.ttsSetCacheDir(path: dir.path);
      debugPrint('[RustApi] ttsSetCacheDir -> ${dir.path}（ok=$ok）');
    } catch (e) {
      debugPrint('[RustApi] ttsSetCacheDir 初始化失败，保留 Rust 默认目录：$e');
    }
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
  @override
  Future<String> getVersion() => bridge.version();

  // [审计修复 §4.2] jsonDecode 守卫：类型不符时抛带上下文的 FormatException，
  // 避免 Rust 返回结构漂移时直接 TypeError 崩溃（契约 §1.4 历史教训） — QoderCN

  /// 解码 JSON 数组，类型不符时抛带方法上下文的 [FormatException]
  List<dynamic> _decodeList(String json, String method) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is List<dynamic>) return decoded;
    throw FormatException(
      '$method（RustApi 列表解码）: 期望 JSON 数组，实际为 ${decoded.runtimeType}，'
      '原始内容前 120 字符：${json.length > 120 ? json.substring(0, 120) : json}',
    );
  }

  /// 解码 JSON 对象，类型不符时抛带方法上下文的 [FormatException]
  Map<String, dynamic> _decodeMap(String json, String method) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw FormatException(
      '$method（RustApi 对象解码）: 期望 JSON 对象，实际为 ${decoded.runtimeType}，'
      '原始内容前 120 字符：${json.length > 120 ? json.substring(0, 120) : json}',
    );
  }

  // ========== 书架操作 ==========

  /// 获取书架上所有书籍
  @override
  Future<List<Book>> getBooks() async {
    final json = await bridge.bookshelfList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => Book.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书籍到书架
  @override
  Future<Book> addBook(Book book) async {
    final json = await bridge.bookshelfAdd(bookJson: jsonEncode(book.toJson()));
    return Book.fromJson(_decodeMap(json, 'bookApi'));
  }

  /// 更新书籍信息
  @override
  Future<void> updateBook(Book book) =>
      bridge.bookshelfUpdate(bookJson: jsonEncode(book.toJson()));

  /// 从书架删除书籍
  @override
  Future<void> deleteBook(String bookUrl) =>
      bridge.bookshelfDelete(bookUrl: bookUrl);

  /// 按 bookUrl 获取书籍详情
  @override
  Future<Book?> getBook(String bookUrl) async {
    final json = await bridge.bookshelfGet(bookUrl: bookUrl);
    if (json.isEmpty || json == 'null') return null;
    return Book.fromJson(_decodeMap(json, 'bookApi'));
  }

  /// 置顶书籍（通过设置 order 为负值实现）
  @override
  Future<void> topBook(String bookUrl) async {
    final book = await getBook(bookUrl);
    if (book == null) return;
    await bridge.bookshelfUpdate(
      bookJson: jsonEncode(book.copyWith(order: -1).toJson()),
    );
  }

  /// 取消置顶（恢复 order 为 0）
  @override
  Future<void> unTopBook(String bookUrl) async {
    final book = await getBook(bookUrl);
    if (book == null) return;
    await bridge.bookshelfUpdate(
      bookJson: jsonEncode(book.copyWith(order: 0).toJson()),
    );
  }

  /// 设置书籍分组
  @override
  Future<void> setBookGroup(String bookUrl, int groupId) async {
    final book = await getBook(bookUrl);
    if (book == null) return;
    await bridge.bookshelfUpdate(
      bookJson: jsonEncode(book.copyWith(group: groupId).toJson()),
    );
  }

  /// 批量导入书籍，返回成功导入的数量
  @override
  Future<int> importBooks(String jsonArray) =>
      bridge.bookshelfImport(jsonArray: jsonArray);

  /// 批量持久化书架拖拽排序
  @override
  Future<void> reorderBooks(List<Map<String, dynamic>> orders) =>
      bridge.bookshelfReorderOrders(ordersJson: jsonEncode(orders));

  // ========== 书源操作 ==========

  /// 获取所有书源
  @override
  Future<List<BookSource>> getBookSources() async {
    final json = await bridge.sourceList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取所有启用的书源
  @override
  Future<List<BookSource>> getEnabledBookSources() async {
    final json = await bridge.sourceListEnabled();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书源
  @override
  Future<BookSource> addBookSource(BookSource source) async {
    final json =
        await bridge.sourceAdd(sourceJson: jsonEncode(source.toJson()));
    return BookSource.fromJson(_decodeMap(json, 'bookApi'));
  }

  /// 更新书源
  @override
  Future<void> updateBookSource(BookSource source) =>
      bridge.sourceUpdate(sourceJson: jsonEncode(source.toJson()));

  /// 设置书源自定义变量（契约 §2.3，台账 §5.11-3，Task #65）
  ///
  /// 直通 set_source_variable FFI（单列 UPDATE，空串=清除）；
  /// 书源不存在/写入失败由 Rust 侧抛 BridgeError — Qoder
  @override
  Future<void> setSourceVariable(String sourceUrl, String variable) =>
      bridge.setSourceVariable(sourceUrl: sourceUrl, variable: variable);

  /// 清除 Cookie（契约 §2.3 clearCookie，对齐原版 CookieStore.removeCookie）
  @override
  Future<void> clearCookie(String url) => bridge.clearCookie(url: url);

  @override
  Future<bool> looksLikeCurl(String text) => bridge.looksLikeCurl(text: text);

  @override
  Future<String> curlToAnalyzeUrl(String text) =>
      bridge.curlToAnalyzeUrl(text: text);

  @override
  Future<String> analyzeUrlToCurl(String text) =>
      bridge.analyzeUrlToCurl(text: text);


  /// 删除书源
  @override
  Future<void> deleteBookSource(String sourceUrl) =>
      bridge.sourceDelete(sourceUrl: sourceUrl);

  /// 启用书源
  @override
  Future<void> enableBookSource(String sourceUrl) =>
      bridge.sourceEnable(sourceUrl: sourceUrl);

  /// 禁用书源
  @override
  Future<void> disableBookSource(String sourceUrl) =>
      bridge.sourceDisable(sourceUrl: sourceUrl);

  /// 批量导入书源，返回成功导入的数量
  @override
  Future<int> importBookSources(String jsonArray) =>
      bridge.sourceImport(jsonArray: jsonArray);

  /// 导出所有书源为 JSON 数组
  @override
  Future<String> exportBookSources() => bridge.sourceExport();

  /// 书源排序（将排序偏好存入配置）
  @override
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

  /// 提取 JS 单文件书源配置（返回 BookSource JSON，需 QuickJS 构建）
  @override
  Future<String> extractJsSource(String content) =>
      bridge.jsSourceExtract(content: content);

  /// JS 书源语法检查（返回含 valid/message/line 的 JSON）
  @override
  Future<String> checkJsSourceSyntax(String content) =>
      bridge.jsSourceSyntaxCheck(content: content);

  /// 写回 JS 书源顶层配置的 lastUpdateTime（返回替换后脚本文本，无匹配时空串）
  @override
  Future<String> stampJsSourceLastUpdateTime(String content, int stamp) =>
      bridge.jsSourceStampLastUpdateTime(content: content, stamp: stamp);

  // ========== 书源校验（Task #87） ==========

  /// 校验单个书源（搜索→详情→目录→正文四步 + 验证码/重定向检测）
  ///
  /// Rust 侧返回 CheckResult JSON，字段见 [BookApi.checkSource]。
  @override
  Future<Map<String, dynamic>> checkSource(
    String sourceJson, {
    String? configJson,
  }) async {
    final json = await bridge.sourceCheck(
      sourceJson: sourceJson,
      configJson: configJson ?? '',
    );
    return _decodeMap(json, 'checkSource');
  }

  /// 批量校验书源（串行逐个回推进度）
  ///
  /// 每完成一个书源推送一条进度 Map，字段见 [BookApi.checkSourcesStream]。
  @override
  Stream<Map<String, dynamic>> checkSourcesStream(
    List<String> sourceUrls, {
    String? configJson,
  }) {
    final urlsJson = jsonEncode(sourceUrls);
    return bridge
        .sourceCheckStream(
          sourceUrlsJson: urlsJson,
          configJson: configJson ?? '',
        )
        .map((item) => _decodeMap(item, 'checkSourcesStream'));
  }

  /// 取消正在进行的批量书源校验
  @override
  Future<void> cancelCheckSources() => bridge.sourceCheckCancel();

  // ========== 书源登录 V2 动态状态协议（上游 #402/#488） — QoderCN ==========

  /// 判定书源登录 UI 是否为 V2 动态状态协议
  @override
  Future<bool> isLoginUiV2(String sourceJson) =>
      bridge.sourceIsLoginUiV2(sourceJson: sourceJson);

  /// 执行 loginUi v2 脚本，返回动态 UI 描述 JSON（`{"rows":[...]}`）
  @override
  Future<String> loginUiV2(String sourceJson, String stateJson) async =>
      // 平台桥接拦截：脚本可能以 webView 类桥接载荷作为整体返回（Task #114）— QoderCN
      PlatformBridgeService.instance.interceptResult(
        await bridge.sourceLoginUiV2(sourceJson: sourceJson, stateJson: stateJson),
      );

  /// 执行登录 V2 action 命令（返回命令 JSON：state/error/login/close）
  @override
  Future<String> loginActionV2(String sourceJson, String userInputJson) async =>
      // 平台桥接拦截（Task #114）— QoderCN
      PlatformBridgeService.instance.interceptResult(
        await bridge.sourceLoginActionV2(
          sourceJson: sourceJson,
          userInputJson: userInputJson,
        ),
      );

  // ========== 验证码交互通道（Task #90） ==========

  /// 订阅验证码请求事件流（长期存活）
  ///
  /// 事件 Map 字段见 [BookApi.verificationRequestStream]。
  /// 订阅时 Rust 侧先回放当前进行中的请求。
  @override
  Stream<Map<String, dynamic>> verificationRequestStream() {
    return bridge
        .verificationRequestStream()
        .map((item) => _decodeMap(item, 'verificationRequestStream'));
  }

  /// 提交验证码结果，唤醒 JS 等待方（对齐 Kotlin `setResult`）
  @override
  Future<bool> submitVerificationResult(String key, String code) =>
      bridge.verificationSubmit(key: key, code: code);

  /// 取消验证码请求（对齐 Kotlin `checkResult`：以空结果唤醒等待方）
  @override
  Future<bool> cancelVerificationRequest(String key) =>
      bridge.verificationCancel(key: key);

  // ========== BackstageWebView DOM 通道（SOURCE_DIFF P1） ==========

  @override
  Stream<Map<String, dynamic>> webviewRequestStream() {
    return bridge
        .webviewRequestStream()
        .map((item) => _decodeMap(item, 'webviewRequestStream'));
  }

  @override
  Future<bool> submitWebviewResult(String key, String result) =>
      bridge.webviewSubmit(key: key, result: result);

  @override
  Future<bool> cancelWebviewRequest(String key) =>
      bridge.webviewCancel(key: key);

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
    return list
        .map((e) {
          final map = e as Map<String, dynamic>;
          return SearchResult.fromSearchBook(
            SearchBook.fromJson(map),
            hasReadRecord: map['hasReadRecord'] == true,
          );
        })
        .toList();
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
  @override
  Stream<Map<String, dynamic>> searchMultiStream(
    String query, {
    List<String>? sourceUrls,
  }) {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    return bridge
        .searchMultiStream(query: query, sourceUrlsJson: urlsJson)
        .map((batch) => _decodeMap(batch, 'searchMultiStream'));
  }

  /// 取消搜索
  @override
  Future<void> cancelSearch() => bridge.searchCancel();

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
  }) async {
    final urlsJson = sourceUrls != null ? jsonEncode(sourceUrls) : '[]';
    final optionsJson = jsonEncode({
      'loadInfo': loadInfo,
      'loadToc': loadToc,
      'loadWordCount': loadWordCount,
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
  ) =>
      bridge.sourceSwitchApply(
        bookUrl: bookUrl,
        newSourceUrl: newSourceUrl,
        newBookUrl: newBookUrl,
      );

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
    final json =
        await bridge.rssAddSource(sourceJson: jsonEncode(source.toJson()));
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
    final json =
        await bridge.rssListReadRecordsByOrigin(origin: origin, limit: limit);
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
      throw RustApiException('导入成功但缺少书籍数据',
          operation: 'importLocalBook');
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
  }) =>
      bridge.txtSearchCount(
        path: path,
        query: query,
        caseSensitive: caseSensitive,
      );

  /// 解码 txt_search 系列返回的 JSON 数组（每项为 TxtSearchResult 对象）
  List<Map<String, dynamic>> _decodeSearchResults(String json) {
    final list = _decodeList(json, 'txtSearch');
    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  // ========== 书签操作 ==========

  /// 获取某本书的所有书签
  @override
  Future<List<Bookmark>> getBookmarks(String bookName) async {
    final json = await bridge.bookmarkGetAll(bookName: bookName);
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 按书名+作者获取某本书的所有书签（契约 §2.7，台账 §5.14-2，Task #65）
  ///
  /// get_bookmarks_by_book FFI 返回裸 JSON Array，解析方式同
  /// [getBookmarks]（bookmark_get_all）— Qoder
  @override
  Future<List<Bookmark>> getBookmarksByBook(
    String bookName,
    String bookAuthor,
  ) async {
    final json = await bridge.getBookmarksByBook(
      bookName: bookName,
      bookAuthor: bookAuthor,
    );
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取所有书签
  @override
  Future<List<Bookmark>> getAllBookmarks() async {
    final json = await bridge.bookmarkList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书签
  @override
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
  @override
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
  @override
  Future<void> deleteBookmark(int id) =>
      bridge.bookmarkDelete(bookmarkId: id);

  /// 搜索书签
  @override
  Future<List<Bookmark>> searchBookmarks(String keyword) async {
    final json = await bridge.bookmarkSearch(keyword: keyword);
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ========== 替换规则操作 ==========

  /// 获取所有替换规则
  @override
  Future<List<ReplaceRule>> getReplaceRules() async {
    final json = await bridge.replaceRuleList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取启用的替换规则
  @override
  Future<List<ReplaceRule>> getEnabledReplaceRules() async {
    final json = await bridge.replaceRuleEnabled();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加替换规则
  @override
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
  @override
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
  @override
  Future<void> deleteReplaceRule(int id) =>
      bridge.replaceRuleDelete(ruleId: id);

  /// 启用/禁用替换规则
  @override
  Future<void> setReplaceRuleEnabled(int id, bool enabled) =>
      bridge.replaceRuleSetEnabled(ruleId: id, enabled: enabled);

  // ========== 阅读器操作 ==========

  /// 获取书籍的章节列表
  @override
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
  @override
  Future<String> getChapterContent(String bookUrl, int chapterIndex) =>
      bridge.readerGetContent(bookUrl: bookUrl, chapterIndex: chapterIndex);

  /// 获取章节正文内容（不应用替换规则，用于内容搜索）
  ///
  /// 取正文流程与 [getChapterContent] 相同，但净化时关闭替换规则，
  /// 与 Android 书内搜索默认行为（replaceEnabled=false）对齐。
  @override
  Future<String> getChapterContentRaw(String bookUrl, int chapterIndex) =>
      bridge.readerGetContentRaw(bookUrl: bookUrl, chapterIndex: chapterIndex);

  /// 一次调用获取章节正文（合并 getChapterContent + fetchChapterContent）
  ///
  /// 本地书籍直接解析返回；在线书籍自动从网络抓取并返回净化后的正文。
  /// 始终返回纯正文字符串，不返回 JSON 元数据。
  @override
  Future<String> getChapterContentFull(String bookUrl, int chapterIndex) async =>
      // 平台桥接拦截：正文规则可能以 webView 类桥接载荷作为整体返回（Task #114）— QoderCN
      PlatformBridgeService.instance.interceptResult(
        await bridge.readerGetContentFull(bookUrl: bookUrl, chapterIndex: chapterIndex),
      );

  /// 从网络获取章节正文（带 DB 缓存）
  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async =>
      // 平台桥接拦截（Task #114）— QoderCN
      PlatformBridgeService.instance.interceptResult(
        await bridge.readerFetchContent(
          bookUrl: bookUrl,
          chapterUrl: chapterUrl,
          sourceUrl: sourceUrl,
        ),
      );

  // [Service-fix v2.0.3 | 2026-08-08] 写入/覆盖单章缓存正文
  // （契约 §2.43.1，对标原版 BookHelp.saveText 写回链路） — QoderCN
  @override
  Future<bool> saveChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required String title,
    required String content,
  }) async =>
      bridge.saveChapterContent(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        title: title,
        content: content,
        // 空串由 Rust 侧从 DB 章节表回填 chapter_url
        chapterUrl: '',
      );

  /// 更新阅读进度
  @override
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
  @override
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl) async {
    // 平台桥接拦截：目录规则可能以桥接载荷作为整体返回（Task #114）— QoderCN
    final json = await PlatformBridgeService.instance.interceptResult(
      await bridge.readerRefreshToc(bookUrl: bookUrl, sourceUrl: sourceUrl),
    );
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

  /// 设置阅读器繁简转换类型并持久化（0=不转换 / 1=繁转简 / 2=简转繁）
  ///
  /// 语义对齐 Android `AppConfig.chineseConverterType`；非法取值归一为 0。
  @override
  Future<void> setChineseConvertType(int type) =>
      bridge.readerSetChineseConvert(convertType: type);

  /// 获取当前繁简转换类型（0=不转换 / 1=繁转简 / 2=简转繁）
  @override
  Future<int> getChineseConvertType() => bridge.readerGetChineseConvert();

  /// 章级「删除重复标题」开关（契约 §2.9.10，Task #50 加法式新增）
  ///
  /// enable=true 恢复全局默认（去除重复标题）；false 该章保留原始标题。
  /// 状态持久化于 Rust 侧 DB，重启后保持。
  @override
  Future<void> toggleSameTitleRemoved(
    String bookUrl,
    int chapterIndex,
    bool enable,
  ) =>
      bridge.readerToggleSameTitleRemoved(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        enable: enable,
      );

  @override
  Future<bool> getSameTitleRemoved(String bookUrl, int chapterIndex) =>
      bridge.readerGetSameTitleRemoved(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
      );

  @override
  Future<bool> canRemoveSameTitle(String chapterTitle, String rawContent) =>
      bridge.readerCanRemoveSameTitle(
        chapterTitle: chapterTitle,
        rawContent: rawContent,
      );

  // ========== 配置操作 ==========

  /// 获取配置值
  @override
  Future<String?> getConfig(String key) async {
    final v = await bridge.configGet(key: key);
    return v.isEmpty ? null : v;
  }

  /// 设置配置值
  @override
  Future<void> setConfig(String key, String value) async {
    await bridge.configSet(key: key, value: value);
  }

  /// 删除配置（设置为空字符串）
  @override
  Future<void> deleteConfig(String key) async {
    await bridge.configSet(key: key, value: '');
  }

  /// 获取所有配置
  @override
  Future<Map<String, String>> getAllConfigs() async {
    final json = await bridge.configGetAll();
    final m = _decodeMap(json, 'bookApi');
    return m.map((k, v) => MapEntry(k, v.toString()));
  }

  // ========== 词典操作 ==========

  /// 词典查询（本地内置词典）
  ///
  /// Rust 侧返回结构化释义 JSON 对象，字段：`word` / `phonetic` / `definitions`。
  /// 未收录词返回空 `definitions`（非异常）。
  @override
  Future<Map<String, dynamic>> dictLookup(String word) async {
    final json = await bridge.dictLookup(word: word);
    return _decodeMap(json, 'dictLookup');
  }

  // ========== 应用日志（appLog FFI） ==========
  // [审计修复 §1.2] 接通契约 §2.38 appLog* 五方法（frb 绑定已生成） — QoderCN

  @override
  Future<void> appLogPush({required String level, required String message}) =>
      bridge.appLogPush(level: level, message: message);

  @override
  Future<String> appLogList({required String level}) =>
      bridge.appLogList(level: level);

  @override
  Future<void> appLogClear({required String level}) =>
      bridge.appLogClear(level: level);

  @override
  Future<void> appLogClearAll() => bridge.appLogClearAll();

  @override
  Future<String> appLogExport() => bridge.appLogExport();

  // ========== 备份操作 ==========

  /// 备份数据（委托 Rust backup_create：收集全量数据写入 JSON 文件）
  ///
  /// 在 [dirPath] 下生成时间戳命名的备份文件，返回实际备份文件路径。
  @override
  Future<String> backup(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final fileName =
        'legado_backup_${DateTime.now().millisecondsSinceEpoch}.json';
    final filePath = '$dirPath${Platform.pathSeparator}$fileName';
    return bridge.backupCreate(path: filePath);
  }

  /// 恢复数据（委托 Rust backup_restore：从备份文件导入）
  @override
  Future<void> restore(String backupPath) async {
    final file = File(backupPath);
    if (!await file.exists()) {
      throw RustApiException('Backup file not found: $backupPath',
          operation: 'restore');
    }
    await bridge.backupRestore(path: backupPath);
  }

  /// 导入旧版数据（委托 Rust import_old_data）
  @override
  Future<String> importOldData(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) {
      throw RustApiException('目录不存在: $dirPath', operation: 'importOldData');
    }
    return bridge.importOldData(dir: dirPath);
  }

  @override
  Future<List<String>> backupList(String dir) async {
    final json = await bridge.backupList(dir: dir);
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => e.toString()).toList();
  }

  // ========== 阅读记录 ==========

  /// 获取所有阅读记录
  @override
  Future<List<ReadRecord>> getReadRecords() async {
    final json = await bridge.readRecordList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => ReadRecord.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 更新阅读记录
  @override
  Future<void> putReadRecord(ReadRecord record) async {
    await bridge.readRecordUpsert(
      bookName: record.bookName,
      readTime: record.readTime,
    );
  }

  /// 删除阅读记录
  @override
  Future<void> deleteReadRecord(String bookName) async {
    await bridge.readRecordDelete(bookName: bookName);
  }

  /// 清空阅读记录
  @override
  Future<void> clearReadRecords() async {
    await bridge.readRecordClear();
  }

  // ========== RSS 收藏操作 ==========

  /// 获取所有 RSS 收藏
  @override
  Future<List<RssStar>> getRssStars() async {
    final json = await bridge.rssStarList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => RssStar.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加 RSS 收藏
  @override
  Future<RssStar> addRssStar(RssStar star) async {
    await bridge.rssStarAdd(
      sourceUrl: star.origin,
      title: star.title,
      link: star.link,
    );
    return star;
  }

  /// 删除 RSS 收藏
  @override
  Future<void> deleteRssStar(String link) async {
    await bridge.rssStarDelete(link: link);
  }

  /// 判断是否已收藏
  @override
  Future<bool> isStarred(String link) => bridge.rssStarIsStarred(link: link);

  // ========== 书籍分组 ==========

  /// 获取所有书籍分组
  @override
  Future<List<BookGroup>> getBookGroups() async {
    final json = await bridge.bookGroupList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => BookGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加书籍分组
  @override
  Future<BookGroup> addBookGroup(BookGroup group) async {
    final id = await bridge.bookGroupAdd(
      groupName: group.groupName,
      cover: group.cover ?? '',
      order: group.order,
    );
    return group.copyWith(groupId: id.toInt());
  }

  /// 更新书籍分组
  @override
  Future<void> updateBookGroup(BookGroup group) async {
    await bridge.bookGroupUpdate(
      id: group.groupId,
      groupName: group.groupName,
      cover: group.cover ?? '',
      order: group.order,
    );
  }

  /// 删除书籍分组
  @override
  Future<void> deleteBookGroup(int groupId) async {
    await bridge.bookGroupDelete(id: groupId);
  }

  /// 设置分组显示状态（F3-20）
  @override
  Future<bool> bookGroupSetShow(int groupId, bool show) =>
      bridge.bookGroupSetShow(id: groupId, show_: show);

  // ========== 搜索历史 ==========

  /// 获取搜索历史
  @override
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50}) async {
    final json = await bridge.searchHistoryList(limit: limit);
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => SearchKeyword.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 按前缀搜索历史关键词（用于搜索联想）
  @override
  Future<List<String>> searchHistoryByPrefix(String prefix, {int limit = 20}) async {
    final json = await bridge.searchHistoryByPrefix(prefix: prefix, limit: limit);
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e.toString()).toList();
  }

  /// 添加搜索关键词
  @override
  Future<void> addSearchKeyword(String keyword, String bookName) async {
    await bridge.searchHistoryAdd(keyword: keyword, bookName: bookName);
  }

  /// 删除搜索关键词
  @override
  Future<void> deleteSearchKeyword(String keyword) async {
    await bridge.searchHistoryDelete(keyword: keyword);
  }

  /// 清空搜索历史
  @override
  Future<void> clearSearchHistory() async {
    await bridge.searchHistoryClear();
  }

  // ========== 缓存管理 ==========

  /// 获取缓存大小
  @override
  Future<int> getCacheSize() async {
    final size = await bridge.cacheGetSize();
    return size.toInt();
  }

  /// 清除缓存
  @override
  Future<void> clearCache() async {
    await bridge.cacheClear();
  }

  /// 清除指定书籍章节缓存
  @override
  Future<int> clearBookCache(String bookUrl) async {
    final deleted = await bridge.cacheClearBook(bookUrl: bookUrl);
    return deleted.toInt();
  }

  /// 获取缓存书籍数量
  @override
  Future<int> getCacheBookCount() async {
    final count = await bridge.cacheGetBookCount();
    return count.toInt();
  }

  /// 获取缓存章节数量
  @override
  Future<int> getCacheChapterCount() async {
    final count = await bridge.cacheGetChapterCount();
    return count.toInt();
  }

  /// 清除指定时间之前的缓存
  @override
  Future<void> clearCacheBefore(int beforeTimestampMs) async {
    await bridge.cacheClearBefore(beforeTimestampMs: beforeTimestampMs);
  }

  /// 执行 SQLite VACUUM 压缩数据库，返回释放的字节数（契约 §2.16.6，
  /// Task #50 加法式新增；失败/未初始化时 Rust 侧降级返回 0）
  @override
  Future<int> shrinkDatabase() async {
    final freed = await bridge.cacheShrinkDatabase();
    return freed.toInt();
  }

  /// 获取章节缓存正文（未缓存返回空串，供缓存导出拼装 TXT）
  ///
  /// [UI-fix v2.0.2 | 2026-08-06] 接通 cacheGetChapter FFI（书架菜单缓存导出） — Qoder
  @override
  Future<String> getCachedChapter(String bookUrl, int chapterIndex) =>
      bridge.cacheGetChapter(bookUrl: bookUrl, chapterIndex: chapterIndex);

  /// 列出某本书已缓存章节的 chapter_url 集合（目录页云图标缓存态）
  ///
  /// [UI-fix v2.0.6 | 2026-08-08] Task #22：接通 cacheListCachedChapterUrls FFI，
  /// 解析 Rust 返回的 JSON 字符串数组为 String 列表（非数组降级空列表）。 — Qoder
  @override
  Future<List<String>> listCachedChapterUrls(String bookUrl) async {
    final json = await bridge.cacheListCachedChapterUrls(bookUrl: bookUrl);
    final decoded = jsonDecode(json);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toList();
    }
    return const <String>[];
  }

  // ========== 批量缓存下载（对齐原版 CacheActivity，契约 §2.43.3） ==========

  /// [UI-fix v2.0.16 | 2026-08-10] 接通 cacheDownloadStart FFI（真实下载写缓存）— Reasonix
  @override
  Future<int> cacheDownloadStart(
      String bookUrl, int startChapter, int endChapter) async {
    final json =
        await bridge.cacheDownloadStart(bookUrl: bookUrl, startChapter: startChapter, endChapter: endChapter);
    final taskId = int.tryParse(json.trim());
    if (taskId == null) {
      throw Exception('缓存任务启动失败: $json');
    }
    return taskId;
  }

  @override
  Future<String> cacheDownloadProgress(int taskId) async {
    // PlatformInt64 即 int 的 typedef，直接传值
    return bridge.cacheDownloadProgress(taskId: taskId);
  }

  @override
  Future<bool> cacheDownloadCancel(int taskId) async {
    return bridge.cacheDownloadCancel(taskId: taskId);
  }

  @override
  Future<String> cacheDownloadList() async {
    return bridge.cacheDownloadList();
  }

  // ========== 章节购买 ==========

  /// 执行章节购买动作（契约 §2.43.2，对照 Kotlin ReadBookActivity.payAction）
  ///
  /// 解析 Rust 返回的 `{"kind": ..., "value": ...}` JSON 为元组；
  /// kind 缺失时视为 none，value 缺失时视为空串。
  /// [UI-fix v2.0.3 | 2026-08-08] — QoderCN
  @override
  Future<({String kind, String value})> chapterPayAction({
    required String bookUrl,
    required int chapterIndex,
  }) async {
    final json = await bridge.chapterPayAction(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
    );
    final map = _decodeMap(json, 'chapterPayAction');
    return (
      kind: (map['kind'] ?? 'none').toString(),
      value: (map['value'] ?? '').toString(),
    );
  }

  @override
  Future<Map<String, dynamic>> sourceCallBackBtn({
    required String event,
    required String bookUrl,
    int? chapterIndex,
    String? result,
    int bookType = 0,
  }) async {
    final json = await bridge.sourceCallBackBtn(
      event: event,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      result: result,
      bookType: bookType,
    );
    return _decodeMap(json, 'sourceCallBackBtn');
  }

  // ========== WebBook 操作 ==========
  // 以下解析类方法统一经平台桥接拦截（Task #114）：Rust 侧 webView 类 JS API
  // 无头运行时返回桥接载荷 JSON，恰为整体结果时由此执行并以真实结果回填 — QoderCN

  /// 搜索书籍（书源规则驱动）
  @override
  Future<String> webbookSearch(
    String sourceJson,
    String query,
    int page,
  ) async =>
      PlatformBridgeService.instance.interceptResult(
        await bridge.webbookSearch(sourceJson: sourceJson, query: query, page: page),
      );

  /// 获取书籍详情
  @override
  Future<String> webbookInfo(String sourceJson, String bookUrl) async =>
      PlatformBridgeService.instance.interceptResult(
        await bridge.webbookInfo(sourceJson: sourceJson, bookUrl: bookUrl),
      );

  /// 获取章节列表
  @override
  Future<String> webbookChapters(
    String sourceJson,
    String bookUrl, {
    String tocUrl = '',
    String bookName = '',
  }) async =>
      PlatformBridgeService.instance.interceptResult(
        await bridge.webbookChapters(
          sourceJson: sourceJson,
          bookUrl: bookUrl,
          tocUrl: tocUrl,
          bookName: bookName,
        ),
      );

  /// 获取章节正文
  @override
  Future<String> webbookContent(String sourceJson, String chapterJson) async =>
      PlatformBridgeService.instance.interceptResult(
        await bridge.webbookContent(sourceJson: sourceJson, chapterJson: chapterJson),
      );

  /// 流式书源调试（对齐 Debug.Callback）
  @override
  Stream<Map<String, dynamic>> debugBookSourceStream(
    String sourceUrl,
    String key,
  ) =>
      bridge
          .debugBookSourceStream(sourceUrl: sourceUrl, key: key)
          .map((item) => _decodeMap(item, 'debugBookSourceStream'));

  /// 取消正在进行的书源调试
  @override
  Future<void> cancelDebugBookSource() async {
    await bridge.debugBookSourceCancel();
  }

  // ========== 发现页操作 ==========

  /// 解析 exploreUrl 为分类列表
  ///
  /// 返回 `List<ExploreCategory>`，每项包含 title 和 url。
  /// 对标 Android BookSourceExtensions.exploreKinds()
  @override
  Future<List<ExploreCategory>> exploreParseUrl(
    String exploreUrl, {
    String sourceJson = '',
  }) async {
    final json = await bridge.exploreParseUrl(
      exploreUrl: exploreUrl,
      sourceJson: sourceJson,
    );
    final list = _decodeList(json, 'bookApi');
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
  @override
  Future<List<SearchBook>> exploreFetchBooks(
    String sourceJson,
    String url,
    int page,
  ) async {
    // 平台桥接拦截（Task #114）— QoderCN
    final json = await PlatformBridgeService.instance.interceptResult(
      await bridge.exploreFetchBooks(
        sourceJson: sourceJson,
        url: url,
        page: page,
      ),
    );
    final list = _decodeList(json, 'bookApi');
    // [UI-fix v2.0.3 | 2026-08-06] 发现分类返回的是 Rust WebSearchResult
    // （snake_case：book_url/cover_url/source_url，且无 origin/originName），
    // 与 SearchBook.fromJson 期望的 camelCase 键不一致，直接 fromJson 会丢失
    // bookUrl/origin/coverUrl → 详情页因 origin 为空无法联网补全目录/封面
    // （未入库书共 0 章 / 无封面）。此处显式归一化，并用本次发现所属书源
    // 补齐 origin/originName（同源批量，权威）。 — Qoder
    String srcUrl = '';
    String srcName = '';
    try {
      final sm = jsonDecode(sourceJson);
      if (sm is Map) {
        srcUrl =
            (sm['bookSourceUrl'] ?? sm['book_source_url'] ?? '').toString();
        srcName =
            (sm['bookSourceName'] ?? sm['book_source_name'] ?? '').toString();
      }
    } catch (_) {}
    return list
        .map((e) =>
            _searchBookFromExplore(e as Map<String, dynamic>, srcUrl, srcName))
        .toList();
  }

  @override
  Future<void> exploreInfoMapPut(
    String sourceUrl,
    String key,
    String value,
  ) =>
      bridge.exploreInfoMapPut(
        sourceUrl: sourceUrl,
        key: key,
        value: value,
      );

  @override
  Future<void> exploreInfoMapEnsureDefault(
    String sourceUrl,
    String key,
    String defaultValue,
  ) =>
      bridge.exploreInfoMapEnsureDefault(
        sourceUrl: sourceUrl,
        key: key,
        defaultValue: defaultValue,
      );

  /// 将发现分类返回的 WebSearchResult 归一化为 SearchBook。
  /// 兼容 snake_case 与 camelCase 两种键名；origin/originName 用所属书源补齐，
  /// 避免 Rust 侧字段命名差异导致 origin 丢失（未入库书详情页无法联网取目录/封面）。
  SearchBook _searchBookFromExplore(
    Map<String, dynamic> e,
    String sourceUrl,
    String sourceName,
  ) {
    String? pick(String camel, String snake) {
      final v = e[camel] ?? e[snake];
      final s = v?.toString();
      return (s != null && s.isNotEmpty) ? s : null;
    }

    return SearchBook(
      bookUrl: _absoluteUrl(
          pick('origin', 'source_url') ?? sourceUrl, pick('bookUrl', 'book_url')),
      origin: pick('origin', 'source_url') ?? sourceUrl,
      originName: pick('originName', 'source_name') ?? sourceName,
      name: pick('name', 'name') ?? '',
      author: pick('author', 'author') ?? '',
      kind: pick('kind', 'kind'),
      coverUrl: _absoluteUrlOrNull(
          pick('origin', 'source_url') ?? sourceUrl, pick('coverUrl', 'cover_url')),
      intro: pick('intro', 'intro'),
      wordCount: pick('wordCount', 'word_count'),
      latestChapterTitle: pick('latestChapterTitle', 'latest_chapter'),
      tocUrl: pick('tocUrl', 'toc_url') ?? '',
    );
  }

  /// 将可能为相对路径的 URL 解析为绝对 URL（对标原版 NetworkUtils.getAbsoluteURL）。
  /// 发现/搜索返回的 book_url 可能是相对路径（如 /book/65308/），直接传给
  /// webbookInfo/webbookChapters 会导致 reqwest “builder error”。以书源基地址补齐。
  String _absoluteUrl(String base, String? url) {
    final u = (url ?? '').trim();
    if (u.isEmpty || base.isEmpty) return u;
    if (u.contains('://') || u.startsWith('data:')) return u;
    try {
      return Uri.parse(base).resolve(u).toString();
    } catch (_) {
      return u;
    }
  }

  /// [_absoluteUrl] 的可空包装：空值返回 null（保持封面可空语义）。
  String? _absoluteUrlOrNull(String base, String? url) {
    final u = (url ?? '').trim();
    if (u.isEmpty) return null;
    return _absoluteUrl(base, u);
  }

  // ========== 规则解析 ==========

  /// 使用规则解析内容
  @override
  Future<String> parseRule(
    String content,
    String rule,
    String ruleType,
  ) =>
      bridge.parseRule(content: content, rule: rule, ruleType: ruleType);

  // ========== 网络操作 ==========

  /// HTTP GET 请求
  @override
  Future<String> httpGet(String url) => bridge.httpGet(url: url);

  /// HTTP GET 二进制响应
  @override
  Future<String> httpGetBytes(String url, {String headersJson = ''}) =>
      bridge.httpGetBytes(url: url, headersJson: headersJson);

  /// HTTP POST 请求
  @override
  Future<String> httpPost(String url, String body) =>
      bridge.httpPost(url: url, body: body);

  /// 图片下载 + imageDecode 解码（返回 JSON：{ base64, len }）— Reasonix
  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) =>
      bridge.fetchImageWithDecode(url: url, sourceJson: sourceJson);

  // ========== JS 引擎 ==========

  /// 执行 JS 脚本
  @override
  Future<String> evalJs(String script) async =>
      // 平台桥接拦截：书源调试中 webView 类调用由此真实执行（Task #114）— QoderCN
      PlatformBridgeService.instance.interceptResult(
        await bridge.jsEval(script: script),
      );

  /// 获取 JS 引擎版本（通过 jsEval 查询）
  @override
  Future<String> getJsEngineVersion() async {
    try {
      return await bridge.jsEval(script: 'typeof QuickJS !== "undefined" ? QuickJS.version : "quickjs-ng"');
    } catch (_) {
      return 'unknown';
    }
  }

  // ========== 服务器管理 ==========

  /// 启动服务器（委托 Rust server_start 真实启动 Web 服务）
  @override
  Future<void> startServer({int port = 1122}) async {
    await bridge.serverStart(port: port);
  }

  /// 停止服务器（委托 Rust server_stop）
  @override
  Future<void> stopServer() async {
    await bridge.serverStop();
  }

  /// 获取服务器状态
  ///
  /// Rust 返回 JSON `{running: bool, port: int}`，转换为统一描述串
  ///（与既有 UI/测试语义一致：`running on port X` / `stopped`）。
  @override
  Future<String> getServerStatus() async {
    final raw = await bridge.serverStatus();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['running'] == true) {
        return 'running on port ${m['port'] ?? 1122}';
      }
    } catch (_) {
      // 解析失败按停止处理
    }
    return 'stopped';
  }

  /// 设置服务器端口（记录用户选择，下次 startServer 生效）
  @override
  Future<void> setServerPort(int port) async {
    await bridge.configSet(key: 'server_port', value: port.toString());
  }

  /// 设置自定义 hosts 映射（契约 §2.20.3，Task #74）
  @override
  Future<void> setCustomHosts(String hostsJson) =>
      bridge.setCustomHosts(hostsJson: hostsJson);

  /// 设置独立 MCP 服务端口（契约 §2.22.5，Task #74）
  @override
  Future<void> setMcpPort(int port) => bridge.setMcpPort(port: port);

  /// 封面规则测试搜索（契约 §2.4.8，Task #74）
  ///
  /// Rust 返回裸 JSON Array（§1.4 铁律），解析为字符串列表；
  /// 空结果 `[]` 解析为空列表（非异常）。
  @override
  Future<List<String>> searchCoverRules(String name) async {
    final json = await bridge.searchCoverRules(name: name);
    final decoded = jsonDecode(json);
    if (decoded is! List) return [];
    return decoded.map((e) => e.toString()).toList();
  }

  @override
  Future<Map<String, dynamic>> getCoverRule() async {
    final json = await bridge.getCoverRule();
    return _decodeMap(json, 'getCoverRule');
  }

  @override
  Future<bool> saveCoverRule(Map<String, dynamic> rule) =>
      bridge.saveCoverRule(ruleJson: jsonEncode(rule));

  @override
  Future<bool> deleteCoverRule() => bridge.deleteCoverRule();

  // ========== 书籍格式解析 ==========

  /// 解析 TXT 文件（按章节标题模式分割）
  ///
  /// ⚠️ 死代码标注（批次3治理 Task #118）：此 Dart 纯正则 fallback 在全工程
  /// 已无任何调用点（TXT 章节解析已由 Rust 侧接管）。仅为保持 [BookApi]
  /// 契约面不变而保留，勿删除；后续如需清理须同步 book_api.dart /
  /// mock_book_api.dart 声明。
  @override
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
  @override
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
  @override
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

  // ========== 阅读记录 ==========

  /// 记录阅读时长（通过 readRecordUpsert 实现）
  @override
  Future<void> recordReadingTime(String bookName, int seconds) async {
    await bridge.readRecordUpsert(bookName: bookName, readTime: seconds);
  }

  // ========== HTTP TTS ==========

  /// 获取所有 HTTP TTS 配置
  @override
  Future<List<HttpTts>> getHttpTts() async {
    final json = await bridge.httpTtsList();
    final list = _decodeList(json, 'bookApi');
    return list
        .map((e) => HttpTts.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取所有 HTTP TTS 配置（别名）
  @override
  Future<List<HttpTts>> getHttpTtsList() => getHttpTts();

  /// 添加 HTTP TTS 配置
  @override
  Future<HttpTts> addHttpTts(HttpTts tts) async {
    final id = await bridge.httpTtsAdd(name: tts.name, url: tts.url);
    return tts.copyWith(id: id.toInt());
  }

  /// 更新 HTTP TTS 配置
  @override
  Future<void> updateHttpTts(HttpTts tts) async {
    await bridge.httpTtsUpdate(id: tts.id, name: tts.name, url: tts.url);
  }

  /// 删除 HTTP TTS 配置
  @override
  Future<void> deleteHttpTts(int id) async {
    await bridge.httpTtsDelete(id: id);
  }

  /// 导入 HTTP TTS 配置（解析 JSON 数组并逐条添加）
  @override
  Future<int> importHttpTts(String json) async {
    final list = _decodeList(json, 'bookApi');
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
  @override
  Future<String> exportHttpTts() async {
    final list = await getHttpTts();
    return jsonEncode(list.map((e) => e.toJson()).toList());
  }

  /// 设置 HTTP TTS 源启用/禁用（F3-20）
  @override
  Future<bool> httpTtsSetEnabled(int id, bool enabled) =>
      bridge.httpTtsSetEnabled(id: id, enabled: enabled);

  // ========== 音频播放 ==========

  // [UI-fix v2.0.2 | 2026-08-06] audioSpeak 改接 ttsSpeak 真实管线（缺口②闭合） — QoderCN
  /// TTS 朗读：接 Rust 真实合成管线（bridge.ttsSpeak，契约 §2.42）
  ///
  /// engineUrl 模板原样透传——占位符替换（{{speakText}}/{{text}}/
  /// {{speakSpeed}}/{{speed}}）、HTTP 音频拉取、Content-Type 校验与
  /// MD5 文件缓存均由 Rust 侧完成，Dart 不再预替换模板。
  /// 返回语义保持 Future<void>（调用方 AudioNotifier.play 不消费返回值）；
  /// 合成产物 audioPath 由 Rust 缓存落盘，供后续本地播放接线。
  /// ttsSpeak 异常时降级为原探活逻辑（模板替换 + http.get），
  /// 保持 audio_notifier 既有 try/catch 保护语义不变。
  @override
  Future<void> audioSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceName,
  }) async {
    try {
      final resultJson = await bridge.ttsSpeak(
        text: text,
        engineUrl: engineUrl,
        speed: speed,
      );
      // 解析合成结果（camelCase）：audioPath / fromCache / contentType
      final result =
          (jsonDecode(resultJson) as Map<String, dynamic>).cast<String, dynamic>();
      debugPrint(
        'ttsSpeak 合成完成: audioPath=${result['audioPath']} '
        'fromCache=${result['fromCache']} contentType=${result['contentType']}',
      );
    } catch (e) {
      // 降级探活：真实管线异常（引擎不可达/正文为空/缓存目录未就绪等）
      // 时保留原模板替换 + http.get 探活行为，失败仍向上抛出由调用方保护
      debugPrint('ttsSpeak 真实管线失败，降级探活: $e');
      var url = engineUrl
          .replaceAll('{{speakText}}', Uri.encodeComponent(text))
          .replaceAll('{{text}}', Uri.encodeComponent(text))
          .replaceAll('{{speakSpeed}}', speed.toString())
          .replaceAll('{{speed}}', speed.toString())
          .replaceAll('{{pitch}}', pitch.toString())
          .replaceAll('{{volume}}', volume.toString());
      if (voiceName != null) {
        url = url.replaceAll('{{voice}}', Uri.encodeComponent(voiceName));
      }
      final probe = await bridgeHttpGet(this, url);
      if (!probe.isSuccess) {
        throw StateError('HTTP ${probe.statusCode}');
      }
    }
  }

  /// TTS 真实合成（F3-20 BookApi 抽象）
  @override
  Future<Map<String, dynamic>> ttsSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
  }) async {
    final resultJson = await bridge.ttsSpeak(
      text: text,
      engineUrl: engineUrl,
      speed: speed,
    );
    return (jsonDecode(resultJson) as Map<String, dynamic>).cast<String, dynamic>();
  }

  /// 设置 TTS 音频缓存目录（F3-20）
  @override
  Future<bool> ttsSetCacheDir(String path) => bridge.ttsSetCacheDir(path: path);

  /// 获取章节媒体信息（音频书取址，契约 §2.26）
  ///
  /// 对齐原版 `AudioPlay` → `WebBook.getContent`：经 FFI `audioGetChapterMedia`
  /// 解析可播 `mediaUrl`。返回含 `mediaUrl` / `url` / `isVolume` / `fromCache` 等。
  @override
  Future<Map<String, dynamic>> getAudioChapterMedia(
    String bookUrl,
    int chapterIndex,
  ) async {
    final json = await bridge.audioGetChapterMedia(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
    );
    return (jsonDecode(json) as Map<String, dynamic>).cast<String, dynamic>();
  }

  /// 获取音频播放进度
  @override
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
  @override
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

  // ========== WebDAV 云同步 ==========

  /// WebDAV 列出远程目录
  @override
  Future<String> webdavListDir(String configJson, String path) =>
      bridge.webdavListDir(configJson: configJson, path: path);

  /// WebDAV 上传文件
  @override
  Future<void> webdavUpload(
          String configJson, String path, String data) =>
      bridge.webdavUpload(
          configJson: configJson, path: path, data: data);

  /// WebDAV 从本地文件路径读取并上传（契约 §2.28.6，Task #50 加法式新增）
  @override
  Future<void> webdavUploadFile(
    String configJson,
    String path,
    String localFilePath,
  ) =>
      bridge.webdavUploadFile(
        configJson: configJson,
        path: path,
        localFilePath: localFilePath,
      );

  /// WebDAV 下载文件
  @override
  Future<String> webdavDownload(String configJson, String path) =>
      bridge.webdavDownload(configJson: configJson, path: path);

  /// WebDAV 下载二进制到本地文件（契约 §2.28，2026-08-12 P1-5）
  @override
  Future<void> webdavDownloadFile(
    String configJson,
    String path,
    String localFilePath,
  ) =>
      bridge.webdavDownloadFile(
        configJson: configJson,
        path: path,
        localFilePath: localFilePath,
      );

  /// WebDAV 删除远程文件
  @override
  Future<void> webdavDelete(String configJson, String path) =>
      bridge.webdavDelete(configJson: configJson, path: path);

  /// WebDAV 全量同步
  @override
  Future<String> webdavFullSync(
          String configJson, String localBooks, String localSources) =>
      bridge.webdavFullSync(
          configJson: configJson,
          localBooks: localBooks,
          localSources: localSources);

  // ========== 下载管理器 ==========

  /// 添加下载任务
  @override
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
  @override
  Future<String> downloadGetStats() => bridge.downloadGetStats();

  /// 获取指定书籍的下载任务
  @override
  Future<String> downloadListByBook(String bookUrl) =>
      bridge.downloadListByBook(bookUrl: bookUrl);

  /// 暂停所有下载
  @override
  Future<void> downloadPauseAll() => bridge.downloadPauseAll();

  /// 恢复所有下载
  @override
  Future<void> downloadResumeAll() => bridge.downloadResumeAll();

  /// 移除下载任务
  @override
  Future<void> downloadRemoveTask(String taskId) =>
      bridge.downloadRemoveTask(taskId: taskId);

  /// 更新下载进度
  @override
  Future<void> downloadUpdateProgress(String taskId, double progress) =>
      bridge.downloadUpdateProgress(taskId: taskId, progress: progress);

  // ========== 段评（书源 ruleReview）==========

  /// 段评摘要（P2-9）
  @override
  Future<String> reviewGetSummary(String sourceJson, String requestJson) =>
      bridge.reviewGetSummary(
        sourceJson: sourceJson,
        requestJson: requestJson,
      );

  /// 段评详情分页（P2-9）
  @override
  Future<String> reviewGetDetail(
          String sourceJson, String requestJson, int page) =>
      bridge.reviewGetDetail(
        sourceJson: sourceJson,
        requestJson: requestJson,
        page: page,
      );

  /// 按需加载段评回复（上游 #519）
  ///
  /// 返回 JSON 对象字符串 `{"items": [回复列表], "nextPageUrl": String?}`。
  @override
  Future<String> reviewGetReplies(
          String sourceJson, String requestJson, int page) =>
      bridge.reviewGetReplies(
        sourceJson: sourceJson,
        requestJson: requestJson,
        page: page,
      );

  // ========== 书籍导出 ==========

  /// 导出书籍（返回 ExportResult JSON）
  /// 
  /// # 参数
  /// - `bookUrl`: 书籍 URL
  /// - `format`: 导出格式（txt/epub/html）
  /// - `includeToc`: 是否包含目录
  @override
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
    return _decodeMap(json, 'bookApi');
  }

  @override
  Future<Map<String, dynamic>> bookExportWithOptions({
    required String bookUrl,
    required String format,
    required bool includeToc,
    String optionsJson = '',
  }) async {
    final json = await bridge.bookExportWithOptions(
      bookUrl: bookUrl,
      format: format,
      includeToc: includeToc,
      optionsJson: optionsJson,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 获取导出预览信息（返回 ExportResult JSON）
  @override
  Future<Map<String, dynamic>> bookExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    final json = await bridge.bookExportInfo(
      bookUrl: bookUrl,
      format: format,
    );
    return _decodeMap(json, 'bookApi');
  }

  // ========== 自动任务（auto_task FFI） ==========

  /// 构建书籍更新定时任务（返回 AutoTaskRule JSON）
  ///
  /// 对应 Kotlin `AutoTask.buildBookUpdateTask`。
  @override
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
    return _decodeMap(json, 'bookApi');
  }

  /// 批量更新 cron 表达式（返回更新后的 AutoTaskRule 数组）
  ///
  /// [rules] 为现有规则列表 JSON，[ids] 为待更新任务 ID 列表。
  @override
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
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 准备导入任务（合并本地运行时状态，返回合并后的任务数组）
  @override
  Future<List<Map<String, dynamic>>> autoTaskPrepareImported({
    required String localTasksJson,
    required String importedJson,
  }) async {
    final json = await bridge.autoTaskPrepareImported(
      localTasksJson: localTasksJson,
      importedJson: importedJson,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 执行任务协议（返回 TaskResult JSON）
  ///
  /// [protocolJson] 为 TaskProtocol 序列化字符串。
  @override
  Future<Map<String, dynamic>> autoTaskExecute({
    required String protocolJson,
  }) async {
    final json = await bridge.autoTaskExecute(protocolJson: protocolJson);
    return _decodeMap(json, 'bookApi');
  }

  /// 带任务 ID 执行任务协议（返回 TaskResult JSON）
  @override
  Future<Map<String, dynamic>> autoTaskExecuteWithId({
    required String protocolJson,
    required String taskId,
  }) async {
    final json = await bridge.autoTaskExecuteWithId(
      protocolJson: protocolJson,
      taskId: taskId,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 规范化脚本（去除 `@js:` 前缀或 `<js></js>` 包裹）
  @override
  Future<String> autoTaskNormalizeScript({required String script}) =>
      bridge.autoTaskNormalizeScript(script: script);

  /// 判断书籍是否允许刷新目录
  @override
  Future<bool> autoTaskCanRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  }) =>
      bridge.autoTaskCanRefreshToc(
        canUpdate: canUpdate,
        respectCanUpdate: respectCanUpdate,
      );

  /// 查找书籍更新任务（返回匹配的 AutoTaskRule JSON，未找到返回 null）
  @override
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
    return _decodeMap(json, 'bookApi');
  }

  /// 解析 cron 表达式计算下次执行时间（Unix 毫秒，无法解析返回 -1）
  @override
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
  @override
  Future<List<Map<String, dynamic>>> autoTaskListRules() async {
    final json = await bridge.autoTaskListRules();
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  /// 创建自动任务规则（返回任务 ID）
  @override
  Future<String> autoTaskCreateRule({required String ruleJson}) async {
    return await bridge.autoTaskCreateRule(ruleJson: ruleJson);
  }

  /// 更新自动任务规则
  @override
  Future<void> autoTaskUpdateRule({required String ruleJson}) async {
    await bridge.autoTaskUpdateRule(ruleJson: ruleJson);
  }

  /// 删除自动任务规则
  @override
  Future<void> autoTaskDeleteRule({required String id}) async {
    await bridge.autoTaskDeleteRule(id: id);
  }

  /// 根据 ID 查询自动任务规则
  @override
  Future<Map<String, dynamic>?> autoTaskFindRuleById({required String id}) async {
    final json = await bridge.autoTaskFindRuleById(id: id);
    if (json.isEmpty || json == 'null') return null;
    return _decodeMap(json, 'bookApi');
  }

  // ========== 音频播放模式（audio FFI） ==========

  /// 将播放模式写入 readConfig JSON（返回更新后的 JSON）
  ///
  /// 对应 Kotlin `String?.withAudioPlayMode`。
  @override
  Future<String> audioWithPlayMode({
    String? readConfig,
    required int playMode,
  }) =>
      bridge.audioWithPlayMode(readConfig: readConfig, playMode: playMode);

  /// 解析听书书籍（返回 Book JSON，未找到返回 null）
  ///
  /// 请求 URL 为空时返回缓存书籍；缓存匹配时直接返回；否则按 URL 查库。
  @override
  Future<Map<String, dynamic>?> audioResolvePlayBook({
    String? requestedBookUrl,
    String? cachedBookJson,
  }) async {
    final json = await bridge.audioResolvePlayBook(
      requestedBookUrl: requestedBookUrl,
      cachedBookJson: cachedBookJson,
    );
    if (json.isEmpty || json == 'null') return null;
    return _decodeMap(json, 'bookApi');
  }

  // ========== 压缩包导入 ==========

  /// 导入 ZIP 压缩包中的书籍文件
  ///
  /// 解压 ZIP 文件，提取其中的书籍文件到 [outputDir]。
  /// 返回 ArchiveImportResult JSON 解析后的 Map。
  @override
  Future<Map<String, dynamic>> archiveImportZip({
    required String zipPath,
    required String outputDir,
  }) async {
    final json = await bridge.archiveImportZip(
      zipPath: zipPath,
      outputDir: outputDir,
    );
    return _decodeMap(json, 'bookApi');
  }

  /// 导入 RAR 压缩包中的书籍文件（支持加密）
  ///
  /// 解压 RAR 文件，提取其中的书籍文件到 [outputDir]。
  /// [password] 为可选密码，用于加密 RAR 文件。
  @override
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
    return _decodeMap(json, 'bookApi');
  }

  /// 列出 ZIP 压缩包中的书籍文件名（不解压）
  ///
  /// 返回压缩包内符合书籍格式的文件名列表。
  @override
  Future<List<String>> archiveListZipFiles({required String zipPath}) async {
    final json = await bridge.archiveListZipFiles(zipPath: zipPath);
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e.toString()).toList();
  }

  /// 列出 RAR 压缩包中的书籍文件名（不解压）
  ///
  /// [password] 为可选密码，用于加密 RAR 文件。
  @override
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  }) async {
    final json = await bridge.archiveListRarFiles(
      rarPath: rarPath,
      password: password,
    );
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => e.toString()).toList();
  }

  /// 检测 TXT 文件编码
  ///
  /// 返回 EncodingResult JSON 解析后的 Map，包含：
  /// - encoding: 编码名称
  /// - has_bom: 是否通过 BOM 确定
  /// - confidence: 置信度（high/medium/low）
  @override
  Future<Map<String, dynamic>> archiveDetectEncoding({
    required String filePath,
  }) async {
    final json = await bridge.archiveDetectEncoding(filePath: filePath);
    return _decodeMap(json, 'bookApi');
  }

  /// 转换 TXT 文件编码
  ///
  /// 将文件从 [fromEncoding] 转换为 [toEncoding]，输出为新文件。
  /// 返回 ConvertResult JSON 解析后的 Map。
  @override
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
    return _decodeMap(json, 'bookApi');
  }

  /// 判断文件是否为压缩包格式
  ///
  /// 支持 .zip / .rar / .7z 等格式判断。
  @override
  Future<bool> archiveIsArchive({required String filePath}) =>
      bridge.archiveIsArchive(filePath: filePath);

  // ========== 正文高亮（highlight FFI） ==========

  /// 新增/更新高亮记录（BookHighlight JSON，time=0 时自动分配），返回 time
  @override
  Future<int> highlightAdd({required String highlightJson}) =>
      bridge.highlightAdd(highlightJson: highlightJson);

  /// 按主键 time 删除高亮记录，返回是否实际删除
  @override
  Future<bool> highlightDelete({required int time}) =>
      bridge.highlightDelete(time: time);

  /// 按书籍删除全部高亮记录，返回删除数量
  @override
  Future<int> highlightDeleteByBook({required String bookUrl}) =>
      bridge.highlightDeleteByBook(bookUrl: bookUrl);

  /// 按书籍获取高亮列表（BookHighlight 数组 JSON）
  @override
  Future<String> highlightListByBook({required String bookUrl}) =>
      bridge.highlightListByBook(bookUrl: bookUrl);

  /// 按书籍 + 章节索引获取高亮列表（BookHighlight 数组 JSON）
  @override
  Future<String> highlightListByChapter({
    required String bookUrl,
    required int chapterIndex,
  }) =>
      bridge.highlightListByChapter(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
      );

  /// 全局关键词搜索高亮（BookHighlight 数组 JSON）
  @override
  Future<String> highlightSearch({required String keyword}) =>
      bridge.highlightSearch(keyword: keyword);

  /// 获取所有高亮记录（BookHighlight 数组 JSON）
  @override
  Future<String> highlightListAll() => bridge.highlightListAll();

  /// 获取所有高亮规则（HighlightRule 数组 JSON，按 sortOrder 升序）
  @override
  Future<String> highlightRuleList() => bridge.highlightRuleList();

  /// 保存高亮规则（HighlightRule JSON，id=0 时自增新增），返回规则 ID
  @override
  Future<int> highlightRuleSave({required String ruleJson}) =>
      bridge.highlightRuleSave(ruleJson: ruleJson);

  /// 按 ID 删除高亮规则，返回是否实际删除
  @override
  Future<bool> highlightRuleDelete({required int id}) =>
      bridge.highlightRuleDelete(id: id);

  /// 按书籍查找启用的高亮规则（HighlightRule 数组 JSON）
  @override
  Future<String> highlightRuleFindEnabled({
    required String bookName,
    required String origin,
  }) =>
      bridge.highlightRuleFindEnabled(bookName: bookName, origin: origin);

  // ========== 规则订阅（rule_sub FFI，Task #89） ==========

  /// 获取规则订阅列表（按 customOrder 排序）
  @override
  Future<List<Map<String, dynamic>>> ruleSubList() async {
    final json = await bridge.ruleSubList();
    return _decodeList(json, 'ruleSubList')
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// 新增/更新规则订阅
  @override
  Future<bool> ruleSubSave({required String subJson}) =>
      bridge.ruleSubSave(subJson: subJson);

  /// 删除规则订阅
  @override
  Future<bool> ruleSubDelete({required int id}) =>
      bridge.ruleSubDelete(id: id);

  /// 切换规则订阅启用状态
  @override
  Future<bool> ruleSubSetEnabled({
    required int id,
    required bool enabled,
  }) =>
      bridge.ruleSubSetEnabled(id: id, enabled: enabled);

  /// 拖拽排序：按新顺序 ID 列表重写 customOrder
  @override
  Future<bool> ruleSubUpdateOrder({required List<int> ids}) =>
      bridge.ruleSubUpdateOrder(idsJson: jsonEncode(ids));

  /// 检查更新（返回检查结果 Map）
  @override
  Future<Map<String, dynamic>> ruleSubCheckUpdate({required int id}) async {
    final json = await bridge.ruleSubCheckUpdate(id: id);
    return _decodeMap(json, 'ruleSubCheckUpdate');
  }

  /// 应用更新（返回应用结果 Map）
  @override
  Future<Map<String, dynamic>> ruleSubApplyUpdate({required int id}) async {
    final json = await bridge.ruleSubApplyUpdate(id: id);
    return _decodeMap(json, 'ruleSubApplyUpdate');
  }
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
