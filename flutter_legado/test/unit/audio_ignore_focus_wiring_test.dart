// 批9a 项6：ignoreAudioFocus（忽略音频焦点）接线测试
//
// 语义钉住（对齐原版 AudioPlayService.kt:838 / BaseReadAloudService.kt:582/706）：
// - 默认 false：外部抢占（loss/lossTransient）暂停播放（既有行为不回退）；
// - 开启：不请求焦点（requestAudioFocus 零调用）且焦点丢失事件不再暂停
//   （允许与其他应用同时播放音频）；
// - 流模式听书与 TTS 朗读两条路径均经 initMediaSession 读取偏好。
// 既有焦点语义回归由 audio_focus_wiring_test.dart 承担（本文件补关闭态）。
import 'dart:async';

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

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late MockAudioService mockAudio;
  late FakeStreamAudioPlayer fakePlayer;
  late ProviderContainer container;
  late StreamController<AudioFocusEvent> focusController;
  late StreamController<MediaButtonEvent> buttonController;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    mockAudio = MockAudioService();
    fakePlayer = FakeStreamAudioPlayer();
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

  /// 进入「音频书流模式播放中」
  Future<void> startStreamPlayback() async {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [
        const BookChapter(title: 'ch1', index: 0),
        const BookChapter(title: 'ch2', index: 1),
      ],
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
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
    when(() => mockApi.saveAudioProgress(any(), any(), any()))
        .thenAnswer((_) async {});

    await readNotifier().initMediaSession();
    await readNotifier().loadChapters('url');
    readNotifier().setAudioBookMode(true);
    await readNotifier().play();
  }

  /// 进入「TTS 朗读播放中」
  Future<void> startTtsPlayback() async {
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [const BookChapter(title: '第一章', index: 0)],
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getChapterContentFull(any(), any()))
        .thenAnswer((_) async => '第一段文本内容。\n\n第二段文本内容。');
    when(() => mockApi.audioSpeak(
          text: any(named: 'text'),
          engineUrl: any(named: 'engineUrl'),
          speed: any(named: 'speed'),
          pitch: any(named: 'pitch'),
          volume: any(named: 'volume'),
          voiceName: any(named: 'voiceName'),
        )).thenAnswer((_) async => '/tmp/tts/para_1.wav');

    await readNotifier().initMediaSession();
    await readNotifier().loadChapters('url');
    readNotifier().updateConfig(engineUrl: 'https://tts.example.com/{{text}}');
    await readNotifier().play();
  }

  group('ignoreAudioFocus 默认关闭（既有行为不回退）', () {
    testWidgets('loss → 暂停（默认语义保持）', (tester) async {
      await startStreamPlayback();
      focusController.add(AudioFocusEvent.loss);
      await tester.pump();
      expect(readState().state, PlayerState.paused);
    });

    testWidgets('requestAudioFocus 正常调用（默认请求焦点）', (tester) async {
      await startStreamPlayback();
      verify(() => mockAudio.requestAudioFocus()).called(greaterThanOrEqualTo(1));
    });
  });

  group('ignoreAudioFocus 开启（对齐原版忽略语义）', () {
    testWidgets('不请求焦点：requestAudioFocus 零调用（流模式）', (tester) async {
      SharedPreferences.setMockInitialValues(
          {PrefKeys.ignoreAudioFocus: true});
      await startStreamPlayback();
      verifyNever(() => mockAudio.requestAudioFocus());
    });

    testWidgets('不请求焦点：requestAudioFocus 零调用（TTS 路径同链路）',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {PrefKeys.ignoreAudioFocus: true});
      await startTtsPlayback();
      verifyNever(() => mockAudio.requestAudioFocus());
    });

    testWidgets('loss 不再暂停流播放（允许与其他应用同时出声）', (tester) async {
      SharedPreferences.setMockInitialValues(
          {PrefKeys.ignoreAudioFocus: true});
      await startStreamPlayback();
      final pauseBefore = fakePlayer.pauseCount;

      focusController.add(AudioFocusEvent.loss);
      await tester.pump();

      expect(readState().state, PlayerState.playing,
          reason: '忽略音频焦点开启后，外部抢占不再暂停');
      expect(fakePlayer.pauseCount, pauseBefore);
    });

    testWidgets('lossTransient 不再暂停（TTS 路径同语义）', (tester) async {
      SharedPreferences.setMockInitialValues(
          {PrefKeys.ignoreAudioFocus: true});
      await startTtsPlayback();
      final stopBefore = fakePlayer.stopCount;

      focusController.add(AudioFocusEvent.lossTransient);
      await tester.pump();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.stopCount, stopBefore);
    });
  });
}
