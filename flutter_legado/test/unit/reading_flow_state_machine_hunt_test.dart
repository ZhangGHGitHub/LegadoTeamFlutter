// 视角 A：阅读主流程「状态机 / 生命周期」缺陷猎捕 —— 红态复现用例
//
// 本文件**故意断言「本应成立的不变量」**：当前实现不满足 → 用例红。
// 红 = 缺陷复现证据（不是新测试写错）。严禁为了让本文件变绿而改生产代码。
//
// 覆盖：
// - F1 ReaderState.currentBook 的进度字段在阅读过程中从不更新（_saveProgress
//      只写库不回写 state）。currentBook 是下列调用点的「权威快照」：
//      reader_page_view.dart ErrorView.onRetry → notifier.openBook(book)；
//      reader_top_bar.dart:364-369 _updateBookConfig → api.updateBook(updated)；
//      reader_screen._doAutoChangeSource → notifier.openBook(updated)；
//      reader_screen._openToc → TocScreen(arguments: book)。
// - F2 章级加载无序列守卫：连续翻章（快速连点/自动翻页与手动叠加）时旧章的
//      迟到正文覆盖新章正文 → 章标与正文错配。
// - F4 章级加载错误态粘滞：一次加载失败后，后续成功的章加载不会清除 error，
//     阅读页（reader_page_view build: error != null 分支）永久停在 ErrorView。
// - F6 prevChapter 的 -1 章内位置哨兵被持久化写入 DB。

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';

import '../mocks/mocks.dart';

const testBook = Book(
  bookUrl: 'https://book.com/1',
  name: '测试书籍',
  author: '作者',
  origin: 'https://source-a.com',
  originName: '源A',
  durChapterIndex: 0,
);

