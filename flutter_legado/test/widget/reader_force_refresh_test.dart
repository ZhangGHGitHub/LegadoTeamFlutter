// [P2-9 | 2026-09-24] 阅读器「强制刷新正文 + 换书源后重载」UI 级回归
//
// 针对缺陷：换源后正文不刷新 + 刷新按钮无反馈/不生效。
// ① 缓存命中场景：点「刷新正文」（菜单面板）必须触发强制拉取
//    （mock 的 fetchChapterContent 被调用、正文更新为网络新内容），
//    不得仅经 getChapterContentFull 重读缓存 —— 改造前必红。
// ② 换书源返回（换源路由以新 bookUrl pop）后：读者必须重读书籍
//    （getBook）+ 重载目录（getChapters）+ 强制刷新正文，
//    且 currentBook 更新为换源后记录 —— 改造前必红。
// ③ 失败可见：强制抓取抛错时出现含原因的 SnackBar（非静默；
//    顶栏不再无条件显示误导性的「已刷新」）。
// ④ 换源路由真实类型回归：生产 /change_source 路由为
//    _ChangeSourceSheetRoute（PageRouteBuilder<dynamic>），类型化
//    pushNamed<String> 会在运行期强转 Route<String?> 处抛 TypeError
//    （真机崩溃）——用 dynamic 型路由触发换源流程，断言不崩溃且重载
//    完成（改造前该用例必红）。
// ⑤ 本地书不渲染换源/刷新正文/缓存入口（隐藏而非置灰）。
// ⑥ 慢路径 SnackBar 竞态：换源重载/强制抓取耗时 > 4s（SnackBar 默认
//    自动消失时长）时，旧写法「controller.close() 收起进行中条」在
//    条已自动消失后触发 scaffold.dart:341 断言
//    `_snackBars.first == controller` 崩溃（恰在收起进行中条一步，
//    结果条永不出现；真机 8 次换源全如此，证据
//    docs/parity_shots/verify_ui_20260922/p29b_b1_crash_dialog.png）。
//    四个入口（菜单面板换源/刷新 + 顶栏换书源/刷新）各钉一条慢路径：
//    改造前该组必红（takeException 非 null 且结果条不出现）。
//
// 本文件引用的 mock 方法均属既有 RustApi 契约（未新增 FFI）；
// 新行为以「UI 入口触发强制路径」表达，改造前文件可编译可运行，
// 红 = 断言失败（非编译错误）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar.dart';

import '../mocks/mocks.dart';

const _testBook = Book(
  bookUrl: 'https://book.com/1',
  name: '测试书籍',
  author: '作者',
  origin: 'https://source-a.com',
  originName: '源A',
  durChapterIndex: 1,
  durChapterPos: 3,
);

const _oldToc = [
  BookChapter(url: 'https://book.com/1/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/1/c2', title: '第二章', index: 1),
];

/// 换源后的书籍记录（Rust 换源事务：bookUrl 为稳定主键不变，
/// origin/originName 等源相关字段已更新，originBookUrl 写新源详情页）
const _newBookRecord = Book(
  bookUrl: 'https://book.com/1',
  name: '测试书籍',
  author: '作者',
  origin: 'https://source-b.com',
  originName: '源B',
  originBookUrl: 'https://book.com/1',
  durChapterIndex: 1,
  durChapterPos: 3,
);

/// 新源目录（章节 url 属新源；章节名与旧目录对应）
const _newToc = [
  BookChapter(url: 'https://book.com/2/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/2/c2', title: '第二章', index: 1),
  BookChapter(url: 'https://book.com/2/c3', title: '第三章', index: 2),
];

/// 本地书（origin = loc_book，不显示换源/刷新/缓存入口）
const _localBook = Book(
  bookUrl: 'loc_book/本地书籍.txt',
  name: '本地书籍',
  author: '作者',
  origin: BookType.localTag,
  originName: '本地书',
  durChapterIndex: 0,
);

const _localToc = [
  BookChapter(url: 'loc_book/本地书籍.txt', title: '第一章', index: 0),
];

