// 系统 TTS 服务单测（设置批5a-1）
//
// 覆盖：
// 1) 引擎/音色列表空态与异常回落；
// 2) 合成缓存：同一文本+参数稳定文件名、命中不重复合成、参数变化重新合成；
// 3) 缓存统计/清理/LRU（超龄与超量）；
// 4) 合成失败（平台异常/空文件）→ SystemTtsException 且不留脏文件；
// 5) 无可用引擎 → SystemTtsUnavailableException；
// 6) 引擎/音色/语速/音调/音量真实下发到平台抽象（含 clearVoice/resetEngine）；
// 7) 参考刻度 ↔ UI 倍速/音调/音量换算（兼容旧 playSpeed 的读回口径）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/services/system_tts_service.dart';

/// 平台抽象 Fake：记录调用、按需写文件/抛异常
class FakeSystemTtsPlatform implements SystemTtsPlatform {
  FakeSystemTtsPlatform({
    this.engines = const [
      SystemTtsEngine(name: 'com.example.tts', label: '示例引擎'),
    ],
    this.voices = const [
      SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN'),
    ],
    this.supportsEngineSelection = true,
  });

  List<SystemTtsEngine> engines;
  List<SystemTtsVoice> voices;
  @override
  bool supportsEngineSelection;

  int initCount = 0;
  int synthCount = 0;
  int clearVoiceCount = 0;
  int resetEngineCount = 0;
  final List<String> setEngines = [];
  final List<SystemTtsVoice> setVoices = [];
  final List<double> rates = [];
  final List<double> pitches = [];
  final List<double> volumes = [];
  final List<String> synthTexts = [];

  /// 非空时 synthesizeToFile 抛出该异常
  Object? synthError;

  /// false 时只创建空文件（模拟合成失败产物）
  bool writeBytes = true;

  @override
  Future<void> init() async {
    initCount++;
  }

  @override
  Future<List<SystemTtsEngine>> getEngines() async => engines;

  @override
  Future<List<SystemTtsVoice>> getVoices() async => voices;

  @override
  Future<void> setEngine(String engineName) async {
    setEngines.add(engineName);
  }

  @override
  Future<void> resetEngine() async {
    resetEngineCount++;
  }

  @override
  Future<void> setVoice(SystemTtsVoice voice) async {
    setVoices.add(voice);
  }

  @override
  Future<void> clearVoice() async {
    clearVoiceCount++;
  }

  @override
  Future<void> setSpeechRate(double speed) async => rates.add(speed);

  @override
  Future<void> setPitch(double pitch) async => pitches.add(pitch);

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> synthesizeToFile(String text, String fullPath) async {
    synthCount++;
    synthTexts.add(text);
    final err = synthError;
    if (err != null) throw err;
    final file = File(fullPath);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(writeBytes ? [1, 2, 3, 4] : const []);
  }

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late FakeSystemTtsPlatform platform;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('system_tts_test');
    platform = FakeSystemTtsPlatform();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  SystemTtsService buildService({
    int maxCacheFiles = 50,
    Duration maxCacheAge = const Duration(hours: 48),
    SystemTtsPlatform? fake,
  }) {
    return SystemTtsService(
      platform: fake ?? platform,      baseDirectoryProvider: () async => tempDir,
      maxCacheFiles: maxCacheFiles,
      maxCacheAge: maxCacheAge,
    );
  }

  Future<String> synth(
    SystemTtsService service, {
    String text = '第一段朗读文本。',
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
  }) {
    return service.synthesizeToFile(
      text: text,
      speed: speed,
      pitch: pitch,
      volume: volume,
    );
  }