const testChapters = [
  BookChapter(url: 'https://book.com/1/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/1/c2', title: '第二章', index: 1),
  BookChapter(url: 'https://book.com/1/c3', title: '第三章', index: 2),
  BookChapter(url: 'https://book.com/1/c4', title: '第四章', index: 3),
];

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi mockApi;
  late ProviderContainer container;

  setUp(() {
    // 关闭阅读时长记录：本文件聚焦进度/正文状态，避免无关的
    // getReadRecords / putReadRecord 调用干扰
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

  /// 基础桩：目录 + 进度写入（正文按用例单独 stub）
  void stubBase() {
    when(
      () => mockApi.getChapters(any()),
    ).thenAnswer((_) async => testChapters);
    when(
      () => mockApi.updateReadingProgress(
        bookUrl: any(named: 'bookUrl'),
        chapterIndex: any(named: 'chapterIndex'),
        chapterPos: any(named: 'chapterPos'),
      ),
    ).thenAnswer((_) async {});
  }

  /// 正文按章返回 CH<index>（可指定某些章延迟/抛错）
  void stubContent({
    Duration Function(int index)? delay,
    bool Function(int index)? fail,
  }) {
    when(() => mockApi.getChapterContentFull(any(), any())).thenAnswer((
      invocation,
    ) async {
      final idx = invocation.positionalArguments[1] as int;
      if (delay != null) {
        final d = delay(idx);
        if (d > Duration.zero) await Future.delayed(d);
      }
      if (fail != null && fail(idx)) {
        throw StateError('抓取失败：第 $idx 章');
      }
      return 'CH$idx';
    });
  }

  // ==========================================================================
  // F1 陈旧状态：currentBook 进度字段不随阅读推进更新
  // ==========================================================================

  group('F1 陈旧状态 / currentBook 进度快照', () {
    test('[F1a] 翻章后 currentBook.durChapterIndex/Title 应同步为当前章', () async {
      stubBase();
      stubContent();
      final notifier = readNotifier();
      await notifier.openBook(testBook);
      await notifier.nextChapter();
      await notifier.nextChapter();

      final st = readState();
      expect(st.currentChapterIndex, 2, reason: '基线：确实翻到了第三章');

      // 缺陷断言：currentBook 是「重试 / 回写 DB / 目录定位」的权威快照，
      // 却仍是打开时的进度。
      expect(
        st.currentBook!.durChapterIndex,
        2,
        reason:
            'currentBook.durChapterIndex 仍为 0（打开时值）——'
            'reader_top_bar._updateBookConfig 会用该陈旧对象 updateBook，'
            '而 Rust BookRepository::update 是 37 列全行 UPDATE（含 '
            'durChapterIndex=?21/durChapterPos=?24/durChapterTitle=?20）',
      );
      expect(
        st.currentBook!.durChapterTitle,
        '第三章',
        reason: 'currentBook.durChapterTitle 同样滞留打开时值',
      );
    });

    test('[F1b] 章加载失败后「重试」不得回退到打开时的章节', () async {
      stubBase();
      stubContent();
      final notifier = readNotifier();
      await notifier.openBook(testBook);
      await notifier.nextChapter();
      await notifier.nextChapter();
      expect(readState().currentChapterIndex, 2);

      // 复刻 reader_page_view.dart:651-657 ErrorView.onRetry 的真实取数：
      //   final book = state.currentBook;  notifier.openBook(book)
      final retryBook = readState().currentBook!;
      await notifier.openBook(retryBook);

      expect(
        readState().currentChapterIndex,
        2,
        reason:
            '重试把用户从第三章扔回第一章（durChapterIndex 陈旧为 0）；'
            '随后任何一次进度保存（PopScope.saveProgress）都会把库里'
            '进度真正改写成 0 —— 阅读位置丢失',
      );
    });

    test('[F1c] 阅读中改书籍设置时不得把陈旧进度写回 DB', () async {
      stubBase();
      stubContent();
      final notifier = readNotifier();
      await notifier.openBook(testBook);
      await notifier.nextChapter();
      await notifier.nextChapter();

      Book? written;
      when(() => mockApi.updateBook(any())).thenAnswer((invocation) async {
        written = invocation.positionalArguments.first as Book;
      });

      // 复刻 reader_top_bar.dart:364-369 _updateBookConfig 的真实取数方式：
      //   final book = ref.read(readerNotifierProvider).currentBook;
      //   await api.updateBook(book.copyWith(readConfig: transform(...)));
      final snapshot = readState().currentBook!;
      await mockApi.updateBook(
        snapshot.copyWith(
          readConfig: const ReadConfig(useReplaceRule: false),
        ),
      );

      expect(
        written!.durChapterIndex,
        2,
        reason: '送进 DB 的快照带的是打开时进度（0）→ 全行 UPDATE 覆盖库内进度',
      );
      expect(written!.durChapterTitle, '第三章');
    });
  });

  // ==========================================================================
  // F2 并发/竞态：连续翻章 → 旧章正文覆盖新章正文
  // ==========================================================================

  group('F2 章级加载竞态', () {
    test('[F2] 连点下一章不得出现「章标第三章 / 正文第二章」错配', () async {
      stubBase();
      // 第 1 章慢、第 2 章快 → 后发先至，先到的旧章正文后写
      stubContent(delay: (i) => i == 1 ? const Duration(milliseconds: 60) : Duration.zero);

      final notifier = readNotifier();
      await notifier.openBook(testBook);
      expect(readState().chapterContent, 'CH0');

      // UI 侧真实调用形态：ReaderTurnView._applyCompleted →
      // notifier.nextChapter()（unawaited，无节流/无 in-flight 守卫）
      final first = notifier.nextChapter();
      final second = notifier.nextChapter();
      await Future.wait([first, second]);

      final st = readState();
      expect(st.currentChapterIndex, 2, reason: '基线：索引已推进到第三章');
      expect(
        st.chapterContent,
        'CH2',
        reason:
            '当前章索引=2 但 chapterContent 是第 1 章正文（_loadChapterContent '
            '无序列守卫，迟到结果直接覆盖 state）→ 用户看到「第三章」标题配'
            '第二章正文，进度也按第三章保存',
      );
      expect(st.currentChapter?.title, '第三章');
    });
  });

  // ==========================================================================
  // F4 静默/粘滞错误态：成功加载不清 error
  // ==========================================================================

  group('F4 错误态粘滞', () {
    test('[F4] 章级成功加载必须清除上一次的 error（否则正文已就绪仍全屏报错）', () async {
      stubBase();
      stubContent(fail: (i) => i == 0);

      final notifier = readNotifier();
      await notifier.openBook(testBook);
      expect(readState().error, isNotNull, reason: '基线：第 0 章抓取失败');
      expect(readState().chapterContent, isEmpty);

      // 用户在目录里选第 1 章（reader_screen._openToc → goToChapter）
      await notifier.goToChapter(1);

      final st = readState();
      expect(st.chapterContent, 'CH1', reason: '基线：第 1 章正文已加载成功');
      expect(
        st.error,
        isNull,
        reason:
            'error 未被成功的章加载清除 → reader_page_view.build 的 '
            'error != null 分支优先于正文渲染，正文已就绪但用户永久停在 '
            'ErrorView（唯一出路「重试」还会按 F1b 回退章节）',
      );
    });
  });

  // ==========================================================================
  // F6 进度语义：-1 哨兵被持久化
  // ==========================================================================

  group('F6 进度语义 / 哨兵值入库', () {
    test('[F6] 上一章跳末页的 -1 哨兵不得作为 chapterPos 写库', () async {
      stubBase();
      stubContent();
      final savedPositions = <int>[];
      when(
        () => mockApi.updateReadingProgress(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
          chapterPos: any(named: 'chapterPos'),
        ),
      ).thenAnswer((invocation) async {
        savedPositions
            .add(invocation.namedArguments[#chapterPos] as int);
      });

      final notifier = readNotifier();
      // 打开时定位到第 1 章，使 prevChapter 可用
      await notifier.openBook(testBook.copyWith(durChapterIndex: 1));
      await notifier.prevChapter();

      expect(
        savedPositions.contains(-1),
        isFalse,
        reason:
            'prevChapter 在 resetChapterPos（由 ReaderPageView 分页后延迟调用）'
            '之前就 _saveProgress()，把 -1 哨兵写入 DB（Rust '
            'update_reading_progress 不做钳制，直接写 durChapterPos）；'
            '实测写入序列：$savedPositions',
      );
    });
  });
}
