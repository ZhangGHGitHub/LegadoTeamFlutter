// 朗读系统 TTS 分支单测（设置批5a-1）
//
// 覆盖 AudioNotifier 的系统 TTS 播放链：
// 1) 引擎为空（未配置）或显式哨兵 `system://tts` → 走系统 TTS 合成；
// 2) 合成产物交给 StreamAudioPlayer.playLocalFile，语速/音调/音量传入合成侧；
// 3) 合成失败 → 可见错误提示 + 估算时长推进（不静默）；无引擎 → 一次性提示；
// 4) 停止后迟到的合成结果不再播放（stale）；
// 5) 切段/切章（媒体键翻章偏好）、唤醒锁、退出阅读器停止、参数持久化读回。
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/services/system_tts_service.dart';

import '../mocks/mocks.dart';

/// 平台抽象占位（FakeSystemTtsService 覆盖合成，不使用平台）
class _NoopPlatform implements SystemTtsPlatform {
  @override
  bool get supportsEngineSelection => false;

  @override
  bool get supportsSynthesis => true;

  @override
  Future<void> init() async {}

  @override
  Future<List<SystemTtsEngine>> getEngines() async => const [];

  @override
  Future<List<SystemTtsVoice>> getVoices() async => const [];

  @override
  Future<void> setEngine(String engineName) async {}

  @override
  Future<void> resetEngine() async {}

  @override
  Future<void> setVoice(SystemTtsVoice voice) async {}

  @override
  Future<void> clearVoice() async {}

  @override
  Future<void> setSpeechRate(double speed) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> synthesizeToFile(String text, String fullPath) async {}

  @override
  Future<void> stop() async {}
}

/// 系统 TTS 服务 Fake：记录入参、按调用序返回路径、可注入失败/延迟
class FakeSystemTtsService extends SystemTtsService {
  FakeSystemTtsService()
      : super(
          platform: _NoopPlatform(),
          baseDirectoryProvider: () async => Directory.systemTemp,
        );

  final List<({String text, double speed, double pitch, double volume})> calls =
      [];

  /// 非空时合成抛出该异常
  Object? error;

  /// 延迟闸门（stale 测试用）
  Completer<void>? gate;

  String Function(int call)? pathFor;

  /// 停止次数（P2-6 stop 透传断言）
  int stopCount = 0;

  /// 一次性提示（P2-7 音色回退提示透传断言）
  String? notice;

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  String? takeNotice() {
    final n = notice;
    notice = null;
    return n;
  }

