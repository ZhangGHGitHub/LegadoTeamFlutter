// 自动刷新书架（auto_refresh / onlyUpdateRead）单测
//
// 覆盖：开关关闭不刷新；开启后逐本 refreshToc 且跳过本地书；
// onlyUpdateRead 只刷新「已读完且有阅读进度」的书；进程内只执行一次；
// 单本失败不崩且继续后续书；新增章节数按前后 totalChapterNum 差值累计；
// 成功后才回调书架重载与提示；提示文案（无成功项为 null）。
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/auto_refresh_book_scheduler.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

class _MockBookApi extends Mock implements BookApi {}

Book _book(
  String url, {
  int totalChapterNum = 10,
  int durChapterIndex = 0,
  int durChapterTime = 0,
  int bookType = BookType.text,
  bool canUpdate = true,
  String origin = 'https://source.example.com',
}) {
  return Book(
    bookUrl: url,
    origin: origin,
    name: url,
    bookType: bookType,
    canUpdate: canUpdate,
    totalChapterNum: totalChapterNum,
    durChapterIndex: durChapterIndex,
    durChapterTime: durChapterTime,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockBookApi api;
  late SettingsService settings;
  late List<String> refreshed;
  late int bookshelfReloads;
  late List<AutoRefreshBookResult> notices;

  setUpAll(() {
    registerFallbackValue('');
  });

  setUp(() {
    api = _MockBookApi();
    settings = SettingsService();
    refreshed = [];
    bookshelfReloads = 0;
    notices = [];
    SharedPreferences.setMockInitialValues({});
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.refreshToc(any(), any())).thenAnswer((invocation) async {
      final url = invocation.positionalArguments.first as String;
      refreshed.add(url);
      return const <BookChapter>[];
    });
  });

  AutoRefreshBookScheduler buildScheduler() => AutoRefreshBookScheduler(
    api: api,
    settings: settings,
    onBookshelfChanged: () async => bookshelfReloads++,
    onResult: notices.add,
  );

  Future<void> enablePrefs({
    bool autoRefresh = true,
    bool onlyUpdateRead = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.autoRefreshBook: autoRefresh,
      PrefKeys.onlyUpdateRead: onlyUpdateRead,
    });
  }

  test('auto_refresh 关闭 → 不读取书架、不刷新', () async {
    await enablePrefs(autoRefresh: false);
    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.disabled);
    expect(result.succeeded, 0);
    verifyNever(() => api.getBooks());
    expect(refreshed, isEmpty);
    expect(notices, isEmpty);
  });

  test('auto_refresh 开启 → 逐本刷新可更新书籍并跳过本地书', () async {
    await enablePrefs();
    final online = _book('book-online');
    final local = _book(
      'book-local',
      bookType: BookType.local,
      origin: BookType.localTag,
    );
    final disabled = _book('book-disabled', canUpdate: false);
    when(
      () => api.getBooks(),
    ).thenAnswer((_) async => [online, local, disabled]);

    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.completed);
    expect(result.attempted, 1);
    expect(result.succeeded, 1);
    expect(result.failed, 0);
    expect(refreshed, ['book-online']);
    verify(() => api.refreshToc('book-online', online.origin)).called(1);
    expect(bookshelfReloads, 1);
    expect(notices, hasLength(1));
    expect(notices.single.notice, '已更新 1 本书的目录');
  });

  test('onlyUpdateRead=true → 只刷新已读完且有阅读进度的书', () async {
    await enablePrefs(onlyUpdateRead: true);
    final finished = _book(
      'book-finished',
      totalChapterNum: 100,
      durChapterIndex: 99,
      durChapterTime: 1700000000000,
    );
    final midway = _book(
      'book-midway',
      totalChapterNum: 100,
      durChapterIndex: 50,
      durChapterTime: 1700000000000,
    );
    final neverRead = _book('book-never-read', totalChapterNum: 100);
    final noTocNeverOpened = _book('book-no-toc', totalChapterNum: 0);
    when(
      () => api.getBooks(),
    ).thenAnswer((_) async => [finished, midway, neverRead, noTocNeverOpened]);

    final result = await buildScheduler().run();

    expect(result.attempted, 1);
    expect(refreshed, ['book-finished']);
    expect(notices.single.notice, '已更新 1 本书的目录');
  });

  test('onlyUpdateRead=false → 未读过的书也刷新', () async {
    await enablePrefs();
    final neverRead = _book('book-never-read', totalChapterNum: 100);
    when(() => api.getBooks()).thenAnswer((_) async => [neverRead]);

    final result = await buildScheduler().run();

    expect(result.succeeded, 1);
    expect(refreshed, ['book-never-read']);
  });

  test('进程内只执行一次：第二次 run 直接 alreadyRan 且不重复请求', () async {
    await enablePrefs();
    when(() => api.getBooks()).thenAnswer((_) async => [_book('book-a')]);
    final scheduler = buildScheduler();

    final first = await scheduler.run();
    final second = await scheduler.run();

    expect(first.outcome, AutoRefreshBookOutcome.completed);
    expect(second.outcome, AutoRefreshBookOutcome.alreadyRan);
    verify(() => api.getBooks()).called(1);
    expect(refreshed, ['book-a']);
  });

  test('单本刷新失败不崩：继续后续书并计入 failed', () async {
    await enablePrefs();
    when(
      () => api.getBooks(),
    ).thenAnswer((_) async => [_book('book-fail'), _book('book-ok')]);
    when(
      () => api.refreshToc('book-fail', any()),
    ).thenThrow(Exception('network down'));

    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.completed);
    expect(result.attempted, 2);
    expect(result.succeeded, 1);
    expect(result.failed, 1);
    expect(refreshed, ['book-ok']);
    expect(notices.single.notice, '已更新 1 本书的目录');
  });

  test('全部失败不提示（notices 为空），也不崩', () async {
    await enablePrefs();
    when(() => api.getBooks()).thenAnswer((_) async => [_book('book-fail')]);
    when(() => api.refreshToc(any(), any())).thenThrow(Exception('boom'));

    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.completed);
    expect(result.succeeded, 0);
    expect(result.failed, 1);
    expect(bookshelfReloads, 0);
    expect(notices, isEmpty);
    expect(result.notice, isNull);
  });

  test('新增章节数 = 刷新后 totalChapterNum − 刷新前，多个书累加', () async {
    await enablePrefs();
    final a = _book('book-a', totalChapterNum: 100);
    final b = _book('book-b', totalChapterNum: 50);
    when(() => api.getBooks()).thenAnswer((_) async => [a, b]);
    when(
      () => api.getBook('book-a'),
    ).thenAnswer((_) async => _book('book-a', totalChapterNum: 103));
    when(
      () => api.getBook('book-b'),
    ).thenAnswer((_) async => _book('book-b', totalChapterNum: 52));

    final result = await buildScheduler().run();

    expect(result.newChapters, 5);
    expect(notices.single.notice, '已更新 2 本书的目录，新增 5 章');
  });

  test('目录没变（差值 0 或回退）不计新增章节', () async {
    await enablePrefs();
    final a = _book('book-a', totalChapterNum: 100);
    when(() => api.getBooks()).thenAnswer((_) async => [a]);
    when(
      () => api.getBook('book-a'),
    ).thenAnswer((_) async => _book('book-a', totalChapterNum: 98));

    final result = await buildScheduler().run();

    expect(result.newChapters, 0);
    expect(notices.single.notice, '已更新 1 本书的目录');
  });

  test('书架为空 → nothingToUpdate，不提示', () async {
    await enablePrefs();
    when(() => api.getBooks()).thenAnswer((_) async => []);

    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.nothingToUpdate);
    expect(refreshed, isEmpty);
    expect(notices, isEmpty);
  });

  group('shouldRefresh / onlyUpdateReadAllows', () {
    test('本地书与 canUpdate=false 一律不刷新', () {
      expect(
        AutoRefreshBookScheduler.shouldRefresh(
          book: _book('local', bookType: BookType.local),
          onlyUpdateRead: false,
        ),
        isFalse,
      );
      expect(
        AutoRefreshBookScheduler.shouldRefresh(
          book: _book('no-update', canUpdate: false),
          onlyUpdateRead: false,
        ),
        isFalse,
      );
      expect(
        AutoRefreshBookScheduler.shouldRefresh(
          book: _book('online'),
          onlyUpdateRead: false,
        ),
        isTrue,
      );
    });

    test('unreadChapterNum > 0 不算已读完（对齐原版 getUnreadChapterNum）', () {
      expect(
        AutoRefreshBookScheduler.onlyUpdateReadAllows(
          _book('midway', totalChapterNum: 10, durChapterIndex: 3),
        ),
        isFalse,
      );
      expect(
        AutoRefreshBookScheduler.onlyUpdateReadAllows(
          _book(
            'finished',
            totalChapterNum: 10,
            durChapterIndex: 9,
            durChapterTime: 1,
          ),
        ),
        isTrue,
      );
    });

    test('从未打开过的书不算已读完（totalChapterNum=0 边界）', () {
      expect(
        AutoRefreshBookScheduler.onlyUpdateReadAllows(
          _book('no-toc', totalChapterNum: 0),
        ),
        isFalse,
      );
      expect(
        AutoRefreshBookScheduler.onlyUpdateReadAllows(
          _book('single', totalChapterNum: 1, durChapterIndex: 0),
        ),
        isFalse,
      );
      expect(
        AutoRefreshBookScheduler.onlyUpdateReadAllows(
          _book(
            'single-read',
            totalChapterNum: 1,
            durChapterIndex: 0,
            durChapterTime: 1700000000000,
          ),
        ),
        isTrue,
      );
    });
  });
}
