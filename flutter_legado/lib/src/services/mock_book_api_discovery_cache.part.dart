// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiDiscoveryCache mixin：RSS 收藏 / 分组 / 搜索历史 / 缓存 / 章节购买 / WebBook / 发现页。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiDiscoveryCache on MockBookApiStore implements BookApi {
  // ========== RSS 收藏操作 ==========

  @override
  Future<List<RssStar>> getRssStars() async => List.from(_rssStars);

  @override
  Future<RssStar> addRssStar(RssStar star) async {
    _rssStars.add(star);
    return star;
  }

  @override
  Future<void> deleteRssStar(String link) async {
    _rssStars.removeWhere((s) => s.link == link);
  }

  @override
  Future<bool> isStarred(String link) async =>
      _rssStars.any((s) => s.link == link);

  // ========== 书籍分组 ==========

  @override
  Future<List<BookGroup>> getBookGroups() async => List.from(_bookGroups);

  @override
  Future<BookGroup> addBookGroup(BookGroup group) async {
    // [审查] Mock 分组 ID 同样必须是 2^n，跳过已占用位
    while (_bookGroups.any((g) => g.groupId == _nextGroupBit)) {
      _nextGroupBit <<= 1;
    }
    // 与 Rust add_book_group 一致：新建分组固定非私密（isPrivate 只能经
    // setBookGroupPrivate 单独设置）
    final g = group.copyWith(groupId: _nextGroupBit, isPrivate: false);
    _nextGroupBit <<= 1;
    _bookGroups.add(g);
    return g;
  }

  @override
  Future<void> updateBookGroup(BookGroup group) async {
    final idx = _bookGroups.indexWhere((g) => g.groupId == group.groupId);
    // 与 Rust update_book_group 一致：只更新 name/cover/order，私密标记
    // 保留库内旧值，不得被陈旧快照的 isPrivate=false 清除
    if (idx >= 0) {
      _bookGroups[idx] = group.copyWith(isPrivate: _bookGroups[idx].isPrivate);
    }
  }

  @override
  Future<void> deleteBookGroup(int groupId) async {
    _bookGroups.removeWhere((g) => g.groupId == groupId);
    // [审查 P1] 与 Rust 同语义：删除分组同时清 books.group 对应位/exact
    const maxMask = (1 << 31) - 1;
    final isBit =
        groupId > 0 && groupId <= (1 << 30) && (groupId & (groupId - 1)) == 0;
    for (var i = 0; i < _books.length; i++) {
      final book = _books[i];
      if (isBit) {
        if (book.group > 0 && book.group <= maxMask) {
          _books[i] = book.copyWith(group: book.group & ~groupId);
        }
      } else if (groupId > 0 && book.group == groupId) {
        _books[i] = book.copyWith(group: 0);
      }
    }
  }

  @override
  Future<bool> bookGroupSetShow(int groupId, bool show) async => true;

  // ========== 隐私与私密标记（契约 §2.53，批9a） ==========
  //
  // Mock 仅用于开发联调：凭据用**加盐 SHA-256** 模拟，不是生产安全实现
  // （生产走 Rust PBKDF2-HMAC-SHA256 210000 次）。

  static const int _mockMaxPasswordChars = 128;

  String _mockPasswordHash(String salt, String password) =>
      sha256.convert(utf8.encode('$salt:$password')).toString();

  @override
  Future<bool> privacyHasPassword() async =>
      _mockPasswordSalt != null && _mockPasswordDigest != null;

  @override
  Future<bool> privacySetPassword(
    String password, {
    String? oldPassword,
  }) async {
    final trimmed = password.trim();
    if (trimmed.isEmpty || trimmed.runes.length > _mockMaxPasswordChars) {
      return false;
    }
    final hasExisting =
        _mockPasswordSalt != null && _mockPasswordDigest != null;
    if (hasExisting) {
      final old = oldPassword;
      if (old == null ||
          _mockPasswordHash(_mockPasswordSalt!, old) != _mockPasswordDigest) {
        return false;
      }
    }
    final random = Random.secure();
    final salt = base64Encode(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    _mockPasswordSalt = salt;
    _mockPasswordDigest = _mockPasswordHash(salt, password);
    // 与 Rust 同语义：改密即失效生物快捷
    _clearMockBiometric();
    return true;
  }

  @override
  Future<bool> privacyVerifyPassword(String password) async {
    if (password.isEmpty) return false;
    final salt = _mockPasswordSalt;
    final digest = _mockPasswordDigest;
    if (salt == null || digest == null) return false;
    return _mockPasswordHash(salt, password) == digest;
  }

  @override
  Future<void> privacyClearPassword() async {
    _mockPasswordSalt = null;
    _mockPasswordDigest = null;
    _clearMockBiometric();
  }

  @override
  Future<int> setBooksPrivate(List<String> bookUrls, bool isPrivate) async {
    await _ensureBooksLoaded();
    final targets = bookUrls.toSet();
    var affected = 0;
    for (var i = 0; i < _books.length; i++) {
      if (!targets.contains(_books[i].bookUrl)) continue;
      affected++;
      _books[i] = _books[i].copyWith(isPrivate: isPrivate);
    }
    return affected;
  }

  @override
  Future<List<String>> getPrivateBookUrls() async {
    await _ensureBooksLoaded();
    final urls = _books.where((b) => b.isPrivate).map((b) => b.bookUrl).toList()
      ..sort();
    return urls;
  }

  @override
  Future<bool> setBookGroupPrivate(int groupId, bool isPrivate) async {
    final idx = _bookGroups.indexWhere((g) => g.groupId == groupId);
    if (idx < 0) return false;
    _bookGroups[idx] = _bookGroups[idx].copyWith(isPrivate: isPrivate);
    return true;
  }

  @override
  Future<List<int>> getPrivateGroupIds() async {
    final ids =
        _bookGroups.where((g) => g.isPrivate).map((g) => g.groupId).toList()
          ..sort();
    return ids;
  }

  // ========== 生物识别快捷解锁（契约 §2.53，批9d） ==========

  void _clearMockBiometric() {
    _mockBiometricTokenHash = null;
    _mockBiometricEnvelope = null;
    _mockBiometricIv = null;
  }

  /// 严格 Base64 解码并要求长度恰为 [expected]（失败 null）
  List<int>? _mockDecodeExact(String value, int expected) {
    try {
      final bytes = base64Decode(value);
      return bytes.length == expected ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<String> privacyBiometricStateGet() async {
    final configured =
        _mockBiometricTokenHash != null &&
        _mockBiometricEnvelope != null &&
        _mockBiometricIv != null &&
        _mockDecodeExact(_mockBiometricTokenHash!, 32) != null;
    return jsonEncode({
      'configured': configured,
      'envelope': configured ? _mockBiometricEnvelope : null,
      'iv': configured ? _mockBiometricIv : null,
    });
  }

  @override
  Future<bool> privacyBiometricSet(
    String token,
    String envelope,
    String iv,
  ) async {
    final tokenBytes = _mockDecodeExact(token, 32);
    final ivBytes = _mockDecodeExact(iv, 12);
    List<int>? envelopeBytes;
    try {
      final decoded = base64Decode(envelope);
      if (decoded.isNotEmpty && decoded.length <= 4096) {
        envelopeBytes = decoded;
      }
    } on FormatException {
      envelopeBytes = null;
    }
    if (tokenBytes == null || ivBytes == null || envelopeBytes == null) {
      return false;
    }
    // 与 Rust 同语义：必须已有隐私密码
    if (_mockPasswordSalt == null || _mockPasswordDigest == null) {
      return false;
    }
    _mockBiometricTokenHash = base64Encode(sha256.convert(tokenBytes).bytes);
    _mockBiometricEnvelope = base64Encode(envelopeBytes);
    _mockBiometricIv = base64Encode(ivBytes);
    return true;
  }

  @override
  Future<bool> privacyBiometricVerify(String token) async {
    final tokenBytes = _mockDecodeExact(token, 32);
    final stored = _mockBiometricTokenHash;
    if (tokenBytes == null || stored == null) return false;
    final expected = _mockDecodeExact(stored, 32);
    if (expected == null) return false;
    final actual = sha256.convert(tokenBytes).bytes;
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    return diff == 0;
  }

  @override
  Future<void> privacyBiometricClear() async => _clearMockBiometric();

  // ========== 搜索历史 ==========

  @override
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50}) async =>
      _searchHistory.take(limit).toList();

  @override
  Future<List<String>> searchHistoryByPrefix(
    String prefix, {
    int limit = 20,
  }) async {
    return _searchHistory
        .where((k) => k.word.startsWith(prefix))
        .take(limit)
        .map((k) => k.word)
        .toList();
  }

  @override
  Future<void> addSearchKeyword(String keyword, String bookName) async {
    _searchHistory.insert(0, SearchKeyword(word: keyword));
  }

  @override
  Future<void> deleteSearchKeyword(String keyword) async {
    _searchHistory.removeWhere((k) => k.word == keyword);
  }

  @override
  Future<void> clearSearchHistory() async {
    _searchHistory.clear();
  }

  /// Mock 无 searchBooks 表：no-op 返回 0（契约 §2.15 批9b-1；
  /// 启动接线 USE_MOCK 模式不调用，本实现仅保接口完备）
  @override
  Future<int> clearExpiredSearchBooks(int beforeTimestampMs) async => 0;

  // ========== 缓存管理 ==========

  @override
  Future<int> getCacheSize() async => 1024 * 1024 * 50; // 50MB

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> clearBookCache(String bookUrl) async => 0;

  /// Mock 无缓存存储：no-op 返回 0（对齐 clearBookCache 的 Mock 语义）
  @override
  Future<int> clearChapterCache(String bookUrl, int chapterIndex) async => 0;

  @override
  Future<int> getCacheBookCount() async => 3;

  @override
  Future<int> getCacheChapterCount() async => 30;

  @override
  Future<void> clearCacheBefore(int beforeTimestampMs) async {}

  /// 压缩数据库（契约 §2.16.6，Task #50）
  ///
  /// Mock：短延迟模拟 VACUUM 耗时，固定返回 10MB 释放量。
  @override
  Future<int> shrinkDatabase() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return 10 * 1024 * 1024;
  }

  @override
  Future<String> getCachedChapter(String bookUrl, int chapterIndex) async =>
      '（mock 缓存正文：$bookUrl 第 $chapterIndex 章）';

  // [UI-fix v2.0.6 | 2026-08-08] Task #22：mock 返回空集（目录页云图标均未缓存态） — Qoder
  @override
  Future<List<String>> listCachedChapterUrls(String bookUrl) async =>
      const <String>[];

  // [P2-28c | 2026-09-28] mock 返回空映射（无实时字数刷新数据）
  @override
  Future<Map<String, String>> listCachedChapters(String bookUrl) async =>
      const <String, String>{};

  @override
  Future<int> cacheDownloadStart(
    String bookUrl,
    int startChapter,
    int endChapter,
  ) async => 1;

  @override
  Future<String> cacheDownloadProgress(int taskId) async =>
      '{"taskId":$taskId,"status":"completed","total":0,"completed":0,"failed":0}';

  @override
  Future<bool> cacheDownloadCancel(int taskId) async => true;

  @override
  Future<String> cacheDownloadList() async => '[]';

  // [P2-29 | 2026-09-29] mock 无活跃批量下载任务（在途章集合恒空）
  @override
  Future<List<int>> listDownloadingChapters(String bookUrl) async =>
      const <int>[];

  // [P2-29c 后续 | 2026-10-05] mock 无批量下载失败记录（失败章集合恒空，
  // 契约 §2.43.8 cacheDownloadFailedChapters）
  @override
  Future<List<int>> listFailedChapters(String bookUrl) async => const <int>[];

  // ========== 图片磁盘缓存（契约 §2.46，Mock 以内存 Map 模拟落盘） ==========

  /// [P4-2a | 2026-09-29] mock 图片磁盘缓存写侧：存入内存 Map（模拟 Rust
  /// MD5 文件落盘），恒返回 true（对齐 Rust 侧写成功语义）。
  @override
  Future<bool> saveImageCache({
    required String bookUrl,
    required String url,
    required List<int> bytes,
  }) async {
    _imageCache['$bookUrl\u0000$url'] = List<int>.of(bytes);
    return true;
  }

  /// [P4-2a | 2026-09-29] mock 图片磁盘缓存读侧：命中返回字节副本，
  /// 未命中返回 null（对齐 Rust 侧本地优先语义）。
  @override
  Future<List<int>?> getImageCache(String bookUrl, String url) async {
    final hit = _imageCache['$bookUrl\u0000$url'];
    return hit == null ? null : List<int>.of(hit);
  }

  /// [批9b-3 | 2026-11-03] mock 漫画图片保留清理：内存索引不含章节正文，
  /// 无法还原 Rust 侧窗口判定，恒返回 0（不清理；真实语义由 Rust 单测/
  /// 端到端测试覆盖，契约 §2.46）。
  @override
  Future<int> retainComicImages({
    required String bookUrl,
    required int durIndex,
    required int retain,
    required int preDownload,
  }) async => 0;

  // ========== 音频章节文件缓存（契约 §2.47 读面 + §2.48 写入面，Mock 内存态） ==========

  /// mock 音频缓存（bookUrl → 章节下标集合；仅会话内存态，不落盘）
  final Map<String, Set<int>> _audioCacheIndexes = {};

  /// mock 已缓存章节的 playUrl（.complete 标记内地址的等价物）
  final Map<String, Map<int, String>> _audioCachePlayUrls = {};

  /// [B1 | 2026-10-04] mock 音频缓存查询：按内存态判定（无缓存 → false，
  /// 播放链回落在线取流）。键以章节下标简化（真实键规则在 Rust 侧）。
  @override
  Future<bool> audioCacheQuery({
    required String bookUrl,
    required int chapterIndex,
    required String chapterUrl,
    required String chapterTitle,
  }) async => _audioCacheIndexes[bookUrl]?.contains(chapterIndex) ?? false;

  /// [B1 | 2026-10-04] mock 音频缓存列举：内存态已缓存章节下标升序。
  @override
  Future<List<int>> audioCacheList({required String bookUrl}) async =>
      (_audioCacheIndexes[bookUrl]?.toList() ?? <int>[])..sort();

  /// [B1 | 2026-10-04] mock 音频单章清理：返回删除数据文件数（0/1，幂等）。
  @override
  Future<int> audioCacheClearChapter({
    required String bookUrl,
    required int chapterIndex,
    required String chapterUrl,
    required String chapterTitle,
  }) async {
    final indexes = _audioCacheIndexes[bookUrl];
    final removed = indexes?.remove(chapterIndex) ?? false;
    _audioCachePlayUrls[bookUrl]?.remove(chapterIndex);
    return removed ? 1 : 0;
  }

  /// [B1 | 2026-10-04] mock 音频整书清理：返回删除数据文件数（幂等）。
  @override
  Future<int> audioCacheClearBook({required String bookUrl}) async {
    final count = _audioCacheIndexes.remove(bookUrl)?.length ?? 0;
    _audioCachePlayUrls.remove(bookUrl);
    return count;
  }

  /// [B2 | 2026-10-03] mock 单章预下载：内存态记录（已缓存 → already_cached；
  /// 否则 installed），JSON 形状与 Rust 侧一致。mock 无网络/无字节。
  @override
  Future<String> audioCacheDownload({
    required String bookUrl,
    required int chapterIndex,
    required String chapterUrl,
    required String chapterTitle,
    required String playUrl,
  }) async {
    final indexes = _audioCacheIndexes.putIfAbsent(bookUrl, () => <int>{});
    final playUrls = _audioCachePlayUrls.putIfAbsent(
      bookUrl,
      () => <int, String>{},
    );
    if (indexes.contains(chapterIndex)) {
      return jsonEncode({
        'status': 'already_cached',
        'path': '',
        'sizeBytes': 0,
        'extension': _mockExtension(playUrl),
      });
    }
    indexes.add(chapterIndex);
    playUrls[chapterIndex] = playUrl;
    return jsonEncode({
      'status': 'installed',
      'path': '',
      'sizeBytes': 0,
      'extension': _mockExtension(playUrl),
    });
  }

  /// [B2 | 2026-10-03] mock 取消：无在途下载 → false（同步语义等价）。
  @override
  Future<bool> audioCacheCancel() async => false;

  // ========== 视频弹幕（契约 §2.49，V-B1） ==========

  /// mock 查询：默认无弹幕 → null（对齐 Rust 侧「无记录降级 null」语义）
  @override
  Future<String?> getVideoDanmaku({
    required String bookUrl,
    required int chapterIndex,
  }) async => null;

  /// mock 解析：返回 null（无 Rust 纯函数，UI 降级为无弹幕；
  /// 弹幕渲染层由 widget 测试注入假 API 验证，不在 mock 复制业务逻辑）
  @override
  Future<List<VideoDanmakuItem>?> parseVideoDanmaku({
    required String raw,
  }) async => null;

  /// mock 扩展名探测（对齐原版三级探测的 URL 后缀分支，仅用于 JSON 形状）
  static String _mockExtension(String playUrl) {
    final path = playUrl.split('?').first.split('#').first;
    final dot = path.lastIndexOf('.');
    if (dot >= 0) {
      final ext = path.substring(dot + 1).toLowerCase();
      const whitelist = {
        'mp3',
        'm4a',
        'm4b',
        'aac',
        'ogg',
        'oga',
        'opus',
        'wav',
        'flac',
        'webm',
        'amr',
        '3gp',
      };
      if (whitelist.contains(ext)) return ext;
    }
    return 'audio';
  }

  // ========== 章节购买 ==========

  @override
  Future<({String kind, String value})> chapterPayAction({
    required String bookUrl,
    required int chapterIndex,
  }) async => (kind: 'none', value: '');

  @override
  Future<Map<String, dynamic>> sourceCallBackBtn({
    required String event,
    required String bookUrl,
    int? chapterIndex,
    String? result,
    int bookType = 0,
  }) async => {
    'invoked': false,
    'jsTrue': false,
    'raw': '',
    'actions': <dynamic>[],
  };

  // ========== WebBook 操作 ==========

  @override
  Future<String> webbookSearch(
    String sourceJson,
    String query,
    int page,
  ) async => jsonEncode([]);

  @override
  Future<String> webbookInfo(String sourceJson, String bookUrl) async =>
      jsonEncode({'name': 'Mock书籍', 'author': 'Mock作者'});

  @override
  Future<String> webbookChapters(
    String sourceJson,
    String bookUrl, {
    String tocUrl = '',
    String bookName = '',
  }) async => jsonEncode([]);

  @override
  Future<String> webbookContent(String sourceJson, String chapterJson) async =>
      '（Mock 章节内容）';

  @override
  Stream<Map<String, dynamic>> debugBookSourceStream(
    String sourceUrl,
    String key,
  ) async* {
    yield {'state': 1, 'msg': '[00:00.000] ⇒开始搜索关键字:$key'};
    yield {'state': 1, 'msg': '[00:00.010] 书源 URL: $sourceUrl'};
    yield {'state': 1000, 'msg': '[00:00.020] ︽Mock 调试完成'};
  }

  @override
  Future<void> cancelDebugBookSource() async {}

  // ========== 发现页操作 ==========

  @override
  Future<List<ExploreCategory>> exploreParseUrl(
    String exploreUrl, {
    String sourceJson = '',
  }) async {
    if (exploreUrl.isEmpty) return [];
    return exploreUrl.split('\n').where((l) => l.contains('::')).map((line) {
      final parts = line.split('::');
      return ExploreCategory(
        title: parts[0].trim(),
        url: parts.length > 1 ? parts[1].trim() : '',
      );
    }).toList();
  }

  @override
  Future<List<SearchBook>> exploreFetchBooks(
    String sourceJson,
    String url,
    int page,
  ) async {
    return List.generate(10, (i) {
      return SearchBook(
        bookUrl: 'mock://explore/$url/$page/$i',
        name: '发现书籍 ${(page - 1) * 10 + i + 1}',
        author: '作者${i + 1}',
        coverUrl: 'https://www.biquge.com.cn/files/article/image/${i + 1}.jpg',
        intro: '发现页书籍简介',
        origin: 'https://www.biquge.com.cn',
        originName: '笔趣阁',
        latestChapterTitle: '最新章节',
      );
    });
  }

  final Map<String, Map<String, String>> _exploreInfoMaps = {};

  @override
  Future<void> exploreInfoMapPut(
    String sourceUrl,
    String key,
    String value,
  ) async {
    _exploreInfoMaps.putIfAbsent(sourceUrl, () => {})[key] = value;
  }

  @override
  Future<void> exploreInfoMapEnsureDefault(
    String sourceUrl,
    String key,
    String defaultValue,
  ) async {
    final map = _exploreInfoMaps.putIfAbsent(sourceUrl, () => {});
    map.putIfAbsent(key, () => defaultValue);
  }

  @override
  Future<String> exploreInfoMapSnapshot(String sourceUrl) async =>
      jsonEncode(_exploreInfoMaps[sourceUrl] ?? const <String, String>{});

  @override
  Future<Map<String, dynamic>> exploreEvalAction({
    required String sourceJson,
    required String actionJs,
  }) async {
    return {
      'raw': '',
      'actions': <dynamic>[],
      'refreshExplore': actionJs.contains('refreshExplore'),
    };
  }

  @override
  Future<String> exploreEvalUiJs({
    required String sourceJson,
    required String jsStr,
  }) async => jsStr;
}
