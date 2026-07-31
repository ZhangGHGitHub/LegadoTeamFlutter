import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/providers/search_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late SearchProvider provider;
  late MockRustApi mockApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    provider = SearchProvider(mockApi);
  });

  group('SearchProvider 初始状态', () {
    test('初始关键词为空', () {
      expect(provider.keyword, equals(''));
    });

    test('初始结果为空', () {
      expect(provider.results, isEmpty);
      expect(provider.hasResults, isFalse);
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('初始搜索历史为空', () {
      expect(provider.searchHistory, isEmpty);
    });

    test('初始无选中书源', () {
      expect(provider.selectedSourceUrls, isEmpty);
    });

    test('初始无选中分组', () {
      expect(provider.selectedGroups, isEmpty);
    });

    test('isEmpty 在空关键词时为 false', () {
      expect(provider.isEmpty, isFalse);
    });

    test('hasFilter 初始为 false', () {
      expect(provider.hasFilter, isFalse);
    });
  });

  group('SearchProvider 搜索历史管理', () {
    test('addToHistory 添加关键词到历史', () async {
      await provider.addToHistory('斗破苍穹');
      expect(provider.searchHistory, contains('斗破苍穹'));
      expect(provider.searchHistory.first, equals('斗破苍穹'));
    });

    test('addToHistory 去重：重复关键词移到最前', () async {
      await provider.addToHistory('完美世界');
      await provider.addToHistory('遮天');
      await provider.addToHistory('完美世界');

      expect(provider.searchHistory.length, equals(2));
      expect(provider.searchHistory.first, equals('完美世界'));
      expect(provider.searchHistory[1], equals('遮天'));
    });

    test('addToHistory 截断超过 20 条', () async {
      for (var i = 0; i < 25; i++) {
        await provider.addToHistory('关键词$i');
      }
      expect(provider.searchHistory.length, equals(20));
      expect(provider.searchHistory.first, equals('关键词24'));
    });

    test('addToHistory 触发通知', () async {
      var notified = false;
      provider.addListener(() => notified = true);
      await provider.addToHistory('测试');
      expect(notified, isTrue);
    });

    test('clearHistory 清空搜索历史', () async {
      await provider.addToHistory('a');
      await provider.addToHistory('b');
      await provider.clearHistory();
      expect(provider.searchHistory, isEmpty);
    });

    test('loadHistory 从 SharedPreferences 加载', () async {
      SharedPreferences.setMockInitialValues({
        'search_history': ['历史1', '历史2'],
      });
      final p = SearchProvider(mockApi);
      await p.loadHistory();
      expect(p.searchHistory, equals(['历史1', '历史2']));
    });
  });

  group('SearchProvider 书源筛选', () {
    test('clearResults 清空关键词和结果', () {
      provider.clearResults();
      expect(provider.keyword, equals(''));
      expect(provider.results, isEmpty);
      expect(provider.error, isNull);
    });

    test('clearResults 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearResults();
      expect(notified, isTrue);
    });

    test('toggleSource 添加书源过滤', () {
      provider.toggleSource('https://source1.com');
      expect(provider.selectedSourceUrls, contains('https://source1.com'));
    });

    test('toggleSource 再次点击移除书源', () {
      provider.toggleSource('https://source1.com');
      provider.toggleSource('https://source1.com');
      expect(provider.selectedSourceUrls, isNot(contains('https://source1.com')));
    });

    test('toggleSource 支持多个书源', () {
      provider.toggleSource('https://a.com');
      provider.toggleSource('https://b.com');
      expect(provider.selectedSourceUrls.length, equals(2));
    });

    test('clearSourceFilter 清空所有书源过滤', () {
      provider.toggleSource('https://a.com');
      provider.toggleSource('https://b.com');
      provider.clearSourceFilter();
      expect(provider.selectedSourceUrls, isEmpty);
    });

    test('clearSourceFilter 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearSourceFilter();
      expect(notified, isTrue);
    });

    test('toggleSource 后 hasFilter 为 true', () {
      provider.toggleSource('https://a.com');
      expect(provider.hasFilter, isTrue);
    });
  });

  group('SearchProvider 分组筛选', () {
    test('toggleGroup 添加分组', () {
      provider.toggleGroup('玄幻');
      expect(provider.selectedGroups, contains('玄幻'));
    });

    test('toggleGroup 再次点击移除分组', () {
      provider.toggleGroup('玄幻');
      provider.toggleGroup('玄幻');
      expect(provider.selectedGroups, isNot(contains('玄幻')));
    });

    test('toggleGroup 支持多个分组', () {
      provider.toggleGroup('玄幻');
      provider.toggleGroup('都市');
      expect(provider.selectedGroups.length, equals(2));
    });

    test('toggleGroup 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.toggleGroup('仙侠');
      expect(notified, isTrue);
    });

    test('clearGroupFilter 清空分组筛选', () {
      provider.toggleGroup('玄幻');
      provider.toggleGroup('都市');
      provider.clearGroupFilter();
      expect(provider.selectedGroups, isEmpty);
    });

    test('clearGroupFilter 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearGroupFilter();
      expect(notified, isTrue);
    });

    test('toggleGroup 后 hasFilter 为 true', () {
      provider.toggleGroup('玄幻');
      expect(provider.hasFilter, isTrue);
    });

    test('clearAllFilter 同时清空书源和分组', () {
      provider.toggleSource('https://a.com');
      provider.toggleGroup('玄幻');
      provider.clearAllFilter();
      expect(provider.selectedSourceUrls, isEmpty);
      expect(provider.selectedGroups, isEmpty);
      expect(provider.hasFilter, isFalse);
    });

    test('clearAllFilter 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearAllFilter();
      expect(notified, isTrue);
    });
  });

  group('SearchProvider search 方法（mock API）', () {
    test('空关键词不触发搜索', () async {
      await provider.search('   ');
      expect(provider.loading, isFalse);
      expect(provider.keyword, equals(''));
      verifyNever(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')));
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

      await provider.search('斗破苍穹');

      expect(provider.keyword, equals('斗破苍穹'));
      expect(provider.results.length, equals(1));
      expect(provider.results.first.book.name, equals('斗破苍穹'));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
      expect(provider.hasResults, isTrue);
    });

    test('搜索时 loading 状态正确切换', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      await provider.search('测试');
      // 搜索完成后 loading 应为 false
      expect(provider.loading, isFalse);
    });

    test('搜索异常时设置 error（BridgeError）', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenThrow(const BridgeError(message: '网络超时'));

      await provider.search('测试');

      expect(provider.error, equals('网络超时'));
      expect(provider.loading, isFalse);
      expect(provider.results, isEmpty);
    });

    test('搜索异常时设置 error（普通异常）', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenThrow(Exception('未知错误'));

      await provider.search('测试');

      expect(provider.error, contains('未知错误'));
      expect(provider.loading, isFalse);
    });

    test('搜索后关键词被 trim', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      await provider.search('  斗破苍穹  ');
      expect(provider.keyword, equals('斗破苍穹'));
    });

    test('搜索后关键词被加入历史', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      await provider.search('遮天');
      expect(provider.searchHistory, contains('遮天'));
    });

    test('有选中书源时传递 sourceUrls 参数', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      provider.toggleSource('https://a.com');
      await provider.search('测试');

      verify(() => mockApi.searchBooks(
            '测试',
            sourceUrls: ['https://a.com'],
          )).called(1);
    });

    test('有选中分组时解析分组书源', () async {
      // 模拟 getEnabledBookSources 返回带分组的书源
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

      provider.toggleGroup('玄幻');
      await provider.search('测试');

      // 验证搜索时只传了玄幻分组的书源
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

      provider.toggleGroup('仙侠');
      await provider.search('测试');

      verify(() => mockApi.searchBooks(
            '测试',
            sourceUrls: ['https://multi.com'],
          )).called(1);
    });

    test('选中分组但解析结果为空时设置错误提示', () async {
      // 返回空书源列表
      when(() => mockApi.getEnabledBookSources()).thenAnswer((_) async => []);

      provider.toggleGroup('不存在的分组');
      await provider.search('测试');

      expect(provider.error, equals('所选筛选范围内无有效书源，请调整筛选条件'));
      verifyNever(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')));
    });

    test('分组解析失败时仅使用直接选中的书源', () async {
      when(() => mockApi.getEnabledBookSources())
          .thenThrow(Exception('DB error'));
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      provider.toggleSource('https://direct.com');
      provider.toggleGroup('玄幻');
      await provider.search('测试');

      // 分组解析失败，但直接选中的书源仍然有效
      verify(() => mockApi.searchBooks(
            '测试',
            sourceUrls: ['https://direct.com'],
          )).called(1);
    });

    test('无筛选条件时 sourceUrls 传 null（搜索全部）', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      await provider.search('全部搜索');

      verify(() => mockApi.searchBooks('全部搜索', sourceUrls: null)).called(1);
    });
  });

  group('SearchProvider isEmpty 逻辑', () {
    test('有结果时 isEmpty 为 false', () async {
      final fakeResults = [
        SearchResult(book: const Book(name: 'a'), sourceName: 's'),
      ];
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => fakeResults);

      await provider.search('a');
      expect(provider.isEmpty, isFalse);
    });

    test('无结果且有关键词且非加载时 isEmpty 为 true', () async {
      when(() => mockApi.searchBooks(any(), sourceUrls: any(named: 'sourceUrls')))
          .thenAnswer((_) async => []);

      await provider.search('无结果关键词');
      expect(provider.isEmpty, isTrue);
    });
  });
}
