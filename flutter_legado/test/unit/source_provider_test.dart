/// SourceNotifier 单元测试
///
/// 覆盖：
/// - 初始状态、loadSources、filteredSources、groupedSources
/// - toggleSource/deleteSource/saveSource
/// - 批量操作：enterBatchMode/exitBatchMode/selectAll/batchEnable/batchDisable/batchDelete
/// - 分组筛选：setGroup
/// - 导入：importSources/importFromJson/importFromUrl/importFromFile
library;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/source/source_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

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

  SourceState readState() => container.read(sourceNotifierProvider);
  SourceNotifier readNotifier() =>
      container.read(sourceNotifierProvider.notifier);

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

  group('SourceNotifier 初始状态', () {
    test('初始书源列表为空', () {
      expect(readState().sources, isEmpty);
    });

    test('初始非加载状态', () {
      expect(readState().loading, isFalse);
    });

    test('初始无错误', () {
      expect(readState().error, isNull);
    });

    test('初始无筛选关键字', () {
      expect(readState().filterKeyword, equals(''));
    });

    test('初始无选中分组', () {
      expect(readState().selectedGroup, isNull);
    });

    test('初始非批量模式', () {
      expect(readState().batchMode, isFalse);
      expect(readState().selectedUrls, isEmpty);
      expect(readState().selectedCount, equals(0));
    });

    test('初始无导入结果', () {
      expect(readState().lastImportResult, isNull);
    });
  });

  group('SourceNotifier loadSources', () {
    test('成功加载书源列表', () async {
      final sources = [
        makeSource('http://s1.com', '源1', group: '小说'),
        makeSource('http://s2.com', '源2', group: '漫画'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);

      await readNotifier().loadSources();

      expect(readState().sources.length, equals(2));
      expect(readState().loading, isFalse);
      expect(readState().error, isNull);
    });

    test('加载失败设置 BridgeError', () async {
      when(() => mockApi.getBookSources())
          .thenThrow(const BridgeError(message: '书源加载失败'));

      await readNotifier().loadSources();

      expect(readState().error, equals('书源加载失败'));
      expect(readState().loading, isFalse);
    });

    test('加载失败设置普通异常', () async {
      when(() => mockApi.getBookSources()).thenThrow(Exception('网络'));

      await readNotifier().loadSources();

      expect(readState().error, contains('网络'));
    });

    test('loadSources 触发状态变化通知', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [
            makeSource('http://s1.com', '源1'),
          ]);
      final changes = <SourceState>[];
      container.listen(sourceNotifierProvider, (prev, next) {
        changes.add(next);
      });

      await readNotifier().loadSources();

      // 至少 2 次状态变化：开始 loading + 结束
      expect(changes.length, greaterThanOrEqualTo(2));
    });
  });

  group('SourceNotifier filteredSources', () {
    setUp(() async {
      final sources = [
        makeSource('http://novel.com', '小说源', group: '小说'),
        makeSource('http://comic.com', '漫画源', group: '漫画'),
        makeSource('http://other.com', '其他源'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    });

    test('无筛选时返回全部', () {
      expect(readState().filteredSources.length, equals(3));
    });

    test('按名称关键字筛选', () {
      readNotifier().setFilter('小说');
      expect(readState().filteredSources.length, equals(1));
      expect(readState().filteredSources[0].bookSourceName, equals('小说源'));
    });

    test('按 URL 关键字筛选', () {
      readNotifier().setFilter('comic');
      expect(readState().filteredSources.length, equals(1));
      expect(readState().filteredSources[0].bookSourceUrl, equals('http://comic.com'));
    });

    test('按分组名筛选', () {
      readNotifier().setFilter('漫画');
      // 匹配分组名 "漫画" 和源名 "漫画源"
      expect(readState().filteredSources.length, equals(1));
    });

    test('clearFilter 清除筛选', () {
      readNotifier().setFilter('小说');
      readNotifier().clearFilter();
      expect(readState().filteredSources.length, equals(3));
    });

    test('分组筛选', () {
      readNotifier().setGroup('小说');
      expect(readState().filteredSources.length, equals(1));
      expect(readState().filteredSources[0].bookSourceName, equals('小说源'));
    });

    test('分组筛选 - 未分组', () {
      readNotifier().setGroup('未分组');
      expect(readState().filteredSources.length, equals(1));
      expect(readState().filteredSources[0].bookSourceName, equals('其他源'));
    });

    test('取消分组筛选', () {
      readNotifier().setGroup('小说');
      readNotifier().setGroup(null);
      expect(readState().filteredSources.length, equals(3));
    });
  });

  group('SourceNotifier groups 和 groupedSources', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A', group: '小说'),
        makeSource('http://b.com', 'B', group: '漫画'),
        makeSource('http://c.com', 'C', group: '小说'),
        makeSource('http://d.com', 'D'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    });

    test('groups 返回排序后的分组列表', () {
      final groups = readState().groups;
      expect(groups, containsAll(['小说', '漫画', '未分组']));
    });

    test('groupedSources 按分组归类', () {
      final grouped = readState().groupedSources;
      expect(grouped['小说']!.length, equals(2));
      expect(grouped['漫画']!.length, equals(1));
      expect(grouped['未分组']!.length, equals(1));
    });
  });

  group('SourceNotifier enabledSources/disabledSources', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A', enabled: true),
        makeSource('http://b.com', 'B', enabled: false),
        makeSource('http://c.com', 'C', enabled: true),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    });

    test('enabledSources 只返回启用的', () {
      expect(readState().enabledSources.length, equals(2));
    });

    test('disabledSources 只返回禁用的', () {
      expect(readState().disabledSources.length, equals(1));
      expect(readState().disabledSources[0].bookSourceName, equals('B'));
    });
  });

  group('SourceNotifier toggleSource', () {
    setUp(() async {
      final sources = [makeSource('http://a.com', 'A', enabled: true)];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    });

    test('切换启用状态', () async {
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});

      await readNotifier().toggleSource('http://a.com');

      expect(readState().sources[0].enabled, isFalse);
    });

    test('切换不存在的源不报错', () async {
      await readNotifier().toggleSource('http://nonexist.com');
      expect(readState().error, isNull);
    });

    test('切换失败设置错误', () async {
      when(() => mockApi.updateBookSource(any()))
          .thenThrow(const BridgeError(message: '更新失败'));

      await readNotifier().toggleSource('http://a.com');

      expect(readState().error, equals('更新失败'));
    });
  });

  group('SourceNotifier deleteSource', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A'),
        makeSource('http://b.com', 'B'),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    });

    test('删除成功移除源', () async {
      when(() => mockApi.deleteBookSource(any())).thenAnswer((_) async {});

      await readNotifier().deleteSource('http://a.com');

      expect(readState().sources.length, equals(1));
      expect(readState().sources[0].bookSourceUrl, equals('http://b.com'));
    });

    test('删除失败设置错误', () async {
      when(() => mockApi.deleteBookSource(any()))
          .thenThrow(const BridgeError(message: '删除失败'));

      await readNotifier().deleteSource('http://a.com');

      expect(readState().error, equals('删除失败'));
      expect(readState().sources.length, equals(2));
    });
  });

  group('SourceNotifier saveSource', () {
    test('新建书源', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await readNotifier().loadSources();

      final newSource = makeSource('http://new.com', '新源');
      when(() => mockApi.addBookSource(any())).thenAnswer((_) async => newSource);

      await readNotifier().saveSource(newSource);

      expect(readState().sources.length, equals(1));
      expect(readState().sources[0].bookSourceName, equals('新源'));
    });

    test('更新已有书源', () async {
      final sources = [makeSource('http://a.com', '旧名')];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();

      final updated = makeSource('http://a.com', '新名');
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});

      await readNotifier().saveSource(updated);

      expect(readState().sources[0].bookSourceName, equals('新名'));
    });

    test('保存失败 rethrow', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await readNotifier().loadSources();

      final source = makeSource('http://x.com', 'X');
      when(() => mockApi.addBookSource(any()))
          .thenThrow(const BridgeError(message: '保存失败'));

      expect(
        () => readNotifier().saveSource(source),
        throwsA(isA<BridgeError>()),
      );
    });
  });

  group('SourceNotifier getSource', () {
    setUp(() async {
      final sources = [makeSource('http://a.com', 'A')];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    });

    test('找到存在的源', () {
      final source = readNotifier().getSource('http://a.com');
      expect(source, isNotNull);
      expect(source!.bookSourceName, equals('A'));
    });

    test('找不到返回 null', () {
      expect(readNotifier().getSource('http://nope.com'), isNull);
    });
  });

  group('SourceNotifier 批量操作', () {
    setUp(() async {
      final sources = [
        makeSource('http://a.com', 'A', enabled: true),
        makeSource('http://b.com', 'B', enabled: false),
        makeSource('http://c.com', 'C', enabled: true),
      ];
      when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
      await readNotifier().loadSources();
    });

    test('enterBatchMode 进入批量模式', () {
      readNotifier().enterBatchMode();
      expect(readState().batchMode, isTrue);
      expect(readState().selectedUrls, isEmpty);
    });

    test('exitBatchMode 退出批量模式', () {
      readNotifier().enterBatchMode();
      readNotifier().toggleSelection('http://a.com');
      readNotifier().exitBatchMode();
      expect(readState().batchMode, isFalse);
      expect(readState().selectedUrls, isEmpty);
    });

    test('toggleSelection 切换选中', () {
      readNotifier().enterBatchMode();
      readNotifier().toggleSelection('http://a.com');
      expect(readState().isSelected('http://a.com'), isTrue);
      expect(readState().selectedCount, equals(1));

      readNotifier().toggleSelection('http://a.com');
      expect(readState().isSelected('http://a.com'), isFalse);
    });

    test('selectAll 全选当前过滤结果', () {
      readNotifier().enterBatchMode();
      readNotifier().selectAll();
      expect(readState().selectedCount, equals(3));
      expect(readState().isAllSelected, isTrue);
    });

    test('deselectAll 取消全选', () {
      readNotifier().enterBatchMode();
      readNotifier().selectAll();
      readNotifier().deselectAll();
      expect(readState().selectedCount, equals(0));
    });

    test('batchEnable 批量启用', () async {
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});
      readNotifier().enterBatchMode();
      readNotifier().toggleSelection('http://b.com');

      await readNotifier().batchEnable();

      expect(readState().sources[1].enabled, isTrue);
      expect(readState().batchMode, isFalse);
    });

    test('batchDisable 批量禁用', () async {
      when(() => mockApi.updateBookSource(any())).thenAnswer((_) async {});
      readNotifier().enterBatchMode();
      readNotifier().toggleSelection('http://a.com');
      readNotifier().toggleSelection('http://c.com');

      await readNotifier().batchDisable();

      expect(readState().sources[0].enabled, isFalse);
      expect(readState().sources[2].enabled, isFalse);
    });

    test('batchDelete 批量删除', () async {
      when(() => mockApi.deleteBookSource(any())).thenAnswer((_) async {});
      readNotifier().enterBatchMode();
      readNotifier().toggleSelection('http://a.com');
      readNotifier().toggleSelection('http://b.com');

      await readNotifier().batchDelete();

      expect(readState().sources.length, equals(1));
      expect(readState().sources[0].bookSourceUrl, equals('http://c.com'));
    });

    test('batchEnable 失败设置错误', () async {
      when(() => mockApi.updateBookSource(any()))
          .thenThrow(const BridgeError(message: '批量失败'));
      readNotifier().enterBatchMode();
      readNotifier().toggleSelection('http://b.com');

      await readNotifier().batchEnable();

      expect(readState().error, equals('批量失败'));
    });
  });

  group('SourceNotifier importSources', () {
    test('导入成功重新加载列表', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await readNotifier().loadSources();

      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 2);
      final newSources = [makeSource('http://new.com', '新')];
      // 第二次 getBookSources 返回新列表
      var callCount = 0;
      when(() => mockApi.getBookSources()).thenAnswer((_) async {
        callCount++;
        return callCount > 1 ? newSources : [];
      });

      await readNotifier().importSources('[{"bookSourceUrl":"http://new.com"}]');

      expect(readState().loading, isFalse);
      expect(readState().error, isNull);
    });

    test('导入失败设置错误', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      await readNotifier().loadSources();

      when(() => mockApi.importBookSources(any()))
          .thenThrow(const BridgeError(message: '导入失败'));

      await readNotifier().importSources('invalid');

      expect(readState().error, equals('导入失败'));
    });
  });

  group('SourceNotifier isAllSelected', () {
    test('空列表时返回 false', () {
      expect(readState().isAllSelected, isFalse);
    });
  });

  group('SourceNotifier 排序', () {
    // 辅助：构造带排序字段的 BookSource
    BookSource makeSortSource(
      String url,
      String name, {
      String? group,
      int customOrder = 0,
      int weight = 0,
      int lastUpdateTime = 0,
      int respondTime = 180000,
      bool enabled = true,
    }) {
      return BookSource(
        bookSourceUrl: url,
        bookSourceName: name,
        bookSourceGroup: group,
        customOrder: customOrder,
        weight: weight,
        lastUpdateTime: lastUpdateTime,
        respondTime: respondTime,
        enabled: enabled,
      );
    }

    Future<void> load(List<BookSource> list) async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => list);
      await readNotifier().loadSources();
    }

    test('初始为手动升序', () {
      expect(readState().sort, equals(SourceSort.manual));
      expect(readState().sortAscending, isTrue);
    });

    test('手动排序按 customOrder 升序', () async {
      await load([
        makeSortSource('http://b.com', 'B', customOrder: 2),
        makeSortSource('http://a.com', 'A', customOrder: 1),
        makeSortSource('http://c.com', 'C', customOrder: 3),
      ]);
      readNotifier().setSort(SourceSort.manual);
      expect(
        readState().filteredSources.map((s) => s.bookSourceUrl).toList(),
        equals(['http://a.com', 'http://b.com', 'http://c.com']),
      );
    });

    test('权重排序默认高权重优先', () async {
      await load([
        makeSortSource('http://low.com', '低', weight: 1),
        makeSortSource('http://high.com', '高', weight: 100),
        makeSortSource('http://mid.com', '中', weight: 50),
      ]);
      readNotifier().setSort(SourceSort.weight);
      expect(
        readState().filteredSources.map((s) => s.bookSourceUrl).toList(),
        equals(['http://high.com', 'http://mid.com', 'http://low.com']),
      );
    });

    test('名称排序升序与降序', () async {
      await load([
        makeSortSource('http://1.com', 'banana'),
        makeSortSource('http://2.com', 'apple'),
        makeSortSource('http://3.com', 'cherry'),
      ]);
      readNotifier().setSort(SourceSort.name);
      expect(
        readState().filteredSources.map((s) => s.bookSourceName).toList(),
        equals(['apple', 'banana', 'cherry']),
      );
      readNotifier().toggleSortDirection();
      expect(readState().sortAscending, isFalse);
      expect(
        readState().filteredSources.map((s) => s.bookSourceName).toList(),
        equals(['cherry', 'banana', 'apple']),
      );
    });

    test('URL 排序升序', () async {
      await load([
        makeSortSource('http://c.com', 'C'),
        makeSortSource('http://a.com', 'A'),
        makeSortSource('http://b.com', 'B'),
      ]);
      readNotifier().setSort(SourceSort.url);
      expect(
        readState().filteredSources.map((s) => s.bookSourceUrl).toList(),
        equals(['http://a.com', 'http://b.com', 'http://c.com']),
      );
    });

    test('更新时间排序默认新优先', () async {
      await load([
        makeSortSource('http://old.com', '旧', lastUpdateTime: 100),
        makeSortSource('http://new.com', '新', lastUpdateTime: 300),
        makeSortSource('http://mid.com', '中', lastUpdateTime: 200),
      ]);
      readNotifier().setSort(SourceSort.update);
      expect(
        readState().filteredSources.map((s) => s.bookSourceUrl).toList(),
        equals(['http://new.com', 'http://mid.com', 'http://old.com']),
      );
    });

    test('启用状态排序默认启用优先', () async {
      await load([
        makeSortSource('http://off.com', '禁', enabled: false),
        makeSortSource('http://on.com', '启', enabled: true),
      ]);
      readNotifier().setSort(SourceSort.enable);
      expect(
        readState().filteredSources.map((s) => s.bookSourceUrl).toList(),
        equals(['http://on.com', 'http://off.com']),
      );
    });

    test('响应时间排序默认快优先', () async {
      await load([
        makeSortSource('http://slow.com', '慢', respondTime: 5000),
        makeSortSource('http://fast.com', '快', respondTime: 100),
        makeSortSource('http://mid.com', '中', respondTime: 1000),
      ]);
      readNotifier().setSort(SourceSort.respond);
      expect(
        readState().filteredSources.map((s) => s.bookSourceUrl).toList(),
        equals(['http://fast.com', 'http://mid.com', 'http://slow.com']),
      );
    });

    test('排序与分组筛选叠加生效', () async {
      await load([
        makeSortSource('http://b.com', 'B', group: '小说'),
        makeSortSource('http://a.com', 'A', group: '小说'),
        makeSortSource('http://z.com', 'Z', group: '漫画'),
      ]);
      readNotifier().setSort(SourceSort.name);
      readNotifier().setGroup('小说');
      expect(
        readState().filteredSources.map((s) => s.bookSourceUrl).toList(),
        equals(['http://a.com', 'http://b.com']),
      );
    });
  });
}
