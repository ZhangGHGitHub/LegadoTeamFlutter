// [批1b-1 审查回修 | 2026-10-31] keepLight 通道生命周期 + 亮度条生产挂载
// 测试 — 全栈工程师
//
// 覆盖（needs-changes P1-1 / P1-2 / P2-4）：
// 1. 横条亮度行经 ReaderMenuPanel 生产路径渲染（模式='1'：亮度图标 +
//    横向滑条；模式='0'/'2' 不渲染横条）——不自建 harness，直接用真实
//    ReaderMenuPanel 挂载路径（与 reader_wiring_1a_test 同范式）
// 2. keepLight 定时器语义（真 ReaderScreen pump + fakeAsync 不兼容
//    widget 测试，改用 testWidgets + tester.pump(Duration) 推进假时钟）：
//    - 进入 keepLight=60 → 通道 [true]，60s 后 → [true, false]
//    - 翻页后计时重置（59s 时翻页 → 60s 不清、119s 才清）
//    - keepLight=-1 → [true] 且 10 分钟不自动清
//    - keepLight=0 → 进入不发 true（初始未置 flag 即清语义）
// 3. ReaderScreen 生命周期：进入 [true] / 改值 0 → [true, false] /
//    dispose 追加 false（-1 档路径）
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
import 'package:flutter_legado/src/screens/reader_config_panel.dart'
    show readerAdvConfigProvider;
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';

import '../mocks/mocks.dart';

const _shelfBook = Book(
  bookUrl: 'https://book.com/keep-light',
  name: '亮屏书',
  author: '作者',
  origin: 'https://source-a.com',
);

