/// 阅读页手动高亮（highlights 表）正文渲染测试
///
/// 缺陷背景：保存侧 `TextSelectionPanel._saveHighlight` 写入 `highlights`
/// 表（style = `{"type":"background","color":"#AARRGGBB"}`），但正文渲染链
/// 只读取 `highlight_rules` 规则命中，`highlightListByChapter` 零调用方
/// —— 用户保存高亮后正文内联永不显示。
///
/// 覆盖：按章加载已存高亮并内联渲染、首行缩进偏移对齐、手动高亮优先于
/// 规则高亮、切章不残留、FFI 失败降级、无法映射的样式跳过。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_chrome.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';
import 'package:flutter_legado/src/widgets/reader/text_selection_panel.dart'
    show buildBookHighlightJson, chapterOffsetOfSelection;

const bookUrl = 'https://src.com/book/1';
const bookName = '测试书';
const bookAuthor = '作者A';

class _FixedReaderNotifier extends ReaderNotifier {
  _FixedReaderNotifier(this.initial);

  ReaderState initial;

  @override
  ReaderState build() => initial;
}

class _SwitchableReaderNotifier extends _FixedReaderNotifier {
  _SwitchableReaderNotifier(super.initial);

  void switchTo(ReaderState next) {
    initial = next;
    state = next;
  }
}

/// 第 1 章立即返回、第 2 章挂起：验证切章后旧章高亮同步清空
class _FlakySavedHighlightApi extends MockBookApi {
  _FlakySavedHighlightApi({required this.firstChapterJson});

  final String firstChapterJson;
  final Completer<String> secondChapter = Completer();

  @override
  Future<String> highlightListByChapter({
    required String bookUrl,
    required int chapterIndex,
  }) {
    if (chapterIndex == 0) return Future.value(firstChapterJson);
    return secondChapter.future;
  }
}

/// 恒失败的 highlights 读取（降级与重试预算）
class _FailingSavedHighlightApi extends MockBookApi {
  int calls = 0;

  @override
  Future<String> highlightListByChapter({
    required String bookUrl,
    required int chapterIndex,
  }) async {
    calls++;
    throw StateError('highlights 读取失败');
  }
}

ReaderState readerState({
  required String content,
  int chapterIndex = 0,
  String chapterTitle = '第一章',
}) {
  return ReaderState(
    currentBook: const Book(
      bookUrl: bookUrl,
      name: bookName,
      author: bookAuthor,
      origin: 'https://src.com',
    ),
    chapters: [
      BookChapter(
        url: 'u$chapterIndex',
        title: chapterTitle,
        index: chapterIndex,
      ),
    ],
    currentChapterIndex: chapterIndex,
    chapterContent: content,
    fontSize: 14,
    lineHeight: 1.4,
  );
}

/// BookHighlight JSON（字段与保存侧 `_saveHighlight` 完全一致）
Map<String, dynamic> savedHighlightJson({
  required String bookText,
  required int chapterPos,
  required int chapterPosEnd,
  int chapterIndex = 0,
  int layoutTitleLength = 0,
  String style = '{"type":"background","color":"#33FF0000"}',
}) {
  return {
    'time': 0,
    'bookUrl': bookUrl,
    'chapterUrl': 'u$chapterIndex',
    'bookName': bookName,
    'bookAuthor': bookAuthor,
    'chapterIndex': chapterIndex,
    'chapterPos': chapterPos,
    'chapterPosEnd': chapterPosEnd,
    'layoutTitleLength': layoutTitleLength,
    'chapterName': '第${chapterIndex + 1}章',
    'bookText': bookText,
    'style': style,
    'note': '',
  };
}

Future<void> seedSavedHighlight(
  MockBookApi api, {
  required String bookText,
  required int chapterPos,
  required int chapterPosEnd,
  int chapterIndex = 0,
  int layoutTitleLength = 0,
  String style = '{"type":"background","color":"#33FF0000"}',
}) async {
  await api.highlightAdd(
    highlightJson: jsonEncode(
      savedHighlightJson(
        bookText: bookText,
        chapterPos: chapterPos,
        chapterPosEnd: chapterPosEnd,
        chapterIndex: chapterIndex,
        layoutTitleLength: layoutTitleLength,
        style: style,
      ),
    ),
  );
}

