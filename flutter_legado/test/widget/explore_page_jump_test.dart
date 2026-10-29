// 发现书单页页码跳转 widget 测试（批36）
//
// 参考版依据：ExploreShowScreen.kt:439-470（canJumpPage 才显示页码按钮 +
// 数字输入对话框 ≤4 位）与 ExploreShowViewModel.kt:357-380（跳页重建列表）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/explore_show_screen.dart';
import 'package:flutter_legado/src/widgets/explore_page_control.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  const source = BookSource(
    bookSourceUrl: 'https://paged.test',
    bookSourceName: '页码源',
  );

  const pagedArgs = ExploreShowArgs(
    source: source,
    categoryName: '榜单',
    categoryUrl: 'https://paged.test/list/{{page}}.html',
  );

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.exploreFetchBooks(any(), any(), any())).thenAnswer((
      invocation,
    ) async {
      final page = invocation.positionalArguments[2] as int;
      // 9999 视为越界空页（用于验证跳页后 hasMore 按该页结果）
      if (page >= 9999) return <SearchBook>[];
      return [
        SearchBook(
          bookUrl: 'https://paged.test/book/$page',
          name: '第 $page 页书',
          author: '作者',
        ),
      ];
    });
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: ExploreShowScreen(args: pagedArgs)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder confirmButton() => find.widgetWithText(TextButton, '确定');

  bool confirmEnabled(WidgetTester tester) =>
      tester.widget<TextButton>(confirmButton()).onPressed != null;

  String inputText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('规则支持页码：输入合法页码跳转并按目标页重建列表', (tester) async {
    await pumpScreen(tester);

    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('第 1 页书'), findsOneWidget);

    await tester.tap(find.text('第 1 页'));
    await tester.pumpAndSettle();
    expect(find.text('跳转到页码'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '3');
    await tester.pump();
    expect(confirmEnabled(tester), isTrue);

    await tester.tap(confirmButton());
    await tester.pumpAndSettle();

    expect(find.text('第 3 页'), findsOneWidget);
    expect(find.text('第 3 页书'), findsOneWidget);
    expect(find.text('第 1 页书'), findsNothing);
  });

  testWidgets('输入 0 时确认按钮禁用（页码必须 ≥1）', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('第 1 页'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    expect(confirmEnabled(tester), isFalse);

    // 清空同样不可确认
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(confirmEnabled(tester), isFalse);
  });

  testWidgets('非数字输入被过滤，不算有效页码', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('第 1 页'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(inputText(tester), isEmpty);
    expect(confirmEnabled(tester), isFalse);

    // 混合输入只保留数字
    await tester.enterText(find.byType(TextField), '2a');
    await tester.pump();
    expect(inputText(tester), '2');
    expect(confirmEnabled(tester), isTrue);
  });

  testWidgets('页码输入最多 4 位，超长截断', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('第 1 页'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '12345');
    await tester.pump();
    expect(inputText(tester), '1234');
    expect(explorePageInputMaxLength, 4);
  });

  testWidgets('跳转到越界空页：展示空态 + 页码更新，不再可加载更多', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('第 1 页'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '9999');
    await tester.pump();
    await tester.tap(confirmButton());
    await tester.pumpAndSettle();

    expect(find.text('第 9999 页'), findsOneWidget);
    expect(find.text('暂无书籍'), findsOneWidget);
    expect(find.text('第 1 页书'), findsNothing);
    // hasMore=false → 不展示「上滑加载更多」相关错误/加载尾巴
    expect(find.text('加载失败，点击重试'), findsNothing);
  });
}
