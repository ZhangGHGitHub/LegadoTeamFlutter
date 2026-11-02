// 「我的」页 M1 信息架构回归测试（docs/MY_PAGE_ALIGNMENT_PLAN_20261103.md）
//
// 覆盖用户裁决（2026-11-03）：
// 1. Web 服务块置顶：运行中显示可访问地址 + 「复制地址」「在浏览器中打开」；
//    地址取局域网 IPv4（测试注入固定 IP），端口取状态串实际端口；
// 2. 规则组收敛 5 项（书源/替换/TXT/字典/高亮标签规则）；
// 3. 「服务与工具」组保留定时任务/运行定时任务/MCP；
// 4. 移除独立「设置」组，入口并入「其他」组；
// 5. AI 聊天占位页导航；
// 6. 字典规则单入口默认进管理页，旧 AppRoutes.dict 深链保留且查询页页内可达；
// 7. 主题模式不在「我的」，设置→外观仍可达；
// 8. 小屏滚动无溢出、返回栈正常。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
// url_launcher_platform_interface 是 url_launcher 的传递依赖，
// 测试仅用它注入最小平台假实现（不改 pubspec）。
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/ai_chat_screen.dart';
import 'package:flutter_legado/src/screens/dict_rule_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/services/web_service_address_resolver.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

import '../mocks/fake_web_service_address_resolver.dart';
import '../mocks/mocks.dart';

/// 记录命名路由 push（断言入口落点/返回栈）
class _RouteRecorder extends NavigatorObserver {
  final List<String?> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
    super.didPush(route, previousRoute);
  }
}

