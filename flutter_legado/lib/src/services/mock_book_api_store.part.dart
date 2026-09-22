// mock_book_api.dart 的 part 文件（体检 §三.16 超长文件拆分）：内存数据存储。
// 各分域 mixin 以 on MockBookApiStore 获得存储字段访问。
part of 'mock_book_api.dart';

mixin MockBookApiStore {
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
  // 字典规则内存态（契约 §2.45：dictRule* 七方法；REPLACE by name 语义）
  final List<Map<String, dynamic>> _dictRules = [];
  final Map<String, String> _configs = {};
  final Map<String, List<BookChapter>> _chaptersCache = {};
  final Map<String, Map<int, String>> _contentCache = {};
  // 登录凭据内存态（sourceLogin 手动登录/登录缓存，USE_MOCK 开发模式用）
  final Map<String, String> _mockLoginInfo = {};
  final Map<String, String> _mockLoginHeader = {};

  int _nextId = 1;

  /// 字典规则自增 ID（独立于 `_nextId`，避免与其他 mock 实体串号）
  int _nextDictRuleId = 1;

  // [书源作用域 | 2026-09-13] applyReplaceRulesToSource 调用计数（测试断言用）
  int _applyReplaceRulesToSourceCalls = 0;

  /// [书源作用域 | 2026-09-13] `applyReplaceRulesToSource` 调用次数（测试断言用）
  int get applyReplaceRulesToSourceCalls => _applyReplaceRulesToSourceCalls;

  // [替换规则预览 | 2026-09-13] previewReplaceRule 调用计数（测试断言用）
  int _previewReplaceRuleCalls = 0;

  /// [替换规则预览 | 2026-09-13] `previewReplaceRule` 调用次数（测试断言用）
  int get previewReplaceRuleCalls => _previewReplaceRuleCalls;


  /// 初始化 Mock 数据
  ///
  /// 数据来源见文件头注释。书源/RSS/TTS 取自
  /// Android 原端 app/src/main/assets/defaultData/ 下真实 JSON（内置字面量）；
  /// 书架书籍为合成脱敏样例，经资产 assets/mock_data/bookshelf_sample.json
  /// 惰性加载（MockBookApi 构造器保持同步，资产读取为异步，
  /// 各书架相关方法先 await [_ensureBooksLoaded]）。
  void _initMockData() {
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
        exploreUrl:
            '玄幻::https://www.kaixin7days.com/book-service/bookMgt/getAllBookByCategroyId\n都市::https://www.kaixin7days.com/book-service/bookMgt/getAllBookByCategroyId',
        searchUrl:
            'https://www.kaixin7days.com/book-service/bookMgt/findBookName,{"method":"POST","body":{"title": "searchKey","pageNum": 1,"pageSize": 100}}',
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
        exploreUrl:
            '玄幻::https://www.biquge.com.cn/xuanhuan/\n仙侠::https://www.biquge.com.cn/xianxia/\n都市::https://www.biquge.com.cn/dushi/',
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
        exploreUrl:
            '热门::https://www.qidian.com/rank/hotsales/\n新书::https://www.qidian.com/rank/newbook/',
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
        sourceIcon:
            'https://cdn.jsdelivr.net/gh/gedoor/legado@master/app/src/main/res/mipmap-hdpi/ic_launcher.png',
        sourceGroup: 'legado',
        enabled: true,
        singleUrl: true,
        enableJs: true,
        customOrder: 2,
      ),
      RssSource(
        sourceUrl: 'snssdk1128://user/profile/562564899806367',
        sourceName: '小说拾遗',
        sourceIcon:
            'http://mmbiz.qpic.cn/mmbiz_png/hpfMV8hEuL2eS6vnCxvTzoOiaCAibV6exBzJWq9xMic9xDg3YXAick87tsfafic0icRwkQ5ibV0bJ84JtSuxhPuEDVquA/0?wx_fmt=png',
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
        sourceIcon:
            'https://cdn.jsdelivr.net/gh/gedoor/legado@master/app/src/main/res/mipmap-hdpi/ic_launcher.png',
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
        url:
            'http://tts.baidu.com/text2audio,{"method": "POST","body": "tex={{java.encodeURI(java.encodeURI(speakText))}}&spd={{(speakSpeed + 5) / 10 + 4}}&per=3&cuid=baidu_speech_demo&idx=1&cod=2&lan=zh&ctp=1&pdt=160&vol=5&aue=6&pit=5&_res_tag_=audio"}',
        contentType: 'audio/wav',
      ),
      HttpTts(
        id: -29,
        name: '2.阿里云语音',
        url:
            'https://nls-gateway.cn-shanghai.aliyuncs.com/stream/v1/tts,{"method": "POST","body": {"appkey":"{{source.getLoginInfoMap().get(\'AppKey\')}}","text":"{{speakText}}","format":"mp3","volume":100,"speech_rate":{{String((speakSpeed) * 20 - 400)}} }}',
        contentType: 'audio/mpeg',
      ),
    ]);

    // 默认分组（与书架样例的 group 字段对应：1=科幻、2=收藏）
    _bookGroups.add(
      BookGroup(groupId: 1, groupName: '科幻', order: 0, show: true),
    );
    _bookGroups.add(
      BookGroup(groupId: 2, groupName: '收藏', order: 1, show: true),
    );

    // ── 字典规则（对标 Rust seed_default_rules：表为空时注入原版默认 5 源）──
    // 名称/排序/启用态与 rust/assets/defaultData/dictRules.json 对齐；
    // JS 重量级规则的 urlRule/showRule 以短占位代替（mock 不执行查询链路，
    // dictLookup 走静态 _mockDict，规则内容仅供 CRUD/排序/导入语义演示）。
    _seedDefaultDictRules();
  }

  /// 注入原版默认 5 个字典源（海词中文 / 海词英文 / 有道 / 哔哩 / 百度汉语）
  void _seedDefaultDictRules() {
    final defaults = [
      {
        'name': '海词中文',
        'urlRule': 'https://hanyu.dict.cn/{{key}}',
        'showRule': '#cy',
        'enabled': true,
        'sortNumber': 0,
      },
      {
        'name': '海词英文',
        'urlRule': 'https://apii.dict.cn/mini.php?q={{key}}',
        'showRule': 'tag.body@all',
        'enabled': true,
        'sortNumber': 1,
      },
      {
        'name': '有道',
        'urlRule': 'https://m.youdao.com/translate（POST inputtext={{key}}）',
        'showRule': '（@js 占位）',
        'enabled': true,
        'sortNumber': 2,
      },
      {
        'name': '哔哩',
        'urlRule': 'https://search.bilibili.com/all?keyword={{key}}',
        'showRule': '.search-page@all（@js 占位）',
        'enabled': true,
        'sortNumber': 3,
      },
      {
        'name': '百度汉语',
        'urlRule': 'data:;base64,{{java.base64Encode(key)}},{"type":"bd"}',
        'showRule': '（@js 占位）',
        'enabled': true,
        'sortNumber': 4,
      },
    ];
    for (final rule in defaults) {
      _dictRules.add({
        'id': _nextDictRuleId++,
        ...rule,
      });
    }
  }

  /// 书架样例资产路径（合成脱敏数据；来源与脱敏口径见
  /// assets/mock_data/README.md，结构对齐 Book 模型 & API_CONTRACT §2.2）
  static const String _bookshelfSampleAsset =
      'assets/mock_data/bookshelf_sample.json';

  Future<void>? _booksLoad;

  /// 书架样例惰性加载守卫：首次调用时从资产读取 bookshelf_sample.json，
  /// 填充 _books 与章节/正文缓存；之后各书架相关方法 await 本守卫即可
  /// （同一 Future 记忆化，并发调用只加载一次）。
  Future<void> _ensureBooksLoaded() =>
      _booksLoad ??= _loadBookshelfSample();

  /// 从资产加载书架样例并填充 _books 与章节/正文缓存
  Future<void> _loadBookshelfSample() async {
    final raw = await rootBundle.loadString(_bookshelfSampleAsset);
    final list = jsonDecode(raw) as List<dynamic>;
    _books.addAll(
      list.map((e) => Book.fromJson(e as Map<String, dynamic>)).toList(),
    );
    // 每本书生成至多 10 章（章节标题模拟真实网文目录风格）
    for (final book in _books) {
      final count = book.totalChapterNum < 10
          ? (book.totalChapterNum < 1 ? 1 : book.totalChapterNum)
          : 10;
      final chapters = <BookChapter>[];
      final contents = <int, String>{};
      for (var j = 0; j < count; j++) {
        chapters.add(
          BookChapter(
            title: '第${j + 1}章 ${_mockChapterTitles[j]}',
            bookUrl: book.bookUrl,
            url: 'mock://chapter/${book.bookUrl}/$j',
            index: j,
            start: j * 2000,
            end: (j + 1) * 2000,
          ),
        );
        contents[j] = _generateMockContent(book, j);
      }
      _chaptersCache[book.bookUrl] = chapters;
      _contentCache[book.bookUrl] = contents;
    }
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
  String _generateMockContent(Book book, int chapterIndex) {
    final paragraphs = <String>[];
    final bookName = book.name;
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
}
