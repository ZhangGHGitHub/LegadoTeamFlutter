/// 笔记 Sheet（MarkingSheet）组件测试（契约 §2.52，批7b-2a）
///
/// 覆盖：新建/编辑标题、预览效果、16 色板、7 效果格、备注、保存落库、
/// 编辑模式删除二次确认、360dp 无溢出。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/marking_sheet.dart';

BookMarking _existing({
  String id = 'm1',
  int note = 0,
  BookMarkingStyle? style,
  String selectedText = '已有选中文本',
}) {
  return BookMarking(
    id: id,
    bookUrl: 'https://src.com/book/1',
    bookName: '测试书',
    bookAuthor: '作者A',
    chapterIndex: 0,
    anchorJson: buildBookMarkingAnchor(
      chapterIndex: 0,
      chapterPosition: 8,
      selectedText: selectedText,
    ).encode(),
    styleJson: (style ?? MarkingEffect.wave.toStyle(0xFF22C55E)).encode(),
    note: note == 0 ? '已有备注' : '备注$note',
    chapterName: '第一章',
    enabled: true,
    createdAt: 1000,
    updatedAt: 2000,
  );
}

void main() {
  late MockBookApi api;

  setUp(() => api = MockBookApi());

  Widget host({BookMarking? existing, String selectedText = '选中文本'}) {
    final anchor = BookMarkingAnchor.tryParse(existing?.anchorJson);
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open-marking-sheet'),
              onPressed: () {
                MarkingSheet.show(
                  context,
                  bookName: '测试书',
                  bookAuthor: '作者A',
                  bookUrl: 'https://src.com/book/1',
                  chapterIndex: 0,
                  chapterName: existing?.chapterName ?? '第一章',
                  chapterPosition: anchor?.chapterPosition ?? 12,
                  selectedText: anchor?.selectedText ?? selectedText,
                  contextBefore: '前文',
                  contextAfter: '后文',
                  existing: existing,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester, {BookMarking? existing}) async {
    await tester.pumpWidget(host(existing: existing));
    await tester.tap(find.byKey(const ValueKey('open-marking-sheet')));
    await tester.pumpAndSettle();
  }

  Finder keyedPrefix(String prefix) => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith(prefix),
  );

  /// 色板色块（排除滚动容器 key `marking-color-row`）
  Finder colorSwatches() => find.byWidgetPredicate((w) {
    final key = w.key;
    if (key is! ValueKey<String>) return false;
    return RegExp(
      r'^marking-color-[0-9a-f]+$',
    ).hasMatch(key.value);
  });

  testWidgets('新建：标题/预览/16 色板/7 效果格/备注输入', (tester) async {
    await open(tester);
    expect(find.byKey(const ValueKey('marking-sheet')), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('编辑笔记'), findsNothing);
    expect(find.text('选中文本'), findsOneWidget);
    expect(colorSwatches(), findsNWidgets(16));
    expect(keyedPrefix('marking-effect-'), findsNWidgets(7));
    for (final effect in MarkingEffect.values) {
      expect(
        find.byKey(ValueKey('marking-effect-${effect.name}')),
        findsOneWidget,
      );
    }
    expect(find.byKey(const ValueKey('marking-note-field')), findsOneWidget);
  });

  testWidgets('效果选择实时更新预览（波浪线）', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('marking-effect-wave')));
    await tester.pump();
    final preview = tester.widget<Text>(
      find.byKey(const ValueKey('marking-preview')),
    );
    expect(preview.style?.decoration, TextDecoration.underline);
    expect(preview.style?.decorationStyle, TextDecorationStyle.wavy);

    await tester.tap(find.byKey(const ValueKey('marking-effect-strike')));
    await tester.pump();
    final strike = tester.widget<Text>(
      find.byKey(const ValueKey('marking-preview')),
    );
    expect(strike.style?.decoration, TextDecoration.lineThrough);

    await tester.tap(find.byKey(const ValueKey('marking-effect-bg')));
    await tester.pump();
    final bg = tester.widget<Text>(
      find.byKey(const ValueKey('marking-preview')),
    );
    expect(
      bg.style?.backgroundColor,
      isNotNull,
    );
    expect(bg.style?.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('保存新建：落库锚点/样式/备注并关闭 Sheet', (tester) async {
    await open(tester, existing: null);
    await tester.tap(find.byKey(const ValueKey('marking-effect-dashed')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('marking-note-field')),
      '  新备注  ',
    );
    await tester.tap(find.byKey(const ValueKey('marking-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('marking-sheet')), findsNothing);
    final list = await api.getBookMarkingsByBook('测试书', '作者A');
    expect(list, hasLength(1));
    final saved = list.single;
    expect(saved.note, '新备注');
    expect(saved.chapterName, '第一章');
    final anchor = BookMarkingAnchor.tryParse(saved.anchorJson)!;
    expect(anchor.selectedText, '选中文本');
    expect(anchor.chapterPosition, 12);
    expect(anchor.contextBefore, '前文');
    final style = BookMarkingStyle.tryParse(saved.styleJson)!;
    expect(style.underlineMode, 2, reason: '虚线');
  });

  testWidgets('编辑：预填备注/样式；保存更新保留 id/createdAt', (tester) async {
    final existing = _existing();
    await api.saveBookMarking(existing);
    await open(tester, existing: existing);
    expect(find.text('编辑笔记'), findsOneWidget);
    expect(find.byKey(const ValueKey('marking-delete')), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('marking-note-field')),
    );
    expect(field.controller?.text, '已有备注');
    expect(find.text('已有选中文本'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('marking-note-field')),
      '更新备注',
    );
    await tester.tap(find.byKey(const ValueKey('marking-save')));
    await tester.pumpAndSettle();

    final list = await api.getBookMarkingsByBook('测试书', '作者A');
    expect(list, hasLength(1));
    expect(list.single.id, existing.id);
    expect(list.single.createdAt, 1000);
    expect(list.single.note, '更新备注');
  });

  testWidgets('编辑删除：二次确认后删除并关闭', (tester) async {
    final existing = _existing();
    // 先落库，删除才有实际对象
    await api.saveBookMarking(existing);
    await open(tester, existing: existing);

    await tester.tap(find.byKey(const ValueKey('marking-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除笔记？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('marking-delete-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('marking-sheet')), findsOneWidget);
    expect(await api.getBookMarkingsByBook('测试书', '作者A'), hasLength(1));

    await tester.tap(find.byKey(const ValueKey('marking-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('marking-delete-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('marking-sheet')), findsNothing);
    expect(await api.getBookMarkingsByBook('测试书', '作者A'), isEmpty);
  });

  testWidgets('360dp 窄屏：色板/效果格/预览不横向溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await open(tester, existing: _existing());
    expect(colorSwatches(), findsNWidgets(16));
    expect(keyedPrefix('marking-effect-'), findsNWidgets(7));
    expect(
      tester.takeException(),
      isNull,
      reason: '360dp 下 MarkingSheet 不应出现 RenderFlex 溢出',
    );
  });
}
