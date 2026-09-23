// [P2-9 | 2026-09-24] ReaderNotifier 强制刷新 / 换源后重载（状态级）
//
// 覆盖 refreshChapterContent（Fix A 强制路径）与
// reloadAfterSourceChange（Fix B 换源后重载）的状态语义：
// - 强制刷新：clearBookCache + fetchChapterContent，不再走
//   getChapterContentFull；成功更新正文、失败保留旧正文并记 error；
// - 本地书（loc_book / dav:）守卫：直接返回原因、不调 API、正文不动；
// - 换源重载：getBook → updateCurrentBook → getChapters/refreshToc →
//   章节匹配（标题精确 → 宽松 → 原索引 → 0）→ 强制刷新；
//   同题章节保留章内位置，异题归零。
//
// 注意：本文件引用新 API（refreshChapterContent / reloadAfterSourceChange），
// 改造前编译失败（红 = API 缺失），改造后全绿。

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
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
  durChapterIndex: 1,
  durChapterPos: 3,
);

const testChapters = [
  BookChapter(url: 'https://book.com/1/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/1/c2', title: '第二章', index: 1),
];

/// 换源后书籍记录（bookUrl 稳定主键不变，源字段更新）
const newBookRecord = Book(
  bookUrl: 'https://book.com/1',
  name: '测试书籍',
  author: '作者',
  origin: 'https://source-b.com',
  originName: '源B',
  originBookUrl: 'https://book.com/1',
  durChapterIndex: 1,
  durChapterPos: 3,
);