/// 最小 UrlLauncherPlatform 假实现：记录系统外开调用
class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  _FakeUrlLauncherPlatform({this.result = true});

  final bool result;
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return result;
  }
}

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;
  late FakeWebServiceAddressResolver addressResolver;
  late _FakeUrlLauncherPlatform launcher;
  late UrlLauncherPlatform originalLauncher;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    addressResolver = FakeWebServiceAddressResolver();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        // FakeAsync 下真实 NetworkInterface 枚举不完成 → 注入固定局域网 IP
        webServiceAddressResolverProvider.overrideWithValue(addressResolver),
      ],
    );
    addTearDown(container.dispose);
    originalLauncher = UrlLauncherPlatform.instance;
    launcher = _FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = launcher;
    // 未列出的 config 键按 null（未配置）；服务默认停止
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.getServerStatus()).thenAnswer((_) async => 'stopped');
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalLauncher;
  });

  Widget wrap({
    Widget? home,
    Map<String, WidgetBuilder>? routes,
    NavigatorObserver? observer,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: home ?? const SettingsScreen(),
        routes: routes ?? const {},
        navigatorObservers: observer == null ? const [] : [observer],
      ),
    );
  }

  /// 高画布（800x4200 @1.0）：整页入口一次性构建，便于断言纵向顺序
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> dragTo(WidgetTester tester, String text) async {
    await tester.dragUntilVisible(
      find.text(text),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
  }

  group('M1 我的页信息架构', () {
    testWidgets('分组与条目顺序快照（Web 服务 → 规则 → 服务与工具 → 其他）', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      const orderedLabels = [
        'Web 服务',
        '规则',
        '书源管理',
        '替换净化',
        'TXT 目录规则',
        '字典规则',
        '高亮标签规则',
        '服务与工具',
        '定时任务',
        '运行定时任务',
        'MCP 服务',
        '其他',
        'AI 聊天',
        '设置',
        '书签',
        '阅读记录',
        '缓存管理',
        '文件管理',
        '关于',
        '退出',
      ];
      final positions = <double>[];
      for (final label in orderedLabels) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '应存在条目「$label」');
        positions.add(tester.getTopLeft(finder).dy);
      }
      for (var i = 1; i < positions.length; i++) {
        expect(
          positions[i] > positions[i - 1],
          isTrue,
          reason: '「${orderedLabels[i]}」应位于「${orderedLabels[i - 1]}」之后',
        );
      }

      // 已合并/移除的入口不再出现
      expect(find.text('规则管理'), findsNothing);
      expect(find.text('高亮标注'), findsNothing);
      expect(find.text('主题模式'), findsNothing);

      // 独立「设置」分组已移除：全文仅一个「设置」入口
      expect(find.text('设置'), findsOneWidget);
    });

    testWidgets('Web 服务运行中：地址取状态串端口 + 复制地址', (tester) async {
      SharedPreferences.setMockInitialValues({'webPort': 9999});
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments.first as String;
        return key == 'webService' ? 'true' : null;
      });
      when(
        () => mockApi.getServerStatus(),
      ).thenAnswer((_) async => 'running on port 8080');

      String? clipboardText;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // 地址 = 局域网 IPv4 + Rust 实际绑定端口（8080），而非配置端口 9999
      expect(find.text('http://192.168.1.20:8080'), findsOneWidget);
      expect(addressResolver.resolvedPorts, contains(8080));
      expect(addressResolver.resolvedPorts, isNot(contains(9999)));

      await tester.tap(find.text('复制地址'));
      await tester.pump();

      expect(clipboardText, 'http://192.168.1.20:8080');
      expect(find.text('已复制访问地址'), findsOneWidget);

      // 收起 SnackBar，防跨用例计时器
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Web 服务运行中：在浏览器中打开（url_launcher 外部打开）', (tester) async {
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments.first as String;
        return key == 'webService' ? 'true' : null;
      });
      when(
        () => mockApi.getServerStatus(),
      ).thenAnswer((_) async => 'running on port 1122');

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('在浏览器中打开'));
      await tester.pumpAndSettle();

      expect(launcher.launched, ['http://192.168.1.20:1122']);
      expect(find.text('无法打开浏览器'), findsNothing);
    });

    testWidgets('Web 服务运行中：打开失败给 SnackBar 提示', (tester) async {
      launcher = _FakeUrlLauncherPlatform(result: false);
      UrlLauncherPlatform.instance = launcher;
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments.first as String;
        return key == 'webService' ? 'true' : null;
      });
      when(
        () => mockApi.getServerStatus(),
      ).thenAnswer((_) async => 'running on port 1122');

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('在浏览器中打开'));
      await tester.pump();

      expect(find.text('无法打开浏览器'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Web 服务停止：不显示地址与操作按钮', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('用浏览器写源或看书'), findsOneWidget);
      expect(find.text('复制地址'), findsNothing);
      expect(find.text('在浏览器中打开'), findsNothing);
      expect(addressResolver.resolvedPorts, isEmpty);
    });

    testWidgets('地址解析失败：保留开关并隐藏复制/打开', (tester) async {
      addressResolver = FakeWebServiceAddressResolver(throwOnResolve: true);
      container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(mockApi),
          webServiceAddressResolverProvider.overrideWithValue(addressResolver),
        ],
      );
      addTearDown(container.dispose);
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments.first as String;
        return key == 'webService' ? 'true' : null;
      });
      when(
        () => mockApi.getServerStatus(),
      ).thenAnswer((_) async => 'running on port 1122');

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: card, matching: find.byType(Switch)),
            )
            .value,
        isTrue,
        reason: '地址解析失败不影响开关状态',
      );
      expect(find.text('复制地址'), findsNothing);
      expect(find.text('在浏览器中打开'), findsNothing);
    });

    testWidgets('AI 聊天入口打开占位页并可返回（返回栈）', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(
        wrap(routes: {AppRoutes.aiChat: (_) => const AiChatScreen()}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('AI 聊天'));
      await tester.pumpAndSettle();

      expect(find.text('AI 聊天暂未支持'), findsOneWidget);
      expect(find.text('待 Rust 能力接入后开放'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Web 服务'), findsOneWidget);
    });

    testWidgets('字典规则单入口默认进管理页（旧 dict 查询路由保留）', (tester) async {
      // 旧查询路由仍注册（深链兼容）
      expect(AppRoutes.routes.containsKey(AppRoutes.dict), isTrue);
      expect(AppRoutes.routes.containsKey(AppRoutes.dictRule), isTrue);

      final recorder = _RouteRecorder();
      useTallViewport(tester);
      await tester.pumpWidget(
        wrap(
          routes: {
            AppRoutes.dictRule: (_) => const Scaffold(body: Text('字典规则管理页')),
            AppRoutes.dict: (_) => const Scaffold(body: Text('字典查询页')),
          },
          observer: recorder,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('字典规则'));
      await tester.pumpAndSettle();

      expect(recorder.pushed, contains(AppRoutes.dictRule));
      expect(find.text('字典规则管理页'), findsOneWidget);
    });

    testWidgets('字典规则管理页「字典查询」入口可达查询页', (tester) async {
      when(() => mockApi.dictRuleList()).thenAnswer((_) async => []);
      final recorder = _RouteRecorder();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: const DictRuleScreen(),
            routes: {AppRoutes.dict: (_) => const Scaffold(body: Text('查询页'))},
            navigatorObservers: [recorder],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('字典查询'));
      await tester.pumpAndSettle();

      expect(recorder.pushed, contains(AppRoutes.dict));
      expect(find.text('查询页'), findsOneWidget);
    });

    testWidgets('服务与工具可达：定时任务入口 + MCP 开关', (tester) async {
      when(() => mockApi.setMcpPort(any())).thenAnswer((_) async {});
      final recorder = _RouteRecorder();
      useTallViewport(tester);
      await tester.pumpWidget(
        wrap(
          routes: {
            AppRoutes.autoTasks: (_) => const Scaffold(body: Text('定时任务页')),
          },
          observer: recorder,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('定时任务'));
      await tester.pumpAndSettle();
      expect(recorder.pushed, contains(AppRoutes.autoTasks));
      expect(find.text('定时任务页'), findsOneWidget);

      // 测试用路由为无 AppBar 的简单页，直接 pop 回「我的」
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      final mcpRow = find
          .ancestor(of: find.text('MCP 服务'), matching: find.byType(IosListTile))
          .first;
      tester
          .widget<Switch>(
            find.descendant(of: mcpRow, matching: find.byType(Switch)),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();

      verify(() => mockApi.setMcpPort(1236)).called(1);
    });

    testWidgets('主题模式不在「我的」，设置→外观入口仍可用', (tester) async {
      final recorder = _RouteRecorder();
      await tester.pumpWidget(
        wrap(
          home: const SettingsHomeScreen(),
          routes: {
            AppRoutes.themeConfig: (_) => const Scaffold(body: Text('外观设置页')),
          },
          observer: recorder,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('外观'), findsOneWidget);
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      expect(recorder.pushed, contains(AppRoutes.themeConfig));
      expect(find.text('外观设置页'), findsOneWidget);
    });

    testWidgets('小屏（360x640）滚动到底无布局溢出', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // 从顶部 Web 服务块滚到「退出」
      await dragTo(tester, '退出');

      expect(find.text('退出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('WebServiceAddressResolver 单元', () {
    test('parsePort 从 running 状态串取端口；非运行态/异常返回 null', () {
      expect(
        LanWebServiceAddressResolver.parsePort('running on port 1122'),
        1122,
      );
      expect(
        LanWebServiceAddressResolver.parsePort('Running On Port 8080'),
        8080,
      );
      expect(LanWebServiceAddressResolver.parsePort('stopped'), isNull);
      expect(LanWebServiceAddressResolver.parsePort('running'), isNull);
      expect(
        LanWebServiceAddressResolver.parsePort('running on port 99999'),
        isNull,
      );
    });

    test('format 拼接 http 地址', () {
      expect(
        LanWebServiceAddressResolver.format('192.168.1.20', 1122),
        'http://192.168.1.20:1122',
      );
      expect(
        LanWebServiceAddressResolver.format(
          LanWebServiceAddressResolver.loopbackHost,
          8080,
        ),
        'http://127.0.0.1:8080',
      );
    });
  });
}
