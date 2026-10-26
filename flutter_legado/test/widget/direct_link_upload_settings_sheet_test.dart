// 直链上传规则配置 Sheet widget 测试（批16b）
//
// 覆盖：字段渲染与默认回填、保存写 config、校验失败提示、测试按钮调用
// 参数与结果对话框（可复制）、导入默认规则、复制/粘贴规则、设置页入口可见
// 性与跳转。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/direct_link_upload_settings_sheet.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/services/direct_link_upload_rule_service.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 捕获 directLinkUpload 入参的 Mock（配置读写沿用 MockBookApi 内存实现）
class _CapturingBookApi extends MockBookApi {
  final List<Map<String, Object?>> uploadCalls = [];
  Object? uploadError;
  String uploadResult = 'https://download.example/test.json';

  /// 非空时上传挂起，用于断言「测试中」状态
  Completer<String>? uploadCompleter;

  /// 非空时配置读取/写入抛错（模拟桥接异常）
  Object? loadError;
  Object? saveError;

  @override
  Future<String?> getConfig(String key) async {
    final error = loadError;
    if (error != null) throw error;
    return super.getConfig(key);
  }

  @override
  Future<void> setConfig(String key, String value) async {
    final error = saveError;
    if (error != null) throw error;
    return super.setConfig(key, value);
  }

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

void main() {
  late _CapturingBookApi api;
  late DirectLinkUploadRuleService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // rootBundle 会缓存 Future；跨 testWidgets 的 FakeAsync 区域复用旧
    // Future 会永不完成 → 逐用例清除默认规则资产缓存
    rootBundle.evict(DirectLinkUploadRuleService.defaultRulesAsset);
    api = _CapturingBookApi();
    service = DirectLinkUploadRuleService(api);
  });

  /// mock 系统剪贴板通道（getData 返回 [clipboardText]；setData 记录写入）
  List<String> mockClipboard(WidgetTester tester, {String clipboardText = ''}) {
    final written = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          // SDK 3.44 的 Clipboard 通道方法名为 Clipboard.*（旧版为
          // SystemClipboard.*）；getData 返回 Map{'text': ...}（null=空）
          case 'Clipboard.setData':
            final args = call.arguments as Map<Object?, Object?>;
            written.add(args['text'] as String);
            return null;
          case 'Clipboard.getData':
            return clipboardText.isEmpty
                ? null
                : <String, dynamic>{'text': clipboardText};
          default:
            return null;
        }
      },
    );
    return written;
  }

  Future<void> openSheet(
    WidgetTester tester, {
    DirectLinkUploadRuleService? serviceOverride,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('openSheet'),
                  onPressed: () => DirectLinkUploadSettingsSheet.show(
                    context,
                    service: serviceOverride ?? service,
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('openSheet')));
    await tester.pumpAndSettle();
  }

  TextField byLabel(WidgetTester tester, String label) =>
      tester.widget<TextField>(find.widgetWithText(TextField, label).first);

  Future<void> tapMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('更多菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  group('DirectLinkUploadSettingsSheet', () {
    testWidgets('渲染标题、4 字段、安全提示与按钮，加载后回填默认规则', (tester) async {
      await openSheet(tester);

      expect(find.text('直链上传配置'), findsOneWidget);
      expect(find.text('上传 URL'), findsOneWidget);
      expect(find.text('下载 URL 规则'), findsOneWidget);
      expect(find.text('注释'), findsOneWidget);
      expect(find.text('是否压缩'), findsOneWidget);
      expect(find.text('测试'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确认'), findsOneWidget);
      // 安全提示位于表单底部，ListView 懒构建：先滚动到底部
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.textContaining('安全提示'), findsOneWidget);

      expect(
        byLabel(tester, '上传 URL').controller?.text,
        startsWith('https://sy.nyasama.net/shuyuan'),
      );
      expect(
        byLabel(tester, '下载 URL 规则').controller?.text,
        contains(r'$.data@js:'),
      );
      expect(byLabel(tester, '注释').controller?.text, contains('喵公子网盘①'));
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('保存：写 config 4 字段、关闭 Sheet 并提示', (tester) async {
      await openSheet(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '上传 URL').first,
        'https://up.example/upload,{"method":"POST"}',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '下载 URL 规则').first,
        r'$.data.url',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '注释').first,
        '自定义直链',
      );
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      final raw = await api.getConfig(DirectLinkUploadRuleService.configKey);
      expect(raw, isNotNull);
      final saved = jsonDecode(raw!) as Map<String, dynamic>;
      expect(saved['uploadUrl'], 'https://up.example/upload,{"method":"POST"}');
      expect(saved['downloadUrlRule'], r'$.data.url');
      expect(saved['summary'], '自定义直链');
      expect(saved['compress'], isTrue);
      expect(saved.keys.toSet(), <String>{
        'uploadUrl',
        'downloadUrlRule',
        'summary',
        'compress',
      });

      expect(find.text('直链上传配置'), findsNothing);
      expect(find.text('已保存直链上传规则'), findsOneWidget);
    });

    testWidgets('坏配置回落：提示已回退默认规则并回填默认第 1 条', (tester) async {
      await api.setConfig(DirectLinkUploadRuleService.configKey, '{}');
      await openSheet(tester);

      expect(find.text('已保存的直链规则无效，已回退默认规则'), findsOneWidget);
      expect(
        byLabel(tester, '上传 URL').controller?.text,
        startsWith('https://sy.nyasama.net/shuyuan'),
      );
    });

    testWidgets('读取配置失败：BridgeError 展示真实 message', (tester) async {
      api.loadError = const BridgeError(message: '读取配置失败,真实原因');
      await openSheet(tester);

      expect(
        find.text('读取直链上传规则失败：读取配置失败,真实原因'),
        findsOneWidget,
      );
      expect(find.textContaining('Instance of'), findsNothing);
    });

    testWidgets('导入默认规则资产读取失败：BridgeError 展示真实 message', (tester) async {
      final broken = DirectLinkUploadRuleService(
        api,
        assetLoader: (_) async => throw const BridgeError(message: '资产读取失败,真实原因'),
      );
      await openSheet(tester, serviceOverride: broken);

      await tapMenu(tester, '导入默认规则');

      expect(find.text('读取默认规则失败：资产读取失败,真实原因'), findsOneWidget);
      expect(find.textContaining('Instance of'), findsNothing);
    });

    testWidgets('保存校验失败：提示且不写 config、Sheet 保留', (tester) async {
      await openSheet(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '上传 URL').first,
        '',
      );
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(find.text('上传Url不能为空'), findsOneWidget);
      expect(find.text('直链上传配置'), findsOneWidget);
      expect(
        await api.getConfig(DirectLinkUploadRuleService.configKey),
        isNull,
      );
    });

    testWidgets('保存失败：BridgeError 展示真实 message，Sheet 保留', (tester) async {
      api.saveError = const BridgeError(message: '保存失败,真实原因');
      await openSheet(tester);

      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(find.text('保存失败：保存失败,真实原因'), findsOneWidget);
      expect(find.textContaining('Instance of'), findsNothing);
      expect(find.text('直链上传配置'), findsOneWidget);
    });

    testWidgets('测试：上传 test.json/{} 并展示结果，可复制', (tester) async {
      final written = mockClipboard(tester);
      await openSheet(tester);

      await tester.tap(find.text('测试'));
      await tester.pumpAndSettle();

      expect(api.uploadCalls, hasLength(1));
      final call = api.uploadCalls.single;
      expect(call['fileName'], 'test.json');
      expect(call['contentType'], 'application/json');
      expect(call['content'], '{}');
      expect(find.text('测试结果'), findsOneWidget);
      expect(find.text('https://download.example/test.json'), findsOneWidget);

      await tester.tap(find.text('复制结果'));
      await tester.pumpAndSettle();
      expect(written, ['https://download.example/test.json']);
      expect(find.text('测试结果'), findsNothing);
    });

    testWidgets('测试进行中：显示测试中且表单/菜单禁用，完成后展示结果', (tester) async {
      api.uploadCompleter = Completer<String>();
      await openSheet(tester);

      await tester.tap(find.text('测试'));
      await tester.pump();

      expect(find.text('测试中'), findsOneWidget);
      final testButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '测试中'),
      );
      expect(testButton.onPressed, isNull);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '上传 URL').first)
            .enabled,
        isFalse,
      );
      // 测试进行中菜单禁用：点击后不弹出菜单（测试中按钮有持续动画，
      // 不能用 pumpAndSettle）
      await tester.tap(find.byTooltip('更多菜单'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('导入默认规则'), findsNothing);

      api.uploadCompleter!.complete('https://download.example/test.json');
      await tester.pumpAndSettle();
      expect(find.text('测试结果'), findsOneWidget);
    });

    testWidgets('测试失败：BridgeError 展示真实 message，不出现 Instance of', (tester) async {
      api.uploadError = const BridgeError(message: '上传失败,真实原因');
      await openSheet(tester);

      await tester.tap(find.text('测试'));
      await tester.pumpAndSettle();

      expect(find.text('测试失败'), findsOneWidget);
      expect(find.text('上传失败,真实原因'), findsOneWidget);
      expect(find.textContaining('Instance of'), findsNothing);
    });

    testWidgets('导入默认规则：列出 3 条并回填所选规则', (tester) async {
      await openSheet(tester);

      await tapMenu(tester, '导入默认规则');
      expect(find.text('喵公子网盘①(有效期30天·香港G口)（默认）'), findsOneWidget);
      expect(find.text('喵公子网盘②(有效期7天)'), findsOneWidget);

      await tester.tap(find.text('橘涂书源网盘2.0 Beta(永久有效)'));
      await tester.pumpAndSettle();

      expect(
        byLabel(tester, '上传 URL').controller?.text,
        startsWith('http://v2.jt12.eu/up-v2.php'),
      );
      expect(byLabel(tester, '注释').controller?.text, '橘涂书源网盘2.0 Beta(永久有效)');
      expect(find.textContaining('已导入默认规则'), findsOneWidget);
    });

    testWidgets('复制规则：当前表单 JSON 写入剪贴板', (tester) async {
      final written = mockClipboard(tester);
      await openSheet(tester);

      await tapMenu(tester, '复制规则');

      expect(written, hasLength(1));
      final copied = jsonDecode(written.single) as Map<String, dynamic>;
      expect(copied.keys.toSet(), <String>{
        'uploadUrl',
        'downloadUrlRule',
        'summary',
        'compress',
      });
      expect(copied['summary'], contains('喵公子网盘①'));
      expect(find.text('规则已复制到剪贴板'), findsOneWidget);
    });

    testWidgets('粘贴规则：剪贴板 JSON 回填表单', (tester) async {
      mockClipboard(
        tester,
        clipboardText: jsonEncode(<String, Object?>{
          'uploadUrl': 'https://paste.example/up',
          'downloadUrlRule': r'$.msg',
          'summary': '粘贴规则',
          'compress': true,
        }),
      );
      await openSheet(tester);

      await tapMenu(tester, '粘贴规则');

      expect(
        byLabel(tester, '上传 URL').controller?.text,
        'https://paste.example/up',
      );
      expect(byLabel(tester, '下载 URL 规则').controller?.text, r'$.msg');
      expect(byLabel(tester, '注释').controller?.text, '粘贴规则');
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('已粘贴规则「粘贴规则」'), findsOneWidget);
    });

    testWidgets('粘贴非法内容：提示格式不正确', (tester) async {
      mockClipboard(tester, clipboardText: '不是 JSON');
      await openSheet(tester);

      await tapMenu(tester, '粘贴规则');

      expect(find.text('剪贴板为空或格式不正确'), findsOneWidget);
    });

    testWidgets('复制规则失败：提示复制失败', (tester) async {
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

      await tapMenu(tester, '复制规则');

      expect(find.textContaining('复制失败'), findsOneWidget);
      expect(find.text('规则已复制到剪贴板'), findsNothing);
    });

    testWidgets('粘贴规则读取失败：提示读取剪贴板失败', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            throw PlatformException(code: 'read_failed', message: '剪贴板不可用');
          }
          return null;
        },
      );
      await openSheet(tester);

      await tapMenu(tester, '粘贴规则');

      expect(find.textContaining('读取剪贴板失败'), findsOneWidget);
      expect(find.text('剪贴板为空或格式不正确'), findsNothing);
    });
  });

  group('其他设置入口', () {
    testWidgets('显示「直链上传规则」行并打开配置 Sheet', (tester) async {
      final entryApi = MockBookApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bookApiProvider.overrideWithValue(entryApi)],
          child: const MaterialApp(home: OtherSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('直链上传规则'),
        find.byType(ListView),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      expect(find.text('用于导出书源书单时生成直链 URL'), findsOneWidget);

      await tester.tap(find.text('直链上传规则'));
      await tester.pumpAndSettle();

      expect(find.text('直链上传配置'), findsOneWidget);
      expect(find.text('测试'), findsOneWidget);
    });
  });
}
