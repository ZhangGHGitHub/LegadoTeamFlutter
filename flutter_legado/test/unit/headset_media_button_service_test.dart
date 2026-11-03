// [批9b-5 | 耳机媒体键] HeadsetMediaButtonService 决策/接线单测
//
// 语义基准：原版 `MediaButtonReceiver.kt:73-118`（参考版同构）：
// 1. TTS/音频播放服务运行 → 播放/暂停切换；
// 2. 否则 mediaKey 且 `readAloudByMediaButton=false` → 忽略；
// 3. 有 ReadBook/AudioPlay Activity → 事件交活动处理；
// 4. 否则 `mediaButtonOnExit || activitySize>0 || !isMediaKey` → 从最近
//    阅读书启动/恢复朗读；
// 5. 其余（后台且 mediaButtonOnExit=false）→ 忽略。
//
// 覆盖：
// - 纯决策矩阵（前台/后台、播放/暂停、两偏好四种组合、上一首/下一首、
//   无最近书、非 mediaKey）；
// - 服务接线（ready 握手、通道事件解析、长按 repeat/ACTION_UP 忽略、
//   阅读器前台处理器分派、最近阅读书排序与 audio 书过滤）；
// - 后台释放会话（mediaButtonOnExit=false 且无播放 → release；
//   true / 有播放 → 保留）；
// - AudioNotifier.releaseMediaSession 的保留语义；
// - 两开关默认值与 SharedPreferences 持久化。
//
// — 全栈工程师 ｜ 2026-11-04

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/services/headset_media_button_service.dart';
import 'package:flutter_legado/src/services/settings_service.dart';

import '../mocks/mocks.dart';

/// 可记录调用的音频控制面 fake
class _FakeAudio implements HeadsetMediaAudioController {
  @override
  bool hasActivePlayback = false;

  @override
  bool isPlaying = false;

  @override
  bool isStreamMode = false;

  final List<String> calls = <String>[];

  @override
  void pause() => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> skipNext() async => calls.add('skipNext');

  @override
  Future<void> skipPrevious() async => calls.add('skipPrevious');

  @override
  Future<void> nextParagraph() async => calls.add('nextParagraph');

  @override
  Future<void> prevParagraph() async => calls.add('prevParagraph');

  @override
  Future<void> startReadAloud({
    required String bookUrl,
    required String bookName,
    required int chapterIndex,
  }) async {
    calls.add('startReadAloud:$bookUrl:$chapterIndex');
  }

  @override
  Future<void> releaseMediaSession() async => calls.add('release');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final settings = SettingsService();

  /// 会话媒体键事件流（仅服务接线组初始化）
  late StreamController<MediaButtonEvent> sessionButtons;

  /// 构造服务（默认偏好：全程响应=true、按键启动朗读=false）
  HeadsetMediaButtonService buildService({
    required _FakeAudio audio,
    required MockRustApi api,
    bool Function()? foreground,
    Stream<MediaButtonEvent>? mediaButtonStream,
  }) {
    return HeadsetMediaButtonService(
      audio: () => audio,
      bookApi: api,
      settings: settings,
      isAppForeground: foreground,
      mediaButtonStream: mediaButtonStream ?? sessionButtons.stream,
    );
  }

