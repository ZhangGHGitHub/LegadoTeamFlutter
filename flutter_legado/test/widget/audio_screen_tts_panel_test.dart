// TTS P3（2026-11-11）：听书页面板「音调/音量落库」与「内联引擎选择」
//
// 覆盖：
// a) 音调/音量滑条 onChangeEnd 写入既有 prefs 键（ttsPitch/ttsVolume），
//    新会话 initMediaSession 读回（冷启动等价）；
// b) 引擎列表为空（无系统 TTS + 无 HTTP 引擎）→ 显示「未检测到可用语音
//    引擎」且不可点击，不崩溃（MuMu 无 TTS 引擎场景的 UI 侧兜底）；
// c) HTTP 引擎选择 → setGlobalTtsEngine（落 config:appTtsEngine）并即时
//    更新面板引擎名；
// d) 系统引擎选择 → 先 selectEngine（持久化 systemTtsEngine）再切全局
//    系统 TTS 哨兵，面板显示具体引擎名。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';
import 'package:flutter_legado/src/services/audio_service.dart';
import 'package:flutter_legado/src/services/system_tts_service.dart';

import '../mocks/mocks.dart';

/// 平台抽象占位：引擎列表由 FakeSystemTts 覆盖，不触真实平台通道
class _NoopPlatform implements SystemTtsPlatform {
  @override
  bool get supportsEngineSelection => true;

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

  @override
  Future<void> resetClient() async {}
}

/// 系统 TTS 假服务：可配置引擎列表，记录选择
class _FakeSystemTts extends SystemTtsService {
  _FakeSystemTts({this.engineList = const []})
    : super(
        platform: _NoopPlatform(),
        baseDirectoryProvider: () async => Directory.systemTemp,
      );

  final List<SystemTtsEngine> engineList;
  String? selected;

  @override
  Future<List<SystemTtsEngine>> engines() async => engineList;

  @override
  Future<void> loadSelection() async {}

  @override
  String? get selectedEngineName => selected;

  @override
  Future<List<SystemTtsVoice>?> selectEngine(String? engineName) async {
    selected = engineName;
    return const [];
  }

