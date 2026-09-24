// 视角 C：阅读主流程「失败与边界」缺陷猎捕 —— 红态复现用例
//
// 本文件**故意断言「本应成立的不变量」**：当前实现不满足 → 用例红。
// 红 = 缺陷复现证据（不是新测试写错）。严禁为了让本文件变绿而改生产代码。
//
// 覆盖（视角 C 场景 1/2/4/8 的 Dart 侧）：
// - C1a 打开新书失败时，ReaderState 里仍是**上一本书**的目录/正文 →
//      「error != null && chapterContent.isEmpty」的全屏错误页门槛失效
//      （reader_page_view.dart），用户看到的既不是新书内容、也没有任何
//      错误提示（旧书正文冒充新书正文渲染）。
// - C1b 前后两次 openBook 并发（A 慢 / B 快）→ 无「书标识/代际」守卫，
//      先发起的 A 的迟到结果覆盖已打开 B 的状态：目录/正文/章节索引互相
//      串书（B 的标题 + A 的目录 + 按 A 索引取的 B 正文）。
//
// 对齐口径依据：原版 ReadBook.resetData(book) 在每次开书时执行
// clearTextChapter()（清空上一本书的正文缓存）并重置 chapterSize；
// 本项目 openBook 未做任何「换书即清空」处理，也没有身份守卫。

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';

import '../mocks/mocks.dart';

const bookA = Book(
  bookUrl: 'https://book.com/A',
  name: 'A书',
  author: '作者A',
  origin: 'https://source-a.com',
  originName: '源A',
  durChapterIndex: 0,
);

const bookB = Book(
  bookUrl: 'https://book.com/B',
  name: 'B书',
  author: '作者B',
  origin: 'https://source-b.com',
  originName: '源B',
  durChapterIndex: 0,
);

const chaptersA = [
  BookChapter(url: 'https://book.com/A/c1', title: 'A-第一章', index: 0),
  BookChapter(url: 'https://book.com/A/c2', title: 'A-第二章', index: 1),
  BookChapter(url: 'https://book.com/A/c3', title: 'A-第三章', index: 2),
  BookChapter(url: 'https://book.com/A/c4', title: 'A-第四章', index: 3),
];

