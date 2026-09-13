// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiReaderData mixin：书签 / 替换规则 / 阅读器 / 配置 / 词典 / 备份 / 阅读记录。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiReaderData on MockBookApiStore implements BookApi {
  // ========== 书签操作 ==========

  @override
  Future<List<Bookmark>> getBookmarks(String bookName) async =>
      _bookmarks.where((b) => b.bookName == bookName).toList();

  /// 按书名+作者获取书签（契约 §2.7，台账 §5.14-2，Task #65）
  ///
  /// Mock：短延迟后返回内存书签按 bookName + bookAuthor 双键过滤结果，
  /// 无命中返回空列表（对齐原版 bookmarkDao.getByBook） — Qoder
  @override
  Future<List<Bookmark>> getBookmarksByBook(
    String bookName,
    String bookAuthor,
  ) async {
    await Future.delayed(const Duration(milliseconds: 50));
    return _bookmarks
        .where((b) => b.bookName == bookName && b.bookAuthor == bookAuthor)
        .toList();
  }

  @override
  Future<List<Bookmark>> getAllBookmarks() async => List.from(_bookmarks);

  @override
  Future<Bookmark> addBookmark(Bookmark bookmark) async {
    final bm = bookmark.copyWith(id: _nextId++);
    _bookmarks.add(bm);
    return bm;
  }

  @override
  Future<void> updateBookmark(Bookmark bookmark) async {
    final idx = _bookmarks.indexWhere((b) => b.id == bookmark.id);
    if (idx >= 0) _bookmarks[idx] = bookmark;
  }

  @override
  Future<void> deleteBookmark(int id) async {
    _bookmarks.removeWhere((b) => b.id == id);
  }

  @override
  Future<List<Bookmark>> searchBookmarks(String keyword) async => _bookmarks
      .where((b) => b.content.contains(keyword) || b.bookText.contains(keyword))
      .toList();

  // ========== 替换规则操作 ==========

  @override
  Future<List<ReplaceRule>> getReplaceRules() async => List.from(_replaceRules);

  @override
  Future<List<ReplaceRule>> getEnabledReplaceRules() async =>
      _replaceRules.where((r) => r.isEnabled).toList();

  @override
  Future<ReplaceRule> addReplaceRule(ReplaceRule rule) async {
    final r = rule.copyWith(id: _nextId++);
    _replaceRules.add(r);
    return r;
  }

  @override
  Future<void> updateReplaceRule(ReplaceRule rule) async {
    final idx = _replaceRules.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) _replaceRules[idx] = rule;
  }

  @override
  Future<void> deleteReplaceRule(int id) async {
    _replaceRules.removeWhere((r) => r.id == id);
  }

  @override
  Future<void> setReplaceRuleEnabled(int id, bool enabled) async {
    final idx = _replaceRules.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      _replaceRules[idx] = _replaceRules[idx].copyWith(isEnabled: enabled);
    }
  }

  /// [书源作用域 | 2026-09-13] 书源导入时应用「书源作用域」替换规则
  ///
  /// Mock 不实现真实替换引擎，原样返回输入 [sourceJson]
  /// （对齐契约「任何错误均原样返回、不中断导入」的保守语义），
  /// 并累计调用计数（`applyReplaceRulesToSourceCalls`）供测试断言。
  @override
  Future<String> applyReplaceRulesToSource(
    String sourceJson,
    String sourceName,
    String sourceUrl,
  ) async {
    _applyReplaceRulesToSourceCalls++;
    return sourceJson;
  }

  /// [替换规则预览 | 2026-09-13] 替换规则编辑器预览（确定性 Mock，供测试）
  ///
  /// Mock 不实现真实替换引擎：固定返回 `[mock预览] ` + [sampleContent]，
  /// 并累计调用计数（`previewReplaceRuleCalls`）供测试断言。
  @override
  Future<String> previewReplaceRule(
    String ruleJson,
    String sampleContent,
  ) async {
    _previewReplaceRuleCalls++;
    return '[mock预览] $sampleContent';
  }

  // ========== 阅读器操作 ==========

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async =>
      _chaptersCache[bookUrl] ?? [];

  @override
  Future<String> getChapterContent(String bookUrl, int chapterIndex) async {
    return _contentCache[bookUrl]?[chapterIndex] ?? '（暂无内容）';
  }

  @override
  Future<String> getChapterContentRaw(String bookUrl, int chapterIndex) async {
    // Mock 层不区分净化/raw，返回同一份缓存内容
    return _contentCache[bookUrl]?[chapterIndex] ?? '（暂无内容）';
  }

  @override
  Future<String> getChapterContentFull(String bookUrl, int chapterIndex) async {
    // Mock 层不区分本地/在线，统一返回缓存内容
    return _contentCache[bookUrl]?[chapterIndex] ?? '（Mock 模式：章节内容）';
  }

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return '（Mock 模式：网络章节内容）\n\n这是从网络获取的章节正文。';
  }

  // [Service-fix v2.0.3 | 2026-08-08] 写入/覆盖单章缓存正文（Mock：
  // 回写 _contentCache，后续 getChapterContent* 读到新内容） — QoderCN
  @override
  Future<bool> saveChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required String title,
    required String content,
  }) async {
    _contentCache.putIfAbsent(bookUrl, () => <int, String>{})[chapterIndex] =
        content;
    return true;
  }

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {
    final idx = _books.indexWhere((b) => b.bookUrl == bookUrl);
    if (idx >= 0) {
      _books[idx] = _books[idx].copyWith(
        durChapterIndex: chapterIndex,
        durChapterPos: chapterPos,
      );
    }
  }

  @override
  Future<List<BookChapter>> refreshToc(
    String bookUrl,
    String sourceUrl,
  ) async => _chaptersCache[bookUrl] ?? [];

  /// 繁简转换类型 Mock 持久化键（与 Rust 侧配置键同名）
  static const _chineseConvertKey = 'chineseConverterType';

  @override
  Future<void> setChineseConvertType(int type) async {
    // 非法取值归一为 0，与 Rust 侧语义对齐
    final normalized = (type >= 0 && type <= 2) ? type : 0;
    _configs[_chineseConvertKey] = normalized.toString();
  }

  @override
  Future<int> getChineseConvertType() async {
    return int.tryParse(_configs[_chineseConvertKey] ?? '') ?? 0;
  }

  /// 章级「删除重复标题」opt-out 记录（契约 §2.9.10，Task #50）
  ///
  /// Mock 内存态：集合内存放「保留原标题」的 `${bookUrl}#$chapterIndex`。
  final Set<String> _sameTitleOptOut = {};

  @override
  Future<void> toggleSameTitleRemoved(
    String bookUrl,
    int chapterIndex,
    bool enable,
  ) async {
    // Mock：短延迟模拟 FFI 往返；enable=true 恢复全局默认，false 章级 opt-out
    await Future.delayed(const Duration(milliseconds: 50));
    final key = '$bookUrl#$chapterIndex';
    if (enable) {
      _sameTitleOptOut.remove(key);
    } else {
      _sameTitleOptOut.add(key);
    }
  }

  @override
  Future<bool> getSameTitleRemoved(String bookUrl, int chapterIndex) async {
    return !_sameTitleOptOut.contains('$bookUrl#$chapterIndex');
  }

  @override
  Future<bool> canRemoveSameTitle(
    String chapterTitle,
    String rawContent,
  ) async {
    if (chapterTitle.isEmpty || rawContent.isEmpty) return false;
    return rawContent.trimLeft().startsWith(chapterTitle);
  }

  // ========== 配置操作 ==========

  @override
  Future<String?> getConfig(String key) async => _configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    _configs[key] = value;
  }

  @override
  Future<void> deleteConfig(String key) async {
    _configs.remove(key);
  }

  @override
  Future<Map<String, String>> getAllConfigs() async => Map.from(_configs);

  // ========== 词典操作 ==========

  /// 内置 Mock 词典（占位数据，字段对齐 Rust `DictEntry`）
  static const _mockDict = <String, Map<String, dynamic>>{
    'chapter': {
      'word': 'chapter',
      'phonetic': '/ˈtʃæptə(r)/',
      'definitions': ['n. 章，章节', 'n. （人生的）一段时期'],
    },
    'novel': {
      'word': 'novel',
      'phonetic': '/ˈnɒvl/',
      'definitions': ['n. 长篇小说', 'adj. 新奇的，异常的'],
    },
    'library': {
      'word': 'library',
      'phonetic': '/ˈlaɪbrəri/',
      'definitions': ['n. 图书馆，藏书室', 'n. 文库，（软件）库'],
    },
  };

  @override
  Future<Map<String, dynamic>> dictLookup(String word) async {
    // 模拟查询延迟
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final key = word.trim().toLowerCase();
    final hit = _mockDict[key];
    if (hit != null) return hit;
    // 未收录词：返回空 definitions（非异常，对齐契约）
    return {'word': key, 'phonetic': '', 'definitions': <String>[]};
  }

  // ========== 字典规则操作（契约 §2.45，mock 内存态） ==========
  //
  // 对齐 Rust dict_rule_* 语义：空表 seed 默认 5 源 / name 唯一 /
  // reorder 重编号 / 导入 REPLACE by name。mock 不执行查询链路
  // （dictLookup 走静态 _mockDict），规则内容仅为内存态。

  /// 列出全部字典规则（表为空时注入原版默认 5 源，ORDER BY sortNumber, id）
  @override
  Future<List<Map<String, dynamic>>> dictRuleList() async {
    if (_dictRules.isEmpty) _seedDefaultDictRules();
    final ordered = List<Map<String, dynamic>>.from(_dictRules)
      ..sort((a, b) {
        final bySort = (a['sortNumber'] as int).compareTo(b['sortNumber'] as int);
        if (bySort != 0) return bySort;
        return (a['id'] as int).compareTo(b['id'] as int);
      });
    return ordered.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// 新增字典规则（enabled=true, sortNumber=0；name 重复 → 错误，对标 name 主键）
  @override
  Future<int> dictRuleAdd({
    required String name,
    required String urlRule,
    required String showRule,
  }) async {
    if (_dictRules.any((r) => r['name'] == name)) {
      throw Exception('字典规则已存在: $name');
    }
    final id = _nextDictRuleId++;
    _dictRules.add({
      'id': id,
      'name': name,
      'urlRule': urlRule,
      'showRule': showRule,
      'enabled': true,
      'sortNumber': 0,
    });
    return id;
  }

  /// 更新字典规则（按 id 改 name/urlRule/showRule；不存在返回 false）
  @override
  Future<bool> dictRuleUpdate({
    required int id,
    required String name,
    required String urlRule,
    required String showRule,
  }) async {
    final hits = _dictRules.where((r) => r['id'] == id).toList();
    if (hits.isEmpty) return false;
    final rule = hits.first;
    rule['name'] = name;
    rule['urlRule'] = urlRule;
    rule['showRule'] = showRule;
    return true;
  }

  /// 删除字典规则（按 id；不存在返回 false）
  @override
  Future<bool> dictRuleDelete(int id) async {
    final before = _dictRules.length;
    _dictRules.removeWhere((r) => r['id'] == id);
    return _dictRules.length < before;
  }

  /// 设置字典规则启用/禁用（按 id；不存在返回 false）
  @override
  Future<bool> dictRuleSetEnabled({required int id, required bool enabled}) async {
    if (!_dictRules.any((r) => r['id'] == id)) return false;
    for (final r in _dictRules) {
      if (r['id'] == id) r['enabled'] = enabled;
    }
    return true;
  }

  /// 按给定 ID 顺序重编号 sortNumber（0..n，对标 upSortNumber；非法 JSON → 错误）
  @override
  Future<int> dictRuleReorder(String idsJson) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(idsJson);
    } on FormatException {
      throw Exception('解析 reorder IDs JSON 失败: $idsJson');
    }
    if (decoded is! List) {
      throw Exception('reorder IDs 须为 JSON 数组: $idsJson');
    }
    final ids = decoded.map((e) => (e as num).toInt()).toList();
    for (var idx = 0; idx < ids.length; idx++) {
      for (final r in _dictRules) {
        if (r['id'] == ids[idx]) r['sortNumber'] = idx;
      }
    }
    return ids.length;
  }

  /// 导入字典规则（GSON 数组/单对象，REPLACE by name；返回导入条数）
  ///
  /// kind=text：解析 JSON 文本；kind=url：mock 无网络能力，抛明确错误
  /// （Rust 轨走既有抓取链路，mock 不模拟）。
  @override
  Future<int> dictRuleImport({
    required String jsonOrUrl,
    required String kind,
  }) async {
    final rules = _parseImportDictRules(jsonOrUrl, kind);
    for (final rule in rules) {
      _upsertDictRuleByName(rule);
    }
    return rules.length;
  }

  /// 内存态导入解析（数组/单对象；enabled 缺省 true、sortNumber 缺省 0，GSON 语义）
  List<Map<String, dynamic>> _parseImportDictRules(String body, String kind) {
    if (kind == 'url') {
      throw Exception('mock 不支持 URL 导入（无网络能力）: $body');
    }
    final trimmed = body.trim();
    if (trimmed.isEmpty) throw Exception('导入内容为空');
    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw Exception('解析导入 JSON 失败: $body');
    }
    final List<dynamic> items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map) {
      items = [decoded];
    } else {
      throw Exception('解析导入 JSON 失败: 须为对象数组或单对象');
    }
    if (items.any((e) => e is! Map)) {
      throw Exception('解析导入 JSON 失败: 须为对象数组或单对象');
    }
    final rules = <Map<String, dynamic>>[];
    for (final dynamic e in items) {
      final m = e as Map;
      rules.add({
        'name': (m['name'] ?? '').toString().trim(),
        'urlRule': (m['urlRule'] ?? '').toString(),
        'showRule': (m['showRule'] ?? '').toString(),
        'enabled': m['enabled'] is bool ? m['enabled'] : true,
        // JSON decode 的整数可能为 num（double 字面量场景），统一归一为 int
        'sortNumber': m['sortNumber'] is num ? (m['sortNumber'] as num).toInt() : 0,
      });
    }
    return rules.where((r) => (r['name'] as String).isNotEmpty).toList();
  }

  /// 内存态 REPLACE by name（同名覆盖 urlRule/showRule/enabled/sortNumber 保留 id，
  /// 异名插入）
  void _upsertDictRuleByName(Map<String, dynamic> rule) {
    final name = rule['name'] as String;
    final existing =
        _dictRules.cast<Map<String, dynamic>>().firstWhere(
              (r) => r['name'] == name,
              orElse: () => const {},
            );
    if (existing.isNotEmpty) {
      existing['urlRule'] = rule['urlRule'];
      existing['showRule'] = rule['showRule'];
      existing['enabled'] = rule['enabled'];
      existing['sortNumber'] = rule['sortNumber'];
      return;
    }
    _dictRules.add({'id': _nextDictRuleId++, ...rule});
  }

  // ========== 备份操作 ==========

  @override
  Future<String> backup(String dirPath) async {
    return '$dirPath/legado_backup_mock.json';
  }

  @override
  Future<void> restore(String backupPath) async {}

  @override
  Future<List<String>> backupList(String dir) async => [];

  @override
  Future<String> importOldData(String dirPath) async {
    return jsonEncode({
      'books': 0,
      'bookSources': 0,
      'replaceRules': 0,
      'messages': <String>['mock: 未找到旧版备份文件'],
    });
  }

  // ========== 阅读记录 ==========

  @override
  Future<List<ReadRecord>> getReadRecords() async => List.from(_readRecords);

  @override
  Future<void> putReadRecord(ReadRecord record) async {
    _readRecords.removeWhere((r) => r.bookName == record.bookName);
    _readRecords.add(record);
  }

  @override
  Future<void> deleteReadRecord(String bookName) async {
    _readRecords.removeWhere((r) => r.bookName == bookName);
  }

  @override
  Future<void> clearReadRecords() async {
    _readRecords.clear();
  }

  @override
  Future<List<Map<String, dynamic>>> readRecordDailyList(int year) async => const [];
}
