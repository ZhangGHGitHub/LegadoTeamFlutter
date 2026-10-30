// 阅读器顶栏动作可配置回归（批37）
//
// 覆盖：默认顶栏顺序、书型过滤、最多 6 个、配置持久化/重启读回、
// 配置页开关/上下移/恢复默认、被移出顶栏的动作在「更多」菜单仍可达、
// 长按二级动作（换源/缓存管理）、批37b 回修项（更多菜单去重、
// origin 为空书型判定、charset/toc_rule 点击、同树配置即时生效）。
//
// 编写：全栈工程师（批37/37b） ｜ 2026-10-29
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/providers/reader/reader_top_bar_actions_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar_actions.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar_config_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    return container;
  }

  const onlineBook = Book(
    bookUrl: 'https://book.com/topbar',
    name: '顶栏测试书',
    author: '作者T',
    origin: 'https://source-t.com',
  );

  const localTxtBook = Book(
    bookUrl: 'file:///books/local.txt',
    name: '本地TXT',
    author: '作者L',
    origin: BookType.localTag,
    originName: 'local.txt',
  );

  Widget wrapMenu(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      routes: {
        AppRoutes.offlineCache: (_) => const Scaffold(body: Text('缓存管理页')),
        AppRoutes.txtTocRules: (_) => const Scaffold(body: Text('目录规则库页')),
      },
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

  Finder topBarAction(String id) =>
      find.byKey(ValueKey('reader-topbar-action-$id'));

  Finder allTopBarActions() => find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'reader-topbar-action-',
        ),
  );

  Future<void> pumpMenu(
    WidgetTester tester,
    ProviderContainer container,
    Book book,
  ) async {
    container.read(readerNotifierProvider.notifier).updateCurrentBook(book);
    await tester.pumpWidget(wrapMenu(container));
    // 首帧后配置异步加载完成，再刷一帧
    await tester.pump();
    await tester.pump();
  }

  group('顶栏默认渲染', () {
    testWidgets('在线书默认 = 离线缓存/刷新正文/换源/更多（顺序对齐参考版）', (tester) async {
      final container = makeContainer();
      await pumpMenu(tester, container, onlineBook);

      expect(topBarAction('download'), findsOneWidget);
      expect(topBarAction('refresh'), findsOneWidget);
      expect(topBarAction('change_source'), findsOneWidget);
      expect(find.byTooltip('更多'), findsOneWidget);
      expect(topBarAction('catalog'), findsNothing, reason: '目录默认不上顶栏');
      expect(allTopBarActions(), findsNWidgets(3), reason: '三个动作 + 更多按钮');

      final xDownload = tester.getTopLeft(topBarAction('download')).dx;
      final xRefresh = tester.getTopLeft(topBarAction('refresh')).dx;
      final xChange = tester.getTopLeft(topBarAction('change_source')).dx;
      expect(xDownload < xRefresh && xRefresh < xChange, isTrue);
    });

    testWidgets('本地 TXT 默认显示 TXT 目录规则 + 设置编码，不显示在线动作', (tester) async {
      final container = makeContainer();
      await pumpMenu(tester, container, localTxtBook);

      expect(topBarAction('charset'), findsOneWidget);
      expect(
        topBarAction('toc_rule'),
        findsOneWidget,
        reason: '批43：目录规则已接通作用于当前书，恢复默认启用',
      );
      expect(topBarAction('download'), findsNothing);
      expect(topBarAction('refresh'), findsNothing);
      expect(topBarAction('change_source'), findsNothing);
      expect(find.byTooltip('更多'), findsOneWidget);
    });

    testWidgets('origin 为空按本地书处理（批37b P2-3）', (tester) async {
      const orphanBook = Book(
        bookUrl: 'file:///books/orphan.txt',
        name: '无 origin 本地书',
        author: '作者O',
        origin: '',
        originName: 'orphan.txt',
      );
      final container = makeContainer();
      await pumpMenu(tester, container, orphanBook);

      expect(
        topBarAction('change_source'),
        findsNothing,
        reason: 'origin 空不得误判为在线书',
      );
      expect(topBarAction('refresh'), findsNothing);
      expect(topBarAction('download'), findsNothing);
      expect(topBarAction('charset'), findsOneWidget, reason: '按本地 TXT 处理');
    });
  });

  group('配置生效与「更多」兜底', () {
    testWidgets('顶栏移出换源/刷新/缓存后，仍可从「更多」菜单访问', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readerTopBarActions:
            'catalog,true;setting,true;more_actions,true',
      });
      final container = makeContainer();
      await pumpMenu(tester, container, onlineBook);

      expect(topBarAction('catalog'), findsOneWidget);
      expect(topBarAction('setting'), findsOneWidget);
      expect(topBarAction('change_source'), findsNothing);
      expect(topBarAction('download'), findsNothing);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('换源'), findsOneWidget, reason: '兜底入口');
      expect(find.text('刷新正文'), findsOneWidget);
      expect(find.text('下载（离线缓存）'), findsOneWidget);
      // 菜单里已有同义项不重复
      expect(find.text('查看目录'), findsOneWidget);
      expect(find.text('界面设置'), findsOneWidget);
    });

    testWidgets('默认在线书「更多」不含底部动作行常驻项（批37b P2-1）', (tester) async {
      final container = makeContainer();
      await pumpMenu(tester, container, onlineBook);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();

      final menuItem = find.byWidgetPredicate((w) => w is PopupMenuItem);
      Finder inMenu(String text) =>
          find.descendant(of: menuItem, matching: find.text(text));
      // 底部五键行动作行已有同义入口，不再进「更多」
      expect(inMenu('全文搜索'), findsNothing);
      expect(inMenu('自动翻页'), findsNothing);
      expect(inMenu('朗读'), findsNothing);
      // 目录/设置同理（既有去重）
      expect(inMenu('查看目录'), findsOneWidget);
      expect(inMenu('界面设置'), findsOneWidget);
      // 顶栏未显示的动作仍可达
      expect(inMenu('日/夜切换'), findsOneWidget);
      expect(inMenu('上一章'), findsOneWidget);
    });

    testWidgets('长按下载进入缓存管理页（批37b P2-4）', (tester) async {
      final container = makeContainer();
      await pumpMenu(tester, container, onlineBook);

      await tester.longPress(topBarAction('download'));
      await tester.pumpAndSettle();
      expect(find.text('缓存管理页'), findsOneWidget);
    });

    testWidgets('全部动作开启时顶栏最多 6 个（含固定「更多」）', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readerTopBarActions: [
          for (final def in readerTopBarActionPool) '${def.id},true',
        ].join(';'),
      });
      final container = makeContainer();
      await pumpMenu(tester, container, onlineBook);

      expect(allTopBarActions(), findsNWidgets(5), reason: '最多 5 个动作 + 更多');
      expect(find.byTooltip('更多'), findsOneWidget);
      // 池顺序前五：缓存/刷新/换源/目录/搜索
      expect(topBarAction('download'), findsOneWidget);
      expect(topBarAction('search'), findsOneWidget);
      expect(topBarAction('read_aloud'), findsNothing, reason: '第 7 个起不显示');
    });

    testWidgets('长按换源弹出换书源/单章换源二级菜单', (tester) async {
      final container = makeContainer();
      await pumpMenu(tester, container, onlineBook);

      await tester.longPress(topBarAction('change_source'));
      await tester.pumpAndSettle();
      expect(find.text('单章换源'), findsOneWidget);
      expect(find.text('换书源'), findsOneWidget);
    });

    testWidgets('同一树中配置页关闭换源后顶栏立即消失（批37b P2-4）', (tester) async {
      final container = makeContainer();
      container
          .read(readerNotifierProvider.notifier)
          .updateCurrentBook(onlineBook);
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
                    onOpenReplaceRules: () {},
                  ),
                  Align(
                    alignment: Alignment.center,
                    child: Builder(
                      builder: (ctx) => TextButton(
                        key: const ValueKey('open-topbar-config'),
                        onPressed: () => ReaderTopBarConfigSheet.show(ctx),
                        child: const Text('open-config'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(topBarAction('change_source'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('open-topbar-config')));
      await tester.pumpAndSettle();
      final changeSourceSwitch = find.byKey(
        const ValueKey('reader-topbar-switch-change_source'),
      );
      await tester.ensureVisible(changeSourceSwitch);
      await tester.tap(changeSourceSwitch);
      await tester.pump();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(
        topBarAction('change_source'),
        findsNothing,
        reason: '配置即时生效，同一 ProviderScope 下顶栏立即重绘',
      );
    });

    testWidgets('点击设置编码：对话框 → 单列写 → 成功提示（批37b P1-1）', (tester) async {
      final container = makeContainer();
      const chapter = BookChapter(
        url: 'txt://chapter/0',
        title: '第一章',
        index: 0,
      );
      when(() => mockApi.setBookCharset(any(), any())).thenAnswer((inv) async {
        final charset = inv.positionalArguments[1] as String;
        return localTxtBook.copyWith(charset: charset);
      });
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => [chapter]);
      when(
        () => mockApi.getChapterContentFull(any(), any()),
      ).thenAnswer((_) async => '正文内容');

      await pumpMenu(tester, container, localTxtBook);
      await tester.tap(topBarAction('charset'));
      await tester.pumpAndSettle();
      expect(find.text('设置编码'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'GBK');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      verify(
        () => mockApi.setBookCharset(localTxtBook.bookUrl, 'GBK'),
      ).called(1);
      expect(find.text('已设置编码：GBK'), findsOneWidget);
    });

    testWidgets('点击 TXT 目录规则打开选择弹层并可进入管理页（批43）', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readerTopBarActions: 'toc_rule,true;more_actions,true',
        // 已灌过默认规则，跳过资产导入
        'txtTocRuleVersion': 1,
      });
      when(() => mockApi.getConfig('txt_toc_rules'))
          .thenAnswer((_) async => '[]');
      final container = makeContainer();
      await pumpMenu(tester, container, localTxtBook);

      expect(topBarAction('toc_rule'), findsOneWidget);
      await tester.tap(topBarAction('toc_rule'));
      await tester.pumpAndSettle();
      // 选择弹层（不再是直接跳转规则库管理页）
      expect(find.text('TXT 目录规则'), findsWidgets);
      expect(find.text('默认规则'), findsOneWidget);

      await tester.tap(find.text('管理规则'));
      await tester.pumpAndSettle();
      expect(find.text('目录规则库页'), findsOneWidget);
    });
  });

  group('配置页', () {
    testWidgets('开关/上移/恢复默认并即时落盘', (tester) async {
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ReaderTopBarConfigSheet()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final switchCatalog = find.byKey(
        const ValueKey('reader-topbar-switch-catalog'),
      );
      await tester.ensureVisible(switchCatalog);
      // 先关闭下载（腾位），再开启目录（批37b 默认只开 4 项，此处仍按
      // 开关往返验证即时落盘）
      final switchDownload = find.byKey(
        const ValueKey('reader-topbar-switch-download'),
      );
      await tester.ensureVisible(switchDownload);
      await tester.tap(switchDownload);
      await tester.pump();
      expect(
        container
            .read(readerTopBarActionsProvider)
            .itemFor('download')
            ?.enabled,
        isFalse,
      );
      await tester.ensureVisible(switchCatalog);
      await tester.tap(switchCatalog);
      await tester.pump();
      expect(
        container.read(readerTopBarActionsProvider).itemFor('catalog')?.enabled,
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PrefKeys.readerTopBarActions),
        contains('catalog,true'),
        reason: '键名/值格式对齐参考版并即时落盘',
      );

      // 上移：目录应越过编码（默认池顺序中 charset 在 catalog 之前）
      final upCatalog = find.byKey(const ValueKey('reader-topbar-up-catalog'));
      await tester.ensureVisible(upCatalog);
      await tester.tap(upCatalog);
      await tester.pump();
      final ids = [
        for (final item in container.read(readerTopBarActionsProvider).items)
          item.id,
      ];
      expect(
        ids.indexOf('catalog') < ids.indexOf('charset'),
        isTrue,
        reason: '上移一位后目录排到编码前',
      );

      final restore = find.byKey(const ValueKey('reader-topbar-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pump();
      expect(
        container.read(readerTopBarActionsProvider),
        ReaderTopBarActionsState(defaultReaderTopBarActionItems()),
      );
    });

    testWidgets('达到 6 个上限后，未开启项开关禁用（配置页限制）', (tester) async {
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ReaderTopBarConfigSheet()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 批43 默认集已满 6 个（download/refresh/change_source/toc_rule/charset
      // + 固定「更多」）→ 未开启项直接禁用
      final switchCatalog = find.byKey(
        const ValueKey('reader-topbar-switch-catalog'),
      );
      await tester.ensureVisible(switchCatalog);
      expect(
        tester.widget<Switch>(switchCatalog).onChanged,
        isNull,
        reason: '默认即满 6 个（含「更多」）',
      );

      // 关闭一个已开启项腾出名额 → 目录项恢复可开启
      final switchRefresh = find.byKey(
        const ValueKey('reader-topbar-switch-refresh'),
      );
      await tester.ensureVisible(switchRefresh);
      await tester.tap(switchRefresh);
      await tester.pump();
      await tester.ensureVisible(switchCatalog);
      expect(tester.widget<Switch>(switchCatalog).onChanged, isNotNull);
      await tester.tap(switchCatalog);
      await tester.pump();

      // 已满 6 个时其余未开启项不允许再开启（列表懒构建，先滚动到位）
      final switchSearch = find.byKey(
        const ValueKey('reader-topbar-switch-search'),
      );
      await tester.scrollUntilVisible(
        switchSearch,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<Switch>(switchSearch).onChanged,
        isNull,
        reason: '已满 6 个（含「更多」）时不允许再开启',
      );
      // 已开启项仍可关闭（滚回列表顶部）
      final switchDownload = find.byKey(
        const ValueKey('reader-topbar-switch-download'),
      );
      await tester.scrollUntilVisible(
        switchDownload,
        -120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<Switch>(switchDownload).onChanged, isNotNull);
    });

    testWidgets('「更多」固定开启且不可关闭', (tester) async {
      final container = makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ReaderTopBarConfigSheet()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final moreSwitch = find.byKey(
        const ValueKey('reader-topbar-switch-more_actions'),
      );
      // 「更多」在列表末尾，需滚动到可见（ListView 懒构建）
      await tester.scrollUntilVisible(
        moreSwitch,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      final widget = tester.widget<Switch>(moreSwitch);
      expect(widget.value, isTrue);
      expect(widget.onChanged, isNull, reason: '固定开启，开关禁用');
      expect(
        container.read(readerTopBarActionsProvider).items.last.id,
        kReaderMoreActionsId,
        reason: '「更多」固定末位',
      );
    });
  });

  group('持久化/重启', () {
    test('保存后新容器读回同一配置（模拟重启）', () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      await first.read(readerTopBarActionsProvider.notifier).save([
        const ReaderTopBarActionItem(id: 'catalog', enabled: true),
        const ReaderTopBarActionItem(id: 'search', enabled: true),
        const ReaderTopBarActionItem(id: 'change_source', enabled: false),
      ]);
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      // 初始帧为默认值，异步加载完成后替换
      expect(
        second.read(readerTopBarActionsProvider).itemFor('catalog')?.enabled,
        isFalse,
      );
      await pumpEventQueue();
      final loaded = second.read(readerTopBarActionsProvider);
      expect(loaded.itemFor('catalog')?.enabled, isTrue);
      expect(loaded.itemFor('search')?.enabled, isTrue);
      expect(loaded.itemFor('change_source')?.enabled, isFalse);
      expect(loaded.items.last.id, kReaderMoreActionsId);
    });

    test('恢复默认后落盘为参考版默认集合', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readerTopBarActions: 'catalog,true;more_actions,true',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 先读一次触发 build（异步加载才会排入微任务），再等待加载完成
      container.read(readerTopBarActionsProvider);
      await pumpEventQueue();
      expect(
        container.read(readerTopBarActionsProvider).itemFor('catalog')?.enabled,
        isTrue,
      );
      await container
          .read(readerTopBarActionsProvider.notifier)
          .restoreDefaults();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(PrefKeys.readerTopBarActions) ?? '';
      expect(raw, contains('download,true'));
      expect(raw, contains('refresh,true'));
      expect(raw, contains('change_source,true'));
      expect(raw, contains('catalog,false'));
      expect(raw, endsWith('more_actions,true'));
    });
  });
}
