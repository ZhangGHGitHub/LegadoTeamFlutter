// 第2项：通知栏/锁屏展示定时停止剩余量（AudioNotifier 元数据组合 + 去重）测试
//
// 形态依据（原版）：
// - BaseReadAloudService.kt:700-720/780-805（TTS：通知标题 =
//   “Speaking[(N chapters left|%d min left)]: 书名”，文本 = 章节标题；
//   metadata TITLE = 章节标题、ARTIST = 组合标题）
// - AudioPlayService.kt:872-895（音频书：通知标题 =
//   “Playing[(N chapters left|%d min left)]: 书名”，文本 = 章节标题）
//
// 我方映射（见 audio_notifier.dart [_pushMediaSessionMetadata]）：
// metadata ARTIST = 「正在播放/朗读[(剩余 N 章|分钟)]: 书名」（Kotlin 侧
// PlaybackForegroundService 以此作通知标题），TITLE 保持章节标题（锁屏标题
// 语义不变）；Kotlin 映射纯函数另有 JVM 单测
// （android/app/src/test/.../PlaybackNotificationTextsTest.kt）。
//
// 覆盖：a) 未启用无剩余量；b) 按章 N 章；c) 分钟倒计时；d) 去重节流；
// e) 到点/停止/取消恢复；f) TTS 模式前缀。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/audio_service.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late MockAudioService mockAudio;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;
  late StreamController<AudioFocusEvent> focusController;
  late StreamController<MediaButtonEvent> buttonController;

  /// 记录全部 updateMetadata 调用（title=章节标题、artist=通知标题组合串）
  late List<({String title, String artist, String album})> metadataCalls;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
    mockAudio = MockAudioService();
    fakePlayer = FakeStreamAudioPlayer();
    focusController = StreamController<AudioFocusEvent>.broadcast();
    buttonController = StreamController<MediaButtonEvent>.broadcast();
    metadataCalls = [];

    when(() => mockAudio.init()).thenAnswer((_) async {});
    when(() => mockAudio.isInitialized).thenReturn(true);
    when(() => mockAudio.audioFocusStream)
        .thenAnswer((_) => focusController.stream);
    when(() => mockAudio.mediaButtonStream)
        .thenAnswer((_) => buttonController.stream);
    when(() => mockAudio.requestAudioFocus()).thenAnswer((_) async => true);
    when(() => mockAudio.updateMetadata(
          title: any(named: 'title'),
          artist: any(named: 'artist'),
          album: any(named: 'album'),
        )).thenAnswer((invocation) async {
      metadataCalls.add((
        title: invocation.namedArguments[#title] as String,
        artist: invocation.namedArguments[#artist] as String,
        album: invocation.namedArguments[#album] as String,
      ));
    });
    when(() => mockAudio.notifyPlaying(position: any(named: 'position')))
        .thenAnswer((_) async {});
    when(() => mockAudio.notifyPaused(position: any(named: 'position')))
        .thenAnswer((_) async {});
    when(() => mockAudio.notifyStopped()).thenAnswer((_) async {});
    when(() => mockAudio.setPlaying(any())).thenAnswer((_) async {});
    when(() => mockAudio.updatePlaybackState(
          state: any(named: 'state'),
          position: any(named: 'position'),
        )).thenAnswer((_) async {});
    when(() => mockAudio.abandonAudioFocus()).thenAnswer((_) async {});
    when(() => mockAudio.dispose()).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        audioServiceProvider.overrideWithValue(mockAudio),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() async {
      await focusController.close();
      await buttonController.close();
    });
  });

  AudioState readState() => container.read(audioNotifierProvider);
  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  /// 进入「音频书流媒体播放中」（书名经 initMediaSession 绑定）
  Future<void> startStreamPlayback({
    String bookName = '测试书',
    int chapterCount = 3,
  }) async {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => List.generate(
        chapterCount,
        (i) => BookChapter(title: 'ch${i + 1}', index: i),
      ),
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getAudioChapterMedia(any(), any()))
        .thenAnswer((invocation) async {
      final index = invocation.positionalArguments[1] as int;
      return {
        'mediaUrl': 'https://cdn.example.com/$index.mp3',
        'isVolume': false,
      };
    });
    when(() => mockApi.getAudioProgress(any(), any()))
        .thenAnswer((_) async => null);
    when(() => mockApi.saveAudioProgress(any(), any(), any()))
        .thenAnswer((_) async {});

    await readNotifier().initMediaSession(bookName: bookName);
    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  /// 进入「TTS 朗读播放中」
  Future<void> startTtsPlayback({String bookName = '测试书'}) async {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [const BookChapter(title: '第一章', index: 0)],
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getChapterContent(any(), any()))
        .thenAnswer((_) async => '第一段文本内容。');
    when(() => mockApi.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        )).thenAnswer((_) async => '/tmp/tts/para.mp3');

    await readNotifier().initMediaSession(bookName: bookName);
    await readNotifier().loadChapters('url');
    readNotifier().updateConfig(engineUrl: 'https://tts.example.com/{{text}}');
    await readNotifier().play();
  }

  testWidgets('a) 未启用定时：标题无「剩余」字样，锁屏标题仍为章节标题', (tester) async {
    await startStreamPlayback();
    expect(metadataCalls, isNotEmpty);
    expect(metadataCalls.last.artist, '正在播放: 测试书');
    expect(metadataCalls.last.artist.contains('剩余'), isFalse);
    expect(metadataCalls.last.title, 'ch1'); // 锁屏标题语义不变
    expect(metadataCalls.last.album, '测试书');
    expect(readNotifier().sleepTimerRemainingLabel, isEmpty);

    // 0 视同关闭：不得出现「剩余 0」
    readNotifier().startSleepTimer(0);
    expect(readNotifier().sleepTimerRemainingLabel, isEmpty);
    expect(metadataCalls.last.artist, '正在播放: 测试书');
  });

  testWidgets('b) 按章停止 N 章：标题含「剩余 N 章」，章末计数刷新', (tester) async {
    await startStreamPlayback();
    readNotifier().startChapterStop(3);

    expect(readNotifier().sleepTimerRemainingLabel, '剩余 3 章');
    expect(metadataCalls.last.title, 'ch1');
    expect(metadataCalls.last.artist, '正在播放(剩余 3 章): 测试书');

    // 第一章自然播完 → 计数 2 并切到第二章（章末即时刷新）
    fakePlayer.completePlayback();
    await tester.pump();
    await tester.pump();

    expect(readState().currentIndex, 1);
    expect(readNotifier().chaptersToStopRemaining, 2);
    expect(metadataCalls.last.title, 'ch2');
    expect(metadataCalls.last.artist, '正在播放(剩余 2 章): 测试书');
  });

  testWidgets('c) 分钟倒计时：标题含剩余分钟（向上取整对齐原版节奏）', (tester) async {
    await startStreamPlayback();
    readNotifier().startSleepTimer(5);

    expect(readNotifier().sleepTimerRemainingLabel, '剩余 5 分钟');
    expect(metadataCalls.last.artist, '正在播放(剩余 5 分钟): 测试书');

    // 走过 59 秒：剩余 241s，分钟整数仍为 5
    await tester.pump(const Duration(seconds: 59));
    expect(readNotifier().sleepRemainingSeconds, 241);
    expect(readNotifier().sleepTimerRemainingLabel, '剩余 5 分钟');

    // 再 1 秒到 240s → 4 分钟
    await tester.pump(const Duration(seconds: 1));
    expect(readNotifier().sleepRemainingSeconds, 240);
    expect(readNotifier().sleepTimerRemainingLabel, '剩余 4 分钟');
    expect(metadataCalls.last.artist, '正在播放(剩余 4 分钟): 测试书');

    // 清理进行中的 ticker（测试结束不得残留 pending Timer）
    readNotifier().cancelSleepTimer();
  });

  testWidgets('d) 去重节流：分钟整数不变/同值重设/恢复播放均不重推 metadata', (tester) async {
    await startStreamPlayback();
    readNotifier().startSleepTimer(5);
    final callsAfterStart = metadataCalls.length;

    // 59 次 tick（300→241）分钟整数不变 → 0 次重推
    await tester.pump(const Duration(seconds: 59));
    expect(metadataCalls.length, callsAfterStart);

    // 同值重设 5 分钟：签名未变 → 不重推
    readNotifier().startSleepTimer(5);
    expect(metadataCalls.length, callsAfterStart);

    // 暂停/恢复：元数据未变 → 不重推（播放态经 notifyPlaying 单独发布）
    readNotifier().pause();
    await tester.pump();
    await readNotifier().resumeOrPlay();
    await tester.pump();
    expect(readState().state, PlayerState.playing);
    expect(metadataCalls.length, callsAfterStart);

    // 清理进行中的 ticker（测试结束不得残留 pending Timer）
    readNotifier().cancelSleepTimer();
  });

  testWidgets('e1) 分钟到点：停止后标题恢复原形态（无剩余量）', (tester) async {
    await startStreamPlayback();
    readNotifier().startSleepTimer(1); // 60s
    expect(metadataCalls.last.artist, '正在播放(剩余 1 分钟): 测试书');

    await tester.pump(const Duration(seconds: 60));
    await tester.pump();

    expect(readState().state, PlayerState.idle);
    expect(readNotifier().isSleepTimerActive, isFalse);
    expect(metadataCalls.last.artist, '正在播放: 测试书');
    expect(metadataCalls.last.artist.contains('剩余'), isFalse);
    verify(() => mockAudio.notifyStopped()).called(1);
  });

  testWidgets('e2) 取消定时：标题恢复原形态', (tester) async {
    await startStreamPlayback();
    readNotifier().startChapterStop(2);
    expect(metadataCalls.last.artist, '正在播放(剩余 2 章): 测试书');

    readNotifier().cancelSleepTimer();
    expect(readNotifier().sleepTimerMode, SleepTimerMode.off);
    expect(metadataCalls.last.artist, '正在播放: 测试书');
    expect(metadataCalls.last.artist.contains('剩余'), isFalse);
  });

  testWidgets('e3) 手动停止：定时清空且标题恢复原形态', (tester) async {
    await startStreamPlayback();
    readNotifier().startChapterStop(1);
    expect(metadataCalls.last.artist, '正在播放(剩余 1 章): 测试书');

    readNotifier().stop();
    await tester.pump();

    expect(readNotifier().isSleepTimerActive, isFalse);
    expect(metadataCalls.last.artist, '正在播放: 测试书');
    expect(metadataCalls.last.artist.contains('剩余'), isFalse);
  });

  testWidgets('f) TTS 模式：前缀「正在朗读」，定时剩余量同样进入标题', (tester) async {
    await startTtsPlayback();
    expect(readState().isStreamMode, isFalse);
    expect(metadataCalls.last.artist, '正在朗读: 测试书');
    expect(metadataCalls.last.title, '第一章');

    readNotifier().startSleepTimer(10);
    expect(metadataCalls.last.artist, '正在朗读(剩余 10 分钟): 测试书');

    readNotifier().startChapterStop(2);
    expect(metadataCalls.last.artist, '正在朗读(剩余 2 章): 测试书');

    readNotifier().cancelSleepTimer();
    expect(metadataCalls.last.artist, '正在朗读: 测试书');
    expect(metadataCalls.last.artist.contains('剩余'), isFalse);
  });
}
