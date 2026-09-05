// 一比一复刻 S7 验收：渲染矩阵补页（详情/阅读，UI_ONE_TO_ONE_CLONE_PLAN_
// 20260905.md S7）——md3_acceptance_matrix 原有 4 页之外补关键改动两屏，
// 断言无异常渲染（异常会被 flutter test 捕获）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
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

  group('S7 渲染矩阵补页', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('书籍详情（含 ActionCard/折叠顶栏/取色）'
          '${brightness.name} 无异常渲染', (tester) async {
        tester.view.physicalSize = const Size(1080, 2260);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        final mockApi = MockRustApi();
        final book = Book(
          bookUrl: 'u1',
          name: '矩阵书',
          author: '作者',
          coverUrl: '',
        );
        when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
        when(() => mockApi.getChapters(any()))
            .thenAnswer((_) async => const [BookChapter(title: '第一章')]);
        when(() => mockApi.getBooks()).thenAnswer((_) async => [book]);
        when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
        when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
        when(() => mockApi.getConfig(any()))
            .thenAnswer((_) async => '');
        when(() => mockApi.getChapterContent(any(), any()))
            .thenAnswer((_) async => '内容');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [bookApiProvider.overrideWithValue(mockApi)],
            child: themeWrap(
              BookInfoScreen(book: book),
              brightness: brightness,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // ActionCard 行关键入口可见（S3 骨架在位）
        expect(find.text('目录'), findsWidgets);
        expect(find.text('换源'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('阅读器（单面板菜单挂载路径）light 无异常渲染', (tester) async {
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final mockApi = MockRustApi();
      const chapters = [BookChapter(title: '第一章')];
      when(() => mockApi.getChapters(any()))
          .thenAnswer((_) async => chapters);
      when(() => mockApi.getChapterContent(any(), any()))
          .thenAnswer((_) async => '正文内容');
      when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
      when(() => mockApi.getConfig(any()))
          .thenAnswer((_) async => '');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [bookApiProvider.overrideWithValue(mockApi)],
          child: themeWrap(const ReaderScreen()),
        ),
      );
      // openBook 注入（对标书架打开链路）
      final container =
          ProviderScope.containerOf(tester.element(find.byType(ReaderScreen)));
      // 直读初始帧（openBook 异步链路完成后断言）
      await container
          .read(readerNotifierProvider.notifier)
          .openBook(const Book(bookUrl: 'u1', name: '矩阵书'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
