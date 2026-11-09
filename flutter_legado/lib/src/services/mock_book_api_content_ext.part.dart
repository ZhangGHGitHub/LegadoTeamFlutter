// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiContentExt mixin：音频播放模式 / 压缩包导入 / 正文高亮 / 应用日志 / 规则订阅。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

/// Mock 高亮匹配候选（字节即 UTF-16 code unit，Dart String 下标原生一致）
class _MockHighlightCandidate {
  _MockHighlightCandidate({
    required this.start,
    required this.end,
    required this.ruleIndex,
    required this.seq,
    required this.order,
  });

  final int start;
  final int end;
  final int ruleIndex;
  final int seq;
  final int order;
}

/// Mock 已接受区间（与候选同口径）
class _MockAccepted {
  _MockAccepted({
    required this.start,
    required this.end,
    required this.ruleIndex,
  });

  final int start;
  final int end;
  final int ruleIndex;
}

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
    // 键名对齐 Rust `with_audio_play_mode` 与 ReadConfig.playMode
    config['playMode'] = playMode;
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
    'extracted_files': ['book1.txt', 'book2.epub'],
    'error': null,
  };

  @override
  Future<Map<String, dynamic>> archiveImportRar({
    required String rarPath,
    required String outputDir,
    String? password,
  }) async => {
    'success': true,
    'extracted_files': ['book1.txt'],
    'error': null,
  };

  @override
  Future<List<String>> archiveListZipFiles({required String zipPath}) async => [
    'book1.txt',
    'book2.epub',
  ];

  @override
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  }) async => ['novel.txt'];

  @override
  Future<Map<String, dynamic>> archiveImport7z({
    required String sevenZipPath,
    required String outputDir,
  }) async => {
    'success': true,
    'extracted_files': ['book1.txt'],
    'error': null,
  };

  @override
  Future<List<String>> archiveList7zFiles({required String sevenZipPath}) async =>
      ['book1.txt', 'book2.epub'];

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

  // ========== 书签标记（book_marks，契约 §2.52，批7b-1） ==========

  /// 内存书签标记（key = id；Mock 每次实例独立，测试可新建实例或逐条删除清空）
  final Map<String, BookMarking> _mockBookMarkings = {};

  /// Mock 标记 ID 序列：生成的 id **仅测试占位，不是 UUID**（形如
  /// `mock-marking-<n>-<micros>`）；真实 UUID v4 由 Rust `saveBookMarking` 生成。
  int _nextMockMarkingSeq = 1;

  /// 章节索引比较：NULL 在前（对齐 SQLite `ORDER BY chapterIndex ASC`）
  int _compareChapterIndex(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return a.compareTo(b);
  }

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
          final scopeRaw = r['scope'];
          final scope = scopeRaw is String ? scopeRaw : '';
          if (scope.isEmpty) return true;
          // 空 bookName/origin 不得命中任何非空 scope（对齐 Rust
          // `(?1 != '' AND instr(scope, ?1) > 0)` 空串守卫，P3-4）
          return (bookName.isNotEmpty && scope.contains(bookName)) ||
              (origin.isNotEmpty && scope.contains(origin));
        }).toList()..sort(
          (a, b) => ((a['sortOrder'] as num?) ?? 0).compareTo(
            (b['sortOrder'] as num?) ?? 0,
          ),
        );
    return _highlightListJson(items);
  }

  /// 按启用高亮规则匹配文本（Mock 版，语义对齐 Rust `highlight_rule_match`）
  ///
  /// 只用于 UI 开发与测试：字面量/正则 + 高 order 覆盖低 order + 截断。
  @override
  Future<String> highlightRuleMatch({
    required String text,
    String bookName = '',
    String origin = '',
    bool applyToTitle = false,
    int? maxMatches,
  }) async {
    final limit = maxMatches == null ? 10000 : maxMatches.clamp(0, 1 << 30).toInt();
    if (text.isEmpty || limit == 0) return '[]';
    final rules =
        _mockHighlightRules.values.where((r) {
          if (r['isEnabled'] != true) return false;
          final scopeRaw = r['scope'];
          final scope = scopeRaw is String ? scopeRaw : '';
          // 空 bookName/origin 不得命中任何非空 scope（对齐 Rust 空串守卫）
          if (scope.isNotEmpty &&
              !(bookName.isNotEmpty && scope.contains(bookName)) &&
              !(origin.isNotEmpty && scope.contains(origin))) {
            return false;
          }
          final side = applyToTitle
              ? r['applyToTitle'] == true
              : r['applyToBody'] != false;
          final pattern = (r['pattern'] as String?) ?? '';
          return side && pattern.isNotEmpty;
        }).toList()..sort((a, b) {
          final byOrder = ((a['sortOrder'] as num?) ?? 0).compareTo(
            (b['sortOrder'] as num?) ?? 0,
          );
          return byOrder != 0
              ? byOrder
              : ((a['id'] as num?) ?? 0).compareTo((b['id'] as num?) ?? 0);
        });

    final candidates = <_MockHighlightCandidate>[];
    var seq = 0;
    for (var ruleIndex = 0; ruleIndex < rules.length; ruleIndex++) {
      if (candidates.length >= limit) break;
      final rule = rules[ruleIndex];
      final pattern = rule['pattern'] as String;
      final order = (rule['sortOrder'] as num?)?.toInt() ?? 0;
      if (rule['isRegex'] == true) {
        RegExp regex;
        try {
          regex = RegExp(pattern);
        } catch (_) {
          continue; // 无效正则跳过（对齐 Rust warn 跳过）
        }
        for (final match in regex.allMatches(text)) {
          if (candidates.length >= limit) break;
          if (match.end <= match.start) continue;
          candidates.add(
            _MockHighlightCandidate(
              start: match.start,
              end: match.end,
              ruleIndex: ruleIndex,
              seq: seq++,
              order: order,
            ),
          );
        }
      } else {
        var from = 0;
        while (from <= text.length) {
          if (candidates.length >= limit) break;
          final start = text.indexOf(pattern, from);
          if (start < 0) break;
          final end = start + pattern.length;
          candidates.add(
            _MockHighlightCandidate(
              start: start,
              end: end,
              ruleIndex: ruleIndex,
              seq: seq++,
              order: order,
            ),
          );
          from = end;
        }
      }
    }
    if (candidates.isEmpty) return '[]';

    // 高 order 先占位；同 order 按收集顺序
    candidates.sort((a, b) {
      final byOrder = b.order.compareTo(a.order);
      return byOrder != 0 ? byOrder : a.seq.compareTo(b.seq);
    });
    final accepted = <_MockAccepted>[];
    for (final candidate in candidates) {
      var pieces = <(int, int)>[(candidate.start, candidate.end)];
      for (final acc in accepted) {
        if (pieces.isEmpty) break;
        final next = <(int, int)>[];
        for (final piece in pieces) {
          if (acc.end <= piece.$1 || acc.start >= piece.$2) {
            next.add(piece);
          } else {
            if (piece.$1 < acc.start) next.add((piece.$1, acc.start));
            if (acc.end < piece.$2) next.add((acc.end, piece.$2));
          }
        }
        pieces = next;
      }
      for (final piece in pieces) {
        accepted.add(
          _MockAccepted(
            start: piece.$1,
            end: piece.$2,
            ruleIndex: candidate.ruleIndex,
          ),
        );
      }
    }
    accepted.sort((a, b) {
      final byOrder = ((rules[a.ruleIndex]['sortOrder'] as num?) ?? 0)
          .toInt()
          .compareTo(((rules[b.ruleIndex]['sortOrder'] as num?) ?? 0).toInt());
      return byOrder != 0 ? byOrder : a.start.compareTo(b.start);
    });
    return jsonEncode([
      for (final item in accepted)
        {
          'ruleId': (rules[item.ruleIndex]['id'] as num?)?.toInt() ?? 0,
          'start': item.start,
          'end': item.end,
          'order': (rules[item.ruleIndex]['sortOrder'] as num?)?.toInt() ?? 0,
          'styleJson': (rules[item.ruleIndex]['style'] as String?) ?? '',
        },
    ]);
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

  // ========== 书签标记（book_marking Mock，契约 §2.52） ==========

  @override
  Future<List<BookMarking>> getBookMarkingsByBook(
    String bookName,
    String bookAuthor,
  ) async {
    final items = _mockBookMarkings.values
        .where((m) => m.bookName == bookName && m.bookAuthor == bookAuthor)
        .toList()
      ..sort((a, b) {
        final byChapter = _compareChapterIndex(a.chapterIndex, b.chapterIndex);
        if (byChapter != 0) return byChapter;
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
    return List.of(items);
  }

  @override
  Future<List<BookMarking>> getBookMarkingsForChapter(
    String bookUrl,
    int? chapterIndex,
  ) async {
    final items = _mockBookMarkings.values
        .where(
          (m) =>
              m.bookUrl == bookUrl &&
              (chapterIndex == null ||
                  m.chapterIndex == null ||
                  m.chapterIndex == chapterIndex),
        )
        .toList()
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
    return List.of(items);
  }

  @override
  Future<BookMarking> saveBookMarking(BookMarking marking) async {
    if (marking.anchorJson.trim().isEmpty) {
      throw const BridgeError(message: '书签标记 anchorJson 不能为空');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    var saved = marking;
    if (saved.id.trim().isEmpty) {
      saved = saved.copyWith(
        id: 'mock-marking-${_nextMockMarkingSeq++}-'
            '${DateTime.now().microsecondsSinceEpoch}',
      );
    }
    if (saved.createdAt <= 0) {
      saved = saved.copyWith(createdAt: now);
    }
    saved = saved.copyWith(updatedAt: now);
    _mockBookMarkings[saved.id] = saved;
    return saved;
  }

  @override
  Future<void> deleteBookMarking(String id) async {
    _mockBookMarkings.remove(id);
  }

  @override
  Future<void> setBookMarkingEnabled(String id, bool enabled) async {
    final current = _mockBookMarkings[id];
    if (current == null) return; // 不存在为 no-op
    _mockBookMarkings[id] = current.copyWith(
      enabled: enabled,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