/// 打开书籍的最小 stub（对标 reader_notifier_test 的 stubOpenBook）
void stubOpenBook(MockRustApi api, {String content = '旧正文（缓存）'}) {
  when(() => api.getChapters(any())).thenAnswer((_) async => _oldToc);
  when(
    () => api.getChapterContentFull(any(), any()),
  ).thenAnswer((_) async => content);
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
}

ProviderContainer makeContainer(MockRustApi mockApi) {
  return ProviderContainer(
    overrides: [bookApiProvider.overrideWithValue(mockApi)],
  );
}

Widget wrapMenuPanel(
  ProviderContainer container, {
  // ④ 组注入：模拟生产 onGenerateRoute（/change_source 返回
  // PageRouteBuilder<dynamic>）；缺省不注入，行为与既有 ①⑤ 组一致
  // （本 SDK 中 Navigator.onGenerateRoute 的回调类型为 RouteFactory）
  RouteFactory? onGenerateRoute,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      onGenerateRoute: onGenerateRoute,
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
}

Widget wrapTopBar(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Stack(children: [ReaderTopBar(onAddBookmark: () {})]),
      ),
    ),
  );
}

/// 模拟换源屏成功退出：进入即 `Navigator.pop(context, newBookUrl)`
/// （契约对齐 ChangeSourceScreen._applySource 成功路径的 pop 值）
class _AutoPopChangeSource extends StatefulWidget {
  final Object? result;
  const _AutoPopChangeSource({this.result});

  @override
  State<_AutoPopChangeSource> createState() => _AutoPopChangeSourceState();
}