const chaptersB = [
  BookChapter(url: 'https://book.com/B/c1', title: 'B-第一章', index: 0),
  BookChapter(url: 'https://book.com/B/c2', title: 'B-第二章', index: 1),
];

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi mockApi;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({'enableReadRecord': false});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  ReaderState readState() => container.read(readerNotifierProvider);
  ReaderNotifier readNotifier() =>
      container.read(readerNotifierProvider.notifier);

  void stubProgress() {
    when(
      () => mockApi.updateReadingProgress(
        bookUrl: any(named: 'bookUrl'),
        chapterIndex: any(named: 'chapterIndex'),
        chapterPos: any(named: 'chapterPos'),
      ),
    ).thenAnswer((_) async {});
  }

  /// 目录按 bookUrl 返回；正文返回「<书标签>-CH<index>」
  void stubPerBook({
    Duration Function(String bookUrl)? tocDelay,
  }) {
    when(() => mockApi.getChapters(any())).thenAnswer((invocation) async {
      final url = invocation.positionalArguments[0] as String;
      if (tocDelay != null) {
        final d = tocDelay(url);
        if (d > Duration.zero) await Future.delayed(d);
      }
      if (url == bookA.bookUrl) return chaptersA;
      if (url == bookB.bookUrl) return chaptersB;
      return const <BookChapter>[];
    });
    when(() => mockApi.getChapterContentFull(any(), any())).thenAnswer((
      invocation,
    ) async {
      final url = invocation.positionalArguments[0] as String;
      final idx = invocation.positionalArguments[1] as int;
      final tag = url == bookA.bookUrl ? 'A' : (url == bookB.bookUrl ? 'B' : '?');
      return '$tag-CH$idx';
    });
  }

  // ==========================================================================
  // C1a 打开新书失败：上一本的目录/正文残留 → 无可见错误、错内容渲染
  // ==========================================================================

  group('C1a 换书失败残留（跨书正文/目录泄漏）', () {
    test('[C1a] 打开 B 书目录抓取失败时不得残留 A 书正文与目录', () async {
      stubProgress();
      stubPerBook();
      final notifier = readNotifier();

      // 1) A 书正常打开并读到正文
      await notifier.openBook(bookA);
      expect(readState().chapterContent, 'A-CH0', reason: '基线：A 书正文已就绪');
      expect(readState().chapters.length, 4, reason: '基线：A 书 4 章');

      // 2) 打开 B 书时目录抓取失败（断网 / 源失效 / 书被删后 toc 丢失）
      when(() => mockApi.getChapters(any())).thenAnswer((invocation) async {
        final url = invocation.positionalArguments[0] as String;
        if (url == bookB.bookUrl) {
          throw StateError('Network error: 抓取目录失败（模拟断网）');
        }
        return chaptersA;
      });
      await notifier.openBook(bookB);

      final st = readState();
      expect(st.currentBook!.bookUrl, bookB.bookUrl, reason: '基线：B 书已就位');
      expect(st.error, isNotNull, reason: '基线：B 书目录抓取失败已置 error');

      // 缺陷断言 1：A 书正文残留。reader_page_view.build 的全屏错误门槛是
      // 「error != null && chapterContent.isEmpty」，正文非空 → 不显示错误页，
      // 用户看到的是**A 书正文**配 **B 书书名**，且没有任何失败提示。
      expect(
        st.chapterContent,
        isEmpty,
        reason:
            '打开 B 书失败后 chapterContent 仍是上一本书的正文「${st.chapterContent}」'
            '（openBook 未清空旧数据；原版 ReadBook.resetData → clearTextChapter 会清）'
            '→ 阅读页既不报错也不显示 B 书内容，渲染的是 A 书正文',
      );

      // 缺陷断言 2：A 书目录残留 → 目录页显示 A 书章节，翻页/定位按 A 书目录走
      expect(
        st.chapters,
        isEmpty,
        reason:
            '打开 B 书失败后 chapters 仍是 A 书目录（${st.chapters.map((c) => c.title).toList()}）'
            '→ 目录入口显示错误书籍章节，goToChapter 会在 A 书索引上加载 B 书正文',
      );
    });
  });

  // ==========================================================================
  // C1b 并发开书串书（A 慢 / B 快）
  // ==========================================================================

  group('C1b 并发开书（无书标识守卫）', () {
    test('[C1b] 先发起 A（慢）后打开 B（快）时不得串书', () async {
      stubProgress();
      // A 书目录慢（模拟弱网），B 书目录快
      stubPerBook(
        tocDelay: (url) => url == bookA.bookUrl
            ? const Duration(milliseconds: 80)
            : Duration.zero,
      );
      final notifier = readNotifier();

      // UI 真实形态：各入口 `read(readerNotifierProvider.notifier).openBook(x)`
      // 均不 await（bookshelf_screen/home_tab_screen/offline_cache_screen），
      // 用户点 A 后立刻返回再点 B 即产生两次并发 openBook。
      final first = notifier.openBook(bookA);
      final second = notifier.openBook(bookB);
      await Future.wait([first, second]);

      final st = readState();
      expect(st.currentBook!.bookUrl, bookB.bookUrl, reason: '基线：最后打开的是 B 书');

      // 缺陷断言：A 的迟到结果覆盖了 B 的状态
      expect(
        st.chapters.map((c) => c.title).toList(),
        chaptersB.map((c) => c.title).toList(),
        reason:
            '当前书籍 = B（${st.currentBook!.name}），但目录却是 '
            '${st.chapters.map((c) => c.title).toList()}'
            '（= A 书目录，A 的 openBook 迟到写入）；'
            '随后 _loadChapterContent 用 A 书的索引去取 B 书正文 → '
            '标题（B 章）与正文（B 书另一章/或 A 索引越界）错配',
      );
      expect(
        st.chapterContent,
        startsWith('B-CH'),
        reason:
            'A 书 openBook 收尾时按自身 index=${st.currentChapterIndex} 取正文，'
            '而 state.currentBook 已是 B → 正文来自 B 书却对应 A 的章节索引；'
            '实测 chapterContent=${st.chapterContent}',
      );
    });
  });

  // ==========================================================================
  // C2 「刷新正文」失败 → 整书离线缓存已先被清空（不可回滚）
  // ==========================================================================

  group('C2 刷新正文失败导致整书离线缓存丢失', () {
    test('[C2] 刷新正文抓取失败后，原已缓存章节不得丢失', () async {
      stubProgress();
      stubPerBook();
      // 模拟 cached_chapters 存储：A 书已缓存 3 章
      final cache = <String>{'A/c1', 'A/c2', 'A/c3'};
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async {
        final n = cache.length;
        cache.clear(); // Rust clearBookCache 为书级 DELETE
        return n;
      });
      // 断网：强制联网重抓失败
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => throw StateError('Network error: 断网'));

      final notifier = readNotifier();
      await notifier.openBook(bookA);

      final err = await notifier.refreshChapterContent();
      expect(err, isNotNull, reason: '基线：失败原因已返回（UI 侧有 SnackBar 提示）');
      expect(
        readState().chapterContent,
        'A-CH0',
        reason: '基线：旧正文保留（F4 修法，不降级为错误页）',
      );

      expect(
        cache,
        isNotEmpty,
        reason:
            '刷新失败后 cached_chapters 已被清空且无回滚：refreshChapterContent 先 '
            'clearBookCache(整书) 再联网抓取（reader_notifier.dart:488-495），'
            '抓取失败时缓存不回填 → 用户既没拿到新正文，又丢掉整本书的离线缓存；'
            '此后离线翻到任何已缓存章节都会抓取失败（原版 refreshContentDur 只 '
            'delContent 当前章）。当前 cache=${cache.toList()}',
      );
    });
  });
}
