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
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
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
    this.supportsSynthesis = true,
  });

  List<SystemTtsEngine> engines;
  List<SystemTtsVoice> voices;
  @override
  bool supportsEngineSelection;

  @override
  bool supportsSynthesis;

  int initCount = 0;
  int synthCount = 0;
  int stopCount = 0;
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

  /// 非空时 setVoice 抛出该异常（模拟音色失效）
  Object? setVoiceError;

  /// false 时只创建空文件（模拟合成失败产物）
  bool writeBytes = true;

  /// 非空时仅第一次 synthesizeToFile 等待该闸门（模拟 flutter_tts
  /// 永不完成；后续调用立即完成，便于验证 stop 后新合成）
  Completer<void>? synthGate;

  /// 非空时 setEngine 等待该闸门（模拟引擎初始化永不返回）
  Completer<void>? setEngineGate;

  /// 仅第一次合成抛出的异常（模拟 stop 后旧任务失败）
  Object? firstSynthError;

  /// 并发合成计数（串行队列断言）
  int _running = 0;
  int maxConcurrent = 0;

  /// 按引擎返回不同音色（key=引擎包名；未配置时用 [voices]）
  Map<String, List<SystemTtsVoice>> voicesByEngine = const {};
  String? _currentEngine;

  @override
  Future<void> init() async {
    initCount++;
  }

  @override
  Future<List<SystemTtsEngine>> getEngines() async => engines;

  @override
  Future<List<SystemTtsVoice>> getVoices() async {
    final perEngine = voicesByEngine[_currentEngine];
    return perEngine ?? voices;
  }

  @override
  Future<void> setEngine(String engineName) async {
    setEngines.add(engineName);
    final gate = setEngineGate;
    if (gate != null) await gate.future;
    _currentEngine = engineName;
  }

  @override
  Future<void> resetEngine() async {
    resetEngineCount++;
  }

  @override
  Future<void> setVoice(SystemTtsVoice voice) async {
    final err = setVoiceError;
    if (err != null) throw err;
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
    _running++;
    if (_running > maxConcurrent) maxConcurrent = _running;
    try {
      final gate = synthGate;
      // 仅第一次合成挂起：stop 后新合成必须真实可完成
      if (gate != null && synthCount == 1) await gate.future;
      final err = (synthCount == 1 ? firstSynthError : null) ?? synthError;
      if (err != null) throw err;
      final file = File(fullPath);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(writeBytes ? [1, 2, 3, 4] : const []);
    } finally {
      _running--;
    }
  }

  @override
  Future<void> stop() async {
    // 审查回修 P3：stop 不完成合成闸门，模拟「stop 无法取消挂起合成」
    stopCount++;
  }
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
    Duration synthesisTimeout = const Duration(seconds: 45),
  }) {
    return SystemTtsService(
      platform: fake ?? platform,
      baseDirectoryProvider: () async => tempDir,
      maxCacheFiles: maxCacheFiles,
      maxCacheAge: maxCacheAge,
      synthesisTimeout: synthesisTimeout,
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
      // 引擎重建后音色已随新实例回默认，无需再 clearVoice
      expect(platform.resetEngineCount, 1);
      expect(platform.clearVoiceCount, 0);
    });

    test('仅切回默认音色（不改引擎）：clearVoice 恢复默认', () async {
      final service = buildService();
      await service.selectVoice(
        const SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN'),
      );
      await synth(service, text: '音色A');
      expect(platform.setVoices, hasLength(1));

      await service.selectVoice(null);
      await synth(service, text: '默认音色');
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


  group('审查回修 P1/P2 回归', () {
    test('P1-1 合成永不完成 → 超时 + stop 复位 + 抛 SystemTtsException', () async {
      platform.synthGate = Completer<void>();
      final service = buildService(
        synthesisTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        synth(service),
        throwsA(
          isA<SystemTtsException>().having(
            (e) => e.message,
            'message',
            contains('超时'),
          ),
        ),
      );
      expect(platform.stopCount, greaterThanOrEqualTo(1),
          reason: '超时必须 stop 复位 flutter_tts busy');
      final dir = Directory(
        '${tempDir.path}${Platform.pathSeparator}${SystemTtsService.cacheDirName}',
      );
      expect(
        dir.existsSync() ? dir.listSync().whereType<File>() : const <File>[],
        isEmpty,
      );
      // 释放挂起的 fake 合成，避免遗留 future
      if (!platform.synthGate!.isCompleted) platform.synthGate!.complete();
    });

    test('P1-2 切引擎后重新下发音色/语速/音调/音量', () async {
      final service = buildService();
      await service.selectEngine('com.example.tts');
      await service.selectVoice(
        const SystemTtsVoice(name: 'zh-cn-x', locale: 'zh-CN'),
      );
      await synth(service, text: 'A', speed: 2.0, pitch: 1.2, volume: 0.5);
      expect(platform.rates, [2.0]);
      expect(platform.pitches, [1.2]);
      expect(platform.volumes, [0.5]);
      expect(platform.setVoices, hasLength(1));

      // 切引擎：新 TextToSpeech 实例参数归默认，必须全部重新下发
      await service.selectEngine('com.other.tts');
      await synth(service, text: 'B', speed: 2.0, pitch: 1.2, volume: 0.5);
      expect(platform.rates, [2.0, 2.0]);
      expect(platform.pitches, [1.2, 1.2]);
      expect(platform.volumes, [0.5, 0.5]);
      expect(platform.setVoices, hasLength(2));
    });

    test('P2-1 平台不支持合成（Windows）→ 不可用且不初始化', () async {
      platform.supportsSynthesis = false;
      final service = buildService();
      expect(await service.isAvailable(), isFalse);
      expect(platform.initCount, 0);
      await expectLater(
        synth(service),
        throwsA(isA<SystemTtsUnavailableException>()),
      );
    });

    test('P2-1 FlutterTts 平台合成支持判定（Windows/Linux 不支持）', () {
      final p = FlutterTtsSystemTtsPlatform();
      for (final entry in <TargetPlatform, bool>{
        TargetPlatform.android: true,
        TargetPlatform.iOS: true,
        TargetPlatform.macOS: true,
        TargetPlatform.windows: false,
        TargetPlatform.linux: false,
      }.entries) {
        debugDefaultTargetPlatformOverride = entry.key;
        try {
          expect(p.supportsSynthesis, entry.value, reason: '${entry.key}');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test('P2-1 init 失败复位 _initDone，允许重试', () async {
      final fakeTts = _FakeFlutterTts();
      final p = FlutterTtsSystemTtsPlatform(tts: fakeTts);
      await expectLater(p.init(), throwsStateError);
      await p.init();
      expect(fakeTts.synthCompletionCalls, 2, reason: '第二次必须真正重试');
    });

    test('P2-6 跨 key 合成串行（同 key 仍去重）', () async {
      platform.synthGate = Completer<void>();
      final service = buildService();
      final first = synth(service, text: 'A');
      final second = synth(service, text: 'B');
      final duplicate = synth(service, text: 'A');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(platform.maxConcurrent, 1, reason: '任意时刻只允许一次平台合成');
      platform.synthGate!.complete();
      await Future.wait([first, second, duplicate]);
      expect(platform.synthCount, 2, reason: 'A 的重复请求合并');
    });

    test('P2-B stop 不完成挂起合成 → 新合成成功且旧任务清理不误删', () async {
      platform.synthGate = Completer<void>();
      platform.firstSynthError = StateError('old synth failed');
      final service = buildService(
        synthesisTimeout: const Duration(seconds: 5),
      );
      // 旧任务挂起（fake stop 不完成闸门），错误由 catchError 吞掉
      final first = synth(service, text: 'A').catchError((Object _) => '');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.stop();

      final second = await synth(service, text: 'B');
      expect(second, isNotEmpty);
      expect(File(second).existsSync(), isTrue);
      expect(platform.synthCount, 2);

      // 释放旧任务：其失败清理发生在旧代际，不得删除新代际文件
      platform.synthGate!.complete();
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        File(second).existsSync(),
        isTrue,
        reason: '旧代际失败清理不得删除新合成产物',
      );
    });


    test('P2-A setEngine 永不返回 → selectEngine 超时回滚并返回 null', () async {
      platform.setEngineGate = Completer<void>();
      final service = buildService(
        synthesisTimeout: const Duration(milliseconds: 50),
      );
      final voices = await service.selectEngine('com.hang.tts');
      expect(voices, isNull);
      expect(service.selectedEngineName, isNull, reason: '失败需回滚选择');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.systemTtsEngine), isNull);
      expect(platform.stopCount, greaterThanOrEqualTo(1),
          reason: '引擎初始化超时需 stop 复位');
      if (!platform.setEngineGate!.isCompleted) {
        platform.setEngineGate!.complete();
      }
    });

    test('P2-A 合成路径 setEngine 永不返回 → 引擎初始化超时', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.systemTtsEngine: 'com.hang.tts',
      });
      platform.setEngineGate = Completer<void>();
      final service = buildService(
        synthesisTimeout: const Duration(milliseconds: 50),
      );
      await service.loadSelection();
      await expectLater(
        synth(service),
        throwsA(
          isA<SystemTtsException>().having(
            (e) => e.message,
            'message',
            contains('引擎初始化超时'),
          ),
        ),
      );
      expect(platform.stopCount, greaterThanOrEqualTo(1));
      if (!platform.setEngineGate!.isCompleted) {
        platform.setEngineGate!.complete();
      }
    });

    test('P3 引擎切换进串行队列，不打断在途合成', () async {
      platform.synthGate = Completer<void>();
      final service = buildService();
      final synthFuture = synth(service, text: 'A');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final selectFuture = service.selectEngine('com.other.tts');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(platform.setEngines, isEmpty,
          reason: '在途合成未完成前不得替换 TTS 实例');

      platform.synthGate!.complete();
      await synthFuture;
      final voices = await selectFuture;
      expect(voices, isNotNull);
      expect(platform.setEngines, ['com.other.tts']);
    });

    test('P3 stop 清空一次性提示，避免跨会话迟到提示', () async {
      const voiceA = SystemTtsVoice(name: 'a', locale: 'zh-CN');
      platform.voicesByEngine = const {
        'engine-a': [voiceA],
        'engine-b': <SystemTtsVoice>[],
      };
      final service = buildService();
      await service.selectEngine('engine-a');
      await service.selectVoice(voiceA);
      await synth(service, text: 'A');
      await service.selectEngine('engine-b');
      expect(service.takeNotice(), isNotNull);

      // 再制造一条提示后 stop 清空
      await service.selectEngine('engine-a');
      await service.selectVoice(voiceA);
      await synth(service, text: 'B');
      await service.selectEngine('engine-b');
      expect(service.takeNotice(), isNotNull);
      await service.stop();
      expect(service.takeNotice(), isNull);
    });

    test('P2-7 切引擎刷新音色；已选音色不在新列表则清除并提示一次', () async {
      const voiceA = SystemTtsVoice(name: 'a', locale: 'zh-CN');
      const voiceB = SystemTtsVoice(name: 'b', locale: 'zh-CN');
      platform.voicesByEngine = const {
        'engine-a': [voiceA],
        'engine-b': [voiceB],
      };
      final service = buildService();
      await service.selectEngine('engine-a');
      await service.selectVoice(voiceA);
      await synth(service, text: 'A');

      final voices = await service.selectEngine('engine-b');
      expect(voices, [voiceB]);
      expect(service.selectedVoice, isNull);
      expect(service.takeNotice(), contains('回退'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(PrefKeys.systemTtsVoice), isNull);
      expect(service.takeNotice(), isNull, reason: '提示只消费一次');
    });

    test('P2-7 setVoice 失败回落默认，不逐段失败且只提示一次', () async {
      platform.setVoiceError = const SystemTtsException('音色不可用');
      final service = buildService();
      await service.selectVoice(
        const SystemTtsVoice(name: 'a', locale: 'zh-CN'),
      );
      final path = await synth(service, text: 'A');
      expect(path, isNotEmpty, reason: '音色失败不得让整段合成失败');
      expect(platform.clearVoiceCount, greaterThanOrEqualTo(1));
      expect(service.selectedVoice, isNull);
      expect(service.takeNotice(), contains('回退'));

      final setVoiceCalls = platform.setVoices.length;
      await synth(service, text: 'B');
      expect(platform.setVoices.length, setVoiceCalls,
          reason: '已回落默认后不再重试 setVoice');
      expect(service.takeNotice(), isNull, reason: '提示只出现一次');
    });

    test('P3 缓存文件为 0 字节时重新合成而非误命中', () async {
      final service = buildService();
      final path = await synth(service, text: 'A');
      File(path).writeAsBytesSync(const []);
      final again = await synth(service, text: 'A');
      expect(again, path);
      expect(File(path).lengthSync(), 4);
      expect(platform.synthCount, 2);
    });
  });

  group('刻度换算（兼容旧 playSpeed）', () {
    test('语速 0.5–3.0x ↔ 参考刻度 (rate+5)/10 口径', () {
      // 审查回修 P2-3：参考版 1.0x=5、2.0x=15、3.0x=25
      expect(ttsSpeechRateFromSpeed(0.5), 0);
      expect(ttsSpeechRateFromSpeed(1.0), 5);
      expect(ttsSpeechRateFromSpeed(2.0), 15);
      expect(ttsSpeechRateFromSpeed(3.0), 25);
      expect(ttsSpeechRateFromSpeed(9.0), 25, reason: 'UI 越界先收敛到 3.0x（25）');
      expect(ttsSpeedFromSpeechRate(0), 0.5);
      expect(ttsSpeedFromSpeechRate(5), closeTo(1.0, 0.001));
      expect(ttsSpeedFromSpeechRate(15), closeTo(2.0, 0.001));
      expect(ttsSpeedFromSpeechRate(25), 3.0);
      expect(ttsSpeedFromSpeechRate(80), 3.0, reason: '超出 UI 上限收敛到 3.0');
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

/// FlutterTts 假实现：首次 awaitSynthCompletion 失败，用于验证 init 重试
class _FakeFlutterTts extends FlutterTts {
  int synthCompletionCalls = 0;

  @override
  Future<dynamic> awaitSynthCompletion(bool awaitCompletion) async {
    synthCompletionCalls++;
    if (synthCompletionCalls == 1) {
      throw StateError('plugin not ready');
    }
    return 1;
  }

  @override
  Future<dynamic> setLanguage(String language) async => 1;
}

/// 所有方法抛异常的平台（探测失败路径）
class _ThrowingPlatform implements SystemTtsPlatform {
  @override
  bool get supportsEngineSelection => true;

  @override
  bool get supportsSynthesis => true;

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
