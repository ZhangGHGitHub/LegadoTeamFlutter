import 'dart:convert';

import '../models/models.dart';
import 'book_api.dart';

/// Mock 书籍 API 实现
///
/// 纯 Dart 实现，无需 Rust DLL，供 UI 轨开发使用。
/// 所有数据存储在内存中，会话内可读写。
/// 用法：`flutter run -d windows --dart-define=USE_MOCK=true`
///
/// ─── Mock 数据来源说明（REFACTORING_PLAN §6.4）───
///
/// 书源（BookSource）样本取自原 Android 端内置默认数据：
///   app/src/main/assets/defaultData/bookSources.json
///   （消消乐听书源，bookSourceType=1 音频源，含完整 ruleSearch/ruleExplore/ruleToc）
///
/// RSS 源（RssSource）样本取自原 Android 端内置默认数据：
///   app/src/main/assets/defaultData/rssSources.json
///   （使用说明 / 小说拾遗 / Meow云 / 烏雲净化，均为 legado 官方内置源）
///
/// HTTP TTS 引擎样本取自原 Android 端内置默认数据：
///   app/src/main/assets/defaultData/httpTTS.json
///   （百度 TTS / 阿里云语音，含真实 url 模板与 contentType）
///
/// 书架书籍（Book）为调试用占位数据，字段结构严格对齐
///   flutter_legado/lib/src/models/book.dart 与 docs/API_CONTRACT.md §2.2，
///   书名/作者沿用经典网文以便 UI 截图对比；
///   TODO(§6.4): 后续应从原 Android 端真实书架导出 JSON 替换。
class MockBookApi implements BookApi {
  // ========== 内存数据存储 ==========

  final List<Book> _books = [];
  final List<BookSource> _sources = [];
  final List<RssSource> _rssSources = [];
  final List<Bookmark> _bookmarks = [];
  final List<ReplaceRule> _replaceRules = [];
  final List<BookGroup> _bookGroups = [];
  final List<SearchKeyword> _searchHistory = [];
  final List<ReadRecord> _readRecords = [];
  final List<RssStar> _rssStars = [];
  final List<HttpTts> _httpTtsList = [];
  final Map<String, String> _configs = {};
  final Map<String, List<BookChapter>> _chaptersCache = {};
  final Map<String, Map<int, String>> _contentCache = {};

  int _nextId = 1;

  MockBookApi() {
    _initMockData();
  }

