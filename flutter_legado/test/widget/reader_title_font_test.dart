/// 标题字体贯通测试（差异清单 C3 收尾：对齐原版 #1072 ReadBookConfig.titleFont）
///
/// 覆盖：① ReaderAdvancedConfig.titleFont 持久化（load/save/copy，键名
/// titleFont 无前缀）；② effectiveTitleFontFamily 单源取值（空=跟随正文）；
/// ③ 渲染侧 ReaderTypographicPage 首屏标题块 TextStyle.fontFamily 与测量
/// 传入值一致（同参断言，仿 reader_italic_style_test.dart 方式）；
/// ④ PageChrome.titleFont 并入 layoutKey（触发重分页的可测替代：
/// 断言 chrome.titleFont 传参与 layoutKey 变化）；⑤ Tt 面板标题字体行
/// 显示「跟随正文」/字体名，点按跳转 FontScreen(target: 'title')。
/// — full-stack-engineer + UI
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/font_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_chrome.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';
import 'package:flutter_legado/src/widgets/reader/reader_settings_sheet.dart';

void main() {
  group('ReaderAdvancedConfig.titleFont 持久化', () {
    test('save 写键 titleFont（无前缀，对齐 titleMode/titleSize 系列）',
        () async {
      SharedPreferences.setMockInitialValues({});
      await ReaderAdvancedConfig(titleFont: 'KaiTi').save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('titleFont'), 'KaiTi');
    });

    test('load 读回 titleFont；缺省为空串（空=跟随正文）', () async {
      SharedPreferences.setMockInitialValues({'titleFont': 'SimSun'});
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.titleFont, 'SimSun');

      SharedPreferences.setMockInitialValues({});
      final def = await ReaderAdvancedConfig.load();
      expect(def.titleFont, '');
    });

    test('copy 保留 titleFont', () {
      final cfg = ReaderAdvancedConfig(titleFont: 'Georgia');
      expect(cfg.copy().titleFont, 'Georgia');
      expect(ReaderAdvancedConfig().titleFont, '');
    });
  });

  group('effectiveTitleFontFamily 单源取值', () {
    test('titleFont 非空优先于正文字体', () {
      const chrome = ReaderPageChromeConfig(titleFont: 'KaiTi');
      expect(effectiveTitleFontFamily(chrome, 'SimSun'), 'KaiTi');
    });

    test('titleFont 空值=跟随正文字体（null 正文=默认字体）', () {
      const chrome = ReaderPageChromeConfig();
      expect(effectiveTitleFontFamily(chrome, 'SimSun'), 'SimSun');
      expect(effectiveTitleFontFamily(chrome, null), isNull);
    });
  });

  group('首屏标题块测量/渲染同参', () {
    const pageInfo = PageInfo(paragraphs: [], totalHeight: 0);

    Widget page({required ReaderPageChromeConfig chrome, String? bodyFont}) {
      return MaterialApp(
        home: Scaffold(
          body: ReaderTypographicPage(
            pageInfo: pageInfo,
            pageIndex: 0,
            totalPages: 1,
            chapterTitle: '第一章 标题',
            fontSize: 18,
            lineHeight: 1.6,
            paragraphSpacing: 8,
            backgroundColor: Colors.white,
            textColor: Colors.black,
            fontFamily: bodyFont,
            pageChrome: chrome,
          ),
        ),
      );
    }

    testWidgets('标题 TextStyle.fontFamily == 测量传入值（同参断言）',
        (tester) async {
      const chrome = ReaderPageChromeConfig(titleFont: 'KaiTi');
      const bodyFont = 'SimSun';
      // 测量侧（_computeFirstPageHeight）经同一单源计算的值
      const expected = 'KaiTi';
      expect(effectiveTitleFontFamily(chrome, bodyFont), expected);

      await tester.pumpWidget(page(chrome: chrome, bodyFont: bodyFont));
      final title = tester
          .widget<Text>(find.text('第一章 标题'))
          .style!
          .fontFamily;
      expect(title, expected,
          reason: '标题渲染 fontFamily 须与测量传入值一致');
    });

    testWidgets('标题字体空值=跟随正文字体（修复既有偏差）', (tester) async {
      const chrome = ReaderPageChromeConfig();
      const bodyFont = 'SimSun';
      expect(effectiveTitleFontFamily(chrome, bodyFont), bodyFont);

      await tester.pumpWidget(page(chrome: chrome, bodyFont: bodyFont));
      final title =
          tester.widget<Text>(find.text('第一章 标题')).style!.fontFamily;
      expect(title, bodyFont,
          reason: '空 titleFont 时标题应跟随正文字体（既有偏差修复）');
    });
  });

  group('PageChrome.titleFont 与 layoutKey', () {
    test('titleFont 并入 layoutKey（变化即触发重分页）', () {
      const base = ReaderPageChromeConfig();
      const a = ReaderPageChromeConfig(titleFont: 'KaiTi');
      const b = ReaderPageChromeConfig(titleFont: 'SimSun');
      expect(base.layoutKey, isNot(equals(a.layoutKey)));
      expect(a.layoutKey, isNot(equals(b.layoutKey)));
      expect(a.layoutKey.endsWith('_KaiTi'), isTrue);
    });

    test('fromAdvanced 透传 titleFont', () {
      final cfg = ReaderAdvancedConfig(titleFont: 'KaiTi');
      expect(ReaderPageChromeConfig.fromAdvanced(cfg).titleFont, 'KaiTi');
    });
  });

  group('Tt 面板标题字体行', () {
    testWidgets('默认显示「跟随正文」，点按跳转 FontScreen(target: title)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      String? capturedArgs;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
          child: MaterialApp(
            onGenerateRoute: (settings) {
              if (settings.name == AppRoutes.fonts) {
                capturedArgs = settings.arguments as String?;
                final target = capturedArgs ?? 'body';
                return MaterialPageRoute<void>(
                  builder: (_) => FontScreen(target: target),
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => ReaderFontPanel(config: ReaderAdvancedConfig()),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 空 titleFont → 行值显示「跟随正文」
      expect(find.text('跟随正文'), findsOneWidget);

      await tester.tap(find.text('标题字体'));
      await tester.pumpAndSettle();
      expect(capturedArgs, 'title', reason: '须以 arguments 传 title 目标');
      expect(find.byType(FontScreen), findsOneWidget);
      // FontScreen 标题目标页：标题与「当前标题字体」标识
      expect(find.text('当前标题字体：跟随正文'), findsOneWidget);
    });

    testWidgets('已选标题字体显示字体名（Custom_ 前缀剥离）', (tester) async {
      SharedPreferences.setMockInitialValues({'titleFont': 'Custom_宋体'});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
          child: MaterialApp(
            home: ReaderFontPanel(config: ReaderAdvancedConfig()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('宋体'), findsOneWidget,
          reason: '行值应显示字体名（Custom_ 前缀剥离）');
      expect(find.text('跟随正文'), findsNothing);
    });
  });
}
