// [M1 深色态默认修复] 阅读器渲染 widget 测试：背景色断言
//
// 用真实 ReaderScreen 渲染（模板对齐 one_to_one_matrix_test.dart），
// 断言深色主题下正文背景 Scaffold 的背景色解析结果：
// - 深色主题 + 从未显式设置背景 → 纯黑 0xFF000000（主题默认，对齐参考实测；
//   夜间预设 0xFF1A1A1A 仅作为显式选择保留）
// - 深色主题 + 显式预设索引 1 → 保留 green（0xFFCCEBCC），不随主题变
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';
import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget themeWrap(Widget child, {Brightness brightness = Brightness.light}) {
    return MaterialApp(
      theme: AppTheme.palette(
          brightness: brightness, palette: Md3Palettes.wh),
      darkTheme: AppTheme.palette(
          brightness: Brightness.dark, palette: Md3Palettes.wh),
      themeMode: brightness == Brightness.light
          ? ThemeMode.light
          : ThemeMode.dark,
      home: child,
    );
  }

  /// 阅读器最小 mock 链（对齐 one_to_one_matrix_test 模板）
  void stubReader(MockRustApi mockApi) {
    const chapters = [BookChapter(title: '第一章')];
    when(() => mockApi.getChapters(any()))
        .thenAnswer((_) async => chapters);
    when(() => mockApi.getChapterContent(any(), any()))
        .thenAnswer((_) async => '正文内容');
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(() => mockApi.getConfig(any()))
        .thenAnswer((_) async => '');
  }

  /// 启动真实 ReaderScreen 并打开书籍（书架打开链路）
  Future<void> pumpReader(WidgetTester tester, MockRustApi mockApi) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: themeWrap(const ReaderScreen(), brightness: Brightness.dark),
      ),
    );
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ReaderScreen)));
    await container
        .read(readerNotifierProvider.notifier)
        .openBook(const Book(bookUrl: 'u1', name: '矩阵书'));
    await tester.pumpAndSettle();
  }

  group('[M1] 阅读器深色态背景', () {
    testWidgets('深色主题 + 未设置背景 → 正文背景为纯黑（对齐参考）',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'app_theme_mode': 'dark'});
      final mockApi = MockRustApi();
      stubReader(mockApi);
      await pumpReader(tester, mockApi);

      // 正文 Scaffold（reader_screen.dart:417）背景色 = 状态背景色
      final scaffolds =
          tester.widgetList(find.byType(Scaffold)).cast<Scaffold>().toList();
      expect(
        scaffolds.any((s) => s.backgroundColor == const Color(0xFF000000)),
        isTrue,
        reason: '深色主题 + 未显式设置时，正文背景应为纯黑 0xFF000000'
            '（主题默认，对齐参考实测），而不是纯白；'
            '夜间预设 0xFF1A1A1A 仅为用户显式选择时的取值',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色主题 + 显式 green 索引 → 正文背景保留 green',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'app_theme_mode': 'dark',
        'reader_bg_color_index': 1,
      });
      final mockApi = MockRustApi();
      stubReader(mockApi);
      await pumpReader(tester, mockApi);

      final scaffolds =
          tester.widgetList(find.byType(Scaffold)).cast<Scaffold>().toList();
      expect(
        scaffolds.any((s) => s.backgroundColor == ReaderBackground.green),
        isTrue,
        reason: '用户显式选择的背景必须保留（0xFFCCEBCC），不随主题变化',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
