// D1 回归护栏：音频焦点唯一所有者语义不变。
//
// 修复方案是「底层 media3 播放器不再请求焦点（StreamAudioPlayer
// .playbackOptions / stream_audio_player_focus_test.dart），
// MediaSessionBridge 继续作为唯一焦点所有者」。
// 本文件从 Dart 侧钉住焦点事件处理：外部抢占（loss/lossTransient）
// 仍然暂停真实播放（流模式 pause、TTS 停止当前段），gain 恢复，
// duck 不暂停——流模式与 TTS 两条路径均覆盖，防止今后修复回归。
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

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
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

  group('流模式焦点事件（外部抢占暂停语义保留）', () {
    testWidgets('lossTransient → 暂停流播放（pause，不丢弃进度）', (tester) async {
      await startStreamPlayback();
      expect(readState().state, PlayerState.playing);
      final pauseBefore = fakePlayer.pauseCount;

      focusController.add(AudioFocusEvent.lossTransient);
      await tester.pump();

      expect(readState().state, PlayerState.paused);
      expect(fakePlayer.pauseCount, greaterThan(pauseBefore));
      expect(fakePlayer.stopCount, 0);
    });

    testWidgets('loss（永久丢失）→ 暂停流播放', (tester) async {
      await startStreamPlayback();

      focusController.add(AudioFocusEvent.loss);
      await tester.pump();

      expect(readState().state, PlayerState.paused);
      expect(fakePlayer.pauseCount, greaterThan(0));
    });

    testWidgets('gain（暂停后）→ 恢复流播放且重新同步媒体会话', (tester) async {
      await startStreamPlayback();
      focusController.add(AudioFocusEvent.lossTransient);
      await tester.pump();
      expect(readState().state, PlayerState.paused);

      focusController.add(AudioFocusEvent.gain);
      await tester.pump();
      await tester.pump();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.resumeCount, greaterThan(0));
      verify(() => mockAudio.requestAudioFocus()).called(greaterThan(0));
    });

    testWidgets('lossTransientCanDuck → 保持播放（可 duck，不暂停）', (tester) async {
      await startStreamPlayback();

      focusController.add(AudioFocusEvent.lossTransientCanDuck);
      await tester.pump();

      expect(readState().state, PlayerState.playing);
      expect(fakePlayer.pauseCount, 0);
    });
  });

  group('TTS 焦点事件（与流模式同链路）', () {
    testWidgets('loss → 暂停并停掉当前段音频（恢复时重播当前段）', (tester) async {
      await startTtsPlayback();
      expect(readState().state, PlayerState.playing);
      final stopBefore = fakePlayer.stopCount;

      focusController.add(AudioFocusEvent.loss);
      await tester.pump();

      expect(readState().state, PlayerState.paused);
      expect(fakePlayer.stopCount, greaterThan(stopBefore));
      expect(readNotifier().currentParagraphIndex, 0);
    });

    testWidgets('lossTransientCanDuck → 保持播放', (tester) async {
      await startTtsPlayback();

      focusController.add(AudioFocusEvent.lossTransientCanDuck);
      await tester.pump();

      expect(readState().state, PlayerState.playing);
    });
  });
}
