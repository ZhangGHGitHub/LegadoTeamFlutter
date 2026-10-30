// [批43b P2-1] 阅读器「TXT 目录规则」弹层反馈用例：
// - 规则命中 → 「已应用目录规则」
// - 规则未命中回退默认 → 「规则未命中，已回退默认规则」（不再假报已应用）
// - 恢复默认 → 「已恢复默认目录规则」（usedCustomRule=false 属预期）
// - 重载失败 → 展示失败原因，不得提示成功
// - 非本地 TXT → 入口兜底提示，不打开弹层
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart' show bookApiProvider;
import 'package:flutter_legado/src/providers/txt_toc_rules/txt_toc_rules_notifier.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/reader_toc_rule_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rule = TxtTocRule(
    id: 7,
    name: '方括号篇',
    rule: r'^【第.+篇】.*$',
    replacement: '',
    enable: true,
  );

  const book = Book(
    bookUrl: 'books/a.txt',
    name: '本地 TXT',
    origin: BookType.localTag,
    originName: 'a.txt',
  );

  late MockBookApi api;

  setUp(() async {
    // 版本号已升级 → 跳过内置默认规则灌入，只保留本用例注入的规则
    SharedPreferences.setMockInitialValues({kTxtTocRuleVersionKey: kTxtTocRuleVersion});
    api = MockBookApi();
    await api.addBook(book);
    await api.setConfig(
      'txt_toc_rules',
      jsonEncode([rule.toJson()]),
    );
  });

  Widget host({
    Book target = book,
    required Future<TocRuleReloadResult> Function(Book) onApplied,
  }) {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showReaderTocRuleDialog(
                  context,
                  ref,
                  book: target,
                  onApplied: onApplied,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('TXT 目录规则'), findsOneWidget);
  }

  /// 选中规则并确认；等待异步回调链完成（Mock 初始化 Future 在 setUp 的
  /// 真实异步区完成，需让出一次真实事件循环，假异步区才能看到结果）
  Future<void> applyRule(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('规则命中：提示已应用', (tester) async {
    String? appliedRule;
    await tester.pumpWidget(host(
      onApplied: (updated) async {
        appliedRule = 'captured';
        return (error: null, usedCustomRule: true);
      },
    ));
    await openDialog(tester);
    await applyRule(tester, '方括号篇');

    expect(appliedRule, isNotNull);
    expect(find.text('已应用目录规则'), findsOneWidget);
  });

  testWidgets('规则未命中：提示已回退默认，不提示已应用', (tester) async {
    await tester.pumpWidget(host(
      onApplied: (_) async => (error: null, usedCustomRule: false),
    ));
    await openDialog(tester);
    await applyRule(tester, '方括号篇');

    expect(find.text('规则未命中，已回退默认规则'), findsOneWidget);
    expect(find.text('已应用目录规则'), findsNothing);
  });

  testWidgets('恢复默认：传 null 规则并提示已恢复', (tester) async {
    String? appliedRule = 'sentinel';
    await tester.pumpWidget(host(
      onApplied: (_) async {
        appliedRule = null;
        return (error: null, usedCustomRule: false);
      },
    ));
    await openDialog(tester);
    await applyRule(tester, '默认规则');

    expect(appliedRule, isNull);
    expect(find.text('已恢复默认目录规则'), findsOneWidget);
    expect(find.text('规则未命中，已回退默认规则'), findsNothing);
  });

  testWidgets('重载失败：展示失败原因，不提示成功', (tester) async {
    await tester.pumpWidget(host(
      onApplied: (_) async => (error: '目录为空（可尝试其它规则）', usedCustomRule: false),
    ));
    await openDialog(tester);
    await applyRule(tester, '方括号篇');

    expect(
      find.text('应用目录规则后重载失败：目录为空（可尝试其它规则）'),
      findsOneWidget,
    );
    expect(find.text('已应用目录规则'), findsNothing);
    expect(find.text('规则未命中，已回退默认规则'), findsNothing);
  });

  testWidgets('非本地 TXT：不打开弹层并提示不适用', (tester) async {
    const epub = Book(
      bookUrl: 'books/a.epub',
      name: '本地 EPUB',
      origin: BookType.localTag,
      originName: 'a.epub',
    );
    await tester.pumpWidget(host(
      target: epub,
      onApplied: (_) async => (error: null, usedCustomRule: true),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('TXT 目录规则仅适用于本地 TXT 书籍'), findsOneWidget);
    expect(find.text('确定'), findsNothing);
  });
}
