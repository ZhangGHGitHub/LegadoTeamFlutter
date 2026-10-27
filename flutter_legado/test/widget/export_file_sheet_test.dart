// 通用导出目标 Sheet widget 测试（批16c）
//
// 覆盖：选项渲染 / 保存成功（路径回传）/ 系统另存取消 / 保存失败（真实
// 错误 + 复制 + 重试）/ 上传成功（URL + 规则注释 + 复制 + 完成回传）/
// 上传导入中 / 上传失败（真实错误 + 重试）/ 已保存规则优先。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// path_provider 平台接口为传递依赖，测试直引以覆写 instance 保持 hermetic，
// 不改 pubspec（同 import_screen_cbz_test / export_entries_sheet_test 桩模式）
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/direct_link_upload_rule_service.dart';
import 'package:flutter_legado/src/services/export_file_service.dart';
import 'package:flutter_legado/src/services/file_save_channel.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/source_share_passphrase.dart';
import 'package:flutter_legado/src/widgets/export_file_sheet.dart';

/// 捕获 directLinkUpload 入参的 Mock（配置读写沿用 MockBookApi 内存实现）
class _CapturingBookApi extends MockBookApi {
  final List<Map<String, Object?>> uploadCalls = [];
  Object? uploadError;
  String uploadResult = 'https://download.example/rssSources.json';

  /// 非空时上传挂起，用于断言「正在上传」状态
  Completer<String>? uploadCompleter;

  @override
  Future<String> directLinkUpload({
    required String ruleJson,
    required String fileName,
    required String contentType,
    String? content,
    String? filePath,
  }) async {
    uploadCalls.add(<String, Object?>{
      'ruleJson': ruleJson,
      'fileName': fileName,
      'contentType': contentType,
      'content': content,
      'filePath': filePath,
    });
    final completer = uploadCompleter;
    if (completer != null) return completer.future;
    final error = uploadError;
    if (error != null) throw error;
    return uploadResult;
  }
}

/// 落盘服务桩：记录入参并模拟成功/取消/异常
class _FakeExportFileService extends ExportFileService {
  String? savePath = r'C:\temp\rssSources.json';
  Object? saveError;
  int saveCalls = 0;
  String? lastFileName;
  String? lastContent;

  /// 批26：目录树参数与保存位置
  bool? lastUseTree;
  bool? lastChooseTree;
  int chooseDirectoryCalls = 0;
  Object? chooseDirectoryError;
  SaveTreeSelection? chosenTree;

  /// 已记住的保存目录（initState 读取，用于展示当前保存位置）
  SaveTreeSelection? rememberedTree;

  /// 成功回传的目录树信息（用于断言提示文案回显实际目录）
  String? savedFileName;
  bool savedViaTree = false;
  String? savedDisplayPath;

  /// filePath 模式：既有文件另存
  String? existingSavePath = r'C:\temp\skin.zip';
  Object? existingSaveError;
  int existingSaveCalls = 0;
  String? lastSourcePath;

  @override
  Future<SaveFileResult?> saveToLocal({
    required String fileName,
    required String content,
    bool useTree = true,
    bool chooseTree = false,
  }) async {
    saveCalls++;
    lastFileName = fileName;
    lastContent = content;
    lastUseTree = useTree;
    lastChooseTree = chooseTree;
    final error = saveError;
    if (error != null) throw error;
    final path = savePath;
    return path == null
        ? null
        : SaveFileResult(
            location: path,
            fileName: savedFileName,
            viaTree: savedViaTree,
            displayPath: savedDisplayPath,
          );
  }

  @override
  Future<SaveFileResult?> saveExistingFile({
    required String sourcePath,
    required String fileName,
    bool useTree = true,
    bool chooseTree = false,
  }) async {
    existingSaveCalls++;
    lastSourcePath = sourcePath;
    lastFileName = fileName;
    lastUseTree = useTree;
    lastChooseTree = chooseTree;
    final error = existingSaveError;
    if (error != null) throw error;
    final path = existingSavePath;
    return path == null ? null : SaveFileResult(location: path);
  }