class _AutoPopChangeSourceState extends State<_AutoPopChangeSource> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) Navigator.of(context).pop(widget.result);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  setUpAll(registerFallbacks);

  group('① 菜单面板「刷新正文」= 强制拉取（绕过缓存）', () {
    testWidgets('点刷新正文 → 清缓存 + 联网抓取，正文更新为网络新内容并有成功反馈', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 2);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新正文（网络）');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);
      expect(container.read(readerNotifierProvider).chapterContent, '旧正文（缓存）');

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      // 当前章 = 第二章（index 1，来自 testBook.durChapterIndex）
      await tester.tap(find.byTooltip('刷新正文'));
      await tester.pumpAndSettle();

      // 强制拉取路径：清缓存 + 联网抓取当前章（url 属当前目录 c2）
      verify(() => mockApi.clearBookCache('https://book.com/1')).called(1);
      verify(
        () => mockApi.fetchChapterContent(
          'https://book.com/1',
          'https://book.com/1/c2',
          'https://source-a.com',
        ),
      ).called(1);
      // 正文更新为网络新内容（而非缓存旧内容）
      expect(container.read(readerNotifierProvider).chapterContent, '新正文（网络）');
      // 成功反馈显式可见
      expect(find.text('正文已刷新'), findsOneWidget);
      // 让 SnackBar 到期消失，避免挂起 Timer
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('② 换书源成功返回后重载（重读书籍 + 重载目录 + 强制刷新）', () {
    testWidgets('顶栏换书源 → 路由 pop 新 bookUrl → 重读 + 重载 + 强制刷新，currentBook 更新', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      // 换源后的重载 stub
      when(
        () => mockApi.getBook(any()),
      ).thenAnswer((_) async => _newBookRecord);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => _newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            initialRoute: '/reader',
            onGenerateRoute: (settings) {
              if (settings.name == AppRoutes.changeSource) {
                // 模拟「换源成功，路由 pop 新 bookUrl」。调用方为无类型
                // pushNamed（生产 /change_source 路由是
                // _ChangeSourceSheetRoute（PageRouteBuilder<dynamic>），
                // 类型化 pushNamed<String> 会在运行期强转崩溃——真实
                // 路由类型回归见 ④ 组）
                return MaterialPageRoute<String?>(
                  builder: (_) =>
                      _AutoPopChangeSource(result: 'https://book.com/1'),
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Stack(children: [ReaderTopBar(onAddBookmark: () {})]),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 顶栏 → 换源菜单 → 换书源
      await tester.tap(find.byTooltip('换源'));
      await tester.pumpAndSettle(); // 底部菜单弹层动画
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // 菜单收起 + 换源路由自动 pop + 重载

      // ② 断言：重读书籍 + 重载目录 + 强制拉取（新源当前章 url）
      verify(() => mockApi.getBook('https://book.com/1')).called(1);
      verify(
        () => mockApi.fetchChapterContent(
          'https://book.com/1',
          'https://book.com/2/c2',
          'https://source-b.com',
        ),
      ).called(1);
      final st = container.read(readerNotifierProvider);
      expect(st.currentBook?.bookUrl, 'https://book.com/1'); // 稳定主键
      expect(st.currentBook?.origin, 'https://source-b.com');
      expect(st.currentChapterIndex, 1); // 「第二章」按标题命中
      expect(st.currentChapterPos, 3); // 同题章节 → 章内位置保留
      expect(st.chapterContent, '新源新正文');
      // 换源成功 toast（源名取换源后记录的 originName）
      expect(find.text('已更换书源：源B'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('③ 顶栏「刷新」反馈（成功显式 / 失败可见）', () {
    testWidgets('刷新成功 → SnackBar「正文已刷新」（而非无条件「已刷新」）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 1);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新正文（网络）');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapTopBar(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();

      expect(container.read(readerNotifierProvider).chapterContent, '新正文（网络）');
      expect(find.text('正文已刷新'), findsOneWidget);
      // 旧行为的误导性文案不得再出现
      expect(find.text('已刷新'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('强制抓取失败 → SnackBar 含原因（非静默）且旧正文保留', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenThrow(const BridgeError(message: '404: 源不可达'));

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapTopBar(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();

      // 失败原因可见（非静默）
      expect(find.text('刷新正文失败：404: 源不可达'), findsOneWidget);
      // 旧正文保留（不清空）
      expect(container.read(readerNotifierProvider).chapterContent, '旧正文（缓存）');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('④ 换源路由真实类型回归（PageRouteBuilder<dynamic> 不崩溃）', () {
    test('generateRoute 对 /change_source 返回 dynamic 型路由（非 Route<String?>）', () {
      // 类型守卫：生产路由 _ChangeSourceSheetRoute 继承
      // PageRouteBuilder<dynamic>（routes.dart:465），不是 Route<String?>
      // 的子类型——任何 pushNamed<String>(AppRoutes.changeSource) 都会
      // 在运行期强转处抛 TypeError（真机崩溃，证据
      // docs/parity_shots/verify_ui_20260922/p29_crash_dialog_change_source.xml）
      final route = AppRoutes.generateRoute(
        const RouteSettings(name: AppRoutes.changeSource),
      );
      expect(route, isA<PageRouteBuilder<dynamic>>());
      // PageRouteBuilder<dynamic> 不是 Route<String?> 的子类型
      // （dynamic 非 String? 子类型）：类型化 pushNamed<String> 的
      // 运行期强转即在此断裂
      expect(route is Route<String?>, isFalse);
    });

    testWidgets('菜单面板换源（dynamic 型路由）不崩溃且重载完成', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      // 换源后的重载 stub（openBook 先取 _oldToc，重载时取 _newToc）
      when(
        () => mockApi.getBook(any()),
      ).thenAnswer((_) async => _newBookRecord);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => _newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        wrapMenuPanel(
          container,
          onGenerateRoute: (settings) {
            if (settings.name == AppRoutes.changeSource) {
              // 与生产 _ChangeSourceSheetRoute 同型（routes.dart:465）：
              // PageRouteBuilder<dynamic>——改造前（调用方
              // pushNamed<String>）此路由会让 Navigator 在强转
              // Route<String?> 处抛 TypeError
              return PageRouteBuilder<dynamic>(
                settings: settings,
                pageBuilder: (context, _, _) =>
                    _AutoPopChangeSource(result: 'https://book.com/1'),
              );
            }
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: SizedBox.shrink()),
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      // 在线书渲染两处换源入口（顶栏 IconButton + 中部快捷钮），
      // 此处只取顶栏 IconButton
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == '换源',
        ),
      );
      // 改造前此处抛 "type _ChangeSourceSheetRoute is not a subtype
      // of type 'Route<String?>?' in type cast" —— 必须无异常才算不崩溃
      final exception = tester.takeException();
      expect(exception, isNull);
      await tester.pumpAndSettle(); // 换源路由自动 pop + 重载

      verify(() => mockApi.getBook('https://book.com/1')).called(1);
      verify(
        () => mockApi.fetchChapterContent(
          'https://book.com/1',
          'https://book.com/2/c2',
          'https://source-b.com',
        ),
      ).called(1);
      final st = container.read(readerNotifierProvider);
      expect(st.currentBook?.origin, 'https://source-b.com');
      expect(st.currentChapterIndex, 1);
      expect(st.chapterContent, '新源新正文');
      expect(find.text('已更换书源：源B'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('⑤ 本地书不渲染换源/刷新/缓存入口（隐藏而非置灰）', () {
    testWidgets('本地书菜单面板：三项在线书入口不渲染，其余入口保留', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      when(
        () => mockApi.getChapters(any()),
      ).thenAnswer((_) async => _localToc);
      when(
        () => mockApi.getChapterContentFull(any(), any()),
      ).thenAnswer((_) async => '本地正文');
      when(
        () => mockApi.updateReadingProgress(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
          chapterPos: any(named: 'chapterPos'),
        ),
      ).thenAnswer((_) async {});

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_localBook);
      expect(container.read(readerNotifierProvider).chapterContent, '本地正文');

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      // 本地书：在线书专属入口不渲染（而非置灰不可点）
      expect(find.byTooltip('换源'), findsNothing);
      expect(find.byTooltip('刷新正文'), findsNothing);
      expect(find.byTooltip('缓存当前章'), findsNothing);
      // 面板仍完整渲染（退出/更多/快捷钮保留，非整体隐藏）
      expect(find.byTooltip('退出阅读'), findsOneWidget);
      expect(find.byTooltip('更多'), findsOneWidget);
      expect(find.byTooltip('搜索'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });

  group('⑥ 慢路径 SnackBar 竞态（重载/抓取 > 4s 自动消失时长）', () {
    // 竞态：旧写法「show 进行中条 → await 重活 → controller.close()」
    // 在 await 耗时超过 SnackBar 默认 4s 自动消失时长时，进行中条已
    // 不在 Scaffold 队列首（或队列已空）→ close() 触发
    // scaffold.dart:341 断言 `_snackBars.first == controller`（或队列
    // 空时 `_snackBars.first` 抛 StateError）→ 恰在「收起进行中条」
    // 一步崩溃，结果条永不出现。安全语义（生产端本轮修复）：进行中条
    // 显式 10min duration（慢重载期间不自动消失）+ 结果就绪后
    // removeCurrentSnackBar()（SDK：队列为空早退、无断言）再弹结果条。
    // 推进方式：tap 触发后 pump(5s) 覆盖 4s 自动消失时刻，pump(2s)
    // 覆盖 6s 慢 mock 完成时刻，pumpAndSettle 跑完结果条入场动画。

    testWidgets('菜单面板换源（慢路径）：不崩溃且结果条出现', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      // 慢路径：getBook 延迟 6s（> SnackBar 默认 4s 自动消失时长）
      when(
        () => mockApi.getBook(any()),
      ).thenAnswer(
        (_) =>
            Future<Book?>.delayed(const Duration(seconds: 6), () => _newBookRecord),
      );
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => _newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        wrapMenuPanel(
          container,
          onGenerateRoute: (settings) {
            if (settings.name == AppRoutes.changeSource) {
              return PageRouteBuilder<dynamic>(
                settings: settings,
                pageBuilder: (context, _, _) =>
                    _AutoPopChangeSource(result: 'https://book.com/1'),
              );
            }
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: SizedBox.shrink()),
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == '换源',
        ),
      );
      await tester.pumpAndSettle(); // 换源路由自动 pop + 重载启动（getBook 悬置）
      // 慢路径推进（1s 粒度，对齐真机 16ms 帧节奏：自动消失后的队列
      // 移除帧先于慢 mock 完成时刻落地；粗粒度 5s/2s pump 会让移除帧
      // 滞后于 close()，测不出竞态）：t≈4.6s 进行中条 4s 自动消失，
      // t≈6.6s getBook 完成、流程恢复
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle(); // 结果条入场动画

      // 旧写法在此抛 scaffold.dart:341 断言 / StateError —— 必须无异常
      final exception = tester.takeException();
      expect(exception, isNull);
      // 结果条最终出现（旧写法崩在收起进行中条一步，结果条永不出现）
      expect(find.textContaining('已更换书源'), findsOneWidget);
      verify(() => mockApi.getBook('https://book.com/1')).called(1);
      expect(
        container.read(readerNotifierProvider).currentBook?.origin,
        'https://source-b.com',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('菜单面板刷新（慢路径）：不崩溃且结果条出现', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      // 慢路径：fetchChapterContent 延迟 7s（> 4s 自动消失时长；取 7s
      // 保证完成时刻晚于队列移除帧，旧 close() 代码必踩空队列）
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer(
        (_) =>
            Future<String>.delayed(
              const Duration(seconds: 7),
              () => '新正文（网络）',
            ),
      );

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapMenuPanel(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('刷新正文'));
      await tester.pump(); // 进行中条开始入场
      // 慢路径推进（1s 粒度，对齐真机 16ms 帧节奏：自动消失后的队列
      // 移除帧先于慢 mock 完成时刻落地；粗粒度 pump 会测不出竞态）：
      // t≈4.3s 进行中条 4s 自动消失（含退场 ≈5.1s 队列移除），
      // t≈7s 抓取完成、流程恢复
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle(); // 结果条入场动画

      final exception = tester.takeException();
      expect(exception, isNull);
      expect(find.textContaining('正文已刷新'), findsOneWidget);
      expect(
        container.read(readerNotifierProvider).chapterContent,
        '新正文（网络）',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('顶栏换书源（慢路径）：不崩溃且结果条出现', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      // 慢路径：getBook 延迟 6s（> 4s 自动消失时长）
      when(
        () => mockApi.getBook(any()),
      ).thenAnswer(
        (_) =>
            Future<Book?>.delayed(const Duration(seconds: 6), () => _newBookRecord),
      );
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => _newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            initialRoute: '/reader',
            onGenerateRoute: (settings) {
              if (settings.name == AppRoutes.changeSource) {
                return MaterialPageRoute<String?>(
                  builder: (_) =>
                      _AutoPopChangeSource(result: 'https://book.com/1'),
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Stack(children: [ReaderTopBar(onAddBookmark: () {})]),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 顶栏 → 换源菜单 → 换书源
      await tester.tap(find.byTooltip('换源'));
      await tester.pumpAndSettle(); // 底部菜单弹层动画
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // 菜单收起 + 换源路由自动 pop + 重载启动
      // 慢路径推进（1s 粒度，对齐真机 16ms 帧节奏：自动消失后的队列
      // 移除帧先于慢 mock 完成时刻落地；粗粒度 pump 会测不出竞态）：
      // t≈4.6s 进行中条 4s 自动消失，t≈6.6s getBook 完成、流程恢复
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle(); // 结果条入场动画

      final exception = tester.takeException();
      expect(exception, isNull);
      expect(find.textContaining('已更换书源'), findsOneWidget);
      verify(() => mockApi.getBook('https://book.com/1')).called(1);
      expect(
        container.read(readerNotifierProvider).currentBook?.origin,
        'https://source-b.com',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('顶栏刷新（慢路径）：不崩溃且结果条出现', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 1);
      // 慢路径：fetchChapterContent 延迟 7s（> 4s 自动消失时长；取 7s
      // 保证完成时刻晚于队列移除帧，旧 close() 代码必踩空队列）
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer(
        (_) =>
            Future<String>.delayed(
              const Duration(seconds: 7),
              () => '新正文（网络）',
            ),
      );

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(wrapTopBar(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('刷新'));
      await tester.pump(); // 进行中条开始入场
      // 慢路径推进（1s 粒度，对齐真机 16ms 帧节奏：自动消失后的队列
      // 移除帧先于慢 mock 完成时刻落地；粗粒度 pump 会测不出竞态）：
      // t≈4.3s 进行中条 4s 自动消失（含退场 ≈5.1s 队列移除），
      // t≈7s 抓取完成、流程恢复
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle(); // 结果条入场动画

      final exception = tester.takeException();
      expect(exception, isNull);
      expect(find.textContaining('正文已刷新'), findsOneWidget);
      expect(
        container.read(readerNotifierProvider).chapterContent,
        '新正文（网络）',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
