/// 批10 审查回修：本地长按恢复成功后的远端去重基准
///
/// 恢复成功后写 `lastSeenRemoteBackupMtime=now`，避免下次启动提示恢复一个
/// 比当前数据更旧的 WebDAV 备份；同时不得写 `lastBackup`（自动备份周期
/// 不受影响）。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';
import 'package:flutter_legado/src/services/local_backup_service.dart';

import '../mocks/mocks.dart';

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => result;
}

void _useFakeFilePicker(FilePicker fake) {
  FilePicker? original;
  var initialized = false;
  try {
    original = FilePicker.platform;
    initialized = true;
  } catch (_) {
    // 宿主未初始化（测试 registrant 无本平台分支）
  }
  FilePicker.platform = fake;
  addTearDown(
    () => FilePicker.platform = initialized ? original! : FilePickerIO(),
  );
}

void main() {
  late FakeServersRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    LocalBackupService.resetForTest();
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeServersRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
    when(
      () => mockApi.getBookSources(),
    ).thenAnswer((_) async => <BookSource>[]);
    when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    when(
      () => mockApi.restore(any(), password: any(named: 'password')),
    ).thenAnswer((_) async {});
    when(() => mockApi.backupInspect(any())).thenAnswer(
      (_) async => const BackupInspectInfo(
        format: BackupFormat.zip,
        passwordRequired: false,
        passwordProtectedFiles: [],
      ),
    );
  });

  tearDown(LocalBackupService.resetForTest);

  testWidgets('本地恢复成功写 lastSeenRemoteBackupMtime 且不改 lastBackup', (
    tester,
  ) async {
    final backupPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'legado_backup_seen.zip';
    _useFakeFilePicker(
      _FakeFilePicker(
        FilePickerResult([
          PlatformFile(
            name: 'legado_backup_seen.zip',
            size: 0,
            path: backupPath,
          ),
        ]),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: WebDavSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(find.text('确认恢复吗？'), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('恢复')),
    );
    await tester.pumpAndSettle();

    verify(() => mockApi.restore(backupPath, password: null)).called(1);
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getInt(PrefKeys.lastSeenRemoteBackupMtime);
    expect(seen, isNotNull);
    expect(seen, greaterThan(0));
    expect(prefs.getInt(PrefKeys.lastBackup), isNull, reason: '不得改 lastBackup');
  });
}
