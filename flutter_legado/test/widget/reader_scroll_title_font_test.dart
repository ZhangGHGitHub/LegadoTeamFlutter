/// [A4 滚动模式标题字体 | full-stack-engineer + UI] 滚动模式标题块
/// 接 C3 标题字体（effectiveTitleFontFamily 单源）
///
/// 背景：C3 标题字体（2.0.242）只在翻页/排版模式生效（测量侧
/// _computeFirstPageHeight + 渲染侧 ReaderTypographicPage 首屏标题块）；
/// 滚动模式标题块（ReaderPageView._buildScrollContent）此前 fontSize+4
/// 硬编码、未接 titleFont。
///
/// 覆盖：① titleFont 非空 → 滚动标题 TextStyle.fontFamily == titleFont
/// （与 effectiveTitleFontFamily 单源同参断言，仿 reader_title_font_test.dart）；
/// ② titleFont 空 = 跟随正文字体（_fontFamily 经 SharedPreferences
/// reader_font_family 注入）。
/// 滚动模式不分页 → 仅渲染侧取值（无测量侧同步需求）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/book_chapter.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_chrome.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';

/// 测试专用 ReaderNotifier：build() 直接返回指定状态，不调用父类
/// build（其 Future.microtask(_loadSettings) 会把 pageTurnMode 覆写为
/// 存储值，干扰滚动模式断言）
class _FixedReaderNotifier extends ReaderNotifier {
  _FixedReaderNotifier(this.initial);

  final ReaderState initial;

  @override
  ReaderState build() => initial;
}

void main() {
  const chapterTitle = '第一章 滚动标题';
  const bodyFont = 'SimSun';
  const titleFont = 'KaiTi';

  /// 滚动模式状态：单章 + 短正文（排版引擎分页出 1 页，标题块常显）
  ReaderState scrollState() => ReaderState(
        chapters: const [BookChapter(title: chapterTitle, index: 0)],
        chapterContent: '滚动模式正文第一段。\n第二段文字。',
        pageTurnMode: PageTurnMode.scroll,
      );

  Widget wrap(ReaderState state, ReaderPageChromeConfig chrome) {
    return ProviderScope(
      overrides: [
        readerNotifierProvider.overrideWith(
          () => _FixedReaderNotifier(state),
        ),
        bookApiProvider.overrideWithValue(MockBookApi()),
      ],
      child: MaterialApp(
        home: ReaderPageView(
          paragraphSpacing: 8,
          pageChrome: chrome,
          // 关闭正文延伸状态栏：测试内 inset 恒 0，断言路径确定
          readBodyToLh: false,
        ),
      ),
    );
  }

  group('A4 滚动模式标题字体（_buildScrollContent 标题块）', () {
    testWidgets('titleFont 非空 → 滚动标题 fontFamily 与单源取值一致',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      const chrome = ReaderPageChromeConfig(titleFont: titleFont);
      // 单源函数（reader_page_chrome.dart effectiveTitleFontFamily）取值
      final expected = effectiveTitleFontFamily(chrome, bodyFont);
      expect(expected, titleFont);

      await tester.pumpWidget(wrap(scrollState(), chrome));
      await tester.pumpAndSettle();

      final titleStyle =
          tester.widget<Text>(find.text(chapterTitle)).style!;
      expect(
        titleStyle.fontFamily,
        expected,
        reason: '滚动标题 fontFamily 须与 effectiveTitleFontFamily 单源一致',
      );
    });

    testWidgets('titleFont 空 → 滚动标题跟随正文字体（_fontFamily）',
        (tester) async {
      // 正文字体经 SharedPreferences reader_font_family 注入
      // （ReaderPageView._refreshFontFamily 异步读取后 setState 重建）
      SharedPreferences.setMockInitialValues({
        'reader_font_family': bodyFont,
      });
      const chrome = ReaderPageChromeConfig();
      final expected = effectiveTitleFontFamily(chrome, bodyFont);
      // 纯函数同参断言（仿 reader_title_font_test.dart：空 titleFont 跟随正文，
      // null 正文=默认字体）
      expect(expected, bodyFont);
      expect(effectiveTitleFontFamily(chrome, null), isNull);

      await tester.pumpWidget(wrap(scrollState(), chrome));
      // 等待 _refreshFontFamily 异步完成（setState 重建）
      await tester.pumpAndSettle();
      // 既有行为（非 A4 引入）：滚动模式 build 会走 _paginateIfNeeded，
      // 其 reader_page_view.dart:616 `Future(() => updateChapterPageCount(...))`
      // 在 SDK 内为 Timer.run（零时长 FakeTimer），创建于该帧 elapse 之后；
      // pumpAndSettle 依 hasScheduledFrame 退出时该 Timer 尚 pending。
      // 追加一次 pump 触发 elapse 使其触发，消除 "Timer still pending" 断言。
      await tester.pump(const Duration(seconds: 1));

      final titleStyle =
          tester.widget<Text>(find.text(chapterTitle)).style!;
      expect(
        titleStyle.fontFamily,
        expected,
        reason: '空 titleFont 时滚动标题应跟随正文字体',
      );
    });
  });
}