/// 递归查找指定文本的 TextSpan
List<TextSpan> findSpans(WidgetTester tester, String text) {
  final result = <TextSpan>[];
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.text == text) result.add(span);
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child);
    }
  }

  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    walk(rich.text);
  }
  return result;
}

bool hasSpan(
  WidgetTester tester,
  String text, {
  Color? background,
  TextDecoration? decoration,
}) {
  for (final span in findSpans(tester, text)) {
    final style = span.style;
    if (style == null) continue;
    if (background != null && style.backgroundColor != background) continue;
    if (decoration != null && style.decoration != decoration) continue;
    return true;
  }
  return false;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget wrap({required ProviderContainer container}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ReaderPageView(
          paragraphSpacing: 8,
          pageChrome: const ReaderPageChromeConfig(),
          readBodyToLh: false,
        ),
      ),
    );
  }

  Future<ProviderContainer> pumpReader(
    WidgetTester tester, {
    required MockBookApi api,
    required ReaderState state,
    _SwitchableReaderNotifier? notifier,
  }) async {
    final container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        readerNotifierProvider.overrideWith(
          () => notifier ?? _FixedReaderNotifier(state),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(wrap(container: container));
    await tester.pumpAndSettle();
    // 分页后的章节字数回写 Timer 在 pumpAndSettle 退出后仍 pending
    await tester.pump(const Duration(milliseconds: 50));
    return container;
  }

  testWidgets('已存手动高亮在正文内联渲染（修复前红）', (tester) async {
    final api = MockBookApi();
    const content = '高亮文字其余正文';
    await seedSavedHighlight(
      api,
      bookText: '高亮文字',
      chapterPos: 0,
      chapterPosEnd: 4,
    );

    await pumpReader(
      tester,
      api: api,
      state: readerState(content: content),
    );

    expect(
      hasSpan(tester, '高亮文字', background: const Color(0x33FF0000)),
      isTrue,
      reason: 'highlights 表的已存高亮应出现在正文内联渲染中',
    );
  });

  testWidgets('首行缩进全角空格不使高亮区间偏移', (tester) async {
    final api = MockBookApi();
    // 排版渲染段落 = 「　　」（缩进）+ 正文；章节正文本身不含缩进
    const content = '　　首行文字后文';
    // 保存侧 chapterOffsetOfSelection 的结果：正文索引 2 起
    await seedSavedHighlight(
      api,
      bookText: '文字',
      chapterPos: 4,
      chapterPosEnd: 6,
    );

    await pumpReader(
      tester,
      api: api,
      state: readerState(content: content),
    );

    expect(
      hasSpan(tester, '文字', background: const Color(0x33FF0000)),
      isTrue,
      reason: '渲染侧不得再把缩进列计入章节偏移',
    );
    expect(
      hasSpan(tester, '首行', background: const Color(0x33FF0000)),
      isFalse,
      reason: '高亮不得整体左移覆盖缩进后的前两个字',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动高亮优先于规则高亮', (tester) async {
    final api = MockBookApi();
    const content = '重叠文字';
    await api.highlightRuleSave(
      ruleJson: jsonEncode({
        'name': '规则',
        'pattern': '重叠文字',
        'isRegex': false,
        'scope': '',
        'isEnabled': true,
        'style': jsonEncode(const HighlightStyle(fill: 0x330000FF).toMap()),
        'sortOrder': 5,
        'applyToTitle': false,
        'applyToBody': true,
      }),
    );
    await seedSavedHighlight(
      api,
      bookText: '重叠文字',
      chapterPos: 0,
      chapterPosEnd: 4,
      style: '{"type":"background","color":"#33FF0000"}',
    );

    await pumpReader(
      tester,
      api: api,
      state: readerState(content: content),
    );

    expect(
      hasSpan(tester, '重叠文字', background: const Color(0x33FF0000)),
      isTrue,
      reason: '用户显式添加的高亮应覆盖规则命中',
    );
    expect(
      hasSpan(tester, '重叠文字', background: const Color(0x330000FF)),
      isFalse,
    );
  });

  testWidgets('切章后旧章手动高亮立即清空', (tester) async {
    final api = _FlakySavedHighlightApi(
      firstChapterJson: jsonEncode([
        savedHighlightJson(bookText: '高亮文字', chapterPos: 0, chapterPosEnd: 4),
      ]),
    );
    final notifier = _SwitchableReaderNotifier(readerState(content: '高亮文字在本章'));
    await pumpReader(
      tester,
      api: api,
      state: notifier.initial,
      notifier: notifier,
    );
    expect(
      hasSpan(tester, '高亮文字', background: const Color(0x33FF0000)),
      isTrue,
    );

    notifier.switchTo(
      readerState(content: '高亮文字在新章', chapterIndex: 1, chapterTitle: '第二章'),
    );
    await tester.pump();
    await tester.pump();
    // 新章结果尚未返回（挂起），旧章区间必须已同步清空
    expect(
      hasSpan(tester, '高亮文字', background: const Color(0x33FF0000)),
      isFalse,
    );
    // 分页字数回写 Timer 在切章后重建，推进 1s 避免 teardown 报 pending
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('FFI 失败降级为无高亮且正文照常渲染', (tester) async {
    final api = _FailingSavedHighlightApi();
    await pumpReader(
      tester,
      api: api,
      state: readerState(content: '失败正文仍需可读'),
    );

    expect(api.calls, lessThanOrEqualTo(2), reason: '单章最多尝试 2 次');
    expect(find.textContaining('失败正文仍需可读'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(api.calls, lessThanOrEqualTo(2), reason: '预算耗尽后不再每帧重试');
  });

  testWidgets('无法映射的样式跳过：正文正常且无异常', (tester) async {
    final api = MockBookApi();
    await seedSavedHighlight(
      api,
      bookText: '渐变文字',
      chapterPos: 0,
      chapterPosEnd: 4,
      style: '{"type":"gradient","color":"#FF00FF00"}',
    );

    await pumpReader(
      tester,
      api: api,
      state: readerState(content: '渐变文字正文'),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('渐变文字正文'), findsWidgets);
  });

  testWidgets('保存 → 重新加载 → 正文出现（生产构造器往返）', (tester) async {
    final api = MockBookApi();
    const paragraphText = '　　首行文字后文';
    // 章节正文不含缩进：段落正文起点为 2（「首」「行」之前是两个全角空格）
    const paragraphChapterPos = 2;
    final chapterPos = chapterOffsetOfSelection(
      paragraphText: paragraphText,
      chapterPos: paragraphChapterPos,
      selection: '文字',
      fineSelection: true,
      selectionStart: 4,
    );
    expect(chapterPos, 4, reason: '保存侧应扣除缩进列');

    final container = await pumpReader(
      tester,
      api: api,
      state: readerState(content: paragraphText),
    );
    // 保存前无高亮
    expect(hasSpan(tester, '文字', background: const Color(0xFFFFE082)), isFalse);

    // 走生产构造器生成与 _saveHighlight 完全一致的 BookHighlight JSON
    final highlight = buildBookHighlightJson(
      book: const Book(
        bookUrl: bookUrl,
        name: bookName,
        author: bookAuthor,
        origin: 'https://src.com',
      ),
      chapterIndex: 0,
      chapterUrl: 'u0',
      chapterName: '第一章',
      chapterPos: chapterPos,
      selectedText: '文字',
      color: const Color(0xFFFFE082),
      note: '往返用例',
    );
    await api.highlightAdd(highlightJson: jsonEncode(highlight));
    // 保存成功后阅读器自增修订号 → 重新拉取当前章并内联渲染
    container.read(bookHighlightsRevisionProvider.notifier).state++;
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      hasSpan(tester, '文字', background: const Color(0xFFFFE082)),
      isTrue,
      reason: '保存的高亮应经标题/缩进换算后出现在正确位置',
    );
    expect(hasSpan(tester, '首行', background: const Color(0xFFFFE082)), isFalse);
  });

  testWidgets('360dp 窄屏：手动高亮正文无 overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = MockBookApi();
    await seedSavedHighlight(
      api,
      bookText: '高亮文字',
      chapterPos: 0,
      chapterPosEnd: 4,
    );
    await pumpReader(
      tester,
      api: api,
      state: readerState(content: '高亮文字其余正文'),
    );
    expect(tester.takeException(), isNull);
  });
}
