// [设置批2b-2b] 「我的」容器双栏 widget 测试
//
// 覆盖：
// - 双栏结构（左菜单 + 24dp 间距 + 右 nested Navigator 空态）；
// - 左栏入口双栏进右栏、单栏走 root push；
// - 右栏返回栈（pop 后回空态、选中清除）；
// - 宽度变化：仍双栏时保留右栏路由；缩到单栏时栈顶转 root；
// - 设置项持久化（另见 unit/multi_pane_setting_test.dart）；
// - 最小双栏高度 + 大字体不溢出。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/about_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/utils/multi_pane_layout.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/navigation/adaptive_my_pane.dart';

import '../mocks/mocks.dart';

/// 测试桩页面：文本 = `stub:<route name>`
class _StubPage extends StatelessWidget {
  const _StubPage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}

Route<dynamic> _stubRoute(RouteSettings settings) {
  return MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => _StubPage('stub:${settings.name}'),
  );
}

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.getServerStatus()).thenAnswer((_) async => 'stopped');
    when(() => api.getBooks()).thenAnswer((_) async => []);
    when(() => api.getBookGroups()).thenAnswer((_) async => []);
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    when(() => api.getRssSources()).thenAnswer((_) async => []);
    when(() => api.getReadRecords()).thenAnswer((_) async => []);
    when(() => api.readRecordDailyList(any())).thenAnswer((_) async => []);
  });

  /// 设定逻辑窗口尺寸（devicePixelRatio=1）
  void setWindowSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<GlobalKey<NavigatorState>> pumpPane(
    WidgetTester tester, {
    required MultiPaneMode mode,
    required Size size,
    double textScale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({PrefKeys.multiPaneMode: mode.name});
    setWindowSize(tester, size);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          onGenerateRoute: _stubRoute,
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            );
          },
          home: Scaffold(
            body: AdaptiveMyPane(
              navigatorKey: navigatorKey,
              routeGenerator: _stubRoute,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return navigatorKey;
  }

  testWidgets('双栏：左菜单 + 右空态，入口在右栏打开，返回回空态并清除高亮', (tester) async {
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(900, 700),
    );

    expect(find.byKey(const ValueKey('my-pane-left')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-gap')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('选择左侧项目'), findsOneWidget);

    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();

    // 右栏打开桩页面，左栏菜单仍在（未 root push）
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('my-pane-right')),
        matching: find.text('stub:/sources'),
      ),
      findsOneWidget,
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('选择左侧项目'), findsNothing);
    expect(
      tester
          .widget<IosListTile>(find.widgetWithText(IosListTile, '书源管理'))
          .selected,
      isTrue,
    );

    // 返回键先 pop 右栏（HomeScreen 调用同一 nested Navigator）
    await navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('stub:/sources'), findsNothing);
    expect(find.text('选择左侧项目'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      tester
          .widget<IosListTile>(find.widgetWithText(IosListTile, '书源管理'))
          .selected,
      isFalse,
    );
  });

  testWidgets('单栏（off）：入口保持 root push，返回后回我的页', (tester) async {
    await pumpPane(tester, mode: MultiPaneMode.off, size: const Size(900, 700));

    expect(find.byKey(const ValueKey('my-pane-right')), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();

    expect(find.text('stub:/sources'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);

    Navigator.of(tester.element(find.text('stub:/sources'))).pop();
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('stub:/sources'), findsNothing);
  });

  testWidgets('宽度变化：仍双栏保留右栏路由；缩到单栏时栈顶转 root', (tester) async {
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.auto,
      size: const Size(840, 700),
    );

    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();
    expect(find.text('stub:/sources'), findsOneWidget);

    // 仍 ≥840：双栏保留，路由与选中都不丢
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(find.text('stub:/sources'), findsOneWidget);
    expect(
      tester
          .widget<IosListTile>(find.widgetWithText(IosListTile, '书源管理'))
          .selected,
      isTrue,
    );

    // 缩到 700：退出双栏，右栏栈顶转 root push（页面不丢）
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-right')), findsNothing);
    expect(find.text('stub:/sources'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);

    // 关闭转推的 root 页面 → 回单栏我的页
    Navigator.of(tester.element(find.text('stub:/sources'))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-right')), findsNothing);

    // 再放大：回到双栏，右栏已清空（转推后不重复保留）
    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(find.text('选择左侧项目'), findsOneWidget);
    expect(find.text('stub:/sources'), findsNothing);
    expect(navigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('最小双栏尺寸 744x320 + 2x 大字体不溢出', (tester) async {
    await pumpPane(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(744, 320),
      textScale: 2,
    );

    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(find.text('选择左侧项目'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口 + 2x 大字体保持单栏且不溢出', (tester) async {
    await pumpPane(
      tester,
      mode: MultiPaneMode.auto,
      size: const Size(700, 600),
      textScale: 2,
    );

    expect(find.byKey(const ValueKey('my-pane-right')), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HomeScreen 返回键：先 pop 右栏，空栈后切回书架', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.multiPaneMode: MultiPaneMode.always.name,
      // 关闭 Rail，保证 1000dp 窗口仍用底栏切 Tab（本用例只验证双栏返回）
      PrefKeys.tabletInterface: 'off',
    });
    setWindowSize(tester, const Size(1000, 700));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: const HomeScreen(),
          onGenerateRoute: AppRoutes.generateRoute,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(NavigationDestination).at(4));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('关于'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    // 右栏打开「关于」，左栏菜单仍在
    expect(find.byType(AboutScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );

    // 第一次返回：pop 右栏，仍停留在「我的」
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsNothing);
    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );

    // 第二次返回：右栏空栈 → 原逻辑切回书架
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
  });
}
