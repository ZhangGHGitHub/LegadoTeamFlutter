// [批4a] 九宫格动作分发测试（回调计数，覆盖全部 14 动作 + none）
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/reader_tap_action.dart';
import 'package:flutter_legado/src/widgets/reader/reader_action_helpers.dart';

void main() {
  test('朗读暂停/继续：playing 暂停、paused 继续、idle 不启动', () {
    final calls = <String>[];
    void run({
      required bool isPlaying,
      required bool isIdle,
    }) {
      calls.clear();
      toggleReaderReadAloud(
        isPlaying: isPlaying,
        isIdle: isIdle,
        pause: () => calls.add('pause'),
        resume: () => calls.add('resume'),
      );
    }

    run(isPlaying: true, isIdle: false);
    expect(calls, ['pause']);
    run(isPlaying: false, isIdle: false);
    expect(calls, ['resume']);
    run(isPlaying: false, isIdle: true);
    expect(calls, isEmpty, reason: 'idle 不启动朗读（参考 isRun no-op）');
  });

  test('14 动作分发到对应回调；none 不触发任何动作', () {
    final calls = <String>[];
    void hit(String name) => calls.add(name);
    final delegate = ReaderTapActionDelegate(
      toggleControls: () => hit('menu'),
      nextPage: () => hit('nextPage'),
      previousPage: () => hit('previousPage'),
      nextChapter: () => hit('nextChapter'),
      previousChapter: () => hit('previousChapter'),
      previousParagraph: () => hit('previousParagraph'),
      nextParagraph: () => hit('nextParagraph'),
      addBookmark: () => hit('addBookmark'),
      editContent: () => hit('editContent'),
      toggleReplace: () => hit('toggleReplace'),
      catalog: () => hit('catalog'),
      search: () => hit('search'),
      syncProgress: () => hit('syncProgress'),
      toggleReadAloud: () => hit('toggleReadAloud'),
    );

    const expected = {
      ReaderTapAction.none: null,
      ReaderTapAction.menu: 'menu',
      ReaderTapAction.nextPage: 'nextPage',
      ReaderTapAction.previousPage: 'previousPage',
      ReaderTapAction.nextChapter: 'nextChapter',
      ReaderTapAction.previousChapter: 'previousChapter',
      ReaderTapAction.previousParagraph: 'previousParagraph',
      ReaderTapAction.nextParagraph: 'nextParagraph',
      ReaderTapAction.addBookmark: 'addBookmark',
      ReaderTapAction.editContent: 'editContent',
      ReaderTapAction.toggleReplace: 'toggleReplace',
      ReaderTapAction.catalog: 'catalog',
      ReaderTapAction.search: 'search',
      ReaderTapAction.syncProgress: 'syncProgress',
      ReaderTapAction.toggleReadAloud: 'toggleReadAloud',
    };

    for (final action in ReaderTapAction.values) {
      calls.clear();
      dispatchReaderTapAction(action, delegate);
      final want = expected[action];
      expect(calls, want == null ? isEmpty : [want], reason: action.name);
    }
  });
}
