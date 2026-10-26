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
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/direct_link_upload_rule_service.dart';
import 'package:flutter_legado/src/services/export_file_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
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

  /// filePath 模式：既有文件另存
  String? existingSavePath = r'C:\temp\skin.zip';
  Object? existingSaveError;
  int existingSaveCalls = 0;
  String? lastSourcePath;

  @override
  Future<String?> saveToLocal({
    required String fileName,
    required String content,
  }) async {
    saveCalls++;
    lastFileName = fileName;
    lastContent = content;
    final error = saveError;
    if (error != null) throw error;
    return savePath;
  }

  @override
  Future<String?> saveExistingFile({
    required String sourcePath,
    required String fileName,
  }) async {
    existingSaveCalls++;
    lastSourcePath = sourcePath;
    lastFileName = fileName;
    final error = existingSaveError;
    if (error != null) throw error;
    return existingSavePath;
  }
}

/// 异步结果容器（Sheet 关闭后才回填）
class _ResultBox {
  ExportFileResult? value;
  bool completed = false;
}

void main() {
  late _CapturingBookApi api;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // rootBundle 会缓存 Future；跨 testWidgets 的 FakeAsync 区域复用旧
    // Future 会永不完成 → 逐用例清除默认规则资产缓存
    rootBundle.evict(DirectLinkUploadRuleService.defaultRulesAsset);
    api = _CapturingBookApi();
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
    bool deleteTempFileAfterUpload = false,
    String fileName = 'rssSources.json',
    String? uploadFileName,
    String contentType = 'application/json',
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
                      deleteTempFileAfterUpload: deleteTempFileAfterUpload,
                      fileName: fileName,
                      uploadFileName: uploadFileName,
                      contentType: contentType,
                      subject: '导出文件',
                      fileService: fileService,
                      ruleService: ruleService,
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

    testWidgets('上传成功：入参正确、展示 URL 与规则注释、可复制、完成回传', (
      tester,
    ) async {
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
      final rule = jsonDecode(call['ruleJson'] as String) as Map<String, dynamic>;
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
      expect(box.value?.message, '上传成功：https://download.example/rssSources.json');
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
    /// 创建真实临时文件（模拟调用方自建文件）
    File createTempFile(String name, List<int> bytes) {
      final dir = Directory.systemTemp.createTempSync('export_sheet_test');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      file.writeAsBytesSync(bytes);
      return file;
    }

    testWidgets('content 与 filePath 互斥：都为空 / 都给均 assert 报错', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('anchor'))),
      );
      final context = tester.element(find.text('anchor'));

      expect(
        () => showExportFileSheet(context, fileName: 'x.json'),
        throwsAssertionError,
      );
      expect(
        () => showExportFileSheet(
          context,
          content: '[]',
          filePath: 'x.json',
          fileName: 'x.json',
        ),
        throwsAssertionError,
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
    });

    testWidgets('filePath 上传：按路径上传，成功后删除调用方临时文件', (tester) async {
      final zip = createTempFile('skin.zip', const [1, 2, 3, 4]);
      final box = await openSheet(
        tester,
        content: null,
        filePath: zip.path,
        deleteTempFileAfterUpload: true,
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
      // 上传成功后临时文件被清理
      expect(zip.existsSync(), isFalse);
      expect(box.completed, isFalse);
      expect(find.text('上传成功'), findsOneWidget);
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
  });
}