const _chapters = [
  BookChapter(url: 'https://book.com/keep-light/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/keep-light/c2', title: '第二章', index: 1),
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

/// keepLight 通道调用记录（顶层：[_pumpReader] 内清理跨用例串扰），
/// 每用例 setUp 清空
final keepScreenOnCalls = <bool>[];

/// 启动 App（按钮 push 真实 ReaderScreen）+ 打开书（生产挂载路径）
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
  // 上一用例的 ReaderScreen 树在本次 pumpWidget 替换时才 unmount，其
  // dispose 的 setKeepScreenOn(false) 会落进本用例调用列表——此处
  // （旧树已卸载、阅读器尚未进入）清空，保证后续断言只含本用例时序。
  keepScreenOnCalls.clear();
  await tester.tap(find.text('进入阅读'));
  await tester.pumpAndSettle();

  final container =
      ProviderScope.containerOf(tester.element(find.byType(ReaderScreen)));
  await container.read(readerNotifierProvider.notifier).openBook(_shelfBook);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'enableReadRecord': false});
    keepScreenOnCalls.clear();
    // Windows 测试宿主伪装 Android 分派（生产取 Platform.isAndroid）
    PlatformBridgeService.instance.keepScreenOnOverride = true;
    addTearDown(() {
      PlatformBridgeService.instance.keepScreenOnOverride = null;
      PlatformBridgeService.instance.lastKeepScreenOn = null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('io.legado.app/brightness'),
      (call) async {
        if (call.method == 'setKeepScreenOn') {
          keepScreenOnCalls.add(call.arguments as bool);
        } else if (call.method == 'isBrightnessSupported') {
          return true;
        } else if (call.method == 'isAutoBrightness') {
          return false;
        } else if (call.method == 'getSystemBrightness') {
          return 128;
        }
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('io.legado.app/brightness'), null);
    });
  });

  group('P1-1 亮度横条经 ReaderMenuPanel 生产路径（模式=1）', () {
    /// 展开阅读菜单（点击正文中央 → toggleControls）
    Future<void> openMenu(WidgetTester tester) async {
      final size = tester.getSize(find.byType(ReaderScreen));
      final origin = tester.getTopLeft(find.byType(ReaderScreen));
      await tester.tapAt(origin + Offset(size.width * 0.5, size.height * 0.5));
      await tester.pumpAndSettle();
    }

    testWidgets("模式 '1'：菜单底部面板渲染亮度横条（亮度图标 + 双滑条）",
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'readBrightnessMode': '1',
      });
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(container.read(readerAdvConfigProvider)?.readBrightnessMode, '1');

      await openMenu(tester);

      expect(find.byIcon(Icons.brightness_auto_outlined), findsOneWidget,
          reason: '亮度横条挂进菜单底部面板（ReaderBottomBar 已废，生产唯一路径）');
      // 亮度滑条 + 章节进度滑条
      expect(find.byType(Slider), findsNWidgets(2));
    });

    testWidgets("模式 '0'：菜单面板无亮度横条（仅进度滑条）", (tester) async {
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      await openMenu(tester);

      expect(find.byIcon(Icons.brightness_auto_outlined), findsNothing);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets("模式 '2'：菜单面板渲染竖条而非横条", (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'readBrightnessMode': '2',
        'readBrightnessVwPos': '1',
      });
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      await openMenu(tester);

      // 竖条自动亮度钮；无横向亮度行
      expect(find.byTooltip('自动亮度'), findsOneWidget);
      expect(find.byType(RotatedBox), findsOneWidget);
      // 滑条 = 章节进度 1 条 + 竖条内亮度 1 条（无横条行）
      expect(find.byType(Slider), findsNWidgets(2));
    });
  });

  group('P1-2/P2-4 keepLight 定时器（真 ReaderScreen 生产路径）', () {
    testWidgets('进入 keepLight=60 → [true]，60s 到点 → [true, false]',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'keep_light': 60,
      });
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(keepScreenOnCalls, [true], reason: '进入阅读器置常亮 flag');

      // 假时钟推进 60s（Timer 到点清 flag）
      await tester.pump(const Duration(seconds: 60));
      expect(keepScreenOnCalls, [true, false],
          reason: 'keepLight>0 档到点清 flag（对齐参考版 screenOffRunnable）');
    });

    testWidgets('翻页后计时重置：59s 翻页 → 60s 不清、再 60s 清',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'keep_light': 60,
      });
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);

      // 59s（未到点）点击正文翻页 → 计时重置
      await tester.pump(const Duration(seconds: 59));
      final size = tester.getSize(find.byType(ReaderScreen));
      final origin = tester.getTopLeft(find.byType(ReaderScreen));
      await tester.tapAt(
          origin + Offset(size.width * 0.85, size.height * 0.5));
      await tester.pumpAndSettle();

      // 重置后再 60s 才到点：从进入算 60s（未到重置后时点）不清
      await tester.pump(const Duration(seconds: 1));
      expect(keepScreenOnCalls, [true],
          reason: '交互重挂后 60s 计时重新起算，原到点被推迟');

      // 重置后满 60s：清 flag
      await tester.pump(const Duration(seconds: 60));
      expect(keepScreenOnCalls, [true, false]);
    });

    testWidgets('keepLight=-1 常亮：[true] 且 10 分钟不自动清', (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'keep_light': -1,
      });
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(keepScreenOnCalls, [true]);

      await tester.pump(const Duration(minutes: 10));
      expect(keepScreenOnCalls, [true],
          reason: '-1 恒亮档不设自动清定时器');
    });

    testWidgets('keepLight=0：进入不发 true（交还系统策略）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'keep_light': 0,
      });
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(keepScreenOnCalls, isEmpty,
          reason: '默认档初始未置 flag，无需下发 false（幂等去重）');
    });

    testWidgets('改值 60→0：[true, false] 即时交还系统', (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'keep_light': 60,
      });
      final container = await _pumpReader(tester);
      addTearDown(container.dispose);
      expect(keepScreenOnCalls, [true]);

      // 改值生效链路（界面 Sheet / 独立阅读设置页同款）：save +
      // 推 provider → ReaderScreen 对 keepLight 的 listen 即时应用
      //（对齐参考版 MoreConfigDialog onSharedPreferenceChanged 即时语义）
      final cfg = (container.read(readerAdvConfigProvider)!).copy()
        ..keepLight = 0;
      await cfg.save();
      container.read(readerAdvConfigProvider.notifier).apply(cfg);
      await tester.pumpAndSettle();

      expect(keepScreenOnCalls, [true, false],
          reason: '改 0 档经 provider listen 即时清 flag（取消定时器）');
    });

    testWidgets('dispose：-1 常亮态退出追加 false（恢复系统息屏）',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'enableReadRecord': false,
        'keep_light': -1,
      });
      await _pumpReader(tester);
      expect(keepScreenOnCalls, [true]);

      // 退出阅读器（已入架书直接退出）
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);

      expect(keepScreenOnCalls, [true, false],
          reason: 'dispose 拆除：清 flag 恢复系统息屏策略');
    });
  });
}
