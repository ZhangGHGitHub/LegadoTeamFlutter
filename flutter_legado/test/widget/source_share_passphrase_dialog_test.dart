// 分享口令生成对话框 widget 测试（批25）
//
// 覆盖：默认永久口令 / 有效期输入重算 / 越界校验禁用复制 / 复制写剪贴板
// 与内联「已复制」提示（不使用可能被弹层遮挡的 SnackBar）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_legado/src/services/source_share_passphrase.dart';
import 'package:flutter_legado/src/widgets/source_share_passphrase_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return written;
  }

  String previewText(WidgetTester tester) {
    final widget = tester.widget<SelectableText>(find.byType(SelectableText));
    return widget.data ?? '';
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const Key('openPassphrase'),
                onPressed: () => showSourceSharePassphraseDialog(
                  context,
                  url: 'https://example.com/a.json',
                  type: SourcePassphraseType.bookSource,
                ),
                child: const Text('生成口令'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('openPassphrase')));
    await tester.pumpAndSettle();
  }

  testWidgets('默认永久（©0）并展示口令文本', (tester) async {
    await openDialog(tester);

    expect(find.text('复制口令'), findsNWidgets(2)); // 标题 + 按钮
    expect(find.text('有效期（天）'), findsOneWidget);
    final preview = previewText(tester);
    expect(preview, startsWith('复制口令到阅读导入'));
    expect(preview, contains('！sy©0¥Legado^'));
  });

  testWidgets('输入有效期后口令过期 token 重算', (tester) async {
    await openDialog(tester);
    expect(previewText(tester), contains('©0¥'));

    await tester.enterText(find.byType(TextField), '30');
    await tester.pump();

    final preview = previewText(tester);
    expect(preview, startsWith('复制口令到阅读导入'));
    expect(preview, contains('！sy©'));
    expect(preview, isNot(contains('©0¥')));
    // 7 位过期 token（30 天后）
    final token = RegExp(r'©(\d+)¥').firstMatch(preview)!.group(1)!;
    expect(token.length, 7);
    expect(int.parse(token) * SourceSharePassphrase.expiryPrecision,
        greaterThan(DateTime.now().millisecondsSinceEpoch));
  });

  testWidgets('有效期越界提示并禁用复制', (tester) async {
    await openDialog(tester);

    await tester.enterText(find.byType(TextField), '36501');
    await tester.pump();

    expect(find.text('有效期需为 0~36500 天'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '复制口令'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('复制写入剪贴板并内联提示「已复制到剪贴板」', (tester) async {
    final written = mockClipboard(tester);
    await openDialog(tester);

    await tester.tap(find.widgetWithText(FilledButton, '复制口令'));
    await tester.pump();

    expect(written, hasLength(1));
    expect(written.single, previewText(tester));
    expect(written.single, startsWith('复制口令到阅读导入'));
    expect(find.text('已复制到剪贴板'), findsOneWidget);
    expect(find.text('已复制'), findsOneWidget);

    // 2 秒后内联提示与按钮文案恢复
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('已复制到剪贴板'), findsNothing);
    expect(find.widgetWithText(FilledButton, '复制口令'), findsOneWidget);
  });
}
