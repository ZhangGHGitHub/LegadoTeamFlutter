// SearchNotifier 单元测试
//
// 覆盖：初始状态/搜索历史（去重置顶截断持久化）/联想（前缀过滤）/书源筛选/分组筛选/
// search 流式契约（空关键词/正常批次/多源追加去重/进度/异常/trim/sourceUrls 传递/分组解析/多组名/空解析/降级/搜全部）/isEmpty
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/search/search_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    // 搜索历史后端默认桩：空历史 + 持久化/清空 no-op（各测试可覆写 getSearchHistory）
    when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
        .thenAnswer((_) async => []);
    when(() => mockApi.addSearchKeyword(any(), any()))
        .thenAnswer((_) async {});
    when(() => mockApi.clearSearchHistory()).thenAnswer((_) async {});
    // [fix31] 流式搜索契约默认桩：取消 no-op + 空流（各测试可覆写 searchMultiStream）
    when(() => mockApi.cancelSearch()).thenAnswer((_) async {});
    when(() =>
            mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    // [v2.0.31] 搜索范围持久化：默认无持久化 scope
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  /// 等待 build() 微任务（loadHistory）完成
  Future<void> pumpInit() async {
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
  }

  /// 等待流式批次事件（listen onData/onError/onDone）送达
  Future<void> pumpStream({int turns = 20}) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 构造 Rust searchMultiStream 批次（字段契约见 BookApi.searchMultiStream）
  Map<String, dynamic> makeBatch({
    List<Map<String, dynamic>> books = const [],
    String? error,
    int finished = 1,
    int total = 1,
    bool isLast = true,
  }) =>
      {
        'source_index': 0,
        'source_url': 'https://a.com',
        'source_name': '笔趣阁',
        'books': books,
        'error': error,
        'finished_count': finished,
        'total_count': total,
        'is_last': isLast,
      };

  SearchState readState() => container.read(searchNotifierProvider);
  SearchNotifier readNotifier() =>
      container.read(searchNotifierProvider.notifier);

  group('SearchNotifier 初始状态', () {
    test('各字段为默认值', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      expect(readState().keyword, equals(''));
      expect(readState().results, isEmpty);
      expect(readState().hasResults, isFalse);
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
      expect(readState().searchHistory, isEmpty);
      expect(readState().selectedSourceUrls, isEmpty);
      expect(readState().selectedGroups, isEmpty);
      expect(readState().isEmpty, isFalse);
      expect(readState().hasFilter, isFalse);
    });
  });

  group('SearchNotifier 打开页重置（fix33：默认不显示上次结果）', () {
    test('resetForOpen 清空上次结果/关键词/进度，不 auto-search', () async {
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream.fromIterable([
                makeBatch(books: [
                  {
                    'origin': 'https://a.com',
                    'originName': '笔趣阁',
                    'name': '上次结果书',
                    'author': '作者',
                    'bookUrl': 'https://a.com/b/1',
                  },
                ]),
              ]));
      container.read(searchNotifierProvider);
      await pumpInit();

      // 先搜一次，state 残留结果（模拟全局单例跨页面保留）
      await readNotifier().search('上次的词');
      await pumpStream();
      expect(readState().results, isNotEmpty);
      expect(readState().keyword, equals('上次的词'));

      // 打开搜索页 → resetForOpen
      readNotifier().resetForOpen();
      await pumpStream();

      expect(readState().results, isEmpty, reason: '打开页默认不显示上次结果');
      expect(readState().keyword, equals(''));
      expect(readState().inputText, equals(''));
      expect(readState().isLoading, isFalse);
      expect(readState().searchedCount, equals(0));
      expect(readState().totalCount, equals(0));
      expect(readState().error, isNull);
      expect(readState().isEmpty, isFalse, reason: '未搜索不显示空态');
      // 不 auto-search：searchMultiStream 仍只被调用一次（上次主动搜索）
      verify(() => mockApi.searchMultiStream(any(),
              sourceUrls: any(named: 'sourceUrls')))
          .called(1);
    });

    test('resetForOpen 保留历史与筛选范围（对齐原版持久化语义）', () async {
      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().addToHistory('重生');
      readNotifier().toggleGroup('正版');

      readNotifier().resetForOpen();

      expect(readState().searchHistory, contains('重生'));
      expect(readState().selectedGroups, contains('正版'));
    });
  });

  group('SearchNotifier 搜索历史管理', () {
    test('addToHistory 添加关键词到历史', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('斗破苍穹');
      expect(readState().searchHistory, contains('斗破苍穹'));
      expect(readState().searchHistory.first, equals('斗破苍穹'));
    });

    test('addToHistory 去重：重复关键词移到最前', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('完美世界');
      await readNotifier().addToHistory('遮天');
      await readNotifier().addToHistory('完美世界');

      expect(readState().searchHistory.length, equals(2));
      expect(readState().searchHistory.first, equals('完美世界'));
      expect(readState().searchHistory[1], equals('遮天'));
    });

    test('addToHistory 截断超过 20 条', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      for (var i = 0; i < 25; i++) {
        await readNotifier().addToHistory('关键词$i');
      }
      expect(readState().searchHistory.length, equals(20));
      expect(readState().searchHistory.first, equals('关键词24'));
    });

    test('clearHistory 清空搜索历史', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('a');
      await readNotifier().addToHistory('b');
      await readNotifier().clearHistory();
      expect(readState().searchHistory, isEmpty);
    });

    test('loadHistory 从 BookApi 加载（取 SearchKeyword.word）', () async {
      when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
          .thenAnswer((_) async => const [
                SearchKeyword(word: '历史1'),
                SearchKeyword(word: '历史2'),
              ]);
      container.read(searchNotifierProvider);
      await pumpInit(); // build() 自动 loadHistory

      expect(readState().searchHistory, equals(['历史1', '历史2']));
    });

    test('addToHistory 经 BookApi.addSearchKeyword 持久化', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('斗破苍穹');
      verify(() => mockApi.addSearchKeyword('斗破苍穹', any())).called(1);
    });

    test('clearHistory 经 BookApi.clearSearchHistory 清后端', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().clearHistory();
      verify(() => mockApi.clearSearchHistory()).called(1);
    });
  });

  group('SearchNotifier 联想（前缀过滤）', () {
    test('setInput 更新 inputText', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().setInput('斗破');
      expect(readState().inputText, equals('斗破'));
    });

    test('setInput 相同值不重复更新状态', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().setInput('a');
      final before = readState();
      readNotifier().setInput('a');
      expect(identical(before, readState()), isTrue);
    });

    test('输入为空时 suggestions 返回全部历史', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('斗破苍穹');
      await readNotifier().addToHistory('完美世界');
      expect(readState().suggestions, equals(['完美世界', '斗破苍穹']));
    });

    test('输入非空时 suggestions 返回前缀匹配项', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('斗破苍穹');
      await readNotifier().addToHistory('斗战神');
      await readNotifier().addToHistory('完美世界');

      readNotifier().setInput('斗');
      expect(readState().suggestions, containsAll(['斗战神', '斗破苍穹']));
      expect(readState().suggestions, isNot(contains('完美世界')));
    });

    test('suggestions 对输入做 trim', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('遮天');
      readNotifier().setInput('  遮  ');
      expect(readState().suggestions, equals(['遮天']));
    });

    test('无匹配前缀时 suggestions 为空', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().addToHistory('斗破苍穹');
      readNotifier().setInput('xyz');
      expect(readState().suggestions, isEmpty);
    });
  });

  group('SearchNotifier 书源筛选', () {
    test('clearResults 清空关键词和结果', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().clearResults();
      expect(readState().keyword, equals(''));
      expect(readState().results, isEmpty);
      expect(readState().error, isNull);
    });

    test('toggleSource 添加书源过滤', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleSource('https://source1.com');
      expect(readState().selectedSourceUrls, contains('https://source1.com'));
    });

    test('toggleSource 再次点击移除书源', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleSource('https://source1.com');
      readNotifier().toggleSource('https://source1.com');
      expect(
          readState().selectedSourceUrls, isNot(contains('https://source1.com')));
    });

    test('toggleSource 支持多个书源', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleSource('https://a.com');
      readNotifier().toggleSource('https://b.com');
      expect(readState().selectedSourceUrls.length, equals(2));
    });

    test('clearSourceFilter 清空所有书源过滤', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleSource('https://a.com');
      readNotifier().toggleSource('https://b.com');
      readNotifier().clearSourceFilter();
      expect(readState().selectedSourceUrls, isEmpty);
    });

    test('toggleSource 后 hasFilter 为 true', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleSource('https://a.com');
      expect(readState().hasFilter, isTrue);
    });
  });

  group('SearchNotifier 分组筛选', () {
    test('toggleGroup 添加分组', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleGroup('玄幻');
      expect(readState().selectedGroups, contains('玄幻'));
    });

    test('toggleGroup 再次点击移除分组', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleGroup('玄幻');
      readNotifier().toggleGroup('玄幻');
      expect(readState().selectedGroups, isNot(contains('玄幻')));
    });

    test('toggleGroup 支持多个分组', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleGroup('玄幻');
      readNotifier().toggleGroup('都市');
      expect(readState().selectedGroups.length, equals(2));
    });

    test('clearGroupFilter 清空分组筛选', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleGroup('玄幻');
      readNotifier().toggleGroup('都市');
      readNotifier().clearGroupFilter();
      expect(readState().selectedGroups, isEmpty);
    });

    test('toggleGroup 后 hasFilter 为 true', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleGroup('玄幻');
      expect(readState().hasFilter, isTrue);
    });

    test('clearAllFilter 同时清空书源和分组', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleSource('https://a.com');
      readNotifier().toggleGroup('玄幻');
      readNotifier().clearAllFilter();
      expect(readState().selectedSourceUrls, isEmpty);
      expect(readState().selectedGroups, isEmpty);
      expect(readState().hasFilter, isFalse);
    });

    test('selectGroupExclusive 原子单选并清空书源多选', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      readNotifier().toggleSource('https://a.com');
      readNotifier().toggleGroup('都市');
      readNotifier().selectGroupExclusive('漫画书源');

      expect(readState().selectedGroups, equals({'漫画书源'}));
      expect(readState().selectedSourceUrls, isEmpty);
    });
  });

  group('SearchNotifier search 方法（mock API）', () {
    test('空关键词不触发搜索', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().search('   ');
      expect(readState().isLoading, isFalse);
      expect(readState().keyword, equals(''));
      verifyNever(() => mockApi
          .searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')));
    });

    test('正常搜索流式返回结果', () async {
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream.fromIterable([
                makeBatch(books: [
                  {
                    'name': '斗破苍穹',
                    'author': '天蚕土豆',
                    'bookUrl': 'https://a.com/1',
                    'origin': 'https://a.com',
                    'originName': '笔趣阁',
                  },
                ]),
              ]));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('斗破苍穹');
      await pumpStream();

      expect(readState().keyword, equals('斗破苍穹'));
      expect(readState().results.length, equals(1));
      expect(readState().results.first.book.name, equals('斗破苍穹'));
      expect(readState().results.first.book.author, equals('天蚕土豆'));
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
      expect(readState().hasResults, isTrue);
    });

    test('多源批次同名同作者聚合为一条，originsCount 累加（进度 x/y 更新）', () async {
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream.fromIterable([
                makeBatch(
                  books: [
                    {
                      'name': '遮天',
                      'author': '辰东',
                      'bookUrl': 'https://a.com/1',
                      'origin': 'https://a.com',
                      'originName': '笔趣阁',
                    },
                  ],
                  finished: 1,
                  total: 2,
                  isLast: false,
                ),
                makeBatch(
                  books: [
                    // 同名同作者不同 origin → 聚合为一条（对齐 mergeItems.addOrigin）
                    {
                      'name': '遮天',
                      'author': '辰东',
                      'bookUrl': 'https://b.com/1',
                      'origin': 'https://b.com',
                      'originName': '起点中文网',
                    },
                    {
                      'name': '完美世界',
                      'author': '辰东',
                      'bookUrl': 'https://b.com/2',
                      'origin': 'https://b.com',
                      'originName': '起点中文网',
                    },
                  ],
                  finished: 2,
                  total: 2,
                  isLast: true,
                ),
              ]));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('遮天');
      await pumpStream();

      // 「遮天」两源聚合 1 条 +「完美世界」1 条 → 2 条
      expect(readState().results.length, equals(2));
      final zhetian =
          readState().results.where((r) => r.book.name == '遮天').single;
      expect(zhetian.originsCount, equals(2));
      expect(zhetian.effectiveOrigins, containsAll([
        'https://a.com',
        'https://b.com',
      ]));
      expect(
        readState().results.map((r) => r.book.name),
        containsAll(['遮天', '完美世界']),
      );
      // equal 桶「遮天」应排在 contains「完美世界」之前，且多源优先
      expect(readState().results.first.book.name, equals('遮天'));
      // 进度对齐批次 finished_count/total_count
      expect(readState().searchedCount, equals(2));
      expect(readState().totalCount, equals(2));
      expect(readState().isLoading, isFalse);
    });

    test('空批次记 0 条 success 不报错（无匹配源，整体正常完成）', () async {
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream.fromIterable([
                makeBatch(books: const [], finished: 1, total: 2, isLast: false),
                makeBatch(books: const [], finished: 2, total: 2, isLast: true),
              ]));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('无匹配关键词');
      await pumpStream();

      expect(readState().results, isEmpty);
      expect(readState().error, isNull, reason: '空批次是 success 而非 error');
      expect(readState().isLoading, isFalse, reason: '整体搜索正常完成');
      expect(readState().searchedCount, equals(2));
      expect(readState().totalCount, equals(2));
      expect(readState().isEmpty, isTrue, reason: 'UI 应显示无结果空态');
    });

    test('失败批次静默不弹错误、仅 appLogPush 留痕（对齐原版 SearchModel）', () async {
      // [UI-fix v2.0.11 | 2026-08-10] 批次 error 消费：单源失败不阻断整体、
      // 不写 state.error（杜绝「异常书源」弹窗路径），按原版 AppLog.put 语义留痕 — Reasonix
      when(() => mockApi.appLogPush(
          level: any(named: 'level'), message: any(named: 'message')))
          .thenAnswer((_) async {});
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream.fromIterable([
                makeBatch(
                    error: '搜索请求失败: HTTP 500',
                    finished: 1,
                    total: 2,
                    isLast: false),
                makeBatch(
                  books: [
                    {
                      'origin': 'https://a.com',
                      'originName': '笔趣阁',
                      'name': '成功书',
                      'author': '作者',
                      'bookUrl': 'https://a.com/b/1',
                    },
                  ],
                  finished: 2,
                  total: 2,
                  isLast: true,
                ),
              ]));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('关键词');
      await pumpStream();

      // 静默：error 保持 null，成功源结果正常合并、进度正常推进
      expect(readState().error, isNull, reason: '失败源不写 UI 错误态');
      expect(readState().results, hasLength(1));
      expect(readState().searchedCount, equals(2));
      expect(readState().isLoading, isFalse);
      // 留痕：error 级别记录「书源搜索出错」（对齐原版 AppLog.put 文案）
      final captured = verify(() => mockApi.appLogPush(
          level: 'error', message: captureAny(named: 'message'))).captured;
      expect(captured.single, contains('书源搜索出错'));
    });

    test('全部批次失败时结果为空、error 仍为 null（UI 走无结果空态）', () async {
      when(() => mockApi.appLogPush(
          level: any(named: 'level'), message: any(named: 'message')))
          .thenAnswer((_) async {});
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream.fromIterable([
                makeBatch(
                    error: '书源 searchUrl 为空',
                    finished: 1,
                    total: 1,
                    isLast: true),
              ]));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('关键词');
      await pumpStream();

      expect(readState().results, isEmpty);
      expect(readState().error, isNull);
      expect(readState().isEmpty, isTrue, reason: '全部失败按原版语义显示空态而非错误页');
      final captured = verify(() => mockApi.appLogPush(
          level: 'error', message: captureAny(named: 'message'))).captured;
      expect(captured.single, contains('书源搜索出错'));
    });

    test('搜索完成后 loading 为 false（空流）', () async {
      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('测试');
      await pumpStream();

      expect(readState().isLoading, isFalse);
    });

    test('流错误时设置 error（BridgeError）', () async {
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream<Map<String, dynamic>>.error(
              const BridgeError(message: '网络超时')));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('测试');
      await pumpStream();

      expect(readState().error, equals('网络超时'));
      expect(readState().isLoading, isFalse);
      expect(readState().results, isEmpty);
    });

    test('流错误时设置 error（普通异常）', () async {
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer(
              (_) => Stream<Map<String, dynamic>>.error(Exception('未知错误')));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('测试');
      await pumpStream();

      expect(readState().error, contains('未知错误'));
      expect(readState().isLoading, isFalse);
    });

    test('搜索后关键词被 trim', () async {
      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('  斗破苍穹  ');

      expect(readState().keyword, equals('斗破苍穹'));
    });

    test('搜索后关键词被加入历史', () async {
      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('遮天');

      expect(readState().searchHistory, contains('遮天'));
    });

    test('有选中书源时传递 sourceUrls 参数', () async {
      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleSource('https://a.com');
      await readNotifier().search('测试');
      await pumpStream();

      verify(() => mockApi.searchMultiStream(
            '测试',
            sourceUrls: ['https://a.com'],
          )).called(1);
    });

    test('有选中分组时解析分组书源', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://xuanhuan.com',
          bookSourceName: '玄幻源',
          bookSourceGroup: '玄幻',
        ),
        const BookSource(
          bookSourceUrl: 'https://dushi.com',
          bookSourceName: '都市源',
          bookSourceGroup: '都市',
        ),
      ];
      when(() => mockApi.getEnabledBookSources()).thenAnswer((_) async => sources);

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleGroup('玄幻');
      await readNotifier().search('测试');
      await pumpStream();

      verify(() => mockApi.searchMultiStream(
            '测试',
            sourceUrls: ['https://xuanhuan.com'],
          )).called(1);
    });

    test('分组含多组名（逗号分隔）时正确匹配', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://multi.com',
          bookSourceName: '多组源',
          bookSourceGroup: '玄幻,仙侠',
        ),
      ];
      when(() => mockApi.getEnabledBookSources()).thenAnswer((_) async => sources);

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleGroup('仙侠');
      await readNotifier().search('测试');
      await pumpStream();

      verify(() => mockApi.searchMultiStream(
            '测试',
            sourceUrls: ['https://multi.com'],
          )).called(1);
    });

    test('选中分组但解析结果为空时设置错误提示', () async {
      when(() => mockApi.getEnabledBookSources()).thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleGroup('不存在的分组');
      await readNotifier().search('测试');

      expect(readState().error, equals('所选筛选范围内无有效书源，请调整筛选条件'));
      verifyNever(() => mockApi
          .searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')));
    });

    test('分组解析失败时仅使用直接选中的书源', () async {
      when(() => mockApi.getEnabledBookSources())
          .thenThrow(Exception('DB error'));

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleSource('https://direct.com');
      readNotifier().toggleGroup('玄幻');
      await readNotifier().search('测试');
      await pumpStream();

      verify(() => mockApi.searchMultiStream(
            '测试',
            sourceUrls: ['https://direct.com'],
          )).called(1);
    });

    test('无筛选条件时 sourceUrls 传 null（搜索全部）', () async {
      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('全部搜索');
      await pumpStream();

      verify(() => mockApi.searchMultiStream('全部搜索', sourceUrls: null))
          .called(1);
    });
  });

  group('SearchNotifier isEmpty 逻辑', () {
    test('有结果时 isEmpty 为 false', () async {
      when(() =>
              mockApi.searchMultiStream(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) => Stream.fromIterable([
                makeBatch(books: [
                  {
                    'name': 'a',
                    'author': '',
                    'bookUrl': 'https://a.com/1',
                    'origin': 'https://a.com',
                    'originName': 's',
                  },
                ]),
              ]));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('a');
      await pumpStream();

      expect(readState().isEmpty, isFalse);
    });

    test('无结果且有关键词且非加载时 isEmpty 为 true', () async {
      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('无结果关键词');
      await pumpStream();

      expect(readState().isEmpty, isTrue);
    });
  });

  group('applyPrecisionSearch 精准搜索（fix34：对齐原版 SearchModel 语义）', () {
    SearchResult mk(
      String name,
      String author, {
      String? kind,
      String origin = '',
      String sourceName = '',
    }) =>
        SearchResult(
          book: Book(
            name: name,
            author: author,
            kind: kind,
            origin: origin,
          ),
          sourceName: sourceName.isEmpty ? origin : sourceName,
          origins: origin.isEmpty ? const {} : {origin},
        );

    test('同名/同作者精确命中保留且排最前（equal 桶）', () {
      final results = [
        mk('重生1990', '张三', origin: 'a'),
        mk('重生', '李四', origin: 'b'),
        mk('某书', '重生', origin: 'c'),
      ];

      final out = applyPrecisionSearch(results, '重生');

      expect(out, hasLength(3));
      expect(out.map((r) => r.book.name), equals(['重生', '某书', '重生1990']));
      expect(out.first.book.name, equals('重生'));
    });

    test('书名/作者包含关键词保留（contains 桶，非精确相等）', () {
      final results = [
        mk('重生之门', '王五', origin: 'a'),
        mk('平凡之路', '重生者', origin: 'b'),
      ];

      final out = applyPrecisionSearch(results, '重生');

      expect(out, hasLength(2));
      expect(out[0].book.name, equals('重生之门'));
      expect(out[1].book.name, equals('平凡之路'));
    });

    test('kind 标签包含关键词保留（tags 桶，顺序 equal→tags→contains）', () {
      final results = [
        mk('重生之路', '甲', origin: 'a'), // contains
        mk('都市情缘', '乙', kind: '重生,都市', origin: 'b'), // tags
        mk('重生', '丙', origin: 'c'), // equal
      ];

      final out = applyPrecisionSearch(results, '重生');

      expect(out.map((r) => r.book.name), equals(['重生', '都市情缘', '重生之路']));
    });

    test('无关项（other 桶）精准模式（keepOther: false）被丢弃', () {
      final results = [
        mk('重生', '甲', origin: 'a'),
        mk('斗破苍穹', '天蚕土豆', kind: '玄幻', origin: 'b'),
      ];

      final out = applyPrecisionSearch(results, '重生', keepOther: false);

      expect(out, hasLength(1));
      expect(out.single.book.name, equals('重生'));
    });

    test('无关项（other 桶）默认模式（keepOther: true）保留且排在末尾', () {
      // [UI-fix v2.0.10 | 2026-08-10] 对齐原版 mergeItems：默认搜索保留
      // other 桶（追加末尾），仅精准模式丢弃 — Reasonix
      final results = [
        mk('重生', '甲', origin: 'a'),
        mk('斗破苍穹', '天蚕土豆', kind: '玄幻', origin: 'b'),
      ];

      final out = applyPrecisionSearch(results, '重生');

      expect(out, hasLength(2));
      expect(out.first.book.name, equals('重生'));
      expect(out.last.book.name, equals('斗破苍穹'));
    });

    test('归一化一致：kind 为 null 不抛错且按空串处理', () {
      final results = [
        mk('重生之门', '甲', origin: 'a'), // kind null
        mk('斗破', '乙', origin: 'b'),
      ];

      final out = applyPrecisionSearch(results, '重生', keepOther: false);

      expect(out, hasLength(1));
      expect(out.single.book.name, equals('重生之门'));
    });

    test('关键词为空返回原列表', () {
      final results = [mk('斗破苍穹', '天蚕土豆', origin: 'a')];

      expect(applyPrecisionSearch(results, ''), same(results));
    });

    test('同名同作者多源聚合为一条且 originsCount 累加（对齐 mergeItems.addOrigin）',
        () {
      final results = [
        mk('一人之下', '米二', origin: 'https://a.com', sourceName: '源A'),
        mk('一人之下', '米二', origin: 'https://b.com', sourceName: '源B'),
        mk('一人之下', '米二', origin: 'https://c.com', sourceName: '源C'),
        mk('一人之下番外', '米二', origin: 'https://d.com', sourceName: '源D'),
      ];

      final out = applyPrecisionSearch(results, '一人之下');

      expect(out, hasLength(2));
      expect(out.first.book.name, equals('一人之下'));
      expect(out.first.originsCount, equals(3));
      expect(out.first.effectiveOrigins, containsAll([
        'https://a.com',
        'https://b.com',
        'https://c.com',
      ]));
      // 多源条排在单源 contains 之前（equal 桶内按 origins 降序）
      expect(out.last.book.name, equals('一人之下番外'));
      expect(out.last.originsCount, equals(1));
    });

    test('作者字段带「作者：」前缀时与纯作者名聚合为一条（对齐 formatBookAuthor）',
        () {
      final results = [
        mk('斗破苍穹', '天蚕土豆', origin: 'https://a.com'),
        mk('斗破苍穹', '作者：天蚕土豆', origin: 'https://b.com'),
        mk('斗破苍穹', '作者: 天蚕土豆', origin: 'https://c.com'),
        mk('斗破苍穹 作者天蚕土豆', '天蚕土豆', origin: 'https://d.com'),
      ];

      final out = applyPrecisionSearch(results, '斗破苍穹');

      expect(out, hasLength(1));
      expect(out.single.book.name, equals('斗破苍穹'));
      expect(out.single.book.author, equals('天蚕土豆'));
      expect(out.single.originsCount, equals(4));
    });

    test('formatBookName / formatBookAuthor 对齐 AppPattern', () {
      expect(formatBookName('斗破苍穹 作者天蚕土豆'), equals('斗破苍穹'));
      expect(formatBookName('凡人修仙传 忘语 著'), equals('凡人修仙传'));
      expect(formatBookAuthor('作者：天蚕土豆'), equals('天蚕土豆'));
      expect(formatBookAuthor('天蚕土豆 著'), equals('天蚕土豆'));
    });

    test('多源条按 originsCount 降序（同桶）', () {
      final results = [
        mk('一人之下', '甲', origin: 'https://1.com'),
        mk('一人之下', '乙', origin: 'https://2a.com'),
        mk('一人之下', '乙', origin: 'https://2b.com'),
        mk('一人之下', '乙', origin: 'https://2c.com'),
      ];

      final out = applyPrecisionSearch(results, '一人之下');

      expect(out.first.book.author, equals('乙'));
      expect(out.first.originsCount, equals(3));
      expect(out.last.book.author, equals('甲'));
      expect(out.last.originsCount, equals(1));
    });
  });
}
