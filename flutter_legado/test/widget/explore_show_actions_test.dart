// 发现书单页顶栏动作回归测试（差异清单 A1 对齐项：
// 筛选漏斗 = 本地关键字筛选；☰ 列表切换 = 书卡密度 舒适/紧凑）
//
// 对齐基准：参考版书单页顶栏（←+筛选漏斗+☰ 列表切换，用户 0913 手动截图
// 12~17）；能力不丢失——我方既有 加入书架/页码 动作保留。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/screens/explore_show_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';

void main() {
  final mockApi = MockBookApi();

  final source = BookSource(
    bookSourceUrl: 'https://show.test',
    bookSourceName: '书单验证源',
    exploreUrl: 'https://show.test/{{key}}',
  );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: ExploreShowScreen(
            args: ExploreShowArgs(
              source: source,
              categoryName: '玄幻',
              categoryUrl: 'https://show.test/xuanhuan',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // mock exploreFetchBooks 首页返回 10 本：发现书籍1..10（作者1..作者10）
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('默认展示全部书籍；漏斗筛选按关键字过滤（书名/作者）',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('发现书籍 1'), findsOneWidget);
    expect(find.text('发现书籍 4'), findsOneWidget);

    // 点筛选漏斗 → 弹层输入关键字「作者1」→ 确定（只匹配 作者1/作者10 两本）
    await tester.tap(find.byTooltip('筛选'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '作者1');
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('发现书籍 1'), findsOneWidget);
    expect(find.text('发现书籍 2'), findsNothing);
    // 漏斗进入已开启态（tooltip 变化）
    expect(find.byTooltip('筛选（已开启：作者1）'), findsOneWidget);
  });

  testWidgets('筛选弹层清空关键字 = 取消过滤', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byTooltip('筛选'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '作者4');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.text('发现书籍 2'), findsNothing);

    // 再开筛选：清空关键字 → 恢复全部
    await tester.tap(find.byTooltip('筛选（已开启：作者4）'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.text('发现书籍 2'), findsOneWidget);
    expect(find.text('发现书籍 4'), findsOneWidget);
  });

  testWidgets('☰ 列表切换：紧凑密度下封面缩小', (tester) async {
    await pumpScreen(tester);
    double coverWidth() => tester
        .widgetList<BookCover>(find.byType(BookCover))
        .first
        .width;
    expect(coverWidth(), 45);

    await tester.tap(find.byTooltip('切换为紧凑'));
    await tester.pump();
    expect(coverWidth(), 36);
  });
}
