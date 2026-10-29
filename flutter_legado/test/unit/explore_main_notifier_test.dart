// 发现页源内容模式 Notifier 单元测试
//
// 覆盖：
// - 三个偏好键（exploreMainContent/exploreMainSourceUrl/exploreMainKind）
//   的恢复与落盘；
// - 源内容模式书源/分类选择；
// - 选中源被删除时回退源列表（本批验收要求）；
// - 布局模式与横竖屏列数持久化；
// - 分类键编码/解码往返与非法条目丢弃。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_main_notifier.dart';
import 'package:flutter_legado/src/providers/explore/explore_main_state.dart';
import 'package:flutter_legado/src/providers/explore/explore_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRustApi mockApi;
  late ProviderContainer container;

  const sourceA = BookSource(
    bookSourceUrl: 'https://a.test',
    bookSourceName: '源A',
    bookSourceGroup: '分组1',
    exploreUrl: '分类A::https://a.test/list',
  );
  const sourceB = BookSource(
    bookSourceUrl: 'https://b.test',
    bookSourceName: '源B',
    bookSourceGroup: '分组2',
    exploreUrl: '分类B::https://b.test/list',
  );

  const kindA = ExploreCategory(title: '分类A', url: 'https://a.test/list');
  const kindB = ExploreCategory(title: '分类B', url: 'https://b.test/list');

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(
      () => mockApi.getBookSources(),
    ).thenAnswer((_) async => [sourceA, sourceB]);
  });

  Future<void> createContainer() async {
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    container.listen(exploreMainNotifierProvider, (_, _) {});
    await pumpEventQueue();
    await pumpEventQueue();
  }

  ExploreMainState readState() => container.read(exploreMainNotifierProvider);
  ExploreMainNotifier readNotifier() =>
      container.read(exploreMainNotifierProvider.notifier);

  group('偏好恢复', () {
    test('无偏好时默认源列表模式，并默认选中第一个发现源', () async {
      await createContainer();

      final state = readState();
      expect(state.loaded, isTrue);
      expect(state.showContent, isFalse);
      expect(state.selectedSourceUrl, sourceA.bookSourceUrl);
      expect(state.gridMode, isFalse);
      expect(state.gridCountPortrait, 3);
      expect(state.gridCountLandscape, 7);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(exploreMainSourceUrlKey), sourceA.bookSourceUrl);
    });

    test('恢复内容模式/书源/分类选择与布局偏好', () async {
      final kindKey = exploreKindKey(kindB);
      SharedPreferences.setMockInitialValues({
        exploreMainContentKey: true,
        exploreMainSourceUrlKey: sourceB.bookSourceUrl,
        exploreMainKindKey: encodeExploreKindSelections({
          sourceB.bookSourceUrl: kindKey,
        }),
        exploreLayoutModeKey: 1,
        exploreLayoutGridPortraitKey: 4,
        exploreLayoutGridLandscapeKey: 6,
      });

      await createContainer();

      final state = readState();
      expect(state.showContent, isTrue);
      expect(state.selectedSourceUrl, sourceB.bookSourceUrl);
      expect(state.kindKeyFor(sourceB.bookSourceUrl), kindKey);
      expect(state.gridMode, isTrue);
      expect(state.gridCountFor(landscape: false), 4);
      expect(state.gridCountFor(landscape: true), 6);
    });

    test('选中源被删除 → 回退源列表并清理持久化选择', () async {
      SharedPreferences.setMockInitialValues({
        exploreMainContentKey: true,
        exploreMainSourceUrlKey: 'https://gone.test',
      });

      await createContainer();

      final state = readState();
      expect(state.showContent, isFalse);
      expect(state.selectedSourceUrl, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(exploreMainContentKey), isFalse);
      expect(prefs.getString(exploreMainSourceUrlKey), '');
    });

    test('发现源列表为空 → 内容模式回退源列表', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
      SharedPreferences.setMockInitialValues({
        exploreMainContentKey: true,
        exploreMainSourceUrlKey: sourceA.bookSourceUrl,
      });

      await createContainer();

      final state = readState();
      expect(state.showContent, isFalse);
      expect(state.selectedSourceUrl, isEmpty);
    });
  });

  group('用户操作与持久化', () {
    test('切换内容模式/选择书源/选择分类均落盘', () async {
      await createContainer();

      readNotifier().setShowContent(true);
      readNotifier().selectSource(sourceB.bookSourceUrl);
      readNotifier().selectKind(sourceB.bookSourceUrl, exploreKindKey(kindB));
      await pumpEventQueue();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(exploreMainContentKey), isTrue);
      expect(prefs.getString(exploreMainSourceUrlKey), sourceB.bookSourceUrl);
      final decoded = parseExploreKindSelections(
        prefs.getString(exploreMainKindKey) ?? '',
      );
      expect(decoded[sourceB.bookSourceUrl], exploreKindKey(kindB));

      expect(readState().showContent, isTrue);
      expect(readState().selectedSourceUrl, sourceB.bookSourceUrl);
      expect(
        readState().kindKeyFor(sourceB.bookSourceUrl),
        exploreKindKey(kindB),
      );
    });

    test('布局模式与横竖屏列数分别持久化并收敛到 1..10', () async {
      await createContainer();

      readNotifier().setGridMode(true);
      readNotifier().setGridCount(5, landscape: false);
      readNotifier().setGridCount(99, landscape: true);
      await pumpEventQueue();

      expect(readState().gridMode, isTrue);
      expect(readState().gridCountFor(landscape: false), 5);
      // 越界值收敛到上限
      expect(readState().gridCountFor(landscape: true), exploreGridCountMax);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(exploreLayoutModeKey), 1);
      expect(prefs.getInt(exploreLayoutGridPortraitKey), 5);
      expect(prefs.getInt(exploreLayoutGridLandscapeKey), exploreGridCountMax);
    });

    test('删除当前选中源后重新同步会回退源列表', () async {
      await createContainer();
      readNotifier().setShowContent(true);
      readNotifier().selectSource(sourceB.bookSourceUrl);
      await pumpEventQueue();
      expect(readState().showContent, isTrue);

      // 模拟源 B 被删除：发现源列表只剩 A，并触发重新加载
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [sourceA]);
      await container.read(exploreNotifierProvider.notifier).refresh();
      await pumpEventQueue();

      expect(readState().showContent, isFalse);
      expect(readState().selectedSourceUrl, isEmpty);
    });
  });

  group('分类键与分类过滤', () {
    test('loadableExploreMainKinds 只保留 URL 型可用分类并排除 ERROR 占位', () {
      final kinds = loadableExploreMainKinds([
        const ExploreCategory(title: '分组标题'),
        kindA,
        kindA, // 重复项去重
        const ExploreCategory(title: '开关', type: 'toggle', url: 'x'),
        const ExploreCategory(title: 'ERROR', url: '解析失败详情'),
      ]);
      expect(kinds, hasLength(1));
      expect(kinds.single.title, '分类A');
    });

    test('分类选择编码/解码往返，非法条目丢弃', () {
      final encoded = encodeExploreKindSelections({
        sourceA.bookSourceUrl: exploreKindKey(kindA),
        sourceB.bookSourceUrl: exploreKindKey(kindB),
      });
      final decoded = parseExploreKindSelections(encoded);
      expect(decoded, hasLength(2));
      expect(decoded[sourceA.bookSourceUrl], exploreKindKey(kindA));

      // 缺分隔符/空值条目丢弃
      final parsed = parseExploreKindSelections(
        'abc\u0001def\u0000\u0001x\u0000y',
      );
      expect(parsed, {'x': 'y'});
    });
  });
}
