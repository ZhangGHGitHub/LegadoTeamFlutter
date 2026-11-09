/// 阅读页书签标记正文渲染测试（批7b-2b）
///
/// 覆盖：paged 模式 BG/TEXT/STRIKE/WAVE 四类 mark 渲染、规则与 mark 重叠
/// 合并、切换章节后旧 marks 清空、修订号变化后即时更新、360dp 无溢出。
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

/// 第 1 章请求挂起、第 2 章立即返回（P2-1 旧失败不覆盖新章）
class _FlakyMarkingApi extends MockBookApi {
  _FlakyMarkingApi({required this.secondChapterMarkings});

  final List<BookMarking> secondChapterMarkings;
  final Completer<List<BookMarking>> firstChapter = Completer();
  final List<int?> requestedChapters = [];

  @override
  Future<List<BookMarking>> getBookMarkingsForChapter(
    String bookUrl,
    int? chapterIndex,
  ) {
    requestedChapters.add(chapterIndex);
    if (chapterIndex == 0) return firstChapter.future;
    return Future.value(secondChapterMarkings);
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

Future<BookMarking> seedMark(
  MockBookApi api, {
  required String text,
  required int position,
  required BookMarkingStyle style,
  int chapterIndex = 0,
  bool enabled = true,
}) {
  return api.saveBookMarking(
    BookMarking(
      bookUrl: bookUrl,
      bookName: bookName,
      bookAuthor: bookAuthor,
      chapterIndex: chapterIndex,
      anchorJson: buildBookMarkingAnchor(
        chapterIndex: chapterIndex,
        chapterPosition: position,
        selectedText: text,
      ).encode(),
      styleJson: style.encode(),
      note: '',
      chapterName: '第${chapterIndex + 1}章',
      enabled: enabled,
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

/// 某文本是否至少有一个满足条件的 span
bool hasSpan(
  WidgetTester tester,
  String text, {
  Color? background,
  Color? color,
  TextDecoration? decoration,
  TextDecorationStyle? decorationStyle,
}) {
  for (final span in findSpans(tester, text)) {
    final style = span.style;
    if (style == null) continue;
    if (background != null && style.backgroundColor != background) continue;
    if (color != null && style.color != color) continue;
    if (decoration != null && style.decoration != decoration) continue;
    if (decorationStyle != null && style.decorationStyle != decorationStyle) {
      continue;
    }
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

  testWidgets('paged 正文渲染 BG/TEXT/STRIKE/WAVE 四类标记', (tester) async {
    final api = MockBookApi();
    const content = '背景文字字体文字删除文字波浪文字';
    await seedMark(
      api,
      text: '背景文字',
      position: 0,
      style: const BookMarkingStyle(bgColor: 0x33FF0000),
    );
    await seedMark(
      api,
      text: '字体文字',
      position: 4,
      style: const BookMarkingStyle(textColor: 0xFF0000FF),
    );
    await seedMark(
      api,
      text: '删除文字',
      position: 8,
      style: const BookMarkingStyle(
        underlineMode: 6,
        underlineColor: 0xFF333333,
      ),
    );
    await seedMark(
      api,
      text: '波浪文字',
      position: 12,
      style: const BookMarkingStyle(
        underlineMode: 3,
        underlineColor: 0xFF00AA00,
        underlineWidth: 2,
      ),
    );

    await pumpReader(
      tester,
      api: api,
      state: readerState(content: content),
    );

    expect(
      hasSpan(tester, '背景文字', background: const Color(0x33FF0000)),
      isTrue,
      reason: 'BG 应渲染为背景色',
    );
    expect(
      hasSpan(tester, '字体文字', color: const Color(0xFF0000FF)),
      isTrue,
      reason: 'TEXT 应渲染为字色',
    );
    expect(
      hasSpan(tester, '删除文字', decoration: TextDecoration.lineThrough),
      isTrue,
      reason: 'STRIKE 应渲染删除线',
    );
    expect(
      hasSpan(
        tester,
        '波浪文字',
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.wavy,
      ),
      isTrue,
      reason: 'WAVE 应渲染波浪下划线',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('规则与 mark 重叠：mark 优先且规则保留未覆盖部分', (tester) async {
    final api = MockBookApi();
    const content = '规则文字笔记文字';
    await api.highlightRuleSave(
      ruleJson: jsonEncode({
        'name': '规则',
        'pattern': '规则文字',
        'isRegex': false,
        'scope': '',
        'isEnabled': true,
        'style': jsonEncode(const HighlightStyle(fill: 0x330000FF).toMap()),
        'sortOrder': 5,
        'applyToTitle': false,
        'applyToBody': true,
      }),
    );
    // mark 与规则后两字重叠（内容 index 2..5）
    await seedMark(
      api,
      text: '文字笔',
      position: 2,
      style: const BookMarkingStyle(bgColor: 0x33FF0000),
    );

    await pumpReader(
      tester,
      api: api,
      state: readerState(content: content),
    );

    expect(
      hasSpan(tester, '规则', background: const Color(0x330000FF)),
      isTrue,
      reason: '规则未被 mark 覆盖的前半段应保留',
    );
    expect(
      hasSpan(tester, '文字笔', background: const Color(0x33FF0000)),
      isTrue,
      reason: 'mark 应覆盖与规则重叠的区间',
    );
    expect(
      hasSpan(tester, '文字笔', background: const Color(0x330000FF)),
      isFalse,
      reason: '重叠区间不得被规则样式覆盖',
    );
  });

  testWidgets('切换章节后旧章 marks 立即清空', (tester) async {
    final api = MockBookApi();
    await seedMark(
      api,
      text: '背景文字',
      position: 0,
      style: const BookMarkingStyle(bgColor: 0x33FF0000),
    );
    final notifier = _SwitchableReaderNotifier(readerState(content: '背景文字在本章'));
    await pumpReader(
      tester,
      api: api,
      state: notifier.initial,
      notifier: notifier,
    );
    expect(
      hasSpan(tester, '背景文字', background: const Color(0x33FF0000)),
      isTrue,
    );

    notifier.switchTo(
      readerState(content: '背景文字在新章', chapterIndex: 1, chapterTitle: '第二章'),
    );
    await tester.pump();
    await tester.pump();
    // 清空是同步的（新章 marks 尚未返回前不应套用旧章区间）
    expect(
      hasSpan(tester, '背景文字', background: const Color(0x33FF0000)),
      isFalse,
    );
    // 分页字数回写 Timer 在切章后重建，推进 1s 避免 teardown 报 pending
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('修订号变化后重新加载标记（BG → TEXT）', (tester) async {
    final api = MockBookApi();
    const content = '背景文字保持不变';
    final saved = await seedMark(
      api,
      text: '背景文字',
      position: 0,
      style: const BookMarkingStyle(bgColor: 0x33FF0000),
    );
    final container = await pumpReader(
      tester,
      api: api,
      state: readerState(content: content),
    );
    expect(
      hasSpan(tester, '背景文字', background: const Color(0x33FF0000)),
      isTrue,
    );

    await api.deleteBookMarking(saved.id);
    await seedMark(
      api,
      text: '背景文字',
      position: 0,
      style: const BookMarkingStyle(textColor: 0xFF0000FF),
    );
    container.read(bookMarkingsRevisionProvider.notifier).state++;
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      hasSpan(tester, '背景文字', color: const Color(0xFF0000FF)),
      isTrue,
      reason: '修订号变化后应加载新样式',
    );
    expect(
      hasSpan(tester, '背景文字', background: const Color(0x33FF0000)),
      isFalse,
    );
  });

  testWidgets('P2-1 旧章请求失败不覆盖新章已渲染标记', (tester) async {
    final api = _FlakyMarkingApi(
      secondChapterMarkings: [
        BookMarking(
          id: 'b-mark',
          bookUrl: bookUrl,
          bookName: bookName,
          bookAuthor: bookAuthor,
          chapterIndex: 1,
          anchorJson: buildBookMarkingAnchor(
            chapterIndex: 1,
            chapterPosition: 0,
            selectedText: 'B标记',
          ).encode(),
          styleJson: const BookMarkingStyle(bgColor: 0x3300FF00).encode(),
          chapterName: '第二章',
        ),
      ],
    );
    final notifier = _SwitchableReaderNotifier(readerState(content: 'A章正文'));
    await pumpReader(
      tester,
      api: api,
      state: notifier.initial,
      notifier: notifier,
    );
    expect(api.requestedChapters, contains(0), reason: 'A 章请求应已发出');

    notifier.switchTo(
      readerState(content: 'B标记', chapterIndex: 1, chapterTitle: '第二章'),
    );
    await tester.pump();
    await tester.pump();
    expect(
      hasSpan(tester, 'B标记', background: const Color(0x3300FF00)),
      isTrue,
      reason: 'B 章标记应先渲染',
    );

    // A 章旧请求迟到失败：不得清空 B 章已采纳的标记
    api.firstChapter.completeError(StateError('A 章加载失败'));
    await tester.pump();
    await tester.pump();
    expect(
      hasSpan(tester, 'B标记', background: const Color(0x3300FF00)),
      isTrue,
      reason: '旧请求失败不得覆盖新章结果',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('360dp 窄屏：带标记正文无 overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = MockBookApi();
    const content = '背景文字字体文字删除文字波浪文字';
    await seedMark(
      api,
      text: '背景文字',
      position: 0,
      style: const BookMarkingStyle(bgColor: 0x33FF0000),
    );
    await seedMark(
      api,
      text: '字体文字',
      position: 4,
      style: const BookMarkingStyle(textColor: 0xFF0000FF),
    );

    await pumpReader(
      tester,
      api: api,
      state: readerState(content: content),
    );
    expect(tester.takeException(), isNull);
  });
}
