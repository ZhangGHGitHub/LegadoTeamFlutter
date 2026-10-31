// [批1b-2a | 2026-11-01] 文本阅读器音量键长按语义行为测试 — 全栈工程师
//
// 语义基准：原版 legado-upstream/.../ui/book/read/ReadBookActivity.kt
// volumeKeyPage → handleKeyPage：
// - keyPageOnLongPress=true → 每个 keydown 都翻页（含长按 repeat）；
// - false → 长按 repeat 忽略；短按同方向 600ms 内只翻一次（leading）。
//
// 事件来源：Android 壳把原生 KeyEvent.repeatCount>0 映射为 Flutter
// KeyRepeatEvent（framework hardware_keyboard.dart `_eventFromData`），
// reader_screen._onHardwareKey 以 `event is KeyRepeatEvent` 判定长按。
//
// 覆盖：
// 1. 默认 false：repeat 不翻页；
// 2. true：repeat 逐次翻页；
// 3. false：快速连点 600ms 内只翻一次，600ms 后可再翻；
// 4. volumeKeyPage=false：按键不消费、不翻页；
// 5. 音量键抬起消费但不翻页（对齐原版 onKeyUp volumeKeyPage(NONE)）。
//
// 观测点：ReaderPageViewState.onPageTurnedHaptic（sliderVibrator=true 时
// 每次翻页成功调用；既有 1a 振动测试同款注入范式，避免依赖动画中间态）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/utils/volume_key_page_gate.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';

import '../mocks/mocks.dart';

/// 可推进假单调时钟（毫秒精度）：让 600ms 节流窗口断言不依赖真实时间
class _FakeClock {
  Duration _elapsed = Duration.zero;

  Duration call() => _elapsed;

  void advance(int milliseconds) {
    _elapsed += Duration(milliseconds: milliseconds);
  }
}

const _shelfBook = Book(
  bookUrl: 'https://book.com/volume-key',
  name: '音量键书',
  author: '作者',
  origin: 'https://source-a.com',
  originName: '源A',
);

const _chapters = [
  BookChapter(url: 'https://book.com/volume-key/c1', title: '第一章', index: 0),
  BookChapter(url: 'https://book.com/volume-key/c2', title: '第二章', index: 1),
];

/// 长正文（每章 6000 字）确保每章多页，翻页断言不依赖跨章边界
final _longContent = List.filled(6000, '测').join();

MockRustApi _stubApi() {
  final api = MockRustApi();
  when(() => api.getChapters(any())).thenAnswer((_) async => _chapters);
  when(
    () => api.getChapterContentFull(any(), any()),
  ).thenAnswer((_) async => _longContent);
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

/// 准备偏好：sliderVibrator=true 使翻页成功可经注入点计数
void _mockPrefs({bool keyPageOnLongPress = false, bool volumeKeyPage = true}) {
  SharedPreferences.setMockInitialValues({
    'enableReadRecord': false,
    'sliderVibrator': true,
    'volumeKeyPage': volumeKeyPage,
    'keyPageOnLongPress': keyPageOnLongPress,
  });
}

/// 启动 App（按钮 push 真实 ReaderScreen）+ 开书
///
/// [gate] 可选注入假时钟闸门（600ms 节流断言用）；null 时用生产默认。
Future<ProviderContainer> _pumpReader(
  WidgetTester tester, {
  VolumeKeyPageGate? gate,
}) async {
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
                    builder: (_) => ReaderScreen(volumeKeyPageGate: gate),
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

  final container = ProviderScope.containerOf(
    tester.element(find.byType(ReaderScreen)),
  );
  await container.read(readerNotifierProvider.notifier).openBook(_shelfBook);
  await tester.pumpAndSettle();
  return container;
}

/// 强制推送阅读配置（等价设置页 save + provider 推送）
Future<void> _applyConfig(
  ProviderContainer container, {
  required bool keyPageOnLongPress,
  bool volumeKeyPage = true,
}) async {
  final cfg =
      (container.read(readerAdvConfigProvider) ??
              await ReaderAdvancedConfig.load())
          .copy()
        ..keyPageOnLongPress = keyPageOnLongPress
        ..volumeKeyPage = volumeKeyPage
        ..sliderVibrator = true;
  await cfg.save();
  container.read(readerAdvConfigProvider.notifier).apply(cfg);
}

/// 模拟原生 ReaderKeysBridge 回发音量键事件（Android 路径）
Future<void> _emitNativeVolumeKey(
  WidgetTester tester,
  String direction, {
  bool longPress = false,
}) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'legado/reader_keys',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('volumeKey', <String, Object>{
        'direction': direction,
        'longPress': longPress,
      }),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

/// 记录 Dart → 原生 `setVolumeKeyCapture` 出站调用
///
/// 与漫画 M5 用例同口径：mock 通道出站会拦截入站投递，故「捕获开关
/// 断言」与「原生事件翻页断言」分测试执行。
List<MethodCall> _recordReaderKeyCalls(WidgetTester tester) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('legado/reader_keys'),
    (call) async {
      calls.add(call);
      return true;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('legado/reader_keys'),
      null,
    );
  });
  return calls;
}

