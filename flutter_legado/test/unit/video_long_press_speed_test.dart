// [V-B4] 长按倍速（对齐原版 VideoPlayer.kt / VideoPlay.kt）
//
// 原版依据（app/src/main/java/io/legado/app/help/gsyVideo/VideoPlayer.kt）：
// - :108-115 onLongPress：仅 CURRENT_STATE_PLAYING 生效 →
//   speed = VideoPlay.longPressSpeed / 10.0f → setVideoSpeed(speed) +
//   showOverlayTip("${speed}倍速播放中") + isLongPressSpeed = true
// - :124-133 touchSurfaceUp：isLongPressSpeed → 恢复 playSpeed +
//   showOverlayTip() 隐藏 + resolveDanmakuStart(当前位置)
// - :135-141 setVideoSpeed：弹幕滚动速度因子 danmakuSpeed-(speed-1)/6 联动
// VideoPlay.kt:84-88 longPressSpeed 默认 30（即 3.0 倍）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/video_danmaku_item.dart';
import 'package:flutter_legado/src/utils/video_play_utils.dart';
import 'package:flutter_legado/src/widgets/video_danmaku_layer.dart';
import 'package:flutter_legado/src/widgets/video_long_press_speed.dart';
import 'package:flutter_legado/src/widgets/video_settings_dialog.dart';

const Key _areaKey = Key('long-press-area');

Widget _host({
  required bool enabled,
  required VoidCallback onSpeedUp,
  required VoidCallback onRestore,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 100,
          child: VideoLongPressSpeedArea(
            key: _areaKey,
            enabled: enabled,
            onSpeedUp: onSpeedUp,
            onRestore: onRestore,
            child: Container(color: Colors.black),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('生效倍速（对齐 VideoPlayer.kt:110-112 临时提速）', () {
    test('长按期间 = longPressSpeed，非长按 = 会话倍速', () {
      expect(
        effectiveVideoSpeed(
          sessionSpeed: 1.25,
          longPressActive: true,
          longPressSpeed: 3.0,
        ),
        3.0,
      );
      expect(
        effectiveVideoSpeed(
          sessionSpeed: 1.25,
          longPressActive: false,
          longPressSpeed: 3.0,
        ),
        1.25,
      );
    });

    test('设置默认 30 → 3.0 倍（VideoPlay.kt:84-88 / pressSpeedFactor）', () {
      expect(VideoPlaySettings().longPressSpeed, 30);
      expect(VideoPlaySettings().pressSpeedFactor, 3.0);
    });

    test('tip 文案「X倍速播放中」（对齐 VideoPlayer.kt:112）', () {
      expect(longPressSpeedTipLabel(3.0), '3.0倍速播放中');
      expect(longPressSpeedTipLabel(2.5), '2.5倍速播放中');
    });

    test('弹幕层倍速联动：长按期间滚动弹幕时长缩短（VideoPlayer.kt:135-141）', () {
      const item = VideoDanmakuItem(
        timeMs: 0,
        type: DanmakuType.scrollR2L,
        textSizeRaw: 25,
        color: -1,
        text: 'x',
      );
      final normal = DanmakuLayoutEngine.durationMsOf(
        item,
        effectiveVideoSpeed(
          sessionSpeed: 1.0,
          longPressActive: false,
          longPressSpeed: 3.0,
        ),
      );
      final pressed = DanmakuLayoutEngine.durationMsOf(
        item,
        effectiveVideoSpeed(
          sessionSpeed: 1.0,
          longPressActive: true,
          longPressSpeed: 3.0,
        ),
      );
      expect(pressed, lessThan(normal));
    });
  });

  group('VideoLongPressSpeedArea 手势接线', () {
    testWidgets('播放中长按 → 提速一次；松手 → 恢复一次', (tester) async {
      var speedUp = 0;
      var restore = 0;
      await tester.pumpWidget(_host(
        enabled: true,
        onSpeedUp: () => speedUp++,
        onRestore: () => restore++,
      ));

      final gesture =
          await tester.startGesture(tester.getCenter(find.byKey(_areaKey)));
      await tester.pump(const Duration(milliseconds: 700));
      expect(speedUp, 1, reason: '长按应触发临时提速');
      expect(restore, 0, reason: '按住期间不恢复');

      await gesture.up();
      await tester.pump();
      expect(restore, 1, reason: '松手应恢复会话倍速');
      expect(speedUp, 1, reason: '同一手势不重复提速');
    });

    testWidgets('非播放中（enabled=false）长按不触发提速', (tester) async {
      var speedUp = 0;
      var restore = 0;
      await tester.pumpWidget(_host(
        enabled: false,
        onSpeedUp: () => speedUp++,
        onRestore: () => restore++,
      ));

      final gesture =
          await tester.startGesture(tester.getCenter(find.byKey(_areaKey)));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up();
      await tester.pump();
      expect(speedUp, 0);
      expect(restore, 0);
    });

    testWidgets('未长按的点击/轻触不触发恢复', (tester) async {
      var speedUp = 0;
      var restore = 0;
      await tester.pumpWidget(_host(
        enabled: true,
        onSpeedUp: () => speedUp++,
        onRestore: () => restore++,
      ));

      await tester.tap(find.byKey(_areaKey));
      await tester.pump();
      expect(speedUp, 0);
      expect(restore, 0);
    });
  });
}
