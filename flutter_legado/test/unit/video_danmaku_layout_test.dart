// V-B2 视频弹幕布局引擎定向测试（契约 §2.50 渲染侧）
//
// 覆盖自绘弹幕引擎的对齐语义：
// 1. 四类弹幕布局：右→左滚动（x 递减）、左→右滚动（x 递增）、
//    顶部/底部固定（水平居中、分列上下）
// 2. 原版渲染配置：R2L 最多 5 行；滚动时长 3800ms × 速度因子
//    （VideoPlayer.kt:287/:296，VideoPlay.kt:96 danmakuSpeed=1.2）
// 3. 字号 density 换算（BiliDanmukuParser.kt:104）
//
// [V-B2 | 2026-10-05] 新增。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/widgets/video_danmaku_layer.dart';

VideoDanmakuItem _item(
  int type, {
  int timeMs = 0,
  String text = '弹幕',
  double sizeRaw = 25,
  int color = -1,
}) {
  return VideoDanmakuItem(
    timeMs: timeMs,
    type: type,
    textSizeRaw: sizeRaw,
    color: color,
    text: text,
  );
}

DanmakuLayoutEngine _engine(List<VideoDanmakuItem> items) {
  return DanmakuLayoutEngine(items: items)
    ..measureText = (item, fontSize) => item.text.length * fontSize;
}

