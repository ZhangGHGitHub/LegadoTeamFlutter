// 批7a P1-B：活跃阅读菜单（reader_menu_panel 3-dot）书级开关
//
// 设备验收缺陷：活跃菜单只有「替换规则」打开管理页，没有书级
// 使用替换规则/重新分段开关（reader_top_bar 的勾选项是无实例化点的死实现）。
// 本测试固定：菜单项存在、勾选态跟随书级/全局默认、点击写配置并重载正文、
// 管理项仍导航。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/menu-7a',
  name: '菜单测试书',
  author: '作者',
  origin: 'https://source.example.com',
  readConfig: ReadConfig(),
);

const _toc = [
  BookChapter(url: 'https://book.com/menu-7a/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/menu-7a/c2', title: '第二章', index: 1),
];

void stubOpenBook(MockRustApi api) {
  when(() => api.getChapters(any())).thenAnswer((_) async => _toc);
  when(
    () => api.getChapterContentFull(any(), any()),
  ).thenAnswer((_) async => '正文');
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
  when(() => api.updateBook(any())).thenAnswer((_) async {});
}

void main() {
  setUpAll(registerFallbacks);

  Future<ProviderContainer> pumpMenu(
    WidgetTester tester, {
    required MockRustApi api,
    bool globalReplaceDefault = true,
    required void Function() onManageReplace,
  }) async {
    final container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        if (!globalReplaceDefault)
          replaceEnableDefaultProvider.overrideWith((ref) async => false),
      ],
    );
    addTearDown(container.dispose);
    stubEmptyWebdavServers(api);
    stubOpenBook(api);
    await container.read(readerNotifierProvider.notifier).openBook(_book);
    await tester.pumpWidget(
      UncontrolledProviderScope(
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
                  onOpenReplaceRules: onManageReplace,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openMoreMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
  }

  bool checkedOf(WidgetTester tester, String label) => tester
      .widget<CheckedPopupMenuItem<String>>(
        find.widgetWithText(CheckedPopupMenuItem<String>, label),
      )
      .checked;

  testWidgets('菜单包含两个书级开关，替换勾选态跟随全局默认', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    await pumpMenu(tester, api: api, onManageReplace: () {});

    await openMoreMenu(tester);

    expect(find.text('使用替换规则'), findsOneWidget);
    expect(find.text('重新分段'), findsOneWidget);
    expect(find.text('管理替换规则'), findsOneWidget);
    expect(find.text('替换规则'), findsNothing, reason: '旧文案应改为管理替换规则');
    expect(checkedOf(tester, '使用替换规则'), isTrue,
        reason: '书级 null + 全局默认 true → 生效开启');
    expect(checkedOf(tester, '重新分段'), isFalse);
  });

  testWidgets('全局默认 false 时使用替换规则不勾选', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    await pumpMenu(
      tester,
      api: api,
      globalReplaceDefault: false,
      onManageReplace: () {},
    );

    await openMoreMenu(tester);

    expect(checkedOf(tester, '使用替换规则'), isFalse);
  });

  testWidgets('点击使用替换规则：写显式配置并重载正文', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    final container = await pumpMenu(tester, api: api, onManageReplace: () {});
    final openState = container.read(readerNotifierProvider);
    expect(
      openState.chapters,
      isNotEmpty,
      reason: '前置：openBook 应已载入目录；error=${openState.error}',
    );
    await openMoreMenu(tester);
    clearInteractions(api);

    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, '使用替换规则'),
    );
    await tester.pumpAndSettle();

    final captured = verify(() => api.updateBook(captureAny())).captured;
    final updated = captured.last as Book;
    expect(updated.readConfig?.useReplaceRule, isFalse,
        reason: 'null 生效 true，首次点击应写显式 false');
    verify(() => api.getChapterContentFull(any(), any())).called(1);
    expect(
      container.read(readerNotifierProvider).currentBook?.readConfig?.useReplaceRule,
      isFalse,
    );
  });

  testWidgets('点击重新分段：写 reSegment 并重载正文', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    final container = await pumpMenu(tester, api: api, onManageReplace: () {});
    await openMoreMenu(tester);
    clearInteractions(api);

    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<String>, '重新分段'),
    );
    await tester.pumpAndSettle();

    final captured = verify(() => api.updateBook(captureAny())).captured;
    final updated = captured.last as Book;
    expect(updated.readConfig?.reSegment, isTrue);
    verify(() => api.getChapterContentFull(any(), any())).called(1);
    expect(
      container.read(readerNotifierProvider).currentBook?.readConfig?.reSegment,
      isTrue,
    );
  });

  testWidgets('管理替换规则仍打开规则管理页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    var manageCount = 0;
    await pumpMenu(
      tester,
      api: api,
      onManageReplace: () => manageCount++,
    );
    await openMoreMenu(tester);

    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, '管理替换规则'),
    );
    await tester.pumpAndSettle();

    expect(manageCount, 1);
  });
}
