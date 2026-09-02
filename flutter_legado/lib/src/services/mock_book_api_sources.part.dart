// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiSources mixin：书架 / 书源 / 校验 / 登录 / 验证码。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiSources on MockBookApiStore implements BookApi {
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

  @override
  Future<int> importBooks(String jsonArray) async {
    final list = jsonDecode(jsonArray) as List<dynamic>;
    return list.length;
  }

  @override
  Future<void> reorderBooks(List<Map<String, dynamic>> orders) async {
    for (final item in orders) {
      final url = item['bookUrl'] as String?;
      final order = item['order'] as int?;
      if (url == null || order == null) continue;
      final idx = _books.indexWhere((b) => b.bookUrl == url);
      if (idx >= 0) _books[idx] = _books[idx].copyWith(order: order);
    }
    _books.sort((a, b) => a.order.compareTo(b.order));
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
    final idx = _sources.indexWhere(
      (s) => s.bookSourceUrl == source.bookSourceUrl,
    );
    if (idx >= 0) _sources[idx] = source;
  }

  /// 设置书源自定义变量（契约 §2.3，台账 §5.11-3，Task #63 冻结 / #64-65 实现）
  ///
  /// Mock：短延迟模拟 FFI 往返；命中内存书源时同步回写 variable 字段
  /// （空串=清除，对齐 Rust 单列 UPDATE 语义）；书源不存在时抛错，
  /// 对齐 Rust Internal 语义（评审 S1） — Qoder
  @override
  Future<void> setSourceVariable(String sourceUrl, String variable) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == sourceUrl);
    if (idx < 0) {
      throw Exception('书源不存在: $sourceUrl');
    }
    _sources[idx] = _sources[idx].copyWith(variable: variable);
  }

  /// Mock：短延迟；无真实 Cookie 存储，调用即成功（对齐 void 语义）
  @override
  Future<void> clearCookie(String url) async {
    await Future.delayed(const Duration(milliseconds: 30));
    if (url.trim().isEmpty) {
      throw Exception('url 不能为空');
    }
  }

  @override
  Future<bool> looksLikeCurl(String text) async {
    await Future.delayed(const Duration(milliseconds: 10));
    final t = text.trimLeft().toLowerCase();
    return t == 'curl' ||
        t.startsWith('curl ') ||
        t.startsWith('curl.exe') ||
        t.startsWith('curl\t');
  }

  @override
  Future<String> curlToAnalyzeUrl(String text) async {
    await Future.delayed(const Duration(milliseconds: 10));
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw Exception('[CURL_EMPTY_INPUT]');
    // Mock：仅支持最简 `curl <url>` / `curl -L <url>`
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.isEmpty || !parts.first.toLowerCase().startsWith('curl')) {
      throw Exception('[CURL_INVALID]');
    }
    String? url;
    var follow = false;
    for (final p in parts.skip(1)) {
      if (p == '-L' || p == '--location') {
        follow = true;
        continue;
      }
      if (p.startsWith('-')) continue;
      url = p.replaceAll("'", '').replaceAll('"', '');
      break;
    }
    if (url == null || url.isEmpty) throw Exception('[CURL_MISSING_URL]');
    if (follow) return url;
    return '$url,{"followRedirects":false}';
  }

  @override
  Future<String> analyzeUrlToCurl(String text) async {
    await Future.delayed(const Duration(milliseconds: 10));
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw Exception('[CURL_EMPTY_INPUT]');
    final comma = RegExp(r'\s*,\s*\{').firstMatch(trimmed);
    final url = (comma == null ? trimmed : trimmed.substring(0, comma.start))
        .trim();
    if (url.isEmpty) throw Exception('[CURL_MISSING_URL]');
    var follow = true;
    if (comma != null) {
      final opt = trimmed.substring(comma.start);
      if (opt.contains('"followRedirects":false')) follow = false;
    }
    final quoted = url.contains('?') || url.contains(' ') ? "'$url'" : url;
    return follow ? 'curl -g -L $quoted' : 'curl -g $quoted';
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

  @override
  Future<String> extractJsSource(String content) async {
    // Mock 占位：返回基于脚本内容的假书源 JSON
    return jsonEncode({
      'bookSourceUrl': 'mock://js-source',
      'bookSourceName': 'Mock JS 书源',
      'bookSourceType': 0,
      'enabled': true,
      'mainJs': content,
    });
  }

  @override
  Future<String> checkJsSourceSyntax(String content) async {
    // Mock 占位：非空即视为语法合法
    return jsonEncode({
      'valid': content.trim().isNotEmpty,
      'message': content.trim().isNotEmpty ? 'Mock 语法检查通过' : 'JS源内容为空',
      'line': null,
    });
  }

  @override
  Future<String> stampJsSourceLastUpdateTime(String content, int stamp) async {
    // Mock 占位：原样返回（不模拟写回）
    return content;
  }

  // ========== 书源校验（Task #87） ==========

  /// 构造 Mock 的 CheckResult（四步全部通过，无验证码/重定向）
  Map<String, dynamic> _mockCheckResult(String sourceUrl) => {
    'source_url': sourceUrl,
    'search_ok': true,
    'toc_ok': true,
    'content_ok': true,
    'search_error': null,
    'toc_error': null,
    'content_error': null,
    'total_time_ms': 321,
    'captcha': {
      'detected': false,
      'captcha_type': null,
      'matched_keyword': null,
    },
    'redirect': null,
  };

  @override
  Future<Map<String, dynamic>> checkSource(
    String sourceJson, {
    String? configJson,
  }) async {
    // Mock 占位：模拟校验耗时后返回全部通过
    await Future.delayed(const Duration(milliseconds: 300));
    final dynamic decoded = jsonDecode(sourceJson);
    final url = decoded is Map<String, dynamic>
        ? (decoded['bookSourceUrl'] ?? '') as String
        : '';
    return _mockCheckResult(url);
  }

  @override
  Stream<Map<String, dynamic>> checkSourcesStream(
    List<String> sourceUrls, {
    String? configJson,
  }) async* {
    // Mock 占位：逐个推送全部通过的进度（空列表校验全部 mock 书源）
    final urls = sourceUrls.isEmpty
        ? _sources.map((s) => s.bookSourceUrl).toList()
        : sourceUrls;
    final total = urls.length;
    for (var i = 0; i < total; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      final matches = _sources
          .where((s) => s.bookSourceUrl == urls[i])
          .toList();
      final name = matches.isEmpty ? urls[i] : matches.first.bookSourceName;
      yield {
        'index': i,
        'total': total,
        'is_last': i == total - 1,
        'source_name': name,
        'result': _mockCheckResult(urls[i]),
      };
    }
  }

  @override
  Future<void> cancelCheckSources() async {
    // Mock 占位：无后台任务，无需取消
  }

  // ========== 书源登录 V2 动态状态协议（上游 #402/#488） — QoderCN ==========

  @override
  Future<bool> isLoginUiV2(String sourceJson) async => false;

  @override
  Future<String> loginUiV2(String sourceJson, String stateJson) async =>
      '{"rows":[]}';

  @override
  Future<String> loginActionV2(String sourceJson, String userInputJson) async =>
      '{"close":true}';

  @override
  Future<void> putLoginInfo(String sourceUrl, String infoJson) async {
    // Mock：内存态保存，供 USE_MOCK 开发模式联调
    _mockLoginInfo[sourceUrl] = infoJson;
  }

  @override
  Future<void> putLoginHeader(String sourceUrl, String headerJson) async {
    _mockLoginHeader[sourceUrl] = headerJson;
  }

  @override
  Future<String> getLoginInfo(String sourceUrl) async =>
      _mockLoginInfo[sourceUrl] ?? '';

  @override
  Future<String> getLoginHeader(String sourceUrl) async =>
      _mockLoginHeader[sourceUrl] ?? '';

  // ========== 验证码交互通道（Task #90） ==========

  @override
  Stream<Map<String, dynamic>> verificationRequestStream() async* {
    // Mock 占位：无 JS 引擎，不会产生验证码请求
  }

  @override
  Future<bool> submitVerificationResult(String key, String code) async {
    // Mock 占位：无进行中的请求，返回未命中
    return false;
  }

  @override
  Future<bool> cancelVerificationRequest(String key) async {
    // Mock 占位：无进行中的请求，返回未命中
    return false;
  }

  @override
  Stream<Map<String, dynamic>> webviewRequestStream() async* {
    // Mock 占位：无真实 WebView 通道
  }

  @override
  Future<bool> submitWebviewResult(String key, String result) async => false;

  @override
  Future<bool> cancelWebviewRequest(String key) async => false;
}
