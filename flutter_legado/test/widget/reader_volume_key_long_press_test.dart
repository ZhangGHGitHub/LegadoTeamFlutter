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
import 'package:flutter_legado/src/utils/volume_key_page_gate.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';

import '../mocks/mocks.dart';

/// 可推进假时钟（毫秒精度）：让 600ms 节流窗口断言不依赖真实时间
class _FakeClock {
  DateTime _now = DateTime(2026, 11, 1, 12);

  DateTime call() => _now;

  void advance(int milliseconds) {
    _now = _now.add(Duration(milliseconds: milliseconds));
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

    testWidgets('false：快速连点 600ms 内只翻一次，600ms 后可再翻', (tester) async {
      _mockPrefs();
      final clock = _FakeClock();
      final container = await _pumpReader(
        tester,
        gate: VolumeKeyPageGate(clock: clock.call),
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
  });
}
