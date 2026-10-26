/// 备份恢复前确认对话框（批7b）
///
/// 恢复为覆盖语义（对齐原版 Restore.kt 全列更新）：备份中的阅读进度与
/// 书籍信息会覆盖书架中已有书籍。本测试钉住：
/// - 恢复前后弹确认框，文案明确覆盖已有书进度与书籍信息；
/// - 取消 → 不触发恢复链（WebDAV / 本地均不执行）；
/// - 确认 → 执行原恢复链。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';

import '../mocks/mocks.dart';

/// 记录 pickFiles 调用并返回预置结果的 FilePicker 桩
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;
  int pickCalls = 0;

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
  }) async {
    pickCalls++;
    return result;
  }
}

/// 注入 FilePicker 平台桩并登记恢复（同 bookshelf_add_local_cbz_test 模式）
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
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => <BookSource>[]);
    when(() => mockApi.restore(any())).thenAnswer((_) async {});
  });

  /// 配置 WebDAV（isConfigured 要求地址/账号/密码均非空）
  void configureWebDav() {
    SharedPreferences.setMockInitialValues({
      'sync_webdav_url': 'https://dav.example.com',
      'sync_webdav_username': 'user',
      'sync_webdav_password': 'pass',
    });
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: WebDavSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> longPressRestoreTile(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.longPress(find.text('恢复'));
    await tester.pumpAndSettle();
  }

  Finder dialogButton(String label) => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(label),
      );

  testWidgets('恢复前确认：文案明确覆盖已有书进度与书籍信息', (tester) async {
    configureWebDav();
    await pumpScreen(tester);

    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(find.text('确认恢复吗？'), findsOneWidget);
    expect(
      find.text('恢复书架会覆盖现有书架，包括已有书籍的阅读进度与书籍信息。确定继续吗？'),
      findsOneWidget,
    );
    expect(dialogButton('取消'), findsOneWidget);
    expect(dialogButton('恢复'), findsOneWidget);
  });

  testWidgets('取消恢复：不触发 WebDAV 恢复链', (tester) async {
    configureWebDav();
    await pumpScreen(tester);

    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    await tester.tap(dialogButton('取消'));
    await tester.pumpAndSettle();

    verifyNever(() => mockApi.webdavFullSync(any(), any(), any()));
    expect(find.text('恢复中…'), findsNothing);
  });

  testWidgets('确认恢复：执行 WebDAV 恢复链', (tester) async {
    configureWebDav();
    when(
      () => mockApi.webdavFullSync(any(), any(), any()),
    ).thenAnswer((_) async => '{"sources":"[]"}');
    await pumpScreen(tester);

    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    await tester.tap(dialogButton('恢复'));
    await tester.pumpAndSettle();

    verify(() => mockApi.webdavFullSync(any(), any(), any())).called(1);
    expect(find.text('恢复完成，回写 0 条书源'), findsOneWidget);
  });

  testWidgets('取消本地恢复：不打开文件选择、不调用 restore', (tester) async {
    final picker = _FakeFilePicker(null);
    _useFakeFilePicker(picker);
    await pumpScreen(tester);

    await longPressRestoreTile(tester);

    expect(find.text('确认恢复吗？'), findsOneWidget);
    await tester.tap(dialogButton('取消'));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 0, reason: '取消恢复不应继续走文件选择');
    verifyNever(() => mockApi.restore(any()));
  });

  testWidgets('确认本地恢复：选择文件后调用 restore', (tester) async {
    // 用 .zip 路径避免恢复前的 JSON 偏好读取（真实文件 IO），
    // 本用例只钉「确认 → 进入原恢复链并调用 restore」
    final backupPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}legado_backup.zip';
    final picker = _FakeFilePicker(
      FilePickerResult([
        PlatformFile(name: 'backup.zip', size: 0, path: backupPath),
      ]),
    );
    _useFakeFilePicker(picker);
    await pumpScreen(tester);

    await longPressRestoreTile(tester);
    await tester.tap(dialogButton('恢复'));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    verify(() => mockApi.restore(backupPath)).called(1);
  });
}
