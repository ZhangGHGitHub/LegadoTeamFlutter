// [批1b-2a | 2026-11-01] 音量键翻页语义闸门单测 — 全栈工程师
//
// 语义基准：原版 legado-upstream/.../ReadBookActivity.kt
// volumeKeyPage → handleKeyPage → keyPageDebounce：
// - keyPageOnLongPress=true：每个 keydown 都翻页（含 repeat）；
// - false：longPress repeat 直接忽略；同方向 600ms 内只翻一次
//   （Debounce wait=maxWait=600、leading=true、trailing=false）。
//
// 覆盖：
// 1. 开关 true：长按 repeat / 短按均翻页；
// 2. 开关 false：长按 repeat 忽略；
// 3. 开关 false：首次立即翻，599ms 内再按忽略，600ms 后可再翻；
// 4. 方向分桶（next/prev 各自 600ms，对齐原版两个 Debounce 实例）；
// 5. 被忽略的长按不延长节流窗口；reset 后可立即翻。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/volume_key_page_gate.dart';

/// 可推进的假单调时钟（毫秒精度，避免依赖真实时间导致测试抖动）
class _FakeClock {
  Duration _elapsed = Duration.zero;

  Duration call() => _elapsed;

  void advance(int milliseconds) {
    _elapsed += Duration(milliseconds: milliseconds);
  }
}

void main() {
  group('VolumeKeyPageGate keyPageOnLongPress=true', () {
    test('长按 repeat 与短按都翻页（每个 keydown 一页，无节流）', () {
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);

      for (var i = 0; i < 3; i++) {
        expect(
          gate.shouldTurnPage(
            direction: 'down',
            longPress: true,
            keyPageOnLongPress: true,
          ),
          isTrue,
          reason: '第 ${i + 1} 次长按 repeat 应翻页（对齐原版 keyPage）',
        );
      }
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: true,
        ),
        isTrue,
        reason: '短按同样翻页',
      );
    });
  });

  group('VolumeKeyPageGate keyPageOnLongPress=false', () {
    test('长按 repeat 直接忽略（不翻页）', () {
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);

      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: true,
          keyPageOnLongPress: false,
        ),
        isFalse,
        reason: '对齐原版 keyPageDebounce: if (longPress) return',
      );
      clock.advance(5000);
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: true,
          keyPageOnLongPress: false,
        ),
        isFalse,
        reason: '时间过去多久都不翻（长按整体忽略）',
      );
    });

    test('首次立即翻；599ms 内再按忽略；600ms 后可再翻', () {
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);

      bool press() => gate.shouldTurnPage(
        direction: 'down',
        longPress: false,
        keyPageOnLongPress: false,
      );

      expect(press(), isTrue, reason: 'leading：第一次立即翻');
      clock.advance(100);
      expect(press(), isFalse, reason: '100ms 内连点忽略');
      clock.advance(499); // 累计 599ms
      expect(press(), isFalse, reason: '599ms 内仍忽略');
      clock.advance(1); // 累计 600ms
      expect(press(), isTrue, reason: '满 600ms 允许再翻（>= 阈值）');
      clock.advance(600);
      expect(press(), isTrue, reason: '稳定 600ms 间隔可持续翻页');
    });

    test('快速连点 600ms 窗口内只翻一次', () {
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);
      var pages = 0;
      for (var i = 0; i < 6; i++) {
        if (gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        )) {
          pages++;
        }
        clock.advance(100);
      }
      expect(pages, 1, reason: '6 次 100ms 间隔连点只翻 1 页（600ms 节流）');
    });

    test('方向分桶：next 节流不影响 prev（对齐原版两个 Debounce）', () {
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);

      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isTrue,
      );
      expect(
        gate.shouldTurnPage(
          direction: 'up',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isTrue,
        reason: '反方向有独立节流器，可立即翻',
      );
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isFalse,
      );
      expect(
        gate.shouldTurnPage(
          direction: 'up',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isFalse,
      );
    });

    test('被忽略的长按不延长节流窗口（原版 longPress 提前 return）', () {
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);

      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isTrue,
      );
      clock.advance(500);
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: true,
          keyPageOnLongPress: false,
        ),
        isFalse,
        reason: '长按忽略',
      );
      clock.advance(100); // 距上次翻页满 600ms
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isTrue,
        reason: '长按不触碰节流时间戳，短按按原窗口恢复',
      );
    });

    test('reset 清空节流状态（退出/切书后首次按键立即翻）', () {
      final clock = _FakeClock();
      final gate = VolumeKeyPageGate(elapsed: clock.call);

      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isTrue,
      );
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isFalse,
      );
      gate.reset();
      expect(
        gate.shouldTurnPage(
          direction: 'down',
          longPress: false,
          keyPageOnLongPress: false,
        ),
        isTrue,
        reason: 'reset 后不再受上次翻页时间约束',
      );
    });
  });
}
