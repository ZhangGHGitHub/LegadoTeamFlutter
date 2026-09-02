// rust_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 RustApiReaderData mixin：书签 / 替换规则 / 阅读器 / 配置 / 词典 / 日志 / 备份 / 阅读记录。
// RustApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 解码辅助来自 RustApiDecode（on 约束），同一 library 内私有成员可直接访问。
part of 'rust_api.dart';

mixin RustApiReaderData on RustApiDecode implements BookApi {
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
  Future<void> deleteBookmark(int id) => bridge.bookmarkDelete(bookmarkId: id);

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
  Future<void> updateReplaceRule(ReplaceRule rule) => bridge.replaceRuleUpdate(
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
  Future<String> getChapterContentFull(
    String bookUrl,
    int chapterIndex,
  ) async =>
      // 平台桥接拦截：正文规则可能以 webView 类桥接载荷作为整体返回（Task #114）— QoderCN
      PlatformBridgeService.instance.interceptResult(
        await bridge.readerGetContentFull(
          bookUrl: bookUrl,
          chapterIndex: chapterIndex,
        ),
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
  }) async => bridge.saveChapterContent(
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
  }) => bridge.readerUpdateProgress(
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
  ) => bridge.readerToggleSameTitleRemoved(
    bookUrl: bookUrl,
    chapterIndex: chapterIndex,
    enable: enable,
  );

  @override
  Future<bool> getSameTitleRemoved(String bookUrl, int chapterIndex) => bridge
      .readerGetSameTitleRemoved(bookUrl: bookUrl, chapterIndex: chapterIndex);

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
      throw RustApiException(
        'Backup file not found: $backupPath',
        operation: 'restore',
      );
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

  /// 按年查询每日阅读时长列表（热力图"每日时长"模式数据源）
  @override
  Future<List<Map<String, dynamic>>> readRecordDailyList(int year) async {
    final json = await bridge.readRecordDailyList(year: year);
    return _decodeList(json, 'bookApi').cast<Map<String, dynamic>>();
  }
}
