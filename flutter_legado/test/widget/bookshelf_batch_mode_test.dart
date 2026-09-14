import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 选择模式（批量）书卡列表渲染回归测试
///
/// 背景：台账 1-5 P0「选择模式书卡列表不渲染」。此前整屏空白已修，但选择
/// 模式下书架列表/网格分支仍未完整呈现书卡（封面+书名+作者）+ 勾选态。
/// 本测试 pump 真实 [BookshelfScreen]（注入 MockBookApi 提供 3 本书），
/// 复现并锁定「进入选择模式后书卡行仍渲染 + 点按切换勾选 + 胶囊数字变化」。
void main() {
  /// pump 真实书架页并返回其 ProviderScope 的容器（Riverpod 2.x 用
  /// ProviderScope.containerOf 取回，避免已移除的 `container:` 参数）。
  Future<ProviderContainer> pumpShelf(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
        child: MaterialApp(home: BookshelfScreen()),
      ),
    );
    final context = tester.element(find.byType(BookshelfScreen));
    return ProviderScope.containerOf(context);
  }

  testWidgets('选择模式下书卡列表完整渲染且可勾选', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = await pumpShelf(tester);
    addTearDown(container.dispose);
    // Notifier build() 里 _loadSettings/_loadBooks/_loadGroups 走微任务 + 异步，
    // 连续 pump 让状态落定（isLoading=false、books 就绪）。
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 正常模式：书名在列表行可见
    expect(find.text('斗破苍穹'), findsOneWidget,
        reason: '正常模式书卡行应渲染书名');

    // 进入选择模式
    container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    await tester.pumpAndSettle();

    // [P0 根因] 选择模式下书卡列表仍必须完整渲染（书名出现于书卡行，
    // 而非仅「最近阅读」行）——这是此前被拒修复的缺陷点。
    expect(
      find.text('斗破苍穹'),
      findsOneWidget,
      reason: '选择模式下书卡行必须渲染书名（P0 缺陷点）',
    );

    // 顶栏 4 个批量动作保留
    expect(find.byIcon(Icons.select_all), findsOneWidget, reason: '全选');
    expect(find.byIcon(Icons.flip_rounded), findsOneWidget, reason: '反选');
    expect(find.byIcon(Icons.delete_rounded), findsOneWidget, reason: '删除');
    expect(find.byIcon(Icons.close_rounded), findsOneWidget, reason: '取消');

    // 摘要胶囊：未勾选时「已选 0 本」
    expect(find.text('已选 0 本'), findsOneWidget, reason: '初始未选');

    // 点按书卡 → 勾选态切换，胶囊数字 0 → 1
    await tester.tap(find.text('斗破苍穹'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 本'), findsOneWidget,
        reason: '点按后胶囊计数应变为 1');

    // 再点一次 → 取消勾选，数字回到 0
    await tester.tap(find.text('斗破苍穹'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 本'), findsOneWidget,
        reason: '再点按后计数应回到 0');
  });

  testWidgets('选择模式下网格视图书卡同样渲染且可勾选', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // [骨架对齐 2.0.260 | 台账 1-3] 2 列大封面网格在 800 宽视口下单格
    // 高 ~535px（5:7），首排卡书名落在默认 600px 视口之外导致点按落空。
    // 加高测试视口适配新骨架几何（断言本身不变）。
    tester.view.physicalSize = const Size(800 * 3, 1000 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final container = await pumpShelf(tester);
    addTearDown(container.dispose);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 切到网格视图
    container
        .read(bookshelfNotifierProvider.notifier)
        .toggleViewMode();
    await tester.pumpAndSettle();
    expect(find.text('斗破苍穹'), findsOneWidget, reason: '网格视图书名可见');

    // 进入选择模式
    container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    await tester.pumpAndSettle();

    // [P0 根因] 网格分支选择模式同样须渲染书卡 + 勾选
    expect(
      find.text('斗破苍穹'),
      findsOneWidget,
      reason: '选择模式网格书卡必须渲染书名（P0 缺陷点）',
    );

    // 点按书卡（网格瓦片）→ 胶囊数字 0 → 1
    expect(find.text('已选 0 本'), findsOneWidget);
    await tester.tap(find.text('斗破苍穹'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 本'), findsOneWidget);
  });
}
