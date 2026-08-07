// 设置枢纽菜单 / 其他设置页 widget 测试
//
// 验证 Phase 5.4 provider→Riverpod 迁移后的设置页（对标 Android pref_main 枢纽结构）：
// - SettingsScreen 以菜单入口聚合各管理功能与子设置页
// - OtherSettingsScreen 承接语言/阅读默认/网络/缓存入口
//   （QUIC 开关已随 2.0.3 QUIC 移除批清理，断言同步销记）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';

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

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  group('SettingsScreen 枢纽菜单', () {
    testWidgets('渲染顶部管理入口与设置/其他分组', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      // 顶部管理入口（对标 pref_main 顶层项）
      expect(find.text('书源管理'), findsOneWidget);
      expect(find.text('定时任务'), findsOneWidget);
      expect(find.text('TXT 目录规则'), findsOneWidget);
      expect(find.text('替换净化'), findsOneWidget);
      expect(find.text('词典规则'), findsOneWidget);
      expect(find.text('主题模式'), findsOneWidget);

      // AppBar 标题为「我的」（对标原版 fragment_my_config）
      expect(find.text('我的'), findsOneWidget);
      // 「设置」分组头位于视口外缓存区内（对标 pref_main PreferenceCategory）
      expect(find.text('设置', skipOffstage: false), findsOneWidget);
      // 备份恢复在默认视口折叠区外（ListView 懒构建），需滚动可见
      await tester.scrollUntilVisible(find.text('备份恢复'), 100);
      await tester.pumpAndSettle();
      expect(find.text('备份恢复'), findsOneWidget);
      // 主题设置/其他设置在默认视口折叠区外，需滚动可见
      await tester.scrollUntilVisible(find.text('主题设置'), 100);
      await tester.pumpAndSettle();
      expect(find.text('主题设置'), findsOneWidget);
      expect(find.text('其他设置'), findsOneWidget);
    });

    testWidgets('滚动可见其他分组（书签/阅读记录/关于）', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('关于'), 100);
      await tester.pumpAndSettle();

      expect(find.text('书签'), findsOneWidget);
      expect(find.text('阅读记录'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
    });

    testWidgets('点击主题模式弹出选择对话框并可切换（全局生效）', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      // 默认跟随系统（subtitle）
      expect(find.text('跟随系统'), findsOneWidget);
      expect(
        container.read(themeNotifierProvider).themeMode,
        ThemeMode.system,
      );

      // 点击主题模式弹出选择对话框
      await tester.tap(find.text('主题模式'));
      await tester.pumpAndSettle();
      expect(find.text('选择主题模式'), findsOneWidget);
      expect(find.text('浅色'), findsOneWidget);
      expect(find.text('深色'), findsOneWidget);

      // 选择深色 → ThemeNotifier 状态更新（驱动 MaterialApp 全局切换）
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();

      expect(container.read(themeNotifierProvider).themeMode, ThemeMode.dark);
      expect(find.text('深色'), findsOneWidget);
    });

    testWidgets('点击备份恢复弹出底部弹窗（含延后项占位）', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('备份恢复'), 100);
      await tester.pumpAndSettle();
      await tester.tap(find.text('备份恢复'));
      await tester.pumpAndSettle();

      // 底部弹窗聚合：备份/恢复/WebDAV 同步
      expect(find.text('备份数据'), findsOneWidget);
      expect(find.text('恢复数据'), findsOneWidget);
      expect(find.text('WebDAV 同步'), findsOneWidget);

      // 延后项占位（禁用，副标题「后续版本支持」）
      expect(find.text('恢复忽略项'), findsOneWidget);
      expect(find.text('导入旧版数据'), findsOneWidget);
      expect(find.text('后续版本支持'), findsNWidgets(2));
    });

    testWidgets('滚动可见导出日志入口', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('导出日志'), 100);
      await tester.pumpAndSettle();

      expect(find.text('导出日志'), findsOneWidget);
      expect(find.text('分享应用日志文件用于问题诊断'), findsOneWidget);
    });
  });

  group('OtherSettingsScreen 其他设置', () {
    testWidgets('渲染语言/阅读/网络/缓存分组', (tester) async {
      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('语言'), findsWidgets);
      expect(find.text('阅读设置'), findsOneWidget);
      expect(find.text('网络设置'), findsOneWidget);

      // 缓存入口在折叠区，需滚动可见（QUIC 开关已随 2.0.3 QUIC 移除批清理）
      await tester.scrollUntilVisible(find.text('缓存管理'), 100);
      await tester.pumpAndSettle();
      expect(find.text('缓存管理'), findsOneWidget);
    });
  });
}
