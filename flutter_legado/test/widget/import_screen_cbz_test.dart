/// [cbz 批 C | 2026-10-03] 导入页 cbz 识别与「整本导入不走解压」回归测试
///
/// 覆盖：
/// 1. 格式过滤表包含 .CBZ（新增支持格式，文件浏览器可见可勾选）；
/// 2. .cbz 选中后走 Checkbox → importLocalBook 整本导入，
///    不触发 archiveIsArchive / ArchiveImportDialog 解压路径；
/// 3. 对照：.zip 仍走 ArchiveImportDialog 解压路径（钉住格式判定不漂移）。
///
/// path_provider 经 PathProviderPlatform 平台桩注入临时文档目录；
/// BookApi 经 MockRustApi 注入（importLocalBook 捕获实参）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

// path_provider 平台接口为传递依赖，测试直引以覆写 instance 保持 hermetic，
// 不改 pubspec（同 reader_comic_click_actions_test 桩模式）
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/archive_import_dialog.dart';
import 'package:flutter_legado/src/screens/import_screen.dart';

import '../mocks/mocks.dart';

/// path_provider 平台桩：文档目录固定返回 [docDir]（其余默认实现）；
/// 外置存储返回 null（对齐非 Android 宿主，导入页仅单一根目录）
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docDir);
  final String docDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docDir;

  @override
  Future<String?> getExternalStoragePath() async => null;
}

void main() {
  setUpAll(registerFallbacks);

  late Directory tempDir;
  late MockRustApi api;
  late List<String> importedPaths;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('import_cbz_test_');
    String inTemp(String name) =>
        '${tempDir.path}${Platform.pathSeparator}$name';
    File(inTemp('本地漫画.cbz')).writeAsBytesSync(List<int>.filled(64, 0));
    File(inTemp('合集包.zip')).writeAsBytesSync(List<int>.filled(64, 0));
    File(inTemp('普通小说.txt')).writeAsStringSync('正文');

    final originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    addTearDown(() => PathProviderPlatform.instance = originalProvider);

    api = MockRustApi();
    importedPaths = <String>[];
    when(() => api.getBooks()).thenAnswer((_) async => <Book>[]);
    when(() => api.getBookGroups()).thenAnswer((_) async => <BookGroup>[]);
    when(() => api.importLocalBook(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      importedPaths.add(path);
      // 与 Rust importLocalBook 对齐：cbz → LOCAL|image（本测试仅路径为 cbz）
      return Book(
        bookUrl: path,
        name: '本地漫画',
        author: '本地导入',
        origin: BookType.localTag,
        bookType: BookType.local | BookType.image,
      );
    });
    when(
      () => api.archiveIsArchive(filePath: any(named: 'filePath')),
    ).thenAnswer((_) async => true);
    when(
      () => api.archiveListZipFiles(zipPath: any(named: 'zipPath')),
    ).thenAnswer((_) async => <String>[]);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget harness() => ProviderScope(
    overrides: [bookApiProvider.overrideWithValue(api)],
    child: const MaterialApp(home: ImportScreen()),
  );

  /// pump 导入页并等待目录扫描完成。
  ///
  /// 扫描走真实 dart:io（testWidgets fake async 时钟不驱动文件 IO），
  /// 需经 [WidgetTester.runAsync] 放行真实事件循环，再逐帧 pump 直到
  /// 文件行出现（有界轮询，避免 LoadingIndicator 动画导致 settle 超时）。
  Future<void> pumpImportScreen(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(harness());
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (tester.any(find.text('本地漫画.cbz'))) break;
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('格式过滤表包含 .CBZ（cbz 进入可浏览导入格式）', (tester) async {
    await pumpImportScreen(tester);

    // 格式条为横向懒加载 ListView：滚动到 .CBZ 确保其被构建
    final cbzChip = find.text('.CBZ');
    await tester.scrollUntilVisible(
      cbzChip,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(cbzChip, findsOneWidget);
  });

  testWidgets('cbz 走勾选整本导入（importLocalBook），不触发解压路径', (tester) async {
    await pumpImportScreen(tester);

    // cbz 以 Checkbox 多选行呈现（非压缩包行）
    expect(find.text('本地漫画.cbz'), findsOneWidget);
    await tester.tap(find.text('本地漫画.cbz'));
    await tester.pump();

    // 选中 cbz 不弹压缩包对话框
    expect(find.byType(ArchiveImportDialog), findsNothing);
    verifyNever(() => api.archiveIsArchive(filePath: any(named: 'filePath')));

    // 放入书架 → 走 importLocalBook 整本导入
    await tester.tap(find.textContaining('放入书架'));
    await tester.pumpAndSettle();

    expect(importedPaths, hasLength(1));
    expect(importedPaths.single, endsWith('本地漫画.cbz'));
    // 全程未触碰解压判定/对话框
    verifyNever(() => api.archiveIsArchive(filePath: any(named: 'filePath')));
    expect(find.byType(ArchiveImportDialog), findsNothing);
  });

  testWidgets('对照：zip 仍走 ArchiveImportDialog 解压路径', (tester) async {
    await pumpImportScreen(tester);

    await tester.tap(find.text('合集包.zip'));
    await tester.pumpAndSettle();

    verify(
      () => api.archiveIsArchive(filePath: any(named: 'filePath')),
    ).called(1);
    expect(find.byType(ArchiveImportDialog), findsOneWidget);
    // 压缩包内文件导入走对话框，不直接整本导入压缩包本身
    expect(importedPaths, isEmpty);
  });
}
