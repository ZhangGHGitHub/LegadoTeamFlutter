/// [cbz P1-1 回归 | 2026-10-03] 书架「添加本地」入口白名单测试
///
/// 背景（QA 真机证据 .tmp/cbz_qa/step10_picker_control.xml）：
/// 书架溢出菜单「添加本地」→ file_picker（FileType.custom）白名单缺 cbz，
/// Android 侧经 MimeTypeMap 过滤后 DocumentsUI 将 .cbz 置灰
/// （enabled="false"），UI 无法导入 cbz；而 import_screen.dart 的
/// _supportedFormats 已含 cbz（批 C）——两处白名单漂移导致回归。
///
/// 本用例直接走真实书架入口：
/// 更多菜单 → 添加本地 → 捕获 FilePicker.pickFiles 实参，
/// 断言 allowedExtensions 与 import_screen._supportedFormats 同序同集合
/// （含 cbz；且不含走压缩包解压链路的 zip/rar/7z）。
/// 修复前（['epub','txt','mobi','pdf','umd']）本用例必红。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

/// 记录 pickFiles 实参的 FilePicker 桩；返回 null = 用户取消，
/// 不进入 importLocalBook/FFI 链路（本用例只钉白名单，不测导入）。
class _RecordingFilePicker extends FilePicker {
  int pickCalls = 0;
  FileType? capturedType;
  List<String>? capturedAllowedExtensions;
  bool? capturedAllowMultiple;

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
    capturedType = type;
    capturedAllowedExtensions = allowedExtensions;
    capturedAllowMultiple = allowMultiple;
    return null;
  }
}

/// 注入 FilePicker 平台桩并登记恢复（同 reader_comic_click_actions_test
/// 现有桩模式；宿主若未初始化则回退 [FilePickerIO]）
void _useFakeFilePicker(FilePicker fake) {
  FilePicker? original;
  var initialized = false;
  try {
    original = FilePicker.platform;
    initialized = true;
  } catch (_) {
    // late 未初始化（测试宿主 registrant 无本平台分支）
  }
  FilePicker.platform = fake;
  addTearDown(
    () => FilePicker.platform = initialized ? original! : FilePickerIO(),
  );
}

void main() {
  late MockRustApi api;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    when(() => api.getBooks()).thenAnswer((_) async => <Book>[]);
    when(() => api.getBookGroups()).thenAnswer((_) async => <BookGroup>[]);
  });

  /// pump 真实书架页并等待 Notifier 初始加载落定
  Future<void> pumpShelf(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: BookshelfScreen()),
      ),
    );
    // _loadSettings/_loadBooks/_loadGroups 微任务落定
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('书架「更多 → 添加本地」白名单与导入页一致且含 cbz', (tester) async {
    final fake = _RecordingFilePicker();
    _useFakeFilePicker(fake);
    await pumpShelf(tester);

    // 打开顶栏「⋮ 更多」自绘菜单
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // 点击「添加本地」→ _addLocalBook → FilePicker.pickFiles
    expect(
      find.text(AppStrings.addLocalBook),
      findsOneWidget,
      reason: '溢出菜单应含「添加本地」入口',
    );
    await tester.tap(find.text(AppStrings.addLocalBook));
    await tester.pumpAndSettle();

    expect(fake.pickCalls, 1, reason: '「添加本地」应触发一次文件选择');
    // Windows 测试宿主 Platform.isIOS=false → 走 Android custom 白名单分支
    expect(fake.capturedType, FileType.custom);
    expect(fake.capturedAllowMultiple, isTrue);

    final exts = fake.capturedAllowedExtensions;
    expect(exts, isNotNull, reason: 'custom 分支必须携带 allowedExtensions');
    expect(
      exts,
      contains('cbz'),
      reason: '[P1-1] 白名单缺 cbz → DocumentsUI 将 .cbz 置灰，UI 无法导入',
    );
    expect(
      exts,
      equals(const ['epub', 'txt', 'mobi', 'azw3', 'azw', 'pdf', 'umd', 'cbz']),
      reason: '须与 import_screen.dart::_supportedFormats 同序同集合（互指注释）',
    );
    // 压缩包格式走 ImportScreen 解压导入链路，不属于整本导入白名单
    for (final archive in const ['zip', 'rar', '7z']) {
      expect(exts, isNot(contains(archive)));
    }
  });
}
