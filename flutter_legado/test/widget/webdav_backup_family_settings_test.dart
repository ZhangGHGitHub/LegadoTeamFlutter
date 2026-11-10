/// 批40：WebDAV 备份族设置行（保留数量 / 导入后自动上传 / 自动备份对话框）
///
/// 覆盖：三行渲染与交互、保留数量落盘（字符串偏好）、保留数上限校验
/// （批40 回修 P3-3）、导入后自动上传开关落盘、自动备份对话框校验
/// （0 天拒绝）与三键一次写入、备份按钮链路（批40 回修 P3-6）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

import '../mocks/mocks.dart';

void main() {
  late FakeServersRustApi mockApi;
  late SettingsService settings;

  setUp(() {
    // 批40 回修 P2-2：备份/恢复互斥为进程内静态状态，逐用例复位
    LocalBackupService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
  });

  tearDown(LocalBackupService.resetForTest);

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

  testWidgets('保留数量：超过上限 1000 被拒绝且不落盘（批40 回修 P3-3）', (tester) async {
    await pumpScreen(tester);

    await scrollTo(tester, 'WebDAV 备份保留数量');
    await tester.tap(find.text('WebDAV 备份保留数量'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '1001');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('请输入 0~1000 的整数'), findsOneWidget);
    expect(await settings.getWebDavBackupKeepCount(), 0);
  });

  testWidgets('备份按钮链路：本地备份成功并写 lastBackup，未配置 WebDAV 不上传', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('legado_backup_btn_');
    addTearDown(() {
      // Windows 上文件句柄释放有延迟，清理失败不影响断言结果
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final backupFile = File(
      '${tempDir.path}${Platform.pathSeparator}legado_backup_1.json',
    );
    backupFile.writeAsStringSync('{"version":5}');

    LocalBackupService.resetForTest();
    addTearDown(LocalBackupService.resetForTest);
    SharedPreferences.setMockInitialValues({'app_backup_path': tempDir.path});
    settings = SettingsService();

    mockApi = FakeServersRustApi();
    when(() => mockApi.backup(any())).thenAnswer((_) async => backupFile.path);
    when(() => mockApi.getBooks()).thenAnswer((_) async => []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: WebDavSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await scrollTo(tester, '备份');
    await tester.tap(find.text('备份'));
    await tester.pumpAndSettle();
    // 批11：点按备份行弹三选 Sheet；未配置 WebDAV 时两项含网络的选项禁用
    // （批11 回修 P2-2），本地备份链路改由第一项验证
    expect(find.text('备份至本地'), findsOneWidget);
    expect(find.text('备份至网络'), findsOneWidget);
    expect(find.text('备份至本地与网络'), findsOneWidget);
    expect(find.text('请先配置 WebDAV'), findsNWidgets(2));
    await tester.tap(find.text('备份至本地'));
    // 进度框含无限动画且备份链路有真实文件 IO：不能用 pumpAndSettle；
    // 用 runAsync 推进真实事件循环，等待完成提示出现。
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      if (find.textContaining('备份成功').evaluate().isNotEmpty) break;
    }

    verify(() => mockApi.backup(tempDir.path)).called(1);
    expect(find.textContaining('备份成功'), findsOneWidget);
    expect(await settings.getLastBackupTime(), greaterThan(0));
    verifyNever(() => mockApi.webdavUploadFile(any(), any(), any()));
  });

  testWidgets('未配置 WebDAV：长按备份行明确中止，不静默降级为本地备份（批11 回修 P2-2）', (tester) async {
    await pumpScreen(tester);

    await scrollTo(tester, '备份');
    await tester.longPress(find.text('备份'));
    await tester.pumpAndSettle();

    expect(find.text('未配置 WebDAV，已取消备份'), findsOneWidget);
    expect(find.textContaining('备份成功'), findsNothing);
    verifyNever(() => mockApi.backup(any()));
  });
}
