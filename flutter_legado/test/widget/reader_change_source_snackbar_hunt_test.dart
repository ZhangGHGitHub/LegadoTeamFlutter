// [SB-HUNT | 2026-09-25] 换源后「第二条/残留 SnackBar」回归
//
// 真机证据（docs/parity_shots/verify_ui_20260922/）：换源后「正在更换书源…」
// 与结果条并存（swb_ui46「已更换书源：…」+ swb_ui_a/t/v/x/z「正在更换书源…」
// 残留）；且换源页自身「已切换到『源名』」（p29b_sb*/p29b_sbf*/p29b_sbg* 系列）
// 与阅读器侧「已更换书源：源名」结果条构成同一动作双结果提示。
//
// ① 双入口连发：菜单入口 A 在途（getBook 8s）+ 顶栏入口 B（getBook 12s）
//    → 断言 getBook 只调一次（第二触发被忽略）+ 终态无「已更换书源…」
//    残留结果条（改造前必红：getBook 两次 + A 的结果条过期后 B 的结果条
//    浮现 = 真机残留复现）
// ② 残留回归：重载在途时离场（流程 context unmounted）→ 终态断言无
//    「正在更换书源…」残留（改造前必红：10min 进行中条跳过清理残留）；
//    ②b 异常变体（getBook 抛错 + 离场 → 无任何条）；②c 取消（pop null →
//    无进行中条、getBook 未调用，回归护栏）
// ③ 结果去重：换源页「已切换到」为唯一成功反馈，阅读器侧成功条移除
//    （③a：页面成功条后阅读器侧应无条且无残留；③b：失败恰好一条阅读器
//    侧「更换书源后重载失败」条、无成功条、无残留）
//
// 本文件引用的 mock 方法均属既有 RustApi 契约（未新增 FFI）；新行为以
// 「无残留/去重/单触发」表达，改造前文件可编译可运行，红 = 断言失败
//（非编译错误）。

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

/// 换源后的书籍记录（Rust 换源事务：bookUrl 稳定主键不变，源字段已更新）
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

/// 打开书籍的最小 stub（对标 reader_force_refresh_test 的 stubOpenBook）
void stubOpenBook(MockRustApi api) {
  when(() => api.getChapters(any())).thenAnswer(
    (_) async => const [
      BookChapter(url: 'https://book.com/1/c1', title: '第一章', index: 0),
      BookChapter(url: 'https://book.com/1/c2', title: '第二章', index: 1),
    ],
  );
  when(
    () => api.getChapterContentFull(any(), any()),
  ).thenAnswer((_) async => '旧正文（缓存）');
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

/// 组合树：菜单面板 + 顶栏同场景（两入口共用同一 notifier 实例 →
/// 共享重入守卫生效面；顶栏在 Stack 上层，按钮可点）
Widget wrapReader(ProviderContainer container, {RouteFactory? onGenerateRoute}) {
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
            ReaderTopBar(onAddBookmark: () {}),
          ],
        ),
      ),
    ),
  );
}

/// 顶栏树 + 「可离场」壳：_Home 为 StatefulWidget，withReader 切换只换
/// home 子树，MaterialApp（ScaffoldMessenger）元素保持——对齐真机
/// BACK 离场阅读器（根 messenger 与进行中条队列存活，仅阅读器离场）
Widget _topBarTree(
  ProviderContainer container, {
  bool withReader = true,
  RouteFactory? onGenerateRoute,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      onGenerateRoute: onGenerateRoute,
      home: _Home(withReader: withReader),
    ),
  );
}

class _Home extends StatefulWidget {
  final bool withReader;
  const _Home({required this.withReader});

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: widget.withReader
          ? Stack(children: [ReaderTopBar(onAddBookmark: () {})])
          : const SizedBox.shrink(),
    );
  }
}

/// 模拟换源屏成功退出（对齐 _AutoPopChangeSource 契约：进入即 microtask
/// pop result；不弹页侧成功条）
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

/// 模拟换源页成功契约（对齐 ChangeSourceScreen._applySource 成功路径：
/// 先弹「已切换到『源名』」成功条、后 pop 新 bookUrl）
class _PageContractChangeSource extends StatefulWidget {
  final Object? result;
  final String sourceName;
  const _PageContractChangeSource({this.result, required this.sourceName});

  @override
  State<_PageContractChangeSource> createState() =>
      _PageContractChangeSourceState();
}

class _PageContractChangeSourceState extends State<_PageContractChangeSource> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到「${widget.sourceName}」')),
      );
      Navigator.of(context).pop(widget.result);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 自动 pop 路由（与生产 /change_source 路由同型：
