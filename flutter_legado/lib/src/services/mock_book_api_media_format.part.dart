// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiMediaFormat mixin：规则解析 / 网络 / JS 引擎 / 服务器 / 格式解析 / HTTP TTS / 音频播放。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiMediaFormat on MockBookApiStore implements BookApi {
  // ========== 规则解析 ==========

  @override
  Future<String> parseRule(
    String content,
    String rule,
    String ruleType,
  ) async => content;

  // ========== 网络操作 ==========

  @override
  Future<String> httpGet(String url) async =>
      '{"status":200,"body":"","url":"$url"}';

  @override
  Future<String> httpGetBytes(String url, {String headersJson = ''}) async =>
      '{"status":200,"bodyBase64":"","url":"$url"}';

  @override
  Future<String> httpPost(String url, String body) async =>
      '{"status": "ok", "mock": true}';

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async =>
      '{"base64": "", "len": 0}';

  // ========== JS 引擎 ==========

  @override
  Future<String> evalJs(String script) async => 'undefined';

  @override
  Future<String> getJsEngineVersion() async => 'mock-quickjs';

  // ========== 服务器管理 ==========

  @override
  Future<void> startServer({int port = 1122}) async {
    _configs['server_port'] = port.toString();
    _configs['server_running'] = 'true';
  }

  @override
  Future<void> stopServer() async {
    _configs['server_running'] = 'false';
  }

  @override
  Future<String> getServerStatus() async {
    if (_configs['server_running'] == 'true') {
      return 'running on port ${_configs['server_port'] ?? '1122'}';
    }
    return 'stopped';
  }

  @override
  Future<void> setServerPort(int port) async {
    _configs['server_port'] = port.toString();
  }

  /// 设置自定义 hosts（契约 §2.20.3，Task #74）
  ///
  /// Mock：短延迟成功，持久化到 _configs 供 getConfig 回读；
  /// 非空且非法 JSON 对象模拟抛错（对齐 Rust Internal 语义）。
  @override
  Future<void> setCustomHosts(String hostsJson) async {
    await Future.delayed(const Duration(milliseconds: 50));
    final trimmed = hostsJson.trim();
    if (trimmed.isNotEmpty) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is! Map) {
          throw Exception('customHosts 必须为 JSON 对象');
        }
      } on FormatException {
        throw Exception('customHosts 非法 JSON');
      }
    }
    _configs['customHosts'] = hostsJson;
  }

  /// 设置独立 MCP 端口（契约 §2.22.5，Task #74）
  ///
  /// Mock：短延迟成功；port>0 且越界（1024..65530）模拟抛错。
  @override
  Future<void> setMcpPort(int port) async {
    await Future.delayed(const Duration(milliseconds: 50));
    if (port > 0 && (port < 1024 || port > 65530)) {
      throw Exception('MCP 端口 $port 越界：合法区间为 1024..65530');
    }
    _configs['mcpPort'] = port.toString();
  }

  /// 封面规则测试搜索（契约 §2.4.8，Task #74）
  ///
  /// Mock：短延迟后返回 1-2 个示例 URL。
  @override
  Future<List<String>> searchCoverRules(String name) async {
    await Future.delayed(const Duration(milliseconds: 80));
    final encoded = Uri.encodeComponent(name);
    return [
      'https://mock.cover.example/$encoded/cover_1.jpg',
      'https://mock.cover.example/$encoded/cover_2.jpg',
    ];
  }

  Map<String, dynamic> _mockCoverRule = {
    'enable': true,
    'searchUrl': 'https://mock.cover.example/search?q={{key}}',
    'coverRule': '\$.cover',
  };

  @override
  Future<Map<String, dynamic>> getCoverRule() async {
    await Future.delayed(const Duration(milliseconds: 20));
    return Map<String, dynamic>.from(_mockCoverRule);
  }

  @override
  Future<bool> saveCoverRule(Map<String, dynamic> rule) async {
    await Future.delayed(const Duration(milliseconds: 20));
    _mockCoverRule = Map<String, dynamic>.from(rule);
    return true;
  }

  @override
  Future<bool> deleteCoverRule() async {
    await Future.delayed(const Duration(milliseconds: 20));
    _mockCoverRule = {
      'enable': true,
      'searchUrl': 'https://mock.cover.example/search?q={{key}}',
      'coverRule': '\$.cover',
    };
    return true;
  }

  // ========== 书籍格式解析 ==========

  @override
  Future<List<BookChapter>> parseTxt(String filePath) async {
    return List.generate(
      5,
      (i) => BookChapter(
        title: '第${i + 1}章',
        bookUrl: filePath,
        index: i,
        start: i * 1000,
        end: (i + 1) * 1000,
      ),
    );
  }

  @override
  Future<List<BookChapter>> parseEpub(String filePath) async {
    return List.generate(
      8,
      (i) => BookChapter(
        title: 'Chapter ${i + 1}',
        bookUrl: filePath,
        index: i,
        start: i * 2000,
        end: (i + 1) * 2000,
      ),
    );
  }

  @override
  Future<String> exportBook(
    String bookUrl,
    String format,
    String outDir,
  ) async {
    return '$outDir/export_mock.$format';
  }

  @override
  Future<void> recordReadingTime(String bookName, int seconds) async {}

  // ========== HTTP TTS ==========

  @override
  Future<List<HttpTts>> getHttpTts() async => List.from(_httpTtsList);

  @override
  Future<List<HttpTts>> getHttpTtsList() async => getHttpTts();

  @override
  Future<HttpTts> addHttpTts(HttpTts tts) async {
    final t = tts.copyWith(id: _nextId++);
    _httpTtsList.add(t);
    return t;
  }

  @override
  Future<void> updateHttpTts(HttpTts tts) async {
    final idx = _httpTtsList.indexWhere((t) => t.id == tts.id);
    if (idx >= 0) _httpTtsList[idx] = tts;
  }

  @override
  Future<void> deleteHttpTts(int id) async {
    _httpTtsList.removeWhere((t) => t.id == id);
  }

  @override
  Future<int> importHttpTts(String json) async {
    final list = jsonDecode(json) as List<dynamic>;
    return list.length;
  }

  @override
  Future<String> exportHttpTts() async =>
      jsonEncode(_httpTtsList.map((t) => t.toJson()).toList());

  @override
  Future<bool> httpTtsSetEnabled(int id, bool enabled) async => true;

  // ========== 音频播放 ==========

  @override
  Future<void> audioSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceName,
  }) async {}

  @override
  Future<Map<String, dynamic>> ttsSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
  }) async => {
    'audioPath': '',
    'fromCache': false,
    'contentType': 'audio/mpeg',
  };

  @override
  Future<bool> ttsSetCacheDir(String path) async => true;

  @override
  Future<Map<String, dynamic>> getAudioChapterMedia(
    String bookUrl,
    int chapterIndex,
  ) async {
    final chapters = await getChapters(bookUrl);
    if (chapterIndex < 0 || chapterIndex >= chapters.length) {
      return {'error': 'Invalid chapter index'};
    }
    final chapter = chapters[chapterIndex];
    final isVolume = chapter.isVolume;
    // Mock：直链章 URL 即 mediaUrl（对齐正文规则为空回退）
    final mediaUrl = isVolume
        ? ''
        : ((chapter.resourceUrl?.trim().isNotEmpty ?? false)
              ? chapter.resourceUrl!.trim()
              : chapter.url.trim());
    return {
      'chapterIndex': chapterIndex,
      'title': chapter.title,
      'mediaUrl': mediaUrl,
      'url': chapter.url,
      'resourceUrl': chapter.resourceUrl,
      'isVolume': isVolume,
      'fromCache': false,
      'sourceUrl': '',
    };
  }

  @override
  Future<Map<String, dynamic>?> getAudioProgress(
    String bookUrl,
    int chapterIndex,
  ) async {
    return {'position': 0, 'chapterIndex': chapterIndex};
  }

  @override
  Future<void> saveAudioProgress(
    String bookUrl,
    int chapterIndex,
    int positionMs,
  ) async {}
}
