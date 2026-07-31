import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_legado/src/providers/rss_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late RssProvider provider;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    provider = RssProvider(mockApi);
  });

  group('RssProvider 初始状态', () {
    test('初始源列表为空', () {
      expect(provider.sources, isEmpty);
      expect(provider.isEmpty, isTrue);
    });

    test('初始文章列表为空', () {
      expect(provider.articles, isEmpty);
    });

    test('初始无选中源', () {
      expect(provider.selectedSource, isNull);
    });

    test('初始非加载状态', () {
      expect(provider.isLoadingSources, isFalse);
      expect(provider.isLoadingArticles, isFalse);
      expect(provider.isLoading, isFalse);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });
  });

  group('RssProvider loadSources（mock API）', () {
    test('成功加载 RSS 源列表', () async {
      final sources = [
        const RssSource(sourceUrl: 'https://rss1.com', sourceName: '源1'),
        const RssSource(sourceUrl: 'https://rss2.com', sourceName: '源2'),
      ];
      when(() => mockApi.getRssSources()).thenAnswer((_) async => sources);

      await provider.loadSources();

      expect(provider.sources.length, equals(2));
      expect(provider.isEmpty, isFalse);
      expect(provider.isLoadingSources, isFalse);
      expect(provider.error, isNull);
    });

    test('加载失败时设置 BridgeError', () async {
      when(() => mockApi.getRssSources())
          .thenThrow(const BridgeError(message: 'RSS 加载失败'));

      await provider.loadSources();

      expect(provider.error, equals('RSS 加载失败'));
      expect(provider.isLoadingSources, isFalse);
      expect(provider.sources, isEmpty);
    });

    test('加载失败时设置普通异常', () async {
      when(() => mockApi.getRssSources()).thenThrow(Exception('网络'));

      await provider.loadSources();

      expect(provider.error, contains('网络'));
      expect(provider.isLoadingSources, isFalse);
    });

    test('loadSources 触发通知', () async {
      when(() => mockApi.getRssSources()).thenAnswer((_) async => []);
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      await provider.loadSources();
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('RssProvider selectSource（mock API）', () {
    final testSource = const RssSource(
      sourceUrl: 'https://rss.com',
      sourceName: '测试源',
    );

    test('选择源后加载文章', () async {
      final articles = [
        const RssFeedArticle(title: '文章1', url: 'https://a.com/1'),
        const RssFeedArticle(title: '文章2', url: 'https://a.com/2'),
      ];
      when(() => mockApi.getRssArticles(any()))
          .thenAnswer((_) async => articles);

      await provider.selectSource(testSource);

      expect(provider.selectedSource, equals(testSource));
      expect(provider.articles.length, equals(2));
      expect(provider.isLoadingArticles, isFalse);
      expect(provider.error, isNull);
    });

    test('选择源失败时设置错误', () async {
      when(() => mockApi.getRssArticles(any()))
          .thenThrow(const BridgeError(message: '获取文章失败'));

      await provider.selectSource(testSource);

      expect(provider.error, equals('获取文章失败'));
      expect(provider.isLoadingArticles, isFalse);
      expect(provider.articles, isEmpty);
    });

    test('selectSource 清空旧文章', () async {
      when(() => mockApi.getRssArticles(any()))
          .thenAnswer((_) async => [const RssFeedArticle(title: 'a', url: 'u')]);

      await provider.selectSource(testSource);
      expect(provider.articles.length, equals(1));

      // 选择另一个源
      final other = const RssSource(sourceUrl: 'https://other.com', sourceName: '其他');
      when(() => mockApi.getRssArticles('https://other.com'))
          .thenAnswer((_) async => []);
      await provider.selectSource(other);

      expect(provider.articles, isEmpty);
      expect(provider.selectedSource, equals(other));
    });
  });

  group('RssProvider refreshArticles', () {
    test('无选中源时不抛异常', () async {
      await provider.refreshArticles();
      expect(provider.articles, isEmpty);
      expect(provider.selectedSource, isNull);
    });

    test('有选中源时重新加载文章', () async {
      final source = const RssSource(sourceUrl: 'https://r.com', sourceName: 'R');
      when(() => mockApi.getRssArticles(any()))
          .thenAnswer((_) async => [const RssFeedArticle(title: 'x', url: 'u')]);

      await provider.selectSource(source);
      await provider.refreshArticles();

      verify(() => mockApi.getRssArticles('https://r.com')).called(2);
    });
  });

  group('RssProvider addSource（mock API）', () {
    test('成功添加 RSS 源', () async {
      final added = const RssSource(sourceUrl: 'https://new.com', sourceName: '新源');
      when(() => mockApi.addRssSource(any())).thenAnswer((_) async => added);

      await provider.addSource('新源', 'https://new.com');

      expect(provider.sources.length, equals(1));
      expect(provider.sources.first.sourceName, equals('新源'));
      expect(provider.error, isNull);
    });

    test('添加失败时设置错误', () async {
      when(() => mockApi.addRssSource(any()))
          .thenThrow(const BridgeError(message: '添加失败'));

      await provider.addSource('bad', 'https://bad.com');

      expect(provider.error, equals('添加失败'));
      expect(provider.sources, isEmpty);
    });
  });

  group('RssProvider removeSource（mock API）', () {
    test('成功删除 RSS 源', () async {
      final sources = [
        const RssSource(sourceUrl: 'https://a.com', sourceName: 'A'),
        const RssSource(sourceUrl: 'https://b.com', sourceName: 'B'),
      ];
      when(() => mockApi.getRssSources()).thenAnswer((_) async => sources);
      when(() => mockApi.deleteRssSource(any())).thenAnswer((_) async {});

      await provider.loadSources();
      await provider.removeSource('https://a.com');

      expect(provider.sources.length, equals(1));
      expect(provider.sources.first.sourceUrl, equals('https://b.com'));
    });

    test('删除当前选中源时清除选中状态', () async {
      final source = const RssSource(sourceUrl: 'https://a.com', sourceName: 'A');
      when(() => mockApi.getRssSources()).thenAnswer((_) async => [source]);
      when(() => mockApi.getRssArticles(any())).thenAnswer((_) async => []);
      when(() => mockApi.deleteRssSource(any())).thenAnswer((_) async {});

      await provider.loadSources();
      await provider.selectSource(source);
      await provider.removeSource('https://a.com');

      expect(provider.selectedSource, isNull);
      expect(provider.articles, isEmpty);
    });

    test('删除失败时设置错误', () async {
      when(() => mockApi.deleteRssSource(any()))
          .thenThrow(const BridgeError(message: '删除失败'));

      await provider.removeSource('https://x.com');

      expect(provider.error, equals('删除失败'));
    });
  });

  group('RssProvider 状态管理', () {
    test('clearSelectedSource 清除选中源和文章', () {
      provider.clearSelectedSource();
      expect(provider.selectedSource, isNull);
      expect(provider.articles, isEmpty);
    });

    test('clearSelectedSource 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearSelectedSource();
      expect(notified, isTrue);
    });

    test('clearError 清除错误', () {
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('clearError 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearError();
      expect(notified, isTrue);
    });

    test('isLoading 是 sources 或 articles 加载的或', () {
      expect(provider.isLoading, isFalse);
    });

    test('多次 clearSelectedSource 不抛异常', () {
      provider.clearSelectedSource();
      provider.clearSelectedSource();
      expect(provider.selectedSource, isNull);
    });
  });
}