  @override
  Future<SaveTreeSelection?> chooseSaveDirectory() async {
    chooseDirectoryCalls++;
    final error = chooseDirectoryError;
    if (error != null) throw error;
    return chosenTree;
  }

  @override
  Future<SaveTreeSelection?> rememberedSaveDirectory() async => rememberedTree;
}

/// 异步结果容器（Sheet 关闭后才回填）
class _ResultBox {
  ExportFileResult? value;
  bool completed = false;
}

/// path_provider 平台桩：临时目录指向测试临时目录
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.tempPath);

  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

/// FilePicker 系统另存桩：返回固定目标路径（桌面分支由服务自身写盘）
class _SaveFilePickerStub extends FilePicker {
  _SaveFilePickerStub(this.targetPath);

  final String? targetPath;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    return targetPath;
  }
}

/// 注入 FilePicker 平台桩并登记恢复（同 bookshelf_add_local_cbz_test 桩模式）
void _useFakeSaveFilePicker(FilePicker fake) {
  FilePicker? original;
  var initialized = false;
  try {
    original = FilePicker.platform;
    initialized = true;
  } catch (_) {
    // 测试宿主未初始化：回退 FilePickerIO
  }
  FilePicker.platform = fake;
  addTearDown(
    () => FilePicker.platform = initialized ? original! : FilePickerIO(),
  );
}

