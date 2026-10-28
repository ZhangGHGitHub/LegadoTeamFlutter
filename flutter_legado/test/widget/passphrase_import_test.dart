// 分享口令导入入口 widget 测试（批25）
//
// 覆盖：成功解码 → 按类型进入关联导入确认框；NotFound / Invalid / Expired
// 三类明确中文提示；7 类口令 code → ImportType 映射。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/services/source_share_passphrase.dart';
import 'package:flutter_legado/src/widgets/passphrase_import.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';

/// 记录路由入参的假 Notifier（不触 FFI）
class _RecordingAssociationNotifier extends AssociationNotifier {
  ImportType? bootstrappedType;
  String? bootstrappedUrl;
  String? loadedText;

  @override
  AssociationState build() => const AssociationState();

  @override
  Future<void> bootstrapFromDeepLink({
    ImportType? type,
    required String srcUrl,
  }) async {
    bootstrappedType = type;
    bootstrappedUrl = srcUrl;
    _ready(type ?? ImportType.bookSource);
  }

  @override
  Future<void> loadFromText(String content, {ImportType? typeHint}) async {
    loadedText = content;
    _ready(typeHint ?? ImportType.bookSource);
  }

  void _ready(ImportType type) {
    state = AssociationState(
      type: type,
      items: const [
        AssociationItem(
          raw: {'name': '测试规则', 'bookSourceUrl': 'https://a'},
          name: '测试规则',
          status: ImportItemStatus.isNew,
        ),
      ],
    );
  }
}

void main() {
  late _RecordingAssociationNotifier notifier;

  setUp(() {
    notifier = _RecordingAssociationNotifier();
  });

  Future<void> pumpHost(
    WidgetTester tester,
    String text,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          associationNotifierProvider.overrideWith(() => notifier),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: const Key('importPassphrase'),
                  onPressed: () {
                    unawaited(importPassphraseText(context, text));
                  },
                  child: const Text('导入口令'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('importPassphrase')));
    await tester.pumpAndSettle();
  }

  testWidgets('字典规则口令 → 按类型拉起关联导入并解码 URL', (tester) async {
    await pumpHost(
      tester,
      '复制口令到阅读导入#L:example电com/a！zd©0¥Legado^',
    );

    expect(notifier.bootstrappedType, ImportType.dictRule);
    expect(notifier.bootstrappedUrl, 'https://example.com/a');
    expect(find.text('导入字典规则'), findsOneWidget);
    expect(find.text('确认（1）'), findsOneWidget);
  });

  testWidgets('带有效期的口令同样可导入', (tester) async {
    await pumpHost(
      tester,
      '复制口令到阅读导入#L:example电com/a！dy©9999999999999¥Legado^',
    );

    expect(notifier.bootstrappedType, ImportType.rssSource);
    expect(notifier.bootstrappedUrl, 'https://example.com/a');
    expect(find.text('导入 RSS 源'), findsOneWidget);
  });

  testWidgets('无前缀 → 「不是分享口令」提示', (tester) async {
    await pumpHost(tester, 'hello world');

    expect(notifier.bootstrappedUrl, isNull);
    expect(find.text('不是分享口令'), findsOneWidget);
    expect(find.textContaining('未识别到「复制口令到阅读导入」前缀'), findsOneWidget);
  });

  testWidgets('未知类型 → 「口令无效」提示', (tester) async {
    await pumpHost(
      tester,
      '复制口令到阅读导入#L:example电com/a！xx©0¥Legado^',
    );

    expect(notifier.bootstrappedUrl, isNull);
    expect(find.text('口令无效'), findsOneWidget);
  });

  testWidgets('过期 token → 「口令已过期」提示且不进入导入', (tester) async {
    await pumpHost(
      tester,
      '复制口令到阅读导入#L:example电com/a！sy©1234567890123¥Legado^',
    );

    expect(notifier.bootstrappedUrl, isNull);
    expect(find.text('口令已过期'), findsOneWidget);
    expect(find.textContaining('请联系分享者重新生成'), findsOneWidget);
  });

  testWidgets('剪贴板为空 → 「剪贴板为空」提示且不进入导入', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          // Flutter 侧 `result['text'] as String` 不接受 null：空剪贴板以
          // 平台调用整体返回 null 表达（Clipboard.getData → ClipboardData?）
          return null;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          associationNotifierProvider.overrideWith(() => notifier),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: const Key('importFromClipboard'),
                  onPressed: () {
                    unawaited(importPassphraseFromClipboard(context));
                  },
                  child: const Text('从剪贴板导入'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('importFromClipboard')));
    await tester.pumpAndSettle();

    expect(find.text('剪贴板为空'), findsOneWidget);
    expect(find.textContaining('请先复制分享口令'), findsOneWidget);
    expect(notifier.bootstrappedUrl, isNull);
  });

  test('7 类口令 code 全部映射到 ImportType', () {
    expect(
      passphraseImportType(SourcePassphraseType.bookSource),
      ImportType.bookSource,
    );
    expect(
      passphraseImportType(SourcePassphraseType.rssSource),
      ImportType.rssSource,
    );
    expect(
      passphraseImportType(SourcePassphraseType.dictRule),
      ImportType.dictRule,
    );
    expect(
      passphraseImportType(SourcePassphraseType.replaceRule),
      ImportType.replaceRule,
    );
    expect(
      passphraseImportType(SourcePassphraseType.tocRule),
      ImportType.txtTocRule,
    );
    expect(
      passphraseImportType(SourcePassphraseType.ttsRule),
      ImportType.httpTts,
    );
    expect(
      passphraseImportType(SourcePassphraseType.autoTask),
      ImportType.autoTask,
    );
  });
}
