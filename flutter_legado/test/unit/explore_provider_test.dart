import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_legado/src/providers/explore_provider.dart';
import 'package:flutter_legado/src/models/book_source.dart';

import '../mocks/mocks.dart';

void main() {
  late ExploreProvider provider;
  late MockRustApi mockApi;

  setUp(() {
    mockApi = MockRustApi();
    provider = ExploreProvider(mockApi);
  });

  group('ExploreProvider 初始状态', () {
    test('初始书源列表为空', () {
      expect(provider.bookSources, isEmpty);
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('初始搜索关键词为空', () {
      expect(provider.searchKeyword, equals(''));
    });

    test('初始无选中分组', () {
      expect(provider.selectedGroup, equals(''));
    });

    test('初始分组集合为空', () {
      expect(provider.groups, isEmpty);
    });

    test('初始 filteredBookSources 为空', () {
      expect(provider.filteredBookSources, isEmpty);
    });
  });

  group('ExploreProvider loadBookSources（mock API）', () {
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

      await provider.loadBookSources();

      // 只保留 s1 和 s5
      expect(provider.bookSources.length, equals(2));
      expect(provider.bookSources[0].bookSourceUrl, equals('https://s1.com'));
      expect(provider.bookSources[1].bookSourceUrl, equals('https://s5.com'));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
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

      await provider.loadBookSources();

      expect(provider.groups, containsAll(['玄幻', '都市', '未分类']));
    });

    test('加载失败时设置错误', () async {
      when(() => mockApi.getBookSources())
          .thenThrow(Exception('网络异常'));

      await provider.loadBookSources();

      expect(provider.error, contains('加载书源失败'));
      expect(provider.loading, isFalse);
    });

    test('加载时 loading 状态正确', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);

      await provider.loadBookSources();
      expect(provider.loading, isFalse);
    });

    test('loadBookSources 触发通知', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      await provider.loadBookSources();
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('ExploreProvider 搜索过滤', () {
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

    setUp(() {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
    });

    test('setSearchKeyword 设置搜索关键词', () {
      provider.setSearchKeyword('笔趣阁');
      expect(provider.searchKeyword, equals('笔趣阁'));
    });

    test('setSearchKeyword 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.setSearchKeyword('test');
      expect(notified, isTrue);
    });

    test('clearSearch 清除搜索关键词', () {
      provider.setSearchKeyword('test');
      provider.clearSearch();
      expect(provider.searchKeyword, equals(''));
    });

    test('clearSearch 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearSearch();
      expect(notified, isTrue);
    });

    test('按名称过滤书源', () async {
      await provider.loadBookSources();
      provider.setSearchKeyword('笔趣阁');

      final filtered = provider.filteredBookSources;
      expect(filtered.length, equals(1));
      expect(filtered.first.bookSourceName, equals('笔趣阁'));
    });

    test('按 URL 过滤书源', () async {
      await provider.loadBookSources();
      provider.setSearchKeyword('qidian');

      final filtered = provider.filteredBookSources;
      expect(filtered.length, equals(1));
      expect(filtered.first.bookSourceName, equals('起点中文网'));
    });

    test('搜索不区分大小写', () async {
      await provider.loadBookSources();
      provider.setSearchKeyword('BIQUGE');

      final filtered = provider.filteredBookSources;
      expect(filtered.length, equals(1));
    });

    test('搜索无匹配时返回空列表', () async {
      await provider.loadBookSources();
      provider.setSearchKeyword('不存在的源');

      final filtered = provider.filteredBookSources;
      expect(filtered, isEmpty);
    });

    test('空关键词时返回全部', () async {
      await provider.loadBookSources();
      provider.setSearchKeyword('');

      final filtered = provider.filteredBookSources;
      expect(filtered.length, equals(3));
    });
  });

  group('ExploreProvider 分组过滤', () {
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

    setUp(() {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
    });

    test('selectGroup 设置选中分组', () {
      provider.selectGroup('玄幻');
      expect(provider.selectedGroup, equals('玄幻'));
    });

    test('selectGroup 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.selectGroup('玄幻');
      expect(notified, isTrue);
    });

    test('按分组过滤书源', () async {
      await provider.loadBookSources();
      provider.selectGroup('玄幻');

      final filtered = provider.filteredBookSources;
      expect(filtered.length, equals(2));
      expect(filtered.every((s) => s.bookSourceGroup == '玄幻'), isTrue);
    });

    test('选择无书源的分组返回空', () async {
      await provider.loadBookSources();
      provider.selectGroup('仙侠');

      final filtered = provider.filteredBookSources;
      expect(filtered, isEmpty);
    });

    test('空分组时返回全部', () async {
      await provider.loadBookSources();
      provider.selectGroup('');

      final filtered = provider.filteredBookSources;
      expect(filtered.length, equals(3));
    });

    test('搜索 + 分组联合过滤', () async {
      await provider.loadBookSources();
      provider.selectGroup('玄幻');
      provider.setSearchKeyword('源1');

      final filtered = provider.filteredBookSources;
      expect(filtered.length, equals(1));
      expect(filtered.first.bookSourceName, equals('源1'));
    });
  });

  group('ExploreProvider uninstallSource（mock API）', () {
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

      await provider.loadBookSources();
      final result = await provider.uninstallSource('https://s1.com');

      expect(result, isTrue);
      expect(provider.bookSources.length, equals(1));
      expect(provider.bookSources.first.bookSourceUrl, equals('https://s2.com'));
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

      await provider.loadBookSources();
      final result = await provider.uninstallSource('https://s1.com');

      expect(result, isFalse);
      expect(provider.error, contains('卸载失败'));
      // 列表中仍保留
      expect(provider.bookSources.length, equals(1));
    });

    test('卸载触发通知', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://s1.com',
          bookSourceName: '源1',
          enabledExplore: true,
          exploreUrl: 'https://s1.com/e',
        ),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      when(() => mockApi.deleteBookSource(any())).thenAnswer((_) async {});

      await provider.loadBookSources();

      var notified = false;
      provider.addListener(() => notified = true);
      await provider.uninstallSource('https://s1.com');
      expect(notified, isTrue);
    });
  });

  group('ExploreProvider refreshBookSources', () {
    test('refreshBookSources 等同于 loadBookSources', () async {
      final sources = [
        const BookSource(
          bookSourceUrl: 'https://s1.com',
          bookSourceName: '源1',
          enabledExplore: true,
          exploreUrl: 'https://s1.com/e',
        ),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);

      await provider.refreshBookSources();

      expect(provider.bookSources.length, equals(1));
      verify(() => mockApi.getBookSources()).called(1);
    });
  });
}
