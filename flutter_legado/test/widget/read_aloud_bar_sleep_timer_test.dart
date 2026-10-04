// 缺陷回归：朗读条定时停止下沉 AudioNotifier（双计时冲突，2026-10-04）
//
// 修复前（两套定时互不感知）：
// 1) 朗读条本地 Timer（read_aloud_bar.dart:157-175）到点 pause()，与 Notifier
//    A4 计时（audio_notifier.dart:1040-1103，到点 stop()）可并行倒计时；
// 2) 幽灵暂停：旧条定时在新播放会话中到点 pause()；
// 3) 静默失效：收起/转后台卸载朗读条即取消本地 Timer（dispose），用户设定
//    的定时无声消失。
//
// 修复后计时全部归 AudioNotifier（startSleepTimer / startChapterStop /
// cancelSleepTimer），朗读条仅入口 + ListenableBuilder 展示。本文件断言：
// a) 朗读条设定时 → 剩余量即 Notifier 剩余量（单一数据源，无双计时并行）；
// b) 卸载朗读条后倒计时继续走完并停止播放（静默失效消除）；
// c) 暂停期间剩余量冻结（对齐原版 doDs 的 `if (!pause)` 守卫）；
// d) 到点动作为 stop（对齐原版 BaseReadAloudService.kt:594 的
//    ReadAloud.stop），非 pause；按章停同样在章末 stop（:886-892）；
// e) 20 分钟设定在第 10 分钟不发生 pause（旧条本地 10 分钟定时会 pause 的
//    双计时场景回归）。
//
// 计时推进用 FakeAsync（tester.pump(duration)），播放器经
// streamAudioPlayerProvider 注入 Fake，不触真实平台通道。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/widgets/reader/read_aloud_bar.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
      ],
    );
    addTearDown(container.dispose);

    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: '第一章', index: 0),
        const BookChapter(title: '第二章', index: 1),
        const BookChapter(title: '第三章', index: 2),
      ],
    );
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.getAudioChapterMedia(any(), any())).thenAnswer((
      invocation,
    ) async {
      final index = invocation.positionalArguments[1] as int;
      return {
        'mediaUrl': 'https://cdn.example.com/$index.mp3',
        'isVolume': false,
      };
    });
    when(
      () => api.getAudioProgress(any(), any()),
    ).thenAnswer((_) async => null);
    when(
      () => api.saveAudioProgress(any(), any(), any()),
    ).thenAnswer((_) async {});
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  /// 流媒体起播（听书/TTS 之外的音频书路径，无需合成桩）
  Future<void> startStream() async {
    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ReadAloudBar(
                  onDismiss: () {},
                  onOpenCatalog: () {},
                  onBackstage: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 打开定时面板（Notifier ticker 运行期不用 pumpAndSettle，避免 1s 周期
  /// tick 持续排帧导致超时）
  Future<void> openTimerPicker(WidgetTester tester) async {
    await tester.tap(find.byTooltip('定时停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapSheetOption(WidgetTester tester, String label) async {
    // 面板内容超出弹窗高度时先滚动到可见区（小屏实测底部项会被折叠）
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('朗读条设 20 分钟即 Notifier 单一计时源；第 10 分钟不 pause，'
      '第 20 分钟 stop（双计时并行回归）', (tester) async {
    await startStream();
    await pumpBar(tester);
    await openTimerPicker(tester);
    await tapSheetOption(tester, '20 分钟');

    final notifier = readNotifier();
    // 旧实现：朗读条只改本地 _remainingSeconds，Notifier 计时为 off（红）
    expect(notifier.sleepTimerMode, SleepTimerMode.duration);
    expect(notifier.sleepRemainingSeconds, 1200);
    // 朗读条展示的就是 Notifier 的剩余量（同一数据源）
    expect(find.text('20:00'), findsOneWidget);

    // 走到第 10 分钟：旧本地 10 分钟定时会在此时 pause()；修复后仍在播放
    await tester.pump(const Duration(minutes: 10));
    await tester.pump();
    expect(readState().state, PlayerState.playing);
    expect(notifier.sleepRemainingSeconds, 600);
    expect(find.text('10:00'), findsOneWidget);

    // 第 20 分钟到点：stop（非 pause），计时清空
    await tester.pump(const Duration(minutes: 10));
    await tester.pump();
    expect(readState().state, PlayerState.idle);
    expect(notifier.isSleepTimerActive, isFalse);

    // 继续推进无幽灵暂停/双倒计时残留
    await tester.pump(const Duration(minutes: 5));
    await tester.pump();
    expect(readState().state, PlayerState.idle);
  });

  testWidgets('卸载朗读条后倒计时继续走完并停止播放（静默失效消除）', (tester) async {
    await startStream();
    await pumpBar(tester);
    await openTimerPicker(tester);
    await tapSheetOption(tester, '10 分钟');
    expect(readNotifier().sleepRemainingSeconds, 600);
    expect(find.text('10:00'), findsOneWidget);

    // 模拟收起朗读条 / 离开阅读器：整棵 widget 卸载
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // 旧实现：dispose 取消本地 Timer → 定时无声消失（仍 playing，红）；
    // 修复后计时在 Notifier，走完即 stop
    await tester.pump(const Duration(minutes: 10));
    await tester.pump();
    expect(readState().state, PlayerState.idle);
    expect(readNotifier().isSleepTimerActive, isFalse);
    expect(fakePlayer.isPlaying, isFalse);
  });

  testWidgets('暂停期间剩余量冻结，恢复后继续（对齐原版 doDs 暂停不计时）', (tester) async {
    await startStream();
    await pumpBar(tester);
    await openTimerPicker(tester);
    await tapSheetOption(tester, '10 分钟');

    // 播放 1 分钟 → 剩余 540s
    await tester.pump(const Duration(minutes: 1));
    expect(readNotifier().sleepRemainingSeconds, 540);

    // 暂停 3 分钟 → 冻结（旧本地 Timer 无 isPlaying 守卫会照走，红）
    readNotifier().pause();
    await tester.pump();
    expect(readState().state, PlayerState.paused);
    await tester.pump(const Duration(minutes: 3));
    expect(readNotifier().sleepRemainingSeconds, 540);

    // 恢复播放 1 分钟 → 继续递减
    await readNotifier().resumeOrPlay();
    await tester.pump();
    expect(readState().state, PlayerState.playing);
    await tester.pump(const Duration(minutes: 1));
    expect(readNotifier().sleepRemainingSeconds, 480);

    // 剩余走完 → stop
    await tester.pump(const Duration(minutes: 8));
    await tester.pump();
    expect(readState().state, PlayerState.idle);
    expect(readNotifier().isSleepTimerActive, isFalse);
  });

  testWidgets('分钟到点动作为 stop（非 pause），对齐原版 ReadAloud.stop', (tester) async {
    await startStream();
    await pumpBar(tester);
    await openTimerPicker(tester);
    await tapSheetOption(tester, '10 分钟');

    await tester.pump(const Duration(minutes: 10));
    await tester.pump();

    // 旧实现到点 pause()：state 会是 paused（红）
    expect(readState().state, PlayerState.idle);
    expect(fakePlayer.isPlaying, isFalse);
    expect(readNotifier().isSleepTimerActive, isFalse);
  });

  testWidgets('按章停走 Notifier：本章自然播完即章末 stop', (tester) async {
    await startStream();
    await pumpBar(tester);
    await openTimerPicker(tester);
    await tapSheetOption(tester, '读完本章后停止');

    final notifier = readNotifier();
    // 旧实现只记本地 _chapterStopTarget，Notifier 无按章计时（红）
    expect(notifier.sleepTimerMode, SleepTimerMode.chapters);
    expect(notifier.chaptersToStopRemaining, 1);

    fakePlayer.completePlayback();
    await tester.pump();
    await tester.pump();

    expect(readState().state, PlayerState.idle);
    expect(readState().currentIndex, 0);
    expect(notifier.isSleepTimerActive, isFalse);
  });

  testWidgets('朗读条取消定时清空 Notifier 计时（入口状态与数据源同源）', (tester) async {
    await startStream();
    await pumpBar(tester);
    await openTimerPicker(tester);
    await tapSheetOption(tester, '10 分钟');
    expect(readNotifier().isSleepTimerActive, isTrue);

    // 计时中重开面板：tooltip 剩余量取自 Notifier，且出现取消项
    await tester.tap(find.byTooltip('定时停止：剩余 10:00'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('取消定时'), findsOneWidget);

    await tapSheetOption(tester, '取消定时');
    expect(readNotifier().isSleepTimerActive, isFalse);
    expect(readNotifier().sleepRemainingSeconds, 0);
  });

  testWidgets('听书页/他处已设的计时在朗读条可见（同一剩余量展示）', (tester) async {
    await startStream();
    // 模拟听书页先设 5 分钟（朗读条未参与设定）
    readNotifier().startSleepTimer(5);
    await pumpBar(tester);

    expect(find.text('05:00'), findsOneWidget);
    expect(find.byTooltip('定时停止：剩余 05:00'), findsOneWidget);

    // 清理在途 ticker（测试结束前不遗留 pending timer）
    readNotifier().cancelSleepTimer();
  });
}