  group('引擎与音色列表', () {
    test('返回平台引擎/音色；空列表原样返回（页面走空态）', () async {
      final service = buildService();
      final engines = await service.engines();
      final voices = await service.voices();
      expect(engines.single.name, 'com.example.tts');
      expect(engines.single.displayName, '示例引擎');
      expect(voices.single.name, 'zh-cn-x');
      expect(voices.single.locale, 'zh-CN');

      platform.engines = const [];
      platform.voices = const [];
      final empty = buildService();
      expect(await empty.engines(), isEmpty);
      expect(await empty.voices(), isEmpty);
    });

    test('平台异常 → 空列表（不抛给页面）', () async {
      final throwing = _ThrowingPlatform();
      final service = buildService(fake: throwing);
      expect(await service.engines(), isEmpty);
      expect(await service.voices(), isEmpty);
      expect(await service.isAvailable(), isFalse);
    });

    test('无安装引擎 → isAvailable=false（合成抛 Unavailable）', () async {
      platform.engines = const [];
      final service = buildService();
      expect(await service.isAvailable(), isFalse);
      await expectLater(
        synth(service),
        throwsA(isA<SystemTtsUnavailableException>()),
      );
      expect(platform.synthCount, 0, reason: '无引擎不得尝试合成');
    });

    test('invalidateAvailability 后重新探测（用户新装引擎）', () async {
      platform.engines = const [];
      final service = buildService();
      expect(await service.isAvailable(), isFalse);
      platform.engines = const [
        SystemTtsEngine(name: 'com.example.tts', label: '示例引擎'),
      ];
      service.invalidateAvailability();
      expect(await service.isAvailable(), isTrue);
    });
  });

  group('合成缓存', () {
    test('同一文本+参数 → 稳定文件名且只合成一次', () async {
      final service = buildService();
      final first = await synth(service);
      final second = await synth(service);
      expect(second, first);
      expect(platform.synthCount, 1, reason: '第二次应命中缓存');
      expect(File(first).existsSync(), isTrue);
      expect(first.endsWith('.wav'), isTrue);
      expect(
        first,
        contains(SystemTtsService.cacheDirName),
        reason: '缓存应位于专用子目录',
      );
    });

    test('参数（语速/音调/音量/引擎/音色）变化 → 重新合成且文件名不同', () async {
      final service = buildService();
      final base = await synth(service);
      final faster = await synth(service, speed: 1.5);
      final higher = await synth(service, pitch: 1.3);
      final louder = await synth(service, volume: 0.4);
      expect({base, faster, higher, louder}, hasLength(4));
      expect(platform.synthCount, 4);

      await service.selectEngine('com.other.tts');
      final otherEngine = await synth(service);
      expect(otherEngine, isNot(base));
      expect(platform.setEngines, ['com.other.tts']);

      await service.selectVoice(
        const SystemTtsVoice(name: 'zh-cn-y', locale: 'zh-CN'),
      );
      final otherVoice = await synth(service);
      expect(otherVoice, isNot(otherEngine));
      expect(platform.setVoices.single.name, 'zh-cn-y');
    });

    test('相同文本的并发合成去重（只调平台一次）', () async {
      final service = buildService();
      final results = await Future.wait([
        synth(service),
        synth(service),
        synth(service),
      ]);
      expect(results.toSet(), hasLength(1));
      expect(platform.synthCount, 1);
    });

    test('平台异常 → SystemTtsException 且不留空文件', () async {
      platform.synthError = StateError('引擎崩溃');
      final service = buildService();
      await expectLater(
        synth(service),
        throwsA(
          isA<SystemTtsException>().having(
            (e) => e.message,
            'message',
            contains('系统 TTS 合成失败'),
          ),
        ),
      );
      final dir = Directory(
        '${tempDir.path}${Platform.pathSeparator}${SystemTtsService.cacheDirName}',
      );
      expect(
        dir.existsSync() ? dir.listSync().whereType<File>() : const <File>[],
        isEmpty,
        reason: '失败产物必须清理，避免下次误命中',
      );
    });

    test('平台未产出文件（0 字节）→ SystemTtsException', () async {
      platform.writeBytes = false;
      final service = buildService();
      await expectLater(
        synth(service),
        throwsA(
          isA<SystemTtsException>().having(
            (e) => e.message,
            'message',
            contains('未生成音频文件'),
          ),
        ),
      );
    });

    test('空白文本 → SystemTtsException（不触平台）', () async {
      final service = buildService();
      await expectLater(
        synth(service, text: '   '),
        throwsA(isA<SystemTtsException>()),
      );
      expect(platform.synthCount, 0);
    });
  });

