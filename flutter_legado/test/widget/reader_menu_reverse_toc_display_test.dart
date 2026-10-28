// [批31b P3-4] 阅读器菜单「目录显示反转」回归
//
// 对齐原版 `Book.kt:502` `ReadConfig.reverseTocDisplay`：阅读菜单切换后
// 仅改展示序（数据/章节身份不变），保存走 `updateBook` 落库，并同步
// ReaderNotifier.currentBook（否则后续整书回写会用旧快照还原）。
//
// 编写：全栈工程师（批31b） ｜ 2026-10-28
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  const book = Book(
    bookUrl: 'https://book.com/reverse',
    name: '反转测试书',
    author: '作者R',
    origin: 'https://source-r.com',
    durChapterIndex: 0,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    when(() => mockApi.updateBook(any())).thenAnswer((_) async {});
    stubEmptyWebdavServers(mockApi);
  });

  Widget wrapMenu() => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            ReaderMenuPanel(
              visible: true,
              onBack: () {},
              onAddBookmark: () {},
              onOpenCatalog: () {},
              onOpenSettings: () {},
              onOpenAdvancedConfig: () {},
              onOpenContentSearch: () {},
              onReadAloud: () {},
              onToggleAutoPage: () {},
              onOpenReplaceRules: () {},
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('菜单「目录显示反转」：updateBook 落库并同步 currentBook', (tester) async {
    // 阅读器已打开本书（打开时快照 reverseTocDisplay=false）
    container.read(readerNotifierProvider.notifier).updateCurrentBook(book);

    await tester.pumpWidget(wrapMenu());
    await tester.pump();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录显示反转'));
    await tester.pumpAndSettle();

    final captured =
        verify(() => mockApi.updateBook(captureAny())).captured.single as Book;
    expect(
      captured.readConfig?.reverseTocDisplay,
      isTrue,
      reason: '菜单切换应落库 reverseTocDisplay=true',
    );
    expect(captured.readConfig?.reverseToc, isFalse, reason: '显示反转不得改动数据反转');
    expect(
      container
          .read(readerNotifierProvider)
          .currentBook
          ?.readConfig
          ?.reverseTocDisplay,
      isTrue,
      reason: '落库后必须同步 currentBook（防整书回写还原）',
    );
  });
}
