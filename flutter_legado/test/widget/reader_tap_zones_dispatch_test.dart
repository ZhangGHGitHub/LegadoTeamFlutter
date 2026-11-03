// [批4a] 九宫格点击分发（ReaderScreen 集成：分区命中 / 死区 / 长按）
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/tap4a',
  name: '九宫格书',
  author: '作者T',
  origin: 'https://source-t.com',
  originName: '源T',
);
const _chapters = [
  BookChapter(url: 'https://book.com/tap4a/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/tap4a/c2', title: '第二章', index: 1),
];

MockRustApi _stubApi() {
  final api = MockRustApi();
  when(() => api.getChapters(any())).thenAnswer((_) async => _chapters);
  when(
    () => api.getChapterContentFull(any(), any()),
  ).thenAnswer((i) async => 'CH${i.positionalArguments[1]}');
  when(() => api.getChapterContent(any(), any())).thenAnswer((_) async => '');
  when(() => api.getBookSources()).thenAnswer((_) async => const []);
  when(() => api.getConfig(any())).thenAnswer((_) async => '');
  when(() => api.getBook(any())).thenAnswer((_) async => _book);
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
  return api;
}

Future<ProviderContainer> _pumpReader(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = _stubApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: const MaterialApp(home: ReaderScreen()),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ReaderScreen)),
  );
  await container.read(readerNotifierProvider.notifier).openBook(_book);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUpAll(registerFallbacks);

  testWidgets('中心区=菜单：点击切换工具栏', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.clickActionMiddleCenter: 0,
    });
    final container = await _pumpReader(tester);
    expect(container.read(readerNotifierProvider).showControls, isFalse);

    await tester.tapAt(const Offset(400, 600));
    await tester.pump();
    expect(container.read(readerNotifierProvider).showControls, isTrue);
  });

  testWidgets('长按不触发九宫格动作（中心区=下一章）', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.clickActionMiddleCenter: 3,
    });
    final container = await _pumpReader(tester);
    await tester.longPressAt(const Offset(400, 600));
    await tester.pumpAndSettle();
    expect(container.read(readerNotifierProvider).currentChapterIndex, 0);
  });

  testWidgets('菜单展开时顶栏/底栏/章节行空白点击只收起菜单', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.clickActionMiddleCenter: 0,
    });
    final container = await _pumpReader(tester);
    Future<void> openMenu() async {
      await tester.tapAt(const Offset(400, 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(readerNotifierProvider).showControls, isTrue);
    }

    Future<void> assertClosed() async {
      await tester.pump();
      expect(container.read(readerNotifierProvider).showControls, isFalse);
      expect(container.read(readerNotifierProvider).currentChapterIndex, 0);
    }

    await openMenu();
    final topBar = tester.getRect(
      find.byKey(const ValueKey('reader-topbar-surface')),
    );
    await tester.tapAt(topBar.topLeft + const Offset(4, 4));
    await assertClosed();

    await openMenu();
    final bottom = tester.getRect(
      find.byKey(const ValueKey('reader-bottom-panel-surface')),
    );
    // 底栏中列下缘空白（BC 默认下一页）；若穿透会翻页
    await tester.tapAt(Offset(bottom.center.dx, bottom.bottom - 4));
    await assertClosed();

    await openMenu();
    await tester.tapAt(Offset(topBar.center.dx, topBar.bottom - 6));
    await assertClosed();

    // 收起后九宫格仍正常
    await openMenu();
  });

  testWidgets('pageTouchClick 边缘死区仍吞点击', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pageTouchClick': 120,
      PrefKeys.clickActionTopLeft: 0,
    });
    final container = await _pumpReader(tester);
    await tester.tapAt(const Offset(60, 100));
    await tester.pump();
    expect(
      container.read(readerNotifierProvider).showControls,
      isFalse,
      reason: '左侧 120px 死区不应触发菜单',
    );
  });

  testWidgets('中心区=下一章：命中区域后切换章节', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.clickActionMiddleCenter: 3,
    });
    final container = await _pumpReader(tester);
    expect(container.read(readerNotifierProvider).currentChapterIndex, 0);
    await tester.tapAt(const Offset(400, 600));
    await tester.pumpAndSettle();
    expect(container.read(readerNotifierProvider).currentChapterIndex, 1);
  });
}