void main() {
  const size = Size(400, 300);

  group('DanmakuLayoutEngine 尺寸口径', () {
    test('字号换算：原版 (density-0.6) 且物理像素 → Flutter 逻辑像素', () {
      // 原版：textSize * (dpr - 0.6) 物理像素；逻辑像素 = ÷ dpr
      expect(
        DanmakuLayoutEngine.fontSizeOf(25, 3.0),
        closeTo(25 * (3.0 - 0.6) / 3.0, 0.001),
      );
      expect(
        DanmakuLayoutEngine.fontSizeOf(25, 1.0),
        closeTo(25 * (1.0 - 0.6) / 1.0, 0.001),
      );
    });

    test('滚动时长：3800ms × (1.2 - (speed-1)/6)，固定弹幕恒 3800ms', () {
      final scroll = _item(DanmakuType.scrollR2L);
      expect(DanmakuLayoutEngine.durationMsOf(scroll, 1.0), closeTo(4560, 0.001));
      expect(
        DanmakuLayoutEngine.durationMsOf(scroll, 1.5),
        closeTo(3800 * (1.2 - 0.5 / 6), 0.001),
      );
      expect(
        DanmakuLayoutEngine.durationMsOf(_item(DanmakuType.fixTop), 2.5),
        3800,
      );
      expect(
        DanmakuLayoutEngine.durationMsOf(_item(DanmakuType.fixBottom), 0.5),
        3800,
      );
    });
  });

  group('四类弹幕布局', () {
    test('右→左滚动：右缘入场 → 左外出场，x 单调递减', () {
      final engine = _engine([_item(DanmakuType.scrollR2L, text: 'AAAA')])
        ..measureText = (item, fontSize) => 40;
      final at0 = engine
          .placementsAt(positionMs: 0, size: size, dpr: 3, playbackSpeed: 1)
          .single;
      expect(at0.x, closeTo(size.width, 0.01), reason: '入场时贴右缘');

      final mid = engine
          .placementsAt(positionMs: 600, size: size, dpr: 3, playbackSpeed: 1)
          .single;
      expect(mid.x, lessThan(at0.x), reason: '随时间向左移动');
      expect(mid.y, closeTo(at0.y, 0.01));

      final atEnd = engine
          .placementsAt(positionMs: 4560, size: size, dpr: 3, playbackSpeed: 1)
          .single;
      expect(atEnd.x, closeTo(-40, 0.01), reason: '尾部离场时文本完全移出左缘');
    });

    test('左→右滚动：左外入场 → 右缘出场，x 单调递增', () {
      final engine = _engine([_item(DanmakuType.scrollL2R, text: 'AAAA')])
        ..measureText = (item, fontSize) => 40;
      final at0 = engine
          .placementsAt(positionMs: 0, size: size, dpr: 3, playbackSpeed: 1)
          .single;
      expect(at0.x, closeTo(-40, 0.01), reason: '入场时贴左外缘');

      final mid = engine
          .placementsAt(positionMs: 600, size: size, dpr: 3, playbackSpeed: 1)
          .single;
      expect(mid.x, greaterThan(at0.x), reason: '随时间向右移动');

      final atEnd = engine
          .placementsAt(positionMs: 4560, size: size, dpr: 3, playbackSpeed: 1)
          .single;
      expect(atEnd.x, closeTo(size.width, 0.01), reason: '出场时贴右缘');
    });

    test('顶部固定：水平居中、从顶部起行；底部固定：贴近底缘', () {
      final engine = _engine([
        _item(DanmakuType.fixTop, text: 'AAAA'),
        _item(DanmakuType.fixBottom, text: 'AAAA'),
      ])..measureText = (item, fontSize) => 40;
      final placements = engine.placementsAt(
        positionMs: 100,
        size: size,
        dpr: 3,
        playbackSpeed: 1,
      );
      expect(placements.length, 2);
      final top = placements.firstWhere((p) => p.item.type == DanmakuType.fixTop);
      final bottom =
          placements.firstWhere((p) => p.item.type == DanmakuType.fixBottom);
      expect(top.x, closeTo((size.width - 40) / 2, 0.01));
      expect(bottom.x, closeTo((size.width - 40) / 2, 0.01));
      expect(top.y, 0);
      expect(bottom.y, greaterThan(size.height / 2));
      expect(bottom.y + 27 * 1, lessThanOrEqualTo(size.height + 0.01));
    });

    test('未到时刻不出现、结束后消失', () {
      final engine = _engine([_item(DanmakuType.scrollR2L, timeMs: 1000)]);
      expect(
        engine.placementsAt(
          positionMs: 999,
          size: size,
          dpr: 3,
          playbackSpeed: 1,
        ),
        isEmpty,
        reason: '未到时刻不绘制',
      );
      expect(
        engine.placementsAt(
          positionMs: 1000,
          size: size,
          dpr: 3,
          playbackSpeed: 1,
        ).length,
        1,
      );
      expect(
        engine.placementsAt(
          positionMs: 7000,
          size: size,
          dpr: 3,
          playbackSpeed: 1,
        ),
        isEmpty,
        reason: '超出时长后消失',
      );
    });
  });

  group('原版渲染配置对齐', () {
    test('右→左滚动最多 5 行：第 6 条丢弃', () {
      final items = [
        for (var i = 0; i < 6; i++)
          _item(DanmakuType.scrollR2L, timeMs: 0, text: 'AAAA'),
      ];
      final engine = _engine(items);
      final placements = engine.placementsAt(
        positionMs: 0,
        size: size,
        dpr: 3,
        playbackSpeed: 1,
      );
      expect(placements.length, 5, reason: '原版 maxLinesPair[R2L]=5');
      expect(placements.map((p) => p.lane).toSet(), {0, 1, 2, 3, 4});
    });

    test('左→右滚动不受 5 行限制（原版未显式配置该类型）', () {
      final items = [
        for (var i = 0; i < 6; i++)
          _item(DanmakuType.scrollL2R, timeMs: 0, text: 'AAAA'),
      ];
      final engine = _engine(items);
      final placements = engine.placementsAt(
        positionMs: 0,
        size: size,
        dpr: 3,
        playbackSpeed: 1,
      );
      expect(placements.length, 6);
    });

    test('同轨后续弹幕在前车尾部完全入场后才占用该轨', () {
      // 5 行跑满后，第 6 条（短文本）需等某行前车尾部入场
      final items = [
        for (var i = 0; i < 5; i++)
          _item(DanmakuType.scrollR2L, timeMs: 0, text: 'AAAAAAAA'),
        _item(DanmakuType.scrollR2L, timeMs: 10, text: '短'),
      ];
      final engine = _engine(items);
      final atStart = engine.placementsAt(
        positionMs: 10,
        size: size,
        dpr: 3,
        playbackSpeed: 1,
      );
      expect(atStart.length, 5, reason: '第 6 条起始时 5 行均被占用 → 丢弃');
    });

    test('异宽同轨防追尾：长后车按旧判据获准入轨但必然重叠（P1-3）', () {
      // 前车宽 40 @0ms；后车宽 160 @500ms。
      // 旧判据仅要求后车晚于前车尾部入场 4560×40/440≈414.5ms → 500ms 放行同轨；
      // 滚动速度与宽度成正比（后车更快）→ 巡航期追尾重叠。
      final items = [
        _item(DanmakuType.scrollR2L, timeMs: 0, text: 'AA'), // 宽 40
        _item(DanmakuType.scrollR2L, timeMs: 500, text: 'AAAAAAAA'), // 宽 160
      ];
      final engine = _engine(items);
      final at1000 = engine.placementsAt(
        positionMs: 1000,
        size: size,
        dpr: 3,
        playbackSpeed: 1,
      );
      expect(at1000.length, 2);
      final front = at1000.firstWhere((p) => p.item.text == 'AA');
      final rear = at1000.firstWhere((p) => p.item.text == 'AAAAAAAA');
      expect(
        rear.lane,
        isNot(front.lane),
        reason: '长后车若与前车同轨必然追尾（新判据：入场间隔 ≥ dur×max(W)/'
            '(W+max(W)) = 4560×160/560 ≈ 1302.9ms > 500ms）',
      );

      // 几何复核：整个共存窗口内同轨矩形不得相交
      for (var t = 500; t <= 4560; t += 100) {
        final frame = engine.placementsAt(
          positionMs: t,
          size: size,
          dpr: 3,
          playbackSpeed: 1,
        );
        for (var i = 0; i < frame.length; i++) {
          for (var j = i + 1; j < frame.length; j++) {
            final p = frame[i];
            final q = frame[j];
            if (p.lane != q.lane) continue;
            final pw = p.item.text.length * p.fontSize;
            final qw = q.item.text.length * q.fontSize;
            final overlapX = p.x < q.x + qw && q.x < p.x + pw;
            expect(
              overlapX,
              isFalse,
              reason: 't=${t}ms 同轨横向重叠：${p.item.text} vs ${q.item.text}',
            );
          }
        }
      }
    });
  });

  group('行分配状态有界性（P0-2）', () {
    test('行分配/宽度缓存随扫描窗口前移裁剪，长视频不无界增长', () {
      // 200 条、每 1s 一条、单条时长 4560ms；以 500ms 步进推进 200s。
      // 步进 < 700ms 不触发 seek 重排，旧实现每条首次出现即永久驻留；
      // 新实现随 _scanStart 前移同步 prune，尺寸应恒等于活跃窗口（约 5 条）。
      final items = [
        for (var i = 0; i < 200; i++)
          _item(DanmakuType.scrollR2L, timeMs: i * 1000, text: 'AAAA'),
      ];
      final engine = _engine(items);
      for (var t = 0; t <= 200000; t += 500) {
        engine.placementsAt(
          positionMs: t,
          size: size,
          dpr: 3,
          playbackSpeed: 1,
        );
      }
      expect(
        engine.debugLaneCacheSize,
        lessThanOrEqualTo(20),
        reason: '行分配缓存只保留活跃窗口，不得随历史总量增长',
      );
      expect(
        engine.debugWidthCacheSize,
        lessThanOrEqualTo(20),
        reason: '宽度缓存同样随窗口裁剪',
      );
    });
  });
}
