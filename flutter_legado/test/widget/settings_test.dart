// 设置枢纽菜单 / 其他设置页 widget 测试
//
// 对齐 2026-08-13「我的」设置树（pref_main / pref_config_other）：
// - SettingsScreen：字典规则、备份与恢复全页、无导出日志
// - OtherSettingsScreen：语言/主界面/清理缓存；无创意「阅读/网络」分组
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
      expect(find.text('设置', skipOffstage: false), findsOneWidget);

      await dragTo(tester, '备份与恢复');
      await tester.pumpAndSettle();
      expect(find.text('备份与恢复'), findsOneWidget);

      await dragTo(tester, '主题设置');
      await tester.pumpAndSettle();
      expect(find.text('主题设置'), findsOneWidget);
      expect(find.text('其他设置'), findsOneWidget);

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

    testWidgets('点击备份与恢复进入全页 WebDAV/备份设置', (tester) async {
      await tester.pumpWidget(wrap(
        const SettingsScreen(),
        routes: {
          AppRoutes.webdavSettings: (_) => const WebDavSettingsScreen(),
        },
      ));
      await tester.pumpAndSettle();

      await dragTo(tester, '备份与恢复');
      await tester.drag(find.byType(ListView), const Offset(0, 140));
      await tester.pumpAndSettle();
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