List<MethodCall> _captureCalls(List<MethodCall> calls) => calls
    .where((c) => c.method == 'setVolumeKeyCapture')
    .toList(growable: false);

/// 模拟漫画阅读器的捕获生命周期（与 ReaderComicScreen 同语义：
/// 进入 acquire 租约，dispose release），用于验证文本→漫画→返回文本
/// 的 capture 所有权不冲突。
class _FakeComicVolumeKeyRoute extends StatefulWidget {
  const _FakeComicVolumeKeyRoute();

  @override
  State<_FakeComicVolumeKeyRoute> createState() =>
      _FakeComicVolumeKeyRouteState();
}

class _FakeComicVolumeKeyRouteState extends State<_FakeComicVolumeKeyRoute> {
  @override
  void initState() {
    super.initState();
    final bridge = PlatformBridgeService.instance;
    unawaited(bridge.acquireVolumeKeyCapture(this, (_, _) async {}));
  }

  @override
  void dispose() {
    unawaited(PlatformBridgeService.instance.releaseVolumeKeyCapture(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('漫画')));
}

void main() {
  late int turns;

  setUp(() {
    turns = 0;
    ReaderPageViewState.onPageTurnedHaptic = () => turns++;
  });

  tearDown(() {
    ReaderPageViewState.onPageTurnedHaptic = HapticFeedback.selectionClick;
  });

  group('[批1b-2a] 文本阅读器音量键长按语义', () {
    testWidgets('默认 false：长按 repeat 不翻页', (tester) async {
      _mockPrefs();
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: false);
      expect(turns, 0, reason: '基线：未按键不翻页');

      // 仅 repeat（无前置 down）：若未按长按语义忽略，会被当成一次翻页
      final handled = await simulateKeyRepeatEvent(
        LogicalKeyboardKey.audioVolumeDown,
        character: null,
      );
      await tester.pumpAndSettle();

      expect(
        turns,
        0,
        reason:
            'keyPageOnLongPress=false 时长按 repeat 必须忽略（原版 '
            'keyPageDebounce: if (longPress) return）',
      );
      expect(handled, isTrue, reason: '按键仍需消费，避免系统调音量');
    });

    testWidgets('true：长按 repeat 逐次翻页（连续翻页）', (tester) async {
      _mockPrefs(keyPageOnLongPress: true);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);
      expect(turns, 0);

      await simulateKeyRepeatEvent(
        LogicalKeyboardKey.audioVolumeDown,
        character: null,
      );
      await tester.pumpAndSettle();
      expect(turns, 1, reason: 'true 时 repeat 第 1 次翻页');

      await simulateKeyRepeatEvent(
        LogicalKeyboardKey.audioVolumeDown,
        character: null,
      );
      await tester.pumpAndSettle();
      expect(turns, 2, reason: 'true 时 repeat 第 2 次继续翻页');
    });

    testWidgets('[P1 红→绿] 50ms repeat 连续 1s：cover 动画中继续翻页 ≥3', (tester) async {
      _mockPrefs(keyPageOnLongPress: true);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);
      expect(
        container.read(readerNotifierProvider).pageTurnMode,
        PageTurnMode.cover,
        reason: '本用例固定默认 cover 动画路径（动画时长约 300ms）',
      );
      expect(turns, 0);

      // 真实节奏：每 50ms 一次 repeat + pump 50ms，不 pumpAndSettle；
      // 连续 1s（20 次）。修前每次 repeat 触发 _abortSettle，动画永远
      // 无法提交，整段长按只翻 1 页；修后动画中忽略新 repeat，动画完成
      // 后下一次 repeat 再翻，1s 内应至少 3 页。
      for (var i = 0; i < 20; i++) {
        await simulateKeyRepeatEvent(
          LogicalKeyboardKey.audioVolumeDown,
          character: null,
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      // 让最后一次收尾动画完成（仍不 pumpAndSettle，保持帧驱动语义）
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        turns,
        greaterThanOrEqualTo(3),
        reason: '50ms repeat 连续 1s 必须连续翻页（修前只有 1 页）',
      );
    });

    testWidgets('[P1] 手势取消 abort 程序化翻页后仍可继续翻页（Completer 不悬挂）', (tester) async {
      _mockPrefs(keyPageOnLongPress: true);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);

      // 启动一次程序化翻页（动画进行中）
      await simulateKeyRepeatEvent(
        LogicalKeyboardKey.audioVolumeDown,
        character: null,
      );
      await tester.pump(const Duration(milliseconds: 50));

      // 手势按下 → _abortSettle（唯一允许 abort 的路径）→ 取消
      final size = tester.getSize(find.byType(ReaderScreen));
      final origin = tester.getTopLeft(find.byType(ReaderScreen));
      final gesture = await tester.startGesture(
        origin + Offset(size.width * 0.5, size.height * 0.5),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.cancel();
      await tester.pumpAndSettle();

      expect(turns, 0, reason: '被 abort 的翻页不提交');

      // abort 的 Completer 已 settle，控制器未卡在 isSettling：
      // 下一次 repeat 必须能重新启动动画并提交
      await simulateKeyRepeatEvent(
        LogicalKeyboardKey.audioVolumeDown,
        character: null,
      );
      await tester.pumpAndSettle();
      expect(turns, 1, reason: 'abort 后仍可继续翻页（不永久挂起/不卡动画态）');
    });

    testWidgets('false：快速连点 600ms 内只翻一次，600ms 后可再翻', (tester) async {
      _mockPrefs();
      final clock = _FakeClock();
      final container = await _pumpReader(
        tester,
        gate: VolumeKeyPageGate(elapsed: clock.call),
      );
      await _applyConfig(container, keyPageOnLongPress: false);

      // 第 1 次 down：立即翻
      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
      expect(turns, 1, reason: 'leading：第一次立即翻');

      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();

      // 第 2 次 down（<600ms）：被节流
      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
      expect(turns, 1, reason: '600ms 内第二次按键不翻页');

      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();

      // 推进假时钟 700ms（>600ms 节流窗口；不依赖真实时间）
      clock.advance(700);
      await tester.pumpAndSettle();

      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
      expect(turns, 2, reason: '满 600ms 后再按恢复翻页');
    });

    testWidgets('volumeKeyPage=false：按键不消费、不翻页', (tester) async {
      _mockPrefs(volumeKeyPage: false);
      final container = await _pumpReader(tester);
      await _applyConfig(
        container,
        keyPageOnLongPress: true,
        volumeKeyPage: false,
      );

      final handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeDown,
      );
      await tester.pumpAndSettle();

      expect(handled, isFalse, reason: '开关关闭时交还系统（调音量）');
      expect(turns, 0, reason: '开关关闭不翻页');
    });

