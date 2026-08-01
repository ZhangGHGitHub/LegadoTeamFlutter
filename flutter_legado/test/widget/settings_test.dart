// 设置枢纽菜单 / 其他设置页 widget 测试
//
// 验证 Phase 4.1 设置页重构（对标 Android pref_main 枢纽结构）：
// - SettingsScreen 以菜单入口聚合各管理功能与子设置页
// - OtherSettingsScreen 承接语言/阅读默认/网络（含 QUIC）/缓存入口
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/bookshelf_provider.dart';
import 'package:flutter_legado/src/providers/sync_provider.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/services/book_api.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() {
    mockApi = MockRustApi();
  });

  Widget wrap(Widget child) {
    return MultiProvider(
      providers: [
        Provider<BookApi>.value(value: mockApi),
        ChangeNotifierProvider(create: (_) => BookshelfProvider(mockApi)),
        ChangeNotifierProvider(create: (_) => SyncProvider(mockApi)),
      ],
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

      // 设置分组（“设置”同时出现在 AppBar 标题与分组头，故为 2 处）
      expect(find.text('设置'), findsNWidgets(2));
      expect(find.text('备份恢复'), findsOneWidget);
      // 主题设置/其他设置在默认视口折叠区外，需滚动可见
      await tester.scrollUntilVisible(find.text('主题设置'), 100);
      await tester.pumpAndSettle();
      expect(find.text('主题设置'), findsOneWidget);
      expect(find.text('其他设置'), findsOneWidget);
    });

    testWidgets('滚动可见其他分组（书签/阅读统计/关于）', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('关于'), 100);
      await tester.pumpAndSettle();

      expect(find.text('书签'), findsOneWidget);
      expect(find.text('阅读统计'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
    });

    testWidgets('点击备份恢复弹出底部弹窗', (tester) async {
      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('备份恢复'));
      await tester.pumpAndSettle();

      // 底部弹窗聚合：备份/恢复/WebDAV 同步
      expect(find.text('备份数据'), findsOneWidget);
      expect(find.text('恢复数据'), findsOneWidget);
      expect(find.text('WebDAV 同步'), findsOneWidget);
    });
  });

  group('OtherSettingsScreen 其他设置', () {
    testWidgets('渲染语言/阅读/网络/缓存分组（含 QUIC 开关）', (tester) async {
      await tester.pumpWidget(wrap(const OtherSettingsScreen()));
      await tester.pumpAndSettle();

      expect(find.text('语言'), findsWidgets);
      expect(find.text('阅读设置'), findsOneWidget);
      expect(find.text('网络设置'), findsOneWidget);

      // QUIC 开关与缓存入口在折叠区，需滚动可见
      await tester.scrollUntilVisible(find.text('QUIC/HTTP3'), 100);
      await tester.pumpAndSettle();
      expect(find.text('QUIC/HTTP3'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('缓存管理'), 100);
      await tester.pumpAndSettle();
      expect(find.text('缓存管理'), findsOneWidget);
    });
  });
}
