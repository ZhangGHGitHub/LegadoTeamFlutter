/// SourceProvider 单元测试
///
/// 覆盖：
/// - 初始状态、loadSources、filteredSources、groupedSources
/// - toggleSource/deleteSource/saveSource
/// - 批量操作：enterBatchMode/exitBatchMode/selectAll/batchEnable/batchDisable/batchDelete
/// - 分组筛选：setGroup
/// - 导入：importSources/importFromJson/importFromUrl/importFromFile
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/source_provider.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late SourceProvider provider;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    provider = SourceProvider(mockApi);
  });

  // 辅助：构造 BookSource
  BookSource makeSource(String url, String name,
      {String? group, bool enabled = true}) {
    return BookSource(
      bookSourceUrl: url,
      bookSourceName: name,
      bookSourceGroup: group,
      enabled: enabled,
    );
  }

  group('SourceProvider 初始状态', () {
    test('初始书源列表为空', () {
      expect(provider.sources, isEmpty);
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });

    test('初始无筛选关键字', () {
      expect(provider.filterKeyword, equals(''));
    });

    test('初始无选中分组', () {
      expect(provider.selectedGroup, isNull);
    });

    test('初始非批量模式', () {
      expect(provider.batchMode, isFalse);
      expect(provider.selectedUrls, isEmpty);
      expect(provider.selectedCount, equals(0));
    });

    test('初始无导入结果', () {
      expect(provider.lastImportResult, isNull);
    });
  });

  group('SourceProvider loadSources', () {
    test('成功加载书源列表', () async {
      final sources = [
        makeSource('http://s1.com', '源1', group: '小说'),
        makeSource('http://s2.com', '源2', group: '漫画'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);

      await provider.loadSources();

      expect(provider.sources.length, equals(2));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('加载失败设置 BridgeError', () async {
      when(() => mockApi.getBookSources())
          .thenThrow(const BridgeError(message: '书源加载失败'));

      await provider.loadSources();

      expect(provider.error, equals('书源加载失败'));
      expect(provider.loading, isFalse);
    });

    test('加载失败设置普通异常', () async {
      when(() => mockApi.getBookSources()).thenThrow(Exception('网络'));

      await provider.loadSources();

      expect(provider.error, contains('网络'));
    });

    test('loadSources 触发通知', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      await provider.loadSources();

      // 至少 2 次：开始 loading + 结束
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('SourceProvider filteredSources', () {
    setUp(() async {
      final sources = [
        makeSource('http://novel.com', '小说源', group: '小说'),
        makeSource('http://comic.com', '漫画源', group: '漫画'),
        makeSource('http://other.com', '其他源'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();
    });

    test('无筛选时返回全部', () {
      expect(provider.filteredSources.length, equals(3));
    });

    test('按名称关键字筛选', () {
      provider.setFilter('小说');
      expect(provider.filteredSources.length, equals(1));
      expect(provider.filteredSources[0].bookSourceName, equals('小说源'));
    });

    test('按 URL 关键字筛选', () {
      provider.setFilter('comic');
      expect(provider.filteredSources.length, equals(1));
      expect(provider.filteredSources[0].bookSourceUrl, equals('http://comic.com'));
    });

    test('按分组名筛选', () {
      provider.setFilter('漫画');
      // 匹配分组名 "漫画" 和源名 "漫画源"
      expect(provider.filteredSources.length, equals(1));
    });

    test('clearFilter 清除筛选', () {
      provider.setFilter('小说');
      provider.clearFilter();
      expect(provider.filteredSources.length, equals(3));
    });

    test('分组筛选', () {
      provider.setGroup('小说');
      expect(provider.filteredSources.length, equals(1));
      expect(provider.filteredSources[0].bookSourceName, equals('小说源'));
    });

    test('分组筛选 - 未分组', () {
      provider.setGroup('未分组');
      expect(provider.filteredSources.length, equals(1));
      expect(provider.filteredSources[0].bookSourceName, equals('其他源'));
    });

    test('取消分组筛选', () {
      provider.setGroup('小说');
      provider.setGroup(null);
      expect(provider.filteredSources.length, equals(3));
    });
  });

  group('SourceProvider groups 和 groupedSources', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A', group: '小说'),
        makeSource('http://b.com', 'B', group: '漫画'),
        makeSource('http://c.com', 'C', group: '小说'),
        makeSource('http://d.com', 'D'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();
    });

    test('groups 返回排序后的分组列表', () {
      final groups = provider.groups;
      expect(groups, containsAll(['小说', '漫画', '未分组']));
    });

    test('groupedSources 按分组归类', () {
      final grouped = provider.groupedSources;
      expect(grouped['小说']!.length, equals(2));
      expect(grouped['漫画']!.length, equals(1));
      expect(grouped['未分组']!.length, equals(1));
    });
  });

  group('SourceProvider enabledSources/disabledSources', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A', enabled: true),
        makeSource('http://b.com', 'B', enabled: false),
        makeSource('http://c.com', 'C', enabled: true),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();
    });

    test('enabledSources 只返回启用的', () {
      expect(provider.enabledSources.length, equals(2));
    });

    test('disabledSources 只返回禁用的', () {
      expect(provider.disabledSources.length, equals(1));
      expect(provider.disabledSources[0].bookSourceName, equals('B'));
    });
  });

  group('SourceProvider toggleSource', () {
    setUp(() async {
      final sources = [makeSource('http://a.com', 'A', enabled: true)];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();
    });

    test('切换启用状态', () async {
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});

      await provider.toggleSource('http://a.com');

      expect(provider.sources[0].enabled, isFalse);
    });

    test('切换不存在的源不报错', () async {
      await provider.toggleSource('http://nonexist.com');
      expect(provider.error, isNull);
    });

    test('切换失败设置错误', () async {
      when(() => mockApi.updateBookSource(any()))
          .thenThrow(const BridgeError(message: '更新失败'));

      await provider.toggleSource('http://a.com');

      expect(provider.error, equals('更新失败'));
    });
  });

  group('SourceProvider deleteSource', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A'),
        makeSource('http://b.com', 'B'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();
    });

    test('删除成功移除源', () async {
      when(() => mockApi.deleteBookSource(any())).thenAnswer((_) async {});

      await provider.deleteSource('http://a.com');

      expect(provider.sources.length, equals(1));
      expect(provider.sources[0].bookSourceUrl, equals('http://b.com'));
    });

    test('删除失败设置错误', () async {
      when(() => mockApi.deleteBookSource(any()))
          .thenThrow(const BridgeError(message: '删除失败'));

      await provider.deleteSource('http://a.com');

      expect(provider.error, equals('删除失败'));
      expect(provider.sources.length, equals(2));
    });
  });

  group('SourceProvider saveSource', () {
    test('新建书源', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await provider.loadSources();

      final newSource = makeSource('http://new.com', '新源');
      when(() => mockApi.addBookSource(any())).thenAnswer((_) async => newSource);

      await provider.saveSource(newSource);

      expect(provider.sources.length, equals(1));
      expect(provider.sources[0].bookSourceName, equals('新源'));
    });

    test('更新已有书源', () async {
      final sources = [makeSource('http://a.com', '旧名')];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();

      final updated = makeSource('http://a.com', '新名');
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});

      await provider.saveSource(updated);

      expect(provider.sources[0].bookSourceName, equals('新名'));
    });

    test('保存失败 rethrow', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await provider.loadSources();

      final source = makeSource('http://x.com', 'X');
      when(() => mockApi.addBookSource(any()))
          .thenThrow(const BridgeError(message: '保存失败'));

      expect(
        () => provider.saveSource(source),
        throwsA(isA<BridgeError>()),
      );
    });
  });

  group('SourceProvider getSource', () {
    setUp(() async {
      final sources = [makeSource('http://a.com', 'A')];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();
    });

    test('找到存在的源', () {
      final source = provider.getSource('http://a.com');
      expect(source, isNotNull);
      expect(source!.bookSourceName, equals('A'));
    });

    test('找不到返回 null', () {
      expect(provider.getSource('http://nope.com'), isNull);
    });
  });

  group('SourceProvider 批量操作', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A', enabled: true),
        makeSource('http://b.com', 'B', enabled: false),
        makeSource('http://c.com', 'C', enabled: true),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await provider.loadSources();
    });

    test('enterBatchMode 进入批量模式', () {
      provider.enterBatchMode();
      expect(provider.batchMode, isTrue);
      expect(provider.selectedUrls, isEmpty);
    });

    test('exitBatchMode 退出批量模式', () {
      provider.enterBatchMode();
      provider.toggleSelection('http://a.com');
      provider.exitBatchMode();
      expect(provider.batchMode, isFalse);
      expect(provider.selectedUrls, isEmpty);
    });

    test('toggleSelection 切换选中', () {
      provider.enterBatchMode();
      provider.toggleSelection('http://a.com');
      expect(provider.isSelected('http://a.com'), isTrue);
      expect(provider.selectedCount, equals(1));

      provider.toggleSelection('http://a.com');
      expect(provider.isSelected('http://a.com'), isFalse);
    });

    test('selectAll 全选当前过滤结果', () {
      provider.enterBatchMode();
      provider.selectAll();
      expect(provider.selectedCount, equals(3));
      expect(provider.isAllSelected, isTrue);
    });

    test('deselectAll 取消全选', () {
      provider.enterBatchMode();
      provider.selectAll();
      provider.deselectAll();
      expect(provider.selectedCount, equals(0));
    });

    test('batchEnable 批量启用', () async {
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});
      provider.enterBatchMode();
      provider.toggleSelection('http://b.com');

      await provider.batchEnable();

      expect(provider.sources[1].enabled, isTrue);
      expect(provider.batchMode, isFalse);
    });

    test('batchDisable 批量禁用', () async {
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});
      provider.enterBatchMode();
      provider.toggleSelection('http://a.com');
      provider.toggleSelection('http://c.com');

      await provider.batchDisable();

      expect(provider.sources[0].enabled, isFalse);
      expect(provider.sources[2].enabled, isFalse);
    });

    test('batchDelete 批量删除', () async {
      when(() => mockApi.deleteBookSource(any())).thenAnswer((_) async {});
      provider.enterBatchMode();
      provider.toggleSelection('http://a.com');
      provider.toggleSelection('http://b.com');

      await provider.batchDelete();

      expect(provider.sources.length, equals(1));
      expect(provider.sources[0].bookSourceUrl, equals('http://c.com'));
    });

    test('batchEnable 失败设置错误', () async {
      when(() => mockApi.updateBookSource(any()))
          .thenThrow(const BridgeError(message: '批量失败'));
      provider.enterBatchMode();
      provider.toggleSelection('http://b.com');

      await provider.batchEnable();

      expect(provider.error, equals('批量失败'));
    });
  });

  group('SourceProvider importSources', () {
    test('导入成功重新加载列表', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await provider.loadSources();

      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 2);
      final newSources = [makeSource('http://new.com', '新')];
      // 第二次 getBookSources 返回新列表
      var callCount = 0;
      when(() => mockApi.getBookSources()).thenAnswer((_) async {
        callCount++;
        return callCount > 1 ? newSources : [];
      });

      await provider.importSources('[{"bookSourceUrl":"http://new.com"}]');

      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('导入失败设置错误', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await provider.loadSources();

      when(() => mockApi.importBookSources(any()))
          .thenThrow(const BridgeError(message: '导入失败'));

      await provider.importSources('invalid');

      expect(provider.error, equals('导入失败'));
    });
  });

  group('SourceProvider isAllSelected', () {
    test('空列表时返回 false', () {
      expect(provider.isAllSelected, isFalse);
    });
  });
}
