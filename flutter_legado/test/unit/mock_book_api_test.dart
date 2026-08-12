import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/models/models.dart';

/// MockBookApi 全方法可调用性验证
///
/// 确保 Mock 实现的所有方法均可正常调用且返回合理数据，
/// 不抛出 UnimplementedError，UI 轨可全界面跑通。
void main() {
  late MockBookApi api;

  setUp(() {
    api = MockBookApi();
  });

  group('初始化/版本', () {
    test('initialize 不抛异常', () async {
      await api.initialize();
    });

    test('getVersion 返回 mock 版本号', () async {
      final v = await api.getVersion();
      expect(v, contains('mock'));
    });
  });

  group('书架操作', () {
    test('getBooks 返回 3 本预置书', () async {
      final books = await api.getBooks();
      expect(books.length, 3);
      expect(books[0].name, '斗破苍穹');
      expect(books[1].name, '凡人修仙传');
      expect(books[2].name, '三体');
    });

    test('addBook 添加后可获取', () async {
      final book = Book(bookUrl: 'mock://new', name: '新书', author: '测试');
      await api.addBook(book);
      final books = await api.getBooks();
      expect(books.length, 4);
    });

    test('getBook 按 URL 获取', () async {
      final book = await api.getBook('mock://book/1');
      expect(book, isNotNull);
      expect(book!.name, '斗破苍穹');
    });

    test('getBook 不存在返回 null', () async {
      final book = await api.getBook('mock://nonexist');
      expect(book, isNull);
    });

    test('deleteBook 删除后数量减少', () async {
      await api.deleteBook('mock://book/1');
      final books = await api.getBooks();
      expect(books.length, 2);
    });

    test('topBook/unTopBook 修改 order', () async {
      await api.topBook('mock://book/1');
      var book = await api.getBook('mock://book/1');
      expect(book!.order, -1);

      await api.unTopBook('mock://book/1');
      book = await api.getBook('mock://book/1');
      expect(book!.order, 0);
    });

    test('setBookGroup 修改分组', () async {
      await api.setBookGroup('mock://book/1', 5);
      final book = await api.getBook('mock://book/1');
      expect(book!.group, 5);
    });
  });

  group('书源操作', () {
    test('getBookSources 返回 3 个预置书源', () async {
      final sources = await api.getBookSources();
      expect(sources.length, 3);
    });

    test('getEnabledBookSources 只返回启用的', () async {
      final sources = await api.getEnabledBookSources();
      expect(sources.length, 2);
    });

    test('enableBookSource/disableBookSource 切换状态', () async {
      await api.disableBookSource('https://www.kaixin7days.com');
      var enabled = await api.getEnabledBookSources();
      expect(enabled.length, 1);

      await api.enableBookSource('https://www.kaixin7days.com');
      enabled = await api.getEnabledBookSources();
      expect(enabled.length, 2);
    });

    test('importBookSources 返回导入数量', () async {
      final count = await api.importBookSources('[{},{}]');
      expect(count, 2);
    });

    test('exportBookSources 返回 JSON', () async {
      final json = await api.exportBookSources();
      expect(json, contains('笔趣阁'));
    });

    // [Task #63 冻结 / #64-65 实现，#68 评审 S1/C1 语义对齐]
    // 契约 §2.3 setSourceVariable（台账 §5.11-3）
    test('setSourceVariable 写入/清除书源变量', () async {
      await api.setSourceVariable('https://www.kaixin7days.com', 'key=value');
      var sources = await api.getBookSources();
      final src =
          sources.firstWhere((s) => s.bookSourceUrl == 'https://www.kaixin7days.com');
      expect(src.variable, 'key=value');

      // 空串=清除（对齐 Rust 单列 UPDATE 语义；C1 后 variable 为非空串）
      await api.setSourceVariable('https://www.kaixin7days.com', '');
      sources = await api.getBookSources();
      final cleared =
          sources.firstWhere((s) => s.bookSourceUrl == 'https://www.kaixin7days.com');
      expect(cleared.variable, '');
    });

    // 评审 S1：书源不存在时抛错，对齐 Rust Internal 语义
    test('setSourceVariable 书源不存在时抛错', () async {
      await expectLater(
        api.setSourceVariable('https://not-exist.example.com', 'x'),
        throwsException,
      );
    });

    // 契约 §2.3 clearCookie（2026-08-12 P1-2）
    test('clearCookie 空 url 抛错，合法 url 成功', () async {
      await expectLater(api.clearCookie('  '), throwsException);
      await api.clearCookie('https://www.example.com/path');
    });
  });

  group('cURL AnalyzeUrl', () {
    test('looksLikeCurl / roundtrip 最简路径', () async {
      expect(await api.looksLikeCurl('curl -L https://example.com'), isTrue);
      expect(await api.looksLikeCurl('https://example.com'), isFalse);
      final a = await api.curlToAnalyzeUrl('curl -L https://example.com/book');
      expect(a, 'https://example.com/book');
      final c = await api.analyzeUrlToCurl(a);
      expect(c, contains('curl'));
      expect(c, contains('https://example.com/book'));
    });
  });


  group('搜索操作', () {
    test('searchBooks 返回 5 条结果', () async {
      final results = await api.searchBooks('斗破');
      expect(results.length, 5);
      expect(results[0].book.name, contains('斗破'));
    });

    test('searchMulti 返回多源结果', () async {
      final results = await api.searchMulti('测试');
      expect(results.length, 3);
    });

    test('cancelSearch 不抛异常', () async {
      await api.cancelSearch();
    });

    test('searchSource 返回换源结果', () async {
      final results = await api.searchSource('斗破苍穹', '天蚕土豆');
      expect(results.length, 3);
    });

    test('switchSource 返回新书 URL', () async {
      final url = await api.switchSource('old', 'source', 'new_url');
      expect(url, 'new_url');
    });
  });

  group('RSS 源操作', () {
    test('getRssSources 返回 4 个预置源', () async {
      final sources = await api.getRssSources();
      expect(sources.length, 4);
    });

    test('getRssArticles 每源返回 5 篇文章', () async {
      final articles = await api.getRssArticles('https://www.yuque.com/legado');
      expect(articles.length, 5);
      expect(articles[0].title, isNotEmpty);
    });
  });

  group('阅读器操作', () {
    test('getChapters 返回 10 章', () async {
      final chapters = await api.getChapters('mock://book/1');
      expect(chapters.length, 10);
    });

    test('getChapterContent 返回正文', () async {
      final content = await api.getChapterContent('mock://book/1', 0);
      expect(content, contains('斗破苍穹'));
      expect(content.length, greaterThan(100));
    });

    test('updateReadingProgress 更新进度', () async {
      await api.updateReadingProgress(
        bookUrl: 'mock://book/1',
        chapterIndex: 3,
        chapterPos: 100,
      );
      final book = await api.getBook('mock://book/1');
      expect(book!.durChapterIndex, 3);
      expect(book.durChapterPos, 100);
    });

    test('refreshToc 返回章节列表', () async {
      final chapters = await api.refreshToc('mock://book/1', 'mock://source/1');
      expect(chapters.length, 10);
    });
  });

  group('配置操作', () {
    test('setConfig/getConfig 读写一致', () async {
      await api.setConfig('key1', 'value1');
      final v = await api.getConfig('key1');
      expect(v, 'value1');
    });

    test('deleteConfig 删除后返回 null', () async {
      await api.setConfig('key2', 'value2');
      await api.deleteConfig('key2');
      final v = await api.getConfig('key2');
      expect(v, isNull);
    });

    test('getAllConfigs 返回所有配置', () async {
      await api.setConfig('a', '1');
      await api.setConfig('b', '2');
      final all = await api.getAllConfigs();
      expect(all['a'], '1');
      expect(all['b'], '2');
    });
  });

  group('书签操作', () {
    test('addBookmark/getBookmarks 读写一致', () async {
      final bm = Bookmark(
        bookName: '斗破苍穹',
        bookAuthor: '天蚕土豆',
        chapterIndex: 1,
        chapterPos: 50,
        chapterName: '第2章',
        bookText: '测试文本',
        content: '测试备注',
      );
      await api.addBookmark(bm);
      final list = await api.getBookmarks('斗破苍穹');
      expect(list.length, 1);
      expect(list[0].content, '测试备注');
    });

    // [Task #65] 契约 §2.7 getBookmarksByBook（台账 §5.14-2）
    test('getBookmarksByBook 按书名+作者双键过滤', () async {
      await api.addBookmark(Bookmark(
        bookName: '斗破苍穹',
        bookAuthor: '天蚕土豆',
        chapterIndex: 1,
        chapterPos: 50,
        chapterName: '第2章',
        bookText: '',
        content: '命中',
      ));
      // 同名不同作者不得混入（对齐原版 bookmarkDao.getByBook）
      await api.addBookmark(Bookmark(
        bookName: '斗破苍穹',
        bookAuthor: '同名作者',
        chapterIndex: 0,
        chapterPos: 0,
        chapterName: '干扰项',
        bookText: '',
        content: '',
      ));
      final hit = await api.getBookmarksByBook('斗破苍穹', '天蚕土豆');
      expect(hit.length, 1);
      expect(hit[0].content, '命中');
      final miss = await api.getBookmarksByBook('斗破苍穹', '不存在的作者');
      expect(miss, isEmpty);
    });

    test('deleteBookmark 删除后为空', () async {
      final bm = Bookmark(bookName: '测试', bookAuthor: '', chapterIndex: 0, chapterPos: 0, chapterName: '', bookText: '', content: '');
      final added = await api.addBookmark(bm);
      await api.deleteBookmark(added.id);
      final list = await api.getAllBookmarks();
      expect(list, isEmpty);
    });
  });

  group('替换规则操作', () {
    test('addReplaceRule/getReplaceRules 读写一致', () async {
      final rule = ReplaceRule(name: '测试规则', pattern: 'a', replacement: 'b');
      await api.addReplaceRule(rule);
      final rules = await api.getReplaceRules();
      expect(rules.length, 1);
      expect(rules[0].name, '测试规则');
    });
  });

  group('书籍分组', () {
    test('getBookGroups 返回预置分组', () async {
      final groups = await api.getBookGroups();
      expect(groups.length, 1);
      expect(groups[0].groupName, '科幻');
    });

    test('addBookGroup 添加后可获取', () async {
      await api.addBookGroup(BookGroup(groupName: '玄幻', order: 1));
      final groups = await api.getBookGroups();
      expect(groups.length, 2);
    });
  });

  group('搜索历史', () {
    test('addSearchKeyword/getSearchHistory 读写一致', () async {
      await api.addSearchKeyword('斗破', '斗破苍穹');
      final history = await api.getSearchHistory();
      expect(history.length, 1);
      expect(history[0].word, '斗破');
    });

    test('clearSearchHistory 清空', () async {
      await api.addSearchKeyword('test', '');
      await api.clearSearchHistory();
      final history = await api.getSearchHistory();
      expect(history, isEmpty);
    });
  });

  group('缓存管理', () {
    test('getCacheSize 返回正数', () async {
      final size = await api.getCacheSize();
      expect(size, greaterThan(0));
    });

    test('clearCache 不抛异常', () async {
      await api.clearCache();
    });
  });

  group('阅读统计', () {
    test('getTodayReadingStats 返回合理数据', () async {
      final stats = await api.getTodayReadingStats();
      expect(stats.totalSeconds, greaterThan(0));
      expect(stats.bookCount, greaterThan(0));
    });

    test('getDailyReadingStats 返回指定天数', () async {
      final stats = await api.getDailyReadingStats(days: 7);
      expect(stats.length, 7);
    });
  });

  group('HTTP TTS', () {
    test('addHttpTts/getHttpTts 读写一致', () async {
      await api.addHttpTts(HttpTts(name: '测试引擎', url: 'http://tts.example.com'));
      final list = await api.getHttpTts();
      // 预置 2 个真实 TTS 引擎 + 新增 1 个
      expect(list.length, 3);
      expect(list.last.name, '测试引擎');
    });

    test('预置 TTS 引擎来自 Android 真实样本', () async {
      final list = await api.getHttpTts();
      expect(list.length, 2);
      expect(list[0].name, '1.百度');
      expect(list[0].contentType, 'audio/wav');
      expect(list[1].name, '2.阿里云语音');
      expect(list[1].contentType, 'audio/mpeg');
    });
  });

  group('下载管理器', () {
    test('downloadAddTask 返回任务 ID', () async {
      final id = await api.downloadAddTask(
        bookUrl: 'mock://book/1',
        chapterUrl: 'mock://ch/1',
        chapterTitle: '第1章',
        chapterIndex: 0,
      );
      expect(id, isNotEmpty);
    });

    test('downloadGetStats 返回 JSON', () async {
      final stats = await api.downloadGetStats();
      expect(stats, contains('total'));
    });
  });

  group('WebDAV 云同步', () {
    test('webdavListDir 返回 JSON', () async {
      final result = await api.webdavListDir('{}', '/');
      expect(result, isNotEmpty);
    });

    test('webdavFullSync 返回成功', () async {
      final result = await api.webdavFullSync('{}', '/books', '/sources');
      expect(result, contains('synced'));
    });
  });

  group('自动任务', () {
    test('autoTaskBuildBookUpdateTask 返回任务', () async {
      final task = await api.autoTaskBuildBookUpdateTask(
        bookUrl: 'mock://book/1',
        bookName: '斗破苍穹',
        bookAuthor: '天蚕土豆',
        name: '更新任务',
      );
      expect(task['name'], '更新任务');
      expect(task['cron'], isNotEmpty);
    });

    test('autoTaskNormalizeScript 去除前缀', () async {
      final result = await api.autoTaskNormalizeScript(script: '@js:alert(1)');
      expect(result, 'alert(1)');
    });

    test('autoTaskNextDueAt 返回未来时间', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final next = await api.autoTaskNextDueAt(cron: '0 0 8 * * *', fromMs: now);
      expect(next, greaterThan(now));
    });
  });

  group('压缩包导入', () {
    test('archiveIsArchive 正确判断', () async {
      expect(await api.archiveIsArchive(filePath: 'test.zip'), true);
      expect(await api.archiveIsArchive(filePath: 'test.rar'), true);
      expect(await api.archiveIsArchive(filePath: 'test.txt'), false);
    });

    test('archiveListZipFiles 返回文件列表', () async {
      final files = await api.archiveListZipFiles(zipPath: 'test.zip');
      expect(files, isNotEmpty);
    });

    test('archiveDetectEncoding 返回编码信息', () async {
      final result = await api.archiveDetectEncoding(filePath: 'test.txt');
      expect(result['encoding'], 'UTF-8');
    });
  });

  group('发现页操作', () {
    test('exploreParseUrl 解析分类', () async {
      final categories = await api.exploreParseUrl('玄幻::http://a.com\n都市::http://b.com');
      expect(categories.length, 2);
      expect(categories[0].title, '玄幻');
    });

    test('exploreFetchBooks 返回书籍列表', () async {
      final books = await api.exploreFetchBooks('{}', 'http://a.com', 1);
      expect(books.length, 10);
    });
  });

  group('书籍导出', () {
    test('bookExport 返回成功', () async {
      final result = await api.bookExport(
        bookUrl: 'mock://book/1',
        format: 'txt',
        includeToc: true,
      );
      expect(result['success'], true);
      expect(result['file_name'], contains('斗破苍穹'));
    });

    test('bookExportInfo 返回预览信息', () async {
      final result = await api.bookExportInfo(
        bookUrl: 'mock://book/1',
        format: 'txt',
      );
      expect(result['success'], true);
      expect(result['chapter_count'], '10');
    });
  });

  group('音频播放模式', () {
    test('audioWithPlayMode 写入配置', () async {
      final result = await api.audioWithPlayMode(playMode: 2);
      expect(result, contains('"audioPlayMode":2'));
    });

    test('audioResolvePlayBook 解析书籍', () async {
      final result = await api.audioResolvePlayBook(requestedBookUrl: 'mock://book/1');
      expect(result, isNotNull);
      expect(result!['name'], '斗破苍穹');
    });
  });

  group('服务器管理', () {
    test('startServer/getServerStatus 状态一致', () async {
      await api.startServer(port: 8080);
      final status = await api.getServerStatus();
      expect(status, contains('running'));
      expect(status, contains('8080'));
    });

    test('stopServer 停止后状态为 stopped', () async {
      await api.startServer();
      await api.stopServer();
      final status = await api.getServerStatus();
      expect(status, 'stopped');
    });
  });

  group('用户管理', () {
    test('userLogin 返回 true', () async {
      final result = await api.userLogin(username: 'test', password: '123');
      expect(result, true);
    });

    test('getUsers 返回空列表', () async {
      final users = await api.getUsers();
      expect(users, isEmpty);
    });
  });

  group('应用日志', () {
    // [审计修复 §1.2] appLog* 五方法可调用性验证 — QoderCN
    test('appLogPush/appLogList 读写一致且最新在前', () async {
      await api.appLogPush(level: 'message', message: '第一条');
      await api.appLogPush(level: 'message', message: '第二条');
      final json = await api.appLogList(level: 'message');
      expect(json, contains('第二条'));
      expect(json.indexOf('第二条'), lessThan(json.indexOf('第一条')));
    });

    test('空消息短路不入列', () async {
      await api.appLogPush(level: 'message', message: '');
      final json = await api.appLogList(level: 'message');
      expect(json, '[]');
    });

    test('appLogClear 只清指定级别', () async {
      await api.appLogPush(level: 'message', message: 'a');
      await api.appLogPush(level: 'http', message: 'b');
      await api.appLogClear(level: 'message');
      expect(await api.appLogList(level: 'message'), '[]');
      expect(await api.appLogList(level: 'http'), contains('b'));
    });

    test('appLogClearAll 清空全部', () async {
      await api.appLogPush(level: 'message', message: 'a');
      await api.appLogPush(level: 'crash', message: 'b');
      await api.appLogClearAll();
      expect(await api.appLogList(level: 'message'), '[]');
      expect(await api.appLogList(level: 'crash'), '[]');
    });

    test('appLogExport 时间升序导出', () async {
      await api.appLogPush(level: 'message', message: '第一条');
      await api.appLogPush(level: 'http', message: '第二条');
      final text = await api.appLogExport();
      expect(text, contains('[message] 第一条'));
      expect(text.indexOf('第一条'), lessThan(text.indexOf('第二条')));
    });
  });

  group('段评/章评', () {
    test('reviewAdd 返回 ID', () async {
      final id = await api.reviewAdd(
        bookUrl: 'mock://book/1',
        chapterIndex: 0,
        content: '好文章',
      );
      expect(id, greaterThan(0));
    });

    test('reviewGetByChapter 返回 JSON 数组', () async {
      final result = await api.reviewGetByChapter('mock://book/1', 0);
      expect(result, '[]');
    });
  });
}
