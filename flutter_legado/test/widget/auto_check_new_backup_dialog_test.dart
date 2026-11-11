// 批10：启动自动检查新备份的 Widget 测试
//
// 覆盖：对话框标题/正文/文件名/按钮、取消不恢复、确认恢复后 SnackBar
// 「恢复成功」、360dp + 2x 大字不溢出。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/services/auto_check_new_backup_scheduler.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/services/webdav_backup_service.dart';
import 'package:flutter_legado/src/services/webdav_restore_service.dart';
import 'package:flutter_legado/src/widgets/auto_check_new_backup_dialog.dart';

class _ListApi extends MockBookApi {
  _ListApi(this.listJson);

  final String listJson;

  @override
  Future<String> webdavListDir(String configJson, String path) async =>
      listJson;
}

class _ConfigService extends WebDavBackupService {
  _ConfigService({required super.api});

  @override
  Future<String?> resolveConfigJson() async => '{"url":"x"}';
}

class _RestoreService extends WebDavRestoreService {
  _RestoreService({required super.api, super.settings});

  int calls = 0;

  @override
  Future<WebDavRestoreRunResult> restoreRemoteBackupExclusive({
    required String remoteName,
    String? configJson,
    String? password,
    Future<void> Function()? refresh,
  }) async {
    calls++;
    if (refresh != null) await refresh();
    return const WebDavRestoreRunResult.success();
  }
}

String _remoteListJson() => jsonEncode([
  {
    'name': 'backup_20261110_120000_123.json',
    'is_dir': false,
    'last_modified': 'Tue, 10 Nov 2026 12:00:00 GMT',
  },
]);

void main() {
  final settings = SettingsService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalBackupService.resetForTest();
    AutoCheckNewBackupScheduler.resetForTest();
  });

  tearDown(() {
    LocalBackupService.resetForTest();
    AutoCheckNewBackupScheduler.resetForTest();
  });

  /// 打开对话框并把结果写入 [onResult]
  Future<void> openDialog(
    WidgetTester tester, {
    required void Function(Future<bool?>) onResult,
    String fileName = 'backup_20261110_120000_123.json',
    double textScale = 1.0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => onResult(
                showAutoCheckNewBackupDialog(context, fileName: fileName),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('内容与按钮文案：标题「恢复」、正文提示 + 文件名', (tester) async {
    late Future<bool?> result;
    await openDialog(tester, onResult: (future) => result = future);

    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('WebDAV 备份比本地新，是否恢复？'), findsOneWidget);
    expect(find.text('backup_20261110_120000_123.json'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('点「确定」返回 true', (tester) async {
    late Future<bool?> result;
    await openDialog(tester, onResult: (future) => result = future);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('点遮罩关闭返回 null（未明确选择）', (tester) async {
    late Future<bool?> result;
    await openDialog(tester, onResult: (future) => result = future);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.byType(AutoCheckNewBackupDialog), findsNothing);
  });

  testWidgets('取消不调用恢复；确认调用恢复并显示「恢复成功」SnackBar', (tester) async {
    final api = _ListApi(_remoteListJson());
    final restore = _RestoreService(api: api, settings: settings);
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    AutoCheckNewBackupScheduler buildScheduler() => AutoCheckNewBackupScheduler(
      api: api,
      settings: settings,
      webDavBackupService: _ConfigService(api: api),
      restoreService: restore,
      confirmRestore: (fileName) => showAutoCheckNewBackupDialog(
        navigatorKey.currentContext!,
        fileName: fileName,
      ),
      notify: (message) async {
        ScaffoldMessenger.of(
          navigatorKey.currentContext!,
        ).showSnackBar(SnackBar(content: Text(message)));
      },
      clock: () => DateTime(2026, 11, 10, 13),
    );

    // 取消：不恢复
    var scheduler = buildScheduler();
    var future = scheduler.checkNow();
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pump();
    await future;
    await tester.pumpAndSettle();
    expect(restore.calls, 0);
    expect(find.text('恢复成功'), findsNothing);

    // 确认：调用恢复并提示成功（去重键已在首次弹窗前写入，这里直接
    // 构造新调度器并清掉 seen 以验证确认分支）
    await settings.setIntPref('lastSeenRemoteBackupMtime', 0);
    scheduler = buildScheduler();
    future = scheduler.checkNow();
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pump();
    await future;
    await tester.pumpAndSettle();
    expect(restore.calls, 1);
    expect(find.text('恢复成功'), findsOneWidget);
  });

  testWidgets('360dp + 2x 大字：长文件名不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late Future<bool?> result;
    await openDialog(
      tester,
      textScale: 2.0,
      fileName: 'backup_20261110_120000_123_这是一个很长很长很长很长很长很长的备份文件名.json',
      onResult: (future) => result = future,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('WebDAV 备份比本地新，是否恢复？'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('autoCheckNewBackupFileName')),
      findsOneWidget,
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });
}