  group('缓存统计/清理/LRU', () {
    test('统计文件数与字节；清理后归零', () async {
      final service = buildService();
      await synth(service, text: 'A');
      await synth(service, text: 'B');
      final stats = await service.cacheStats();
      expect(stats.fileCount, 2);
      expect(stats.totalBytes, 8);

      final deleted = await service.clearCache();
      expect(deleted, 2);
      final after = await service.cacheStats();
      expect(after.fileCount, 0);
      expect(after.totalBytes, 0);
    });

    test('pruneCache 删除超龄文件', () async {
      // 先用宽松配置造文件（避免合成后的自动 prune 提前删掉旧文件）
      final creator = buildService(
        maxCacheFiles: 100,
        maxCacheAge: const Duration(days: 365),
      );
      final oldPath = await synth(creator, text: '旧段落');
      File(oldPath).setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 3)),
      );
      final freshPath = await synth(creator, text: '新段落');

      final service = buildService(maxCacheAge: const Duration(hours: 1));
      final deleted = await service.pruneCache();
      expect(deleted, 1);
      expect(File(oldPath).existsSync(), isFalse);
      expect(File(freshPath).existsSync(), isTrue);
    });

    test('pruneCache 超量时按最近修改时间保留最新 N 个', () async {
      final creator = buildService(
        maxCacheFiles: 100,
        maxCacheAge: const Duration(days: 365),
      );
      final paths = <String>[];
      for (var i = 0; i < 4; i++) {
        final path = await synth(creator, text: '段落$i');
        File(path).setLastModifiedSync(
          DateTime.now().subtract(Duration(minutes: 10 - i)),
        );
        paths.add(path);
      }
      final service = buildService(
        maxCacheFiles: 2,
        maxCacheAge: const Duration(days: 365),
      );
      final deleted = await service.pruneCache();
      expect(deleted, 2);
      expect(File(paths[0]).existsSync(), isFalse);
      expect(File(paths[1]).existsSync(), isFalse);
      expect(File(paths[2]).existsSync(), isTrue);
      expect(File(paths[3]).existsSync(), isTrue);
      final stats = await service.cacheStats();
      expect(stats.fileCount, 2);
    });
  });

  group('平台参数下发与选择持久化', () {
    test('引擎/音色/语速/音调/音量真实下发；重复合成不重复下发', () async {
      final service = buildService();
      await service.selectEngine('com.example.tts');
      await service.selectVoice(
        const SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN'),
      );
      await synth(service, speed: 2.0, pitch: 1.4, volume: 0.3);
      expect(platform.setEngines, ['com.example.tts']);
      expect(platform.setVoices.single.name, 'zh-cn-x');
      expect(platform.rates, [2.0]);
      expect(platform.pitches, [1.4]);
      expect(platform.volumes, [0.3]);

      // 同参数再次合成（缓存命中）不重复下发
      await synth(service, speed: 2.0, pitch: 1.4, volume: 0.3);
      expect(platform.rates, [2.0]);
      expect(platform.pitches, [1.4]);
      expect(platform.volumes, [0.3]);
    });

    test('切回系统默认：resetEngine + clearVoice', () async {
      final service = buildService();
      await service.selectEngine('com.example.tts');
      await service.selectVoice(
        const SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN'),
      );
      await synth(service);
      expect(platform.setEngines, ['com.example.tts']);
      expect(platform.setVoices, hasLength(1));

      await service.selectEngine(null);
      await service.selectVoice(null);
      await synth(service, text: '切换默认后');
      expect(platform.resetEngineCount, 1);
      expect(platform.clearVoiceCount, 1);
    });

    test('选择态持久化到 SharedPreferences 并可读回', () async {
      final service = buildService();
      await service.selectEngine('com.example.tts');
      await service.selectVoice(
        const SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN'),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.systemTtsEngine), 'com.example.tts');
      expect(prefs.getString(PrefKeys.systemTtsVoice), 'zh-cn-x');
      expect(prefs.getString(PrefKeys.systemTtsVoiceLocale), 'zh-CN');

      final reloaded = buildService();
      await reloaded.loadSelection();
      expect(reloaded.selectedEngineName, 'com.example.tts');
      expect(reloaded.selectedVoice?.name, 'zh-cn-x');
      expect(reloaded.selectedVoice?.locale, 'zh-CN');
    });

    test('清空选择会移除持久化键', () async {
      final service = buildService();
      await service.selectEngine('com.example.tts');
      await service.selectVoice(
        const SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN'),
      );
      await service.selectEngine(null);
      await service.selectVoice(null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.systemTtsEngine), isNull);
      expect(prefs.getString(PrefKeys.systemTtsVoice), isNull);
      expect(prefs.getString(PrefKeys.systemTtsVoiceLocale), isNull);
    });
  });

  group('刻度换算（兼容旧 playSpeed）', () {
    test('语速 0.5–3.0x ↔ 参考刻度 0–80', () {
      expect(ttsSpeechRateFromSpeed(0.5), 0);
      expect(ttsSpeechRateFromSpeed(1.0), 16);
      expect(ttsSpeechRateFromSpeed(3.0), 80);
      expect(ttsSpeechRateFromSpeed(9.0), 80, reason: '越界收敛');
      expect(ttsSpeedFromSpeechRate(0), 0.5);
      expect(ttsSpeedFromSpeechRate(16), closeTo(1.0, 0.001));
      expect(ttsSpeedFromSpeechRate(80), 3.0);
      expect(ttsSpeedFromSpeechRate(null), 1.0, reason: '缺失回退默认');
      expect(ttsSpeedFromSpeechRate(-5), 0.5, reason: '脏值收敛');
    });

    test('音调 0.5–2.0 ↔ 参考刻度 5–20', () {
      expect(ttsPitchToStored(0.5), 5);
      expect(ttsPitchToStored(1.0), 10);
      expect(ttsPitchToStored(2.0), 20);
      expect(ttsPitchToStored(5.0), 20, reason: '越界收敛');
      expect(ttsPitchFromStored(10), 1.0);
      expect(ttsPitchFromStored(null), 1.0);
      expect(ttsPitchFromStored(99), 2.0);
    });

    test('音量 0–1 ↔ 参考刻度 0–100', () {
      expect(ttsVolumeToStored(0.0), 0);
      expect(ttsVolumeToStored(0.5), 50);
      expect(ttsVolumeToStored(1.0), 100);
      expect(ttsVolumeToStored(3.0), 100, reason: '越界收敛');
      expect(ttsVolumeFromStored(0), 0.0);
      expect(ttsVolumeFromStored(50), 0.5);
      expect(ttsVolumeFromStored(null), 1.0);
    });
  });
}

/// 所有方法抛异常的平台（探测失败路径）
class _ThrowingPlatform implements SystemTtsPlatform {
  @override
  bool get supportsEngineSelection => true;

  @override
  Future<void> init() async => throw StateError('init failed');

  @override
  Future<List<SystemTtsEngine>> getEngines() async =>
      throw StateError('engines failed');

  @override
  Future<List<SystemTtsVoice>> getVoices() async =>
      throw StateError('voices failed');

  @override
  Future<void> setEngine(String engineName) async =>
      throw StateError('setEngine failed');

  @override
  Future<void> resetEngine() async => throw StateError('resetEngine failed');

  @override
  Future<void> setVoice(SystemTtsVoice voice) async =>
      throw StateError('setVoice failed');

  @override
  Future<void> clearVoice() async => throw StateError('clearVoice failed');

  @override
  Future<void> setSpeechRate(double speed) async =>
      throw StateError('rate failed');

  @override
  Future<void> setPitch(double pitch) async => throw StateError('pitch failed');

  @override
  Future<void> setVolume(double volume) async =>
      throw StateError('volume failed');

  @override
  Future<void> synthesizeToFile(String text, String fullPath) async =>
      throw StateError('synth failed');

  @override
  Future<void> stop() async {}
}
