// [批31] 书源管理「显示书籍数量」开关回归
//
// 取证（原版 gedoor/legado `531f9fbf07`）：
// - `BookSourceAdapter.kt:45,58,261-265`：`showBookshelfCount` 控制
//   `tvBookshelfCount` 显隐，文本为「书架：N 本」；
// - `BookSourceActivity.kt:348-355`：菜单勾选写回
//   `AppConfig.showSourceBookshelfCount`（默认关）；
// - `BookDao.flowBookshelfSourceOrigins` 按 origin 聚合书架书（排除
//   notShelf 与 local）。
//
// 本测试锁定 Dart 侧行为（Rust 聚合计数由 legado-db/legado-ffi 单测覆盖）：
// 1. 开关默认关：列表行不显示「N 本」；
// 2. 菜单开启后立即显示，偏好写入 SharedPreferences（备份 appPrefs 自动携带）；
// 3. 再次关闭后隐藏，偏好回落 false。
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/book_source.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/source_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late MockBookApi api;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = MockBookApi();
    await api.addBookSource(
      const BookSource(
        bookSourceUrl: 'https://count-test.example',
        bookSourceName: '计数测试源',
        bookshelfCount: 2,
      ),
    );
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: child),
  );

  Future<void> pumpSourceScreen(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const SourceScreen()));
    // initState 的 postFrame 回调触发 loadSources + 读取偏好
    await tester.pumpAndSettle();
  }

  Future<void> toggleShowCount(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多选项').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, '显示书籍数量'),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认关：列表行不显示书籍数', (tester) async {
    await pumpSourceScreen(tester);

    expect(find.text('计数测试源'), findsOneWidget);
    expect(find.text('书架：2 本'), findsNothing);
  });

  testWidgets('菜单开启后显示「书架：N 本」并持久化偏好', (tester) async {
    await pumpSourceScreen(tester);

    await toggleShowCount(tester);

    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('计数测试源'),
          matching: find.byType(InkWell),
        ),
        matching: find.text('书架：2 本'),
      ),
      findsOneWidget,
      reason: '开启后该源行应显示「书架：2 本」',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.showSourceBookshelfCount), isTrue);
  });

  testWidgets('再次关闭后隐藏并写回 false', (tester) async {
    await pumpSourceScreen(tester);
    await toggleShowCount(tester);
    expect(find.text('书架：2 本'), findsOneWidget);

    await toggleShowCount(tester);

    expect(find.text('书架：2 本'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.showSourceBookshelfCount), isFalse);
  });

  testWidgets('启动时偏好为开：加载完成后显示书籍数', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.showSourceBookshelfCount: true,
    });
    await pumpSourceScreen(tester);

    expect(find.text('书架：2 本'), findsOneWidget);
  });
}
