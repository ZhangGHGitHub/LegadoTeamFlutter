import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';

/// P2-15 openUrl 外跳确认统一 —— 桥接层 widget 测试
///
/// 覆盖：
/// 1. openUrl(http) → 先弹确认框；取消不进浏览器；
/// 2. openUrl(http) → 确认后进应用内浏览器（AppRoutes.browser）；
/// 3. openUrl(自定义协议) → 确认后走系统打开（测试环境无 launchUrl 实现 →
///    归一为「无法打开」SnackBar，证明已进入打开分支）；
/// 4. legado:// 关联导入不经确认（对齐原版 openUrl 直进 OnLineImportActivity）。
void main() {
  testWidgets('openUrl http：确认框弹出，取消不导航', (tester) async {
    final observer = _RouteRecorder();
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await PlatformBridgeService.instance.dispatchPayload({
      'action': 'openUrl',
      'url': 'https://example.com/target',
      'mimeType': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsOneWidget);
    expect(find.text('https://example.com/target'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    // 初始 home 路由外无任何导航（浏览器未打开）
    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
  });

  testWidgets('openUrl http：确认后进内置浏览器', (tester) async {
    final observer = _RouteRecorder();
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await PlatformBridgeService.instance.dispatchPayload({
      'action': 'openUrl',
      'url': 'https://example.com/target',
      'mimeType': '',
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(observer.pushedNames, contains(AppRoutes.browser));
  });

  testWidgets('openUrl 自定义协议：确认后走系统打开分支', (tester) async {
    final observer = _RouteRecorder();
    // url_launcher 默认实例走 plugins.flutter.io/url_launcher 旧通道；
    // mock 返回 false → 归一为「无法打开」SnackBar（证明确认后已进入
    // 系统打开分支，未进内置浏览器）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async => call.method == 'launch' ? false : null,
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      );
    });
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await PlatformBridgeService.instance.dispatchPayload({
      'action': 'openUrl',
      'url': 'cloudgame://play/123',
      'mimeType': '',
    });
    await tester.pumpAndSettle();
    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsOneWidget);

    await tester.tap(find.text('跳转'));
    await tester.pumpAndSettle();
    expect(observer.pushedNames, isNot(contains(AppRoutes.browser)));
    expect(find.text('无法打开：cloudgame://play/123'), findsOneWidget);
  });

  testWidgets('openUrl legado://：直进关联导入，不经确认', (tester) async {
    final observer = _RouteRecorder();
    await tester.pumpWidget(_host(observer));
    await tester.pumpAndSettle();

    await PlatformBridgeService.instance.dispatchPayload({
      'action': 'openUrl',
      'url': 'legado://import/bookSource',
      'mimeType': '',
    });
    await tester.pumpAndSettle();

    expect(find.text('正在请求跳转链接/应用，是否跳转？'), findsNothing);
  });
}

/// 测试宿主：与 [PlatformBridgeService.navigatorKey] 同 key 的最小 MaterialApp
///（browser 路由用占位屏替换，避免 WebView 平台依赖；ProviderScope 供
/// legado:// 关联导入弹窗消费）
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