void main() {
  late _CapturingBookApi api;
  late Directory tempRoot;
  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // rootBundle 会缓存 Future；跨 testWidgets 的 FakeAsync 区域复用旧
    // Future 会永不完成 → 逐用例清除默认规则资产缓存
    rootBundle.evict(DirectLinkUploadRuleService.defaultRulesAsset);
    api = _CapturingBookApi();

    // 临时文件清理（deleteTempFileOnClose）依赖 path_provider：逐用例
    // 指向独立临时目录，避免真实平台插件在测试宿主不可用
    tempRoot = Directory.systemTemp.createTempSync('export_sheet_test');
    tempDir = Directory('${tempRoot.path}${Platform.pathSeparator}tmp')
      ..createSync(recursive: true);
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    addTearDown(() {
      PathProviderPlatform.instance = originalPathProvider;
      try {
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 偶发句柄未释放；临时目录交由系统清理
      }
    });
  });

  /// mock 系统剪贴板通道（setData 记录写入）
  List<String> mockClipboard(WidgetTester tester) {
    final written = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          written.add(args['text'] as String);
        }
        return null;
      },
    );
    return written;
  }

  Future<_ResultBox> openSheet(
    WidgetTester tester, {
    ExportFileService? fileService,
    DirectLinkUploadRuleService? ruleService,
    String? content = '[]',
    String? filePath,
    bool deleteTempFileOnClose = false,
    String fileName = 'rssSources.json',
    String? uploadFileName,
    String contentType = 'application/json',
    SourcePassphraseType? passphraseType,
  }) async {
    final box = _ResultBox();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const Key('openExportSheet'),
                  onPressed: () async {
                    box.value = await showExportFileSheet(
                      context,
                      content: content,
                      filePath: filePath,
                      deleteTempFileOnClose: deleteTempFileOnClose,
                      fileName: fileName,
                      uploadFileName: uploadFileName,
                      contentType: contentType,
                      subject: '导出文件',
                      fileService: fileService,
                      ruleService: ruleService,
                      passphraseType: passphraseType,
                    );
                    box.completed = true;
                  },
                  child: const Text('打开导出'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('openExportSheet')));
    await tester.pumpAndSettle();
    return box;
  }

  group('ExportFileSheet', () {
    testWidgets('渲染标题、两个选项、文件名与取消', (tester) async {
      await openSheet(tester);

      expect(find.text('导出文件'), findsOneWidget);
      expect(find.text('保存到本地'), findsOneWidget);
      expect(find.text('上传直链'), findsOneWidget);
      expect(find.text('导出文件：rssSources.json'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('保存成功：移动端提示只显示文件名并回传保存路径', (tester) async {
      final saver = _FakeExportFileService()
        ..savePath = r'D:\导出\rssSources.json';
      final box = await openSheet(tester, fileService: saver, content: '[1]');

      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();

      expect(saver.saveCalls, 1);
      expect(saver.lastFileName, 'rssSources.json');
      expect(saver.lastContent, '[1]');
      expect(find.text('保存到本地'), findsNothing);
      expect(box.completed, isTrue);
      expect(box.value?.outcome, ExportFileOutcome.savedLocal);
      expect(box.value?.path, r'D:\导出\rssSources.json');
      // widget 测试默认平台为 Android：移动端只提示文件名
      expect(box.value?.message, '已保存：rssSources.json');
    });

    testWidgets('保存成功（桌面端）：提示完整路径', (tester) async {
      // binding 不变量校验先于 tearDown，平台覆写必须在测试体内复位
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final saver = _FakeExportFileService()
          ..savePath = r'D:\导出\rssSources.json';
        final box = await openSheet(tester, fileService: saver, content: '[1]');

        await tester.tap(find.text('保存到本地'));
        await tester.pumpAndSettle();

        expect(box.value?.outcome, ExportFileOutcome.savedLocal);
        expect(box.value?.message, r'已保存到：D:\导出\rssSources.json');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // 批26：Android 目录树保存成功后回显实际目录（用户可据此定位文件）
    testWidgets('保存成功（目录树）：提示回显实际保存目录', (tester) async {
      final saver = _FakeExportFileService()
        ..savePath =
            'content://com.android.externalstorage.documents/document/x'
        ..savedFileName = 'bookSource_QA (1).json'
        ..savedViaTree = true
        ..savedDisplayPath = '下载/legado';
      final box = await openSheet(tester, fileService: saver, content: '[1]');

      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();

      expect(saver.saveCalls, 1);
      expect(box.value?.message, '已保存到「下载/legado」：bookSource_QA (1).json');
    });

    testWidgets('未记住目录：展示首次保存提示与「换个保存位置」入口', (tester) async {
      final saver = _FakeExportFileService();
      await openSheet(tester, fileService: saver);

      expect(find.text('首次保存需选择保存文件夹，之后沿用'), findsOneWidget);
      expect(find.text('换个保存位置'), findsOneWidget);
      expect(find.text('选择文件保存到哪个文件夹'), findsOneWidget);
    });

    testWidgets('已记住目录：展示当前保存位置', (tester) async {
      final saver = _FakeExportFileService()
        ..rememberedTree = const SaveTreeSelection(
          location: 'content://tree/downloads',
          displayPath: '下载',
        );
      await openSheet(tester, fileService: saver);
      await tester.pumpAndSettle();

      expect(find.text('保存到「下载」'), findsOneWidget);
      expect(find.text('当前：下载 · 点击重新选择文件夹'), findsOneWidget);
    });

    testWidgets('换个保存位置：选目录后更新展示（不立即保存）', (tester) async {
      final saver = _FakeExportFileService()
        ..chosenTree = const SaveTreeSelection(
          location: 'content://tree/downloads-legado',
          displayPath: '下载/legado',
        );
      await openSheet(tester, fileService: saver);

      await tester.tap(find.text('换个保存位置'));
      await tester.pumpAndSettle();

      expect(saver.chooseDirectoryCalls, 1);
      expect(saver.saveCalls, 0);
      expect(find.text('保存到「下载/legado」'), findsOneWidget);
    });

    testWidgets('保存失败：目录树失败可「换个位置」重选后重试成功', (tester) async {
      final saver = _FakeExportFileService()
        ..saveError = const FileSaveException(
          code: 'TREE_WRITE_FAILED',
          message: '无法写入所选文件夹，请换一个文件夹重试',
        );
      final box = await openSheet(tester, fileService: saver);

      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();

      expect(find.text('保存失败'), findsOneWidget);
      expect(find.text('无法写入所选文件夹，请换一个文件夹重试'), findsOneWidget);
      expect(find.text('换个位置'), findsOneWidget);

      // 换到可写目录后重试：第二次保存成功并带回实际目录
      saver
        ..saveError = null
        ..savePath = 'content://tree/document/x.json'
        ..savedViaTree = true
        ..savedDisplayPath = '下载/legado'
        ..chosenTree = const SaveTreeSelection(
          location: 'content://tree/downloads-legado',
          displayPath: '下载/legado',
        );
      await tester.tap(find.text('换个位置'));
      await tester.pumpAndSettle();

      expect(saver.chooseDirectoryCalls, 1);
      expect(saver.saveCalls, 2);
      expect(saver.lastChooseTree, isFalse);
      expect(box.value?.outcome, ExportFileOutcome.savedLocal);
      expect(find.text('保存失败'), findsNothing);
    });

    testWidgets('系统另存取消：关闭 Sheet 且不返回结果', (tester) async {
      final saver = _FakeExportFileService()..savePath = null;
      final box = await openSheet(tester, fileService: saver);

      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();

      expect(saver.saveCalls, 1);
      expect(find.text('保存到本地'), findsNothing);
      expect(box.completed, isTrue);
      expect(box.value, isNull);
    });

    testWidgets('保存失败：展示真实错误，可复制并重试成功', (tester) async {
      final written = mockClipboard(tester);
      final saver = _FakeExportFileService()
        ..saveError = const BridgeError(message: '写入失败,磁盘只读');
      final box = await openSheet(tester, fileService: saver);

      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();

      expect(find.text('保存失败'), findsOneWidget);
      expect(find.text('写入失败,磁盘只读'), findsOneWidget);
      expect(find.textContaining('Instance of'), findsNothing);

      await tester.tap(find.text('复制错误'));
      await tester.pumpAndSettle();
      expect(written, ['写入失败,磁盘只读']);

      // 修复后重试 → 保存成功
      saver
        ..saveError = null
        ..savePath = r'C:\temp\ok.json';
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(saver.saveCalls, 2);
      expect(box.value?.outcome, ExportFileOutcome.savedLocal);
      expect(box.value?.path, r'C:\temp\ok.json');
    });

    // [D4] 展示层最小映射：连接错误中文化，原始底层串作为次要行保留，
    // 「复制错误」复制原文（排障信息不丢）
    testWidgets('上传失败：连接错误映射中文并保留原始次要行', (tester) async {
      final written = mockClipboard(tester);
      api.uploadError = const BridgeError(
        message:
            'Network error: Request failed: connection refused (os error 111)',
      );
      final box = await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(find.text('上传失败'), findsOneWidget);
      // 主要行：中文映射（不再把 os error 111 直接抛给用户）
      expect(find.text('无法连接服务器'), findsOneWidget);
      // 次要行：原始底层串保留
      expect(find.text('原始错误：'), findsOneWidget);
      expect(find.textContaining('os error 111'), findsOneWidget);

      await tester.tap(find.text('复制错误'));
      await tester.pumpAndSettle();
      expect(written.single, contains('os error 111'));

      // 关闭 Sheet（失败态可取消）
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(box.value, isNull);
    });

    // [D4] 仅剥离 `FFI error:` 前缀（业务文案原样保留）
    testWidgets('上传失败：剥离 FFI 前缀且与原文一致时不重复展示次要行', (tester) async {
      api.uploadError = const BridgeError(
        message: 'FFI error: 上传失败,{"error":"mock"}',
      );
      await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(find.text('上传失败,{"error":"mock"}'), findsOneWidget);
      expect(find.text('原始错误：'), findsOneWidget);
      expect(find.textContaining('FFI error:'), findsOneWidget);
    });

    testWidgets('上传成功：入参正确、展示 URL 与规则注释、可复制、完成回传', (tester) async {
      final written = mockClipboard(tester);
      final box = await openSheet(tester, content: '[{"a":1}]');

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(api.uploadCalls, hasLength(1));
      final call = api.uploadCalls.single;
      expect(call['fileName'], 'rssSources.json');
      expect(call['contentType'], 'application/json');
      expect(call['content'], '[{"a":1}]');
      expect(call['filePath'], isNull);
      final rule =
          jsonDecode(call['ruleJson'] as String) as Map<String, dynamic>;
      expect(rule.keys.toSet(), <String>{
        'uploadUrl',
        'downloadUrlRule',
        'summary',
        'compress',
      });

      expect(find.text('上传成功'), findsOneWidget);
      expect(
        find.text('https://download.example/rssSources.json'),
        findsOneWidget,
      );
      // 规则注释（summary）来自内置默认第 1 条
      expect(find.text(rule['summary'] as String), findsOneWidget);
      // 未主动点击复制时不得写剪贴板
      expect(written, isEmpty);

      await tester.tap(find.text('复制链接'));
      await tester.pumpAndSettle();
      expect(written, ['https://download.example/rssSources.json']);
      // 内联反馈：按钮短暂变为「已复制」（不再用 SnackBar）
      expect(find.text('已复制'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('已复制'), findsNothing);
      expect(find.text('复制链接'), findsOneWidget);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(box.value?.outcome, ExportFileOutcome.uploaded);
      expect(box.value?.url, 'https://download.example/rssSources.json');
      expect(box.value?.summary, rule['summary']);
      expect(
        box.value?.message,
        '上传成功：https://download.example/rssSources.json',
      );
    });

    testWidgets('uploadFileName：另存用 fileName、上传用 uploadFileName', (
      tester,
    ) async {
      await openSheet(tester, uploadFileName: 'export_rules.json');

      // 选项区展示的仍是另存文件名
      expect(find.text('导出文件：rssSources.json'), findsOneWidget);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(api.uploadCalls, hasLength(1));
      expect(api.uploadCalls.single['fileName'], 'export_rules.json');
      expect(find.text('上传成功'), findsOneWidget);
    });

    testWidgets('复制失败：Sheet 内联展示原因，不弹底层 SnackBar', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'copy_failed', message: '剪贴板不可用');
          }
          return null;
        },
      );
      await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制链接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('复制失败'), findsOneWidget);
      expect(find.text('已复制'), findsNothing);
      // 失败反馈内联在 Sheet 内，不显示底层 SnackBar
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('上传失败后取消：返回 null 且调用方不重复提示', (tester) async {
      api.uploadError = const BridgeError(message: '上传失败,真实原因');
      final box = await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();
      expect(find.text('上传失败'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(box.completed, isTrue);
      expect(box.value, isNull);
      // 失败信息已在 Sheet 内展示，关闭后不应再弹 SnackBar
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('上传进行中：展示「正在上传」并禁用取消', (tester) async {
      api.uploadCompleter = Completer<String>();
      await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pump();

      expect(find.text('正在上传…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final cancel = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '取消'),
      );
      expect(cancel.onPressed, isNull);

      api.uploadCompleter!.complete('https://download.example/done.json');
      await tester.pumpAndSettle();
      expect(find.text('上传成功'), findsOneWidget);
      expect(find.text('https://download.example/done.json'), findsOneWidget);
    });

    testWidgets('P1 回归：上传中下拉不关闭 Sheet（避免结果丢失）', (tester) async {
      api.uploadCompleter = Completer<String>();
      await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pump();
      expect(find.text('正在上传…'), findsOneWidget);

      // 在标题区域下拉：修复前拖拽走 Navigator.pop 绕过 PopScope，Sheet 会被关闭
      await tester.drag(find.text('导出文件'), const Offset(0, 400));
      // 上传中进度圈持续动画，不能用 pumpAndSettle
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('正在上传…'), findsOneWidget);
      expect(find.text('导出文件'), findsOneWidget);

      // 收尾：完成挂起上传，避免遗留未完成 Future
      api.uploadCompleter!.complete('https://download.example/done.json');
      await tester.pumpAndSettle();
      expect(find.text('上传成功'), findsOneWidget);
    });

    testWidgets('上传失败：展示真实错误，重试后成功', (tester) async {
      api.uploadError = const BridgeError(message: '上传失败,真实原因');
      final box = await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(find.text('上传失败'), findsOneWidget);
      expect(find.text('上传失败,真实原因'), findsOneWidget);
      expect(find.textContaining('Instance of'), findsNothing);

      api.uploadError = null;
      api.uploadResult = 'https://download.example/retry.json';
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(api.uploadCalls, hasLength(2));
      expect(find.text('上传成功'), findsOneWidget);
      expect(find.text('https://download.example/retry.json'), findsOneWidget);
      expect(box.completed, isFalse);
    });

    testWidgets('上传使用已保存规则（配置优先于默认）', (tester) async {
      await api.setConfig(
        DirectLinkUploadRuleService.configKey,
        jsonEncode(<String, Object?>{
          'uploadUrl': 'https://up.example/upload',
          'downloadUrlRule': r'$.url',
          'summary': '自定义直链',
          'compress': false,
        }),
      );
      await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      final rule =
          jsonDecode(api.uploadCalls.single['ruleJson'] as String)
              as Map<String, dynamic>;
      expect(rule['uploadUrl'], 'https://up.example/upload');
      expect(rule['summary'], '自定义直链');
      expect(find.text('自定义直链'), findsOneWidget);
    });

    testWidgets('取消：关闭 Sheet 且不返回结果', (tester) async {
      final box = await openSheet(tester);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.text('保存到本地'), findsNothing);
      expect(box.completed, isTrue);
      expect(box.value, isNull);
    });
  });

  group('filePath 模式（批16e）', () {
    /// 创建真实临时文件（默认落在 path_provider 临时目录下）
    File createTempFile(String name, List<int> bytes, {Directory? dir}) {
      final target = dir ?? tempDir;
      final file = File('${target.path}${Platform.pathSeparator}$name');
      file.writeAsBytesSync(bytes);
      return file;
    }

    /// 放行真实事件循环，等待 Sheet dispose 触发的异步清理落定
    Future<void> waitForCleanup(WidgetTester tester, File file) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && file.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
    }

    // P2-4：saveExistingFile 的假实现不读文件，这里直接验证真实服务
    // 读取源文件字节并复制到系统另存位置（桌面分支由服务自身写盘）
    test('saveExistingFile：复制真实源文件字节到目标路径', () async {
      final source = createTempFile('source.zip', const [9, 8, 7, 6]);
      final destPath = '${tempDir.path}${Platform.pathSeparator}saved.zip';
      _useFakeSaveFilePicker(_SaveFilePickerStub(destPath));

      // 桌面分支（服务自行写盘）便于断言真实字节
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final saved = await const ExportFileService().saveExistingFile(
          sourcePath: source.path,
          fileName: 'saved.zip',
        );
        expect(saved?.location, destPath);
        expect(File(destPath).readAsBytesSync(), const [9, 8, 7, 6]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    // P2-2：清理护栏 —— 仅删除系统临时目录内的文件
    test('deleteTemporaryFile：临时目录内删除，用户目录/.. 逃逸不删除', () async {
      const service = ExportFileService();
      final inside = createTempFile('inside.bin', const [1]);
      expect(await service.deleteTemporaryFile(inside.path), isTrue);
      expect(inside.existsSync(), isFalse);

      final userDir = Directory.systemTemp.createTempSync('export_user_dir');
      addTearDown(() {
        if (userDir.existsSync()) userDir.deleteSync(recursive: true);
      });
      final outside = createTempFile('outside.bin', const [2], dir: userDir);
      expect(await service.deleteTemporaryFile(outside.path), isFalse);
      expect(outside.existsSync(), isTrue);

      // 路径经 `..` 规范化后仍落在临时目录之外 → 护栏拦截
      final escapeFile = File(
        '${tempRoot.path}${Platform.pathSeparator}escape.bin',
      )..writeAsBytesSync(const [3]);
      final escaped =
          '${tempDir.path}${Platform.pathSeparator}..${Platform.pathSeparator}'
          'escape.bin';
      expect(await service.deleteTemporaryFile(escaped), isFalse);
      expect(escapeFile.existsSync(), isTrue);
    });

    testWidgets('content 与 filePath 互斥：都为空 / 都给均抛 ArgumentError', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('anchor'))),
      );
      final context = tester.element(find.text('anchor'));

      // P3-6：运行时校验常驻（release 下 assert 失效也不会放行）
      expect(
        () => showExportFileSheet(context, fileName: 'x.json'),
        throwsArgumentError,
      );
      expect(
        () => showExportFileSheet(
          context,
          content: '[]',
          filePath: 'x.json',
          fileName: 'x.json',
        ),
        throwsArgumentError,
      );
    });

    testWidgets('filePath 保存：复制既有文件字节，不回退文本写入', (tester) async {
      final zip = createTempFile('skin.zip', const [1, 2, 3, 4]);
      final saver = _FakeExportFileService()
        ..existingSavePath = r'D:\导出\skin.zip';
      final box = await openSheet(
        tester,
        fileService: saver,
        content: null,
        filePath: zip.path,
        fileName: 'skin.zip',
        contentType: 'application/zip',
      );

      expect(find.text('导出文件：skin.zip'), findsOneWidget);
      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();

      expect(saver.existingSaveCalls, 1);
      expect(saver.lastSourcePath, zip.path);
      expect(saver.lastFileName, 'skin.zip');
      // 文本写入分支不得被触发
      expect(saver.saveCalls, 0);
      expect(box.value?.outcome, ExportFileOutcome.savedLocal);
      expect(box.value?.message, '已保存：skin.zip');
      // 未声明清理时临时文件保持原样
      expect(zip.existsSync(), isTrue);
    });

    testWidgets('另存成功：Sheet 关闭后清理临时文件', (tester) async {
      final zip = createTempFile('skin.zip', const [1, 2, 3, 4]);
      await openSheet(
        tester,
        fileService: _FakeExportFileService()
          ..existingSavePath = r'D:\导出\skin.zip',
        content: null,
        filePath: zip.path,
        deleteTempFileOnClose: true,
        fileName: 'skin.zip',
      );

      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();
      await waitForCleanup(tester, zip);

      expect(zip.existsSync(), isFalse);
    });

    testWidgets('另存取消：Sheet 关闭后同样清理临时文件', (tester) async {
      final zip = createTempFile('skin.zip', const [1, 2, 3, 4]);
      await openSheet(
        tester,
        fileService: _FakeExportFileService()..existingSavePath = null,
        content: null,
        filePath: zip.path,
        deleteTempFileOnClose: true,
        fileName: 'skin.zip',
      );

      await tester.tap(find.text('保存到本地'));
      await tester.pumpAndSettle();
      await waitForCleanup(tester, zip);

      expect(zip.existsSync(), isFalse);
    });

    testWidgets('filePath 上传：成功后文件保留到 Sheet 关闭再清理', (tester) async {
      final zip = createTempFile('skin.zip', const [1, 2, 3, 4]);
      final box = await openSheet(
        tester,
        content: null,
        filePath: zip.path,
        deleteTempFileOnClose: true,
        fileName: 'skin.zip',
        contentType: 'application/zip',
      );

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(api.uploadCalls, hasLength(1));
      final call = api.uploadCalls.single;
      expect(call['filePath'], zip.path);
      expect(call['content'], isNull);
      expect(call['contentType'], 'application/zip');
      expect(call['fileName'], 'skin.zip');
      // 上传成功面板仍需可操作，文件此时尚未删除
      expect(zip.existsSync(), isTrue);
      expect(box.completed, isFalse);
      expect(find.text('上传成功'), findsOneWidget);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await waitForCleanup(tester, zip);

      expect(box.completed, isTrue);
      expect(box.value?.outcome, ExportFileOutcome.uploaded);
      expect(zip.existsSync(), isFalse);
    });

    testWidgets('上传失败：文件保留可重试，关闭 Sheet 后清理', (tester) async {
      api.uploadError = const BridgeError(message: '上传失败,真实原因');
      final zip = createTempFile('skin.zip', const [1, 2, 3, 4]);
      await openSheet(
        tester,
        content: null,
        filePath: zip.path,
        deleteTempFileOnClose: true,
        fileName: 'skin.zip',
      );

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(find.text('上传失败'), findsOneWidget);
      // 失败后 Sheet 保持打开供重试：文件必须仍在
      expect(zip.existsSync(), isTrue);

      api.uploadError = null;
      api.uploadResult = 'https://download.example/retry.zip';
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(api.uploadCalls, hasLength(2));
      expect(find.text('上传成功'), findsOneWidget);
      expect(zip.existsSync(), isTrue);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await waitForCleanup(tester, zip);

      expect(zip.existsSync(), isFalse);
    });

    testWidgets('filePath 上传：未声明清理时保留原文件（避免误删用户文件）', (tester) async {
      final userFile = createTempFile('user.json', const [123]);
      await openSheet(
        tester,
        content: null,
        filePath: userFile.path,
        fileName: 'user.json',
      );

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(api.uploadCalls.single['filePath'], userFile.path);
      expect(userFile.existsSync(), isTrue);
    });

    testWidgets('删除护栏：声明清理但文件位于用户目录时不删除', (tester) async {
      // 用户目录（非 path_provider 临时目录）
      final userDir = Directory.systemTemp.createTempSync('export_user_dir');
      addTearDown(() {
        if (userDir.existsSync()) userDir.deleteSync(recursive: true);
      });
      final userFile = createTempFile('user.json', const [
        1,
        2,
        3,
      ], dir: userDir);
      await openSheet(
        tester,
        content: null,
        filePath: userFile.path,
        deleteTempFileOnClose: true,
        fileName: 'user.json',
      );

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // 放行异步清理，确认护栏拦截（否则会被误删）
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );

      expect(userFile.existsSync(), isTrue);
    });

    testWidgets('批25：上传成功且传 passphraseType 时展示复制口令并可复制', (tester) async {
      final written = mockClipboard(tester);
      await openSheet(tester, passphraseType: SourcePassphraseType.rssSource);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(find.text('上传成功'), findsOneWidget);
      expect(find.text('复制口令'), findsOneWidget);

      await tester.tap(find.text('复制口令'));
      await tester.pumpAndSettle();

      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      final preview = tester
          .widget<SelectableText>(
            find.descendant(of: dialog, matching: find.byType(SelectableText)),
          )
          .data!;
      expect(preview, startsWith('复制口令到阅读导入'));
      expect(preview, contains('！dy©0¥Legado^'));

      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(FilledButton, '复制口令'),
        ),
      );
      await tester.pump();

      expect(written.single, preview);
      expect(find.text('已复制到剪贴板'), findsOneWidget);
    });

    testWidgets('批25：未传 passphraseType 时不展示复制口令', (tester) async {
      await openSheet(tester);

      await tester.tap(find.text('上传直链'));
      await tester.pumpAndSettle();

      expect(find.text('上传成功'), findsOneWidget);
      expect(find.text('复制口令'), findsNothing);
    });
  });
}
