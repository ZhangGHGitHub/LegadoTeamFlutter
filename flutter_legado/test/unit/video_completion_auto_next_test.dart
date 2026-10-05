// [V-B4] 自然播完自动连播判定
//
// 原版依据（app/src/main/java/io/legado/app/help/gsyVideo/VideoPlayer.kt）：
// - :185-188 onAutoCompletion（自然播完）→ VideoPlay.upDurIndex(1, this)
// - :190-193 onCompletion（用户主动结束/错误）→ 仅 releaseDanmaku，不连播
// VideoPlay.kt:474-490 upDurIndex：下一集 index 越界 → toast「已播放完」，
// 负向 → 「已到开头」；本侧仅实现自然播完正向推进。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/video_play_utils.dart';

void main() {
  group('nextPlayableChapterIndex（对齐 upDurIndex(1) 的集内推进/越界）', () {
    test('普通下一集', () {
      expect(nextPlayableChapterIndex([false, false, false], 0), 1);
      expect(nextPlayableChapterIndex([false, false, false], 1), 2);
    });

    test('跳过卷标题（对齐 episodes 列表不含卷标题）', () {
      expect(nextPlayableChapterIndex([false, true, true, false], 0), 3);
      expect(nextPlayableChapterIndex([false, false, true], 1), isNull);
    });

    test('越界 → null（调用方 toast「已播放完」，对齐 upDurIndex 越界分支）', () {
      expect(nextPlayableChapterIndex([false, false], 1), isNull);
      expect(nextPlayableChapterIndex([false, true], 0), isNull);
      expect(nextPlayableChapterIndex([], 0), isNull);
    });
  });

  group('shouldAdvanceOnCompletion（completed 边沿：仅自然播完触发一次）', () {
    test('未完成 → 完成：触发', () {
      expect(
        shouldAdvanceOnCompletion(wasCompleted: false, isCompleted: true),
        isTrue,
      );
    });

    test('completed 持续为真：不重复触发（防同一集多次切集）', () {
      expect(
        shouldAdvanceOnCompletion(wasCompleted: true, isCompleted: true),
        isFalse,
      );
    });

    test('主动停止/播放中/错误（非 completed）：不触发', () {
      expect(
        shouldAdvanceOnCompletion(wasCompleted: false, isCompleted: false),
        isFalse,
      );
      expect(
        shouldAdvanceOnCompletion(wasCompleted: true, isCompleted: false),
        isFalse,
      );
    });

    test('seek 回看后再自然播完：可再次触发', () {
      expect(
        shouldAdvanceOnCompletion(wasCompleted: true, isCompleted: false),
        isFalse,
      );
      expect(
        shouldAdvanceOnCompletion(wasCompleted: false, isCompleted: true),
        isTrue,
      );
    });
  });
}
