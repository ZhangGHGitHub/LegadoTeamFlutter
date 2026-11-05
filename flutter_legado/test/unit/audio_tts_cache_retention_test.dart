// 系统 TTS 缓存保留策略测试（设置批5c）
//
// 覆盖：
// 1) 非 0 保留时间：启动朗读时按设置执行 pruneByRetention；
// 2) 0 即听即焚：每段播放完成后删除该段产物；
// 3) 播放失败/估算推进：已合成但未播出的产物同样删除；
// 4) stop：清理本次会话尚未删除的临时文件；
// 5) 设置页/服务清理不得删除正在播放的文件（由 keepPath 语义单测覆盖）。
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
import 'package:flutter_legado/src/services/system_tts_service.dart';

import '../mocks/mocks.dart';

/// 平台抽象占位（Fake 服务覆盖合成，不使用平台）
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

  @override
  Future<void> resetClient() async {}
}

/// 系统 TTS 服务 Fake：记录合成路径、删除与保留时间清理调用
class _FakeCacheTtsService extends SystemTtsService {
  _FakeCacheTtsService()
    : super(
        platform: _NoopPlatform(),
        baseDirectoryProvider: () async => Directory.systemTemp,
      );

  final List<String> synthesized = [];
  final List<String> deleted = [];
  final List<({int minutes, String? keepPath})> prunes = [];
  final List<String?> clearKeepPaths = [];

  /// 非空时所有合成返回同一路径（模拟缓存复用）
  String? fixedPath;

  @override
  Future<int> clearCache({String? keepPath}) async {
    clearKeepPaths.add(keepPath);
    return 0;
  }

  @override
  Future<String> synthesizeToFile({
    required String text,
    required double speed,
    required double pitch,
    required double volume,
  }) async {
    final path =
        fixedPath ?? '/cache/system_tts/seg_${synthesized.length + 1}.wav';
    if (!synthesized.contains(path)) synthesized.add(path);
    return path;
  }

  @override
  Future<bool> deleteCacheFile(String path, {String? keepPath}) async {
    deleted.add(path);
    return true;
  }

