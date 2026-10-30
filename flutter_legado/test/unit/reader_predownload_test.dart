// 批9a 项8：预下载（preDownloadNum）轻量预取测试
//
// 语义钉住（对齐参考版 ReadBook.preDownload / CacheBook 失败计数）：
// - 翻章成功后向后预取 [cur+1, cur+N] 窗口（getChapterContentFull 落盘
//   链路见 rust/legado-ffi/src/api/reader.rs fetch_chapter_content_inner
//   → save_chapter_cache → CacheBookRepository.insert）；
// - 0 = 关闭（不发起预取调用）；
// - 本地书不预取；
// - 失败静默（不影响当前章状态），单章连续失败 3 次后本会话不再重试
//   （对齐原版 CacheBook.kt:290 计数 / ReadBook.kt:1889 >= 3 门）；
// - 换书清空去重/失败表并作废旧队列（P1-1：Notifier 全局单例，残留表
//   会静默跳过新书同索引章；P2-2：代际 token）；
// - 串行泵：同刻至多 1 个在途预取请求（P2-2，对齐原版 Semaphore(2)
//   限流意图）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(const ReadRecord());
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpInit() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  /// 等预取串行泵排空（每章：出队 + Full 调用 microtask 链）
  Future<void> pumpPredownload({int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ReaderNotifier readNotifier() =>
      container.read(readerNotifierProvider.notifier);

  final onlineBook = Book(
    bookUrl: 'https://book.com/1',
    name: '在线书',
    origin: 'https://source.com',
    bookType: BookType.text,
    durChapterIndex: 0,
  );

  final bookB = Book(
    bookUrl: 'https://book.com/2',
    name: 'B书',
    origin: 'https://source.com',
    bookType: BookType.text,
    durChapterIndex: 0,
  );

  void stubOpenBook({int chapterCount = 6}) {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => List.generate(
        chapterCount,
        (i) => BookChapter(title: '第${i + 1}章', index: i),
      ),
    );
    when(() => mockApi.getChapterContentFull(any(), any()))
        .thenAnswer((_) async => '正文');
    when(() => mockApi.updateReadingProgress(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
          chapterPos: any(named: 'chapterPos'),
        )).thenAnswer((_) async {});
    when(() => mockApi.putReadRecord(
          any(),
          bookUrl: any(named: 'bookUrl'),
        )).thenAnswer((_) async => true);
  }

  group('preDownloadNum 预下载', () {
    test('默认 10：翻章成功后预取后续章节（窗口内调用 Full 链路）', () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues(
          {PrefKeys.preDownloadNum: 2});
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      // 翻到下一章（索引 1）→ 预取 [2, 3]
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      await readNotifier().nextChapter();
      await pumpPredownload();

      verify(() => mockApi.getChapterContentFull(any(), 2)).called(1);
      verify(() => mockApi.getChapterContentFull(any(), 3)).called(1);
      // 窗口外（cur+3=4）不预取
      verifyNever(() => mockApi.getChapterContentFull(any(), 4));
    });

    test('0 = 关闭：不发起任何预取调用', () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues({PrefKeys.preDownloadNum: 0});
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      // 清空 openBook 期间的当前章调用记录，仅统计预取
      clearInteractions(mockApi);
      await readNotifier().nextChapter();
      await pumpPredownload();

      // nextChapter 自身取当前章 1 次；预取窗口调用应为 0
      verifyNever(() => mockApi.getChapterContentFull(any(), 2));
      verifyNever(() => mockApi.getChapterContentFull(any(), 3));
    });

    test('本地书不预取（参考版 book?.isLocal == true 直接 return）', () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues({PrefKeys.preDownloadNum: 3});
      const localBook = Book(
        bookUrl: 'file:///books/本地.txt',
        name: '本地书',
        origin: 'loc_book',
        bookType: BookType.local | BookType.text,
        durChapterIndex: 0,
      );
      await readNotifier().openBook(localBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      clearInteractions(mockApi);
      await readNotifier().nextChapter();
      await pumpPredownload();

      verifyNever(() => mockApi.getChapterContentFull(any(), 2));
      verifyNever(() => mockApi.getChapterContentFull(any(), 3));
    });

    test('预取失败静默：不影响当前章正文与错误状态', () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues({PrefKeys.preDownloadNum: 2});
      // 预取目标章抛异常
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((inv) async {
        final index = inv.positionalArguments[1] as int;
        if (index >= 2) throw StateError('网络失败');
        return '当前章正文';
      });
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      await readNotifier().nextChapter();
      await pumpPredownload();

      expect(readNotifier().state.error, isNull,
          reason: '预取失败必须静默（异常路径吞掉）');
      expect(readNotifier().state.chapterContent, '当前章正文');
    });

    test('不重复：同章同会话恰好预取 1 次（equals(1)）', () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues(
          {PrefKeys.preDownloadNum: 4});
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      await readNotifier().nextChapter(); // cur=1 → 预取 [2..5]
      await pumpPredownload();
      // 立即再翻一章（cur=2 → 预取 [3..6∩5]）；章 3/4 已在上批记录
      await readNotifier().nextChapter();
      await pumpPredownload();

      // P2-4：精确 1 次——成功章去重语义（同会话内同章只抓一次）
      verify(() => mockApi.getChapterContentFull(any(), 3)).called(1);
      verify(() => mockApi.getChapterContentFull(any(), 4)).called(1);
      // 章 5 仅在第一批窗口内（cur=2 窗口 [3..5]∩去重 → 不重抓）
      verify(() => mockApi.getChapterContentFull(any(), 5)).called(1);
      // 窗口外（章 6 是当前章自身加载，不属于预取断言范围）
      verifyNever(() => mockApi.getChapterContentFull(any(), 7));
    });

    test('P1-1 换书清空去重表：A 书预取后换 B 书，B 书同索引章仍会预取（红→绿）',
        () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues({PrefKeys.preDownloadNum: 2});
      // A 书：打开（预取当前章 0 的窗口 [1,2]）→ 翻章 → 预取索引 2/3
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      await readNotifier().nextChapter(); // cur=1 → 预取 [2,3]
      await pumpPredownload();
      verify(() => mockApi.getChapterContentFull('https://book.com/1', 2))
          .called(1);

      // 换 B 书（同源章节布局：索引 2/3 与 A 书重叠）——不 clear 记录，
      // 用 bookUrl 精确区分两书的调用
      stubOpenBook(chapterCount: 6);
      await readNotifier().openBook(bookB);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      await readNotifier().nextChapter(); // cur=1 → 预取 [2,3]
      await pumpPredownload();

      // 修复前：A 书的 _preDownloadedBatch[2] 残留 → B 书章 2 被静默跳过
      //（B 书 called(0) 红）；修复后：换书清表 → B 书章 2/3 照常预取
      verify(() => mockApi.getChapterContentFull('https://book.com/2', 2))
          .called(1);
      verify(() => mockApi.getChapterContentFull('https://book.com/2', 3))
          .called(1);
    });

    test('P2-2 换书作废排队任务：慢请求在途时换书，旧书未出队章节不再发起',
        () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues({PrefKeys.preDownloadNum: 5});
      // 章 2 慢请求（可控 Completer）：占住串行泵，章 3..5 排队
      final slow2 = Completer<String>();
      final completers = <int, Completer<String>>{};
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((inv) async {
        final index = inv.positionalArguments[1] as int;
        if (index == 2) {
          completers[index] = Completer<String>();
          return completers[index]!.future;
        }
        return '第$index章';
      });
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      await readNotifier().nextChapter(); // cur=1 → 窗口 [2..5] 入队
      // 只泵一次：章 2 出队在途，章 3..5 还在队列
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // 换书：代际自增 + 队列清空；随后放行章 2 的慢请求
      stubOpenBook(chapterCount: 6);
      await readNotifier().openBook(bookB);
      slow2.complete('A书第2章迟到结果');
      await pumpPredownload(rounds: 12);

      // 旧书章 3/4/5 未出队 → 换书后不再发起（P2-2 代际取消）
      verifyNever(() => mockApi.getChapterContentFull('https://book.com/1', 3));
      verifyNever(() => mockApi.getChapterContentFull('https://book.com/1', 4));
      verifyNever(() => mockApi.getChapterContentFull('https://book.com/1', 5));
      // 在途章 2 结果已放行且只此一次（结果只进 Rust 落盘链路，不写 state）
      verify(() => mockApi.getChapterContentFull('https://book.com/1', 2))
          .called(1);
      expect(readNotifier().state.chapterContent, isNot('A书第2章迟到结果'),
          reason: '预取在途结果不得写入阅读器 state');
    });

    test('P2-1 失败重试：单章连续失败 3 次内重试，达 3 次后本会话跳过',
        () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues({PrefKeys.preDownloadNum: 1});
      var failChapter2 = true;
      // 手动计数（mocktail verify 会消费匹配记录，跨阶段累积计数不可用）
      var chapter2Calls = 0;
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((inv) async {
        final index = inv.positionalArguments[1] as int;
        if (index == 2) {
          chapter2Calls++;
          if (failChapter2) throw StateError('网络失败');
        }
        return '第$index章';
      });
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      // 章 2 第 1 次尝试（openBook cur=0 窗口 [1] 不会碰章 2，翻章后
      // cur=1 窗口 [2]）：失败计数=1
      await readNotifier().nextChapter();
      await pumpPredownload();
      expect(chapter2Calls, 1);

      // 往返翻章两次，每轮 cur=1 都重建窗口 [2]：失败章不在成功表，
      // 未达 3 次门 → 重试（失败计数 2、3）
      await readNotifier().prevChapter(); // cur=0
      await pumpPredownload();
      await readNotifier().nextChapter(); // cur=1 → 章 2 重试，失败计数=2
      await pumpPredownload();
      await readNotifier().prevChapter(); // cur=0
      await pumpPredownload();
      await readNotifier().nextChapter(); // cur=1 → 章 2 重试，失败计数=3
      await pumpPredownload();
      expect(chapter2Calls, 3, reason: '失败恰 3 次后不再发起（原版 >=3 门）');

      // 即使网络恢复（failChapter2=false），同会话也不再重试章 2
      failChapter2 = false;
      await readNotifier().prevChapter(); // cur=0
      await pumpPredownload();
      await readNotifier().nextChapter(); // cur=1 → 门内跳过
      await pumpPredownload();
      expect(chapter2Calls, 3, reason: '达 3 次门后网络恢复也不再重试');
    });

    test('P2-2 串行泵：同刻至多 1 个在途预取请求', () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues({PrefKeys.preDownloadNum: 3});
      var inFlight = 0;
      var maxInFlight = 0;
      final gate = Completer<void>();
      when(() => mockApi.getChapterContentFull(any(), any()))
          .thenAnswer((inv) async {
        final index = inv.positionalArguments[1] as int;
        if (index < 2) return '当前章'; // 当前章加载（0/1）不走预取泵
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await gate.future;
        inFlight--;
        return '第$index章';
      });
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      gate.complete();
      await readNotifier().nextChapter(); // cur=1 → 窗口 [2,3,4]
      await pumpPredownload(rounds: 12);

      expect(maxInFlight, 1, reason: '串行泵同刻至多 1 个在途预取');
      verify(() => mockApi.getChapterContentFull(any(), 2)).called(1);
      verify(() => mockApi.getChapterContentFull(any(), 3)).called(1);
      verify(() => mockApi.getChapterContentFull(any(), 4)).called(1);
    });
  });
}
