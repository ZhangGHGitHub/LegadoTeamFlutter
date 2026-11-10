// WebDAV / 备份与恢复页 widget 测试
//
// 对齐 BackupConfigFragment + pref_config_backup：AppBar「备份与恢复」
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';
import 'package:flutter_legado/src/widgets/restore_ignore_dialog.dart';

import '../mocks/mocks.dart';

class _FailingSaveSettings extends SettingsService {
  @override
  Future<bool> saveBackupIgnoreConfig(Map<String, bool> config) async => false;
}

void main() {
  late FakeServersRustApi mockApi;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeServersRustApi();
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

  testWidgets('渲染 WebDAV 配置组与备份/恢复组', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // AppBar 标题
    expect(find.text('备份与恢复'), findsWidgets);

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

    await tester.scrollUntilVisible(find.text('备份路径'), 80);
    await tester.pumpAndSettle();
    expect(find.text('备份'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('恢复忽略列表'), findsOneWidget);
    expect(find.text('备份忽略列表'), findsOneWidget);
    expect(find.text('未设置'), findsOneWidget);
    expect(find.text('仅保留最新备份'), findsOneWidget);
  });

  testWidgets('点击服务器地址弹出编辑对话框并保存', (tester) async {
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.text('WebDAV 服务器地址'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'https://dav.example.com');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('https://dav.example.com'), findsOneWidget);
  });

  testWidgets('[GLOBALCOMP B5] 开关行迁移后整行点击即切换并持久化', (tester) async {
    // 该行由 SwitchListTile 迁移为统一 SettingSwitchRow（M3 设置开关行），
    // 行为要求不变：整行可点即切换（参考版 SwitchSettingItem onClick 语义）
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('仅保留最新备份'), 80);
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text('仅保留最新备份'),
      matching: find.byType(SettingSwitchRow),
    );
    expect(row, findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);

    final switchFinder = find.descendant(
      of: row,
      matching: find.byType(Switch),
    );
    final before = tester.widget<Switch>(switchFinder).value;

    // 点标题（非开关本体）即切换：等价原 SwitchListTile 整行语义
    await tester.tap(find.text('仅保留最新备份'));
    await tester.pumpAndSettle();

    final after = tester.widget<Switch>(switchFinder).value;
    expect(after, !before);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('onlyLatestBackup'), after);
  });

  testWidgets('[批11] 未配置 WebDAV 时点击恢复弹四项 Sheet，网络项禁用', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(find.text('本地恢复'), findsOneWidget);
    expect(find.text('网络恢复'), findsOneWidget);
    expect(find.text('本地最新'), findsOneWidget);
    expect(find.text('远端最新'), findsOneWidget);
    // 网络恢复 + 远端最新两项禁用原因
    expect(find.text('请先配置 WebDAV'), findsNWidgets(2));
  });

  testWidgets('备份忽略列表：打开独立对话框并保存勾选项', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('备份忽略列表'), 80);
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份忽略列表'));
    await tester.pumpAndSettle();

    // 复用恢复忽略 UI，但标题/说明/保存目标为备份忽略
    expect(find.text('备份忽略'), findsOneWidget);
    expect(find.text('恢复忽略'), findsNothing);
    expect(find.text('勾选后备份时跳过对应项，不写入备份文件；恢复忽略请单独设置。'), findsOneWidget);

    await tester.tap(find.text('阅读界面配置'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('已保存备份忽略项'), findsOneWidget);
    expect(find.text('已勾选 1 项'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('backupIgnore');
    expect(saved, isNotNull);
    expect(saved, contains('"readConfig":true'));
    // 恢复忽略策略不被写入
    expect(prefs.getString('restoreIgnore'), isNull);
  });

  testWidgets('备份忽略列表：已保存配置加载后显示勾选数', (tester) async {
    SharedPreferences.setMockInitialValues({
      'backupIgnore': '{"readConfig":true,"themeMode":true}',
    });
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('备份忽略列表'), 80);
    await tester.pumpAndSettle();
    expect(find.text('已勾选 2 项'), findsOneWidget);
  });

  testWidgets('恢复忽略对话框默认副标题提示备份忽略需单独设置', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RestoreIgnoreDialog(
            initial: {
              for (final k in SettingsService.restoreIgnoreKeys) k: false,
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('恢复忽略'), findsOneWidget);
    expect(find.text('恢复时跳过对应项；备份忽略请单独设置。'), findsOneWidget);
  });

  testWidgets('备份忽略对话框 360dp 大字体不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            textScaler: TextScaler.linear(2.0),
          ),
          child: Scaffold(
            body: RestoreIgnoreDialog(
              initial: {
                for (final k in SettingsService.backupIgnoreKeys) k: false,
              },
              title: '备份忽略',
              subtitle: '勾选后备份时跳过对应项，不写入备份文件；恢复忽略请单独设置。',
              keys: SettingsService.backupIgnoreKeys,
              titles: SettingsService.backupIgnoreTitles,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('备份忽略'), findsOneWidget);
  });

  testWidgets('备份忽略保存失败：提示失败且不更新勾选数', (tester) async {
    final failingContainer = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        settingsProvider.overrideWithValue(_FailingSaveSettings()),
      ],
    );
    addTearDown(failingContainer.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: failingContainer,
        child: const MaterialApp(home: WebDavSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('备份忽略列表'), 80);
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份忽略列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读界面配置'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('保存备份忽略项失败'), findsOneWidget);
    expect(find.text('已保存备份忽略项'), findsNothing);
    expect(find.text('未设置'), findsOneWidget, reason: '保存失败不更新页面状态');
  });
}
