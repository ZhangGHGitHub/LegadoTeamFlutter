// [批9b-6c | Web 服务前台服务] 设置页接线回归
//
// 语义基准：原版 `WebService.kt:50-57,101-169,254-295`（参考版同构）——
// Web 服务启动成功即前台服务运行，停止即撤前台。9b-6 设备验收确认唤醒锁
// 无法改变息屏后的 `APP_BACKGROUND` 网络策略，前台服务是 LAN 可达的等价物。
//
// 覆盖：
// 1. startServer 成功 → 权限确认 + 前台服务 start + 启动后确认；
//    stopServer 成功 → stop；
// 2. 启动后状态异常（查询失败 / 假成功）→ 回滚 stop + best-effort 停 server；
// 3. 设置页初始化 running → ensureStarted 幂等（已运行不重复 start）；
// 4. 前台服务启动失败不阻断 Web 服务开关（静默降级）；
// 5. 与唤醒锁解耦：偏好 `webServiceWakeLock=false` 仍启动前台服务；
// 6. 停服报错但状态已停 → 仍撤前台服务并关闭开关；
// 7. 通知权限拒绝 → FGS 照常运行、UI 提示「通知不可见」；
// 8. 回到前台对账 → FGS 被系统停止时重新拉起（审查回修 P3）。
//
// 平台标志经 WebServiceForegroundService.platformIsAndroid /
// WebServiceWakeLockService.platformIsAndroid 测试缝隙注入（Windows 测试
// 环境 Platform.isAndroid=false，不注入则全部 no-op）；启动确认延时置零。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/services/web_keep_alive_service.dart';
import 'package:flutter_legado/src/services/web_service_foreground_service.dart';
import 'package:flutter_legado/src/services/web_service_wake_lock_service.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

import '../mocks/fake_web_service_address_resolver.dart';
import '../mocks/mocks.dart';

/// 模拟原生前台服务（含通知权限），记录方法调用顺序
class _ForegroundMock {
  _ForegroundMock({this.running = false});

  bool running;
  bool notificationGranted = true;
  bool requestGranted = true;
  final List<String> calls = <String>[];

