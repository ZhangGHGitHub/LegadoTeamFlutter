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
  final Map<String, String> _configs = {};
  final Map<String, List<BookChapter>> _chaptersCache = {};
  final Map<String, Map<int, String>> _contentCache = {};
  // 登录凭据内存态（sourceLogin 手动登录/登录缓存，USE_MOCK 开发模式用）
  final Map<String, String> _mockLoginInfo = {};
  final Map<String, String> _mockLoginHeader = {};

  int _nextId = 1;


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
        coverUrl:
            'https://www.biquge.com.cn/files/article/image/6/6909/6909s.jpg',
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
        tocUrl:
            'https://www.kaixin7days.com/book-service/bookMgt/getAllChapterByBookId',
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
        chapters.add(
          BookChapter(
            title: '第${j + 1}章 ${_mockChapterTitles[j]}',
            bookUrl: bookUrl,
            url: 'mock://chapter/$bookUrl/$j',
            index: j,
            start: j * 2000,
            end: (j + 1) * 2000,
          ),
        );
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

    // 默认分组
    _bookGroups.add(
      BookGroup(groupId: 1, groupName: '科幻', order: 0, show: true),
    );
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
}
