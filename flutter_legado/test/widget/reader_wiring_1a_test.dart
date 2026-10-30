// [批1a | 2026-10-31] 阅读器接线行为测试 — 全栈工程师
//
// 覆盖：
// 1. showReadTitleAddition：菜单顶栏信息块（章节名 + 书源徽标）按偏好显隐；
//    关闭时信息块不渲染（修前恒显示）
// 2. disableReturnKey：开启且菜单未展开 → 系统返回不放行（阅读器不退出、
//    无「放入书架」弹窗）；菜单展开 → 先关菜单不退出；未开启 → 原退出路径
//    不变（弹「放入书架」提示）
// 3. 振动接线：翻页成功 / 选词触发 HapticFeedback（经注入收集器断言，
//    platform channel 在测试环境不可直接断言）
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';

import '../mocks/mocks.dart';

const _shelfBook = Book(
  bookUrl: 'https://book.com/back-key',
  name: '返回键书',
  author: '作者',
  origin: 'https://source-a.com',
  originName: '源A',
);

const _chapters = [
  BookChapter(url: 'https://book.com/back-key/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/back-key/c2', title: '第二章', index: 1),
];

MockRustApi _stubApi() {
  final api = MockRustApi();
  when(() => api.getChapters(any())).thenAnswer((_) async => _chapters);
  when(() => api.getChapterContentFull(any(), any()))
      .thenAnswer((i) async => 'CH${i.positionalArguments[1]}');
  when(() => api.getChapterContent(any(), any())).thenAnswer((_) async => '');
  when(() => api.getBookSources()).thenAnswer((_) async => const []);
  when(() => api.getConfig(any())).thenAnswer((_) async => '');
  when(() => api.getBook(any())).thenAnswer((_) async => _shelfBook);
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
  return api;
}

/// 菜单面板场景外壳（已开书 + visible=true）
Widget _menuPanelHarness(ProviderContainer container) {
  return UncontrolledProviderScope(
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
}

/// 启动 App（按钮 push 真实 ReaderScreen，PopScope 可触发）+ 打开书
Future<ProviderContainer> _pumpReader(WidgetTester tester) async {
  final api = _stubApi();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<Route<dynamic>>(
                    builder: (_) => const ReaderScreen(),
                  ),
                ),
                child: const Text('进入阅读'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('进入阅读'));
  await tester.pumpAndSettle();

  final container =
      ProviderScope.containerOf(tester.element(find.byType(ReaderScreen)));
  await container.read(readerNotifierProvider.notifier).openBook(_shelfBook);
  await tester.pumpAndSettle();
  return container;
}

