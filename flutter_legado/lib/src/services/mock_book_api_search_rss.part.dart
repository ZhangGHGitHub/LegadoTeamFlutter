// mock_book_api.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// 本文件承载 MockBookApiSearchRss mixin：搜索 / RSS 源 / 本地书籍 / TXT 全文搜索。
// MockBookApi 经 with 组合各 mixin（成员合集实现 BookApi）；
// 内存存储字段来自 MockBookApiStore（on 约束），同一 library 内私有成员可直接访问。
part of 'mock_book_api.dart';

mixin MockBookApiSearchRss on MockBookApiStore implements BookApi {
  // ========== 搜索操作 ==========

  @override
  Future<List<SearchResult>> searchBooks(
    String keyword, {
    List<String>? sourceUrls,
  }) async {
    // 固定返回 5 条结果（模拟多源聚合搜索）
    const mockSourceNames = ['消消乐听书', '笔趣阁', '起点中文网'];
    return List.generate(5, (i) {
      final srcName = mockSourceNames[i % mockSourceNames.length];
      return SearchResult(
        sourceName: srcName,
        book: Book(
          bookUrl: 'mock://search/$keyword/$i',
          name: '$keyword 相关书籍${i + 1}',
          author: '作者${i + 1}',
          coverUrl:
              'https://www.biquge.com.cn/files/article/image/${i + 1}.jpg',
          intro: '这是搜索"$keyword"的第${i + 1}条结果简介。',
          latestChapterTitle: '最新章节',
          origin: 'https://www.kaixin7days.com',
          originName: srcName,
        ),
      );
    });
  }

  @override
  Future<SearchBook> preciseSearch(
    String name,
    String author, {
    List<String>? sourceUrls,
  }) async {
    return SearchBook(
      name: name,
      author: author,
      bookUrl: 'mock://precise/$name',
      origin: 'https://www.kaixin7days.com',
      originName: '消消乐听书',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> searchMulti(
    String query, {
    List<String>? sourceUrls,
  }) async {
    const srcNames = ['消消乐听书', '笔趣阁', '起点中文网'];
    return List.generate(
      3,
      (i) => {
        'source': srcNames[i],
        'count': 5,
        'results': <Map<String, dynamic>>[],
      },
    );
  }

  @override
  Stream<Map<String, dynamic>> searchMultiStream(
    String query, {
    List<String>? sourceUrls,
    int page = 1,
  }) async* {
    const srcNames = ['消消乐听书', '笔趣阁', '起点中文网'];
    const srcUrls = [
      'https://www.kaixin7days.com',
      'https://www.biquge.com.cn',
      'https://www.qidian.com',
    ];
    final total = srcNames.length;
    for (var i = 0; i < total; i++) {
      // 模拟逐源完成的渐进推送
      await Future<void>.delayed(const Duration(milliseconds: 120));
      yield {
        'source_index': i,
        'source_url': srcUrls[i],
        'source_name': srcNames[i],
        'books': List.generate(
          2,
          (j) => {
            'origin': srcUrls[i],
            'originName': srcNames[i],
            // 源级 BookType（对齐原版 getBookType：text=8/audio=32）
            'type': i == 0 ? 32 : 8,
            'name': '$query 相关书籍${i * 2 + j + 1}',
            'author': '作者${i * 2 + j + 1}',
            'bookUrl': 'mock://search/$query/${i}_$j',
            'kind': i == 0 ? '都市,轻松' : '玄幻,热血',
            'wordCount': '${(i * 2 + j + 1) * 12}万字',
            'latestChapterTitle': '最新章节',
            'intro': '渐进搜索“$query”的结果。',
            'coverUrl': null,
          },
        ),
        'error': null,
        'finished_count': i + 1,
        'total_count': total,
        'is_last': i == total - 1,
        // 批次B G-B-02：Mock 批次恒有下一页（非末批语义），与 Rust has_more 累积值对齐
        'has_more': true,
      };
    }
  }

  @override
  Future<void> cancelSearch() async {}

  // 批次B G-B-04：Mock 无真实并发调度，暂停/恢复为空操作（保持接口一致性）
  @override
  Future<void> pauseSearch() async {}

  @override
  Future<void> resumeSearch() async {}

  @override
  Future<List<Map<String, dynamic>>> searchSource(
    String bookName,
    String author, {
    List<String>? sourceUrls,
    bool loadInfo = false,
    bool loadToc = false,
    bool loadWordCount = false,
    bool forceRefresh = false,
  }) async {
    // forceRefresh 仅真实后端消费；Mock 忽略
    // ignore: unused_local_variable
    final _ = forceRefresh;
    const srcNames = ['消消乐听书', '笔趣阁', '起点中文网'];
    const srcUrls = [
      'https://www.kaixin7days.com',
      'https://www.biquge.com.cn',
      'https://www.qidian.com',
    ];
    // 对齐 Rust `SourceMatch` 的 snake_case 序列化（按 score 降序，Rust 侧已排序）
    final all = List.generate(
      3,
      (i) => {
        'source_url': srcUrls[i],
        'source_name': srcNames[i],
        'book_url': 'mock://switch/$bookName/$i',
        'book_name': bookName,
        'author': author,
        'latest_chapter': '最新章节${i + 1}',
        'word_count': '${100 + i * 50}万字',
        'score': 90.0 - i * 10,
      },
    );
    // [UI-fix v2.0.3 | 2026-08-06] 留项#12（Task #131）：模拟 sourceUrls 过滤语义，
    // 非空列表时仅返回指定书源的候选 — QoderCN
    if (sourceUrls != null && sourceUrls.isNotEmpty) {
      return all.where((m) => sourceUrls.contains(m['source_url'])).toList();
    }
    return all;
  }

  /// T6 Mock：模拟逐源完成的渐进推送（对齐 Rust `ChangeSourceBatch` 批次字段；
  /// `matches` 为累积候选全量快照——与 [searchSource] 同源数据按到达顺序累积）
  @override
  Stream<Map<String, dynamic>> searchSourceStream(
    String bookName,
    String author, {
    List<String>? sourceUrls,
    bool loadInfo = false,
    bool loadToc = false,
    bool loadWordCount = false,
    bool forceRefresh = false,
  }) async* {
    // forceRefresh 仅真实后端消费；Mock 忽略
    // ignore: unused_local_variable
    final _ = forceRefresh;
    const srcNames = ['消消乐听书', '笔趣阁', '起点中文网'];
    const srcUrls = [
      'https://www.kaixin7days.com',
      'https://www.biquge.com.cn',
      'https://www.qidian.com',
    ];
    // 与 searchSource 同源的候选全集（snake_case，score 降序）
    final all = List.generate(
      3,
      (i) => {
        'source_url': srcUrls[i],
        'source_name': srcNames[i],
        'book_url': 'mock://switch/$bookName/$i',
        'book_name': bookName,
        'author': author,
        'latest_chapter': '最新章节${i + 1}',
        'word_count': '${100 + i * 50}万字',
        'score': 90.0 - i * 10,
      },
    );
    // sourceUrls 过滤语义（与 searchSource 一致）
    final pool = (sourceUrls != null && sourceUrls.isNotEmpty)
        ? all.where((m) => sourceUrls.contains(m['source_url'])).toList()
        : all;
    if (pool.isEmpty) {
      yield {
        'source_index': 0,
        'source_url': '',
        'source_name': '',
        'error': null,
        'finished_count': 0,
        'total_count': 0,
        'is_last': true,
        'matches': <Map<String, dynamic>>[],
      };
      return;
    }
    // 模拟逐源完成：每轮追加一个候选（累积快照），末批 is_last
    var accumulated = <Map<String, dynamic>>[];
    for (var i = 0; i < pool.length; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      accumulated = [...accumulated, pool[i]];
      yield {
        'source_index': i,
        'source_url': pool[i]['source_url'],
        'source_name': pool[i]['source_name'],
        'error': null,
        'finished_count': i + 1,
        'total_count': pool.length,
        'is_last': i == pool.length - 1,
        'matches': accumulated,
      };
    }
  }

  @override
  Future<List<Map<String, dynamic>>> searchCover(String bookName) async {
    // 模拟网络延迟
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 按书名生成确定性候选封面（占位数据，字段对齐 Rust `CoverCandidate`）
    final base = bookName.hashCode.abs();
    return List.generate(
      5,
      (i) => {
        'url': 'https://picsum.photos/seed/${base + i}/240/320',
        'width': 240,
        'height': 320,
      },
    );
  }

  @override
  Future<String> switchSource(
    String bookUrl,
    String newSourceUrl,
    String newBookUrl,
  ) async {
    return newBookUrl;
  }

  final Map<String, int> _searchBookScores = {};

  @override
  Future<void> updateSearchBookScore(String bookUrl, int score) async {
    _searchBookScores[bookUrl] = score;
  }

  @override
  Future<void> deleteSearchBook(String bookUrl) async {
    _searchBookScores.remove(bookUrl);
  }

  // ========== RSS 源操作 ==========

  @override
  Future<List<RssSource>> getRssSources() async => List.from(_rssSources);

  @override
  Future<RssSource> addRssSource(RssSource source) async {
    _rssSources.add(source);
    return source;
  }

  @override
  Future<void> updateRssSource(RssSource source) async {
    // 对齐 rssUpdateSource FFI 语义：源不存在时报错（不再静默忽略） — QoderCN
    final idx = _rssSources.indexWhere((s) => s.sourceUrl == source.sourceUrl);
    if (idx < 0) {
      throw StateError(
        'updateRssSource: RSS 源不存在（sourceUrl=${source.sourceUrl}）',
      );
    }
    _rssSources[idx] = source;
  }

  @override
  Future<void> deleteRssSource(String sourceUrl) async {
    _rssSources.removeWhere((s) => s.sourceUrl == sourceUrl);
  }

  @override
  Future<void> enableRssSource(String sourceUrl) async {
    final idx = _rssSources.indexWhere((s) => s.sourceUrl == sourceUrl);
    if (idx >= 0) _rssSources[idx] = _rssSources[idx].copyWith(enabled: true);
  }

  @override
  Future<void> disableRssSource(String sourceUrl) async {
    final idx = _rssSources.indexWhere((s) => s.sourceUrl == sourceUrl);
    if (idx >= 0) _rssSources[idx] = _rssSources[idx].copyWith(enabled: false);
  }

  @override
  Future<int> importRssSources(String jsonArray) async {
    final list = jsonDecode(jsonArray) as List<dynamic>;
    var count = 0;
    for (final item in list) {
      if (item is! Map) continue;
      await addRssSource(RssSource.fromJson(Map<String, dynamic>.from(item)));
      count++;
    }
    return count;
  }

  @override
  Future<String> exportRssSources() async =>
      jsonEncode(_rssSources.map((s) => s.toJson()).toList());

  @override
  Future<List<RssFeedArticle>> getRssArticles(String sourceUrl) async {
    // 每源 5 篇假文章
    return List.generate(5, (i) {
      return RssFeedArticle(
        title: '文章标题 ${i + 1} - ${sourceUrl.contains('1') ? '科技' : '文学'}',
        url: 'mock://rss/article/$sourceUrl/$i',
        description: '这是第${i + 1}篇文章的摘要描述。',
        pubDate: DateTime.now().subtract(Duration(days: i)).toIso8601String(),
        imageUrl: 'https://via.placeholder.com/300x150?text=Article${i + 1}',
        content: '<p>这是第${i + 1}篇文章的正文内容。</p>' * 5,
      );
    });
  }

  @override
  Future<void> rssClearArticles(String sourceUrl) async {
    // Mock：无本地文章表，空实现即可
  }

  // ========== RSS 已读记录 ==========

  final Set<String> _rssReadLinks = {};
  final List<Map<String, dynamic>> _rssReadRecords = [];

  @override
  Future<void> rssMarkRead(String origin, String title, [String? link]) async {
    if (link != null) _rssReadLinks.add(link);
    _rssReadRecords.insert(0, {
      'origin': origin,
      'title': title,
      'link': link,
      'read_time': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Future<bool> rssIsRead(String link) async => _rssReadLinks.contains(link);

  @override
  Future<bool> rssIsReadByTitle(String origin, String title) async =>
      _rssReadRecords.any((r) => r['origin'] == origin && r['title'] == title);

  @override
  Future<void> rssClearReadRecords() async {
    _rssReadLinks.clear();
    _rssReadRecords.clear();
  }

  @override
  Future<int> rssReadRecordCount() async => _rssReadRecords.length;

  @override
  Future<List<Map<String, dynamic>>> rssListReadRecords([int? limit]) async {
    final l = limit ?? 100;
    return _rssReadRecords.take(l).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> rssListReadRecordsByOrigin(
    String origin, [
    int? limit,
  ]) async {
    final l = limit ?? 100;
    return _rssReadRecords.where((r) => r['origin'] == origin).take(l).toList();
  }

  // ========== 本地书籍操作 ==========

  @override
  Future<Book> importLocalBook(String filePath) async {
    final book = Book(
      bookUrl: 'file://$filePath',
      name: filePath
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll(RegExp(r'\.\w+$'), ''),
      author: '本地导入',
      bookType: BookType.local,
    );
    _books.add(book);
    return book;
  }

  @override
  Future<List<Map<String, dynamic>>> scanLocalBooks(String dirPath) async {
    return [
      {
        'path': '$dirPath/book1.txt',
        'name': 'book1.txt',
        'size': 102400,
        'lastModified': DateTime.now().toIso8601String(),
      },
      {
        'path': '$dirPath/book2.epub',
        'name': 'book2.epub',
        'size': 2048000,
        'lastModified': DateTime.now().toIso8601String(),
      },
    ];
  }

  @override
  Future<String> detectFormat(String filePath) async {
    if (filePath.endsWith('.epub')) return 'epub';
    if (filePath.endsWith('.pdf')) return 'pdf';
    return 'txt';
  }

  @override
  Future<String> parseMetadata(String filePath) async {
    return jsonEncode({'title': '未知书籍', 'author': '未知作者', 'format': 'txt'});
  }

  // ========== 本地 TXT 全文搜索（Task #98 缺口#4，加法式新增） ==========

  /// 构造 Mock 搜索结果（字段结构对齐 Rust TxtSearchResult）
  List<Map<String, dynamic>> _mockTxtSearchResults(String query) {
    return [
      {
        'chapter_index': 0,
        'chapter_title': '第一章 测试章节',
        'char_offset': 42,
        'matched_text': query,
        'context': '……这是包含 $query 的上下文摘要……',
        'context_match_start': 6,
        'context_match_end': 6 + query.length,
      },
      {
        'chapter_index': 1,
        'chapter_title': '第二章 后续发展',
        'char_offset': 108,
        'matched_text': query,
        'context': '……另一处包含 $query 的正文片段……',
        'context_match_start': 8,
        'context_match_end': 8 + query.length,
      },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> txtSearch(
    String path,
    String query, {
    bool caseSensitive = false,
    int maxResults = 500,
  }) async {
    if (query.isEmpty) return [];
    return _mockTxtSearchResults(query);
  }

  @override
  Future<List<Map<String, dynamic>>> txtSearchRegex(
    String path,
    String pattern, {
    bool caseSensitive = false,
    int maxResults = 500,
  }) async {
    if (pattern.isEmpty) return [];
    return _mockTxtSearchResults(pattern);
  }

  @override
  Future<List<Map<String, dynamic>>> txtSearchInChapter(
    String path,
    String query,
    int chapterIndex, {
    bool caseSensitive = false,
    int maxResults = 50,
  }) async {
    if (query.isEmpty) return [];
    return _mockTxtSearchResults(
      query,
    ).where((r) => r['chapter_index'] == chapterIndex).toList();
  }

  @override
  Future<int> txtSearchCount(
    String path,
    String query, {
    bool caseSensitive = false,
  }) async {
    if (query.isEmpty) return 0;
    return 2;
  }
}
