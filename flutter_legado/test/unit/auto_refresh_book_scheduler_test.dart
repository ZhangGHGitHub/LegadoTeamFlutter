// 自动刷新书架（auto_refresh / onlyUpdateRead）单测
//
// 覆盖：开关关闭不刷新；开启后逐本 refreshToc 且跳过本地书；
// onlyUpdateRead 与上游 getUnreadChapterNum 同口径（total=0 / total=1,dur=0
// 也视为已读完）；进程内只执行一次；单本失败不崩且继续后续书；
// 同书并发被取代计入 cancelled（不是静默 failed）；
// 成功判定按刷新后元信息实变（空解析 no-op / getBook 失败场景）；
// 新增章节数按前后 totalChapterNum 差值累计；成功后才回调书架重载与提示；
// attach 生产路径（首帧 → 2s Timer）与 dispose 取消。
import 'package:flutter/widgets.dart';
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

  /// 刷新后的书籍快照（getBook 返回；默认 refreshToc 每本 +1 章）
  late Map<String, Book> currentBooks;

  setUpAll(() {
    registerFallbackValue('');
  });

  setUp(() {
    api = _MockBookApi();
    settings = SettingsService();
    refreshed = [];
    bookshelfReloads = 0;
    notices = [];
    currentBooks = {};
    SharedPreferences.setMockInitialValues({});
    when(() => api.getBook(any())).thenAnswer((invocation) async {
      return currentBooks[invocation.positionalArguments.first as String];
    });
    // 默认刷新：记录调用 + 目录 +1 章（元信息实变 → succeeded）
    when(() => api.refreshToc(any(), any())).thenAnswer((invocation) async {
      final url = invocation.positionalArguments.first as String;
      refreshed.add(url);
      final before = currentBooks[url];
      if (before != null) {
        currentBooks[url] = before.copyWith(
          totalChapterNum: before.totalChapterNum + 1,
        );
      }
      return const <BookChapter>[BookChapter(url: 'c1', title: '第一章')];
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

  void stubBooks(List<Book> books) {
    for (final b in books) {
      currentBooks[b.bookUrl] = b;
    }
    when(() => api.getBooks()).thenAnswer((_) async => books);
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
    stubBooks([online, local, disabled]);

    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.completed);
    expect(result.attempted, 1);
    expect(result.succeeded, 1);
    expect(result.unchanged, 0);
    expect(result.cancelled, 0);
    expect(result.failed, 0);
    expect(refreshed, ['book-online']);
    verify(() => api.refreshToc('book-online', online.origin)).called(1);
    expect(bookshelfReloads, 1);
    expect(notices, hasLength(1));
    expect(notices.single.notice, '已更新 1 本书的目录，新增 1 章');
  });

  test('onlyUpdateRead=true → 与上游同口径：只刷新无未读章节的书', () async {
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
    // 上游口径：total=0 / total=1,dur=0 的从未打开书 unread=0，同样刷新
    final noTocNeverOpened = _book('book-no-toc', totalChapterNum: 0);
    final singleNeverOpened = _book(
      'book-single',
      totalChapterNum: 1,
      durChapterIndex: 0,
    );
    stubBooks([
      finished,
      midway,
      neverRead,
      noTocNeverOpened,
      singleNeverOpened,
    ]);

    final result = await buildScheduler().run();

    expect(result.attempted, 3);
    expect(refreshed, ['book-finished', 'book-no-toc', 'book-single']);
  });

  test('onlyUpdateRead=false → 未读过的书也刷新', () async {
    await enablePrefs();
    final neverRead = _book('book-never-read', totalChapterNum: 100);
    stubBooks([neverRead]);

    final result = await buildScheduler().run();

    expect(result.succeeded, 1);
    expect(refreshed, ['book-never-read']);
  });

  test('进程内只执行一次：第二次 run 直接 alreadyRan 且不重复请求', () async {
    await enablePrefs();
    stubBooks([_book('book-a')]);
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
    stubBooks([_book('book-fail'), _book('book-ok')]);
    when(
      () => api.refreshToc('book-fail', any()),
    ).thenThrow(Exception('network down'));

    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.completed);
    expect(result.attempted, 2);
    expect(result.succeeded, 1);
    expect(result.failed, 1);
    expect(result.cancelled, 0);
    expect(refreshed, ['book-ok']);
    expect(notices.single.notice, '已更新 1 本书的目录，新增 1 章');
  });

  test('全部失败不提示（notices 为空），也不崩', () async {
    await enablePrefs();
    stubBooks([_book('book-fail')]);
    when(() => api.refreshToc(any(), any())).thenThrow(Exception('boom'));

    final result = await buildScheduler().run();

    expect(result.outcome, AutoRefreshBookOutcome.completed);
    expect(result.succeeded, 0);
    expect(result.failed, 1);
    expect(bookshelfReloads, 0);
    expect(notices, isEmpty);
    expect(result.notice, isNull);
  });

  test('同书并发被取代：计入 cancelled，不并入 failed，并在提示中说明', () async {
    await enablePrefs();
    stubBooks([_book('book-a'), _book('book-ok')]);
    when(() => api.refreshToc('book-a', any())).thenThrow(
      Exception(
        'Internal("toc refresh superseded by a newer refresh generation")',
      ),
    );

    final result = await buildScheduler().run();

    expect(result.attempted, 2);
    expect(result.succeeded, 1);
    expect(result.cancelled, 1);
    expect(result.failed, 0, reason: '被同书新刷新取代不是失败');
    expect(notices.single.notice, '已更新 1 本书的目录，新增 1 章（1 本被同书新刷新取代）');
  });

  test('全部被取代：不提示但结果可观测（不是静默 failed）', () async {
    await enablePrefs();
    stubBooks([_book('book-a')]);
    when(() => api.refreshToc(any(), any())).thenThrow(
      Exception('toc refresh superseded by a newer refresh generation'),
    );

    final result = await buildScheduler().run();

    expect(result.cancelled, 1);
    expect(result.failed, 0);
    expect(result.succeeded, 0);
    expect(result.notice, isNull);
  });

  test('Rust 空解析回退旧目录（no-op）不计入 succeeded', () async {
    await enablePrefs();
    final book = _book('book-a', totalChapterNum: 100);
    stubBooks([book]);
    // refreshToc 返回旧目录（非空）但不改元信息 = 空解析回退 no-op
    when(() => api.refreshToc('book-a', any())).thenAnswer(
      (_) async => const <BookChapter>[BookChapter(url: 'old', title: '旧章')],
    );

    final result = await buildScheduler().run();

    expect(result.succeeded, 0);
    expect(result.unchanged, 1);
    expect(result.failed, 0);
    expect(notices, isEmpty, reason: '无实际更新不打扰用户');
  });

  test('getBook 读取失败不把已刷新成功计为 failed', () async {
    await enablePrefs();
    stubBooks([_book('book-a')]);
    when(() => api.getBook('book-a')).thenThrow(Exception('db busy'));

    final result = await buildScheduler().run();

    expect(result.succeeded, 1, reason: 'refreshToc 已成功，getBook 失败不影响判定');
    expect(result.failed, 0);
    expect(result.unchanged, 0);
  });

  test('getBook 失败且 refreshToc 返回空列表 → no-op（unchanged）', () async {
    await enablePrefs();
    stubBooks([_book('book-a')]);
    when(
      () => api.refreshToc('book-a', any()),
    ).thenAnswer((_) async => const <BookChapter>[]);
    when(() => api.getBook('book-a')).thenThrow(Exception('db busy'));

    final result = await buildScheduler().run();

    expect(result.succeeded, 0);
    expect(result.unchanged, 1);
    expect(result.failed, 0);
  });

  test('新增章节数 = 刷新后 totalChapterNum − 刷新前，多个书累加', () async {
    await enablePrefs();
    stubBooks([
      _book('book-a', totalChapterNum: 100),
      _book('book-b', totalChapterNum: 50),
    ]);
    when(() => api.refreshToc('book-a', any())).thenAnswer((_) async {
      refreshed.add('book-a');
      currentBooks['book-a'] = _book('book-a', totalChapterNum: 103);
      return const <BookChapter>[BookChapter(url: 'a1')];
    });
    when(() => api.refreshToc('book-b', any())).thenAnswer((_) async {
      refreshed.add('book-b');
      currentBooks['book-b'] = _book('book-b', totalChapterNum: 52);
      return const <BookChapter>[BookChapter(url: 'b1')];
    });

    final result = await buildScheduler().run();

    expect(result.newChapters, 5);
    expect(notices.single.notice, '已更新 2 本书的目录，新增 5 章');
  });

  test('目录总数不变（差值 0）不计新增章节，按 unchanged 处理', () async {
    await enablePrefs();
    stubBooks([_book('book-a', totalChapterNum: 100)]);
    when(
      () => api.refreshToc('book-a', any()),
    ).thenAnswer((_) async => const <BookChapter>[BookChapter(url: 'x')]);
    when(
      () => api.getBook('book-a'),
    ).thenAnswer((_) async => _book('book-a', totalChapterNum: 100));

    final result = await buildScheduler().run();

    expect(result.newChapters, 0);
    expect(result.succeeded, 0);
    expect(result.unchanged, 1);
    expect(result.notice, isNull);
  });

  test('末章标题变化也算更新（总章数不变）', () async {
    await enablePrefs();
    stubBooks([_book('book-a', totalChapterNum: 100)]);
    when(() => api.refreshToc('book-a', any())).thenAnswer(
      (_) async => const <BookChapter>[BookChapter(url: 'x', title: '新章')],
    );
    when(() => api.getBook('book-a')).thenAnswer(
      (_) async => Book(
        bookUrl: 'book-a',
        origin: 'https://source.example.com',
        name: 'book-a',
        bookType: BookType.text,
        totalChapterNum: 100,
        latestChapterTitle: '新章',
      ),
    );

    final result = await buildScheduler().run();

    expect(result.succeeded, 1);
    expect(result.newChapters, 0);
    expect(result.notice, '已更新 1 本书的目录');
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

    test('上游口径：total=0 与 total=1,dur=0 的从未打开书也算已读完', () {
      expect(
        AutoRefreshBookScheduler.onlyUpdateReadAllows(
          _book('no-toc', totalChapterNum: 0),
        ),
        isTrue,
        reason: 'max(0-0-1,0)=0，上游会刷新（不附加「读过」条件）',
      );
      expect(
        AutoRefreshBookScheduler.onlyUpdateReadAllows(
          _book('single', totalChapterNum: 1, durChapterIndex: 0),
        ),
        isTrue,
      );
    });
  });

  group('attach 生产路径（首帧 → Timer）与释放', () {
    /// attach 的 postFrameCallback 只在真正绘制帧时执行（无 widget 树时
    /// tester.pump 不会 drawFrame），这里显式 scheduleFrame 模拟 runApp 首帧。
    Future<void> pumpScheduledFrame(WidgetTester tester) async {
      tester.binding.scheduleFrame();
      await tester.pump();
    }

    testWidgets('首帧后延迟 2s 执行一次；instance getter 可观测', (tester) async {
      AutoRefreshBookScheduler.resetForTest();
      addTearDown(AutoRefreshBookScheduler.resetForTest);
      await enablePrefs();
      when(() => api.getBooks()).thenAnswer((_) async => []);

      await tester.pumpWidget(const SizedBox.shrink());
      final scheduler = AutoRefreshBookScheduler.attach(
        api: api,
        settings: settings,
        startupDelay: const Duration(seconds: 2),
      );
      expect(AutoRefreshBookScheduler.instance, same(scheduler));

      await pumpScheduledFrame(tester); // 首帧 → 注册 Timer
      verifyNever(() => api.getBooks());
      await tester.pump(const Duration(seconds: 1));
      // 未到 2s 不刷新
      verifyNever(() => api.getBooks());
      await tester.pump(const Duration(seconds: 1));
      // Timer 触发后 run() 内含多次 await（偏好读取 → 书架读取），
      // 多 pump 几帧把异步链走完
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      verify(() => api.getBooks()).called(1);
    });

    testWidgets('dispose 取消未触发的 Timer 并清空单例', (tester) async {
      AutoRefreshBookScheduler.resetForTest();
      addTearDown(AutoRefreshBookScheduler.resetForTest);
      await enablePrefs();
      when(() => api.getBooks()).thenAnswer((_) async => []);

      await tester.pumpWidget(const SizedBox.shrink());
      AutoRefreshBookScheduler.attach(
        api: api,
        settings: settings,
        startupDelay: const Duration(seconds: 2),
      );
      await pumpScheduledFrame(tester); // 注册 Timer
      AutoRefreshBookScheduler.instance?.dispose();
      expect(AutoRefreshBookScheduler.instance, isNull);

      await tester.pump(const Duration(seconds: 5));
      verifyNever(() => api.getBooks());
    });
  });
}