    testWidgets('音量键抬起消费但不翻页（原版 onKeyUp volumeKeyPage(NONE)）', (tester) async {
      _mockPrefs(keyPageOnLongPress: true);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);

      final handledUp = await simulateKeyUpEvent(
        LogicalKeyboardKey.audioVolumeDown,
      );
      await tester.pumpAndSettle();

      expect(handledUp, isTrue, reason: '语义生效时抬起事件也消费');
      expect(turns, 0, reason: '抬起事件不翻页');
    });

    testWidgets('[P3-2] 阅读菜单展开时音量键交还系统（不翻页/不消费）', (tester) async {
      _mockPrefs(keyPageOnLongPress: true);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);

      container.read(readerNotifierProvider.notifier).toggleControls();
      await tester.pumpAndSettle();
      expect(
        container.read(readerNotifierProvider).showControls,
        isTrue,
        reason: '菜单已展开',
      );

      final handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeDown,
      );
      await tester.pumpAndSettle();
      expect(
        handled,
        isFalse,
        reason: '对齐原版 menuLayoutIsVisible → super.onKeyDown（交还系统）',
      );
      expect(turns, 0, reason: '菜单展开不翻页');

      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
    });

    testWidgets('[P3-2] 目录/设置等子路由压栈时 handler 不生效', (tester) async {
      _mockPrefs(keyPageOnLongPress: true);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      // push 的 Future 在路由 pop 时才完成，测试内不 await（否则挂起）
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Center(child: Text('子路由'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('子路由'), findsOneWidget);

      final handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeDown,
      );
      await tester.pumpAndSettle();
      expect(
        handled,
        isFalse,
        reason: '阅读器非当前路由（ModalRoute.isCurrent=false），交还系统',
      );
      expect(turns, 0, reason: '子路由压栈时不翻页');

      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
    });

    testWidgets('[P3-4] dispose 时 reset 节流闸门（重进首键不被节流）', (tester) async {
      _mockPrefs();
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);
      final container = await _pumpReader(tester, gate: gate);
      await _applyConfig(container, keyPageOnLongPress: false);

      // 第一次翻页占住 600ms 节流窗口
      await simulateKeyDownEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
      expect(turns, 1);
      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();

      // 未推进时钟，闸门仍处于节流窗口
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isFalse,
        reason: '节流窗口内（600ms 未到）应拒绝',
      );

      // 退出阅读器 → dispose 调 reset
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing, reason: '阅读器已销毁');

      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isTrue,
        reason: 'dispose 必须 reset 闸门，重进阅读器首键立即翻',
      );
    });
  });

  group('[设备验收 P1] Android 文本阅读器原生音量键捕获', () {
    setUp(() {
      PlatformBridgeService.instance.volumeKeyCaptureOverride = true;
    });

    tearDown(() {
      PlatformBridgeService.instance.volumeKeyCaptureOverride = null;
    });

    testWidgets('进入 → capture true 仅一次；dispose → false', (tester) async {
      _mockPrefs();
      final calls = _recordReaderKeyCalls(tester);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: false);

      final captures = _captureCalls(calls);
      expect(captures, isNotEmpty, reason: '进入阅读器应开启原生捕获');
      expect(
        captures.where((c) => c.arguments == true).length,
        1,
        reason: '首帧/配置加载/openBook 多次同步不得重复 enable',
      );
      expect(captures.last.arguments, isTrue);

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing, reason: '阅读器已销毁');

      final afterDispose = _captureCalls(calls);
      expect(
        afterDispose.where((c) => c.arguments == false).length,
        1,
        reason: 'dispose 必须关闭捕获且只关一次',
      );
      expect(afterDispose.last.arguments, isFalse);
    });

    testWidgets('原生 Map 事件翻页：短按翻页、长按按 keyPageOnLongPress', (tester) async {
      _mockPrefs();
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: false);

      // 默认 false：长按 repeat 忽略（原生事件直达 Dart gate）
      await _emitNativeVolumeKey(tester, 'down', longPress: true);
      expect(turns, 0, reason: 'keyPageOnLongPress=false 忽略长按 repeat');

      // 短按：翻一页
      await _emitNativeVolumeKey(tester, 'down', longPress: false);
      expect(turns, 1, reason: '原生短按应翻页（原生捕获闭环）');

      // 打开长按连翻后：repeat 逐次翻页
      await _applyConfig(container, keyPageOnLongPress: true);
      await _emitNativeVolumeKey(tester, 'down', longPress: true);
      expect(turns, 2, reason: 'keyPageOnLongPress=true 原生 repeat 翻页');
    });

    testWidgets('Android 不注册 HardwareKeyboard handler（无双触发）', (tester) async {
      _mockPrefs();
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);

      final handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeDown,
      );
      await tester.pumpAndSettle();
      expect(
        handled,
        isFalse,
        reason: 'Android 走原生捕获，HardwareKeyboard handler 不应注册',
      );
      expect(turns, 0, reason: '键盘事件不翻页（防原生+Dart 双翻页）');

      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();

      // 原生事件仍可正常翻页
      await _emitNativeVolumeKey(tester, 'down', longPress: false);
      expect(turns, 1);
    });

    testWidgets('菜单展开 → capture false；收起 → true（按键交还系统）', (tester) async {
      _mockPrefs();
      final calls = _recordReaderKeyCalls(tester);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);
      expect(
        _captureCalls(calls).where((c) => c.arguments == true).length,
        1,
        reason: '进入阅读器已开启一次',
      );

      container.read(readerNotifierProvider.notifier).toggleControls();
      await tester.pumpAndSettle();
      expect(
        _captureCalls(calls).last.arguments,
        isFalse,
        reason: '菜单展开必须关闭捕获，音量键交还系统',
      );

      container.read(readerNotifierProvider.notifier).toggleControls();
      await tester.pumpAndSettle();
      expect(
        _captureCalls(calls).where((c) => c.arguments == true).length,
        2,
        reason: '菜单收起重新开启（一次）',
      );
      expect(_captureCalls(calls).last.arguments, isTrue);
    });

    testWidgets('子路由压栈 → capture false；返回 → true', (tester) async {
      _mockPrefs();
      final calls = _recordReaderKeyCalls(tester);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Center(child: Text('目录'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('目录'), findsOneWidget);
      expect(
        _captureCalls(calls).last.arguments,
        isFalse,
        reason: '目录/设置等子路由压栈时交还系统音量',
      );

      navigator.pop();
      await tester.pumpAndSettle();
      expect(
        _captureCalls(calls).last.arguments,
        isTrue,
        reason: '返回阅读器恢复原生捕获',
      );
    });

    testWidgets('volumeKeyPage=false：最终关闭捕获', (tester) async {
      _mockPrefs(volumeKeyPage: false);
      final calls = _recordReaderKeyCalls(tester);
      final container = await _pumpReader(tester);
      await _applyConfig(
        container,
        keyPageOnLongPress: false,
        volumeKeyPage: false,
      );

      expect(
        _captureCalls(calls).last.arguments,
        isFalse,
        reason: '开关关闭时不得拦截系统音量键',
      );
    });

    testWidgets('桌面（未启用原生捕获）：HardwareKeyboard 仍翻页', (tester) async {
      // 本组 setUp 默认模拟 Android；此用例显式回桌面
      PlatformBridgeService.instance.volumeKeyCaptureOverride = null;
      _mockPrefs();
      final calls = _recordReaderKeyCalls(tester);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);

      expect(_captureCalls(calls), isEmpty, reason: '桌面不调用原生捕获通道');

      final handled = await simulateKeyDownEvent(
        LogicalKeyboardKey.audioVolumeDown,
      );
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(turns, 1, reason: '桌面保留 HardwareKeyboard 音量键路径');

      await simulateKeyUpEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
    });

    testWidgets('切书：先关闭捕获，新书落定后恢复', (tester) async {
      _mockPrefs();
      final calls = _recordReaderKeyCalls(tester);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);
      expect(_captureCalls(calls).where((c) => c.arguments == true).length, 1);

      final other = _shelfBook.copyWith(
        bookUrl: 'https://book.com/volume-key-2',
        name: '音量键书2',
      );
      await container.read(readerNotifierProvider.notifier).openBook(other);
      await tester.pumpAndSettle();

      final seq = _captureCalls(calls).map((c) => c.arguments).toList();
      expect(seq, contains(false), reason: '切书瞬间交还系统音量');
      expect(seq.last, isTrue, reason: '新书落定后恢复原生捕获');
    });

    testWidgets('漫画阅读器压栈/退出不冲突：文本捕获最终恢复', (tester) async {
      _mockPrefs();
      final calls = _recordReaderKeyCalls(tester);
      final container = await _pumpReader(tester);
      await _applyConfig(container, keyPageOnLongPress: true);
      expect(_captureCalls(calls).where((c) => c.arguments == true).length, 1);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const _FakeComicVolumeKeyRoute(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('漫画'), findsOneWidget);
      // 漫画是当前捕获方：文本 didPushNext 不得把漫画的 capture 关掉
      expect(
        _captureCalls(calls).last.arguments,
        isTrue,
        reason: '漫画路径捕获不被下层文本阅读器关闭',
      );

      navigator.pop();
      await tester.pumpAndSettle();
      // 漫画 dispose 的 false 之后，文本返回本页必须恢复捕获
      expect(
        _captureCalls(calls).last.arguments,
        isTrue,
        reason: '漫画退出后文本阅读器恢复原生捕获（不被上层收尾覆盖）',
      );
    });
  });
}
