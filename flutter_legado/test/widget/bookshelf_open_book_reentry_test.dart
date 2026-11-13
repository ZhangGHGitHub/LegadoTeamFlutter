import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

/// [P2-5] 书架双击开书重入保护回归测试
///
/// 背景：`_openBook` 在 push 前要 await `getBookSources()`（书源匹配）与
/// `refreshShowMangaUi()`；弱网/书源多时双击会在第一段 await 期间再次进入，
/// 导致同一本书压入两个阅读器。
///
/// 本用例用 Completer 卡住书源查询，在等待窗口内双击，断言阅读器路由
/// 只被 push 一次。修复前第二次点击会并行走完流程并再次 push（红）。
class _ReaderPushCounter extends NavigatorObserver {
  int readerPushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == AppRoutes.reader) readerPushes++;
    super.didPush(route, previousRoute);
  }
}

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
  });

  const book = Book(
    name: '在线之书',
    bookUrl: 'book://online',
    origin: 'https://src.example',
    totalChapterNum: 10,
    durChapterIndex: 1,
    durChapterTitle: '第2章',
  );

  testWidgets('等待书源匹配期间双击：阅读器只 push 一次', (tester) async {
    SharedPreferences.setMockInitialValues({
      'bookshelfLayoutPortrait': 0,
      'bookshelf_layout_landscape': 0,
    });
    when(() => mockApi.getBooks()).thenAnswer((_) async => [book]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);

    // 卡住书源查询，制造「点击后仍在等待」窗口
    final gate = Completer<List<BookSource>>();
    when(() => mockApi.getBookSources()).thenAnswer((_) => gate.future);

    // 阅读器 openBook 的章节装载
    when(() => mockApi.getChapters('book://online')).thenAnswer(
      (_) async => [
        for (var i = 0; i < 10; i++)
          BookChapter(
            title: '第${i + 1}章',
            bookUrl: 'book://online',
            url: 'mock://online/$i',
            index: i,
          ),
      ],
    );
    when(
      () => mockApi.getChapterContentFull('book://online', 1),
    ).thenAnswer((_) async => '正文内容');

    final observer = _ReaderPushCounter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: const BookshelfScreen(),
          navigatorObservers: [observer],
          routes: {
            AppRoutes.reader: (_) => const Scaffold(body: Text('STUB_READER')),
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('在线之书'), findsOneWidget);

    // 第一次点击后进入 await（书源查询未完成），立即第二次点击
    await tester.tap(find.text('在线之书'));
    await tester.pump();
    await tester.tap(find.text('在线之书'));
    await tester.pump();

    // 放行书源查询，等待两次流程全部走完
    gate.complete(const <BookSource>[]);
    await tester.pumpAndSettle();

    expect(observer.readerPushes, 1, reason: '同一本书在开书等待窗口内重复点击不得 push 第二个阅读器');
    expect(find.text('STUB_READER'), findsOneWidget);

    // [P3-6] 守卫必须在 finally 中释放：进入阅读器后返回书架，再次点击
    // 仍能正常 push。若 finally 漏了 remove，守卫永久锁死，上面「只 push
    // 一次」的断言仍会通过，本段是缺失的回归覆盖。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('在线之书'), findsOneWidget, reason: '应已返回书架');

    await tester.tap(find.text('在线之书'));
    await tester.pumpAndSettle();

    expect(
      observer.readerPushes,
      2,
      reason: '返回书架后再次点击必须能重新 push；否则说明 _openingBookUrls 未释放',
    );
    expect(find.text('STUB_READER'), findsOneWidget);
  });
}