  void install(TestDefaultBinaryMessenger messenger) {
    messenger.setMockMethodCallHandler(WebServiceForegroundService.channel, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'start':
          running = true;
          return true;
        case 'stop':
          running = false;
          return true;
        case 'isRunning':
          return running;
        case 'hasNotificationPermission':
          return notificationGranted;
        case 'requestNotificationPermission':
          notificationGranted = requestGranted;
          return notificationGranted;
        default:
          return null;
      }
    });
  }
}

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;
  late TestDefaultBinaryMessenger messenger;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        // [M1] 初始化/启动路径会解析 Web 服务地址；FakeAsync 下真实网卡枚举
        // 不完成，注入固定 IP（否则 _initServiceStates 挂在地址解析上）
        webServiceAddressResolverProvider.overrideWithValue(
          FakeWebServiceAddressResolver(),
        ),
      ],
    );
    addTearDown(container.dispose);
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    WebKeepAliveService.instance.debugReset();
    WebServiceForegroundService.instance.debugReset();
    WebServiceForegroundService.platformIsAndroid = () => true;
    WebServiceForegroundService.startConfirmDelay = Duration.zero;
    WebServiceWakeLockService.instance.debugReset();
    WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
  });

  tearDown(() {
    WebServiceForegroundService.platformIsAndroid = () => Platform.isAndroid;
    WebServiceForegroundService.startConfirmDelay = const Duration(
      milliseconds: 200,
    );
    WebServiceForegroundService.instance.debugReset();
    messenger.setMockMethodCallHandler(
      WebServiceForegroundService.channel,
      null,
    );
    WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
    WebServiceWakeLockService.instance.debugReset();
    messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, null);
    WebKeepAliveService.instance.debugReset();
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    );
  }

  Future<void> dragTo(WidgetTester tester, String text) {
    return tester.dragUntilVisible(
      find.text(text),
      find.byType(ListView),
      const Offset(0, -100),
    );
  }

  /// 直接触发 SwitchRow 的 onChanged（NestedScrollView 下 tap 易被折叠头遮挡）
  void toggleWebService(WidgetTester tester, bool value) {
    final row = find.widgetWithText(SettingSwitchRow, 'Web 服务');
    expect(row, findsOneWidget);
    final switchFinder = find.descendant(
      of: row,
      matching: find.byType(Switch),
    );
    tester.widget<Switch>(switchFinder).onChanged!(value);
  }

  bool webServiceSwitchValue(WidgetTester tester) {
    final row = find.widgetWithText(SettingSwitchRow, 'Web 服务');
    return tester
        .widget<Switch>(
          find.descendant(of: row, matching: find.byType(Switch)),
        )
        .value;
  }

  void stubServer({
    required List<String> statuses,
    bool stopThrows = false,
    String? webServiceConfig,
  }) {
    when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
      final key = inv.positionalArguments.first as String;
      return key == 'webService' ? webServiceConfig : null;
    });
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(
      () => mockApi.startServer(port: any(named: 'port')),
    ).thenAnswer((_) async {});
    if (stopThrows) {
      when(
        () => mockApi.stopServer(),
      ).thenAnswer((_) async => throw const BridgeError(message: '停止超时'));
    } else {
      when(() => mockApi.stopServer()).thenAnswer((_) async {});
    }
    var index = 0;
    when(() => mockApi.getServerStatus()).thenAnswer((_) async {
      final i = index < statuses.length - 1 ? index++ : statuses.length - 1;
      return statuses[i];
    });
  }

  Future<void> settleSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  testWidgets('startServer 成功 → 权限确认 + 前台服务 start；停止 → stop', (tester) async {
    final foreground = _ForegroundMock();
    foreground.install(messenger);
    stubServer(statuses: ['stopped', 'running on port 1122']);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    // 初始化对账（服务未运行）会撤一次遗留前台服务，先清掉
    foreground.calls.clear();

    toggleWebService(tester, true);
    await tester.pumpAndSettle();
    expect(foreground.calls, [
      'hasNotificationPermission',
      'start',
      'isRunning',
    ], reason: '开启时先确认通知权限，再启动 FGS 并短延时确认');

    toggleWebService(tester, false);
    await tester.pumpAndSettle();
    expect(foreground.calls, [
      'hasNotificationPermission',
      'start',
      'isRunning',
      'stop',
    ], reason: 'stopServer 成功后应停止前台服务');
  });

  testWidgets('通知权限 pending 时 server 尚未启动；完成后才启动 server/FGS', (tester) async {
    final foreground = _ForegroundMock();
    final permissionCompleter = Completer<bool>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(WebServiceForegroundService.channel, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasNotificationPermission':
          return false;
        case 'requestNotificationPermission':
          // 模拟权限对话框未关闭：Dart 侧必须停在 await，不得先启 server
          return permissionCompleter.future;
        case 'start':
          foreground.running = true;
          return true;
        case 'isRunning':
          return foreground.running;
        case 'stop':
          foreground.running = false;
          return true;
        default:
          return null;
      }
    });
    stubServer(statuses: ['stopped', 'running on port 1122']);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    calls.clear();

    toggleWebService(tester, true);
    await tester.pump();
    await tester.pump();

    expect(calls, [
      'hasNotificationPermission',
      'requestNotificationPermission',
    ]);
    verifyNever(() => mockApi.startServer(port: any(named: 'port')));
    expect(foreground.running, isFalse, reason: '权限未决时不得启动 FGS');
    // 开关处于 busy（Switch 被进度圈替换），此处不读开关值，仅验证无启动副作用

    // 用户拒绝权限：仍继续启动 server 与 FGS（仅通知不可见）
    permissionCompleter.complete(false);
    await tester.pumpAndSettle();

    verify(() => mockApi.startServer(port: any(named: 'port'))).called(1);
    expect(calls, [
      'hasNotificationPermission',
      'requestNotificationPermission',
      'start',
      'isRunning',
    ]);
    expect(foreground.running, isTrue);
    expect(webServiceSwitchValue(tester), isTrue);
    expect(find.textContaining('通知权限未授予，前台通知不可见'), findsOneWidget);

    await settleSnackBar(tester);
  });

  testWidgets('启动后状态查询失败 → 回滚 stop + best-effort 停 server', (tester) async {
    final foreground = _ForegroundMock();
    foreground.install(messenger);
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(
      () => mockApi.startServer(port: any(named: 'port')),
    ).thenAnswer((_) async {});
    when(() => mockApi.stopServer()).thenAnswer((_) async {});
    var statusCall = 0;
    when(() => mockApi.getServerStatus()).thenAnswer((_) async {
      statusCall++;
      // 初始化对账：stopped；启动后状态查询：抛错（服务状态未知）
      if (statusCall == 1) return 'stopped';
      throw const BridgeError(message: '查询失败');
    });

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    foreground.calls.clear();

    toggleWebService(tester, true);
    await tester.pumpAndSettle();

    expect(foreground.calls, [
      'hasNotificationPermission',
      'start',
      'isRunning',
      'stop',
    ], reason: '状态未知时回滚前台服务');
    expect(find.textContaining('无法确认服务状态'), findsOneWidget);
    expect(webServiceSwitchValue(tester), isFalse);
    verify(() => mockApi.stopServer()).called(1);

    await settleSnackBar(tester);
  });

  testWidgets('启动假成功（状态 stopped）→ 回滚 stop + best-effort 停 server', (
    tester,
  ) async {
    final foreground = _ForegroundMock();
    foreground.install(messenger);
    stubServer(statuses: ['stopped']);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    foreground.calls.clear();

    toggleWebService(tester, true);
    await tester.pumpAndSettle();

    expect(foreground.calls, [
      'hasNotificationPermission',
      'start',
      'isRunning',
      'stop',
    ], reason: '假成功不得留下前台通知');
    expect(find.textContaining('服务状态异常'), findsOneWidget);
    expect(webServiceSwitchValue(tester), isFalse);
    verify(() => mockApi.stopServer()).called(1);
    verifyNever(() => mockApi.setConfig('webService', 'true'));

    await settleSnackBar(tester);
  });

  testWidgets('初始化 running → ensureStarted 幂等（不重复 start）', (tester) async {
    final foreground = _ForegroundMock(running: true);
    foreground.install(messenger);
    stubServer(statuses: ['running on port 1122'], webServiceConfig: 'true');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();

    expect(foreground.calls, [
      'isRunning',
      'hasNotificationPermission',
    ], reason: '原生已运行：只查询对账，不重复拉起');
    expect(webServiceSwitchValue(tester), isTrue);
  });

  testWidgets('前台服务启动失败不阻断 Web 服务开关', (tester) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(WebServiceForegroundService.channel, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isRunning':
          return false;
        case 'hasNotificationPermission':
          return true;
        case 'requestNotificationPermission':
          return true;
        default:
          throw PlatformException(
            code: 'web_foreground_start_failed',
            message: '后台启动限制',
          );
      }
    });
    stubServer(statuses: ['stopped', 'running on port 1122']);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    calls.clear();

    toggleWebService(tester, true);
    await tester.pumpAndSettle();

    expect(calls, ['hasNotificationPermission', 'start']);
    expect(
      webServiceSwitchValue(tester),
      isTrue,
      reason: '前台服务失败仅降级，不得阻断 Web 服务开关',
    );
    expect(find.textContaining('Web 服务切换失败'), findsNothing);
    verify(() => mockApi.setConfig('webService', 'true')).called(1);
  });

  testWidgets('与唤醒锁解耦：偏好关仍启动前台服务', (tester) async {
    // 唤醒锁通道也接上，断言偏好关时不下发 setEnabled
    final wakeLockCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
      call,
    ) async {
      if (call.method == 'isHeld') return false;
      wakeLockCalls.add(call);
      return (call.arguments as Map)['enabled'] as bool;
    });
    WebServiceWakeLockService.platformIsAndroid = () => true;

    final foreground = _ForegroundMock();
    foreground.install(messenger);
    // 偏好默认 false（未设置）
    SharedPreferences.setMockInitialValues({});
    stubServer(statuses: ['stopped', 'running on port 1122']);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    foreground.calls.clear();

    toggleWebService(tester, true);
    await tester.pumpAndSettle();

    expect(foreground.calls, [
      'hasNotificationPermission',
      'start',
      'isRunning',
    ], reason: '前台服务恒随 Web 服务启停');
    expect(wakeLockCalls, isEmpty, reason: '偏好关：绕过唤醒锁，不影响前台服务');

    // 偏好键确实是关（防止测试误设）
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.webServiceWakeLock), isNull);
  });

  testWidgets('停服报错但状态已停 → 仍撤前台服务并关闭开关', (tester) async {
    final foreground = _ForegroundMock(running: true);
    foreground.install(messenger);
    stubServer(
      statuses: ['running on port 1122', 'stopped'],
      stopThrows: true,
      webServiceConfig: 'true',
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    expect(foreground.calls, [
      'isRunning',
      'hasNotificationPermission',
    ], reason: '初始化对账：运行中仅查询');
    foreground.calls.clear();

    toggleWebService(tester, false);
    await tester.pumpAndSettle();

    expect(foreground.calls, ['stop'], reason: '状态确认已停 → 撤前台服务');
    expect(webServiceSwitchValue(tester), isFalse);
    expect(find.textContaining('Web 服务切换失败'), findsNothing);
    verify(() => mockApi.setConfig('webService', 'false')).called(1);
  });

  testWidgets('通知权限拒绝 → FGS 照常运行并提示通知不可见', (tester) async {
    final foreground = _ForegroundMock()
      ..notificationGranted = false
      ..requestGranted = false;
    foreground.install(messenger);
    stubServer(statuses: ['stopped', 'running on port 1122']);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    foreground.calls.clear();

    toggleWebService(tester, true);
    await tester.pumpAndSettle();

    expect(foreground.calls, [
      'hasNotificationPermission',
      'requestNotificationPermission',
      'start',
      'isRunning',
    ], reason: '未授予时才弹权限框；拒绝后仍启动 FGS');
    expect(webServiceSwitchValue(tester), isTrue, reason: '通知权限拒绝不阻断 Web 服务');
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('通知权限未授予：Web 服务前台通知不可见（局域网访问不受影响）'),
      ),
      findsOneWidget,
      reason: '拒绝时给出一次性 SnackBar 提示',
    );
    expect(
      find.textContaining('通知权限未授予，前台通知不可见'),
      findsOneWidget,
      reason: '卡片副题登记通知不可见（FGS 与 LAN 访问不受影响）',
    );
    verify(() => mockApi.setConfig('webService', 'true')).called(1);

    await settleSnackBar(tester);
  });

  testWidgets('回到前台对账：FGS 被系统停止 → 重新拉起', (tester) async {
    final foreground = _ForegroundMock(running: true);
    foreground.install(messenger);
    stubServer(statuses: ['running on port 1122'], webServiceConfig: 'true');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    expect(foreground.calls, ['isRunning', 'hasNotificationPermission']);
    foreground.calls.clear();

    // 模拟系统在后台停止 FGS：Dart 镜像仍为 true，原生已停
    foreground.running = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(foreground.calls, [
      'isRunning',
      'start',
      'isRunning',
      'hasNotificationPermission',
    ], reason: '回前台强制查询并重新拉起（forceQuery，修复镜像陈旧）');
    expect(foreground.running, isTrue);
  });
}