  @override
  Future<int> pruneByRetention(int retentionMinutes, {String? keepPath}) async {
    prunes.add((minutes: retentionMinutes, keepPath: keepPath));
    return 0;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRustApi api;
  late FakeStreamAudioPlayer fakePlayer;
  late MockAudioService audioService;
  late _FakeCacheTtsService fakeTts;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    fakePlayer = FakeStreamAudioPlayer();
    fakeTts = _FakeCacheTtsService();
    audioService = MockAudioService();
    // 保留时间由媒体会话初始化读回；平台动作打成空实现，避免测试 zone 等待。
    when(() => audioService.init()).thenAnswer((_) async {});
    when(() => audioService.isInitialized).thenReturn(false);
    when(
      () => audioService.mediaButtonStream,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => audioService.audioFocusStream,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => audioService.playbackActiveStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => audioService.playbackActive).thenReturn(false);
    when(() => audioService.requestAudioFocus()).thenAnswer((_) async => true);
    when(() => audioService.abandonAudioFocus()).thenAnswer((_) async {});
    when(() => audioService.setWakeLock(any())).thenAnswer((_) async {});
    when(
      () => audioService.notifyPlaying(position: any(named: 'position')),
    ).thenAnswer((_) async {});
    when(
      () => audioService.notifyPaused(position: any(named: 'position')),
    ).thenAnswer((_) async {});
    when(() => audioService.notifyStopped()).thenAnswer((_) async {});
    when(
      () => audioService.updateMetadata(
        title: any(named: 'title'),
        artist: any(named: 'artist'),
        album: any(named: 'album'),
      ),
    ).thenAnswer((_) async {});
    when(() => audioService.dispose()).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        streamAudioPlayerProvider.overrideWithValue(fakePlayer),
        systemTtsServiceProvider.overrideWithValue(fakeTts),
        audioServiceProvider.overrideWithValue(audioService),
      ],
    );
    addTearDown(container.dispose);

    when(
      () => api.getChapters(any()),
    ).thenAnswer((_) async => [const BookChapter(title: '第一章', index: 0)]);
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.getConfig(any())).thenAnswer((_) async => null);
  });

  AudioNotifier readNotifier() =>
      container.read(audioNotifierProvider.notifier);

  Future<void> startTts(String content) async {
    when(
      () => api.getChapterContentFull(any(), any()),
    ).thenAnswer((_) async => content);
    await readNotifier().loadChapters('url');
    readNotifier().updateConfig(engineUrl: kSystemTtsEngineUrl);
    // 保留时间在媒体会话初始化的偏好读回中加载（与真实入口一致）
    await readNotifier().initMediaSession(bookName: '测试书');
    await readNotifier().play();
    expect(readNotifier().paragraphCount, greaterThan(0));
  }

  testWidgets('非 0 保留时间：启动朗读按设置值执行清理', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readAloudCacheRetentionMinutes: 30,
    });
    await startTts('第一段内容。');
    await tester.pump();
    await tester.pump();

    expect(fakeTts.prunes, isNotEmpty);
    expect(fakeTts.prunes.last.minutes, 30);
    readNotifier().stop();
    await tester.pump();
  });

  testWidgets('0 即听即焚：每段播放完成立即删除该段产物', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readAloudCacheRetentionMinutes: 0,
    });
    await startTts('第一段内容。\n\n第二段内容。');
    await tester.pump();
    await tester.pump();
    expect(fakeTts.synthesized, hasLength(1));
    expect(fakeTts.deleted, isEmpty);

    // 首段自然播完 → 删除首段文件，继续第二段
    fakePlayer.completePlayback();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(fakeTts.deleted, contains(fakeTts.synthesized[0]));
    expect(fakeTts.synthesized, hasLength(2));
    expect(readNotifier().currentParagraphIndex, 1);

    // stop：清理本次会话尚未删除的第二段临时文件
    readNotifier().stop();
    await tester.pump();
    await tester.pump();
    expect(fakeTts.deleted, contains(fakeTts.synthesized[1]));
  });

  testWidgets('0 模式播放失败/估算推进：已合成产物也删除并提示', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readAloudCacheRetentionMinutes: 0,
    });
    fakePlayer.playLocalError = StateError('本地播放失败');
    await startTts('只有一段内容。');
    await tester.pump();
    await tester.pump();

    expect(fakeTts.deleted, contains(fakeTts.synthesized.single));
    expect(
      container.read(audioNotifierProvider).errorMessage,
      contains('系统 TTS 朗读失败'),
    );

    readNotifier().stop();
    await tester.pump();
  });

  testWidgets('0 模式会话起手清理旧残留，同进程只执行一次', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readAloudCacheRetentionMinutes: 0,
    });
    await readNotifier().initMediaSession(bookName: '测试书');
    await tester.pump();

    expect(fakeTts.clearKeepPaths, hasLength(1));
    // 第二次初始化不得重复全量清空
    await readNotifier().initMediaSession(bookName: '测试书');
    await tester.pump();
    expect(fakeTts.clearKeepPaths, hasLength(1));
  });

  testWidgets('0 模式 stop→立即 play 复用同路径：旧清理不删新会话文件', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readAloudCacheRetentionMinutes: 0,
    });
    fakeTts.fixedPath = '/cache/system_tts/shared.wav';
    await startTts('第一段内容。');

    // 卡住 stop，让旧清理尚未执行时新会话立即 play（同路径复用）
    fakePlayer.stopGate = Completer<void>();
    readNotifier().stop();
    final playFuture = readNotifier().play();
    fakePlayer.stopGate!.complete();
    await playFuture;
    await tester.pump();
    await tester.pump();

    expect(fakeTts.deleted, isNot(contains(fakeTts.fixedPath)));
    expect(readNotifier().paragraphCount, 1);

    readNotifier().stop();
    await tester.pump();
  });
}
