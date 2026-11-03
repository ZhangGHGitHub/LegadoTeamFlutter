// [设置批2b-2b] 「我的」容器双栏/单栏 widget 测试
//
// 覆盖：
// - 双栏结构（左菜单 + 24dp 间距 + 右 nested Navigator 空态）；
// - 双栏菜单入口进右栏 nested；单栏命名入口 root push 全屏；
// - 双→单：命名栈顶转 root、匿名栈顶 nested 全屏（隐藏底栏/禁横滑）；
// - 重复点同入口去重；返回逐级 pop，空栈回菜单并清高亮；
// - 宽度变化双→单→双保留同一栈（含匿名 MaterialPageRoute 与输入内容）；
// - 不可见 Tab 期间形态冻结（含窄窗安全回单栏），重新可见后按新窗口判定；
// - 最小双栏高度 + 2x 大字体、右栏 360x320 / 页签减高 nested 弹层不溢出；
// - HomeScreen + Rail 840/839dp 窗口阈值与返回键优先级。
import 'dart:async';

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
import 'package:flutter_legado/src/widgets/navigation/app_navigation_bars.dart';

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

/// 匿名路由编辑页：验证缩窄/变宽后 State（输入内容）不丢
class _AnonEditorPage extends StatefulWidget {
  const _AnonEditorPage();

  @override
  State<_AnonEditorPage> createState() => _AnonEditorPageState();
}

class _AnonEditorPageState extends State<_AnonEditorPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          key: const ValueKey('anon-editor'),
          controller: _controller,
          maxLines: null,
          decoration: const InputDecoration(hintText: '匿名编辑页'),
        ),
      ),
    );
  }
}

/// 右栏 nested 弹层页（360x320 窗格内验证不溢出）
class _SheetStubPage extends StatelessWidget {
  const _SheetStubPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey('open-sheet'),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            builder: (_) =>
                const SizedBox(height: 160, child: Center(child: Text('右栏弹层'))),
          ),
          child: const Text('打开弹层'),
        ),
      ),
    );
  }
}

Route<dynamic> _stubRoute(RouteSettings settings) {
  if (settings.name == '/sheet') {
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => const _SheetStubPage(),
    );
  }
  return MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => _StubPage('stub:${settings.name}'),
  );
}

