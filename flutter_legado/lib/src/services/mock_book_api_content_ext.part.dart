// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiContentExt mixin：音频播放模式 / 压缩包导入 / 正文高亮 / 应用日志 / 规则订阅。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiContentExt on MockBookApiStore implements BookApi {
  // ========== 音频播放模式 ==========

  @override
  Future<String> audioWithPlayMode({
    String? readConfig,
    required int playMode,
  }) async {
    final config = readConfig != null && readConfig.isNotEmpty
        ? (jsonDecode(readConfig) as Map<String, dynamic>)
        : <String, dynamic>{};
    config['audioPlayMode'] = playMode;
    return jsonEncode(config);
  }

  @override
  Future<Map<String, dynamic>?> audioResolvePlayBook({
    String? requestedBookUrl,
    String? cachedBookJson,
  }) async {
    if (requestedBookUrl == null || requestedBookUrl.isEmpty) {
      if (cachedBookJson != null && cachedBookJson.isNotEmpty) {
        return jsonDecode(cachedBookJson) as Map<String, dynamic>;
      }
      return null;
    }
    final book = await getBook(requestedBookUrl);
    return book?.toJson();
  }

  // ========== 压缩包导入 ==========

  @override
  Future<Map<String, dynamic>> archiveImportZip({
    required String zipPath,
    required String outputDir,
  }) async => {
    'success': true,
    'imported_count': 2,
    'files': ['book1.txt', 'book2.epub'],
  };

  @override
  Future<Map<String, dynamic>> archiveImportRar({
    required String rarPath,
    required String outputDir,
    String? password,
  }) async => {
    'success': true,
    'imported_count': 1,
    'files': ['book1.txt'],
  };

  @override
  Future<List<String>> archiveListZipFiles({required String zipPath}) async => [
    'book1.txt',
    'book2.epub',
    'readme.md',
  ];

  @override
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  }) async => ['novel.txt'];

  @override
  Future<Map<String, dynamic>> archiveDetectEncoding({
    required String filePath,
  }) async => {'encoding': 'UTF-8', 'has_bom': false, 'confidence': 'high'};

  @override
  Future<Map<String, dynamic>> archiveConvertEncoding({
    required String filePath,
    required String fromEncoding,
    required String toEncoding,
  }) async => {'success': true, 'output_path': '$filePath.converted'};

  @override
  Future<bool> archiveIsArchive({required String filePath}) async {
    return filePath.endsWith('.zip') ||
        filePath.endsWith('.rar') ||
        filePath.endsWith('.7z');
  }

  // ========== 正文高亮（highlight Mock） ==========

  /// 内存高亮记录（key = time 主键）
  final Map<int, Map<String, dynamic>> _mockHighlights = {};

  /// 内存高亮规则（key = id）
  final Map<int, Map<String, dynamic>> _mockHighlightRules = {};

  @override
  Future<int> highlightAdd({required String highlightJson}) async {
    final h = jsonDecode(highlightJson) as Map<String, dynamic>;
    var time = (h['time'] as num?)?.toInt() ?? 0;
    if (time == 0) {
      time = DateTime.now().millisecondsSinceEpoch;
      while (_mockHighlights.containsKey(time)) {
        time += 1;
      }
    }
    h['time'] = time;
    _mockHighlights[time] = h;
    return time;
  }

  @override
  Future<bool> highlightDelete({required int time}) async {
    return _mockHighlights.remove(time) != null;
  }

  @override
  Future<int> highlightDeleteByBook({required String bookUrl}) async {
    final keys = _mockHighlights.entries
        .where((e) => e.value['bookUrl'] == bookUrl)
        .map((e) => e.key)
        .toList();
    keys.forEach(_mockHighlights.remove);
    return keys.length;
  }

  String _highlightListJson(Iterable<Map<String, dynamic>> items) =>
      jsonEncode(items.toList());

  @override
  Future<String> highlightListByBook({required String bookUrl}) async {
    final items =
        _mockHighlights.values.where((h) => h['bookUrl'] == bookUrl).toList()
          ..sort(
            (a, b) =>
                ((a['time'] as num?) ?? 0).compareTo((b['time'] as num?) ?? 0),
          );
    return _highlightListJson(items);
  }

  @override
  Future<String> highlightListByChapter({
    required String bookUrl,
    required int chapterIndex,
  }) async {
    final items =
        _mockHighlights.values
            .where(
              (h) =>
                  h['bookUrl'] == bookUrl && h['chapterIndex'] == chapterIndex,
            )
            .toList()
          ..sort(
            (a, b) =>
                ((a['time'] as num?) ?? 0).compareTo((b['time'] as num?) ?? 0),
          );
    return _highlightListJson(items);
  }

  @override
  Future<String> highlightSearch({required String keyword}) async {
    final key = keyword.toLowerCase();
    final items = _mockHighlights.values
        .where(
          (h) =>
              ((h['bookText'] as String?) ?? '').toLowerCase().contains(key) ||
              ((h['note'] as String?) ?? '').toLowerCase().contains(key),
        )
        .toList();
    return _highlightListJson(items);
  }

  @override
  Future<String> highlightListAll() async =>
      _highlightListJson(_mockHighlights.values);

  @override
  Future<String> highlightRuleList() async {
    final items = _mockHighlightRules.values.toList()
      ..sort(
        (a, b) => ((a['sortOrder'] as num?) ?? 0).compareTo(
          (b['sortOrder'] as num?) ?? 0,
        ),
      );
    return _highlightListJson(items);
  }

  @override
  Future<int> highlightRuleSave({required String ruleJson}) async {
    final rule = jsonDecode(ruleJson) as Map<String, dynamic>;
    var id = (rule['id'] as num?)?.toInt() ?? 0;
    if (id == 0) {
      id = _nextId++;
      rule['id'] = id;
    }
    _mockHighlightRules[id] = rule;
    return id;
  }

  @override
  Future<bool> highlightRuleDelete({required int id}) async {
    return _mockHighlightRules.remove(id) != null;
  }

  @override
  Future<String> highlightRuleFindEnabled({
    required String bookName,
    required String origin,
  }) async {
    final items =
        _mockHighlightRules.values.where((r) {
          final enabled = (r['isEnabled'] as bool?) ?? false;
          if (!enabled) return false;
          final scope = r['scope'] as String?;
          if (scope == null || scope.isEmpty) return true;
          return scope.contains(bookName) || scope.contains(origin);
        }).toList()..sort(
          (a, b) => ((a['sortOrder'] as num?) ?? 0).compareTo(
            (b['sortOrder'] as num?) ?? 0,
          ),
        );
    return _highlightListJson(items);
  }

  // ========== 应用日志（appLog 假实现） ==========
  // [审计修复 §1.2] 内存环形缓冲（每级最多 500 条），行为对齐 Rust log_api — QoderCN

  static const int _appLogMaxPerLevel = 500;
  final Map<String, List<Map<String, dynamic>>> _appLogs = {};

  @override
  Future<void> appLogPush({
    required String level,
    required String message,
  }) async {
    if (message.isEmpty) return; // 对齐 Kotlin put 的空消息短路
    final bucket = _appLogs.putIfAbsent(level, () => <Map<String, dynamic>>[]);
    bucket.insert(0, {
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'level': level,
      'message': message,
    });
    if (bucket.length > _appLogMaxPerLevel) {
      bucket.removeRange(_appLogMaxPerLevel, bucket.length);
    }
  }

  @override
  Future<String> appLogList({required String level}) async =>
      jsonEncode(_appLogs[level] ?? const <Map<String, dynamic>>[]);

  @override
  Future<void> appLogClear({required String level}) async {
    _appLogs.remove(level);
  }

  @override
  Future<void> appLogClearAll() async {
    _appLogs.clear();
  }

  @override
  Future<String> appLogExport() async {
    // 时间升序导出（对齐 #543），截断 64_000 字符
    final all = _appLogs.values.expand((entries) => entries).toList()
      ..sort(
        (a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int),
      );
    final buffer = StringBuffer();
    for (final entry in all) {
      buffer.writeln(
        '[${entry['timestamp']}] [${entry['level']}] ${entry['message']}',
      );
    }
    final text = buffer.toString();
    return text.length > 64000 ? text.substring(0, 64000) : text;
  }

  // ========== 规则订阅（Task #89） ==========

  /// Mock 内存态订阅列表（自增 ID 分配，语义对齐 Rust rule_sub FFI）
  final List<Map<String, dynamic>> _ruleSubs = [];
  int _ruleSubNextId = 1;

  @override
  Future<List<Map<String, dynamic>>> ruleSubList() async {
    final list = _ruleSubs.map((e) => Map<String, dynamic>.from(e)).toList()
      ..sort(
        (a, b) => (a['customOrder'] as int).compareTo(b['customOrder'] as int),
      );
    return list;
  }

  @override
  Future<bool> ruleSubSave({required String subJson}) async {
    final dynamic decoded = jsonDecode(subJson);
    if (decoded is! Map<String, dynamic>) return false;
    final sub = Map<String, dynamic>.from(decoded);
    final id = (sub['id'] as num?)?.toInt() ?? 0;
    if (id > 0) {
      final index = _ruleSubs.indexWhere((e) => e['id'] == id);
      if (index >= 0) {
        _ruleSubs[index] = sub;
        return true;
      }
    }
    sub['id'] = _ruleSubNextId++;
    sub.putIfAbsent('customOrder', () => _ruleSubs.length);
    _ruleSubs.add(sub);
    return true;
  }

  @override
  Future<bool> ruleSubDelete({required int id}) async {
    final before = _ruleSubs.length;
    _ruleSubs.removeWhere((e) => e['id'] == id);
    return _ruleSubs.length < before;
  }

  @override
  Future<bool> ruleSubSetEnabled({
    required int id,
    required bool enabled,
  }) async {
    final index = _ruleSubs.indexWhere((e) => e['id'] == id);
    if (index < 0) return false;
    _ruleSubs[index]['isEnabled'] = enabled;
    return true;
  }

  @override
  Future<bool> ruleSubUpdateOrder({required List<int> ids}) async {
    for (var i = 0; i < ids.length; i++) {
      final index = _ruleSubs.indexWhere((e) => e['id'] == ids[i]);
      if (index >= 0) _ruleSubs[index]['customOrder'] = i;
    }
    return true;
  }

  @override
  Future<Map<String, dynamic>> ruleSubCheckUpdate({required int id}) async {
    final index = _ruleSubs.indexWhere((e) => e['id'] == id);
    if (index < 0) {
      return {'id': id, 'error': '订阅不存在'};
    }
    final sub = _ruleSubs[index];
    // Mock 占位：无网络，始终返回无更新
    return {
      'id': id,
      'url': sub['url'] ?? '',
      'name': sub['name'] ?? '',
      'dueForUpdate': true,
      'hasUpdate': false,
      'remoteVersion': sub['version'] ?? '',
      'error': null,
    };
  }

  @override
  Future<Map<String, dynamic>> ruleSubApplyUpdate({required int id}) async {
    final index = _ruleSubs.indexWhere((e) => e['id'] == id);
    if (index < 0) {
      return {'id': id, 'success': false, 'error': '订阅不存在'};
    }
    // Mock 占位：无网络，模拟应用成功但无条目变更
    return {
      'id': id,
      'url': _ruleSubs[index]['url'] ?? '',
      'success': true,
      'itemsAdded': 0,
      'itemsUpdated': 0,
      'itemsRemoved': 0,
      'totalItems': 0,
      'error': null,
    };
  }
}
