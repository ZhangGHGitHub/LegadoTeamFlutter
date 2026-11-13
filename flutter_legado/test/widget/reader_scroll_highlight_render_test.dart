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
/// ④ [ReaderParagraphs] 回退渲染同样按章节坐标切 span（第 3 段定位）；
/// ⑤ 批32 P2-2：CRLF 正文（`\r\n`）第 3 段定位、多命中共存
///    （早段 + 晚段，游标推进）、乱序输入兜底；
/// ⑥ 批32 P3-3：CRLF 跨段命中不染色段尾不可见 `\r`（两路渲染）。
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

/// 构造带红色背景的手动高亮命中（[start, end) 章节全局偏移）
HighlightMatch redMatch(int start, int end, {int order = 1}) {
  return HighlightMatch(
    ruleId: -1,
    start: start,
    end: end,
    order: order,
    style: HighlightStyle.fromMap(const {'fill': 0x33FF0000}),
  );
}

/// 直接挂载滚动回退渲染（[ReaderParagraphs]）
Future<void> pumpReaderParagraphs(
  WidgetTester tester, {
  required String content,
  required List<HighlightMatch> matches,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReaderParagraphs(
            content: content,
            fontSize: 14,
            lineHeight: 1.4,
            paragraphSpacing: 8,
            textColor: Colors.black,
            highlightMatches: matches,
          ),
        ),
      ),
    ),
  );
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

  // CRLF 三段落正文（段间 `\r\n`，每段 7 字）：
  //   第 1 段 [0,7)，'\r'=7，'\n'=8
  //   第 2 段 [9,16)，'\r'=16，'\n'=17
  //   第 3 段 [18,25)
  const crlfThreeParagraphs = '第一段落文字。\r\n第二段落文字。\r\n第三段落文字。';
  const crlfThirdParagraphStart = 18;

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

  testWidgets('滚动模式多段章节（CRLF）：第 3 段高亮位置正确', (tester) async {
    final api = MockBookApi();
    await seedSavedHighlight(
      api,
      bookText: crlfThreeParagraphs,
      chapterPos: crlfThirdParagraphStart,
      chapterPosEnd: crlfThirdParagraphStart + 3,
    );

    await pumpScrollReader(tester, api: api, content: crlfThreeParagraphs);

    expect(
      hasSpan(tester, '第三段', background: const Color(0x33FF0000)),
      isTrue,
      reason: 'CRLF 的 \\r 也计入章节偏移：7 + 2 + 7 + 2 = 18',
    );
    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isFalse,
    );
    expect(
      hasSpan(tester, '第二段', background: const Color(0x33FF0000)),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ReaderParagraphs 回退渲染（CRLF）：第 3 段高亮位置正确', (tester) async {
    await pumpReaderParagraphs(
      tester,
      content: crlfThreeParagraphs,
      matches: [redMatch(crlfThirdParagraphStart, crlfThirdParagraphStart + 3)],
    );

    expect(
      hasSpan(tester, '第三段', background: const Color(0x33FF0000)),
      isTrue,
      reason: 'split 后 \\r 留在段尾，offset 累计需同时计入 \\r 与 \\n',
    );
    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isFalse,
    );
    expect(
      hasSpan(tester, '第二段', background: const Color(0x33FF0000)),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动模式多命中共存：早段与晚段都染色、中间段不染', (tester) async {
    final api = MockBookApi();
    await seedSavedHighlight(
      api,
      bookText: threeParagraphs,
      chapterPos: 0,
      chapterPosEnd: 3,
    );
    await seedSavedHighlight(
      api,
      bookText: threeParagraphs,
      chapterPos: thirdParagraphStart,
      chapterPosEnd: thirdParagraphStart + 3,
    );

    await pumpScrollReader(tester, api: api, content: threeParagraphs);

    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '早段命中不能因游标推进而丢失',
    );
    expect(
      hasSpan(tester, '第三段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '游标推进后晚段命中仍需渲染',
    );
    expect(
      hasSpan(tester, '第二段', background: const Color(0x33FF0000)),
      isFalse,
      reason: '中间段未被任何命中覆盖',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ReaderParagraphs 多命中共存：首尾染色、中间不染', (tester) async {
    await pumpReaderParagraphs(
      tester,
      content: threeParagraphs,
      matches: [redMatch(0, 3), redMatch(16, 19)],
    );

    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isTrue,
    );
    expect(
      hasSpan(tester, '第三段', background: const Color(0x33FF0000)),
      isTrue,
    );
    expect(
      hasSpan(tester, '第二段', background: const Color(0x33FF0000)),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ReaderParagraphs 乱序命中（晚段在前）：两处都染色', (tester) async {
    await pumpReaderParagraphs(
      tester,
      content: threeParagraphs,
      // 乱序输入：晚段在前、早段在后（非合并结果契约之外的历史/坏数据）
      matches: [redMatch(16, 19, order: 1), redMatch(0, 3, order: 2)],
    );

    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '乱序兜底应在段落遍历前排序一次，早段命中不能丢',
    );
    expect(
      hasSpan(tester, '第三段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '乱序兜底后晚段命中仍需渲染',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ReaderParagraphs（CRLF）多命中跨段：不染色段尾 \\r', (tester) async {
    const content = '第一段落文字。\r\n第二段落文字。';
    // 两个命中，其中 [5,12) 跨段：第 1 段 [5,7)（字。），跨过 '\r\n'
    // 后第 2 段 [9,12)。多命中同时覆盖游标「遇跨段命中不得提前跳过」。
    await pumpReaderParagraphs(
      tester,
      content: content,
      matches: [redMatch(0, 3, order: 1), redMatch(5, 12, order: 2)],
    );

    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '早段命中应渲染',
    );
    expect(
      hasSpan(tester, '字。', background: const Color(0x33FF0000)),
      isTrue,
      reason: '跨段命中在第 1 段应裁剪到正文末尾',
    );
    final crSpans = findSpans(tester, '字。\r');
    expect(
      crSpans,
      isEmpty,
      reason: '段尾 \\r 是分隔符，不应进入渲染 span 被下划线/背景染色',
    );
    expect(
      hasSpan(tester, '第二段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '跨段命中在第 2 段应继续染色（游标判据不能只看 start）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动模式（CRLF）多命中跨段：两段都染色且不含 \\r', (tester) async {
    const content = '第一段落文字。\r\n第二段落文字。';
    final api = MockBookApi();
    await seedSavedHighlight(
      api,
      bookText: content,
      chapterPos: 0,
      chapterPosEnd: 3,
    );
    await seedSavedHighlight(
      api,
      bookText: content,
      chapterPos: 5,
      chapterPosEnd: 12,
    );

    await pumpScrollReader(tester, api: api, content: content);

    expect(
      hasSpan(tester, '第一段', background: const Color(0x33FF0000)),
      isTrue,
    );
    expect(
      hasSpan(tester, '字。', background: const Color(0x33FF0000)),
      isTrue,
    );
    expect(
      hasSpan(tester, '第二段', background: const Color(0x33FF0000)),
      isTrue,
      reason: '跨段命中在第 2 行需继续染色（游标判据不能只看 start）',
    );
    expect(
      findSpans(tester, '字。\r'),
      isEmpty,
      reason: '分页排版路径已 trim 段落，\\r 不应出现在正文 span 中',
    );
    expect(tester.takeException(), isNull);
  });
}
