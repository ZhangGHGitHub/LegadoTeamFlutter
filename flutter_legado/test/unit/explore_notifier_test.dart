// ExploreNotifier 单元测试
//
// 覆盖：初始状态/loadBookSources 过滤/分组收集/搜索过滤/分组过滤/
// uninstallSource/refresh/loadCategories（exploreParseUrl 缓存）
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
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

  /// 等待 build() 微任务自动加载完成
  Future<void> pumpInit() async {
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);
  }

  ExploreState readState() => container.read(exploreNotifierProvider);
  ExploreNotifier readNotifier() =>
      container.read(exploreNotifierProvider.notifier);

  group('ExploreNotifier 初始状态', () {
    test('初始书源列表为空且各展示字段为默认值', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      container.read(exploreNotifierProvider);
      await pumpInit();

      expect(readState().bookSources, isEmpty);
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
      expect(readState().searchKeyword, equals(''));
      expect(readState().selectedGroup, equals(''));
      expect(readState().groups, isEmpty);
      expect(readState().filteredBookSources, isEmpty);
    });
  });

  group('ExploreNotifier loadBookSources（mock API）', () {
    test('成功加载书源并过滤（仅保留启用发现且有 exploreUrl 的）', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://s1.com',
          bookSourceName: '源1',
          enabledExplore: true,
          exploreUrl: 'https://s1.com/explore',
          bookSourceGroup: '玄幻',
        ),
        const BookSource(
          bookSourceUrl: 'https://s2.com',
          bookSourceName: '源2',
          enabledExplore: false, // 未启用发现
          exploreUrl: 'https://s2.com/explore',
        ),
        const BookSource(
          bookSourceUrl: 'https://s3.com',
          bookSourceName: '源3',
          enabledExplore: true,
          exploreUrl: null, // 无 exploreUrl
        ),
        const BookSource(
          bookSourceUrl: 'https://s4.com',
          bookSourceName: '源4',
          enabledExplore: true,
          exploreUrl: '  ', // 空白 exploreUrl
        ),
        const BookSource(
          bookSourceUrl: 'https://s5.com',
          bookSourceName: '源5',
          enabledExplore: true,
          exploreUrl: 'https://s5.com/explore',
          bookSourceGroup: '都市',
        ),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);

      container.read(exploreNotifierProvider);
      await pumpInit();

      // 只保留 s1 和 s5
      expect(readState().bookSources.length, equals(2));
      expect(readState().bookSources[0].bookSourceUrl, equals('https://s1.com'));
      expect(readState().bookSources[1].bookSourceUrl, equals('https://s5.com'));
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
    });

    test('加载后正确收集分组', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://s1.com',
          bookSourceName: '源1',
          enabledExplore: true,
          exploreUrl: 'https://s1.com/e',
          bookSourceGroup: '玄幻',
        ),
        const BookSource(
          bookSourceUrl: 'https://s2.com',
          bookSourceName: '源2',
          enabledExplore: true,
          exploreUrl: 'https://s2.com/e',
          bookSourceGroup: '都市',
        ),
        const BookSource(
          bookSourceUrl: 'https://s3.com',
          bookSourceName: '源3',
          enabledExplore: true,
          exploreUrl: 'https://s3.com/e',
          bookSourceGroup: null, // 无分组
        ),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);

      container.read(exploreNotifierProvider);
      await pumpInit();

      expect(readState().groups, containsAll(['玄幻', '都市', '未分类']));
    });

    test('加载失败时设置错误', () async {
      when(() => mockApi.getBookSources()).thenThrow(Exception('网络异常'));

      container.read(exploreNotifierProvider);
      await pumpInit();

      expect(readState().error, contains('加载书源失败'));
      expect(readState().isLoading, isFalse);
    });
  });

  group('ExploreNotifier 搜索过滤', () {
    final sources = [
      const BookSource(
        bookSourceUrl: 'https://biquge.com',
        bookSourceName: '笔趣阁',
        enabledExplore: true,
        exploreUrl: 'https://biquge.com/explore',
        bookSourceGroup: '玄幻',
      ),
      const BookSource(
        bookSourceUrl: 'https://qidian.com',
        bookSourceName: '起点中文网',
        enabledExplore: true,
        exploreUrl: 'https://qidian.com/explore',
        bookSourceGroup: '都市',
      ),
      const BookSource(
        bookSourceUrl: 'https://zongheng.com',
        bookSourceName: '纵横中文网',
        enabledExplore: true,
        exploreUrl: 'https://zongheng.com/explore',
        bookSourceGroup: '玄幻',
      ),
    ];

    setUp(() async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      container.read(exploreNotifierProvider);
      await pumpInit();
    });

    test('setSearchKeyword 设置搜索关键词', () {
      readNotifier().setSearchKeyword('笔趣阁');
      expect(readState().searchKeyword, equals('笔趣阁'));
    });

    test('clearSearch 清除搜索关键词', () {
      readNotifier().setSearchKeyword('test');
      readNotifier().clearSearch();
      expect(readState().searchKeyword, equals(''));
    });

    test('按名称过滤书源', () {
      readNotifier().setSearchKeyword('笔趣阁');
      final filtered = readState().filteredBookSources;
      expect(filtered.length, equals(1));
      expect(filtered.first.bookSourceName, equals('笔趣阁'));
    });

    test('按 URL 过滤书源', () {
      readNotifier().setSearchKeyword('qidian');
      final filtered = readState().filteredBookSources;
      expect(filtered.length, equals(1));
      expect(filtered.first.bookSourceName, equals('起点中文网'));
    });

    test('搜索不区分大小写', () {
      readNotifier().setSearchKeyword('BIQUGE');
      expect(readState().filteredBookSources.length, equals(1));
    });

    test('搜索无匹配时返回空列表', () {
      readNotifier().setSearchKeyword('不存在的源');
      expect(readState().filteredBookSources, isEmpty);
    });

    test('空关键词时返回全部', () {
      readNotifier().setSearchKeyword('');
      expect(readState().filteredBookSources.length, equals(3));
    });
  });

  group('ExploreNotifier 分组过滤', () {
    final sources = [
      const BookSource(
        bookSourceUrl: 'https://s1.com',
        bookSourceName: '源1',
        enabledExplore: true,
        exploreUrl: 'https://s1.com/e',
        bookSourceGroup: '玄幻',
      ),
      const BookSource(
        bookSourceUrl: 'https://s2.com',
        bookSourceName: '源2',
        enabledExplore: true,
        exploreUrl: 'https://s2.com/e',
        bookSourceGroup: '都市',
      ),
      const BookSource(
        bookSourceUrl: 'https://s3.com',
        bookSourceName: '源3',
        enabledExplore: true,
        exploreUrl: 'https://s3.com/e',
        bookSourceGroup: '玄幻',
      ),
    ];

    setUp(() async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      container.read(exploreNotifierProvider);
      await pumpInit();
    });

    test('selectGroup 设置选中分组', () {
      readNotifier().selectGroup('玄幻');
      expect(readState().selectedGroup, equals('玄幻'));
    });

    test('按分组过滤书源', () {
      readNotifier().selectGroup('玄幻');
      final filtered = readState().filteredBookSources;
      expect(filtered.length, equals(2));
      expect(filtered.every((s) => s.bookSourceGroup == '玄幻'), isTrue);
    });

    test('选择无书源的分组返回空', () {
      readNotifier().selectGroup('仙侠');
      expect(readState().filteredBookSources, isEmpty);
    });

    test('空分组时返回全部', () {
      readNotifier().selectGroup('');
      expect(readState().filteredBookSources.length, equals(3));
    });

    test('搜索 + 分组联合过滤', () {
      readNotifier().selectGroup('玄幻');
      readNotifier().setSearchKeyword('源1');
      final filtered = readState().filteredBookSources;
      expect(filtered.length, equals(1));
      expect(filtered.first.bookSourceName, equals('源1'));
    });
  });

  group('ExploreNotifier uninstallSource（mock API）', () {
    test('卸载成功返回 true 并从列表移除', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://s1.com',
          bookSourceName: '源1',
          enabledExplore: true,
          exploreUrl: 'https://s1.com/e',
        ),
        const BookSource(
          bookSourceUrl: 'https://s2.com',
          bookSourceName: '源2',
          enabledExplore: true,
          exploreUrl: 'https://s2.com/e',
        ),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      when(() => mockApi.deleteBookSource(any())).thenAnswer((_) async {});

      container.read(exploreNotifierProvider);
      await pumpInit();
      final result = await readNotifier().uninstallSource('https://s1.com');

      expect(result, isTrue);
      expect(readState().bookSources.length, equals(1));
      expect(readState().bookSources.first.bookSourceUrl, equals('https://s2.com'));
    });

    test('卸载失败返回 false 并设置错误', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://s1.com',
          bookSourceName: '源1',
          enabledExplore: true,
          exploreUrl: 'https://s1.com/e',
        ),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      when(() => mockApi.deleteBookSource(any()))
          .thenThrow(Exception('删除失败'));

      container.read(exploreNotifierProvider);
      await pumpInit();
      final result = await readNotifier().uninstallSource('https://s1.com');

      expect(result, isFalse);
      expect(readState().error, contains('卸载失败'));
      // 列表中仍保留
      expect(readState().bookSources.length, equals(1));
    });
  });

  group('ExploreNotifier refresh', () {
    test('refresh 重新加载书源', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [
            const BookSource(
              bookSourceUrl: 'https://s1.com',
              bookSourceName: '源1',
              enabledExplore: true,
              exploreUrl: 'https://s1.com/e',
            ),
          ]);

      container.read(exploreNotifierProvider);
      await pumpInit();
      expect(readState().bookSources.length, equals(1));

      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await readNotifier().refresh();

      expect(readState().bookSources, isEmpty);
    });
  });

  group('ExploreNotifier loadCategories（exploreParseUrl）', () {
    const source = BookSource(
      bookSourceUrl: 'https://s1.com',
      bookSourceName: '源1',
      enabledExplore: true,
      exploreUrl: 'https://s1.com/explore',
    );

    test('成功解析并缓存分类', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      when(() => mockApi.exploreParseUrl(
            any(),
            sourceJson: any(named: 'sourceJson'),
          )).thenAnswer(
        (_) async => const [
          ExploreCategory(title: '玄幻', url: 'https://s1.com/xuanhuan'),
          ExploreCategory(title: '都市', url: 'https://s1.com/dushi'),
        ],
      );
      container.read(exploreNotifierProvider);
      await pumpInit();

      await readNotifier().loadCategories(source);

      final cached = readState().categoriesFor('https://s1.com');
      expect(cached, isNotNull);
      expect(cached, hasLength(2));
      expect(cached!.first.title, equals('玄幻'));
      // 加载完成后 loadingCategories 清空
      expect(readState().isLoadingCategories('https://s1.com'), isFalse);
    });

    test('exploreUrl 为空时缓存空分类且不调用 API', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      container.read(exploreNotifierProvider);
      await pumpInit();

      const noExplore = BookSource(
        bookSourceUrl: 'https://s2.com',
        bookSourceName: '源2',
        enabledExplore: true,
        exploreUrl: null,
      );
      await readNotifier().loadCategories(noExplore);

      expect(readState().categoriesFor('https://s2.com'), isEmpty);
      verifyNever(() => mockApi.exploreParseUrl(
            any(),
            sourceJson: any(named: 'sourceJson'),
          ));
    });

    test('幂等：已缓存时不重复请求', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      when(() => mockApi.exploreParseUrl(
            any(),
            sourceJson: any(named: 'sourceJson'),
          )).thenAnswer(
        (_) async => const [ExploreCategory(title: '玄幻', url: 'u')],
      );
      container.read(exploreNotifierProvider);
      await pumpInit();

      await readNotifier().loadCategories(source);
      await readNotifier().loadCategories(source);

      verify(() => mockApi.exploreParseUrl(
            any(),
            sourceJson: any(named: 'sourceJson'),
          )).called(1);
    });

    test('解析失败时缓存空分类（静默失败）', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      when(() => mockApi.exploreParseUrl(
            any(),
            sourceJson: any(named: 'sourceJson'),
          )).thenThrow(Exception('解析失败'));
      container.read(exploreNotifierProvider);
      await pumpInit();

      await readNotifier().loadCategories(source);

      expect(readState().categoriesFor('https://s1.com'), isEmpty);
      expect(readState().isLoadingCategories('https://s1.com'), isFalse);
    });

    test('空缓存失败后可重试（非幂等阻塞）', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      var calls = 0;
      when(() => mockApi.exploreParseUrl(
            any(),
            sourceJson: any(named: 'sourceJson'),
          )).thenAnswer((_) async {
        calls++;
        if (calls == 1) {
          throw Exception('首次失败');
        }
        return const [ExploreCategory(title: '重试成功', url: 'u')];
      });
      container.read(exploreNotifierProvider);
      await pumpInit();

      await readNotifier().loadCategories(source);
      expect(readState().categoriesFor('https://s1.com'), isEmpty);

      await readNotifier().loadCategories(source);
      expect(readState().categoriesFor('https://s1.com'), hasLength(1));
      expect(readState().categoriesFor('https://s1.com')!.first.title, '重试成功');
      expect(calls, 2);
    });

    test('@js: 书源传递 sourceJson', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      when(() => mockApi.exploreParseUrl(
            any(),
            sourceJson: any(named: 'sourceJson'),
          )).thenAnswer(
        (_) async => const [ExploreCategory(title: '热门', url: '/hot')],
      );
      container.read(exploreNotifierProvider);
      await pumpInit();

      const jsSource = BookSource(
        bookSourceUrl: 'https://js.example.com',
        bookSourceName: 'JS源',
        enabledExplore: true,
        exploreUrl: '@js:[{title:"热门",url:"/hot"}]',
      );
      await readNotifier().loadCategories(jsSource);

      final captured = verify(() => mockApi.exploreParseUrl(
            captureAny(),
            sourceJson: captureAny(named: 'sourceJson'),
          )).captured;
      expect(captured[0], jsSource.exploreUrl);
      expect(captured[1], contains('"bookSourceUrl"'));
      expect(captured[1], contains('https://js.example.com'));
    });
  });
}
