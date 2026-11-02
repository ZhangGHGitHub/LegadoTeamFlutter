// 设置枢纽菜单 / 其他设置页 widget 测试
//
// 对齐 2026-08-13「我的」设置树（pref_main / pref_config_other）：
// - SettingsScreen：字典规则、备份与恢复全页、无导出日志
// - OtherSettingsScreen：语言/主界面/清理缓存；无创意「阅读/网络」分组
import 'dart:io';

import 'package:flutter/foundation.dart';
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
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/web_keep_alive_service.dart';
import 'package:flutter_legado/src/services/web_service_wake_lock_service.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

import '../mocks/fake_web_service_address_resolver.dart';
import '../mocks/mocks.dart';

void main() {
  late FakeServersRustApi mockApi;
  late ProviderContainer container;
  late FakeWebServiceAddressResolver addressResolver;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeServersRustApi();
    addressResolver = FakeWebServiceAddressResolver();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        // [M1] FakeAsync 下真实网卡枚举不完成，注入固定局域网 IP
        webServiceAddressResolverProvider.overrideWithValue(addressResolver),
      ],
    );
    addTearDown(container.dispose);
    // 保活单例为进程单例：逐用例复位，防跨用例状态泄漏
    WebKeepAliveService.instance.debugReset();
    // 唤醒锁单例同为进程级：逐用例复位内存态与平台门控（审查 P3）
    WebServiceWakeLockService.instance.debugReset();
    WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
  });

  /// 等 SnackBar 自动消失，避免挂起计时器影响后续用例
  Future<void> settleSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  Widget wrap(Widget child, {Map<String, WidgetBuilder>? routes}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: child,
        routes: routes ?? const {},
      ),
    );
  }

  /// [MD3 LargeTitle] 页面改为 NestedScrollView（外层折叠头 + 内层 ListView），
  /// 滚动定位需指定内层 ListView 视图
  Future<void> dragTo(WidgetTester tester, String text) {
    return tester.dragUntilVisible(
      find.text(text),
      find.byType(ListView),
      const Offset(0, -100),
    );
  }

  /// 把 Web 服务卡滚到「可真实命中」的位置（批23）
  ///
  /// [dragTo] 只保证目标「刚可见」：实测卡片标题停在 y=0，被折叠大标题的
  /// PinnedHeader 覆盖，`tester.tap` 会命中 AppBar 而非卡片（hit test 失败）。
  /// 额外向下拖 200 逻辑像素，让卡片离开顶部覆盖层再点按。
  Future<void> centerWebServiceCard(WidgetTester tester) async {
    await dragTo(tester, 'Web 服务');
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
  }

  group('SettingsScreen 枢纽菜单', () {
    testWidgets('渲染 Web 服务置顶与规则/服务与工具/其他分组（M1）', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      // [M1 我的页 | 2026-11-03] Web 服务块置顶后无需滚动即可见
      expect(find.text('Web 服务'), findsOneWidget);

      // 「规则」组 5 项（原「规则管理」并入「字典规则」；文案对齐
      // 参考版「高亮标签规则」）
      for (final label in ['书源管理', '替换净化', 'TXT 目录规则', '字典规则', '高亮标签规则']) {
        await dragTo(tester, label);
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget, reason: '规则组应含「$label」');
      }

      // 「服务与工具」组：原版能力保留区
      for (final label in ['定时任务', '运行定时任务', 'MCP 服务']) {
        await dragTo(tester, label);
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget, reason: '服务与工具组应含「$label」');
      }

      // 「其他」组：AI 聊天 / 设置 / 书签 / 阅读记录 / 缓存管理 / 文件管理 /
      // 关于 / 退出
      for (final label in ['AI 聊天', '设置', '书签', '阅读记录', '缓存管理', '文件管理', '关于', '退出']) {
        await dragTo(tester, label);
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget, reason: '其他组应含「$label」');
      }

      // 已合并/移除项的负向断言由 my_page_m1_test 的高画布用例承担：
      // 默认 800x600 列表存在懒构建，未滚动到的条目不在树上，
      // 此处 findsNothing 无法区分「已移除」与「尚未构建」。

      expect(find.text('我的'), findsWidgets,
          reason: 'SliverAppBar.large 展开大标题与折叠工具栏标题同时存在');
    });

    testWidgets('滚动可见其他分组（书签/阅读记录/关于）', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      await dragTo(tester, '关于');
      await tester.pumpAndSettle();

      expect(find.text('书签'), findsOneWidget);
      expect(find.text('阅读记录'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
    });

    // [2026-10-06 登记待修 → 本批已修复] iOS 实机开启 Web 服务不可用：
    // 根因见 docs/IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006.md（缺陷 A/B/C
    // 已随本批修复：绑定前置+0.0.0.0、Info.plist 补本地网络用途描述）。
    // 原「iOS 标记暂不可用」用例按登记要求改为本「iOS 可用」断言。
    testWidgets('Web 服务卡：iOS 可用（副题为正常文案，开关可用）', (tester) async {
      // debugDefaultTargetPlatformOverride 须在测试体内复位（框架在
      // addTearDown 之前校验 foundation 调试变量已归位），故用 try/finally。
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(wrap(const SettingsScreen()));
        await tester.pumpAndSettle();
        await dragTo(tester, 'Web 服务');
        await tester.pumpAndSettle();

        expect(find.text('用浏览器写源或看书'), findsOneWidget);
        expect(find.text('暂不可用，将在后续版本修复'), findsNothing);
        final card = find
            .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
            .first;
        expect(
          tester
              .widget<Switch>(
                find.descendant(of: card, matching: find.byType(Switch)),
              )
              .onChanged,
          isNotNull,
          reason: 'iOS 上 Web 服务开关应可用（门控已移除）',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Web 服务卡：非 iOS 维持原形态（副题与开关可用）', (tester) async {
      // 明示 android 防上一用例平台残留；try/finally 理由同上
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpWidget(wrap(const SettingsScreen()));
        await tester.pumpAndSettle();
        await dragTo(tester, 'Web 服务');
        await tester.pumpAndSettle();

        expect(find.text('用浏览器写源或看书'), findsOneWidget);
        expect(find.text('暂不可用，将在后续版本修复'), findsNothing);
        final card = find
            .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
            .first;
        expect(
          tester
              .widget<Switch>(
                find.descendant(of: card, matching: find.byType(Switch)),
              )
              .onChanged,
          isNotNull,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // [Web 端口缺陷修复 | 2026-10-06] 开关启动须使用「其他设置 → Web 服务端口」
    // 配置（PrefKeys.webPort）：原实现在此调 startServer() 不传参，恒用默认
    // 1122，设置页端口形同虚设（对齐原版 WebService.kt:244 启动读配置端口）。
    testWidgets('Web 服务开关：启动使用配置端口 webPort=8080', (tester) async {
      SharedPreferences.setMockInitialValues({'webPort': 8080});
      final startedPorts = <int>[];
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((inv) async {
        startedPorts.add(inv.namedArguments[#port] as int);
      });
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 8080');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      // 直接触发 onChanged（等价用户点开关）：NestedScrollView 下
      // ensureVisible/tap 会把卡片滚出视口导致 finder 失效
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(startedPorts, [8080], reason: '应把「其他设置」配置端口传给 startServer');
    });

    testWidgets('Web 服务开关：未配置端口回落默认 1122', (tester) async {
      final startedPorts = <int>[];
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((inv) async {
        startedPorts.add(inv.namedArguments[#port] as int);
      });
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(startedPorts, [1122], reason: '未设置 webPort 时默认 1122（对齐原版）');
    });

    testWidgets('Web 服务开关：越界 webPort 回落默认 1122（防手改 prefs）', (tester) async {
      SharedPreferences.setMockInitialValues({'webPort': 500});
      final startedPorts = <int>[];
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((inv) async {
        startedPorts.add(inv.namedArguments[#port] as int);
      });
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(startedPorts, [1122], reason: '越界端口（<1024）按默认 1122 兜底');
    });

    // [2026-10-07 | iOS Web 服务后台保活批] 接线回归：服务 start/stop 成功
    // 必须伴随保活 setEnabled(true/false)——静音音轨生命周期严格绑定 Web 服务
    //（对齐原版 WakeLock 的「防睡眠」目的，见 WEB_SERVICE_KEEPALIVE_SURVEY_20261007.md）。
    testWidgets('Web 服务开关：start 成功接保活 true，stop 成功接保活 false', (
      tester,
    ) async {
      WebKeepAliveService.platformIsIOS = () => true;
      addTearDown(
        () => WebKeepAliveService.platformIsIOS = () => Platform.isIOS,
      );
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebKeepAliveService.channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          WebKeepAliveService.channel,
          null,
        ),
      );

      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((_) async {});
      when(() => mockApi.stopServer()).thenAnswer((_) async {});
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );

      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(calls, hasLength(1), reason: 'startServer 成功后应启动保活');
      expect(calls.single.method, 'setEnabled');
      expect((calls.single.arguments as Map)['enabled'], isTrue);

      tester.widget<Switch>(switchFinder).onChanged!(false);
      await tester.pumpAndSettle();

      expect(calls, hasLength(2), reason: 'stopServer 成功后应停止保活');
      expect((calls.last.arguments as Map)['enabled'], isFalse);
    });

    // [2026-10-07 | 方案 A 兜底] 保活启动失败不得阻断 Web 服务：开关仍开启、
    // 副题提示「后台保活不可用，请保持 App 打开」。
    testWidgets('Web 服务开关：保活失败回退提示且不阻断服务开启', (tester) async {
      WebKeepAliveService.platformIsIOS = () => true;
      addTearDown(
        () => WebKeepAliveService.platformIsIOS = () => Platform.isIOS,
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        WebKeepAliveService.channel,
        (call) async => false, // 平台侧启动失败（如会话激活失败）
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          WebKeepAliveService.channel,
          null,
        ),
      );

      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((_) async {});
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(find.textContaining('后台保活不可用'), findsOneWidget);
      expect(
        tester.widget<Switch>(switchFinder).value,
        isTrue,
        reason: '保活失败不阻断 Web 服务开关（方案 A 兜底）',
      );
    });

    // [批9b-6 | Web 服务唤醒锁] 接线回归：偏好 `webServiceWakeLock` 开 →
    // startServer 成功后 acquire，stopServer 成功后 release（对齐原版
    // WebService.kt:105-106,140-141,160-161；Android 通道语义，测试注入平台标志）。
    testWidgets('Web 服务开关：偏好开 → 启动接唤醒锁，停止释放', (tester) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        // 原生 isHeld 查询：初始未持有；setEnabled 回传下发后的持有态
        if (call.method == 'isHeld') return false;
        calls.add(call);
        return (call.arguments as Map)['enabled'] as bool;
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      // 偏好开（其他设置 → Web 服务唤醒锁）
      SharedPreferences.setMockInitialValues({
        PrefKeys.webServiceWakeLock: true,
      });

      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((_) async {});
      when(() => mockApi.stopServer()).thenAnswer((_) async {});
      // 初始化对账时服务未运行；startServer 后再报 running，确保本用例只
      // 验证「启动成功后 acquire」而不是初始化对账路径
      var serverStatus = 'stopped';
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => serverStatus);

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );

      serverStatus = 'running on port 1122';
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(calls, hasLength(1), reason: 'startServer 成功后应持唤醒锁');
      expect(calls.single.method, 'setEnabled');
      expect((calls.single.arguments as Map)['enabled'], isTrue);
      expect(WebServiceWakeLockService.instance.isHeld, isTrue);

      tester.widget<Switch>(switchFinder).onChanged!(false);
      await tester.pumpAndSettle();

      expect(calls, hasLength(2), reason: 'stopServer 成功后应释放唤醒锁');
      expect((calls.last.arguments as Map)['enabled'], isFalse);
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);
    });

    // 偏好关（默认 false）→ 服务启动也不得持有唤醒锁
    testWidgets('Web 服务开关：偏好关 → 不 acquire 唤醒锁', (tester) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        // 原生 isHeld 查询：返回未持有，让首次同步走 acquire
        if (call.method == 'isHeld') return false;
        calls.add(call);
        return (call.arguments as Map)['enabled'] as bool;
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });

      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((_) async {});
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '偏好关闭时不得持有唤醒锁');
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);
    });

    // [批9b-6 审查回修 P3] 启动 post-check：startServer 未报错但状态仍
    // stopped（假成功）→ 回滚释放唤醒锁、不置开关、不写 webService=true。
    testWidgets('Web 服务开关：启动后状态 stopped → 回滚释放并提示', (tester) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') return false;
        calls.add(call);
        return (call.arguments as Map)['enabled'] as bool;
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      SharedPreferences.setMockInitialValues({
        PrefKeys.webServiceWakeLock: true,
      });

      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((_) async {});
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'stopped');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [true, false],
        reason: '启动后状态异常应回滚释放唤醒锁',
      );
      expect(
        find.textContaining('Web 服务启动失败'),
        findsOneWidget,
        reason: '假成功应提示失败',
      );
      expect(
        tester.widget<Switch>(switchFinder).value,
        isFalse,
        reason: '启动失败不得把开关置为开',
      );
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);
      verifyNever(() => mockApi.setConfig('webService', 'true'));

      await settleSnackBar(tester);
    });

    // [批9b-6 审查回修 P3] 停服报错但状态查询确认已停 → 仍释放锁并关闭开关，
    // 不误报「切换失败」。
    testWidgets('Web 服务开关：停服异常但状态已停 → 释放锁并关闭', (tester) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') return false;
        calls.add(call);
        return (call.arguments as Map)['enabled'] as bool;
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      SharedPreferences.setMockInitialValues({
        PrefKeys.webServiceWakeLock: true,
      });

      final statuses = <String>['running on port 1122', 'stopped'];
      // 模拟「Web 服务运行中」：配置镜像 true，初始化对账即持锁
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments[0] as String;
        return key == 'webService' ? 'true' : null;
      });
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(() => mockApi.stopServer()).thenAnswer(
        (_) async => throw const BridgeError(message: '停止超时'),
      );
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => statuses.removeAt(0));

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      expect(
        tester.widget<Switch>(switchFinder).value,
        isTrue,
        reason: '配置 webService=true 且状态 running → 开关为开',
      );
      expect(calls, hasLength(1), reason: '初始化对账应持锁');

      tester.widget<Switch>(switchFinder).onChanged!(false);
      await tester.pumpAndSettle();

      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [true, false],
        reason: '状态已停 → 仍应释放唤醒锁',
      );
      expect(
        tester.widget<Switch>(switchFinder).value,
        isFalse,
        reason: '状态确认已停 → 开关应关闭',
      );
      expect(find.textContaining('Web 服务切换失败'), findsNothing);
      verify(() => mockApi.setConfig('webService', 'false')).called(1);
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);
    });

    // [批9b-6 边界回修] 初始化对账不再只看 webService 配置：配置关/缺失也
    // 查询实际状态；stopped + 原生仍持有 → 释放遗留锁（新引擎场景）。
    testWidgets('设置页初始化：配置关 + 服务 stopped + 原生仍持有 → 释放遗留锁', (
      tester,
    ) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      var nativeHeld = true;
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'isHeld':
            return nativeHeld;
          case 'setEnabled':
            calls.add(call);
            nativeHeld = (call.arguments as Map)['enabled'] as bool;
            return nativeHeld;
          default:
            return null;
        }
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'stopped');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [false],
        reason: '配置关但服务未运行 → 仍应清理原生遗留锁',
      );
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);
      expect(nativeHeld, isFalse);
    });

    // [批9b-6 边界回修] 启动后状态查询异常：回滚释放刚 acquire 的锁并提示，
    // 不留在「已持锁但状态未知」。
    testWidgets('Web 服务开关：启动后状态查询异常 → 回滚释放并提示', (tester) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        if (call.method == 'isHeld') return false;
        calls.add(call);
        return (call.arguments as Map)['enabled'] as bool;
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      SharedPreferences.setMockInitialValues({
        PrefKeys.webServiceWakeLock: true,
      });

      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((_) async {});
      when(() => mockApi.getServerStatus()).thenAnswer(
        (_) async => throw const BridgeError(message: '状态查询失败'),
      );

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [true, false],
        reason: '状态查询异常应回滚释放刚获取的唤醒锁',
      );
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);
      expect(find.textContaining('无法确认服务状态'), findsOneWidget);
      expect(tester.widget<Switch>(switchFinder).value, isFalse);
      verifyNever(() => mockApi.setConfig('webService', 'true'));

      await settleSnackBar(tester);
    });

    // [批9b-6 审查回修 P1-2/P2-5] 引擎/Activity 重建：Dart 状态归零但原生
    // 锁进程级仍在 → 设置页初始化按 running + 偏好开重新确认持有（不重复下发）。
    testWidgets('设置页初始化：引擎重建后原生仍持有 → 重新对账保持锁', (tester) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      var nativeHeld = true;
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'isHeld':
            return nativeHeld;
          case 'setEnabled':
            calls.add(call);
            nativeHeld = (call.arguments as Map)['enabled'] as bool;
            return nativeHeld;
          default:
            return null;
        }
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      SharedPreferences.setMockInitialValues({
        PrefKeys.webServiceWakeLock: true,
      });
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments[0] as String;
        return key == 'webService' ? 'true' : null;
      });
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      expect(
        WebServiceWakeLockService.instance.isHeld,
        isTrue,
        reason: '运行中 + 偏好开 → 对账后确认持有',
      );
      expect(nativeHeld, isTrue);
      expect(
        calls,
        isEmpty,
        reason: '原生已持有，重新对账不应重复 acquire（幂等）',
      );
    });

    // 引擎重建 + 运行中 + 偏好关 → 初始化对账释放原生遗留锁
    testWidgets('设置页初始化：运行中偏好关 → 释放遗留锁', (tester) async {
      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      var nativeHeld = true;
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'isHeld':
            return nativeHeld;
          case 'setEnabled':
            calls.add(call);
            nativeHeld = (call.arguments as Map)['enabled'] as bool;
            return nativeHeld;
          default:
            return null;
        }
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments[0] as String;
        return key == 'webService' ? 'true' : null;
      });
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      expect(
        calls.map((c) => (c.arguments as Map)['enabled']).toList(),
        [false],
        reason: '运行中偏好关 → 释放遗留锁',
      );
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);
      expect(nativeHeld, isFalse);
    });

    // [批23 | 全栈工程师] 整卡可点：原实现只有右端 Switch 可点，点标题/
    // 图标/副题无响应。本用例点标题文本（InkWell 覆盖区域）验证开关被切换。
    testWidgets('Web 服务卡：点卡片标题即切换开关', (tester) async {
      final startedPorts = <int>[];
      final configWrites = <MapEntry<String, String>>[];
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((inv) async {
        configWrites.add(
          MapEntry(
            inv.positionalArguments[0] as String,
            inv.positionalArguments[1] as String,
          ),
        );
      });
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((inv) async {
        startedPorts.add(inv.namedArguments[#port] as int);
      });
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await centerWebServiceCard(tester);

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(InkWell))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );

      await tester.tap(find.text('Web 服务'));
      await tester.pumpAndSettle();

      expect(startedPorts, [1122], reason: '点卡片标题应等价点开关（启动服务）');
      expect(
        tester.widget<Switch>(switchFinder).value,
        isTrue,
        reason: '整卡点击后开关应变为开启',
      );
      expect(
        configWrites
            .where((e) => e.key == 'webService')
            .map((e) => e.value)
            .toList(),
        ['true'],
        reason: '整卡点击只应写入一次 webService=true',
      );
    });

    // [批23b] 效果幂等：点右端 Switch 即使冒泡到整卡 onTap，busy 守卫也会
    // 吞掉同步重复触发。本用例只断言可观察结果「只切换一次」（启动一次、
    // 仅写一次 webService=true、无 stopServer 二次切换），不宣称能证明
    // 手势来源唯一（若晚到触发发生在 busy 释放后，会表现为二次切换）。
    testWidgets('Web 服务卡：点开关不误触整卡点击', (tester) async {
      final startedPorts = <int>[];
      final configWrites = <MapEntry<String, String>>[];
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((inv) async {
        configWrites.add(
          MapEntry(
            inv.positionalArguments[0] as String,
            inv.positionalArguments[1] as String,
          ),
        );
      });
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer((inv) async {
        startedPorts.add(inv.namedArguments[#port] as int);
      });
      when(() => mockApi.stopServer()).thenAnswer((_) async {});
      when(() => mockApi.getServerStatus())
          .thenAnswer((_) async => 'running on port 1122');

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();
      await centerWebServiceCard(tester);

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(InkWell))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(startedPorts, [1122], reason: '点开关应只启动一次');
      expect(
        tester.widget<Switch>(switchFinder).value,
        isTrue,
        reason: '点开关后应开启（若被整卡 onTap 二次触发会再次切换）',
      );
      expect(
        configWrites
            .where((e) => e.key == 'webService')
            .map((e) => e.value)
            .toList(),
        ['true'],
        reason: '点开关只应写入一次 webService=true（效果幂等）',
      );
      verifyNever(() => mockApi.stopServer());
    });

    testWidgets('经设置主页进入备份与恢复全页 WebDAV/备份设置', (tester) async {
      await tester.pumpWidget(wrap(
        const SettingsScreen(),
        routes: {
          AppRoutes.settingsHome: (_) => const SettingsHomeScreen(),
          AppRoutes.webdavSettings: (_) => const WebDavSettingsScreen(),
        },
      ));
      await tester.pumpAndSettle();

      // 我的页「设置」→ 设置主页「备份与恢复」（集中化两级导航）
      await dragTo(tester, '设置');
      await tester.drag(find.byType(ListView), const Offset(0, 140));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
          find.text('备份与恢复'), find.byType(CustomScrollView).first,
          const Offset(0, -80));
      await tester.tap(find.text('备份与恢复'));
      await tester.pumpAndSettle();

      // 全页（非底部弹窗）：AppBar + 配置项
      expect(find.text('备份与恢复'), findsWidgets);
      expect(find.text('WebDAV 服务器地址'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('备份'), 80);
      await tester.pumpAndSettle();
      expect(find.text('备份'), findsOneWidget);
      expect(find.text('恢复'), findsOneWidget);
      expect(find.text('恢复忽略列表'), findsOneWidget);
    });
  });

  group('OtherSettingsScreen 其他设置', () {
    testWidgets('渲染语言/主界面/清理缓存（无创意阅读网络分组）', (tester) async {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);

      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('语言'), findsWidgets);
      expect(find.text('主界面'), findsOneWidget);

      // 创意分组已删
      expect(find.text('阅读设置'), findsNothing);
      expect(find.text('网络设置'), findsNothing);
      expect(find.text('缓存管理'), findsNothing);

      await tester.scrollUntilVisible(find.text('清理缓存'), 100);
      await tester.pumpAndSettle();
      expect(find.text('清理缓存'), findsOneWidget);
    });

    // 批9b-4：用户代理保存/清空经既有 BookApi.setConfig 同步 Rust 网络层
    testWidgets('用户代理保存与清空同步 Rust config:userAgent', (tester) async {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      // 保存：打开对话框输入自定义 UA
      await dragTo(tester, '用户代理');
      await tester.pumpAndSettle();
      await tester.tap(find.text('用户代理'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'GlobalUA/9.9');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      verify(() => mockApi.setConfig(PrefKeys.userAgent, 'GlobalUA/9.9'))
          .called(1);

      // 清空：再次打开对话框，清空文本 → 写空串（Rust 回落内置默认）
      await tester.tap(find.text('用户代理'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      verify(() => mockApi.setConfig(PrefKeys.userAgent, '')).called(1);
    });

    // 批9b-2：线程数默认 16（空 prefs）、保存经 setConfig 同步 Rust、
    // 范围对齐参考版 1..256（越界不保存）
    testWidgets('线程数：默认 16、保存同步 Rust、越界拒绝', (tester) async {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      const tileTitle = '更新和搜索线程数（太多会卡顿）';
      await dragTo(tester, tileTitle);
      await tester.pumpAndSettle();

      final tile = tester.widget<IosListTile>(
        find.ancestor(
          of: find.text(tileTitle),
          matching: find.byType(IosListTile),
        ).first,
      );
      expect(tile.value, '16', reason: '未设置偏好时默认 16（对齐参考版）');

      // 保存：写 prefs 并经 BookApi.setConfig 同步 Rust
      await tester.tap(find.text(tileTitle));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '48');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      verify(() => mockApi.setConfig(PrefKeys.threadCount, '48')).called(1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.threadCount), 48);

      // 范围校验：999 超出 1..256 → toast 且不写入
      await tester.tap(find.text(tileTitle));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '999');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(find.text('请输入 1 ~ 256 之间的数字'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      verifyNever(() => mockApi.setConfig(PrefKeys.threadCount, '999'));
      expect(prefs.getInt(PrefKeys.threadCount), 48, reason: '越界值不得写入');
    });

    // 批9b-2 审查回修：存量 >256 仅夹逼显示（不改写 prefs）
    testWidgets('线程数：存量 999 夹逼显示 256', (tester) async {
      SharedPreferences.setMockInitialValues({PrefKeys.threadCount: 999});
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      const tileTitle = '更新和搜索线程数（太多会卡顿）';
      await dragTo(tester, tileTitle);
      await tester.pumpAndSettle();

      final tile = tester.widget<IosListTile>(
        find.ancestor(
          of: find.text(tileTitle),
          matching: find.byType(IosListTile),
        ).first,
      );
      expect(tile.value, '256', reason: '存量超上限仅夹逼显示');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.threadCount), 999, reason: '不改写存量偏好');
    });

    // [批9b-6 | Web 服务唤醒锁] 运行中切换即时生效：Web 服务已运行且偏好原为
    // 关时，打开开关立即 acquire、关闭立即 release（对齐原版开关关即释放）；
    // 服务未运行的分支由 service 单测覆盖。
    testWidgets('Web 服务唤醒锁：运行中切换即时 acquire/release', (tester) async {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

      WebServiceWakeLockService.platformIsAndroid = () => true;
      WebServiceWakeLockService.instance.debugReset();
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(WebServiceWakeLockService.channel, (
        call,
      ) async {
        // 原生 isHeld 查询：返回未持有，让首次同步走 acquire
        if (call.method == 'isHeld') return false;
        calls.add(call);
        return (call.arguments as Map)['enabled'] as bool;
      });
      addTearDown(() {
        WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid;
        WebServiceWakeLockService.instance.debugReset();
        messenger.setMockMethodCallHandler(
          WebServiceWakeLockService.channel,
          null,
        );
      });
      // 模拟「Web 服务运行中、偏好关」（进页面前服务已启动）
      await WebServiceWakeLockService.instance.onServiceStarted(
        keepAwake: false,
      );

      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      await dragTo(tester, 'Web 服务唤醒锁');
      await tester.pumpAndSettle();
      // 仅 Android 生效的既有副题（不新增平台文案）
      expect(find.text('仅 Android 生效'), findsWidgets);

      final row = find
          .ancestor(
            of: find.text('Web 服务唤醒锁'),
            matching: find.byType(IosListTile),
          )
          .first;
      final switchFinder = find.descendant(
        of: row,
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(switchFinder).value, isFalse);

      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(calls, hasLength(1), reason: '运行中打开开关应立即 acquire');
      expect(calls.single.method, 'setEnabled');
      expect((calls.single.arguments as Map)['enabled'], isTrue);
      expect(WebServiceWakeLockService.instance.isHeld, isTrue);

      tester.widget<Switch>(switchFinder).onChanged!(false);
      await tester.pumpAndSettle();

      expect(calls, hasLength(2), reason: '运行中关闭开关应立即 release');
      expect((calls.last.arguments as Map)['enabled'], isFalse);
      expect(WebServiceWakeLockService.instance.isHeld, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PrefKeys.webServiceWakeLock), isFalse);
    });

    // [批9b-6 审查回修 P3] 非 Android 无平台实现：开关置灰（副题已说明
    // 「仅 Android 生效」），避免用户误以为能生效。
    testWidgets('Web 服务唤醒锁：非 Android 开关禁用', (tester) async {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      WebServiceWakeLockService.platformIsAndroid = () => false;
      addTearDown(
        () => WebServiceWakeLockService.platformIsAndroid = () => Platform.isAndroid,
      );

      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务唤醒锁');
      await tester.pumpAndSettle();

      final row = find
          .ancestor(
            of: find.text('Web 服务唤醒锁'),
            matching: find.byType(IosListTile),
          )
          .first;
      final switchFinder = find.descendant(
        of: row,
        matching: find.byType(Switch),
      );
      expect(
        tester.widget<Switch>(switchFinder).onChanged,
        isNull,
        reason: '非 Android 平台开关应禁用',
      );
      expect(find.text('仅 Android 生效'), findsWidgets);
    });
  });
}
