// 批9a 项8：预下载（preDownloadNum）轻量预取测试
//
// 语义钉住（对齐参考版 ReadBook.preDownload）：
// - 翻章成功后向后预取 [cur+1, cur+N] 窗口（getChapterContentFull 落盘
//   链路见 rust/legado-ffi/src/api/reader.rs fetch_chapter_content_inner
//   → save_chapter_cache → CacheBookRepository.insert）；
// - 0 = 关闭（不发起预取调用）；
// - 本地书不预取；
// - 失败静默（catchError 吞异常，不影响当前章状态）。
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

  ReaderNotifier readNotifier() =>
      container.read(readerNotifierProvider.notifier);

  final onlineBook = Book(
    bookUrl: 'https://book.com/1',
    name: '在线书',
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

  /// 等预取 fire-and-forget 链路完成（偏好读取 microtask + API 调用）
  Future<void> pumpPredownload() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
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

      verify(() => mockApi.getChapterContentFull(any(), 2)).called(greaterThanOrEqualTo(1));
      verify(() => mockApi.getChapterContentFull(any(), 3)).called(greaterThanOrEqualTo(1));
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
          reason: '预取失败必须静默（catchError 吞掉）');
      expect(readNotifier().state.chapterContent, '当前章正文');
    });

    test('不重复：同章在既有批次内只发起一次', () async {
      stubOpenBook(chapterCount: 6);
      SharedPreferences.setMockInitialValues(
          {PrefKeys.preDownloadNum: 4});
      await readNotifier().openBook(onlineBook);
      await pumpInit();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      await readNotifier().nextChapter(); // cur=1 → 预取 [2..5]
      await pumpPredownload();
      // 立即再翻一章（cur=2 → 预取 [3..6∩4]）；章 3/4 已在上批记录
      await readNotifier().nextChapter();
      await pumpPredownload();

      // 章 2 在第一批预取过（cur=1 时）、cur=2 后自身是当前章（不属预取）；
      // 关键断言：章 3/4 的 Full 调用次数不超过批次覆盖次数
      final calls3 = verify(() => mockApi.getChapterContentFull(any(), 3))
          .callCount;
      expect(calls3, lessThanOrEqualTo(1),
          reason: '章 3 预取过一次后，同批次语义下不重复网络抓取');
    });
  });
}
