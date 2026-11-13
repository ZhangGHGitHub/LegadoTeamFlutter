/// [批24 | 2026-10-27] 7z 解压导入对话框组件测试
///
/// 覆盖：
/// 1. 7z → 调 archiveList7zFiles 并展示书籍列表（默认全选）；
/// 2. 7z 不显示 RAR 密码框；
/// 3. 确认导入调用 archiveImport7z，outputDir 以 archive_import 结尾；
/// 4. 列表失败 → 错误态与重试入口；
/// 5. [P1-1] 部分文件导入失败时结果提示分列成功/失败数与失败书名、原因，
///    不把失败计入「成功导入 N 本」；全成功时提示正常；
/// 6. [批28 P2-1] 全失败/零处理/零解压文件不得提示「成功导入」；
/// 7. [批28 P2-2] 导入期间禁用勾选、编码与检测入口，总数起始快照；
/// 8. [批28 P2-3] 编码转换后使用 output_path 导入，转换失败计入失败明细；
/// 9. [批28 P3-6/P3-7/P3-8] 失败明细不泄漏 RustApiException 类名，
///    多失败只展示首条 + 「另有 N-1 本」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

// path_provider 平台接口为传递依赖，测试直引以覆写 instance 保持 hermetic
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/archive_import_dialog.dart';
import 'package:flutter_legado/src/services/rust_api.dart' show RustApiException;

import '../mocks/mocks.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docDir);
  final String docDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docDir;
}

