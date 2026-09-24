import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/change_source/change_source_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  group('SourceMatch model', () {
    test('fromJson 解析 Rust SourceMatch 的 snake_case 字段', () {
      final json = {
        'source_url': 'https://source.example.com',
        'source_name': '笔趣阁',
        'book_url': 'https://source.example.com/book/1',
        'book_name': '斗破苍穹',
        'author': '天蚕土豆',
        'latest_chapter': '第一千六百章 大结局',
        'word_count': '530万字',
        'score': 87.5,
      };

      final item = SourceMatch.fromJson(json);

      expect(item.sourceUrl, equals('https://source.example.com'));
      expect(item.sourceName, equals('笔趣阁'));
      expect(item.bookUrl, equals('https://source.example.com/book/1'));
      expect(item.bookName, equals('斗破苍穹'));
      expect(item.author, equals('天蚕土豆'));
      expect(item.latestChapter, equals('第一千六百章 大结局'));
      expect(item.wordCount, equals('530万字'));
      expect(item.score, equals(87.5));
    });

    test('fromJson 可选字段缺失时为 null，score 默认 0', () {
      final item = SourceMatch.fromJson({
        'source_url': 'https://a.com',
        'source_name': 'A源',
        'book_url': 'https://a.com/b',
        'book_name': '测试',
        'author': '',
      });

      expect(item.latestChapter, isNull);
      expect(item.wordCount, isNull);
      expect(item.score, equals(0.0));
    });

    test('fromJson score 为整数时正确转为 double', () {
      final item = SourceMatch.fromJson({
        'source_url': 'https://a.com',
        'source_name': 'A源',
        'book_url': 'https://a.com/b',
        'book_name': '测试',
        'author': '',
        'score': 95,
      });

      expect(item.score, equals(95.0));
    });

    test('fromJson 空 map 使用默认值', () {
      final item = SourceMatch.fromJson({});
      expect(item.sourceUrl, equals(''));
      expect(item.sourceName, equals(''));
      expect(item.bookUrl, equals(''));
      expect(item.score, equals(0.0));
    });
  });

  group('ChangeSourceNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUpAll(() {
      registerFallbacks();
    });

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    ChangeSourceState readState() =>
        container.read(changeSourceNotifierProvider);
    ChangeSourceNotifier readNotifier() =>
        container.read(changeSourceNotifierProvider.notifier);

    /// 构造一条候选结果 Map（snake_case，对齐 Rust SourceMatch）
    Map<String, dynamic> rawMatch(String url, String name, double score) => {
      'source_url': url,
      'source_name': name,
      'book_url': '$url/book',
      'book_name': '斗破苍穹',
      'author': '天蚕土豆',
      'score': score,
    };

    /// 构造一个 T6 流式批次（契约 §2.4：matches 全量快照 + x/y 进度）
    Map<String, dynamic> makeBatch({
      required List<Map<String, dynamic>> matches,
      int finished = 1,
      int total = 1,
      String sourceName = '',
    }) => {
      'source_index': 0,
      'source_url': '',
      'source_name': sourceName,
      'error': null,
      'finished_count': finished,
      'total_count': total,
      'is_last': true,
      'matches': matches,
    };

    /// stub searchSourceStream（named 参数全 any，匹配 notifier 的实际调用）
    void stubSearchStream(Stream<Map<String, dynamic>> stream) {
      when(
        () => mockApi.searchSourceStream(
          any(),
          any(),
          sourceUrls: any(named: 'sourceUrls'),
          loadInfo: any(named: 'loadInfo'),
          loadToc: any(named: 'loadToc'),
          loadWordCount: any(named: 'loadWordCount'),
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).thenAnswer((_) => stream);
    }

    test('初始状态为空', () {
      final state = readState();
      expect(state.results, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.applyingUrl, isNull);
      expect(state.hasResults, isFalse);
      expect(state.isApplying, isFalse);
    });

    test('search 经 BookApi.searchSourceStream 逐批解析为 SourceMatch 列表',
        () async {
      // T6：逐源批次——首批仅 A 源命中，末批双源全量快照（直接替换展示）
      stubSearchStream(Stream.fromIterable([
        makeBatch(
          matches: [rawMatch('https://a.com', 'A源', 90)],
          finished: 1,
          total: 2,
        ),
        makeBatch(
          matches: [
            rawMatch('https://a.com', 'A源', 90),
            rawMatch('https://b.com', 'B源', 70),
          ],
          finished: 2,
          total: 2,
        ),
      ]));

      await readNotifier().search('斗破苍穹', '天蚕土豆');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.results.length, equals(2));
      expect(state.results.first.sourceUrl, equals('https://a.com'));
      expect(state.results.first.sourceName, equals('A源'));
      expect(state.results.first.score, equals(90));
      // mocktail 调用匹配为严格相等：notifier 实际传齐 5 个 named 参数，
      // verify/stub 必须逐一列出（与 stubSearchStream 同口径）
      verify(
        () => mockApi.searchSourceStream(
          '斗破苍穹',
          '天蚕土豆',
          sourceUrls: any(named: 'sourceUrls'),
          loadInfo: any(named: 'loadInfo'),
          loadToc: any(named: 'loadToc'),
          loadWordCount: any(named: 'loadWordCount'),
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).called(1);
    });
    test('分组搜索：分号/全角逗号组名的源不被 Dart 预过滤剔除（审计 D1）', () async {
      when(() => mockApi.getEnabledBookSources()).thenAnswer(
        (_) async => const [
          BookSource(
            bookSourceUrl: 'https://semi.com',
            bookSourceName: '分号源',
            bookSourceGroup: '玄幻;都市',
          ),
          BookSource(
            bookSourceUrl: 'https://plain.com',
            bookSourceName: '全角逗号源',
            bookSourceGroup: '玄幻，都市',
          ),
        ],
      );
      stubSearchStream(Stream.value(makeBatch(matches: [])));

      await readNotifier().search('斗破苍穹', '天蚕土豆', group: '玄幻');

      final captured =
          verify(
            () => mockApi.searchSourceStream(
              any(),
              any(),
              sourceUrls: captureAny(named: 'sourceUrls'),
              loadInfo: any(named: 'loadInfo'),
              loadToc: any(named: 'loadToc'),
              loadWordCount: any(named: 'loadWordCount'),
              forceRefresh: any(named: 'forceRefresh'),
            ),
          ).captured.single as List<String>;
      // 分号（;）与全角逗号（，）分组的源都必须进入 sourceUrls
      expect(captured, containsAll(['https://semi.com', 'https://plain.com']));
    });

    test('search 保持 Rust 返回顺序（不在 Dart 侧重排）', () async {
      // Rust 已按评分降序；此处故意返回升序，验证 Notifier 不重排
      stubSearchStream(Stream.value(makeBatch(
        matches: [
          rawMatch('https://low.com', '低分源', 30),
          rawMatch('https://high.com', '高分源', 95),
        ],
        finished: 2,
        total: 2,
      )));

      await readNotifier().search('斗破苍穹', '天蚕土豆');

      expect(readState().results.first.sourceUrl, equals('https://low.com'));
      expect(readState().results.last.sourceUrl, equals('https://high.com'));
    });

    test('search 异常时记录 error 并清除加载态', () async {
      when(
        () => mockApi.searchSourceStream(
          any(),
          any(),
          sourceUrls: any(named: 'sourceUrls'),
          loadInfo: any(named: 'loadInfo'),
          loadToc: any(named: 'loadToc'),
          loadWordCount: any(named: 'loadWordCount'),
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).thenThrow(Exception('网络错误'));

      await readNotifier().search('斗破苍穹', '天蚕土豆');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, contains('网络错误'));
      expect(state.results, isEmpty);
    });

    test('search 进行中时重复调用被忽略', () async {
      var callCount = 0;
      when(
        () => mockApi.searchSourceStream(
          any(),
          any(),
          sourceUrls: any(named: 'sourceUrls'),
          loadInfo: any(named: 'loadInfo'),
          loadToc: any(named: 'loadToc'),
          loadWordCount: any(named: 'loadWordCount'),
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).thenAnswer((_) {
        callCount++;
        // searchSourceStream 直接返回 Stream（非 Future），延迟发射保持
        // 「搜索进行中」窗口，验证 isLoading 守卫拒绝并发调用
        return Stream.fromFuture(
          Future<void>.delayed(const Duration(milliseconds: 20))
              .then((_) => makeBatch(matches: [rawMatch('https://a.com', 'A源', 90)])),
        );
      });

      final f1 = readNotifier().search('斗破苍穹', '天蚕土豆');
      final f2 = readNotifier().search('斗破苍穹', '天蚕土豆');
      await Future.wait([f1, f2]);

      expect(callCount, equals(1));
    });

    test(
      'applySource 经 BookApi.switchSourcePrefetch 回写并返回新 bookUrl'
      '（2026-09-24 换源预拉缓存）',
      () async {
        when(
          () => mockApi.switchSourcePrefetch(any(), any(), any()),
        ).thenAnswer((_) async => '{"bookUrl":"https://new.com/book/1"}');
        const match = SourceMatch(
          sourceUrl: 'https://new.com',
          sourceName: '新源',
          bookUrl: 'https://new.com/fallback',
        );

        final newUrl = await readNotifier().applySource(
          match,
          bookUrl: 'https://old.com/book',
        );

        expect(newUrl, equals('https://new.com/book/1'));
        expect(readState().applyingUrl, isNull);
        verify(
          () => mockApi.switchSourcePrefetch(
            'https://old.com/book',
            'https://new.com',
            'https://new.com/fallback',
          ),
        ).called(1);
      },
    );

    test(
      'applySource 选中走预拉缓存通道：不直接调用 switchSource'
      '（命中零二次抓取的 Dart 侧 call-count 断言）',
      () async {
        when(
          () => mockApi.switchSourcePrefetch(any(), any(), any()),
        ).thenAnswer((_) async => '{"bookUrl":"https://new.com/book/1"}');
        const match = SourceMatch(
          sourceUrl: 'https://new.com',
          sourceName: '新源',
          bookUrl: 'https://new.com/fallback',
        );

        await readNotifier().applySource(match, bookUrl: 'https://old.com/book');

        verify(
          () => mockApi.switchSourcePrefetch(any(), any(), any()),
        ).called(1);
        // 命中预拉缓存 → Rust 侧零网络直接落地；Dart 侧不得再走旧通道
        verifyNever(() => mockApi.switchSource(any(), any(), any()));
      },
    );

    test('applySource 返回 JSON 无 bookUrl 时回退到候选项 bookUrl', () async {
      when(
        () => mockApi.switchSourcePrefetch(any(), any(), any()),
      ).thenAnswer((_) async => '{}');
      const match = SourceMatch(
        sourceUrl: 'https://new.com',
        sourceName: '新源',
        bookUrl: 'https://new.com/fallback',
      );

      final newUrl = await readNotifier().applySource(
        match,
        bookUrl: 'https://old.com/book',
      );

      expect(newUrl, equals('https://new.com/fallback'));
    });

    test('applySource 异常时清除 applyingUrl 并重新抛出', () async {
      when(
        () => mockApi.switchSourcePrefetch(any(), any(), any()),
      ).thenThrow(Exception('切换失败'));
      const match = SourceMatch(sourceUrl: 'https://new.com');

      await expectLater(
        readNotifier().applySource(match, bookUrl: 'https://old.com/book'),
        throwsA(isA<Exception>()),
      );
      expect(readState().applyingUrl, isNull);
      expect(readState().isApplying, isFalse);
    });

    test('applySource 进行中时再次调用抛出 StateError', () async {
      when(() => mockApi.switchSourcePrefetch(any(), any(), any())).thenAnswer(
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return '{}';
        },
      );
      const match = SourceMatch(sourceUrl: 'https://new.com');

      final f1 = readNotifier().applySource(match, bookUrl: 'https://old.com');
      // 等待第一次调用进入 applying 状态
      await Future<void>.delayed(Duration.zero);
      expect(readState().isApplying, isTrue);

      expect(
        () => readNotifier().applySource(match, bookUrl: 'https://old.com'),
        throwsA(isA<StateError>()),
      );
      await f1;
    });

    test(
      'cancelApply 经 BookApi.cancelSwitchSourceApply'
      '（2026-09-24 换源预拉缓存，对齐上游 cancelChangeSource）',
      () async {
        when(() => mockApi.cancelSwitchSourceApply())
            .thenAnswer((_) async {});

        await readNotifier().cancelApply();
        verify(() => mockApi.cancelSwitchSourceApply()).called(1);
      },
    );

    test(
      'search 批次携带 source_name 时进度文案对齐上游'
      '「结果 N，进度 M/K：源名」（values-zh/strings.xml:1457）',
      () async {
        stubSearchStream(Stream.value(makeBatch(
          matches: [rawMatch('https://a.com', 'A源', 90)],
          finished: 3,
          total: 5,
        )));

        await readNotifier().search('斗破苍穹', '天蚕土豆');

        final state = readState();
        // 搜索完成后进度字段清空，但加载态文案（isLoading 窗口内）按
        // 最后批次状态渲染——这里直接以终态字段构造验证渲染口径
        final loadingState = const ChangeSourceState().copyWith(
          isLoading: true,
          progressFinished: 3,
          progressTotal: 5,
          progressLastSourceName: 'A源',
        );
        expect(
          loadingState.loadingProgressLabel(2),
          equals('结果 2，进度 3/5：A源'),
        );
        // 源名缺失/为空 → 退化为「结果 N，进度 M/K」
        expect(
          loadingState
              .copyWith(progressLastSourceName: null)
              .loadingProgressLabel(2),
          equals('结果 2，进度 3/5'),
        );
        // 无 x/y（流启动前占位）→ 搜索中
        expect(
          const ChangeSourceState().loadingProgressLabel(2),
          equals('结果 2，搜索中…'),
        );
        // 终态：进度字段已清空
        expect(state.progressLastSourceName, isNull);
      },
    );

    test('search 进行中逐批记录 progressLastSourceName，终态清空', () async {
      final controller = StreamController<Map<String, dynamic>>();
      stubSearchStream(controller.stream);
      String? midSourceName;
      int? midFinished;
      int? midTotal;

      final f = readNotifier().search('斗破苍穹', '天蚕土豆');
      // 首批：source_name='A源'（对齐 Rust 批次契约字段）
      controller.add(makeBatch(
        matches: [rawMatch('https://a.com', 'A源', 90)],
        finished: 1,
        total: 2,
        sourceName: 'A源',
      ));
      // 等待首批被 notifier 消费
      await Future<void>.delayed(const Duration(milliseconds: 10));
      midSourceName = readState().progressLastSourceName;
      midFinished = readState().progressFinished;
      midTotal = readState().progressTotal;
      // 末批：source_name='B源'
      controller.add(makeBatch(
        matches: [
          rawMatch('https://a.com', 'A源', 90),
          rawMatch('https://b.com', 'B源', 70),
        ],
        finished: 2,
        total: 2,
        sourceName: 'B源',
      ));
      await controller.close();
      await f;

      // 进行中（首批消费后）：记录该批 source_name 与 x/y
      expect(midSourceName, equals('A源'));
      expect(midFinished, equals(1));
      expect(midTotal, equals(2));
      // 终态：进度字段（含 progressLastSourceName）清空
      final state = readState();
      expect(state.progressFinished, isNull);
      expect(state.progressTotal, isNull);
      expect(state.progressLastSourceName, isNull);
      expect(state.results.length, equals(2));
    });

    test('search 异常路径同样清空 progressLastSourceName', () async {
      stubSearchStream(Stream.fromFuture(
        Future<void>.delayed(const Duration(milliseconds: 10)).then((
          _,
        ) {
          throw Exception('搜索中断');
        }),
      ));

      await readNotifier().search('斗破苍穹', '天蚕土豆');

      final state = readState();
      expect(state.error, contains('搜索中断'));
      expect(state.progressFinished, isNull);
      expect(state.progressTotal, isNull);
      expect(state.progressLastSourceName, isNull);
    });

    test('updateBookScore 经 BookApi 持久化并更新本地 bookScore', () async {
      when(
        () => mockApi.updateSearchBookScore(any(), any()),
      ).thenAnswer((_) async {});
      stubSearchStream(Stream.value(
        makeBatch(matches: [rawMatch('https://a.com', 'A源', 90)]),
      ));

      await readNotifier().search('斗破苍穹', '天蚕土豆');
      final bookUrl = readState().results.first.bookUrl;

      await readNotifier().updateBookScore(bookUrl, 1);

      expect(readState().results.first.bookScore, equals(1));
      verify(() => mockApi.updateSearchBookScore(bookUrl, 1)).called(1);
    });

    test('moveToTop / moveToBottom 本地重排', () async {
      stubSearchStream(Stream.value(makeBatch(
        matches: [
          rawMatch('https://a.com', 'A源', 90),
          rawMatch('https://b.com', 'B源', 70),
        ],
        finished: 2,
        total: 2,
      )));
      await readNotifier().search('斗破苍穹', '天蚕土豆');

      final bUrl = readState().results.last.bookUrl;
      readNotifier().moveToTop(bUrl);
      expect(readState().results.first.sourceUrl, equals('https://b.com'));

      readNotifier().moveToBottom(bUrl);
      expect(readState().results.last.sourceUrl, equals('https://b.com'));
    });

    test('deleteSearchBookItem 移除列表项', () async {
      when(() => mockApi.deleteSearchBook(any())).thenAnswer((_) async {});
      stubSearchStream(Stream.value(makeBatch(
        matches: [
          rawMatch('https://a.com', 'A源', 90),
          rawMatch('https://b.com', 'B源', 70),
        ],
        finished: 2,
        total: 2,
      )));
      await readNotifier().search('斗破苍穹', '天蚕土豆');

      final removed = await readNotifier().deleteSearchBookItem(
        readState().results.first.bookUrl,
      );

      expect(removed, isNotNull);
      expect(readState().results.length, equals(1));
      verify(() => mockApi.deleteSearchBook(any())).called(1);
    });
  });
}
