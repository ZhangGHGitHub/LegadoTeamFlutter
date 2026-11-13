/// 滚动阅读模式正文高亮渲染测试
///
/// 缺陷背景：滚动模式（[PageTurnMode.scroll]）下 `HighlightMatchRequest`
/// 的 `enabled` 恒为 false（Rule/笔记/手动高亮三路都不加载），且滚动正文
/// 渲染未把 `_combinedHighlightMatches` 传给渲染层。用户切到滚动模式后，
/// 规则高亮与手动高亮全部消失（分页模式正常）。
///
/// 覆盖：
/// ① 滚动模式 + 规则高亮 → 正文出现高亮 span；
/// ② 滚动模式 + 手动高亮 → 正文出现高亮 span；
/// ③ 多段章节第 3 段高亮 → 位置正确（验证 `\n` 计入章节偏移累计）；
/// ④ [ReaderParagraphs] 回退渲染同样按章节坐标切 span（第 3 段定位）。
library;

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
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';

const bookUrl = 'https://src.com/scroll-book';
const bookName = '滚动高亮书';
const bookAuthor = '作者S';

/// 固定状态 Notifier：不调用父类 build（避免 SharedPreferences 覆写翻页模式）
class _FixedReaderNotifier extends ReaderNotifier {
  _FixedReaderNotifier(this.initial);

  final ReaderState initial;

  @override
  ReaderState build() => initial;
}

ReaderState scrollReaderState(String content) {
  return ReaderState(
    currentBook: const Book(
      bookUrl: bookUrl,
      name: bookName,
      author: bookAuthor,
      origin: 'https://src.com',
    ),
    chapters: const [BookChapter(url: 'u0', title: '第一章', index: 0)],
    currentChapterIndex: 0,
    chapterContent: content,
    fontSize: 14,
    lineHeight: 1.4,
    pageTurnMode: PageTurnMode.scroll,
  );
}

Widget wrap(ProviderContainer container) {
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

Future<void> pumpScrollReader(
  WidgetTester tester, {
  required MockBookApi api,
  required String content,
}) async {
  final container = ProviderContainer(
    overrides: [
      bookApiProvider.overrideWithValue(api),
      readerNotifierProvider.overrideWith(
        () => _FixedReaderNotifier(scrollReaderState(content)),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(wrap(container));
  await tester.pumpAndSettle();
  // 分页后的章节字数回写 Timer 在 pumpAndSettle 退出后仍 pending
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> seedSavedHighlight(
  MockBookApi api, {
  required String bookText,
  required int chapterPos,
  required int chapterPosEnd,
  String style = '{"type":"background","color":"#33FF0000"}',
}) async {
  await api.highlightAdd(
    highlightJson: jsonEncode({
      'time': 0,
      'bookUrl': bookUrl,
      'chapterUrl': 'u0',
      'bookName': bookName,
      'bookAuthor': bookAuthor,
      'chapterIndex': 0,
      'chapterPos': chapterPos,
      'chapterPosEnd': chapterPosEnd,
      'layoutTitleLength': 0,
      'chapterName': '第一章',
      'bookText': bookText,
      'style': style,
      'note': '',
    }),
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

  // 三段落正文（含 2 个换行符）：
  //   第 1 段 [0,7)  「第一段落文字。」
  //   '\n'   [7,8)
  //   第 2 段 [8,15) 「第二段落文字。」
  //   '\n'   [15,16)
  //   第 3 段 [16,23)「第三段落文字。」
  const threeParagraphs = '第一段落文字。\n第二段落文字。\n第三段落文字。';
  const thirdParagraphStart = 16;

  testWidgets('滚动模式 + 规则高亮：正文出现高亮 span（修复前红）', (tester) async {
    final api = MockBookApi();
    await api.highlightRuleSave(
      ruleJson: jsonEncode({
        'name': '滚动规则',
        'pattern': '高亮文字',
        'isRegex': false,
        'scope': '',
        'isEnabled': true,
        'style': jsonEncode(const HighlightStyle(fill: 0x330000FF).toMap()),
        'sortOrder': 5,
        'applyToTitle': false,
        'applyToBody': true,
      }),
    );

    await pumpScrollReader(
      tester,
      api: api,
      content: '高亮文字其余正文',
    );

    expect(
      hasSpan(tester, '高亮文字', background: const Color(0x330000FF)),
      isTrue,
      reason: '滚动模式也应渲染规则高亮',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动模式 + 手动高亮：正文出现高亮 span（修复前红）', (tester) async {
    final api = MockBookApi();
    await seedSavedHighlight(
      api,
      bookText: '高亮文字',
      chapterPos: 0,
      chapterPosEnd: 4,
    );

    await pumpScrollReader(
      tester,
      api: api,
      content: '高亮文字其余正文',
    );

    expect(
      hasSpan(tester, '高亮文字', background: const Color(0x33FF0000)),
      isTrue,
      reason: '滚动模式也应把 highlights 表的已存高亮渲染到正文',
    );
  });

  testWidgets('滚动模式多段章节：第 3 段高亮位置正确（换行符计入偏移）', (tester) async {
    final api = MockBookApi();
    await seedSavedHighlight(
      api,
      bookText: '第三段',
      chapterPos: thirdParagraphStart,
      chapterPosEnd: thirdParagraphStart + 3,
    );

    await pumpScrollReader(tester, api: api, content: threeParagraphs);

    expect(
      hasSpan(tester, '第三段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '第 3 段起点 = 第 1 段长度 + 换行 + 第 2 段长度 + 换行 = 16',
    );
    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isFalse,
      reason: '换行符漏计会使高亮整体前移，错误染到第 1 段',
    );
    expect(
      hasSpan(tester, '第二段', background: const Color(0x33FF0000)),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ReaderParagraphs 回退渲染：第 3 段高亮位置正确', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReaderParagraphs(
              content: threeParagraphs,
              fontSize: 14,
              lineHeight: 1.4,
              paragraphSpacing: 8,
              textColor: Colors.black,
              highlightMatches: [
                HighlightMatch(
                  ruleId: -1,
                  start: thirdParagraphStart,
                  end: thirdParagraphStart + 3,
                  order: 1,
                  style: HighlightStyle.fromMap(const {
                    'fill': 0x33FF0000,
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      hasSpan(tester, '第三段', background: const Color(0x33FF0000)),
      isTrue,
      reason: 'ReaderParagraphs 需按章节全局坐标 + 换行累计定位第 3 段',
    );
    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