void main() {
  setUpAll(registerFallbacks);

  late Directory tempDir;
  late MockRustApi api;
  /// 需要让 importLocalBook 抛错的文件名（P1-1 部分失败用例）
  late Set<String> failNames;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('archive_dialog_7z_');
    final originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    addTearDown(() => PathProviderPlatform.instance = originalProvider);

    failNames = <String>{};
    api = MockRustApi();
    when(() => api.getBooks()).thenAnswer((_) async => <Book>[]);
    when(() => api.getBookGroups()).thenAnswer((_) async => <BookGroup>[]);
    when(() => api.importLocalBook(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      final name = path.split(Platform.pathSeparator).last;
      if (failNames.contains(name)) {
        throw const BridgeError(message: '文件损坏，无法解析');
      }
      return Book(
        bookUrl: path,
        name: name,
        author: '本地导入',
        origin: BookType.localTag,
        bookType: BookType.local,
      );
    });
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget harness(String archivePath) {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ArchiveImportDialog(archivePath: archivePath),
                ),
                child: const Text('打开压缩包'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester, String path) async {
    await tester.pumpWidget(harness(path));
    await tester.tap(find.text('打开压缩包'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('7z 列表展示、默认全选且不显示密码框', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['book1.txt', 'book2.epub']);

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');

    expect(find.text('book1.txt'), findsOneWidget);
    expect(find.text('book2.epub'), findsOneWidget);
    // 默认全选：导入按钮计数 = 文件数
    expect(find.text('导入 (2)'), findsOneWidget);
    // 7z 不支持加密：不渲染密码框
    expect(find.byType(TextField), findsNothing);
    verify(
      () => api.archiveList7zFiles(
        sevenZipPath: any(named: 'sevenZipPath'),
      ),
    ).called(1);
  });

  testWidgets('确认导入调用 archiveImport7z 且 outputDir 以 archive_import 结尾', (
    tester,
  ) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['book1.txt']);
    String? capturedPath;
    String? capturedOutputDir;
    when(
      () => api.archiveImport7z(
        sevenZipPath: any(named: 'sevenZipPath'),
        outputDir: any(named: 'outputDir'),
      ),
    ).thenAnswer((invocation) async {
      capturedPath =
          invocation.namedArguments[#sevenZipPath] as String?;
      capturedOutputDir = invocation.namedArguments[#outputDir] as String?;
      return <String, dynamic>{
        'success': true,
        'extracted_files': <String>[
          '$capturedOutputDir${Platform.pathSeparator}book1.txt',
        ],
        'error': null,
      };
    });

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    expect(find.text('导入 (1)'), findsOneWidget);

    // 确认导入含真实目录 IO（getApplicationDocumentsDirectory + create），
    // 需 runAsync 放行真实事件循环；有界轮询避免动画拖满超时
    await tester.runAsync(() async {
      await tester.tap(find.text('导入 (1)'));
      for (var i = 0; i < 50 && capturedOutputDir == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(capturedPath, endsWith('books.7z'));
    expect(capturedOutputDir, isNotNull);
    expect(capturedOutputDir!.endsWith('archive_import'), isTrue,
        reason: capturedOutputDir);
  });

  testWidgets('7z 列表失败展示错误态与重试', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenThrow(Exception('7z列表失败: 文件损坏'));

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}bad.7z');

    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  /// 点击导入并等待结果 SnackBar 出现
  ///
  /// 确认导入含真实目录 IO（getApplicationDocumentsDirectory + create）与
  /// 异步刷新，需 runAsync 放行真实事件循环；有界轮询避免动画拖满超时。
  Future<void> tapImportAndWaitForResult(
    WidgetTester tester, {
    required String buttonText,
    required String expectedText,
  }) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(buttonText));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.textContaining(expectedText).evaluate().isNotEmpty) break;
      }
    });
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('P1-1 部分文件失败：不计入成功数，提示失败书名与原因', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['good.txt', 'bad1.txt', 'bad2.txt']);
    when(
      () => api.archiveImport7z(
        sevenZipPath: any(named: 'sevenZipPath'),
        outputDir: any(named: 'outputDir'),
      ),
    ).thenAnswer((invocation) async {
      final outputDir = invocation.namedArguments[#outputDir] as String;
      return <String, dynamic>{
        'success': true,
        'extracted_files': <String>[
          '$outputDir${Platform.pathSeparator}good.txt',
          '$outputDir${Platform.pathSeparator}bad1.txt',
          '$outputDir${Platform.pathSeparator}bad2.txt',
        ],
        'error': null,
      };
    });
    // 两个文件导入抛错（模拟损坏/权限/主键冲突/DB 失败）
    failNames.addAll(['bad1.txt', 'bad2.txt']);

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (3)',
      expectedText: '本失败',
    );

    // 失败不得被计入成功数（修复前提示「成功导入 3 本书籍」）
    expect(
      find.textContaining('成功导入 3'),
      findsNothing,
      reason: '失败的 2 本不能计入成功数',
    );
    // 成功/失败分列，含首个失败书名与原因（BridgeError 走 errorMessage）
    expect(
      find.textContaining('成功导入 1 本，2 本失败：bad1.txt：文件损坏，无法解析'),
      findsOneWidget,
    );
    // P3-7：多条失败只展示首条，其余条数以「另有 N-1 本」汇总
    expect(find.textContaining('（另有 1 本）'), findsOneWidget);
    expect(find.textContaining('等 2 本'), findsNothing);
    // BridgeError 无 toString()，不得显示类型名
    expect(find.textContaining("Instance of 'BridgeError'"), findsNothing);
    // 失败文件保留位置可定位（应用文档/archive_import）
    expect(find.textContaining('archive_import'), findsOneWidget);

    // 走完 SnackBar 计时器，避免用例结束残留 pending timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P1-1 全部成功：提示成功导入 N 本书籍', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['good1.txt', 'good2.txt']);
    when(
      () => api.archiveImport7z(
        sevenZipPath: any(named: 'sevenZipPath'),
        outputDir: any(named: 'outputDir'),
      ),
    ).thenAnswer((invocation) async {
      final outputDir = invocation.namedArguments[#outputDir] as String;
      return <String, dynamic>{
        'success': true,
        'extracted_files': <String>[
          '$outputDir${Platform.pathSeparator}good1.txt',
          '$outputDir${Platform.pathSeparator}good2.txt',
        ],
        'error': null,
      };
    });

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (2)',
      expectedText: '成功导入 2 本书籍',
    );

    expect(find.text('成功导入 2 本书籍'), findsOneWidget);
    expect(find.textContaining('本失败'), findsNothing);

    // 走完 SnackBar 计时器，避免用例结束残留 pending timer
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  /// 解压结果 stub：按文件名返回 outputDir 下的解压路径
  void stub7zExtracted(List<String> names) {
    when(
      () => api.archiveImport7z(
        sevenZipPath: any(named: 'sevenZipPath'),
        outputDir: any(named: 'outputDir'),
      ),
    ).thenAnswer((invocation) async {
      final outputDir = invocation.namedArguments[#outputDir] as String;
      return <String, dynamic>{
        'success': true,
        'extracted_files': <String>[
          for (final name in names) '$outputDir${Platform.pathSeparator}$name',
        ],
        'error': null,
      };
    });
  }

  /// 选择 TXT 编码下拉项（打开菜单后点选目标编码）
  Future<void> selectEncoding(WidgetTester tester, String encoding) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(encoding).last);
    await tester.pumpAndSettle();
  }

  testWidgets('P3-8 全部失败：提示「导入失败：」且不出现「成功导入」', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['bad1.txt', 'bad2.txt', 'bad3.txt']);
    stub7zExtracted(['bad1.txt', 'bad2.txt', 'bad3.txt']);
    failNames.addAll(['bad1.txt', 'bad2.txt', 'bad3.txt']);

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (3)',
      expectedText: '导入失败：',
    );

    expect(find.textContaining('导入失败：'), findsOneWidget);
    // 全失败不得出现任何「成功导入」字样（修复前提示「成功导入 0 本书籍」）
    expect(find.textContaining('成功导入'), findsNothing);
    // P3-7：首条明细 + 其余条数
    expect(find.textContaining('（另有 2 本）'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P3-7 单条失败不出现「等 N 本」/「另有 0 本」', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['good.txt', 'bad.txt']);
    stub7zExtracted(['good.txt', 'bad.txt']);
    failNames.add('bad.txt');

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (2)',
      expectedText: '本失败',
    );

    expect(
      find.textContaining('成功导入 1 本，1 本失败：bad.txt：文件损坏，无法解析'),
      findsOneWidget,
    );
    expect(find.textContaining('等 1 本'), findsNothing);
    expect(find.textContaining('另有 0 本'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P2-1 解压成功但零文件：提示未解压出可导入文件', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['book.txt']);
    stub7zExtracted(const []);

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (1)',
      expectedText: '压缩包内未解压出可导入文件',
    );

    expect(find.textContaining('压缩包内未解压出可导入文件'), findsOneWidget);
    expect(find.textContaining('成功导入'), findsNothing);
    expect(find.textContaining('未导入任何文件'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P2-1 零处理：选中与解压结果不匹配时提示未导入任何文件', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['selected.txt']);
    // 解压结果里没有选中文件：成功数 0、失败数 0
    stub7zExtracted(['other.txt']);

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (1)',
      expectedText: '未导入任何文件',
    );

    expect(find.textContaining('未导入任何文件（已选 1 本）'), findsOneWidget);
    expect(find.textContaining('成功导入'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P2-3 编码转换成功：使用 output_path 导入，编码选择生效', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['book.txt']);
    stub7zExtracted(['book.txt']);

    when(
      () => api.archiveConvertEncoding(
        filePath: any(named: 'filePath'),
        fromEncoding: any(named: 'fromEncoding'),
        toEncoding: any(named: 'toEncoding'),
      ),
    ).thenAnswer((invocation) async {
      final filePath = invocation.namedArguments[#filePath] as String;
      return <String, dynamic>{
        'success': true,
        'output_path': '$filePath.converted',
        'error': null,
      };
    });

    final importedPaths = <String>[];
    when(() => api.importLocalBook(any())).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      importedPaths.add(path);
      return Book(
        bookUrl: path,
        name: path.split(Platform.pathSeparator).last,
        author: '本地导入',
        origin: BookType.localTag,
        bookType: BookType.local,
      );
    });

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await selectEncoding(tester, 'GBK');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (1)',
      expectedText: '成功导入 1 本书籍',
    );

    verify(
      () => api.archiveConvertEncoding(
        filePath: any(named: 'filePath'),
        fromEncoding: 'GBK',
        toEncoding: 'utf-8',
      ),
    ).called(1);
    // 修复前转换结果被丢弃，导入的是原文件（编码选择完全无效）
    expect(importedPaths, hasLength(1));
    expect(importedPaths.single, endsWith('book.txt.converted'));

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P2-3 编码转换失败：计入失败明细，不静默导入原文件', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['book.txt']);
    stub7zExtracted(['book.txt']);
    when(
      () => api.archiveConvertEncoding(
        filePath: any(named: 'filePath'),
        fromEncoding: any(named: 'fromEncoding'),
        toEncoding: any(named: 'toEncoding'),
      ),
    ).thenAnswer(
      (_) async => <String, dynamic>{
        'success': false,
        'output_path': null,
        'error': '编码转换失败: 源文件包含无法以 GBK 解码的字节',
      },
    );

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await selectEncoding(tester, 'GBK');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (1)',
      expectedText: '编码转换失败',
    );

    expect(find.textContaining('导入失败：book.txt：编码转换失败'), findsOneWidget);
    expect(find.textContaining('成功导入'), findsNothing);
    // 转换失败时不得退回导入原文件（否则用户选择的编码形同虚设）
    verifyNever(() => api.importLocalBook(any()));

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P3-6 RustApiException 失败明细只显示 message', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['book.txt']);
    stub7zExtracted(['book.txt']);
    when(() => api.importLocalBook(any())).thenAnswer(
      (_) async => throw const RustApiException(
        '书籍内容为空',
        operation: 'importLocalBook',
      ),
    );

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');
    await tapImportAndWaitForResult(
      tester,
      buttonText: '导入 (1)',
      expectedText: '导入失败：',
    );

    expect(find.textContaining('导入失败：book.txt：书籍内容为空'), findsOneWidget);
    // 内部类名与 operation 不得泄漏到用户可见文案
    expect(find.textContaining('RustApiException'), findsNothing);
    expect(find.textContaining('operation: importLocalBook'), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('P2-2 导入期间禁用勾选/编码/检测，总数按起始快照', (tester) async {
    when(() => api.archiveList7zFiles(sevenZipPath: any(named: 'sevenZipPath')))
        .thenAnswer((_) async => ['a.txt', 'b.txt']);
    final extract = Completer<Map<String, dynamic>>();
    when(
      () => api.archiveImport7z(
        sevenZipPath: any(named: 'sevenZipPath'),
        outputDir: any(named: 'outputDir'),
      ),
    ).thenAnswer((_) => extract.future);

    await openDialog(tester, '${tempDir.path}${Platform.pathSeparator}books.7z');

    // 解压挂起期间：导入中，总数已按起始快照固定为 2
    await tester.runAsync(() async {
      await tester.tap(find.text('导入 (2)'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    });
    await tester.pump();
    expect(find.text('导入中 0/2'), findsOneWidget);

    // 列表勾选、编码下拉、检测编码按钮全部禁用（不得在导入中改输入）
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );

    // P2-2 ③：点击遮罩不得关闭对话框（否则导入结果提示会丢失）
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ArchiveImportDialog), findsOneWidget);

    // 收尾：完成解压（零文件）并走完提示
    await tester.runAsync(() async {
      extract.complete(<String, dynamic>{
        'success': true,
        'extracted_files': <String>[],
        'error': null,
      });
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.textContaining('未解压出可导入文件').evaluate().isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
