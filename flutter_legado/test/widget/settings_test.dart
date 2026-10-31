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

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/web_keep_alive_service.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

import '../mocks/mocks.dart';

void main() {
  late FakeServersRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeServersRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    // 保活单例为进程单例：逐用例复位，防跨用例状态泄漏
    WebKeepAliveService.instance.debugReset();
  });

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
    testWidgets('渲染顶部管理入口与设置/其他分组', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      // 顶部管理入口（对标 pref_main；字典规则非「词典规则」）
      expect(find.text('书源管理'), findsOneWidget);
      expect(find.text('定时任务'), findsOneWidget);
      expect(find.text('TXT 目录规则'), findsOneWidget);
      expect(find.text('替换净化'), findsOneWidget);
      expect(find.text('字典规则'), findsOneWidget);
      expect(find.text('主题模式'), findsOneWidget);

      expect(find.text('我的'), findsWidgets,
          reason: 'SliverAppBar.large 展开大标题与折叠工具栏标题同时存在');
      // [UI_SYNC_REFACTOR S6 | 2026-09-08] 设置主页集中化：我的页原
      // 备份与恢复/主题设置/其他设置三 tile 收敛为单一「设置」入口
      //（组头「设置」+ 入口 tile 同文案，skipOffstage 计 2）— Qoder
      await dragTo(tester, '设置');
      expect(
          find.text('设置', skipOffstage: false), findsNWidgets(2));
      expect(find.text('备份与恢复'), findsNothing);
      expect(find.text('主题设置'), findsNothing);

      // 已删除创意项
      expect(find.text('导出日志'), findsNothing);
      expect(find.text('词典规则'), findsNothing);
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

    testWidgets('点击主题模式弹出选择对话框并可切换（全局生效）', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('跟随系统'), findsOneWidget);
      expect(
        container.read(themeNotifierProvider).themeMode,
        ThemeMode.system,
      );

      // 点标题「主题模式」（subtitle「选择主题模式」同屏，勿用模糊 finder）；
      // LargeTitle 展开占高，先滚动到可见区，再回拖使其离开 pinned 头部遮挡区
      await dragTo(tester, '主题模式');
      await tester.drag(find.byType(ListView), const Offset(0, 140));
      await tester.pumpAndSettle();
      await tester.tap(find.text('主题模式'));
      await tester.pumpAndSettle();

      // 底栏标题与列表 subtitle 可能同文案，用 ListTile 精确匹配选项
      expect(find.widgetWithText(ListTile, '浅色'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '深色'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, '深色'));
      await tester.pumpAndSettle();

      expect(container.read(themeNotifierProvider).themeMode, ThemeMode.dark);
      expect(find.text('深色'), findsOneWidget);
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

    // 批9b-2：线程数默认 32（空 prefs）、保存经 setConfig 同步 Rust、
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
  });
}