const newToc = [
  BookChapter(url: 'https://book.com/2/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/2/c2', title: '第二章', index: 1),
  BookChapter(url: 'https://book.com/2/c3', title: '第三章', index: 2),
];

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi mockApi;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  /// 打开书籍到「第二章（index 1, pos 3）+ 旧正文」基线态。
  /// 需要断言「getChapterContentFull 未被再次调用」的用例，
  /// 在用例内重新 stub（后 stub 覆盖前 stub）并自带计数闭包。
  Future<void> openBookBaseline({String content = '旧正文（缓存）'}) async {
    when(
      () => mockApi.getChapters(any()),
    ).thenAnswer((_) async => testChapters);
    when(
      () => mockApi.getChapterContentFull(any(), any()),
    ).thenAnswer((_) async => content);
    when(
      () => mockApi.updateReadingProgress(
        bookUrl: any(named: 'bookUrl'),
        chapterIndex: any(named: 'chapterIndex'),
        chapterPos: any(named: 'chapterPos'),
      ),
    ).thenAnswer((_) async {});
    final notifier = container.read(readerNotifierProvider.notifier);
    await notifier.openBook(testBook);
    expect(container.read(readerNotifierProvider).chapterContent, content);
    expect(container.read(readerNotifierProvider).currentChapterIndex, 1);
  }

  group('refreshChapterContent（Fix A 强制路径）', () {
    test('强制刷新：清缓存 + 联网抓取并更新正文，不再走 getChapterContentFull', () async {
      await openBookBaseline();
      var fullCalls = 0;
      when(() => mockApi.getChapterContentFull(any(), any())).thenAnswer((_) {
        fullCalls++;
        return Future.value('旧正文（缓存）');
      });
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 2);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新正文（网络）');

      final err = await container
          .read(readerNotifierProvider.notifier)
          .refreshChapterContent();

      expect(err, isNull);
      final st = container.read(readerNotifierProvider);
      expect(st.chapterContent, '新正文（网络）');
      expect(st.error, isNull);
      expect(fullCalls, 0, reason: '强制刷新不得再走缓存优先读取路径');
      verify(() => mockApi.clearBookCache('https://book.com/1')).called(1);
      verify(
        () => mockApi.fetchChapterContent(
          'https://book.com/1',
          'https://book.com/1/c2',
          'https://source-a.com',
        ),
      ).called(1);
    });

    test('本地书（loc_book）守卫：返回原因、不调 API、正文不动', () async {
      const localBook = Book(
        bookUrl: 'loc://books/本地书.epub',
        name: '本地书',
        origin: BookType.localTag,
        durChapterIndex: 0,
      );
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [
          const BookChapter(
            url: 'loc://books/本地书.epub/1',
            title: '第一章',
            index: 0,
          ),
        ],
      );
      when(
        () => mockApi.getChapterContentFull(any(), any()),
      ).thenAnswer((_) async => '本地正文');
      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(localBook);

      final err = await notifier.refreshChapterContent();

      expect(err, '本地书不支持刷新正文');
      final st = container.read(readerNotifierProvider);
      expect(st.chapterContent, '本地正文');
      expect(st.error, isNull);
      verifyNever(() => mockApi.clearBookCache(any()));
      verifyNever(() => mockApi.fetchChapterContent(any(), any(), any()));
    });

    test('WebDAV 书（dav:）守卫：返回原因、不调 API', () async {
      const davBook = Book(
        bookUrl: 'dav://server/books/x.epub',
        name: '云书',
        origin: 'dav://server/books',
        durChapterIndex: 0,
      );
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [
          const BookChapter(
            url: 'dav://server/books/x/1',
            title: '第一章',
            index: 0,
          ),
        ],
      );
      when(
        () => mockApi.getChapterContentFull(any(), any()),
      ).thenAnswer((_) async => '云端正文');
      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(davBook);

      final err = await notifier.refreshChapterContent();

      expect(err, '本地书不支持刷新正文');
      verifyNever(() => mockApi.clearBookCache(any()));
      verifyNever(() => mockApi.fetchChapterContent(any(), any(), any()));
    });

    test('抓取抛错 → 返回错误原因，旧正文保留，state.error 记录', () async {
      await openBookBaseline();
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 1);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenThrow(const BridgeError(message: '404: 源不可达'));

      final err = await container
          .read(readerNotifierProvider.notifier)
          .refreshChapterContent();

      expect(err, '404: 源不可达');
      final st = container.read(readerNotifierProvider);
      expect(st.chapterContent, '旧正文（缓存）', reason: '失败必须保留旧正文');
      expect(st.error, '404: 源不可达');
    });

    test('抓取返回空串 → 视为失败（保留旧正文，不清空）', () async {
      await openBookBaseline();
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 1);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '   ');

      final err = await container
          .read(readerNotifierProvider.notifier)
          .refreshChapterContent();

      expect(err, isNotNull);
      expect(container.read(readerNotifierProvider).chapterContent, '旧正文（缓存）');
    });

    test('无书籍/无目录 → 返回原因，不抛异常', () async {
      final err = await container
          .read(readerNotifierProvider.notifier)
          .refreshChapterContent();
      expect(err, '没有书籍或目录');
    });
  });

  group('reloadAfterSourceChange（Fix B 换源后重载）', () {
    test('成功：getBook + getChapters + 强制刷新，currentBook/章节/位置更新', () async {
      await openBookBaseline();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => newBookRecord);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final err = await container
          .read(readerNotifierProvider.notifier)
          .reloadAfterSourceChange('https://book.com/1');

      expect(err, isNull);
      final st = container.read(readerNotifierProvider);
      expect(st.currentBook?.bookUrl, 'https://book.com/1'); // 稳定主键
      expect(st.currentBook?.origin, 'https://source-b.com'); // 已更新
      expect(st.currentBook?.originName, '源B');
      expect(st.chapters, newToc);
      expect(st.currentChapterIndex, 1, reason: '「第二章」按标题命中');
      expect(st.currentChapterPos, 3, reason: '同题章节保留章内位置');
      expect(st.chapterContent, '新源新正文');
      verify(() => mockApi.getBook('https://book.com/1')).called(1);
      verify(
        () => mockApi.fetchChapterContent(
          'https://book.com/1',
          'https://book.com/2/c2',
          'https://source-b.com',
        ),
      ).called(1);
    });

    test('旧章名在新目录未命中且原索引在范围内 → 回退原索引，位置归零', () async {
      await openBookBaseline();
      const renamedToc = [
        BookChapter(url: 'https://book.com/2/甲', title: '甲', index: 0),
        BookChapter(url: 'https://book.com/2/乙', title: '乙', index: 1),
      ];
      when(() => mockApi.getBook(any())).thenAnswer((_) async => newBookRecord);
      when(
        () => mockApi.getChapters(any()),
      ).thenAnswer((_) async => renamedToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final err = await container
          .read(readerNotifierProvider.notifier)
          .reloadAfterSourceChange('https://book.com/1');

      expect(err, isNull);
      final st = container.read(readerNotifierProvider);
      expect(st.currentChapterIndex, 1, reason: '「乙」= 原索引 1 回退命中');
      expect(st.currentChapterPos, 0, reason: '异题章节位置归零');
    });

    test('原索引越界 → 回退第 0 章，位置归零', () async {
      await openBookBaseline();
      const shortToc = [
        BookChapter(url: 'https://book.com/2/独', title: '独', index: 0),
      ];
      when(() => mockApi.getBook(any())).thenAnswer((_) async => newBookRecord);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => shortToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final err = await container
          .read(readerNotifierProvider.notifier)
          .reloadAfterSourceChange('https://book.com/1');

      expect(err, isNull);
      final st = container.read(readerNotifierProvider);
      expect(st.currentChapterIndex, 0);
      expect(st.currentChapterPos, 0);
    });

    test('新源本地无目录（getChapters 空）→ 经 refreshToc 联网取目录', () async {
      await openBookBaseline();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => newBookRecord);
      when(
        () => mockApi.getChapters(any()),
      ).thenAnswer((_) async => <BookChapter>[]);
      when(
        () => mockApi.refreshToc(any(), any()),
      ).thenAnswer((_) async => newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final err = await container
          .read(readerNotifierProvider.notifier)
          .reloadAfterSourceChange('https://book.com/1');

      expect(err, isNull);
      verify(
        () => mockApi.refreshToc('https://book.com/1', 'https://source-b.com'),
      ).called(1);
      expect(container.read(readerNotifierProvider).chapters, newToc);
    });

    test('getBook 返回 null → 返回错误原因，旧正文/旧目录保留', () async {
      await openBookBaseline();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);

      final err = await container
          .read(readerNotifierProvider.notifier)
          .reloadAfterSourceChange('https://book.com/1');

      expect(err, isNotNull);
      final st = container.read(readerNotifierProvider);
      // 重载未走成：书籍记录/目录/正文均保持换源前状态
      expect(st.currentBook?.origin, 'https://source-a.com');
      expect(st.chapters, testChapters);
      expect(st.chapterContent, '旧正文（缓存）');
      expect(st.error, isNotNull);
    });

    test('强制刷新失败 → 目录已更新、旧正文保留、返回错误原因', () async {
      await openBookBaseline();
      when(() => mockApi.getBook(any())).thenAnswer((_) async => newBookRecord);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenThrow(const BridgeError(message: '502: 抓取失败'));

      final err = await container
          .read(readerNotifierProvider.notifier)
          .reloadAfterSourceChange('https://book.com/1');

      expect(err, isNotNull);
      expect(err, contains('502: 抓取失败'));
      final st = container.read(readerNotifierProvider);
      expect(st.chapters, newToc, reason: '目录重载先行，失败不丢失');
      expect(st.chapterContent, '旧正文（缓存）', reason: '失败保留旧正文');
      expect(st.error, isNotNull);
    });

    test('无 currentBook → 返回原因，不抛异常', () async {
      final err = await container
          .read(readerNotifierProvider.notifier)
          .reloadAfterSourceChange('https://book.com/1');
      expect(err, '没有书籍');
    });
  });
}