  /// 初始化 Mock 数据
  ///
  /// 数据来源见文件头注释。书籍为占位调试数据，书源/RSS/TTS 取自
  /// Android 原端 app/src/main/assets/defaultData/ 下真实 JSON。
  void _initMockData() {
    // ── 书架书籍（占位调试数据，字段对齐 Book model & API_CONTRACT §2.2）──
    // TODO(§6.4): 替换为原 Android 真实书架导出 JSON
    _books.addAll([
      Book(
        bookUrl: 'mock://book/1',
        tocUrl: 'https://www.biquge.com.cn/book/6909/',
        name: '斗破苍穹',
        author: '天蚕土豆',
        kind: '玄幻',
        coverUrl: 'https://www.biquge.com.cn/files/article/image/6/6909/6909s.jpg',
        intro: '讲述了天才少年萧炎在创造了家族史上空前绝后的修炼纪录后突然成了废人，在药老的帮助下一步步走向巅峰的故事。',
        latestChapterTitle: '第一千六百四十八章 大结局',
        latestChapterTime: 1630656684531,
        totalChapterNum: 1648,
        wordCount: '5342000',
        canUpdate: true,
        order: 0,
        group: 0,
        origin: 'https://www.biquge.com.cn',
        originName: '笔趣阁',
      ),
      Book(
        bookUrl: 'mock://book/2',
        tocUrl: 'https://www.qidian.com/book/1010erta/',
        name: '凡人修仙传',
        author: '忘语',
        kind: '仙侠',
        coverUrl: 'https://bookcover.yuewen.com/qdbimg/349573/1010erta/150',
        intro: '一个普通山村少年，偶然下进入了当地江湖小门派，成了一名记名弟子，从而踏上了漫漫的修仙之路。',
        latestChapterTitle: '第七百七十四章 飞升',
        latestChapterTime: 1630656684531,
        totalChapterNum: 774,
        wordCount: 3728000.toString(),
        canUpdate: true,
        order: 1,
        group: 0,
        origin: 'https://www.qidian.com',
        originName: '起点中文网',
      ),
      Book(
        bookUrl: 'mock://book/3',
        tocUrl: 'https://www.kaixin7days.com/book-service/bookMgt/getAllChapterByBookId',
        name: '三体',
        author: '刘慈欣',
        kind: '科幻',
        coverUrl: null,
        intro: '文化大革命如火如荼进行的同时，军方探寻外星文明的绝秘计划"红岸工程"取得了突破性进展。',
        latestChapterTitle: '第三部 死神永生',
        latestChapterTime: 1630656684531,
        totalChapterNum: 80,
        wordCount: '880000',
        canUpdate: false,
        order: 2,
        group: 1,
        origin: 'https://www.kaixin7days.com',
        originName: '消消乐听书',
      ),
    ]);

    // 每本书 10 章（章节标题模拟真实网文目录风格）
    for (var i = 0; i < 3; i++) {
      final bookUrl = 'mock://book/${i + 1}';
      final chapters = <BookChapter>[];
      final contents = <int, String>{};
      for (var j = 0; j < 10; j++) {
        chapters.add(BookChapter(
          title: '第${j + 1}章 ${_mockChapterTitles[j]}',
          bookUrl: bookUrl,
          url: 'mock://chapter/$bookUrl/$j',
          index: j,
          start: j * 2000,
          end: (j + 1) * 2000,
        ));
        contents[j] = _generateMockContent(i, j);
      }
      _chaptersCache[bookUrl] = chapters;
      _contentCache[bookUrl] = contents;
    }

    // ── 书源（来源：app/src/main/assets/defaultData/bookSources.json）──
    // 基于原 Android 内置「消消乐听书」音频源结构，扩充为 3 条贴近真实书源。
    _sources.addAll([
      BookSource(
        bookSourceUrl: 'https://www.kaixin7days.com',
        bookSourceName: '消消乐听书',
        bookSourceGroup: '听书',
        bookSourceType: 1, // 音频源
        enabled: true,
        enabledExplore: true,
        exploreUrl: '玄幻::https://www.kaixin7days.com/book-service/bookMgt/getAllBookByCategroyId\n都市::https://www.kaixin7days.com/book-service/bookMgt/getAllBookByCategroyId',
        searchUrl: 'https://www.kaixin7days.com/book-service/bookMgt/findBookName,{"method":"POST","body":{"title": "searchKey","pageNum": 1,"pageSize": 100}}',
        customOrder: 0,
        lastUpdateTime: 1630656684531,
        respondTime: 180000,
        weight: 0,
      ),
      BookSource(
        bookSourceUrl: 'https://www.biquge.com.cn',
        bookSourceName: '笔趣阁',
        bookSourceGroup: '网文',
        bookSourceType: 0, // 文本源
        enabled: true,
        enabledExplore: true,
        exploreUrl: '玄幻::https://www.biquge.com.cn/xuanhuan/\n仙侠::https://www.biquge.com.cn/xianxia/\n都市::https://www.biquge.com.cn/dushi/',
        searchUrl: 'https://www.biquge.com.cn/s?q=searchKey',
        customOrder: 1,
        lastUpdateTime: 1630656684531,
        respondTime: 180000,
        weight: 0,
      ),
      BookSource(
        bookSourceUrl: 'https://www.qidian.com',
        bookSourceName: '起点中文网',
        bookSourceGroup: '网文',
        bookSourceType: 0,
        enabled: false, // 需登录，默认禁用
        enabledExplore: true,
        exploreUrl: '热门::https://www.qidian.com/rank/hotsales/\n新书::https://www.qidian.com/rank/newbook/',
        searchUrl: 'https://www.qidian.com/so/searchKey/',
        customOrder: 2,
        lastUpdateTime: 1630656684531,
        respondTime: 180000,
        weight: 0,
      ),
    ]);

    // ── RSS 订阅源（来源：app/src/main/assets/defaultData/rssSources.json）──
    _rssSources.addAll([
      RssSource(
        sourceUrl: 'https://www.yuque.com/legado',
        sourceName: '使用说明',
        sourceIcon: 'https://cdn.jsdelivr.net/gh/gedoor/legado@master/app/src/main/res/mipmap-hdpi/ic_launcher.png',
        sourceGroup: 'legado',
        enabled: true,
        singleUrl: true,
        enableJs: true,
        customOrder: 2,
      ),
      RssSource(
        sourceUrl: 'snssdk1128://user/profile/562564899806367',
        sourceName: '小说拾遗',
        sourceIcon: 'http://mmbiz.qpic.cn/mmbiz_png/hpfMV8hEuL2eS6vnCxvTzoOiaCAibV6exBzJWq9xMic9xDg3YXAick87tsfafic0icRwkQ5ibV0bJ84JtSuxhPuEDVquA/0?wx_fmt=png',
        sourceGroup: 'legado',
        enabled: true,
        singleUrl: true,
        enableJs: true,
        customOrder: 3,
      ),
      RssSource(
        sourceUrl: 'https://pan.miaogongzi.net',
        sourceName: 'Meow云',
        sourceIcon: 'https://cdn.jsdelivr.net/gh/mgz0227/meowcloud/icon.png',
        sourceGroup: 'legado',
        enabled: true,
        singleUrl: true,
        enableJs: true,
        customOrder: 4,
      ),
      RssSource(
        sourceUrl: 'https://www.lanzout.com/b0bw8jwoh',
        sourceName: '烏雲净化',
        sourceIcon: 'https://cdn.jsdelivr.net/gh/gedoor/legado@master/app/src/main/res/mipmap-hdpi/ic_launcher.png',
        sourceGroup: 'legado',
        enabled: true,
        singleUrl: true,
        enableJs: true,
        customOrder: 5,
      ),
    ]);

    // ── HTTP TTS 引擎（来源：app/src/main/assets/defaultData/httpTTS.json）──
    _httpTtsList.addAll([
      HttpTts(
        id: -100,
        name: '1.百度',
        url: 'http://tts.baidu.com/text2audio,{"method": "POST","body": "tex={{java.encodeURI(java.encodeURI(speakText))}}&spd={{(speakSpeed + 5) / 10 + 4}}&per=3&cuid=baidu_speech_demo&idx=1&cod=2&lan=zh&ctp=1&pdt=160&vol=5&aue=6&pit=5&_res_tag_=audio"}',
        contentType: 'audio/wav',
      ),
      HttpTts(
        id: -29,
        name: '2.阿里云语音',
        url: 'https://nls-gateway.cn-shanghai.aliyuncs.com/stream/v1/tts,{"method": "POST","body": {"appkey":"{{source.getLoginInfoMap().get(\'AppKey\')}}","text":"{{speakText}}","format":"mp3","volume":100,"speech_rate":{{String((speakSpeed) * 20 - 400)}} }}',
        contentType: 'audio/mpeg',
      ),
    ]);

    // 默认分组
    _bookGroups.add(BookGroup(
      groupId: 1,
      groupName: '科幻',
      order: 0,
      show: true,
    ));
  }

