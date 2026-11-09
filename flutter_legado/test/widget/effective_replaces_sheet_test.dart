/// 有效替换规则 Sheet 测试（批7c-1）
///
/// 覆盖：生效过滤（scope/blank/书名空）/合成繁简/重新分段/X 禁用/
/// reload/空态/编辑入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/replace_rule_edit_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/effective_replaces_sheet.dart';

class _FakeReaderNotifier extends ReaderNotifier {
  _FakeReaderNotifier(this.initial);

  ReaderState initial;
  int reloads = 0;

  @override
  ReaderState build() => initial;

  @override
  void updateCurrentBook(Book book) {
    initial = initial.copyWith(currentBook: book);
    state = initial;
  }

  @override
  Future<void> reloadChapterContent() async {
    reloads++;
  }
}

void main() {
  late MockBookApi api;
  late _FakeReaderNotifier reader;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockBookApi();
  });

  Book makeBook({
    String name = '测试书',
    bool reSegment = true,
    bool? useReplaceRule = true,
  }) {
    return Book(
      bookUrl: 'https://book.com/er',
      name: name,
      author: '作者A',
      origin: 'https://source.example.com',
      readConfig: ReadConfig(
        reSegment: reSegment,
        useReplaceRule: useReplaceRule,
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester, {required Book book}) async {
    reader = _FakeReaderNotifier(
      ReaderState(
        currentBook: book,
        chapters: [
          BookChapter(url: 'u0', title: '第一章', index: 0, bookUrl: book.bookUrl),
        ],
        currentChapterIndex: 0,
        chapterContent: '正文',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          readerNotifierProvider.overrideWith(() => reader),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                key: const ValueKey('open-effective-replaces'),
                onPressed: () => EffectiveReplacesSheet.show(context, ref),
                child: const Text('打开有效替换'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-effective-replaces')));
    await tester.pumpAndSettle();
  }

  Future<ReplaceRule> addRule({
    required String name,
    required String pattern,
    String? scope,
    bool scopeContent = true,
    bool isEnabled = true,
  }) {
    return api.addReplaceRule(
      ReplaceRule(
        name: name,
        pattern: pattern,
        replacement: 'X',
        group: '分组',
        scope: scope,
        scopeContent: scopeContent,
        isEnabled: isEnabled,
      ),
    );
  }

  testWidgets('生效过滤 + 合成项置底 + 计数', (tester) async {
    await api.setChineseConvertType(1);
    final effective = await addRule(name: '生效A', pattern: 'a', scope: '测试书');
    await addRule(name: '停用B', pattern: 'b', scope: '测试书', isEnabled: false);
    await addRule(name: '标题C', pattern: 'c', scope: '测试书', scopeContent: false);
    await addRule(name: '外书D', pattern: 'd', scope: '别的书');
    final global = await addRule(name: '全局E', pattern: 'e', scope: null);

    await openSheet(tester, book: makeBook());

    expect(find.text('本章生效 4 条'), findsOneWidget);
    expect(
      find.byKey(ValueKey('effective-replaces-rule-${effective.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('effective-replaces-rule-${global.id}')),
      findsOneWidget,
    );
    expect(find.text('停用B'), findsNothing);
    expect(find.text('标题C'), findsNothing);
    expect(find.text('外书D'), findsNothing);
    expect(find.text('繁简转换（繁转简）'), findsOneWidget);
    expect(find.text('重新分段'), findsOneWidget);
    // 合成项在规则之后
    final aY = tester
        .getTopLeft(
          find.byKey(ValueKey('effective-replaces-rule-${effective.id}')),
        )
        .dy;
    final converterY = tester
        .getTopLeft(find.byKey(const ValueKey('effective-replaces-converter')))
        .dy;
    expect(converterY, greaterThan(aY));
  });

  testWidgets('书名空时 scoped 规则不生效', (tester) async {
    await addRule(name: '作用域规则', pattern: 'a', scope: '测试书');
    await openSheet(tester, book: makeBook(name: '', reSegment: false));
    expect(find.text('本章暂无生效替换规则'), findsOneWidget);
  });

  testWidgets('X 关闭规则：setEnabled(false)+reload+移除', (tester) async {
    final rule = await addRule(name: '规则', pattern: 'a', scope: '测试书');
    await openSheet(tester, book: makeBook(reSegment: false));
    await tester.tap(
      find.byKey(ValueKey('effective-replaces-remove-${rule.id}')),
    );
    await tester.pumpAndSettle();

    final stored = (await api.getReplaceRules()).single;
    expect(stored.isEnabled, isFalse);
    expect(reader.reloads, 1);
    expect(
      find.byKey(ValueKey('effective-replaces-rule-${rule.id}')),
      findsNothing,
    );
  });

  testWidgets('X 关闭繁简转换：type=0+reload', (tester) async {
    await api.setChineseConvertType(2);
    await openSheet(tester, book: makeBook(reSegment: false));
    expect(find.text('繁简转换（简转繁）'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('effective-replaces-remove-converter')),
    );
    await tester.pumpAndSettle();
    expect(await api.getChineseConvertType(), 0);
    expect(reader.reloads, 1);
    expect(find.text('繁简转换（简转繁）'), findsNothing);
  });

  testWidgets('X 关闭重新分段：写 readConfig 并重载', (tester) async {
    await openSheet(tester, book: makeBook(reSegment: true));
    expect(find.text('重新分段'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('effective-replaces-remove-resegment')),
    );
    await tester.pumpAndSettle();
    expect(reader.initial.currentBook?.readConfig?.reSegment, isFalse);
    expect(reader.reloads, 1);
    expect(find.text('重新分段'), findsNothing);
  });

  testWidgets('点合成项提示去阅读设置调整', (tester) async {
    await api.setChineseConvertType(1);
    await openSheet(tester, book: makeBook(reSegment: false));
    await tester.tap(find.text('繁简转换（繁转简）'));
    await tester.pump();
    expect(find.text('请在阅读设置中调整'), findsOneWidget);
  });

  testWidgets('点规则打开编辑页', (tester) async {
    final rule = await addRule(name: '规则', pattern: 'a', scope: '测试书');
    await openSheet(tester, book: makeBook(reSegment: false));
    await tester.tap(
      find.byKey(ValueKey('effective-replaces-rule-${rule.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReplaceRuleEditScreen), findsOneWidget);
  });

  testWidgets('360dp 不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await api.setChineseConvertType(1);
    await addRule(name: '很长的生效规则名称用于溢出检查', pattern: '模式', scope: '测试书');
    await openSheet(tester, book: makeBook(reSegment: true));
    expect(tester.takeException(), isNull);
  });
}