/// `PageRouteBuilder<dynamic>`，见 routes.dart _ChangeSourceSheetRoute）
RouteFactory autoPopRoute(Object? result) => (settings) {
  if (settings.name == AppRoutes.changeSource) {
    return PageRouteBuilder<dynamic>(
      settings: settings,
      pageBuilder: (context, _, _) => _AutoPopChangeSource(result: result),
    );
  }
  return MaterialPageRoute<void>(
    builder: (_) => const Scaffold(body: SizedBox.shrink()),
  );
};

/// 页侧成功契约路由（换源页弹「已切换到」后 pop 新 bookUrl）
RouteFactory pageContractRoute(Object? result, String sourceName) => (
  settings,
) {
  if (settings.name == AppRoutes.changeSource) {
    return PageRouteBuilder<dynamic>(
      settings: settings,
      pageBuilder: (context, _, _) =>
          _PageContractChangeSource(result: result, sourceName: sourceName),
    );
  }
  return MaterialPageRoute<void>(
    builder: (_) => const Scaffold(body: SizedBox.shrink()),
  );
};

/// 菜单面板中部快捷「换源」钮（面板内第二处换源入口：顶栏行 IconButton
/// 在先、中部快捷钮在后；位于屏幕中部，与顶栏按钮无命中区重叠）
Finder get _panelMidChangeSource => find
    .descendant(
      of: find.byType(ReaderMenuPanel),
      matching: find.byTooltip('换源'),
    )
    .last;

/// 顶栏「换源」钮（顶栏树中唯一）
Finder get _topBarChangeSource => find.descendant(
  of: find.byType(ReaderTopBar),
  matching: find.byTooltip('换源'),
);