  static const _mockChapterTitles = [
    '初入江湖',
    '风云际会',
    '暗流涌动',
    '绝地反击',
    '峰回路转',
    '真相大白',
    '生死一线',
    '破茧成蝶',
    '天下大势',
    '尘埃落定',
  ];

  /// 生成 Mock 章节正文（足够排版引擎分页）
  String _generateMockContent(int bookIndex, int chapterIndex) {
    final paragraphs = <String>[];
    final bookName = _books[bookIndex].name;
    paragraphs.add('    这是《$bookName》第${chapterIndex + 1}章的正文内容。');
    for (var i = 0; i < 15; i++) {
      paragraphs.add(
        '    第${i + 1}段：修炼之路漫漫其修远兮，吾将上下而求索。'
        '天地之间，灵气充沛，万物生长。'
        '少年立于山巅，俯瞰苍茫大地，心中豪情万丈。'
        '远处的云海翻涌如潮，金色的阳光穿透云层洒落人间。'
        '他深吸一口气，感受着体内真气的流转，每一步都踏得坚实有力。',
      );
    }
    return paragraphs.join('\n\n');
  }

  // ========== 初始化/版本 ==========

  @override
  Future<void> initialize() async {
    // Mock 模式无需初始化
  }

  @override
  Future<String> getVersion() async => 'mock-1.0.0';

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
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == source.bookSourceUrl);
    if (idx >= 0) _sources[idx] = source;
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
          coverUrl: 'https://www.biquge.com.cn/files/article/image/${i + 1}.jpg',
          intro: '这是搜索"$keyword"的第${i + 1}条结果简介。',
          latestChapterTitle: '最新章节',
          origin: 'https://www.kaixin7days.com',
          originName: srcName,
        ),
      );
    });
  }

  @override
  Future<List<Map<String, dynamic>>> searchMulti(
    String query, {
    List<String>? sourceUrls,
  }) async {
    const srcNames = ['消消乐听书', '笔趣阁', '起点中文网'];
    return List.generate(3, (i) => {
      'source': srcNames[i],
      'count': 5,
      'results': <Map<String, dynamic>>[],
    });
  }

  @override
  Stream<Map<String, dynamic>> searchMultiStream(
    String query, {
    List<String>? sourceUrls,
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
        'books': List.generate(2, (j) => {
          'source_url': srcUrls[i],
          'source_name': srcNames[i],
          'book_name': '$query 相关书籍${i * 2 + j + 1}',
          'author': '作者${i * 2 + j + 1}',
          'book_url': 'mock://search/$query/${i}_$j',
          'latest_chapter': '最新章节',
          'intro': '渐进搜索“$query”的结果。',
          'cover_url': null,
        }),
        'error': null,
        'finished_count': i + 1,
        'total_count': total,
        'is_last': i == total - 1,
      };
    }
  }

  @override
  Future<void> cancelSearch() async {}

  @override
  Future<List<Map<String, dynamic>>> searchSource(
    String bookName,
    String author,
  ) async {
    const srcNames = ['消消乐听书', '笔趣阁', '起点中文网'];
    const srcUrls = [
      'https://www.kaixin7days.com',
      'https://www.biquge.com.cn',
      'https://www.qidian.com',
    ];
    // 对齐 Rust `SourceMatch` 的 snake_case 序列化（按 score 降序，Rust 侧已排序）
    return List.generate(3, (i) => {
      'source_url': srcUrls[i],
      'source_name': srcNames[i],
      'book_url': 'mock://switch/$bookName/$i',
      'book_name': bookName,
      'author': author,
      'latest_chapter': '最新章节${i + 1}',
      'word_count': '${100 + i * 50}万字',
      'score': 90.0 - i * 10,
    });
  }

  @override
  Future<List<Map<String, dynamic>>> searchCover(String bookName) async {
    // 模拟网络延迟
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 按书名生成确定性候选封面（占位数据，字段对齐 Rust `CoverCandidate`）
    final base = bookName.hashCode.abs();
    return List.generate(5, (i) => {
      'url': 'https://picsum.photos/seed/${base + i}/240/320',
      'width': 240,
      'height': 320,
    });
  }

  @override
  Future<String> switchSource(
    String bookUrl,
    String newSourceUrl,
    String newBookUrl,
  ) async {
    return newBookUrl;
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
    final idx = _rssSources.indexWhere((s) => s.sourceUrl == source.sourceUrl);
    if (idx >= 0) _rssSources[idx] = source;
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
    return list.length;
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

  // ========== 本地书籍操作 ==========

  @override
  Future<Book> importLocalBook(String filePath) async {
    final book = Book(
      bookUrl: 'file://$filePath',
      name: filePath.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'\.\w+$'), ''),
      author: '本地导入',
      bookType: BookType.local,
    );
    _books.add(book);
    return book;
  }

  @override
  Future<List<Map<String, dynamic>>> scanLocalBooks(String dirPath) async {
    return [
      {'path': '$dirPath/book1.txt', 'name': 'book1.txt', 'size': 102400, 'lastModified': DateTime.now().toIso8601String()},
      {'path': '$dirPath/book2.epub', 'name': 'book2.epub', 'size': 2048000, 'lastModified': DateTime.now().toIso8601String()},
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

  // ========== 书签操作 ==========

  @override
  Future<List<Bookmark>> getBookmarks(String bookName) async =>
      _bookmarks.where((b) => b.bookName == bookName).toList();

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
  Future<List<Bookmark>> searchBookmarks(String keyword) async =>
      _bookmarks.where((b) => b.content.contains(keyword) || b.bookText.contains(keyword)).toList();

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
    if (idx >= 0) _replaceRules[idx] = _replaceRules[idx].copyWith(isEnabled: enabled);
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
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl) async =>
      _chaptersCache[bookUrl] ?? [];

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
    return {
      'word': key,
      'phonetic': '',
      'definitions': <String>[],
    };
  }

  // ========== 备份操作 ==========

  @override
  Future<String> backup(String dirPath) async {
    return '$dirPath/legado_backup_mock.json';
  }

  @override
  Future<void> restore(String backupPath) async {}

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
    final g = group.copyWith(groupId: _nextId++);
    _bookGroups.add(g);
    return g;
  }

  @override
  Future<void> updateBookGroup(BookGroup group) async {
    final idx = _bookGroups.indexWhere((g) => g.groupId == group.groupId);
    if (idx >= 0) _bookGroups[idx] = group;
  }

  @override
  Future<void> deleteBookGroup(int groupId) async {
    _bookGroups.removeWhere((g) => g.groupId == groupId);
  }

  // ========== 搜索历史 ==========

  @override
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50}) async =>
      _searchHistory.take(limit).toList();

  @override
  Future<List<String>> searchHistoryByPrefix(String prefix, {int limit = 20}) async {
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

  // ========== 缓存管理 ==========

  @override
  Future<int> getCacheSize() async => 1024 * 1024 * 50; // 50MB

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheBookCount() async => 3;

  @override
  Future<int> getCacheChapterCount() async => 30;

  @override
  Future<void> clearCacheBefore(int beforeTimestampMs) async {}

  // ========== WebBook 操作 ==========

  @override
  Future<String> webbookSearch(String sourceJson, String query, int page) async =>
      jsonEncode([]);

  @override
  Future<String> webbookInfo(String sourceJson, String bookUrl) async =>
      jsonEncode({'name': 'Mock书籍', 'author': 'Mock作者'});

  @override
  Future<String> webbookChapters(String sourceJson, String bookUrl) async =>
      jsonEncode([]);

  @override
  Future<String> webbookContent(String sourceJson, String chapterJson) async =>
      '（Mock 章节内容）';

  // ========== 发现页操作 ==========

  @override
  Future<List<ExploreCategory>> exploreParseUrl(String exploreUrl) async {
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

  // ========== 规则解析 ==========

  @override
  Future<String> parseRule(String content, String rule, String ruleType) async =>
      content;

  // ========== 网络操作 ==========

  @override
  Future<String> httpGet(String url) async => '{"status": "ok", "mock": true}';

  @override
  Future<String> httpPost(String url, String body) async =>
      '{"status": "ok", "mock": true}';

  /// Mock QUIC 开关状态（内存态，供设置页切换回显）
  bool _mockQuicEnabled = false;

  @override
  Future<bool> netIsQuicEnabled() async => _mockQuicEnabled;

  @override
  Future<void> netSetQuicEnabled(bool enabled) async {
    _mockQuicEnabled = enabled;
  }

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

  // ========== 书籍格式解析 ==========

  @override
  Future<List<BookChapter>> parseTxt(String filePath) async {
    return List.generate(5, (i) => BookChapter(
      title: '第${i + 1}章',
      bookUrl: filePath,
      index: i,
      start: i * 1000,
      end: (i + 1) * 1000,
    ));
  }

  @override
  Future<List<BookChapter>> parseEpub(String filePath) async {
    return List.generate(8, (i) => BookChapter(
      title: 'Chapter ${i + 1}',
      bookUrl: filePath,
      index: i,
      start: i * 2000,
      end: (i + 1) * 2000,
    ));
  }

  @override
  Future<String> exportBook(String bookUrl, String format, String outDir) async {
    return '$outDir/export_mock.$format';
  }

  // ========== 阅读统计 ==========

  @override
  Future<ReadingStatsToday> getTodayReadingStats() async {
    return const ReadingStatsToday(
      totalSeconds: 3600,
      bookCount: 2,
      durationSeconds: 3600,
      wordCount: 15000,
      readingSpeed: 250.0,
    );
  }

  @override
  Future<Map<String, int>> getDailyReadingStats({required int days}) async {
    final result = <String, int>{};
    for (var i = 0; i < days; i++) {
      final date = DateTime.now().subtract(Duration(days: i));
      result['${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'] =
          (i + 1) * 600;
    }
    return result;
  }

  @override
  Future<Map<String, int>> getBookReadingStats() async {
    return {
      '斗破苍穹': 7200,
      '凡人修仙传': 5400,
      '三体': 3600,
    };
  }

  @override
  Future<Map<String, int>> getReadingHeatmap({required int days}) async {
    return getDailyReadingStats(days: days);
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
  Future<Map<String, dynamic>> getAudioChapterMedia(
    String bookUrl,
    int chapterIndex,
  ) async {
    final chapters = await getChapters(bookUrl);
    if (chapterIndex < 0 || chapterIndex >= chapters.length) {
      return {'error': 'Invalid chapter index'};
    }
    return {
      'chapterIndex': chapterIndex,
      'title': chapters[chapterIndex].title,
      'url': chapters[chapterIndex].url,
      'resourceUrl': chapters[chapterIndex].resourceUrl,
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

  // ========== 用户管理 ==========

  @override
  Future<List<Map<String, dynamic>>> getUsers() async => [];

  @override
  Future<int> saveUser({
    required String username,
    required String password,
    required String sourceUrl,
  }) async => _nextId++;

  @override
  Future<bool> deleteUser(String username) async => true;

  @override
  Future<bool> userLogin({
    required String username,
    required String password,
  }) async => true;

  @override
  Future<bool> userLogout(String username) async => true;

  @override
  Future<bool> checkLoginStatus(String username) async => false;

  // ========== WebDAV 云同步 ==========

  @override
  Future<String> webdavListDir(String configJson, String path) async =>
      jsonEncode([]);

  @override
  Future<void> webdavUpload(String configJson, String path, String data) async {}

  @override
  Future<String> webdavDownload(String configJson, String path) async => '';

  @override
  Future<void> webdavDelete(String configJson, String path) async {}

  @override
  Future<String> webdavFullSync(
    String configJson,
    String localBooks,
    String localSources,
  ) async => '{"synced": true}';

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

  // ========== 段评/章评 ==========

  @override
  Future<String> reviewGetByChapter(String bookUrl, int chapterIndex) async =>
      jsonEncode([]);

  @override
  Future<int> reviewAdd({
    required String bookUrl,
    required int chapterIndex,
    int paragraphIndex = -1,
    required String content,
    String author = '',
  }) async => _nextId++;

  @override
  Future<bool> reviewDelete(int id) async => true;

  @override
  Future<void> reviewLike(int id) async {}

  @override
  Future<String> reviewGetReplies(
      String sourceJson, String requestJson, int page) async {
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
    final ids = (jsonDecode(idsJson) as List<dynamic>).map((e) => e.toString()).toList();
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
  Future<Map<String, dynamic>?> autoTaskFindRuleById({required String id}) async {
    try {
      return _mockAutoTaskRules.firstWhere((r) => r['id'] == id);
    } catch (_) {
      return null;
    }
  }

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
  Future<List<String>> archiveListZipFiles({required String zipPath}) async =>
      ['book1.txt', 'book2.epub', 'readme.md'];

  @override
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  }) async => ['novel.txt'];

  @override
  Future<Map<String, dynamic>> archiveDetectEncoding({
    required String filePath,
  }) async => {
    'encoding': 'UTF-8',
    'has_bom': false,
    'confidence': 'high',
  };

  @override
  Future<Map<String, dynamic>> archiveConvertEncoding({
    required String filePath,
    required String fromEncoding,
    required String toEncoding,
  }) async => {
    'success': true,
    'output_path': '$filePath.converted',
  };

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
    final items = _mockHighlights.values
        .where((h) => h['bookUrl'] == bookUrl)
        .toList()
      ..sort((a, b) =>
          ((a['time'] as num?) ?? 0).compareTo((b['time'] as num?) ?? 0));
    return _highlightListJson(items);
  }

  @override
  Future<String> highlightListByChapter({
    required String bookUrl,
    required int chapterIndex,
  }) async {
    final items = _mockHighlights.values
        .where((h) =>
            h['bookUrl'] == bookUrl && h['chapterIndex'] == chapterIndex)
        .toList()
      ..sort((a, b) =>
          ((a['time'] as num?) ?? 0).compareTo((b['time'] as num?) ?? 0));
    return _highlightListJson(items);
  }

  @override
  Future<String> highlightSearch({required String keyword}) async {
    final key = keyword.toLowerCase();
    final items = _mockHighlights.values
        .where((h) =>
            ((h['bookText'] as String?) ?? '')
                .toLowerCase()
                .contains(key) ||
            ((h['note'] as String?) ?? '').toLowerCase().contains(key))
        .toList();
    return _highlightListJson(items);
  }

  @override
  Future<String> highlightListAll() async =>
      _highlightListJson(_mockHighlights.values);

  @override
  Future<String> highlightRuleList() async {
    final items = _mockHighlightRules.values.toList()
      ..sort((a, b) => ((a['sortOrder'] as num?) ?? 0)
          .compareTo((b['sortOrder'] as num?) ?? 0));
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
    final items = _mockHighlightRules.values.where((r) {
      final enabled = (r['isEnabled'] as bool?) ?? false;
      if (!enabled) return false;
      final scope = r['scope'] as String?;
      if (scope == null || scope.isEmpty) return true;
      return scope.contains(bookName) || scope.contains(origin);
    }).toList()
      ..sort((a, b) => ((a['sortOrder'] as num?) ?? 0)
          .compareTo((b['sortOrder'] as num?) ?? 0));
    return _highlightListJson(items);
  }
}
