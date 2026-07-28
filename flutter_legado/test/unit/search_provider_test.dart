import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/providers/search_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  late SearchProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    provider = SearchProvider(RustApi());
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

    test('isEmpty 在空关键词时为 false', () {
      // isEmpty 需要 keyword 非空才为 true
      expect(provider.isEmpty, isFalse);
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
      // 最新的在前面
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
      final p = SearchProvider(RustApi());
      await p.loadHistory();
      expect(p.searchHistory, equals(['历史1', '历史2']));
    });
  });

  group('SearchProvider 状态切换', () {
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
  });
}