  @override
  Future<void> stop() async {}
}

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late MockAudioService audioService;
  late _FakeSystemTts systemTts;
  late ProviderContainer container;

  const book = Book(bookUrl: 'https://book.example.com/a', name: '测试书');

  ProviderContainer buildContainer() => ProviderContainer(
    overrides: [
      bookApiProvider.overrideWithValue(api),
      streamAudioPlayerProvider.overrideWithValue(FakeStreamAudioPlayer()),
      systemTtsServiceProvider.overrideWithValue(systemTts),
      audioServiceProvider.overrideWithValue(audioService),
    ],
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'httpTtsSeedVersion': 1,
      'enableReadRecord': false,
    });
    api = MockRustApi();
    systemTts = _FakeSystemTts();
    audioService = MockAudioService();
    container = buildContainer();
    addTearDown(container.dispose);

    // 音频会话用 Mock：真实 MethodChannel 在测试 zone 无 handler 时
    // invokeMethod 不返回，会阻塞 initMediaSession。
    when(() => audioService.init()).thenAnswer((_) async {});
    when(() => audioService.isInitialized).thenReturn(true);
    when(
      () => audioService.mediaButtonStream,
    ).thenAnswer((_) => const Stream<MediaButtonEvent>.empty());
    when(
      () => audioService.audioFocusStream,
    ).thenAnswer((_) => const Stream<AudioFocusEvent>.empty());
    when(() => audioService.requestAudioFocus()).thenAnswer((_) async => true);
    when(
      () => audioService.updateMetadata(
        title: any(named: 'title'),
        artist: any(named: 'artist'),
        album: any(named: 'album'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => audioService.notifyPlaying(position: any(named: 'position')),
    ).thenAnswer((_) async {});
    when(
      () => audioService.notifyPaused(position: any(named: 'position')),
    ).thenAnswer((_) async {});
    when(() => audioService.notifyStopped()).thenAnswer((_) async {});
    when(() => audioService.setPlaying(any())).thenAnswer((_) async {});
    when(
      () => audioService.updatePlaybackState(
        state: any(named: 'state'),
        position: any(named: 'position'),
      ),
    ).thenAnswer((_) async {});
    when(() => audioService.abandonAudioFocus()).thenAnswer((_) async {});
    when(() => audioService.dispose()).thenAnswer((_) async {});
    when(() => audioService.setWakeLock(any())).thenAnswer((_) async {});

    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.updateBook(any())).thenAnswer((_) async {});
    when(() => api.getHttpTts()).thenAnswer((_) async => const []);
    when(
      () => api.getChapters(any()),
    ).thenAnswer((_) async => [const BookChapter(title: '第一章', index: 0)]);
  });

  AudioState readState() => container.read(audioNotifierProvider);

  Future<void> pumpAudioScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AudioScreen(book: book)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 固定帧推进（不用 pumpAndSettle：面板加载态含 indeterminate 进度圈，
  /// pumpAndSettle 会一直等到 10 分钟超时）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  final engineRow = find.byKey(const ValueKey('audio-tts-engine-row'));

  group('音调/音量落库并可读回', () {
    testWidgets('拖动结束写 ttsSpeechRate/ttsPitch/ttsVolume，新会话读回', (tester) async {
      await pumpAudioScreen(tester);
      await openSettings(tester);

      final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
      expect(sliders.length, greaterThanOrEqualTo(3), reason: '语速/音调/音量三条滑条');

      // 语速 2.0x → 参考刻度 15（听书页面板自身也落库）
      sliders[0].onChanged!(2.0);
      await tester.pump();
      tester.widgetList<Slider>(find.byType(Slider)).elementAt(0).onChangeEnd!(
        2.0,
      );
      await settle(tester);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.ttsSpeechRate), ttsSpeechRateFromSpeed(2.0));

      // 音调 1.3 → 参考刻度 13
      sliders[1].onChanged!(1.3);
      await tester.pump();
      tester.widgetList<Slider>(find.byType(Slider)).elementAt(1).onChangeEnd!(
        1.3,
      );
      await settle(tester);

      expect(prefs.getInt(PrefKeys.ttsPitch), ttsPitchToStored(1.3));
      // 音量 0.4 → 参考刻度 40
      tester.widgetList<Slider>(find.byType(Slider)).elementAt(2).onChangeEnd!(
        0.4,
      );
      await settle(tester);
      expect(prefs.getInt(PrefKeys.ttsVolume), ttsVolumeToStored(0.4));

      // 冷启动等价：全新容器 initMediaSession 读回持久化参数
      final restarted = buildContainer();
      addTearDown(restarted.dispose);
      await restarted.read(audioNotifierProvider.notifier).initMediaSession();

      final config = restarted.read(audioNotifierProvider).config;
      expect(config.speed, closeTo(2.0, 0.001));
      expect(config.pitch, closeTo(1.3, 0.001));
      expect(config.volume, closeTo(0.4, 0.001));
    });
  });

  group('退出听书页媒体会话释放', () {
    testWidgets('空闲态销毁页面 → 释放媒体会话且无框架断言', (tester) async {
      await pumpAudioScreen(tester);
      expect(readState().state, PlayerState.idle);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pump();

      verify(() => audioService.dispose()).called(1);
      expect(tester.takeException(), isNull);
    });
  });

  group('内联引擎选择', () {
    testWidgets('系统/HTTP 引擎皆空 → 显示未检测到可用语音引擎且禁用选择', (tester) async {
      await pumpAudioScreen(tester);
      await openSettings(tester);

      expect(find.text('未检测到可用语音引擎'), findsOneWidget);
      final tile = tester.widget<ListTile>(engineRow);
      expect(tile.enabled, isFalse);
      expect(tile.onTap, isNull);

      // 点击禁用行不弹选择框、不抛异常
      await tester.tap(engineRow);
      await settle(tester);
      expect(find.text('选择朗读引擎'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('选择 HTTP 引擎 → 立即切换并持久化 appTtsEngine', (tester) async {
      const url = 'https://tts.example.com/speak?text={{text}}';
      when(
        () => api.getHttpTts(),
      ).thenAnswer((_) async => const [HttpTts(name: 'HTTP引擎A', url: url)]);

      await pumpAudioScreen(tester);
      await openSettings(tester);
      expect(find.text('系统 TTS（未检测到可用引擎）'), findsOneWidget);

      await tester.tap(engineRow);
      await settle(tester);
      expect(find.text('选择朗读引擎'), findsOneWidget);

      await tester.tap(find.text('HTTP引擎A'));
      await settle(tester);

      expect(readState().config.engineUrl, url, reason: '选中后会话配置立即指向该引擎');
      verify(() => api.setConfig(kTtsEngineConfigKey, url)).called(1);
      expect(find.text('HTTP引擎A'), findsOneWidget, reason: '面板回显引擎名');
    });

    testWidgets('选择系统引擎 → 先落系统引擎选择再切全局系统 TTS', (tester) async {
      systemTts = _FakeSystemTts(
        engineList: const [
          SystemTtsEngine(name: 'com.test.tts', label: '测试引擎'),
        ],
      );
      // 重建容器使新 fake 生效
      container = buildContainer();
      addTearDown(container.dispose);

      await pumpAudioScreen(tester);
      await openSettings(tester);

      await tester.tap(engineRow);
      await settle(tester);
      expect(find.text('测试引擎'), findsOneWidget);

      await tester.tap(find.text('测试引擎'));
      await settle(tester);

      expect(systemTts.selected, 'com.test.tts');
      verify(
        () => api.setConfig(kTtsEngineConfigKey, kSystemTtsEngineUrl),
      ).called(1);
      expect(find.text('测试引擎'), findsOneWidget, reason: '面板回显具体系统引擎名');
      expect(readState().config.engineUrl, kSystemTtsEngineUrl);
    });
  });
}
