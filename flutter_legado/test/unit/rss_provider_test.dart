// RssNotifier 单元测试
//
// 覆盖：初始状态/loadSources/selectSource/refreshArticles/addSource/
// removeSource/状态管理（clear*）/分组筛选（对齐安卓 RssFragment）
//
// 迁移自原 RssProvider（ChangeNotifier）测试，改为 Riverpod 范式：
// 使用 ProviderContainer + bookApiProvider.overrideWithValue(mockApi)。
// 原「触发通知」测试点改为通过 container.listen 断言状态变更会触发监听。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    // 跳过首启默认源导入（对标已达 LocalConfig.rssSourceVersion=6）
    SharedPreferences.setMockInitialValues({kRssSourceVersionKey: 6});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  RssState readState() => container.read(rssNotifierProvider);
  RssNotifier readNotifier() => container.read(rssNotifierProvider.notifier);

  group('RssNotifier 初始状态', () {
    test('初始源列表为空', () {
      expect(readState().sources, isEmpty);
      expect(readState().isEmpty, isTrue);
    });

    test('初始文章列表为空', () {
      expect(readState().articles, isEmpty);
    });

    test('初始无选中源', () {
      expect(readState().selectedSource, isNull);
    });

    test('初始非加载状态', () {
      expect(readState().isLoadingSources, isFalse);
      expect(readState().isLoadingArticles, isFalse);
      expect(readState().isLoading, isFalse);
    });

    test('初始无错误', () {
      expect(readState().error, isNull);
    });
  });

  group('RssNotifier loadSources（mock API）', () {
    test('成功加载 RSS 源列表', () async {
      final sources = [
        const RssSource(sourceUrl: 'https://rss1.com', sourceName: '源1'),
        const RssSource(sourceUrl: 'https://rss2.com', sourceName: '源2'),
      ];
      when(() => mockApi.getRssSources()).thenAnswer((_) async => sources);

      await readNotifier().loadSources();

      expect(readState().sources.length, equals(2));
      expect(readState().isEmpty, isFalse);
      expect(readState().isLoadingSources, isFalse);
      expect(readState().error, isNull);
    });

    test('加载失败时设置 BridgeError', () async {
      when(() => mockApi.getRssSources())
          .thenThrow(const BridgeError(message: 'RSS 加载失败'));

      await readNotifier().loadSources();

      expect(readState().error, equals('RSS 加载失败'));
      expect(readState().isLoadingSources, isFalse);
      expect(readState().sources, isEmpty);
    });

    test('加载失败时设置普通异常', () async {
      when(() => mockApi.getRssSources()).thenThrow(Exception('网络'));

      await readNotifier().loadSources();

      expect(readState().error, contains('网络'));
      expect(readState().isLoadingSources, isFalse);
    });

    test('loadSources 触发状态更新（loading→data 至少两次）', () async {
      when(() => mockApi.getRssSources()).thenAnswer((_) async => []);
      var notifyCount = 0;
      container.listen(rssNotifierProvider, (_, __) => notifyCount++);

      await readNotifier().loadSources();
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('RssNotifier selectSource（mock API）', () {
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

      await readNotifier().selectSource(testSource);

      expect(readState().selectedSource, equals(testSource));
      expect(readState().articles.length, equals(2));
      expect(readState().isLoadingArticles, isFalse);
      expect(readState().error, isNull);
    });

    test('选择源失败时设置错误', () async {
      when(() => mockApi.getRssArticles(any()))
          .thenThrow(const BridgeError(message: '获取文章失败'));

      await readNotifier().selectSource(testSource);

      expect(readState().error, equals('获取文章失败'));
      expect(readState().isLoadingArticles, isFalse);
      expect(readState().articles, isEmpty);
    });

    test('selectSource 清空旧文章', () async {
      when(() => mockApi.getRssArticles(any()))
          .thenAnswer((_) async => [const RssFeedArticle(title: 'a', url: 'u')]);

      await readNotifier().selectSource(testSource);
      expect(readState().articles.length, equals(1));

      // 选择另一个源
      final other =
          const RssSource(sourceUrl: 'https://other.com', sourceName: '其他');
      when(() => mockApi.getRssArticles('https://other.com'))
          .thenAnswer((_) async => []);
      await readNotifier().selectSource(other);

      expect(readState().articles, isEmpty);
      expect(readState().selectedSource, equals(other));
    });
  });

  group('RssNotifier refreshArticles', () {
    test('无选中源时不抛异常', () async {
      await readNotifier().refreshArticles();
      expect(readState().articles, isEmpty);
      expect(readState().selectedSource, isNull);
    });

    test('有选中源时重新加载文章', () async {
      final source =
          const RssSource(sourceUrl: 'https://r.com', sourceName: 'R');
      when(() => mockApi.getRssArticles(any()))
          .thenAnswer((_) async => [const RssFeedArticle(title: 'x', url: 'u')]);

      await readNotifier().selectSource(source);
      await readNotifier().refreshArticles();

      verify(() => mockApi.getRssArticles('https://r.com')).called(2);
    });
  });

  group('RssNotifier addSource（mock API）', () {
    test('成功添加 RSS 源', () async {
      final added =
          const RssSource(sourceUrl: 'https://new.com', sourceName: '新源');
      when(() => mockApi.addRssSource(any())).thenAnswer((_) async => added);

      await readNotifier().addSource('新源', 'https://new.com');

      expect(readState().sources.length, equals(1));
      expect(readState().sources.first.sourceName, equals('新源'));
      expect(readState().error, isNull);
    });

    test('添加失败时设置错误', () async {
      when(() => mockApi.addRssSource(any()))
          .thenThrow(const BridgeError(message: '添加失败'));

      await readNotifier().addSource('bad', 'https://bad.com');

      expect(readState().error, equals('添加失败'));
      expect(readState().sources, isEmpty);
    });
  });

  group('RssNotifier removeSource（mock API）', () {
    test('成功删除 RSS 源', () async {
      final sources = [
        const RssSource(sourceUrl: 'https://a.com', sourceName: 'A'),
        const RssSource(sourceUrl: 'https://b.com', sourceName: 'B'),
      ];
      when(() => mockApi.getRssSources()).thenAnswer((_) async => sources);
      when(() => mockApi.deleteRssSource(any())).thenAnswer((_) async {});

      await readNotifier().loadSources();
      await readNotifier().removeSource('https://a.com');

      expect(readState().sources.length, equals(1));
      expect(readState().sources.first.sourceUrl, equals('https://b.com'));
    });

    test('删除当前选中源时清除选中状态', () async {
      final source =
          const RssSource(sourceUrl: 'https://a.com', sourceName: 'A');
      when(() => mockApi.getRssSources()).thenAnswer((_) async => [source]);
      when(() => mockApi.getRssArticles(any())).thenAnswer((_) async => []);
      when(() => mockApi.deleteRssSource(any())).thenAnswer((_) async {});

      await readNotifier().loadSources();
      await readNotifier().selectSource(source);
      await readNotifier().removeSource('https://a.com');

      expect(readState().selectedSource, isNull);
      expect(readState().articles, isEmpty);
    });

    test('删除失败时设置错误', () async {
      when(() => mockApi.deleteRssSource(any()))
          .thenThrow(const BridgeError(message: '删除失败'));

      await readNotifier().removeSource('https://x.com');

      expect(readState().error, equals('删除失败'));
    });
  });

  group('RssNotifier 状态管理', () {
    test('clearSelectedSource 清除选中源和文章', () {
      readNotifier().clearSelectedSource();
      expect(readState().selectedSource, isNull);
      expect(readState().articles, isEmpty);
    });

    test('clearSelectedSource 状态变更触发监听', () async {
      final source =
          const RssSource(sourceUrl: 'https://a.com', sourceName: 'A');
      when(() => mockApi.getRssArticles(any()))
          .thenAnswer((_) async => [const RssFeedArticle(title: 'a', url: 'u')]);
      await readNotifier().selectSource(source);

      var notified = false;
      container.listen(rssNotifierProvider, (_, __) => notified = true);
      readNotifier().clearSelectedSource();
      expect(notified, isTrue);
    });

    test('clearError 清除错误', () {
      readNotifier().clearError();
      expect(readState().error, isNull);
    });

    test('clearError 状态变更触发监听', () async {
      when(() => mockApi.getRssSources())
          .thenThrow(const BridgeError(message: 'e'));
      await readNotifier().loadSources();
      expect(readState().error, isNotNull);

      var notified = false;
      container.listen(rssNotifierProvider, (_, __) => notified = true);
      readNotifier().clearError();
      expect(notified, isTrue);
    });

    test('isLoading 是 sources 或 articles 加载的或', () {
      expect(readState().isLoading, isFalse);
    });

    test('多次 clearSelectedSource 不抛异常', () {
      readNotifier().clearSelectedSource();
      readNotifier().clearSelectedSource();
      expect(readState().selectedSource, isNull);
    });
  });

  group('RssNotifier 分组筛选（对齐安卓 RssFragment）', () {
    Future<void> loadWithGroups(List<RssSource> sources) async {
      when(() => mockApi.getRssSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    }

    test('初始 selectedGroup 为 null（全部）', () {
      expect(readState().selectedGroup, isNull);
    });

    test('多分组聚合去重并保持插入顺序', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1', sourceGroup: '科技'),
        RssSource(sourceUrl: 'u2', sourceName: 's2', sourceGroup: '生活'),
        RssSource(sourceUrl: 'u3', sourceName: 's3', sourceGroup: '科技'),
      ]);

      expect(readState().groups, equals(['科技', '生活']));
    });

    test('逗号/中文逗号/分号多组拆分', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1', sourceGroup: '科技,财经'),
        RssSource(sourceUrl: 'u2', sourceName: 's2', sourceGroup: '生活，科技'),
        RssSource(sourceUrl: 'u3', sourceName: 's3', sourceGroup: '财经;娱乐'),
      ]);

      expect(readState().groups, equals(['科技', '财经', '生活', '娱乐']));
    });

    test('拆分时 trim 并去除空分组', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1', sourceGroup: ' 科技 , , 财经 '),
      ]);

      expect(readState().groups, equals(['科技', '财经']));
    });

    test('空分组场景：sourceGroup 为 null 或空串不计入', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1'),
        RssSource(sourceUrl: 'u2', sourceName: 's2', sourceGroup: ''),
        RssSource(sourceUrl: 'u3', sourceName: 's3', sourceGroup: '科技'),
      ]);

      expect(readState().groups, equals(['科技']));
    });

    test('selectedGroup 为 null 时 filteredSources 返回全部', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1', sourceGroup: '科技'),
        RssSource(sourceUrl: 'u2', sourceName: 's2', sourceGroup: '生活'),
      ]);

      expect(readState().filteredSources.length, equals(2));
    });

    test('选中分组后过滤（含多组源命中）', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1', sourceGroup: '科技'),
        RssSource(sourceUrl: 'u2', sourceName: 's2', sourceGroup: '科技,财经'),
        RssSource(sourceUrl: 'u3', sourceName: 's3', sourceGroup: '生活'),
      ]);

      readNotifier().setGroup('科技');

      expect(readState().selectedGroup, equals('科技'));
      expect(
        readState().filteredSources.map((s) => s.sourceUrl).toList(),
        equals(['u1', 'u2']),
      );
    });

    test('切回「全部」恢复全部源', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1', sourceGroup: '科技'),
        RssSource(sourceUrl: 'u2', sourceName: 's2', sourceGroup: '生活'),
      ]);

      readNotifier().setGroup('科技');
      expect(readState().filteredSources.length, equals(1));

      readNotifier().setGroup(null);
      expect(readState().selectedGroup, isNull);
      expect(readState().filteredSources.length, equals(2));
    });

    test('选中不存在的分组时 filteredSources 为空', () async {
      await loadWithGroups(const [
        RssSource(sourceUrl: 'u1', sourceName: 's1', sourceGroup: '科技'),
      ]);

      readNotifier().setGroup('不存在');
      expect(readState().filteredSources, isEmpty);
    });

    test('setGroup 状态变更触发监听', () {
      var notified = false;
      container.listen(rssNotifierProvider, (_, __) => notified = true);
      readNotifier().setGroup('科技');
      expect(notified, isTrue);
    });
  });

  group('DefaultData 默认订阅源同步', () {
    test('syncDefaultRssSources 删除 legado 分组后导入', () async {
      final legado = const RssSource(
        sourceUrl: 'https://old.legado',
        sourceName: '旧默认',
        sourceGroup: 'legado',
      );
      final custom = const RssSource(
        sourceUrl: 'https://custom',
        sourceName: '自定义',
        sourceGroup: '我的',
      );
      when(() => mockApi.getRssSources())
          .thenAnswer((_) async => [legado, custom]);
      when(() => mockApi.deleteRssSource(any())).thenAnswer((_) async {});
      when(() => mockApi.importRssSources(any())).thenAnswer((_) async => 4);

      const payload =
          '[{"sourceUrl":"https://www.yuque.com/legado","sourceName":"使用说明","sourceGroup":"legado"}]';
      final n = await syncDefaultRssSources(mockApi, jsonOverride: payload);

      expect(n, equals(4));
      verify(() => mockApi.deleteRssSource('https://old.legado')).called(1);
      verifyNever(() => mockApi.deleteRssSource('https://custom'));
      verify(() => mockApi.importRssSources(payload)).called(1);
    });
  });
}