  @override
  Future<String> synthesizeToFile({
    required String text,
    required double speed,
    required double pitch,
    required double volume,
  }) async {
    calls.add((text: text, speed: speed, pitch: pitch, volume: volume));
    final g = gate;
    if (g != null) await g.future;
    final err = error;
    if (err != null) throw err;
    return pathFor?.call(calls.length) ?? '/tmp/sys_${calls.length}.wav';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRustApi mockApi;
  late MockAudioService mockAudio;
  late FakeStreamAudioPlayer fakePlayer;
  late FakeSystemTtsService fakeSystemTts;
  late ProviderContainer container;
  late StreamController<AudioFocusEvent> focusController;
  late StreamController<MediaButtonEvent> buttonController;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      // 跳过 HTTP TTS 种子导入（版本已是最新）
      'httpTtsSeedVersion': 1,
    });
    mockApi = MockRustApi();
    mockAudio = MockAudioService();
    fakePlayer = FakeStreamAudioPlayer();
    fakeSystemTts = FakeSystemTtsService();
    focusController = StreamController<AudioFocusEvent>.broadcast();
    buttonController = StreamController<MediaButtonEvent>.broadcast();

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
        )).thenAnswer((_) async {});
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
    when(() => mockAudio.setWakeLock(any())).thenAnswer((_) async {});

    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.getHttpTts()).thenAnswer((_) async => []);
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: '第一章', index: 0),
        const BookChapter(title: '第二章', index: 1),
      ],
    );
    when(() => mockApi.getChapterContentFull(any(), any()))
        .thenAnswer((_) async => '第一段文本内容。\n\n第二段文本内容。');
    when(() => mockApi.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        )).thenAnswer((_) async => '/tmp/http/never.mp3');

    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        audioServiceProvider.overrideWithValue(mockAudio),
        systemTtsServiceProvider.overrideWithValue(fakeSystemTts),
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

  Future<void> startTts({String engineUrl = ''}) async {
    await readNotifier().initMediaSession();
    await readNotifier().loadChapters('url');
    if (engineUrl.isNotEmpty) {
      readNotifier().updateConfig(engineUrl: engineUrl);
    }
    await readNotifier().play();
  }

  group('系统 TTS 播放分支', () {
    testWidgets('未配置引擎 → 系统 TTS 合成并播放本地文件', (tester) async {
      await startTts();

      expect(fakeSystemTts.calls, hasLength(1));
      expect(fakeSystemTts.calls.single.text, '第一段文本内容。');
      expect(fakePlayer.playedLocalFiles, hasLength(1));
      expect(fakePlayer.playedLocalFiles.single.path, '/tmp/sys_1.wav');
      expect(fakePlayer.playedLocalFiles.single.speed, 1.0);
      expect(readState().state, PlayerState.playing);
      expect(readState().errorMessage, isNull);
      verifyNever(() => mockApi.audioSpeak(
            text: any(named: 'text'),
            engineUrl: any(named: 'engineUrl'),
            speed: any(named: 'speed'),
            pitch: any(named: 'pitch'),
            volume: any(named: 'volume'),
            voiceName: any(named: 'voiceName'),
          ));
    });

    testWidgets('显式哨兵 system://tts 同样走系统分支', (tester) async {
      await startTts(engineUrl: kSystemTtsEngineUrl);
      expect(fakeSystemTts.calls, hasLength(1));
      expect(fakePlayer.playedLocalFiles, hasLength(1));
    });

    testWidgets('语速/音调/音量传入系统 TTS 合成侧', (tester) async {
      readNotifier().updateConfig(speed: 1.5, pitch: 1.2, volume: 0.6);
      await startTts();
      final call = fakeSystemTts.calls.single;
      expect(call.speed, 1.5);
      expect(call.pitch, 1.2);
      expect(call.volume, 0.6);
    });

    testWidgets('播放完成 → 切到下一段并再次系统合成', (tester) async {
      await startTts();
      expect(readNotifier().currentParagraphIndex, 0);
      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readNotifier().currentParagraphIndex, 1);
      expect(fakeSystemTts.calls, hasLength(2));
      expect(fakePlayer.playedLocalFiles, hasLength(2));
    });
  });

  group('失败与降级', () {
    testWidgets('合成失败 → 可见错误提示 + 估算时长推进', (tester) async {
      fakeSystemTts.error = const SystemTtsException('引擎崩溃');
      await startTts();

      expect(readState().errorMessage, contains('系统 TTS 朗读失败'));
      expect(fakePlayer.playedLocalFiles, isEmpty);
      // 估算推进：2s 假时钟跨过第一段估算时长（约 1.6s），尚未到第二段
      await tester.pump(const Duration(seconds: 2));
      expect(readNotifier().currentParagraphIndex, 1);
      expect(readState().state, PlayerState.playing);
      // 清理第二段失败后重新排的估算计时器
      readNotifier().stop();
      await tester.pump();
    });

    testWidgets('无可用引擎 → 复用一次性「无可用引擎」提示', (tester) async {
      fakeSystemTts.error =
          const SystemTtsUnavailableException('系统未安装可用的 TTS 引擎');
      await startTts();
      expect(readState().errorMessage, kNoUsableEngineHint);
      expect(fakePlayer.playedLocalFiles, isEmpty);
      // 清理降级估算计时器（避免测试结束仍有挂起 Timer）
      readNotifier().stop();
      await tester.pump();
    });

    testWidgets('播放本地文件失败 → 错误提示 + 估算推进', (tester) async {
      fakePlayer.playLocalError = StateError('解码失败');
      await startTts();
      expect(readState().errorMessage, contains('系统 TTS 朗读失败'));
      await tester.pump(const Duration(seconds: 2));
      expect(readNotifier().currentParagraphIndex, 1);
      readNotifier().stop();
      await tester.pump();
    });

    testWidgets('停止后迟到的合成结果不落播放（stale）', (tester) async {
      final gate = Completer<void>();
      fakeSystemTts.gate = gate;
      final playFuture = startTts();
      await tester.pump();
      readNotifier().stop();
      gate.complete();
      await playFuture;
      await tester.pump();
      expect(fakePlayer.playedLocalFiles, isEmpty);
    });
  });

  group('媒体键与切段/切章', () {
    testWidgets('默认（mediaButtonPerNext=false）下一首键切段', (tester) async {
      await startTts();
      expect(readNotifier().currentParagraphIndex, 0);
      buttonController.add(MediaButtonEvent.skipToNext);
      await tester.pump();
      await tester.pump();
      expect(readState().currentIndex, 0, reason: '不得切章');
      expect(readNotifier().currentParagraphIndex, 1);
    });

    testWidgets('mediaButtonPerNext=true 下一首键切章', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.mediaButtonPerNext: true,
      });
      await startTts();
      buttonController.add(MediaButtonEvent.skipToNext);
      await tester.pump();
      await tester.pump();
      expect(readState().currentIndex, 1);
    });

    testWidgets('setMediaButtonPerNext 即时生效', (tester) async {
      await startTts();
      readNotifier().setMediaButtonPerNext(true);
      buttonController.add(MediaButtonEvent.skipToNext);
      await tester.pump();
      await tester.pump();
      expect(readState().currentIndex, 1);
    });
  });

  group('唤醒锁 / 退出保持', () {
    testWidgets('朗读唤醒锁偏好开启 → 播放时持锁、停止时释放', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudWakeLock: true,
      });
      await startTts();
      verify(() => mockAudio.setWakeLock(true)).called(1);

      readNotifier().stop();
      await tester.pump();
      verify(() => mockAudio.setWakeLock(false)).called(1);
    });

    testWidgets('setReadAloudWakeLock 在播放中即时持锁/释放', (tester) async {
      await startTts();
      clearInteractions(mockAudio);
      await readNotifier().setReadAloudWakeLock(true);
      verify(() => mockAudio.setWakeLock(true)).called(1);
      await readNotifier().setReadAloudWakeLock(false);
      verify(() => mockAudio.setWakeLock(false)).called(1);
    });

    testWidgets('退出阅读器（keepReadAloudOnExit=false）→ 停止阅读器发起的朗读',
        (tester) async {
      await readNotifier().startReadAloud(
        bookUrl: 'url',
        bookName: '书',
        fromReader: true,
      );
      expect(readState().state, PlayerState.playing);
      await readNotifier().onReaderExit();
      expect(readState().state, PlayerState.idle);
      expect(readNotifier().readAloudStartedFromReader, isFalse);
    });

    testWidgets('退出阅读器（keepReadAloudOnExit=true）→ 继续朗读', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.keepReadAloudOnExit: true,
      });
      await readNotifier().startReadAloud(
        bookUrl: 'url',
        bookName: '书',
        fromReader: true,
      );
      await readNotifier().onReaderExit();
      expect(readState().state, PlayerState.playing);
    });

    testWidgets('非阅读器发起的会话（后台/听书页）不被退出钩子误停', (tester) async {
      await readNotifier().startReadAloud(bookUrl: 'url', bookName: '书');
      await readNotifier().onReaderExit();
      expect(readState().state, PlayerState.playing);
    });
  });


  group('审查回修 P2 回归', () {
    testWidgets('P2-5 暂停释放朗读唤醒锁', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.readAloudWakeLock: true,
      });
      await startTts();
      verify(() => mockAudio.setWakeLock(true)).called(1);
      clearInteractions(mockAudio);

      readNotifier().pause();
      await tester.pump();
      verify(() => mockAudio.setWakeLock(false)).called(1);
    });

    testWidgets('P2-6 stop 透传 SystemTts.stop', (tester) async {
      await startTts();
      final before = fakeSystemTts.stopCount;
      readNotifier().stop();
      await tester.pump();
      expect(fakeSystemTts.stopCount, before + 1);
    });

    testWidgets('P2-6 停止后立即重播不被旧合成阻塞', (tester) async {
      await startTts();
      final before = fakeSystemTts.calls.length;
      readNotifier().stop();
      await tester.pump();

      await readNotifier().play();
      expect(fakeSystemTts.calls.length, before + 1);
      expect(readState().state, PlayerState.playing);
      readNotifier().stop();
      await tester.pump();
    });

    testWidgets('P2-2 startReadAloud 重读全局语速（覆盖已有 config）',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.ttsSpeechRate: 5, // (5+5)/10 = 1.0x
      });
      readNotifier().updateConfig(speed: 2.0);

      await readNotifier().startReadAloud(bookUrl: 'url', bookName: '书');
      expect(readState().config.speed, closeTo(1.0, 0.001));
      readNotifier().stop();
      await tester.pump();
    });

    testWidgets('P2-7 音色回退提示只出现一次', (tester) async {
      fakeSystemTts.notice = '音色不可用，已回退系统默认音色';
      await startTts();
      expect(readState().errorMessage, contains('回退'));

      // 下一段成功播放后提示自然清除（不逐段重复）
      fakePlayer.completePlayback();
      await tester.pump();
      await tester.pump();
      expect(readState().errorMessage, isNull);
      readNotifier().stop();
      await tester.pump();
    });
  });

  group('语速/音调/音量持久化读回', () {
    testWidgets('initMediaSession 读回参考刻度并写入 state.config', (tester) async {
      SharedPreferences.setMockInitialValues({
        'httpTtsSeedVersion': 1,
        PrefKeys.ttsSpeechRate: 7,
        PrefKeys.ttsPitch: 12,
        PrefKeys.ttsVolume: 50,
      });
      await readNotifier().initMediaSession();
      final config = readState().config;
      expect(config.speed, closeTo(1.2, 0.001));
      expect(config.pitch, closeTo(1.2, 0.001));
      expect(config.volume, closeTo(0.5, 0.001));
    });

    testWidgets('未写入新键时保留旧值（兼容书级 playSpeed 读回）', (tester) async {
      readNotifier().updateConfig(speed: 1.3);
      await readNotifier().initMediaSession();
      expect(readState().config.speed, closeTo(1.3, 0.001));
    });
  });
}
