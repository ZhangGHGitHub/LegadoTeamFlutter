// 设置枢纽菜单 / 其他设置页 widget 测试
//
// 对齐 2026-08-13「我的」设置树（pref_main / pref_config_other）：
// - SettingsScreen：字典规则、备份与恢复全页、无导出日志
// - OtherSettingsScreen：语言/主界面/清理缓存；无创意「阅读/网络」分组
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_home_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
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
  });
}
