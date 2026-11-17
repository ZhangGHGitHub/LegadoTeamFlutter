// 搜索范围弹层（◯ 顶栏钮）回归测试
//
// 覆盖设备验收（批45b，61a_src_tab.png）发现的两个 P2 缺陷：
// 1. 溢出：小屏 / 大字号下底部 `BOTTOM OVERFLOWED BY N PIXELS`，列表被压成
//    0 高、底栏被挤出 Column 布局盒（点按落到遮罩层 → 弹层关闭且不提交）；
// 2. 勾选不生效：范围快捷节立即写 provider、复选框/单选只在「确定」提交，
//    两套时序并存 → 多次操作后（如先点分组快捷项再点确定）勾选被覆盖回退。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/search/search_notifier.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  const sources = <BookSource>[
    BookSource(
      bookSourceUrl: 'https://a.com',
      bookSourceName: 'A 源',
      bookSourceGroup: 'QA',
    ),
    BookSource(
      bookSourceUrl: 'https://b.com',
      bookSourceName: 'B 源',
      bookSourceGroup: 'QA',
    ),
    BookSource(
      bookSourceUrl: 'https://c.com',
      bookSourceName: 'C 源',
      bookSourceGroup: '其他',
    ),
  ];

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
        .thenAnswer((_) async => []);
    when(() => mockApi.addSearchKeyword(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.clearSearchHistory()).thenAnswer((_) async {});
    when(() => mockApi.cancelSearch()).thenAnswer((_) async {});
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.getEnabledBookSources())
        .thenAnswer((_) async => sources);
    when(() => mockApi.searchMultiStream(
            any(),
            sourceUrls: any(named: 'sourceUrls'),
            page: any(named: 'page')))
        .thenAnswer((_) => const Stream.empty());
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: child),
      );

  Future<void> pumpSearch(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const SearchScreen()));
    await tester.pump();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('搜索范围'));
    await tester.pumpAndSettle();
  }

  /// 最近一次 searchMultiStream 实际收到的 sourceUrls
  List<String>? lastSearchSourceUrls() {
    final calls = verify(() => mockApi.searchMultiStream(
          any(),
          sourceUrls: captureAny(named: 'sourceUrls'),
          page: any(named: 'page'),
        )).captured;
    if (calls.isEmpty) return null;
    return calls.last as List<String>?;
  }

  group('搜索范围弹层：布局不溢出且底栏可点', () {
    testWidgets('360×640 + 书源页签：无 RenderFlex 溢出，底栏按钮可命中',
        (tester) async {
      // 设备验收复现尺寸（逻辑 360×640，与 1080×1920@3.0 一致）
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await pumpSearch(tester);
      await openSheet(tester);
      // 切到「书源」页签（设备截图 61a_src_tab.png 的场景）
      await tester.tap(find.text('书源'));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: '内容超出可用高度时必须由滚动容器承载，不得 RenderFlex 溢出',
      );

      // 底栏三钮必须位于布局盒内（修复前被挤出 → hitTestable 为空 →
      // 点按落到遮罩层，弹层关闭且勾选不提交）
      for (final label in ['全部书源', '取消', '确定']) {
        final button = find.widgetWithText(TextButton, label);
        expect(button, findsOneWidget);
        expect(
          button.hitTestable(),
          findsOneWidget,
          reason: '底栏「$label」必须可命中（修复前可见但点不到）',
        );
      }

      // 书源列表不得被压成 0 高（修复前 Expanded 在溢出 Column 中高度为 0，
      // 整块列表消失、无从勾选）
      final listScroll = find.byKey(const ValueKey('search-scope-scroll'));
      expect(listScroll, findsOneWidget);
      final radioTiles = find.byType(RadioListTile<String>);
      expect(radioTiles, findsWidgets, reason: '书源单选列表必须渲染');
      expect(
        tester.getRect(radioTiles.first).height,
        greaterThan(0),
        reason: '书源列表行高不得被压成 0',
      );
    });

    testWidgets('640×360 横屏 + 1.6 倍字号：可滚动、底栏仍可点', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(640, 360),
            textScaler: TextScaler.linear(1.6),
          ),
          child: wrap(const SearchScreen()),
        ),
      );
      await tester.pump();
      await openSheet(tester);
      // 横屏下内容区需要滚动才能看到分段切换，先 ensureVisible 再点
      final sourceTab = find.text('书源');
      await tester.ensureVisible(sourceTab);
      await tester.pumpAndSettle();
      await tester.tap(sourceTab);
      await tester.pumpAndSettle();
      // 断言页签真的切过去了（书源筛选框出现），避免空转的假绿
      expect(find.text('搜索书源'), findsOneWidget,
          reason: '横屏下「书源」页签必须可点中并完成切换');

      expect(tester.takeException(), isNull,
          reason: '横屏 + 大字号下同样不得溢出');

      final okButton = find.widgetWithText(TextButton, '确定');
      expect(okButton.hitTestable(), findsOneWidget,
          reason: '底栏「确定」必须可命中');

      // 内容区滚动容器存在且可滚动（内容超屏时必须能滚，不得硬塞）
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('search-scope-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        scrollable.position.maxScrollExtent,
        greaterThan(0),
        reason: '内容高度超过可用高度时必须可纵向滚动',
      );
      // 用 jumpTo 而非 animateTo：后者返回的 Future 需要帧驱动，
      // 在 testWidgets 内直接 await 会因无帧推进而死锁
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      // 滚到底后仍无异常，且底栏未随内容滚走
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(TextButton, '确定').hitTestable(),
          findsOneWidget);
    });
  });

  group('搜索范围弹层：勾选写回与回显', () {
    testWidgets('书源页签选中源 → 确定 → 状态写回且搜索使用该源', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await pumpSearch(tester);
      await openSheet(tester);
      await tester.tap(find.text('书源'));
      await tester.pumpAndSettle();

      final target = find.widgetWithText(RadioListTile<String>, 'B 源');
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();

      final okButton = find.widgetWithText(TextButton, '确定');
      await tester.ensureVisible(okButton);
      await tester.pumpAndSettle();
      await tester.tap(okButton);
      await tester.pumpAndSettle();

      final state = container.read(searchNotifierProvider);
      expect(state.selectedSourceUrls, {'https://b.com'},
          reason: '勾选的书源必须写回 notifier');
      expect(state.selectedGroups, isEmpty);

      // 实际搜索入参必须是该单源
      await container.read(searchNotifierProvider.notifier).search('测试');
      await tester.pump(const Duration(milliseconds: 50));
      expect(lastSearchSourceUrls(), ['https://b.com'],
          reason: '搜索必须真的只用所选书源');
    });

    testWidgets('「全部书源」→ 清空筛选且搜索入参为 null（搜全部）', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      container
          .read(searchNotifierProvider.notifier)
          .selectSourceOnly('https://a.com');
      await pumpSearch(tester);
      await openSheet(tester);

      final allButton = find.widgetWithText(TextButton, '全部书源');
      expect(allButton.hitTestable(), findsOneWidget,
          reason: '底栏「全部书源」必须可命中（修复前落在布局盒外点不到）');
      await tester.tap(allButton);
      await tester.pumpAndSettle();

      final state = container.read(searchNotifierProvider);
      expect(state.selectedSourceUrls, isEmpty);
      expect(state.selectedGroups, isEmpty);

      await container.read(searchNotifierProvider.notifier).search('测试');
      await tester.pump(const Duration(milliseconds: 50));
      expect(lastSearchSourceUrls(), isNull,
          reason: '无筛选 → sourceUrls 必须为 null（搜全部书源）');
    });

    testWidgets('分组勾选 → 确定 → 关闭重开仍保留（不回弹）', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await pumpSearch(tester);
      await openSheet(tester);

      // 默认分组模式：点复选框行（而非快捷节同名文本，避免二义）
      final checkbox = find.widgetWithText(CheckboxListTile, '其他');
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(checkbox);
      await tester.pumpAndSettle();

      final okButton = find.widgetWithText(TextButton, '确定');
      await tester.ensureVisible(okButton);
      await tester.pumpAndSettle();
      await tester.tap(okButton);
      await tester.pumpAndSettle();
      expect(container.read(searchNotifierProvider).selectedGroups, {'其他'});

      // 重开弹层：复选框仍为选中态
      await openSheet(tester);
      final reopened = tester.widget<CheckboxListTile>(
        find.widgetWithText(CheckboxListTile, '其他'),
      );
      expect(reopened.value, isTrue, reason: '重开弹层必须回显已选分组');
    });

    testWidgets('多次操作：分组快捷项 + 书源页签 → 确定后以最后选择为准',
        (tester) async {
      // 缺陷核心复现：旧实现里快捷节立即写 provider、页签内选择只在确定
      // 提交，先点分组快捷项再切书源页签选源并确定，分组选择会被「确定」
      // 静默回退/覆盖（toggleSource 清空分组），表现为「勾选不生效」。
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await pumpSearch(tester);
      await openSheet(tester);

      // ① 快捷节点「其他」分组（旧实现此处立即写 provider）
      final quickGroup = find.descendant(
        of: find.byType(InkWell),
        matching: find.text('其他'),
      );
      await tester.tap(quickGroup.first);
      await tester.pumpAndSettle();
      expect(
        container.read(searchNotifierProvider).selectedGroups,
        isEmpty,
        reason: '未点确定前不得写入 provider（取消须真正丢弃改动）',
      );

      // ② 切书源页签选 C 源
      await tester.tap(find.text('书源'));
      await tester.pumpAndSettle();
      final sourceTile = find.widgetWithText(RadioListTile<String>, 'C 源');
      await tester.ensureVisible(sourceTile);
      await tester.pumpAndSettle();
      await tester.tap(sourceTile);
      await tester.pumpAndSettle();

      // ③ 确定
      final okButton = find.widgetWithText(TextButton, '确定');
      await tester.ensureVisible(okButton);
      await tester.pumpAndSettle();
      await tester.tap(okButton);
      await tester.pumpAndSettle();

      final state = container.read(searchNotifierProvider);
      expect(state.selectedSourceUrls, {'https://c.com'},
          reason: '最后一次选择（书源）必须生效');
      expect(state.selectedGroups, isEmpty,
          reason: '分组选择应被书源选择原子替换，不得残留冲突');
    });

    testWidgets('取消不提交：勾选后点取消 → 状态保持原样', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      container
          .read(searchNotifierProvider.notifier)
          .selectSourceOnly('https://a.com');
      await pumpSearch(tester);
      await openSheet(tester);
      await tester.tap(find.text('书源'));
      await tester.pumpAndSettle();

      final sourceTile = find.widgetWithText(RadioListTile<String>, 'C 源');
      await tester.ensureVisible(sourceTile);
      await tester.pumpAndSettle();
      await tester.tap(sourceTile);
      await tester.pumpAndSettle();

      final cancelButton = find.widgetWithText(TextButton, '取消');
      await tester.ensureVisible(cancelButton);
      await tester.pumpAndSettle();
      await tester.tap(cancelButton);
      await tester.pumpAndSettle();

      expect(
        container.read(searchNotifierProvider).selectedSourceUrls,
        {'https://a.com'},
        reason: '取消必须丢弃暂存改动',
      );
    });

    testWidgets('书源范围打开弹层：直接进入书源页签并回显已选源', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      container
          .read(searchNotifierProvider.notifier)
          .selectSourceOnly('https://c.com');
      await pumpSearch(tester);
      await openSheet(tester);

      final group = tester.widget<RadioGroup<String>>(
        find.byType(RadioGroup<String>),
      );
      expect(group.groupValue, 'https://c.com',
          reason: '重开必须回显已选书源');
    });
  });
}
