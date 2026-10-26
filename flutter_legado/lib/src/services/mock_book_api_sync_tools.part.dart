// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiSyncTools mixin：WebDAV / 下载管理 / 段评 / 书籍导出 / 自动任务。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiSyncTools on MockBookApiStore implements BookApi {
  // ========== WebDAV 云同步 ==========

  @override
  Future<String> webdavListDir(String configJson, String path) async =>
      jsonEncode([]);

  @override
  Future<void> webdavUpload(
    String configJson,
    String path,
    String data,
  ) async {}

  /// WebDAV 本地文件上传（契约 §2.28.6，Task #50）
  ///
  /// Mock：短延迟模拟上传耗时，不做真实网络请求。
  @override
  Future<void> webdavUploadFile(
    String configJson,
    String path,
    String localFilePath,
  ) async {
    await Future.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<String> webdavDownload(String configJson, String path) async => '';

  /// WebDAV 二进制下载到本地（契约 §2.28，2026-08-12 P1-5）
  @override
  Future<void> webdavDownloadFile(
    String configJson,
    String path,
    String localFilePath,
  ) async {
    await Future.delayed(const Duration(milliseconds: 50));
  }

  @override
  Future<void> webdavDelete(String configJson, String path) async {}

  @override
  Future<String> webdavFullSync(
    String configJson,
    String localBooks,
    String localSources,
  ) async => '{"synced": true}';

  /// 列出 servers 表全部服务器（契约 §2.28，批8）
  ///
  /// Mock：内存列表，按 sortNumber 升序、同值按 id 升序（对齐原版
  /// `ServerDao.all` 的 order by sortNumber）。
  @override
  Future<String> webdavServersList() async {
    final sorted = [..._servers]..sort((a, b) {
      final bySort = ((a['sortNumber'] as num?)?.toInt() ?? 0)
          .compareTo((b['sortNumber'] as num?)?.toInt() ?? 0);
      if (bySort != 0) return bySort;
      return ((a['id'] as num?)?.toInt() ?? 0)
          .compareTo((b['id'] as num?)?.toInt() ?? 0);
    });
    return jsonEncode(sorted);
  }

  /// 保存服务器配置（契约 §2.28，批8）
  ///
  /// Mock：REPLACE by id；id 为 0 时分配当前毫秒（避让既有主键），
  /// 负数 id 原样保留（-1 = 默认 WebDAV）。
  @override
  Future<int> webdavServerSave(String serverJson) async {
    final decoded = jsonDecode(serverJson);
    if (decoded is! Map) {
      throw const FormatException('serverJson 必须为 JSON 对象');
    }
    final map = Map<String, dynamic>.from(decoded);
    var id = (map['id'] as num?)?.toInt() ?? 0;
    if (id == 0) {
      id = DateTime.now().millisecondsSinceEpoch;
      while (_servers.any((e) => (e['id'] as num?)?.toInt() == id)) {
        id++;
      }
    }
    map['id'] = id;
    map.putIfAbsent('name', () => '');
    map.putIfAbsent('type', () => 'WEBDAV');
    map.putIfAbsent('sortNumber', () => 0);
    final idx = _servers.indexWhere((e) => (e['id'] as num?)?.toInt() == id);
    if (idx >= 0) {
      _servers[idx] = map;
    } else {
      _servers.add(map);
    }
    return id;
  }

  /// 删除服务器配置（契约 §2.28，批8）；未命中返回 false
  @override
  Future<bool> webdavServerDelete(int id) async {
    final before = _servers.length;
    _servers.removeWhere((e) => (e['id'] as num?)?.toInt() == id);
    return _servers.length < before;
  }

  // ========== 下载管理器 ==========

  @override
  Future<String> downloadAddTask({
    required String bookUrl,
    required String chapterUrl,
    required String chapterTitle,
    required int chapterIndex,
    int priority = 0,
  }) async => 'mock-task-${_nextId++}';

  @override
  Future<String> downloadGetStats() async =>
      jsonEncode({'total': 0, 'completed': 0, 'failed': 0, 'pending': 0});

  @override
  Future<String> downloadListByBook(String bookUrl) async => jsonEncode([]);

  @override
  Future<void> downloadPauseAll() async {}

  @override
  Future<void> downloadResumeAll() async {}

  @override
  Future<void> downloadRemoveTask(String taskId) async {}

  @override
  Future<void> downloadUpdateProgress(String taskId, double progress) async {}

  // ========== 段评（书源 ruleReview）==========

  @override
  Future<String> reviewGetSummary(String sourceJson, String requestJson) async {
    return jsonEncode({
      'counts': {'1': 3, '2': 1},
      'keys': {'1': 'mock-para-1', '2': 'mock-para-2'},
    });
  }

  @override
  Future<String> reviewGetDetail(
    String sourceJson,
    String requestJson,
    int page,
  ) async {
    return jsonEncode({
      'items': [
        {
          'id': 'mock_detail_$page-1',
          'name': '读者甲',
          'content': 'Mock 段评内容一（第$page 页）',
          'badges': <String>['作者'],
          'time': '刚刚',
          'replyCount': 2,
          'replies': <Map<String, dynamic>>[],
        },
        {
          'id': 'mock_detail_$page-2',
          'name': '读者乙',
          'content': 'Mock 段评内容二（第$page 页）',
          'badges': <String>[],
          'replyCount': 0,
          'replies': <Map<String, dynamic>>[],
        },
      ],
      'nextPageUrl': page < 2 ? 'mock://next' : null,
      'hasReplyUrl': true,
    });
  }

  @override
  Future<String> reviewGetReplies(
    String sourceJson,
    String requestJson,
    int page,
  ) async {
    // Mock 返回两条示例回复，便于 UI 轨联调段评回复弹窗
    return jsonEncode({
      'items': [
        {
          'id': 'mock_reply_$page-1',
          'name': '读者甲',
          'content': 'Mock 回复内容一（第$page 页）',
          'badges': <String>['沙发'],
          'time': '刚刚',
        },
        {
          'id': 'mock_reply_$page-2',
          'name': '读者乙',
          'content': 'Mock 回复内容二（第$page 页）',
          'badges': <String>[],
        },
      ],
      'nextPageUrl': null,
    });
  }

  // ========== 书籍导出 ==========

  @override
  Future<Map<String, dynamic>> bookExport({
    required String bookUrl,
    required String format,
    required bool includeToc,
  }) async {
    final book = await getBook(bookUrl);
    if (book == null) {
      return {'success': false, 'error': '书籍不存在: $bookUrl'};
    }
    return {
      'success': true,
      'file_name': '${book.name}.$format',
      'data_base64': base64Encode(utf8.encode('Mock 导出内容')),
      'mime_type': 'text/plain',
    };
  }

  @override
  Future<Map<String, dynamic>> bookExportWithOptions({
    required String bookUrl,
    required String format,
    required bool includeToc,
    String optionsJson = '',
  }) async {
    return bookExport(bookUrl: bookUrl, format: format, includeToc: includeToc);
  }

  @override
  Future<Map<String, dynamic>> bookExportInfo({
    required String bookUrl,
    required String format,
  }) async {
    final book = await getBook(bookUrl);
    if (book == null) {
      return {'success': false, 'error': '书籍不存在: $bookUrl'};
    }
    final chapters = await getChapters(bookUrl);
    return {
      'success': true,
      'file_name': '${book.name}.$format',
      'chapter_count': chapters.length.toString(),
    };
  }

  /// 直链上传（契约 §2.51，批16a）
  ///
  /// Mock：不发网络请求，按上传语义构造可验证的直链（文件名 + 标记 +
  /// 压缩后缀），便于 UI 流程测试；规则非法（上传 URL/下载规则为空、
  /// content/filePath 非二选一）抛 [ArgumentError] 对齐 Rust 错误语义。
  @override
  Future<String> directLinkUpload({
    required String ruleJson,
    required String fileName,
    required String contentType,
    String? content,
    String? filePath,
  }) async {
    final rule = jsonDecode(ruleJson);
    if (rule is! Map) {
      throw ArgumentError('直链上传规则 JSON 形态非法');
    }
    final uploadUrl = (rule['uploadUrl'] ?? rule['upload_url'] ?? '')
        .toString()
        .trim();
    final downloadRule =
        (rule['downloadUrlRule'] ?? rule['download_url_rule'] ?? '')
            .toString()
            .trim();
    if (uploadUrl.isEmpty) throw StateError('上传 URL 未配置');
    if (downloadRule.isEmpty) throw StateError('下载链接规则未配置');
    if ((content == null) == (filePath == null)) {
      throw ArgumentError('content 与 filePath 必须二选一');
    }
    // 对齐 Rust 载荷校验（§2.51）：空路径与 content 超限明确报错
    if (filePath != null && filePath.trim().isEmpty) {
      throw StateError('上传文件路径为空');
    }
    const maxUploadBytes = 100 * 1024 * 1024;
    if (content != null && content.length > maxUploadBytes) {
      throw StateError('上传内容超过上传上限（100 MiB）');
    }
    final compress = rule['compress'] == true && contentType != 'application/zip';
    final uploadName = compress ? '$fileName.zip' : fileName;
    final source = content ?? filePath!;
    return 'https://mock.direct-link.local/$uploadName'
        '?rule=${Uri.encodeComponent(downloadRule)}'
        '&size=${source.length}';
  }

  // ========== 自动任务 ==========

  @override
  Future<Map<String, dynamic>> autoTaskBuildBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
    required String name,
  }) async => {
    'id': 'mock-task-${_nextId++}',
    'name': name,
    'bookUrl': bookUrl,
    'bookName': bookName,
    'bookAuthor': bookAuthor,
    'cron': '0 0 8 * * *',
    'enabled': true,
  };

  @override
  Future<List<Map<String, dynamic>>> autoTaskUpdateCronBatch({
    required String rulesJson,
    required String idsJson,
    required String cron,
  }) async {
    final rules = (jsonDecode(rulesJson) as List<dynamic>)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final ids = (jsonDecode(idsJson) as List<dynamic>)
        .map((e) => e.toString())
        .toList();
    for (final rule in rules) {
      if (ids.contains(rule['id']?.toString())) {
        rule['cron'] = cron;
      }
    }
    return rules;
  }

  @override
  Future<List<Map<String, dynamic>>> autoTaskPrepareImported({
    required String localTasksJson,
    required String importedJson,
  }) async {
    final imported = (jsonDecode(importedJson) as List<dynamic>)
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    return imported;
  }

  @override
  Future<Map<String, dynamic>> autoTaskExecute({
    required String protocolJson,
  }) async => {'success': true, 'message': 'Mock 执行成功'};

  @override
  Future<Map<String, dynamic>> autoTaskExecuteWithId({
    required String protocolJson,
    required String taskId,
  }) async => {'success': true, 'taskId': taskId, 'message': 'Mock 执行成功'};

  @override
  Future<String> autoTaskNormalizeScript({required String script}) async {
    if (script.startsWith('@js:')) return script.substring(4);
    return script;
  }

  @override
  Future<bool> autoTaskCanRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  }) async {
    if (!respectCanUpdate) return true;
    return canUpdate;
  }

  @override
  Future<Map<String, dynamic>?> autoTaskFindBookUpdateTask({
    required String tasksJson,
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
  }) async => null;

  @override
  Future<int> autoTaskNextDueAt({
    required String cron,
    required int fromMs,
  }) async => fromMs + 86400000; // +24h

  // ========== 自动任务数据库 CRUD ==========

  final List<Map<String, dynamic>> _mockAutoTaskRules = [];

  @override
  Future<List<Map<String, dynamic>>> autoTaskListRules() async =>
      List.from(_mockAutoTaskRules);

  @override
  Future<String> autoTaskCreateRule({required String ruleJson}) async {
    final rule = jsonDecode(ruleJson) as Map<String, dynamic>;
    final id = rule['id']?.toString() ?? 'mock-task-${_nextId++}';
    rule['id'] = id;
    _mockAutoTaskRules.add(rule);
    return id;
  }

  @override
  Future<void> autoTaskUpdateRule({required String ruleJson}) async {
    final rule = jsonDecode(ruleJson) as Map<String, dynamic>;
    final id = rule['id']?.toString();
    if (id != null) {
      final index = _mockAutoTaskRules.indexWhere((r) => r['id'] == id);
      if (index >= 0) {
        _mockAutoTaskRules[index] = rule;
      }
    }
  }

  @override
  Future<void> autoTaskDeleteRule({required String id}) async {
    _mockAutoTaskRules.removeWhere((r) => r['id'] == id);
  }

  @override
  Future<Map<String, dynamic>?> autoTaskFindRuleById({
    required String id,
  }) async {
    try {
      return _mockAutoTaskRules.firstWhere((r) => r['id'] == id);
    } catch (_) {
      return null;
    }
  }
}
