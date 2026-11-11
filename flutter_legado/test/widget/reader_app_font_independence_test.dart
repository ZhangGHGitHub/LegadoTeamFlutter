// [应用字体入口回修 2026-11-11] 应用字体不得泄漏进阅读正文（P1 负例）
// — 全栈工程师
//
// 背景：MaterialApp 的 ThemeData 注入应用字体后，Material 以
// theme.textTheme.bodyMedium 作为 DefaultTextStyle；ReaderTextContent
// 此前用 `fontFamily: null` 的 TextStyle 继承该默认样式，未设置阅读字体时
// 正文实际使用了应用字体。修复后 ReaderPageView 显式取平台默认族名
// （ThemeData.typography），绝不返回 null。
//
// 覆盖：① 环境 DefaultTextStyle 确为应用字体（证明污染源存在）；
// ② 正文 RenderParagraph 实际族名非空且 ≠ 应用字体；
// ③ 阅读字体显式配置时正文仍以 reader_font_family 为准。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/book_chapter.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_chrome.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';

/// 固定状态 ReaderNotifier：不执行父类异步加载，滚动模式断言确定
class _FixedReaderNotifier extends ReaderNotifier {
  _FixedReaderNotifier(this.initial);

  final ReaderState initial;

  @override
  ReaderState build() => initial;
}

void main() {
  const bodyText = '应用字体独立性探针：正文第一段。\n第二段文字。';

  ReaderState scrollState() => ReaderState(
    chapters: const [BookChapter(title: '第一章 字体探针', index: 0)],
    chapterContent: bodyText,
    pageTurnMode: PageTurnMode.scroll,
  );

  Widget wrap({required String? appFontFamily}) {
    final theme = AppTheme.palette(
      brightness: Brightness.light,
      palette: Md3Palettes.def,
      fontFamily: appFontFamily,
    );
    return ProviderScope(
      overrides: [
        readerNotifierProvider.overrideWith(
          () => _FixedReaderNotifier(scrollState()),
        ),
        bookApiProvider.overrideWithValue(MockBookApi()),
      ],
      child: MaterialApp(
        theme: theme,
        // 生产环境 ReaderScreen 外层有 Scaffold（Material 会把
        // theme.textTheme.bodyMedium 注入 DefaultTextStyle）
        home: const Scaffold(
          body: ReaderPageView(
            paragraphSpacing: 8,
            pageChrome: ReaderPageChromeConfig(),
            readBodyToLh: false,
          ),
        ),
      ),
    );
  }

  Future<void> pumpReader(WidgetTester tester) async {
    await tester.pumpWidget(wrap(appFontFamily: 'AppCustomFont_probe'));
    await tester.pumpAndSettle();
    // 滚动模式 build 内的零时长 Timer：多 pump 一次消除 pending timer
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('应用字体仅作用于界面：正文族名非空且不等于应用字体', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpReader(tester);

    // 污染源存在：ReaderPageView 上层 DefaultTextStyle 就是应用字体
    final viewContext = tester.element(find.byType(ReaderPageView));
    final ambient = DefaultTextStyle.of(viewContext).style;
    expect(ambient.fontFamily, 'AppCustomFont_probe');

    final body = tester.renderObject<RenderParagraph>(
      find.textContaining('应用字体独立性探针').first,
    );
    final bodyFamily = body.text.style?.fontFamily;
    expect(bodyFamily, isNotNull, reason: '正文必须显式指定字体族，不能继承应用字体');
    expect(bodyFamily, isNot('AppCustomFont_probe'));
  });

  testWidgets('阅读字体显式配置时仍以 reader_font_family 为准', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'reader_font_family': 'SimSun',
    });
    await pumpReader(tester);
    await tester.pumpAndSettle();

    final body = tester.renderObject<RenderParagraph>(
      find.textContaining('应用字体独立性探针').first,
    );
    expect(body.text.style?.fontFamily, 'SimSun');
  });
}