void main() {
  setUpAll(registerFallbacks);

  group('① 双入口连发（菜单在途 + 顶栏第二触发）', () {
    testWidgets('getBook 只调一次、终态无残留结果条（改造前必红）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      // 错峰慢路径：A（菜单入口）getBook 8s，B（顶栏入口）getBook 12s
      var getBookSeq = 0;
      when(() => mockApi.getBook(any())).thenAnswer((_) {
        getBookSeq += 1;
        final delay = getBookSeq == 1 ? 8 : 12;
        return Future<Book?>.delayed(Duration(seconds: delay), () => _newBookRecord);
      });
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => _newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        wrapReader(container, onGenerateRoute: autoPopRoute('https://book.com/1')),
      );
      await tester.pumpAndSettle();

      // A = 菜单面板中部快捷「换源」
      await tester.tap(_panelMidChangeSource);
      await tester.pumpAndSettle(); // A 路由自动 pop + 重载启动（getBook#1 悬置 8s）
      expect(find.text('正在更换书源…'), findsOneWidget);

      // B = 顶栏「换源」→「换书源」（A 在途时触发）
      await tester.tap(_topBarChangeSource);
      await tester.pumpAndSettle(); // 底部菜单弹层入场
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // B 路由自动 pop +（改造前）第二次重载启动
      // FIFO 队列仅渲染队首 → 视觉上仍一条进行中条（改造前两堆叠条并
      // 不可见，真红信号 = 下方 getBook 次数与残留结果条）
      expect(find.text('正在更换书源…'), findsOneWidget);

      // t≈6.5（A 未完成）：getBook 应只调用一次（改造前红：A+B 双执行
      // → called(2)）
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      verify(() => mockApi.getBook(any())).called(1);

      // t≈13（B 的 12s 完成）：阅读器侧不应有「已更换书源…」结果条
      //（改造前红：A 结果条 4s 过期后 B 的「已更换书源：源B」浮现 =
      // 真机残留复现 swb_ui46 + swb_ui_a 系列）
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('已更换书源'), findsNothing);
      expect(find.text('正在更换书源…'), findsNothing);
      // 计时器安全：冲刷任何 10min 进行中条定时器（改造前残留路径）
      await tester.pump(const Duration(minutes: 11));
      await tester.pumpAndSettle();
    });
  });

  group('② 残留回归（在途完成必清理）', () {
    testWidgets('重载在途离场 → 无「正在更换书源…」残留（改造前必红）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      // 慢路径：getBook 延迟 8s
      when(() => mockApi.getBook(any())).thenAnswer(
        (_) =>
            Future<Book?>.delayed(const Duration(seconds: 8), () => _newBookRecord),
      );
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => _newToc);
      when(() => mockApi.clearBookCache(any())).thenAnswer((_) async => 0);
      when(
        () => mockApi.fetchChapterContent(any(), any(), any()),
      ).thenAnswer((_) async => '新源新正文');

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        _topBarTree(container, onGenerateRoute: autoPopRoute('https://book.com/1')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('换源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // 进行中条展示，getBook 悬置 8s
      expect(find.text('正在更换书源…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2)); // t≈2 在途

      // 离场：同 MaterialApp（根 messenger 存活，对齐真机 BACK 离场），
      // 仅顶栏 unmounted → 流程的 context.mounted == false
      await tester.pumpWidget(
        _topBarTree(
          container,
          withReader: false,
          onGenerateRoute: autoPopRoute('https://book.com/1'),
        ),
      );
      // t≈10：getBook 完成、重载完成。改造前：`if (!context.mounted) return;`
      // 跳过清理 → 10min 进行中条残留（红）
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.text('正在更换书源…'), findsNothing);
      expect(find.textContaining('已更换书源'), findsNothing);
      // 计时器安全：冲刷 10min 定时器（改造前残留路径）
      await tester.pump(const Duration(minutes: 11));
      await tester.pumpAndSettle();
    });

    testWidgets('异常 + 离场 → 无任何条（改造前红：进行中条残留）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      // 慢路径异常：getBook 延迟 4s 后失败（保证异常发生在离场之后，
      // 即「在途完成时 context 已 unmounted」路径）
      when(() => mockApi.getBook(any())).thenAnswer(
        (_) async {
          await Future<void>.delayed(const Duration(seconds: 4));
          throw const BridgeError(message: 'bridge 不可用');
        },
      );

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        _topBarTree(container, onGenerateRoute: autoPopRoute('https://book.com/1')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('换源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // 进行中条展示，getBook 悬置 4s
      expect(find.text('正在更换书源…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2)); // t≈2 在途

      // 离场（同 ② 主例：根 messenger 存活、仅顶栏 unmounted）
      await tester.pumpWidget(
        _topBarTree(
          container,
          withReader: false,
          onGenerateRoute: autoPopRoute('https://book.com/1'),
        ),
      );
      // t≈6：getBook 失败（异常已被 reload 捕获，不抛）。改造前：
      // `if (!context.mounted) return;` 跳过清理 → 10min 进行中条残留（红）；
      // 改造后：clearSnackBars 必清理 + 离场不弹失败条 → 无任何 SnackBar
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.text('正在更换书源…'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      // 计时器安全：冲刷 10min 定时器（改造前残留路径）
      await tester.pump(const Duration(minutes: 11));
      await tester.pumpAndSettle();
    });

    testWidgets('取消（pop null）→ 无进行中条、getBook 未调用（回归护栏）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        _topBarTree(container, onGenerateRoute: autoPopRoute(null)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('换源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // 路由 pop null → 取消
      expect(find.text('正在更换书源…'), findsNothing);
      // mocktail：零次调用断言用 verifyNever（.called(0) 会抛错）
      verifyNever(() => mockApi.getBook(any()));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('③ 结果去重（页「已切换到」为唯一成功反馈）', () {
    testWidgets('成功：阅读器侧无成功条 + 无残留（改造前必红）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
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

      // 页侧契约：换源页弹「已切换到「源B」」后 pop 新 bookUrl
      await tester.pumpWidget(
        _topBarTree(
          container,
          onGenerateRoute: pageContractRoute('https://book.com/1', '源B'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('换源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // 重载完成（快）
      // 去重：成功反馈唯一 = 换源页「已切换到」；阅读器侧成功条已移除
      //（改造前红：阅读器「已更换书源：源B」浮现）
      expect(find.textContaining('已更换书源'), findsNothing);
      expect(find.textContaining('更换书源后重载失败'), findsNothing);
      // 无残留：5s 后队列应为空（改造前红：页「已切换到」条被
      // removeCurrent 队首误收后，10min 进行中条残留可见）
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('失败：恰一条阅读器侧失败条、无成功条、无残留', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mockApi = MockRustApi();
      final container = makeContainer(mockApi);
      addTearDown(container.dispose);
      stubOpenBook(mockApi);
      when(() => mockApi.getBook(any())).thenThrow(
        const BridgeError(message: 'bridge 不可用'),
      );

      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_testBook);

      await tester.pumpWidget(
        _topBarTree(container, onGenerateRoute: autoPopRoute('https://book.com/1')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('换源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('换书源'));
      await tester.pumpAndSettle(); // 重载失败（不抛，返回原因）
      // 失败可见（不变量，改造前后均绿）：恰好一条失败条
      expect(find.textContaining('更换书源后重载失败'), findsOneWidget);
      expect(find.textContaining('已更换书源'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      // 无残留（改造前红：10min 进行中条残留可见）
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
