/// 备份恢复确认对话框（批7b/批7c）
///
/// 短按「恢复」= WebDAV 同步（上传本地书架覆盖远端 + 回写远端书源），
/// 长按「恢复」= 本地恢复（用备份覆盖本地阅读进度与书籍信息）。
/// 本测试钉住：
/// - 两个入口的确认文案与实际数据方向一致；
/// - WebDAV 未配置时短按只提示、不弹确认；
/// - 本地恢复先选文件后确认：取消选择/取消确认均不触发 restore；
/// - 确认后执行对应恢复链。
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

/// 记录 pickFiles 调用/参数并返回预置结果的 FilePicker 桩
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;
  int pickCalls = 0;
  FileType? lastType;
  List<String>? lastAllowedExtensions;

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
    lastType = type;
    lastAllowedExtensions = allowedExtensions;
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
  late FakeServersRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeServersRustApi();
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

  Future<void> tapRestoreTile(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('恢复'), 100);
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
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

  /// 造一个 .json 备份文件路径（不落盘；恢复链的偏好读取异常会被吞掉）
  String fakeBackupPath(String name) =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}$name';

  testWidgets('短按恢复：文案说明上传本地覆盖远端、不覆盖本地进度', (tester) async {
    configureWebDav();
    await pumpScreen(tester);

    await tapRestoreTile(tester);

    expect(find.text('确认同步吗？'), findsOneWidget);
    expect(
      find.text(
        '将上传本地书架并覆盖远端备份（bookshelf.json），同时回写远端书源；'
        '不会覆盖本地阅读进度。如需从备份覆盖本地，请使用长按本地恢复。',
      ),
      findsOneWidget,
    );
    expect(dialogButton('取消'), findsOneWidget);
    expect(dialogButton('同步'), findsOneWidget);
    // 短按入口不得复用本地恢复文案（会误导用户以为覆盖本地进度）
    expect(find.text('确认恢复吗？'), findsNothing);
  });

  testWidgets('取消 WebDAV 同步：不触发恢复链', (tester) async {
    configureWebDav();
    await pumpScreen(tester);

    await tapRestoreTile(tester);
    await tester.tap(dialogButton('取消'));
    await tester.pumpAndSettle();

    verifyNever(() => mockApi.webdavFullSync(any(), any(), any()));
    expect(find.text('恢复中…'), findsNothing);
  });

  testWidgets('确认 WebDAV 同步：执行 webdavFullSync', (tester) async {
    configureWebDav();
    when(
      () => mockApi.webdavFullSync(any(), any(), any()),
    ).thenAnswer((_) async => '{"sources":"[]"}');
    await pumpScreen(tester);

    await tapRestoreTile(tester);
    await tester.tap(dialogButton('同步'));
    await tester.pumpAndSettle();

    verify(() => mockApi.webdavFullSync(any(), any(), any())).called(1);
    expect(find.text('恢复完成，回写 0 条书源'), findsOneWidget);
  });

  testWidgets('WebDAV 未配置：短按只提示长按本地恢复、不弹确认', (tester) async {
    await pumpScreen(tester);

    await tapRestoreTile(tester);

    expect(find.text('未配置 WebDAV，请长按「恢复」从本地恢复'), findsOneWidget);
    expect(find.text('确认同步吗？'), findsNothing);
    expect(find.text('确认恢复吗？'), findsNothing);
    verifyNever(() => mockApi.webdavFullSync(any(), any(), any()));
    verifyNever(() => mockApi.restore(any()));
  });

  testWidgets('本地恢复取消选择文件：不弹确认、不调用 restore', (tester) async {
    final picker = _FakeFilePicker(null);
    _useFakeFilePicker(picker);
    await pumpScreen(tester);

    await longPressRestoreTile(tester);

    expect(picker.pickCalls, 1);
    expect(find.text('确认恢复吗？'), findsNothing);
    verifyNever(() => mockApi.restore(any()));
    expect(find.text('恢复中…'), findsNothing);
  });

  testWidgets('取消本地恢复：选文件后取消确认，不调用 restore', (tester) async {
    final picker = _FakeFilePicker(
      FilePickerResult([
        PlatformFile(
          name: 'backup.json',
          size: 0,
          path: fakeBackupPath('legado_backup_cancel.json'),
        ),
      ]),
    );
    _useFakeFilePicker(picker);
    await pumpScreen(tester);

    await longPressRestoreTile(tester);

    expect(picker.pickCalls, 1);
    expect(find.text('确认恢复吗？'), findsOneWidget);
    await tester.tap(dialogButton('取消'));
    await tester.pumpAndSettle();

    verifyNever(() => mockApi.restore(any()));
    expect(find.text('恢复中…'), findsNothing);
  });

  testWidgets('确认本地恢复：选择器仅允许 .json，选择文件后调用 restore', (tester) async {
    // widget 测试的 FakeAsync 不驱动真实文件 IO：走 .json 备份会触发
    // RestoreIgnorePrefs 的真实读取而挂起，故恢复执行链用 .zip 桩路径；
    // 选择器约束改由 lastType/lastAllowedExtensions 直接断言。
    final backupPath = fakeBackupPath('legado_backup_ok.zip');
    final picker = _FakeFilePicker(
      FilePickerResult([
        PlatformFile(name: 'backup.zip', size: 0, path: backupPath),
      ]),
    );
    _useFakeFilePicker(picker);
    await pumpScreen(tester);

    await longPressRestoreTile(tester);
    expect(find.text('确认恢复吗？'), findsOneWidget);
    await tester.tap(dialogButton('恢复'));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    expect(picker.lastType, FileType.custom);
    expect(picker.lastAllowedExtensions, ['json']);
    verify(() => mockApi.restore(backupPath)).called(1);
  });
}
