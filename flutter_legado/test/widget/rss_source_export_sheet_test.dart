// 订阅源管理页导出/分享接线测试（批16c）
//
// 覆盖：批量「导出选中」打开统一导出 Sheet 并以上传直链落地（payload 正确、
// 不再写剪贴板）；批量「分享源」写临时文件后走系统分享（对齐原版 share(file)）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// share_plus 平台接口为传递依赖，测试直引以覆写 instance 保持 hermetic，
// 不改 pubspec（同 import_screen_cbz_test 的 path_provider 桩模式）
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/rss_source_manage_screen.dart';
import 'package:flutter_legado/src/services/direct_link_upload_rule_service.dart';
import 'package:flutter_legado/src/services/export_file_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 捕获 directLinkUpload 入参的 Mock（其余能力沿用 MockBookApi）
class _CapturingBookApi extends MockBookApi {
  final List<Map<String, Object?>> uploadCalls = [];

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
    return 'https://download.example/rssSources.json';
  }
}

/// 落盘服务桩：同步写入临时目录（避免测试 FakeAsync 区内真实异步 I/O）
class _FakeExportFileService extends ExportFileService {
  _FakeExportFileService(this.tempPath);

  final String tempPath;

  @override
  Future<XFile> writeTempFile({
    required String fileName,
    required String content,
    String mimeType = 'application/json',
  }) async {
    final file = File('$tempPath${Platform.pathSeparator}$fileName');
    file.writeAsStringSync(content);
    return XFile(file.path, mimeType: mimeType);
  }
}

/// share_plus 平台桩：记录 shareXFiles 入参
class _FakeSharePlatform extends SharePlatform {
  final List<Map<String, Object?>> calls = [];

  @override
  Future<ShareResult> shareXFiles(
    List<XFile> files, {
    String? subject,
    String? text,
    Rect? sharePositionOrigin,
    List<String>? fileNameOverrides,
  }) async {
    calls.add(<String, Object?>{
      'paths': files.map((f) => f.path).toList(),
      'subject': subject,
      'text': text,
    });
    return const ShareResult('ok', ShareResultStatus.success);
  }
}

void main() {
  late _CapturingBookApi api;
  late _FakeSharePlatform share;
  late Directory tempDir;
  late _FakeExportFileService fileService;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // rootBundle 会缓存 Future；跨 testWidgets 复用旧 Future 会永不完成
    rootBundle.evict(DirectLinkUploadRuleService.defaultRulesAsset);
    api = _CapturingBookApi();
    share = _FakeSharePlatform();

    tempDir = await Directory.systemTemp.createTemp('rss_export_test_');
    fileService = _FakeExportFileService(tempDir.path);

    final originalShare = SharePlatform.instance;
    SharePlatform.instance = share;
    addTearDown(() => SharePlatform.instance = originalShare);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// mock 剪贴板：记录写入内容（断言导出不再直接写剪贴板）
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

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: RssSourceManageScreen(exportFileService: fileService),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 选中第一条订阅源（Mock 数据 customOrder 升序后为「使用说明」）
  Future<void> selectFirst(WidgetTester tester) async {
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
  }

  Future<void> openBatchMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多选项'));
    await tester.pumpAndSettle();
  }

  testWidgets('导出选中：打开统一 Sheet，上传直链使用选中源 JSON 且不写剪贴板', (tester) async {
    final written = mockClipboard(tester);
    await pumpScreen(tester);
    await selectFirst(tester);
    await openBatchMenu(tester);

    await tester.tap(find.text('导出选中'));
    await tester.pumpAndSettle();

    expect(find.text('导出订阅源'), findsOneWidget);
    expect(find.text('保存到本地'), findsOneWidget);
    expect(find.text('上传直链'), findsOneWidget);
    expect(find.text('导出文件：rssSources.json'), findsOneWidget);

    await tester.tap(find.text('上传直链'));
    await tester.pumpAndSettle();

    expect(api.uploadCalls, hasLength(1));
    final call = api.uploadCalls.single;
    expect(call['fileName'], 'rssSources.json');
    expect(call['contentType'], 'application/json');
    expect(call['filePath'], isNull);
    final payload = jsonDecode(call['content'] as String) as List<dynamic>;
    expect(payload, hasLength(1));
    final source = payload.single as Map<String, dynamic>;
    expect(source['sourceUrl'], 'https://www.yuque.com/legado');
    expect(source['sourceName'], '使用说明');

    expect(find.text('上传成功'), findsOneWidget);
    expect(find.text('https://download.example/rssSources.json'), findsOneWidget);
    // 未点击「复制链接」→ 导出链不再直接写剪贴板
    expect(written, isEmpty);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(
      find.text('上传成功：https://download.example/rssSources.json'),
      findsOneWidget,
    );
    expect(find.text('已选择 1 项'), findsNothing);
    expect(written, isEmpty);
  });

  testWidgets('分享源：写临时 JSON 文件并走系统文件分享', (tester) async {
    await pumpScreen(tester);
    await selectFirst(tester);
    await openBatchMenu(tester);

    await tester.tap(find.text('分享源'));
    await tester.pumpAndSettle();

    expect(share.calls, hasLength(1));
    final call = share.calls.single;
    final paths = (call['paths'] as List<dynamic>).cast<String>();
    expect(paths, hasLength(1));
    expect(call['subject'], '订阅源分享（1 个）');

    final file = File(paths.single);
    expect(file.existsSync(), isTrue);
    final payload = jsonDecode(file.readAsStringSync()) as List<dynamic>;
    expect(payload, hasLength(1));
    expect(
      (payload.single as Map<String, dynamic>)['sourceUrl'],
      'https://www.yuque.com/legado',
    );
  });
}
