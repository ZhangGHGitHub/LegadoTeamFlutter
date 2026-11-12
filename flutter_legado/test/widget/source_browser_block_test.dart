// 「拦截书源打开浏览器」行为测试（批39）
//
// 对齐参考版 OtherSettings.blockSourceBrowser：
// - 开启后书源 JS 的 openUrl / showBrowser / startBrowser 一律拦截并提示
//   （[批39 审查回修] 文案中性化统一为「已阻止书源打开浏览器」）；
// - `legado:/yuedu:` 关联导入仍走站内（不受拦截影响；[批39 审查回修]
//   openBrowser/startBrowser 也豁免）；
// - 关闭时保持既有 openUrl 外跳确认链路。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/services/image_action_outcome.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/utils/image_action_replay.dart';

void main() {
  tearDown(() {
    PlatformBridgeService.instance.blockSourceBrowserOverride = null;
    uiSettingsListenable.value = const UiSettingsState();
  });

  PlatformBridgeService bridge() => PlatformBridgeService.instance;

  testWidgets('开启拦截：openUrl 不弹确认、不进浏览器并提示', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = true;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'openUrl',
      'url': 'https://example.com/target',
      'mimeType': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsNothing);
    expect(find.text('已阻止书源打开浏览器'), findsOneWidget);
    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
  });

  testWidgets('开启拦截：openBrowser 不打开内置浏览器并提示', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = true;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'openBrowser',
      'url': 'https://example.com/page',
      'html': '',
    });
    await tester.pumpAndSettle();

    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
    expect(find.text('已阻止书源打开浏览器'), findsOneWidget);
  });

  testWidgets('开启拦截：startBrowser 不外开也不降级内置浏览器', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = true;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'startBrowser',
      'url': 'https://example.com/download',
      'title': '下载',
      'html': '',
    });
    await tester.pumpAndSettle();

    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
    expect(find.text('已阻止书源打开浏览器'), findsOneWidget);
  });

  testWidgets('开启拦截：legado:// 关联导入仍走站内，不提示拦截', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = true;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'openUrl',
      'url': 'legado://import/bookSource',
      'mimeType': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('已阻止书源打开浏览器'), findsNothing);
    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsNothing);
  });

  testWidgets('全局设置镜像开启（无测试覆写）同样拦截', (tester) async {
    final observer = _RouteRecorder();
    // UiSettingsNotifier 启动加载后镜像；此处直接模拟镜像值
    uiSettingsListenable.value = const UiSettingsState(
      blockSourceBrowser: true,
    );
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'openUrl',
      'url': 'https://example.com/target',
      'mimeType': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsNothing);
    expect(find.text('已阻止书源打开浏览器'), findsOneWidget);
  });

  testWidgets('关闭拦截：openUrl 恢复外跳确认链路', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = false;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'openUrl',
      'url': 'https://example.com/target',
      'mimeType': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsOneWidget);
    expect(find.text('已阻止书源打开浏览器'), findsNothing);
  });

  // ─── [批39 审查回修] openBrowser/startBrowser 同样豁免 legado:/yuedu: ────

  testWidgets('开启拦截：openBrowser 的 legado:// 深链仍走站内、不提示拦截', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = true;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'openBrowser',
      'url': 'legado://import/bookSource',
      'html': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('已阻止书源打开浏览器'), findsNothing);
    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
  });

  testWidgets('开启拦截：startBrowser 的 yuedu:// 深链仍走站内、不提示拦截', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = true;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await bridge().dispatchPayload({
      'action': 'startBrowser',
      'url': 'yuedu://import/booksource',
      'title': '导入',
      'html': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('已阻止书源打开浏览器'), findsNothing);
    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
  });

  // ─── 批21-A 回修 P1：图片动作外链复用既有桥接策略 ───

  testWidgets('图片动作 openUrl 回放：开启拦截后不弹确认并提示', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = true;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await replayImageActionSideEffects(const [
      ImageActionSideEffect(
        name: 'openUrl',
        data: {
          'action': 'openUrl',
          'url': 'https://image-action.example.com/target',
        },
      ),
    ], onToast: (message, {required bool isLong}) {});
    await tester.pumpAndSettle();

    expect(find.text('已阻止书源打开浏览器'), findsOneWidget);
    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsNothing);
    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
  });

  testWidgets('图片动作 openUrl 回放：关闭拦截后走外跳二次确认', (tester) async {
    final observer = _RouteRecorder();
    bridge().blockSourceBrowserOverride = false;
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await replayImageActionSideEffects(const [
      ImageActionSideEffect(
        name: 'openUrl',
        data: {
          'action': 'openUrl',
          'url': 'https://image-action.example.com/target',
        },
      ),
    ], onToast: (message, {required bool isLong}) {});
    await tester.pumpAndSettle();

    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsOneWidget);
    expect(find.text('已阻止书源打开浏览器'), findsNothing);
  });
}

/// 测试宿主：与 [PlatformBridgeService.navigatorKey] 同 key 的最小 MaterialApp
Widget _host(NavigatorObserver observer) {
  return ProviderScope(
    child: MaterialApp(
      navigatorKey: PlatformBridgeService.navigatorKey,
      navigatorObservers: [observer],
      onGenerateRoute: (settings) {
        if (settings.name == AppRoutes.browser) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('browser-stub')),
          );
        }
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const Scaffold(body: Text('home-stub')),
        );
      },
    ),
  );
}

class _RouteRecorder extends NavigatorObserver {
  final List<String?> pushedNames = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedNames.add(route.settings.name);
  }
}
