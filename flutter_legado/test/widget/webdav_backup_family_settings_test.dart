/// 批40：WebDAV 备份族设置行（保留数量 / 导入后自动上传 / 自动备份对话框）
///
/// 覆盖：三行渲染与交互、保留数量落盘（字符串偏好）、导入后自动上传开关
/// 落盘、自动备份对话框校验（0 天拒绝）与三键一次写入。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

import '../mocks/mocks.dart';

void main() {
  late FakeServersRustApi mockApi;
  late SettingsService settings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    mockApi = FakeServersRustApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: WebDavSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('保留数量：输入 2 并确定后以字符串偏好落盘', (tester) async {
    await pumpScreen(tester);

    await scrollTo(tester, 'WebDAV 备份保留数量');
    await tester.tap(find.text('WebDAV 备份保留数量'));
    await tester.pumpAndSettle();

    expect(find.textContaining('0 表示不自动清理'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(await settings.getWebDavBackupKeepCount(), 2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.get('webDavBackupKeepCount'), '2');
  });

  testWidgets('导入后自动上传：整行点击切换并落盘', (tester) async {
    await pumpScreen(tester);
    expect(await settings.getWebDavBookAutoUpload(), isFalse);

    await scrollTo(tester, '导入后自动上传本地书');
    await tester.tap(find.text('导入后自动上传本地书'));
    await tester.pumpAndSettle();

    expect(await settings.getWebDavBookAutoUpload(), isTrue);
  });

  testWidgets('自动备份对话框：0 天被拒绝，3 天保存三项设置', (tester) async {
    await pumpScreen(tester);

    await scrollTo(tester, '自动备份');
    await tester.tap(find.text('自动备份'));
    await tester.pumpAndSettle();

    expect(find.text('启用自动备份'), findsOneWidget);

    // 间隔 0 天：内联错误且对话框不关闭
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('请输入大于 0 的整数'), findsOneWidget);
    expect(find.text('启用自动备份'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('启用自动备份'), findsNothing);
    expect(await settings.getAutoBackupIntervalDays(), 3);
    expect(await settings.getAutoBackup(), isTrue);
    expect(await settings.getAutoBackupWebDav(), isTrue);
  });
}
