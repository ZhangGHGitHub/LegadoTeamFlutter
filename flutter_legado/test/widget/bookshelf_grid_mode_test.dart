import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 选择模式（批量）网格视图书卡渲染回归测试
///
/// 背景：台账 1-5 P0「选择模式书卡列表不渲染」的网格分支配套用例：
/// 切到网格视图后，选择模式下书卡（封面+书名+作者）+ 勾选态必须完整
/// 呈现。pump 真实 [BookshelfScreen]（注入 MockBookApi，消费合成脱敏
/// 样例资产 assets/mock_data/bookshelf_sample.json 的 10 本书）。
///
/// [测试隔离] 本用例单独成文件：MockBookApi 经 rootBundle 惰性加载
/// 样例资产，而 flutter test 的 fake-async 域中资产加载仅在该进程内
/// 首个用例可靠完成（后续用例中同一加载永不 resolve，书架停留在
/// isLoading 骨架分支，持续动画令无界 pumpAndSettle 永不收敛）。
/// 独立文件 = 独立 isolate，本用例即首用例，资产加载可靠。
/// 列表+批量用例见 bookshelf_batch_mode_test.dart。
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
    // Notifier build() 里 _loadSettings/_loadBooks/_loadGroups 走微任务 +
    // 资产异步加载，连续 pump 让状态落定（isLoading=false、books 就绪）。
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 切到网格视图
    container
        .read(bookshelfNotifierProvider.notifier)
        .toggleViewMode();
    await tester.pumpAndSettle();
    expect(find.text('示例书籍 01'), findsOneWidget,
        reason: '网格视图书名可见');

    // 进入选择模式
    container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    await tester.pumpAndSettle();

    // [P0 根因] 网格分支选择模式同样须渲染书卡 + 勾选
    expect(
      find.text('示例书籍 01'),
      findsOneWidget,
      reason: '选择模式网格书卡必须渲染书名（P0 缺陷点）',
    );

    // 点按书卡（网格瓦片）→ 胶囊数字 0 → 1
    expect(find.text('已选 0 本'), findsOneWidget);
    await tester.tap(find.text('示例书籍 01'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 本'), findsOneWidget);
  });
}
