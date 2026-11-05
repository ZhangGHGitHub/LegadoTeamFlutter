// A4 批：定时停止（分钟倒计时 + 按章停止）计时下沉 AudioNotifier 测试
//
// 覆盖：
// a) 按章停止（对齐原版 ChapterStopTimer 语义）：
//    - 流媒体：自然播完 1 章即在章末停止（不进入下一章）并 force 写进度
//    - 流媒体：N=2 时第一章完成自动切章、第二章完成才停
//    - 手动 next()/jumpTo 不计按章（原版仅 auto 完成计数）
//    - TTS：末段播完到章末停止（不切章、不写流媒体进度键）
// b) 分钟倒计时在退出听书页（widget 销毁）后仍继续，到点停止
// c) 定时到点停止播放并 force 写进度（复用 A3）
// d) 暂停冻结倒计时、恢复后继续（对齐原版 doDs 的 `if (!pause)` 守卫）
// e) 分钟/按章互斥、取消、上限 clamp
//
// 计时推进用 testWidgets 的 FakeAsync（tester.pump(duration) 推时钟），
// 播放器经 streamAudioPlayerProvider 注入 Fake，不触真实 video_player 平台通道。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    // [设置批5c] 定时设置/缓存保留时间在起播入口读 SharedPreferences：
    // 测试 zone 必须先装 mock，否则 getInstance 的 Future 永不完成。
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
      ],
    );
    addTearDown(container.dispose);
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  /// 流媒体 stub + 起播（[chapterCount] 章）
  Future<void> startStream({int chapterCount = 3}) async {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => List.generate(
        chapterCount,
        (i) => BookChapter(title: 'ch${i + 1}', index: i),
      ),
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer((
      invocation,
    ) async {
      final index = invocation.positionalArguments[1] as int;
      return {
        'mediaUrl': 'https://cdn.example.com/$index.mp3',
        'isVolume': false,
      };
    });
    when(
      () => mockApi.getAudioProgress(any(), any()),
    ).thenAnswer((_) async => null);
    when(
      () => mockApi.saveAudioProgress(any(), any(), any()),
    ).thenAnswer((_) async {});

    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  group('a) 按章停止（章末边界，对齐原版 ChapterStopTimer）', () {
    testWidgets('流媒体：按章停止 1 = 本章播完即停，不进入下一章且写进度', (tester) async {
      await startStream(); // 3 章
      readNotifier().startChapterStop(1);
      expect(readNotifier().sleepTimerMode, SleepTimerMode.chapters);
      expect(readNotifier().chaptersToStopRemaining, 1);

      // 3s 位置已周期写库；4s 增量 <5s 被节流（确保停止时确有新值可写）
      fakePlayer.emitProgress(
        const Duration(seconds: 3),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 3000)).called(1);
      fakePlayer.emitProgress(
        const Duration(seconds: 4),
        const Duration(minutes: 3),
      );
      await tester.pump();

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();

      // 章末停止：停留在原章，不切下一章
      expect(readState().state, PlayerState.idle);
      expect(readState().currentIndex, 0);
      expect(readNotifier().isSleepTimerActive, isFalse);
      // 停止时 force 写当前章进度（A3 复用）
      verify(() => mockApi.saveAudioProgress('url', 0, 4000)).called(1);
      verifyNever(() => mockApi.saveAudioProgress('url', 1, any()));
    });

    testWidgets('流媒体：按章停止 2 = 第一章完成计数并切章，第二章完成才停', (tester) async {
      await startStream();
      readNotifier().startChapterStop(2);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();

      expect(readState().currentIndex, 1);
      expect(readState().state, PlayerState.playing);
      expect(readNotifier().chaptersToStopRemaining, 1);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();

      expect(readState().state, PlayerState.idle);
      expect(readState().currentIndex, 1);
      expect(readNotifier().isSleepTimerActive, isFalse);
    });

    testWidgets('手动 next() 不计按章，计数保持不变', (tester) async {
      await startStream();
      readNotifier().startChapterStop(1);

      await readNotifier().next();
      await tester.pump();

      expect(readState().currentIndex, 1);
      expect(readNotifier().chaptersToStopRemaining, 1);
    });

    testWidgets('TTS：末段播完到章末停止（不切章、不写流媒体进度键）', (tester) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [
          const BookChapter(title: '第一章', index: 0),
          const BookChapter(title: '第二章', index: 1),
        ],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(
        () => mockApi.getChapterContentFull(any(), any()),
      ).thenAnswer((_) async => '第一段文本内容。');
      when(
        () => mockApi.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        ),
      ).thenAnswer((_) async => '/tmp/tts/para.mp3');

      await readNotifier().loadChapters('url');
      readNotifier().updateConfig(
        engineUrl: 'https://tts.example.com/{{text}}',
      );
      await readNotifier().play();
      expect(readState().isStreamMode, isFalse);
      readNotifier().startChapterStop(1);

      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();

      expect(readState().state, PlayerState.idle);
      expect(readState().currentIndex, 0);
      expect(readNotifier().isSleepTimerActive, isFalse);
      verifyNever(() => mockApi.saveAudioProgress(any(), any(), any()));
    });
  });

  group('b) 计时下沉：退出听书页后倒计时继续', () {
    testWidgets('页面 widget 销毁后分钟倒计时仍走完并停止播放', (tester) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [
          const BookChapter(title: '第一章', index: 0),
          const BookChapter(title: '第二章', index: 1),
        ],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.getAudioChapterMedia(any(), any())).thenAnswer((
        invocation,
      ) async {
        final index = invocation.positionalArguments[1] as int;
        return {
          'mediaUrl': 'https://cdn.example.com/$index.mp3',
          'isVolume': false,
        };
      });
      when(
        () => mockApi.getAudioProgress(any(), any()),
      ).thenAnswer((_) async => null);
      when(
        () => mockApi.saveAudioProgress(any(), any(), any()),
      ).thenAnswer((_) async {});

      // 预载章节，保证页面 initState 不重复 load（渲染路径确定性）
      await readNotifier().loadChapters('url');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: AudioScreen(
              book: Book(bookUrl: 'url', name: '测试书', bookType: 32),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final notifier = readNotifier();
      expect(readState().hasChapters, isTrue);
      // 听书页 postFrame 已切流媒体模式
      expect(readState().isStreamMode, isTrue);
      await notifier.play();
      await tester.pump();
      expect(readState().state, PlayerState.playing);

      notifier.startSleepTimer(5);
      expect(notifier.sleepRemainingSeconds, 300);

      // 模拟退出听书页：整棵页面树移除（AudioScreen.dispose）
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      // 退出后倒计时仍继续：走满 5 分钟 → 到点停止
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();

      expect(readState().state, PlayerState.idle);
      expect(notifier.isSleepTimerActive, isFalse);
      expect(fakePlayer.isPlaying, isFalse);
    });
  });

  group('c) 分钟倒计时到点停止 + force 写进度', () {
    testWidgets('倒计时归零：停止播放并在停止前 force 写当前进度', (tester) async {
      await startStream();
      fakePlayer.emitProgress(
        const Duration(seconds: 3),
        const Duration(minutes: 3),
      );
      await tester.pump();
      verify(() => mockApi.saveAudioProgress('url', 0, 3000)).called(1);

      // 4s 增量被节流（未写库），确保到点停止时确有新位置可写
      fakePlayer.emitProgress(
        const Duration(seconds: 4),
        const Duration(minutes: 3),
      );
      await tester.pump();

      readNotifier().startSleepTimer(5);
      expect(readNotifier().sleepTimerMode, SleepTimerMode.duration);
      expect(readNotifier().sleepRemainingSeconds, 300);

      await tester.pump(const Duration(minutes: 5));
      await tester.pump();

      expect(readState().state, PlayerState.idle);
      expect(readNotifier().isSleepTimerActive, isFalse);
      verify(() => mockApi.saveAudioProgress('url', 0, 4000)).called(1);
    });
  });

  group('d) 暂停/恢复对倒计时的影响（对齐原版：暂停冻结）', () {
    testWidgets('暂停期间倒计时冻结，恢复播放后从剩余时间继续', (tester) async {
      await startStream();
      readNotifier().startSleepTimer(5);
      expect(readNotifier().sleepRemainingSeconds, 300);

      // 播放 1 分钟 → 剩余 240s
      await tester.pump(const Duration(minutes: 1));
      expect(readNotifier().sleepRemainingSeconds, 240);

      // 暂停 3 分钟 → 冻结不变
      readNotifier().pause();
      await tester.pump(const Duration(minutes: 3));
      expect(readState().state, PlayerState.paused);
      expect(readNotifier().sleepRemainingSeconds, 240);

      // 恢复播放 1 分钟 → 继续递减到 180s
      await readNotifier().resumeOrPlay();
      expect(readState().state, PlayerState.playing);
      await tester.pump(const Duration(minutes: 1));
      expect(readNotifier().sleepRemainingSeconds, 180);

      // 剩余走完 → 停止
      await tester.pump(const Duration(minutes: 3));
      await tester.pump();
      expect(readState().state, PlayerState.idle);
      expect(readNotifier().isSleepTimerActive, isFalse);
    });
  });

  group('e) 模式互斥/取消/上限', () {
    testWidgets('分钟与按章互斥：设置其一清空另一', (tester) async {
      readNotifier().startChapterStop(3);
      expect(readNotifier().sleepTimerMode, SleepTimerMode.chapters);
      expect(readNotifier().chaptersToStopRemaining, 3);

      readNotifier().startSleepTimer(10);
      expect(readNotifier().sleepTimerMode, SleepTimerMode.duration);
      expect(readNotifier().chaptersToStopRemaining, 0);
      expect(readNotifier().sleepRemainingSeconds, 600);

      readNotifier().startChapterStop(1);
      expect(readNotifier().sleepTimerMode, SleepTimerMode.chapters);
      expect(readNotifier().sleepRemainingSeconds, 0);

      readNotifier().cancelSleepTimer();
      expect(readNotifier().isSleepTimerActive, isFalse);
      expect(readNotifier().sleepTimerMode, SleepTimerMode.off);
    });

    testWidgets('上限对齐参考版：分钟 ≤180、章 ≤50；0 视为关闭', (tester) async {
      readNotifier().startSleepTimer(181);
      expect(readNotifier().sleepRemainingSeconds, 180 * 60);

      readNotifier().startChapterStop(100);
      expect(readNotifier().chaptersToStopRemaining, 50);

      readNotifier().startSleepTimer(0);
      expect(readNotifier().isSleepTimerActive, isFalse);

      readNotifier().startChapterStop(0);
      expect(readNotifier().isSleepTimerActive, isFalse);
    });
  });

  group('f) 读完本章再停（设置批5c）', () {
    /// TTS 起播（HTTP 合成桩；正文 paragraph 数由 [content] 决定）
    Future<void> startTts(String content) async {
      when(() => mockApi.getChapters(any())).thenAnswer(
        (_) async => [
          const BookChapter(title: '第一章', index: 0),
          const BookChapter(title: '第二章', index: 1),
        ],
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(
        () => mockApi.getChapterContentFull(any(), any()),
      ).thenAnswer((_) async => content);
      when(
        () => mockApi.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        ),
      ).thenAnswer((_) async => '/tmp/tts/para.mp3');

      await readNotifier().loadChapters('url');
      readNotifier().updateConfig(
        engineUrl: 'https://tts.example.com/{{text}}',
      );
      await readNotifier().play();
      expect(readState().isStreamMode, isFalse);
    }

    testWidgets('分钟到点当前章未播完：保留播放，章末 stop 并清空标志', (tester) async {
      await startTts('第一段内容。\n\n第二段内容。');
      final notifier = readNotifier();
      notifier.setFinishCurrentChapterAfterTimer(true);
      notifier.startSleepTimer(1);
      expect(notifier.paragraphCount, 2);

      // 到点：当前是首段，装臂标并继续播放
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(readState().state, PlayerState.playing);
      expect(notifier.sleepTimerMode, SleepTimerMode.finishChapter);
      expect(notifier.isFinishChapterAfterTimerArmed, isTrue);
      expect(notifier.sleepTimerRemainingLabel, '读完本章后停止');

      // 首段播完 → 继续第二段（不因定时到点立即停）
      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(readState().state, PlayerState.playing);
      expect(notifier.currentParagraphIndex, 1);
      expect(notifier.isFinishChapterAfterTimerArmed, isTrue);

      // 末段播完 → 章末 stop（不进入第二章）
      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readState().state, PlayerState.idle);
      expect(readState().currentIndex, 0);
      expect(notifier.isFinishChapterAfterTimerArmed, isFalse);
      expect(notifier.isSleepTimerActive, isFalse);
    });

    testWidgets('分钟到点已在章末：立即 stop，不进入等待', (tester) async {
      await startTts('只有一段内容。');
      final notifier = readNotifier();
      notifier.setFinishCurrentChapterAfterTimer(true);
      notifier.startSleepTimer(1);
      // 模拟末段音频已经结束但完成回调尚未送达（仍在章末）
      fakePlayer.isPlaying = false;

      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      expect(readState().state, PlayerState.idle);
      expect(notifier.sleepTimerMode, SleepTimerMode.off);
      expect(notifier.isSleepTimerActive, isFalse);
    });

    testWidgets('手动切章清除章末等待臂标', (tester) async {
      await startTts('第一段内容。\n\n第二段内容。');
      final notifier = readNotifier();
      notifier.setFinishCurrentChapterAfterTimer(true);
      notifier.startSleepTimer(1);
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();
      expect(notifier.sleepTimerMode, SleepTimerMode.finishChapter);

      await notifier.next();
      await tester.pump();
      expect(notifier.sleepTimerMode, SleepTimerMode.off);
      expect(readState().currentIndex, 1);
    });
  });
}
