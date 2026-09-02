// rust_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 RustApiSources mixin：书架 / 书源 / 校验 / 登录 / 验证码 / WebView 通道。
// RustApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 解码辅助来自 RustApiDecode（on 约束），同一 library 内私有成员可直接访问。
part of 'rust_api.dart';

mixin RustApiSources on RustApiDecode implements BookApi {
  // ========== 书架操作 ==========

  /// 获取书架上所有书籍
  @override
  Future<List<Book>> getBooks() async {
    final json = await bridge.bookshelfList();
    final list = _decodeList(json, 'bookApi');
    return list.map((e) => Book.fromJson(e as Map<String, dynamic>)).toList();
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
    final json = await bridge.sourceAdd(
      sourceJson: jsonEncode(source.toJson()),
    );
    CoverDecodeLoader.invalidateSourceRegistry();
    return BookSource.fromJson(_decodeMap(json, 'bookApi'));
  }

  /// 更新书源
  @override
  Future<void> updateBookSource(BookSource source) async {
    await bridge.sourceUpdate(sourceJson: jsonEncode(source.toJson()));
    CoverDecodeLoader.invalidateSourceRegistry();
  }

  /// 设置书源自定义变量（契约 §2.3，台账 §5.11-3，Task #65）
  ///
  /// 直通 set_source_variable FFI（单列 UPDATE，空串=清除）；
  /// 书源不存在/写入失败由 Rust 侧抛 BridgeError — Qoder
  @override
  Future<void> setSourceVariable(String sourceUrl, String variable) async {
    await bridge.setSourceVariable(
      sourceUrl: sourceUrl,
      variable: variable,
    );
    CoverDecodeLoader.invalidateSourceRegistry();
  }

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
  Future<void> deleteBookSource(String sourceUrl) async {
    await bridge.sourceDelete(sourceUrl: sourceUrl);
    CoverDecodeLoader.invalidateSourceRegistry();
  }

  /// 启用书源
  @override
  Future<void> enableBookSource(String sourceUrl) async {
    await bridge.sourceEnable(sourceUrl: sourceUrl);
    CoverDecodeLoader.invalidateSourceRegistry();
  }

  /// 禁用书源
  @override
  Future<void> disableBookSource(String sourceUrl) async {
    await bridge.sourceDisable(sourceUrl: sourceUrl);
    CoverDecodeLoader.invalidateSourceRegistry();
  }

  /// 批量导入书源，返回成功导入的数量
  @override
  Future<int> importBookSources(String jsonArray) async {
    final count = await bridge.sourceImport(jsonArray: jsonArray);
    CoverDecodeLoader.invalidateSourceRegistry();
    return count;
  }

  /// 导出所有书源为 JSON 数组
  @override
  Future<String> exportBookSources() => bridge.sourceExport();

  /// 书源排序（将排序偏好存入配置）
  @override
  Future<void> sortBookSources(int sortKey, bool ascending) async {
    await bridge.configSet(key: 'source_sort_key', value: sortKey.toString());
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
        await bridge.sourceLoginUiV2(
          sourceJson: sourceJson,
          stateJson: stateJson,
        ),
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

  /// 保存书源登录用户信息（对齐原版 BaseSource.putLoginInfo → `userInfo_<key>`）
  @override
  Future<void> putLoginInfo(String sourceUrl, String infoJson) =>
      bridge.sourcePutLoginInfo(sourceUrl: sourceUrl, infoJson: infoJson);

  /// 保存书源登录头（对齐原版 BaseSource.putLoginHeader → `loginHeader_<key>`）
  @override
  Future<void> putLoginHeader(String sourceUrl, String headerJson) =>
      bridge.sourcePutLoginHeader(sourceUrl: sourceUrl, headerJson: headerJson);

  /// 读取书源登录用户信息（无则空串）
  @override
  Future<String> getLoginInfo(String sourceUrl) =>
      bridge.sourceGetLoginInfo(sourceUrl: sourceUrl);

  /// 读取书源登录头（无则空串）
  @override
  Future<String> getLoginHeader(String sourceUrl) =>
      bridge.sourceGetLoginHeader(sourceUrl: sourceUrl);

  // ========== 验证码交互通道（Task #90） ==========

  /// 订阅验证码请求事件流（长期存活）
  ///
  /// 事件 Map 字段见 [BookApi.verificationRequestStream]。
  /// 订阅时 Rust 侧先回放当前进行中的请求。
  @override
  Stream<Map<String, dynamic>> verificationRequestStream() {
    return bridge.verificationRequestStream().map(
      (item) => _decodeMap(item, 'verificationRequestStream'),
    );
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
    return bridge.webviewRequestStream().map(
      (item) => _decodeMap(item, 'webviewRequestStream'),
    );
  }

  @override
  Future<bool> submitWebviewResult(String key, String result) =>
      bridge.webviewSubmit(key: key, result: result);

  @override
  Future<bool> cancelWebviewRequest(String key) =>
      bridge.webviewCancel(key: key);
}
