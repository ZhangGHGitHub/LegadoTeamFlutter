// 「我的」页 M1 信息架构回归测试（docs/MY_PAGE_ALIGNMENT_PLAN_20261103.md）
//
// 覆盖用户裁决（2026-11-03）与复核补强：
// 1. Web 服务块置顶：运行中显示可访问地址 + 「复制地址」「在浏览器中打开」；
//    地址取局域网 IPv4（测试注入固定 IP），端口取状态串实际端口；
// 2. 规则组收敛 5 项（书源/替换/TXT/字典/高亮标签规则）；
// 3. 「服务与工具」组保留定时任务/运行定时任务/MCP；
// 4. 移除独立「设置」组，入口并入「其他」组；
// 5. AI 聊天占位页导航（无输入框）；
// 6. 字典规则单入口默认进管理页，旧 AppRoutes.dict 深链保留且查询页页内可达；
// 7. 主题模式不在「我的」，设置→外观→深色端到端生效并持久化；
// 8. 小屏滚动无溢出、返回栈正常；
// 9. 复核 P1：回前台刷新地址、地址解析失败降级、网卡枚举卡死不阻塞开关、
//    网卡/VPN 选择纯函数；P2：复制失败提示、定时任务 scheduler 接线。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/ai_chat_screen.dart';
import 'package:flutter_legado/src/screens/dict_rule_screen.dart';
import 'package:flutter_legado/src/screens/dict_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/services/auto_task_scheduler.dart';
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
    // 定时任务调度器为进程单例：逐用例复位（取消挂起的 Timer/观察者）
    AutoTaskScheduler.instance.debugReset();
    addTearDown(AutoTaskScheduler.instance.debugReset);
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

  /// 模拟 Web 服务运行中（配置镜像 + 状态串）
  void stubWebServiceRunning({String status = 'running on port 1122'}) {
    when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
      final key = inv.positionalArguments.first as String;
      return key == 'webService' ? 'true' : null;
    });
    when(() => mockApi.getServerStatus()).thenAnswer((_) async => status);
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

      // 已合并/移除的入口不再出现（高画布下整页已构建，断言有效）
      expect(find.text('规则管理'), findsNothing);
      expect(find.text('高亮标注'), findsNothing);
      expect(find.text('主题模式'), findsNothing);
      expect(find.text('备份与恢复'), findsNothing);
      expect(find.text('主题设置'), findsNothing);
      expect(find.text('导出日志'), findsNothing);
      expect(find.text('词典规则'), findsNothing);

      // 独立「设置」分组已移除：全文仅一个「设置」入口
      expect(find.text('设置'), findsOneWidget);
    });

    // [M2 我的页 | 2026-11-03] 视觉形态回归：参考版 WebServiceSettingBlock 是
    // 无标题 SplicedColumnGroup 内的 SwitchSettingItem（开关行），不是独立
    // 大卡（旧实现：48dp 图标槽 + 整卡描边 + 整卡 InkWell/MergeSemantics）。
    testWidgets('M2 Web 服务为置顶分组开关行而非独立大卡', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final row = find.widgetWithText(SettingSwitchRow, 'Web 服务');
      expect(row, findsOneWidget, reason: 'Web 服务应为 SettingSwitchRow 开关行');

      // 置顶无标题 IosGroup（对齐参考版 SplicedColumnGroup(title = "")）
      final firstGroup = find.byType(IosGroup).first;
      expect(
        find.descendant(of: firstGroup, matching: row),
        findsOneWidget,
        reason: 'Web 服务开关行应在首个无标题分组内',
      );

      // 裸 24dp 图标（旧大卡为 48dp 图标槽 + 28dp 图标）
      final rowIcon = find.descendant(of: row, matching: find.byType(Icon));
      expect(rowIcon, findsOneWidget);
      expect(
        tester.widget<Icon>(rowIcon).size,
        24,
        reason: '开关行沿用 IosListTile 裸 24dp 图标，无 48dp 图标槽',
      );

      // 开关行整行可点（SettingSwitchRow 语义），开关可操作
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: row, matching: find.byType(Switch)),
            )
            .onChanged,
        isNotNull,
      );
      // 停止态不展开操作行
      expect(find.byKey(const ValueKey('web-service-copy-address')), findsNothing);
      expect(
        find.byKey(const ValueKey('web-service-open-browser')),
        findsNothing,
      );
    });

    testWidgets('M2 运行中操作行贴邻开关行、右对齐且不误触开关', (tester) async {
      stubWebServiceRunning();
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final row = find.widgetWithText(SettingSwitchRow, 'Web 服务');
      final copy = find.byKey(const ValueKey('web-service-copy-address'));
      final open = find.byKey(const ValueKey('web-service-open-browser'));
      expect(copy, findsOneWidget);
      expect(open, findsOneWidget);

      // 操作行在开关行之外：不在开关行的语义/手势区域，不会误触开关
      expect(find.descendant(of: row, matching: copy), findsNothing);
      expect(find.descendant(of: row, matching: open), findsNothing);

      // 贴邻：操作行紧接开关行下方（组外 + 小间距，视觉仍为一体）
      final rowRect = tester.getRect(row);
      final copyRect = tester.getRect(copy);
      expect(
        copyRect.top - rowRect.bottom,
        lessThanOrEqualTo(12),
        reason: '操作行应紧贴开关行下方',
      );
      // 右对齐：末个按钮右缘与开关行右缘相差 16dp 内边距
      expect(
        tester.getRect(open).right,
        closeTo(rowRect.right - 16, 1.0),
        reason: '操作行右对齐（参考版 Row Arrangement.End）',
      );

      // 点「复制地址」不得切换开关/停服
      await tester.tap(copy);
      await tester.pump();
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: row, matching: find.byType(Switch)),
            )
            .value,
        isTrue,
        reason: '复制地址不改变开关状态',
      );
      verifyNever(() => mockApi.setConfig('webService', 'false'));
      verifyNever(() => mockApi.stopServer());

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Web 服务运行中：地址取状态串端口 + 复制地址', (tester) async {
      SharedPreferences.setMockInitialValues({'webPort': 9999});
      stubWebServiceRunning(status: 'running on port 8080');

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
      // 复制纯 UI 操作：不得启停服务
      verifyNever(() => mockApi.startServer(port: any(named: 'port')));
      verifyNever(() => mockApi.stopServer());

      // 收起 SnackBar，防跨用例计时器
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Web 服务运行中：在浏览器中打开（url_launcher 外部打开）', (tester) async {
      stubWebServiceRunning();

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('在浏览器中打开'));
      await tester.pumpAndSettle();

      expect(launcher.launched, ['http://192.168.1.20:1122']);
      expect(find.text('无法打开浏览器'), findsNothing);
      // 打开纯 UI 操作：不得启停服务
      verifyNever(() => mockApi.startServer(port: any(named: 'port')));
      verifyNever(() => mockApi.stopServer());
    });

    testWidgets('Web 服务运行中：复制失败给 SnackBar 提示', (tester) async {
      stubWebServiceRunning();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'clipboard', message: '剪贴板不可用');
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('复制地址'));
      await tester.pump();

      expect(find.textContaining('复制地址失败'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Web 服务运行中：打开失败给 SnackBar 提示', (tester) async {
      launcher = _FakeUrlLauncherPlatform(result: false);
      UrlLauncherPlatform.instance = launcher;
      stubWebServiceRunning();

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('在浏览器中打开'));
      await tester.pump();

      expect(find.text('无法打开浏览器'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Web 服务运行中：回环地址标注「（本机）」且复制不含标注', (tester) async {
      addressResolver.host = '127.0.0.1';
      stubWebServiceRunning();
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

      expect(find.text('http://127.0.0.1:1122（本机）'), findsOneWidget);

      await tester.tap(find.text('复制地址'));
      await tester.pump();
      expect(clipboardText, 'http://127.0.0.1:1122');

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
      stubWebServiceRunning();

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // [M2] 开关行（SettingSwitchRow）取代原大卡
      final row = find.widgetWithText(SettingSwitchRow, 'Web 服务');
      expect(row, findsOneWidget);
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: row, matching: find.byType(Switch)),
            )
            .value,
        isTrue,
        reason: '地址解析失败不影响开关状态',
      );
      expect(find.text('复制地址'), findsNothing);
      expect(find.text('在浏览器中打开'), findsNothing);
    });

    testWidgets('回到前台：running 刷新地址（新 IP 展示并可复制），stopped 清空', (tester) async {
      stubWebServiceRunning();
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
      expect(find.text('http://192.168.1.20:1122'), findsOneWidget);

      // 后台期间网卡/IP 变化 → 回前台重新解析
      addressResolver.host = '192.168.1.99';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('http://192.168.1.99:1122'), findsOneWidget);
      expect(find.text('http://192.168.1.20:1122'), findsNothing);

      await tester.tap(find.text('复制地址'));
      await tester.pump();
      expect(clipboardText, 'http://192.168.1.99:1122');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // 服务在后台被停止 → 回前台清空状态/地址与操作按钮
      when(() => mockApi.getServerStatus()).thenAnswer((_) async => 'stopped');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.textContaining('192.168.1.99'), findsNothing);
      expect(find.text('复制地址'), findsNothing);
      expect(find.text('在浏览器中打开'), findsNothing);
    });

    testWidgets('Web 服务启动：网卡枚举永不完成也不阻塞开关/不残留 spinner', (tester) async {
      var serverStatus = 'stopped';
      when(
        () => mockApi.getServerStatus(),
      ).thenAnswer((_) async => serverStatus);
      when(() => mockApi.startServer(port: any(named: 'port'))).thenAnswer((
        _,
      ) async {
        serverStatus = 'running on port 1122';
      });
      container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(mockApi),
          webServiceAddressResolverProvider.overrideWithValue(
            NeverCompletingWebServiceAddressResolver(),
          ),
        ],
      );
      addTearDown(container.dispose);

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final row = find.widgetWithText(SettingSwitchRow, 'Web 服务');
      expect(row, findsOneWidget);
      final switchFinder = find.descendant(
        of: row,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(
        tester.widget<Switch>(switchFinder).value,
        isTrue,
        reason: '地址解析挂起不得影响开关落定',
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
        reason: '启动成功后 busy spinner 应收起',
      );
      expect(find.text('running on port 1122'), findsOneWidget);
      verify(() => mockApi.setConfig('webService', 'true')).called(1);
    });

    testWidgets('AI 聊天入口打开占位页（无输入框）并可返回（返回栈）', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(
        wrap(routes: {AppRoutes.aiChat: (_) => const AiChatScreen()}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('AI 聊天'));
      await tester.pumpAndSettle();

      expect(find.text('AI 聊天暂未支持'), findsOneWidget);
      expect(find.text('待 Rust 能力接入后开放'), findsOneWidget);
      expect(
        find.byType(TextField),
        findsNothing,
        reason: '占位页不得提供可用输入框，避免误以为已接 LLM',
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Web 服务'), findsOneWidget);
    });

    testWidgets('字典规则单入口默认进管理页（旧 dict 查询路由保留）', (tester) async {
      // 旧查询路由经 generateRoute 仍可构建（深链兼容）
      late BuildContext probeContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              probeContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final dictRoute = AppRoutes.generateRoute(
        const RouteSettings(name: AppRoutes.dict),
      );
      expect(dictRoute, isA<MaterialPageRoute<dynamic>>());
      final dictBuilder = (dictRoute as MaterialPageRoute<dynamic>).builder;
      expect(dictBuilder(probeContext), isA<DictScreen>());
      expect(
        AppRoutes.generateRoute(const RouteSettings(name: AppRoutes.dictRule)),
        isA<MaterialPageRoute<dynamic>>(),
      );

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

    testWidgets('运行定时任务：写入 autoTaskService 并触发 scheduler refresh', (
      tester,
    ) async {
      var autoTaskEnabled = false;
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments.first as String;
        return switch (key) {
          'autoTaskService' => autoTaskEnabled ? 'true' : 'false',
          _ => null,
        };
      });
      when(() => mockApi.setConfig('autoTaskService', any())).thenAnswer((
        inv,
      ) async {
        autoTaskEnabled = inv.positionalArguments[1] == 'true';
      });
      when(() => mockApi.autoTaskListRules()).thenAnswer((_) async => []);
      AutoTaskScheduler.instance.attach(mockApi);
      await tester.pump();

      useTallViewport(tester);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final row = find
          .ancestor(of: find.text('运行定时任务'), matching: find.byType(IosListTile))
          .first;
      final switchFinder = find.descendant(
        of: row,
        matching: find.byType(Switch),
      );

      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      verify(() => mockApi.setConfig('autoTaskService', 'true')).called(1);
      verify(
        () => mockApi.autoTaskListRules(),
      ).called(1); // 开关开启触发 scheduler.refresh

      tester.widget<Switch>(switchFinder).onChanged!(false);
      await tester.pumpAndSettle();

      verify(() => mockApi.setConfig('autoTaskService', 'false')).called(1);
      verifyNever(() => mockApi.startServer(port: any(named: 'port')));
    });

    testWidgets('主题模式不在「我的」，设置→外观→深色端到端生效并持久化', (tester) async {
      final recorder = _RouteRecorder();
      await tester.pumpWidget(
        wrap(
          routes: {
            AppRoutes.settingsHome: (_) => const SettingsHomeScreen(),
            AppRoutes.themeConfig: (_) => const ThemeConfigScreen(),
          },
          observer: recorder,
        ),
      );
      await tester.pumpAndSettle();

      // 我的页无主题模式入口
      expect(find.text('主题模式'), findsNothing);

      await dragTo(tester, '设置');
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(recorder.pushed, contains(AppRoutes.settingsHome));

      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      expect(recorder.pushed, contains(AppRoutes.themeConfig));

      expect(container.read(themeNotifierProvider).themeMode, ThemeMode.system);
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();

      expect(container.read(themeNotifierProvider).themeMode, ThemeMode.dark);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_theme_mode'), 'dark');
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

    testWidgets('运行态小屏（360x640）地址/操作按钮不溢出', (tester) async {
      stubWebServiceRunning();
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('http://192.168.1.20:1122'), findsOneWidget);
      expect(find.text('复制地址'), findsOneWidget);
      expect(find.text('在浏览器中打开'), findsOneWidget);
      expect(tester.takeException(), isNull);

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

    test('selectHost：过滤 tun，优先 wlan（172.20 胜 10.8）', () {
      expect(
        LanWebServiceAddressResolver.selectHost(const [
          NetworkAddressEntry(interfaceName: 'tun0', address: '10.8.0.2'),
          NetworkAddressEntry(interfaceName: 'wlan0', address: '172.20.10.2'),
        ]),
        '172.20.10.2',
      );
    });

    test('selectHost：过滤 vEthernet/Hyper-V 等虚拟网卡', () {
      expect(
        LanWebServiceAddressResolver.selectHost(const [
          NetworkAddressEntry(
            interfaceName: 'vEthernet (Default Switch)',
            address: '172.20.0.1',
          ),
          NetworkAddressEntry(interfaceName: 'docker0', address: '172.17.0.1'),
          NetworkAddressEntry(interfaceName: 'en0', address: '10.0.0.8'),
        ]),
        '10.0.0.8',
      );
    });

    test('selectHost：多 192.168 按网卡名/IP 数值确定性 tie-break', () {
      expect(
        LanWebServiceAddressResolver.selectHost(const [
          NetworkAddressEntry(interfaceName: 'eth0', address: '192.168.1.9'),
          NetworkAddressEntry(interfaceName: 'eth0', address: '192.168.1.5'),
        ]),
        '192.168.1.5',
      );
      expect(
        LanWebServiceAddressResolver.selectHost(const [
          NetworkAddressEntry(interfaceName: 'eth1', address: '192.168.1.5'),
          NetworkAddressEntry(interfaceName: 'eth0', address: '192.168.1.9'),
        ]),
        '192.168.1.9',
        reason: '同名优先后按网卡名升序：eth0 早于 eth1',
      );
      expect(
        LanWebServiceAddressResolver.selectHost(const [
          NetworkAddressEntry(interfaceName: 'wlan0', address: '192.168.1.9'),
          NetworkAddressEntry(interfaceName: 'eth0', address: '192.168.1.5'),
        ]),
        '192.168.1.9',
        reason: 'wlan 优先于私网排序',
      );
    });

    test('selectHost：仅虚拟网卡/空列表回落回环', () {
      expect(LanWebServiceAddressResolver.selectHost(const []), '127.0.0.1');
      expect(
        LanWebServiceAddressResolver.selectHost(const [
          NetworkAddressEntry(interfaceName: 'tun0', address: '10.8.0.2'),
          NetworkAddressEntry(interfaceName: 'vmnet8', address: '192.168.56.1'),
        ]),
        '127.0.0.1',
      );
    });

    test('可注入枚举 seam：resolve 走 selectHost 并拼接端口', () async {
      final resolver = LanWebServiceAddressResolver(
        enumerate: () async => const [
          NetworkAddressEntry(interfaceName: 'veth0', address: '10.8.0.2'),
          NetworkAddressEntry(interfaceName: 'wlan0', address: '192.168.1.7'),
        ],
      );
      expect(await resolver.resolve(1122), 'http://192.168.1.7:1122');
      expect(await resolver.resolveHost(), '192.168.1.7');
    });

    test('真实网卡枚举：返回合法 IPv4（无候选时为回环）', () async {
      final host = await const LanWebServiceAddressResolver().resolveHost();
      final parsed = InternetAddress.tryParse(host);
      expect(parsed, isNotNull);
      expect(parsed!.type, InternetAddressType.IPv4);
    });
  });
}
