// [批31b P3-4 / 批32] 阅读器菜单「目录显示反转」回归
//
// 对齐原版 `Book.kt:502` `ReadConfig.reverseTocDisplay`：阅读菜单切换后
// 仅改展示序（数据/章节身份不变）。批32 起保存走**单键写**
// `updateReadConfigField`（不再整书 `updateBook` 回写，避免清空 Dart
// 未建模的 readConfig 键），并同步 ReaderNotifier.currentBook。
//
// 编写：全栈工程师（批31b，批32 更新） ｜ 2026-10-28 / 2026-10-29
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
    when(
      () => mockApi.updateReadConfigField(any(), any(), any()),
    ).thenAnswer((_) async {});
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

  testWidgets('菜单「目录显示反转」：单键写落库并同步 currentBook', (tester) async {
    // 阅读器已打开本书（打开时快照 reverseTocDisplay=false）
    container.read(readerNotifierProvider.notifier).updateCurrentBook(book);

    await tester.pumpWidget(wrapMenu());
    await tester.pump();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录显示反转'));
    await tester.pumpAndSettle();

    verify(
      () => mockApi.updateReadConfigField(
        book.bookUrl,
        'reverseTocDisplay',
        'true',
      ),
    ).called(1); // 菜单切换应经单键写落库 reverseTocDisplay=true
    verifyNever(() => mockApi.updateBook(any()));
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
