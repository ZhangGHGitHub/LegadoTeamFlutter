// SearchNotifier 单元测试
//
// 覆盖：初始状态/搜索历史（去重置顶截断持久化）/联想（前缀过滤）/书源筛选/分组筛选/
// search（空关键词/正常/异常/trim/sourceUrls 传递/分组解析/多组名/空解析/降级/搜全部）/isEmpty
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/search/search_notifier.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

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
  });

  group('SearchNotifier search 方法（mock API）', () {
    test('空关键词不触发搜索', () async {
      container.read(searchNotifierProvider);
      await pumpInit();

      await readNotifier().search('   ');
      expect(readState().isLoading, isFalse);
      expect(readState().keyword, equals(''));
      verifyNever(
          () => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')));
    });

    test('正常搜索返回结果', () async {
      final fakeResults = [
        SearchResult(
          book: const Book(name: '斗破苍穹', author: '天蚕土豆'),
          sourceName: '笔趣阁',
        ),
      ];
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => fakeResults);

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('斗破苍穹');

      expect(readState().keyword, equals('斗破苍穹'));
      expect(readState().results.length, equals(1));
      expect(readState().results.first.book.name, equals('斗破苍穹'));
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
      expect(readState().hasResults, isTrue);
    });

    test('搜索完成后 loading 为 false', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('测试');

      expect(readState().isLoading, isFalse);
    });

    test('搜索异常时设置 error（BridgeError）', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenThrow(const BridgeError(message: '网络超时'));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('测试');

      expect(readState().error, equals('网络超时'));
      expect(readState().isLoading, isFalse);
      expect(readState().results, isEmpty);
    });

    test('搜索异常时设置 error（普通异常）', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenThrow(Exception('未知错误'));

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('测试');

      expect(readState().error, contains('未知错误'));
      expect(readState().isLoading, isFalse);
    });

    test('搜索后关键词被 trim', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('  斗破苍穹  ');

      expect(readState().keyword, equals('斗破苍穹'));
    });

    test('搜索后关键词被加入历史', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('遮天');

      expect(readState().searchHistory, contains('遮天'));
    });

    test('有选中书源时传递 sourceUrls 参数', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleSource('https://a.com');
      await readNotifier().search('测试');

      verify(() => mockApi.searchBooks(
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
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleGroup('玄幻');
      await readNotifier().search('测试');

      verify(() => mockApi.searchBooks(
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
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleGroup('仙侠');
      await readNotifier().search('测试');

      verify(() => mockApi.searchBooks(
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
      verifyNever(
          () => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')));
    });

    test('分组解析失败时仅使用直接选中的书源', () async {
      when(() => mockApi.getEnabledBookSources())
          .thenThrow(Exception('DB error'));
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      readNotifier().toggleSource('https://direct.com');
      readNotifier().toggleGroup('玄幻');
      await readNotifier().search('测试');

      verify(() => mockApi.searchBooks(
            '测试',
            sourceUrls: ['https://direct.com'],
          )).called(1);
    });

    test('无筛选条件时 sourceUrls 传 null（搜索全部）', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('全部搜索');

      verify(() => mockApi.searchBooks('全部搜索', sourceUrls: null)).called(1);
    });
  });

  group('SearchNotifier isEmpty 逻辑', () {
    test('有结果时 isEmpty 为 false', () async {
      final fakeResults = [
        SearchResult(book: const Book(name: 'a'), sourceName: 's'),
      ];
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => fakeResults);

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('a');

      expect(readState().isEmpty, isFalse);
    });

    test('无结果且有关键词且非加载时 isEmpty 为 true', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      container.read(searchNotifierProvider);
      await pumpInit();
      await readNotifier().search('无结果关键词');

      expect(readState().isEmpty, isTrue);
    });
  });
}