/// 根导航栈深度计数（用于断言 root push / 容器栈不变）
class _DepthObserver extends NavigatorObserver {
  int depth = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth--;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == null) depth++;
  }
}

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late ProviderContainer container;

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
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
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

  Widget buildPaneApp({
    required GlobalKey<NavigatorState> navigatorKey,
    bool active = true,
    double textScale = 1,
    GlobalKey<NavigatorState>? rootKey,
    NavigatorObserver? rootObserver,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: rootKey,
        navigatorObservers: rootObserver == null ? const [] : [rootObserver],
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
            active: active,
          ),
        ),
      ),
    );
  }

  Future<GlobalKey<NavigatorState>> pumpPane(
    WidgetTester tester, {
    required MultiPaneMode mode,
    required Size size,
    double textScale = 1,
    GlobalKey<NavigatorState>? rootKey,
    NavigatorObserver? rootObserver,
  }) async {
    SharedPreferences.setMockInitialValues({PrefKeys.multiPaneMode: mode.name});
    setWindowSize(tester, size);
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      buildPaneApp(
        navigatorKey: navigatorKey,
        textScale: textScale,
        rootKey: rootKey,
        rootObserver: rootObserver,
      ),
    );
    await tester.pumpAndSettle();
    return navigatorKey;
  }

  testWidgets('双栏：左菜单 + 右空态，入口进右栏，重复点去重，返回清高亮', (tester) async {
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(900, 700),
    );

    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-gap')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('选择左侧项目'), findsOneWidget);

    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();

    // 右栏打开桩页面，左栏菜单仍在（同一 nested Navigator，非 root push）
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
    final listTile = tester.widget<ListTile>(
      find.descendant(
        of: find.widgetWithText(IosListTile, '书源管理'),
        matching: find.byType(ListTile),
      ),
    );
    expect(
      listTile.selectedColor,
      Theme.of(
        tester.element(find.byType(SettingsScreen)),
      ).colorScheme.onSurface,
    );

    // 重复点同一入口：不叠加第二页
    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();
    expect(find.text('stub:/sources'), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isTrue);

    // 返回键先 pop 容器栈（HomeScreen 调用同一 nested Navigator）
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

  testWidgets('单栏（off）：命名入口 root push 全屏，容器栈不变，返回回菜单', (tester) async {
    final rootKey = GlobalKey<NavigatorState>();
    final rootObserver = _DepthObserver();
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.off,
      size: const Size(900, 700),
      rootKey: rootKey,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );

    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(paneState.rightStackDepth, 1);
    expect(rootObserver.depth, 1);

    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();

    // 单栏命名入口走 root push（全屏覆盖容器），容器栈保持初始空态
    expect(find.text('stub:/sources'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsNothing);
    expect(rootKey.currentState!.canPop(), isTrue);
    expect(rootObserver.depth, 2);
    expect(paneState.rightStackDepth, 1);

    rootKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('stub:/sources'), findsNothing);
    expect(rootObserver.depth, 1);
  });

  testWidgets('双→单→双：匿名路由栈顶与输入内容保留，菜单按空栈恢复', (tester) async {
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(900, 700),
    );

    // 匿名 MaterialPageRoute（无 RouteSettings.name），模拟编辑页/表单。
    // push 的 Future 在路由 pop 时才完成，不能 await（否则测试挂起）。
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const _AnonEditorPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('anon-editor')), '草稿内容');
    // 失焦停止光标闪烁，否则后续 pumpAndSettle 会被周期性帧拖住。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);

    // 缩到单栏：左菜单隐藏，匿名页全宽保留，输入不丢
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsNothing);
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsNothing);
    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('anon-editor')))
          .controller!
          .text,
      '草稿内容',
    );
    expect(navigatorKey.currentState!.canPop(), isTrue);

    // 再变宽：左菜单 + 右栏同一匿名页（栈未重建）
    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);
    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('anon-editor')))
          .controller!
          .text,
      '草稿内容',
    );

    // 逐级 pop 回空栈 → 双栏空态
    await navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(_AnonEditorPage), findsNothing);
    expect(find.text('选择左侧项目'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('双→单：命名栈顶转 root push，容器栈清空，返回回菜单', (tester) async {
    final rootKey = GlobalKey<NavigatorState>();
    final rootObserver = _DepthObserver();
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(900, 700),
      rootKey: rootKey,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );

    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();
    expect(find.text('stub:/sources'), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isTrue);
    expect(paneState.rightStackDepth, 2);
    expect(rootObserver.depth, 1);

    // 缩到单栏：命名栈顶转 root push（全屏），容器栈清空
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(find.text('stub:/sources'), findsOneWidget);
    expect(rootKey.currentState!.canPop(), isTrue);
    expect(rootObserver.depth, 2);
    expect(navigatorKey.currentState!.canPop(), isFalse);
    expect(paneState.rightStackDepth, 1);

    rootKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('stub:/sources'), findsNothing);
    expect(rootObserver.depth, 1);
  });

  testWidgets('不可见 Tab 期间形态冻结，重新可见后按新窗口判定', (tester) async {
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.auto,
      size: const Size(900, 700),
    );
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);

    // 不可见 + 缩到 auto 单栏区间：冻结上一次可见的双栏形态
    tester.view.physicalSize = const Size(760, 700);
    await tester.pumpWidget(
      buildPaneApp(navigatorKey: navigatorKey, active: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);

    // 重新可见：按当前窗口（auto <840）落单栏
    await tester.pumpWidget(buildPaneApp(navigatorKey: navigatorKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsNothing);
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
  });

  testWidgets('不可见 Tab 冻结：窄窗放不下双栏时安全回落单栏', (tester) async {
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(900, 700),
    );
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);

    // 不可见 + 窄到双栏最小宽度以下：冻结值不再适用，安全回单栏防溢出
    tester.view.physicalSize = const Size(400, 700);
    await tester.pumpWidget(
      buildPaneApp(navigatorKey: navigatorKey, active: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsNothing);
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 重新可见仍为单栏
    await tester.pumpWidget(buildPaneApp(navigatorKey: navigatorKey));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
  });

  testWidgets('最小双栏 744x320 + 2x 大字体与右栏 360x320 nested 弹层不溢出', (tester) async {
    final navigatorKey = await pumpPane(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(744, 320),
      textScale: 2,
    );

    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);
    expect(find.text('选择左侧项目'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 右栏宽度 360dp、高度 320dp：nested Navigator 内弹层不溢出
    unawaited(navigatorKey.currentState!.pushNamed('/sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();
    expect(find.text('右栏弹层'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右栏 360x320 + 页签减高（56dp）nested 弹层不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.multiPaneMode: MultiPaneMode.always.name,
    });
    setWindowSize(tester, const Size(744, 376));
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          onGenerateRoute: _stubRoute,
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: AdaptiveMyPane(
                    navigatorKey: navigatorKey,
                    routeGenerator: _stubRoute,
                  ),
                ),
                // 模拟底栏页签占用 56dp：窗格实际高度 376-56=320
                const SizedBox(height: 56, child: Center(child: Text('页签栏'))),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-right')), findsOneWidget);

    unawaited(navigatorKey.currentState!.pushNamed('/sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-sheet')));
    await tester.pumpAndSettle();
    expect(find.text('右栏弹层'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口 + 2x 大字体保持单栏且不溢出', (tester) async {
    await pumpPane(
      tester,
      mode: MultiPaneMode.auto,
      size: const Size(700, 600),
      textScale: 2,
    );

    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HomeScreen 返回键：先 pop 容器栈，空栈后切回书架', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.multiPaneMode: MultiPaneMode.always.name,
      // 关闭 Rail，保证 1000dp 窗口仍用底栏切 Tab
      PrefKeys.tabletInterface: 'off',
    });
    setWindowSize(tester, const Size(1000, 700));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: const HomeScreen(),
          onGenerateRoute: AppRoutes.generateRoute,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(NavigationDestination).at(4));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('关于'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    // 容器内打开「关于」，左栏菜单仍在
    expect(find.byType(AboutScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );

    // 第一次返回：pop 容器栈，仍停留在「我的」
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      4,
    );

    // 第二次返回：容器空栈 → 原逻辑切回书架
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
  });

  testWidgets('HomeScreen 单栏命名页：root 全屏无底栏，返回恢复 My', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.multiPaneMode: MultiPaneMode.off.name,
      PrefKeys.tabletInterface: 'off',
    });
    setWindowSize(tester, const Size(900, 700));
    final rootKey = GlobalKey<NavigatorState>();
    final rootObserver = _DepthObserver();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootKey,
          navigatorObservers: [rootObserver],
          home: const HomeScreen(),
          onGenerateRoute: _stubRoute,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(NavigationDestination).at(4));
    await tester.pumpAndSettle();
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.text('书源管理'));
    await tester.pumpAndSettle();

    // 单栏命名入口 root push：全屏覆盖，底栏不可见，容器栈不变
    expect(find.text('stub:/sources'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(rootObserver.depth, 2);
    expect(paneState.rightStackDepth, 1);

    rootKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(rootObserver.depth, 1);
  });

  testWidgets('双→单匿名栈全屏：隐藏底栏/禁横滑，退出恢复 My', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.multiPaneMode: MultiPaneMode.always.name,
      PrefKeys.tabletInterface: 'off',
    });
    setWindowSize(tester, const Size(900, 700));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: const HomeScreen(),
          onGenerateRoute: _stubRoute,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(NavigationDestination).at(4));
    await tester.pumpAndSettle();
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    final nestedNavigator = tester.state<NavigatorState>(
      find.descendant(
        of: find.byKey(const ValueKey('my-pane-right')),
        matching: find.byType(Navigator),
      ),
    );
    unawaited(
      nestedNavigator.push(
        MaterialPageRoute<void>(builder: (_) => const _AnonEditorPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('anon-editor')), '草稿内容');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);

    // 缩到单栏：匿名栈顶保持 nested，但整页全屏（隐藏底栏、禁横滑）
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsNothing);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    expect(paneState.rightStackDepth, 2);
    expect(container.read(myPaneFullscreenProvider), isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('anon-editor')))
          .controller!
          .text,
      '草稿内容',
    );

    // 再变宽：恢复双栏与底栏，匿名页仍在右栏（栈未重建）
    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);
    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(container.read(myPaneFullscreenProvider), isFalse);

    // 再缩窄：重新进入匿名全屏覆盖
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(container.read(myPaneFullscreenProvider), isTrue);

    // 退出匿名栈：恢复底栏/横滑与 My 菜单
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(_AnonEditorPage), findsNothing);
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<ClampingScrollPhysics>(),
    );
    expect(paneState.rightStackDepth, 1);
    expect(container.read(myPaneFullscreenProvider), isFalse);
  });

  testWidgets('HomeScreen + Rail：840dp 双栏、839dp 单栏（阈值含 Rail）', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.multiPaneMode: MultiPaneMode.auto.name,
      PrefKeys.tabletInterface: 'auto',
    });
    setWindowSize(tester, const Size(840, 700));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: const HomeScreen(),
          onGenerateRoute: AppRoutes.generateRoute,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppRailBar), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AppRailBar), matching: find.text('我的')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsOneWidget);
    expect(find.text('选择左侧项目'), findsOneWidget);

    // 839dp：窗口阈值不满足（即使扣 Rail 后窗格仍够宽）→ 单栏
    tester.view.physicalSize = const Size(839, 700);
    await tester.pumpAndSettle();
    expect(find.byType(AppRailBar), findsOneWidget);
    expect(find.byKey(const ValueKey('my-pane-left-menu')), findsNothing);
    expect(find.byKey(const ValueKey('my-pane-menu-overlay')), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
