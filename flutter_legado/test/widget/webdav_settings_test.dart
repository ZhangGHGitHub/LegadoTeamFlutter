// WebDAV 设置页 widget 测试
//
// 验证 Phase 5.4 provider→Riverpod 迁移后（对齐原版 BackupConfigFragment WebDAV 设置组）：
// - Preference 列表风格渲染（配置组 + 备份/恢复组）
// - 点击配置项弹出编辑对话框并保存
// - 未配置时备份给出提示
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: WebDavSettingsScreen()),
    );
  }

  testWidgets('渲染 WebDAV 设置组与备份/恢复组', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // AppBar 标题 + 分组头同名 → 2 处（未滚动时均可见）
    expect(find.text('WebDAV 设置'), findsNWidgets(2));

    // 配置组各项（按需向下滚动至可见）
    for (final label in const [
      'WebDAV 服务器地址',
      'WebDAV 账号',
      'WebDAV 密码',
      '子目录',
      '设备名称',
      '同步书籍进度',
      '同步书籍进度增强',
    ]) {
      await tester.scrollUntilVisible(find.text(label), 80);
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
    }

    // 备份/恢复组
    await tester.scrollUntilVisible(find.text('备份与恢复'), 80);
    await tester.pumpAndSettle();
    expect(find.text('备份'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('最后同步时间'), findsOneWidget);
  });

  testWidgets('点击服务器地址弹出编辑对话框并保存', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('WebDAV 服务器地址'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'https://dav.example.com');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // summary 更新为已保存值
    expect(find.text('https://dav.example.com'), findsOneWidget);
  });

  testWidgets('未配置时点击备份给出提示', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('备份'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份'));
    await tester.pumpAndSettle();

    expect(find.text('请先配置并保存 WebDAV 服务器信息'), findsOneWidget);
  });
}