  Future<void> emitNative(Map<String, Object?> arguments) async {
    await messenger.handlePlatformMessage(
      'legado/headset_media_button',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onMediaButton', arguments),
      ),
      (_) {},
    );
    // 处理器内部含 prefs/API 异步读取，留出微任务窗口
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HeadsetMediaButtonService.debounceWindow = Duration.zero;
  });

  tearDown(() {
    HeadsetMediaButtonService.debounceWindow =
        const Duration(milliseconds: 250);
    messenger.setMockMethodCallHandler(HeadsetMediaButtonService.channel, null);
  });

  group('[批9b-5] 纯决策矩阵', () {
    HeadsetMediaAction decide({
      HeadsetMediaKey key = HeadsetMediaKey.toggle,
      bool hasPlayback = false,
      bool isPlaying = false,
      bool isMediaKey = true,
      bool readAloud = false,
      bool onExit = true,
      bool activity = false,
      bool foreground = false,
    }) {
      return decideHeadsetMediaAction(
        key: key,
        hasPlaybackSession: hasPlayback,
        isPlaying: isPlaying,
        isMediaKey: isMediaKey,
        readAloudByMediaButton: readAloud,
        mediaButtonOnExit: onExit,
        activityHandlerAttached: activity,
        appForeground: foreground,
      );
    }

    test('播放中切换 → 暂停；暂停中切换 → 恢复（两偏好均不影响）', () {
      expect(
        decide(hasPlayback: true, isPlaying: true),
        HeadsetMediaAction.pausePlayback,
      );
      expect(
        decide(
          hasPlayback: true,
          isPlaying: false,
          readAloud: false,
          onExit: false,
          foreground: false,
        ),
        HeadsetMediaAction.resumePlayback,
        reason: '播放会话存在时优先于两偏好/前后台判定（原版分支 1）',
      );
    });

    test('播放会话存在时上一首/下一首 → 切段/切章', () {
      expect(
        decide(key: HeadsetMediaKey.next, hasPlayback: true),
        HeadsetMediaAction.nextItem,
      );
      expect(
        decide(key: HeadsetMediaKey.previous, hasPlayback: true),
        HeadsetMediaAction.previousItem,
      );
    });

    test('无播放 + readAloudByMediaButton=false → 忽略（即使前台/有活动）', () {
      expect(
        decide(readAloud: false, foreground: true, activity: true),
        HeadsetMediaAction.ignoreStartDisabled,
      );
    });

    test('无播放 + 启动朗读开 + 阅读页存在 → 交活动处理（不直接启动）', () {
      expect(
        decide(readAloud: true, activity: true, foreground: true),
        HeadsetMediaAction.dispatchToActivity,
      );
      expect(
        decide(readAloud: true, activity: true, foreground: false),
        HeadsetMediaAction.dispatchToActivity,
        reason: '原版 LifecycleHelp.isExistActivity 只看实例存在，不看 resumed',
      );
    });

    test('后台 + 全程响应开 → 从最近书启动朗读', () {
      expect(
        decide(readAloud: true, onExit: true, foreground: false),
        HeadsetMediaAction.startReadAloud,
      );
    });

    test('后台 + 全程响应关 → 忽略', () {
      expect(
        decide(readAloud: true, onExit: false, foreground: false),
        HeadsetMediaAction.ignoreExitDisabled,
      );
    });

    test('前台其他页面 + 全程响应关 → activitySize>0 仍启动朗读', () {
      expect(
        decide(readAloud: true, onExit: false, foreground: true),
        HeadsetMediaAction.startReadAloud,
      );
    });

    test('无播放时上一首/下一首不触发启动朗读', () {
      expect(
        decide(key: HeadsetMediaKey.next, readAloud: true, onExit: true),
        HeadsetMediaAction.ignoreNoPlayback,
      );
      expect(
        decide(key: HeadsetMediaKey.previous, readAloud: true, onExit: true),
        HeadsetMediaAction.ignoreNoPlayback,
      );
    });

    test('非 mediaKey 调用（isMediaKey=false）不受启动开关限制', () {
      expect(
        decide(readAloud: false, onExit: false, isMediaKey: false),
        HeadsetMediaAction.startReadAloud,
        reason: '原版 readAloud(context, isMediaKey=false) 用于强制启动',
      );
    });

    test('keyCode 映射：87/88 → 上一首/下一首，其余 → 切换', () {
      expect(HeadsetMediaKey.fromKeyCode(87), HeadsetMediaKey.next);
      expect(HeadsetMediaKey.fromKeyCode(88), HeadsetMediaKey.previous);
      expect(HeadsetMediaKey.fromKeyCode(85), HeadsetMediaKey.toggle);
      expect(HeadsetMediaKey.fromKeyCode(126), HeadsetMediaKey.toggle);
      expect(HeadsetMediaKey.fromKeyCode(127), HeadsetMediaKey.toggle);
      expect(HeadsetMediaKey.fromKeyCode(79), HeadsetMediaKey.toggle);
    });
  });

  group('[批9b-5] 服务接线', () {
    late _FakeAudio audio;
    late MockRustApi api;
    late HeadsetMediaButtonService service;
    late List<MethodCall> nativeCalls;

    setUp(() {
      audio = _FakeAudio();
      api = MockRustApi();
      nativeCalls = <MethodCall>[];
      sessionButtons = StreamController<MediaButtonEvent>.broadcast();
      messenger.setMockMethodCallHandler(HeadsetMediaButtonService.channel, (
        call,
      ) async {
        nativeCalls.add(call);
        return 0;
      });
    });

    tearDown(() async {
      await service.stop();
      await sessionButtons.close();
    });

    test('start 后向原生发送 ready 握手', () async {
      service = buildService(audio: audio, api: api);
      await service.start();
      expect(nativeCalls.map((c) => c.method), contains('ready'));
    });

    test('通道播放键事件：TTS 播放中 → pause', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: true,
      });
      audio
        ..hasActivePlayback = true
        ..isPlaying = true;
      service = buildService(audio: audio, api: api);
      await service.start();
      await emitNative({'keyCode': 85, 'action': 0, 'repeat': 0});
      expect(audio.calls, ['pause']);
    });

    test('会话空闲态播放键：按偏好从最近书启动（不盲目重播旧会话）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: true,
      });
      when(() => api.getBooks()).thenAnswer(
        (_) async => [
          const Book(
            bookUrl: 'last',
            name: '最近书',
            bookType: BookType.text,
            durChapterTime: 1,
            durChapterIndex: 3,
          ),
        ],
      );
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      sessionButtons.add(MediaButtonEvent.play);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.calls, ['startReadAloud:last:3']);
    });

    test('会话空闲态播放键 + 启动朗读关 → 忽略', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: false,
      });
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      sessionButtons.add(MediaButtonEvent.play);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.calls, isEmpty);
      verifyNever(() => api.getBooks());
    });

    test('会话播放中不重复处理（AudioNotifier 已暂停/恢复）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: true,
      });
      audio
        ..hasActivePlayback = true
        ..isPlaying = true;
      service = buildService(audio: audio, api: api);
      await service.start();
      sessionButtons.add(MediaButtonEvent.play);
      await Future<void>.delayed(Duration.zero);
      expect(audio.calls, isEmpty);
    });

    test('ACTION_UP、repeat>0、畸形参数均忽略', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: true,
      });
      audio
        ..hasActivePlayback = true
        ..isPlaying = true;
      service = buildService(audio: audio, api: api);
      await service.start();
      await emitNative({'keyCode': 85, 'action': 1, 'repeat': 0});
      await emitNative({'keyCode': 85, 'action': 0, 'repeat': 2});
      await emitNative({'keyCode': '85', 'action': 0, 'repeat': 0});
      await emitNative({'action': 0});
      expect(audio.calls, isEmpty);
    });

    test('后台 + 两开关开 + 有最近阅读书：取 durChapterTime 最大的文本书', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: true,
      });
      when(() => api.getBooks()).thenAnswer(
        (_) async => [
          const Book(
            bookUrl: 'older',
            name: '旧书',
            bookType: BookType.text,
            durChapterTime: 100,
            durChapterIndex: 1,
          ),
          const Book(
            bookUrl: 'audio',
            name: '音频书',
            bookType: BookType.audio,
            durChapterTime: 999,
            durChapterIndex: 0,
          ),
          const Book(
            bookUrl: 'newest',
            name: '最近书',
            bookType: BookType.text,
            durChapterTime: 500,
            durChapterIndex: 7,
          ),
        ],
      );
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      await emitNative({'keyCode': 85, 'action': 0, 'repeat': 0});
      expect(audio.calls, ['startReadAloud:newest:7']);
    });

    test('后台 + 无最近阅读书：忽略启动朗读', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: true,
      });
      when(() => api.getBooks()).thenAnswer((_) async => []);
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      await emitNative({'keyCode': 85, 'action': 0, 'repeat': 0});
      expect(audio.calls, isEmpty);
    });

    test('后台 + 全程响应关：忽略（不启动/不恢复）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: false,
        PrefKeys.readAloudByMediaButton: true,
      });
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      await emitNative({'keyCode': 85, 'action': 0, 'repeat': 0});
      expect(audio.calls, isEmpty);
      verifyNever(() => api.getBooks());
    });

    test('后台 + 启动朗读关：忽略', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: false,
      });
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      await emitNative({'keyCode': 85, 'action': 0, 'repeat': 0});
      expect(audio.calls, isEmpty);
    });

    test('阅读器挂载时事件交页面处理器，不直接启动朗读', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: false,
        PrefKeys.readAloudByMediaButton: true,
      });
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => true,
      );
      final received = <HeadsetMediaKey>[];
      final owner = Object();
      service.attachActivityHandler(owner, received.add);
      await service.start();
      await emitNative({'keyCode': 85, 'action': 0, 'repeat': 0});
      expect(received, [HeadsetMediaKey.toggle]);
      expect(audio.calls, isEmpty);
      expect(service.hasActivityHandler, isTrue);

      service.detachActivityHandler(owner);
      expect(service.hasActivityHandler, isFalse);
      // 其他 owner 注销不误清（模拟旧阅读器 dispose 晚于新实例挂载）
      final newOwner = Object();
      service.attachActivityHandler(newOwner, received.add);
      service.detachActivityHandler(owner);
      expect(service.hasActivityHandler, isTrue);
    });

    test('后台且全程响应关、无播放：退出后台时释放会话', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: false,
        PrefKeys.readAloudByMediaButton: true,
      });
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(audio.calls, ['release']);
    });

    test('后台但全程响应开 / 有播放会话：退出后台不释放会话', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
        PrefKeys.readAloudByMediaButton: true,
      });
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(audio.calls, isEmpty);

      await service.stop();
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: false,
        PrefKeys.readAloudByMediaButton: true,
      });
      audio
        ..hasActivePlayback = true
        ..isPlaying = false;
      service = buildService(
        audio: audio,
        api: api,
        foreground: () => false,
      );
      await service.start();
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(audio.calls, isEmpty);
    });
  });

  group('[批9b-5] AudioNotifier.releaseMediaSession 保留语义', () {
    late MockRustApi api;
    late MockAudioService audioService;
    late FakeStreamAudioPlayer player;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      api = MockRustApi();
      audioService = MockAudioService();
      player = FakeStreamAudioPlayer();
      when(() => audioService.dispose()).thenAnswer((_) async {});
      when(() => audioService.notifyStopped()).thenAnswer((_) async {});
      when(() => audioService.abandonAudioFocus()).thenAnswer((_) async {});
      when(() => audioService.mediaButtonStream)
          .thenAnswer((_) => Stream<MediaButtonEvent>.empty());
      when(() => audioService.audioFocusStream)
          .thenAnswer((_) => Stream<AudioFocusEvent>.empty());
      container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          audioServiceProvider.overrideWithValue(audioService),
          streamAudioPlayerProvider.overrideWithValue(player),
        ],
      );
      addTearDown(container.dispose);
    });

    test('mediaButtonOnExit=true（默认）→ 保留会话，不 dispose', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
      });
      final notifier = container.read(audioNotifierProvider.notifier);
      await notifier.releaseMediaSession();
      verifyNever(() => audioService.dispose());
    });

    test('mediaButtonOnExit=false → 释放会话', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: false,
      });
      final notifier = container.read(audioNotifierProvider.notifier);
      await notifier.releaseMediaSession();
      verify(() => audioService.dispose()).called(1);
    });

    test('force=true 无视偏好强制释放', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.mediaButtonOnExit: true,
      });
      final notifier = container.read(audioNotifierProvider.notifier);
      await notifier.releaseMediaSession(force: true);
      verify(() => audioService.dispose()).called(1);
    });

    test('空闲态会话播放/切段键不盲目启动播放（交服务按偏好决策）', () async {
      final buttons = StreamController<MediaButtonEvent>.broadcast();
      addTearDown(buttons.close);
      when(() => audioService.mediaButtonStream)
          .thenAnswer((_) => buttons.stream);
      when(() => audioService.init()).thenAnswer((_) async {});
      when(() => audioService.isInitialized).thenReturn(true);

      final notifier = container.read(audioNotifierProvider.notifier);
      await notifier.initMediaSession();
      expect(container.read(audioNotifierProvider).isMediaSessionReady, isTrue);

      buttons.add(MediaButtonEvent.play);
      buttons.add(MediaButtonEvent.skipToNext);
      buttons.add(MediaButtonEvent.skipToPrevious);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(audioNotifierProvider).state, PlayerState.idle);
      verifyNever(() => api.getChapters(any()));
      verifyNever(() => audioService.notifyPlaying(position: any(named: 'position')));
    });
  });

  group('[批9b-5] 两开关默认值/持久化', () {
    test('默认值对齐原版 AppConfig：onExit=true、readAloud=false', () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await settings.getBoolPref(
          PrefKeys.mediaButtonOnExit,
          defaultValue: true,
        ),
        isTrue,
      );
      expect(
        await settings.getBoolPref(
          PrefKeys.readAloudByMediaButton,
          defaultValue: false,
        ),
        isFalse,
      );
    });

    test('写入后可读回（设置页持久化链路）', () async {
      SharedPreferences.setMockInitialValues({});
      await settings.setBoolPref(PrefKeys.mediaButtonOnExit, false);
      await settings.setBoolPref(PrefKeys.readAloudByMediaButton, true);
      expect(
        await settings.getBoolPref(
          PrefKeys.mediaButtonOnExit,
          defaultValue: true,
        ),
        isFalse,
      );
      expect(
        await settings.getBoolPref(
          PrefKeys.readAloudByMediaButton,
          defaultValue: false,
        ),
        isTrue,
      );
    });
  });
}