/// 触发系统返回（maybePop → canPop=false 的 PopScope 拦截）
void _popReader(WidgetTester tester) {
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .maybePop();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'enableReadRecord': false});
  });

  group('showReadTitleAddition 菜单顶栏信息块显隐', () {
    /// 菜单面板场景：已开书 + 信息块条件齐备（章节非空 / 源名非空）
    Future<ProviderContainer> pumpMenu(WidgetTester tester) async {
      final api = _stubApi();
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(readerNotifierProvider.notifier);
      await notifier.openBook(_shelfBook);

      await tester.pumpWidget(_menuPanelHarness(container));
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('默认（true）显示章节名信息块', (tester) async {
      await pumpMenu(tester);

      // 章节名「第一章」在信息块渲染（正文章节未挂载，此文本唯一）
      expect(find.text('第一章'), findsOneWidget);
      // 书源徽标
      expect(find.text('源A'), findsOneWidget);
    });

    testWidgets('关闭后信息块不渲染（修前恒显示）', (tester) async {
      final container = await pumpMenu(tester);
      expect(find.text('第一章'), findsOneWidget);

      // 推送 showReadTitleAddition=false（等价阅读设置页改值路径）
      final cfg = container.read(readerAdvConfigProvider) ??
          (await ReaderAdvancedConfig.load());
      cfg.showReadTitleAddition = false;
      container
          .read(readerAdvConfigProvider.notifier)
          .apply(cfg.copy());
      await tester.pumpAndSettle();

      expect(
        find.text('第一章'),
        findsNothing,
        reason: 'showReadTitleAddition=false 时顶栏信息块必须整体不渲染',
      );
      expect(find.text('源A'), findsNothing);
    });

    testWidgets('重新开启后信息块恢复渲染', (tester) async {
      final container = await pumpMenu(tester);
      final cfg = container.read(readerAdvConfigProvider)!;
      cfg.showReadTitleAddition = false;
      container.read(readerAdvConfigProvider.notifier).apply(cfg.copy());
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsNothing);

      cfg.showReadTitleAddition = true;
      container.read(readerAdvConfigProvider.notifier).apply(cfg.copy());
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget);
    });
  });

  group('disableReturnKey 返回拦截', () {
    testWidgets('默认关闭：返回走原退出判定（弹「放入书架」— 已入架书则直接退）',
        (tester) async {
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(container.read(readerAdvConfigProvider)?.disableReturnKey,
          isFalse);

      _popReader(tester);
      await tester.pumpAndSettle();

      // 已入架书（getBook 返回未打 notShelf 位）→ 直接退出
      expect(find.byType(ReaderScreen), findsNothing);
    });

    testWidgets('开启且菜单未展开：返回不放行，阅读器保持', (tester) async {
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);

      // 开启 disableReturnKey（等价阅读设置页改值路径：save + 推 provider）
      final cfg = (container.read(readerAdvConfigProvider) ??
              await ReaderAdvancedConfig.load())
          .copy();
      cfg.disableReturnKey = true;
      await cfg.save();
      container.read(readerAdvConfigProvider.notifier).apply(cfg);

      expect(container.read(readerNotifierProvider).showControls, isFalse);
      _popReader(tester);
      await tester.pumpAndSettle();

      expect(
        find.byType(ReaderScreen),
        findsOneWidget,
        reason: 'disableReturnKey=true 且菜单未开时返回键不得退出阅读器',
      );
      expect(find.text('放入书架'), findsNothing);
    });

    testWidgets('开启且菜单展开：返回放行走既有退出判定（不吞）',
        (tester) async {
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);

      final cfg = (container.read(readerAdvConfigProvider) ??
              await ReaderAdvancedConfig.load())
          .copy();
      cfg.disableReturnKey = true;
      await cfg.save();
      container.read(readerAdvConfigProvider.notifier).apply(cfg);

      // 展开菜单（等价点击正文中央）
      container.read(readerNotifierProvider.notifier).toggleControls();
      await tester.pumpAndSettle();
      expect(container.read(readerNotifierProvider).showControls, isTrue);

      _popReader(tester);
      await tester.pumpAndSettle();

      // 对齐原版 ReadBookActivity.kt:391-414：仅 disableReturnKey &&
      // !menuLayoutIsVisible 才吞返回；菜单展开时放行 → 既有退出判定
      //（已入架书 → 直接退出，阅读器路由消失）
      expect(
        find.byType(ReaderScreen),
        findsNothing,
        reason: '菜单展开时返回不拦截，走既有退出判定（保证可达退出路径）',
      );
    });

    testWidgets('开启时仍存在可达退出路径（菜单开→返回退出）', (tester) async {
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);

      final cfg = (container.read(readerAdvConfigProvider) ??
              await ReaderAdvancedConfig.load())
          .copy();
      cfg.disableReturnKey = true;
      await cfg.save();
      container.read(readerAdvConfigProvider.notifier).apply(cfg);

      // 连续两次：菜单关 → 吞返回保持；再展开菜单 → 返回退出
      _popReader(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget,
          reason: '菜单关吞返回（第一路）');

      container.read(readerNotifierProvider.notifier).toggleControls();
      await tester.pumpAndSettle();
      _popReader(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing,
          reason: '开启 disableReturnKey 后菜单展开路径仍可退出（无死锁）');
    });
  });

  group('振动接线（sliderVibrator / selectVibrator）', () {
    testWidgets('翻页成功且 sliderVibrator=true → 触发振动注入点',
        (tester) async {
      final calls = <String>[];
      ReaderPageViewState.onPageTurnedHaptic = () => calls.add('turn');
      addTearDown(() {
        ReaderPageViewState.onPageTurnedHaptic = HapticFeedback.selectionClick;
      });

      final container = await _pumpReader(tester);
      addTearDown(container.dispose);

      final cfg = (container.read(readerAdvConfigProvider) ??
              await ReaderAdvancedConfig.load())
          .copy();
      cfg.sliderVibrator = true;
      await cfg.save();
      container.read(readerAdvConfigProvider.notifier).apply(cfg);

      // 点击右侧翻页区（nextPage 动作 → nextPageOrChapter → 翻页成功）
      final size = tester.getSize(find.byType(ReaderScreen));
      final origin = tester.getTopLeft(find.byType(ReaderScreen));
      await tester.tapAt(origin + Offset(size.width * 0.85, size.height * 0.5));
      await tester.pumpAndSettle();

      expect(
        calls,
        isNotEmpty,
        reason: 'sliderVibrator=true 翻页成功必须触发振动',
      );
    });

    testWidgets('sliderVibrator=false 翻页不触发振动（默认行为不变）',
        (tester) async {
      final calls = <String>[];
      ReaderPageViewState.onPageTurnedHaptic = () => calls.add('turn');
      addTearDown(() {
        ReaderPageViewState.onPageTurnedHaptic = HapticFeedback.selectionClick;
      });

      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(container.read(readerAdvConfigProvider)?.sliderVibrator, isFalse);

      final size = tester.getSize(find.byType(ReaderScreen));
      final origin = tester.getTopLeft(find.byType(ReaderScreen));
      await tester.tapAt(origin + Offset(size.width * 0.85, size.height * 0.5));
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '默认关闭不振动（对齐参考版默认 false）');
    });

    testWidgets('selectVibrator=true 长按选词触发 HapticFeedback 通道消息',
        (tester) async {
      // [批1a 审查回修] mock flutter/platform 通道捕获 HapticFeedback.vibrate
      // 消息（HapticFeedback.selectionClick 发送
      // ('HapticFeedback.vibrate', 'HapticFeedbackType.selectionClick')，
      // 见 SDK haptic_feedback.dart L90-95），开=1 次 / 关=0 次 — 全栈工程师
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final container = await _pumpReader(tester);
      addTearDown(container.dispose);

      final cfg = (container.read(readerAdvConfigProvider) ??
              await ReaderAdvancedConfig.load())
          .copy();
      cfg.selectVibrator = true;
      await cfg.save();
      container.read(readerAdvConfigProvider.notifier).apply(cfg);

      // 长按正文段落（ReaderTextContent selectText 长按入口 →
      // ReaderSelectionToolbar.show → selectVibrator 分支）；正文按
      // 排版引擎逐行渲染（全角缩进前缀），全文搜索面板亦有同文本，
      // 取第一个命中（正文区）定位
      await tester.longPress(find.textContaining('CH').first);
      await tester.pumpAndSettle();

      expect(
        haptics.where((m) => m.contains('selectionClick')),
        hasLength(1),
        reason: 'selectVibrator=true 起选即发一次 selectionClick 通道消息',
      );
    });

    testWidgets('selectVibrator=false 长按选词不发送振动消息（默认）',
        (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(container.read(readerAdvConfigProvider)?.selectVibrator, isFalse);

      await tester.longPress(find.textContaining('CH').first);
      await tester.pumpAndSettle();

      expect(
        haptics.where((m) => m.contains('selectionClick')),
        isEmpty,
        reason: '默认关闭不发送振动（对齐参考版默认 false）',
      );
    });
  });
}
