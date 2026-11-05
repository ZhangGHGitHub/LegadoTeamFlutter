import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/pref_keys.dart';

/// 系统 TTS 引擎哨兵 URL
///
/// 对齐参考版「系统 TTS」语义：`ReadAloud.ttsEngine == null` 即系统引擎。
/// 本项目用固定哨兵值承载用户显式选择（区别于「空 = 未配置」），
/// [AudioNotifier] 解析到空串或该哨兵时走系统 TTS 分支，绝不把它传给
/// HTTP 合成管线（Rust `tts_speak` 会把它当 URL 模板）。
const String kSystemTtsEngineUrl = 'system://tts';

/// UI 语速下限/上限（倍速）
const double kMinTtsSpeed = 0.5;
const double kMaxTtsSpeed = 3.0;

/// 参考刻度语速范围（0–80，1.0x = 16）
const int kTtsSpeechRateMin = 0;
const int kTtsSpeechRateMax = 80;

/// 参考刻度音调范围（5–20，即 0.5–2.0；默认 10 = 1.0）
const int kTtsPitchStoredMin = 5;
const int kTtsPitchStoredMax = 20;

/// 参考刻度音量范围（0–100，即 0–1）
const int kTtsVolumeStoredMin = 0;
const int kTtsVolumeStoredMax = 100;

/// UI 倍速 → 参考刻度语速（0.5x→0、1.0x→16、3.0x→80）
///
/// [设置批5a-1] 参考版内部使用 0–80 整数刻度；本项目 UI 保留倍速显示，
/// 持久化统一落参考刻度，读写只经本组纯函数，避免两套刻度漂移。
int ttsSpeechRateFromSpeed(double speed) {
  final clamped = speed.clamp(kMinTtsSpeed, kMaxTtsSpeed);
  final ratio = (clamped - kMinTtsSpeed) / (kMaxTtsSpeed - kMinTtsSpeed);
  return (ratio * kTtsSpeechRateMax).round().clamp(
        kTtsSpeechRateMin,
        kTtsSpeechRateMax,
      );
}

/// 参考刻度语速 → UI 倍速（越界值收敛到 0.5–3.0；缺失/非法回退 [fallback]）
double ttsSpeedFromSpeechRate(int? rate, {double fallback = 1.0}) {
  if (rate == null) return fallback;
  final clamped = rate.clamp(kTtsSpeechRateMin, kTtsSpeechRateMax);
  final ratio = clamped / kTtsSpeechRateMax;
  return kMinTtsSpeed + ratio * (kMaxTtsSpeed - kMinTtsSpeed);
}

/// UI 音调 → 参考刻度（0.5–2.0 → 5–20）
int ttsPitchToStored(double pitch) =>
    (pitch * 10).round().clamp(kTtsPitchStoredMin, kTtsPitchStoredMax);

/// 参考刻度 → UI 音调（缺失/非法回退 [fallback]）
double ttsPitchFromStored(int? value, {double fallback = 1.0}) {
  if (value == null) return fallback;
  return (value.clamp(kTtsPitchStoredMin, kTtsPitchStoredMax) / 10.0);
}

/// UI 音量 → 参考刻度（0–1 → 0–100）
int ttsVolumeToStored(double volume) =>
    (volume * 100).round().clamp(kTtsVolumeStoredMin, kTtsVolumeStoredMax);

/// 参考刻度 → UI 音量（缺失/非法回退 [fallback]）
double ttsVolumeFromStored(int? value, {double fallback = 1.0}) {
  if (value == null) return fallback;
  return value.clamp(kTtsVolumeStoredMin, kTtsVolumeStoredMax) / 100.0;
}

/// 系统 TTS 引擎信息（Android getEngines 返回包名）
class SystemTtsEngine {
  const SystemTtsEngine({required this.name, required this.label});

  /// 引擎包名（setEngine 入参）
  final String name;

  /// 展示名（无 label 时回落包名）
  final String label;

  String get displayName => label.trim().isEmpty ? name : label;

  @override
  String toString() => 'SystemTtsEngine($name, $label)';
}

/// 系统 TTS 音色（name + locale 是 setVoice 的完整定位键）
class SystemTtsVoice {
  const SystemTtsVoice({required this.name, required this.locale});

  /// 音色名（Android Voice.getName / iOS identifier）
  final String name;

  /// BCP 47 locale（如 zh-CN）
  final String locale;

  String get displayName {
    if (name.isEmpty) return locale;
    return locale.isEmpty ? name : '$name（$locale）';
  }

  @override
  String toString() => 'SystemTtsVoice($name, $locale)';
}

/// 系统 TTS 缓存统计（文件数 + 总字节）
class SystemTtsCacheStats {
  const SystemTtsCacheStats({required this.fileCount, required this.totalBytes});

  static const empty = SystemTtsCacheStats(fileCount: 0, totalBytes: 0);

  final int fileCount;
  final int totalBytes;
}

/// 系统 TTS 异常基类（消息直接进 [AudioState.errorMessage] 展示）
class SystemTtsException implements Exception {
  const SystemTtsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 系统 TTS 不可用（未安装引擎/初始化失败）——调用方据此走「无可用引擎」
/// 一次性提示语义，而不是报合成失败
class SystemTtsUnavailableException extends SystemTtsException {
  const SystemTtsUnavailableException(super.message);
}

/// 系统 TTS 平台抽象（便于单测注入 fake，不触真实平台通道）
abstract class SystemTtsPlatform {
  /// 是否支持引擎选择（Android true；iOS/桌面 false）
  bool get supportsEngineSelection;

  Future<void> init();

  Future<List<SystemTtsEngine>> getEngines();

  Future<List<SystemTtsVoice>> getVoices();

  Future<void> setEngine(String engineName);

  /// 恢复系统默认引擎（Android 插件 getDefaultEngine + setEngine）
  Future<void> resetEngine();

  Future<void> setVoice(SystemTtsVoice voice);

  /// 恢复系统默认音色（Android/iOS 插件提供；其它平台可抛异常）
  Future<void> clearVoice();

  /// 传入 UI 倍速（内部按平台折算）
  Future<void> setSpeechRate(double speed);

  Future<void> setPitch(double pitch);

  Future<void> setVolume(double volume);

  /// 合成到绝对路径（文件不存在/为空由 [SystemTtsService] 判定失败）
  Future<void> synthesizeToFile(String text, String fullPath);

  Future<void> stop();
}

/// flutter_tts 实现
///
/// 刻度差异（见 flutter_tts Android 插件 setSpeechRate 注释）：
/// Android 原生 rate 1.0 对应 flutter rate 0.5，插件内部 ×2，故本层统一
/// 传 `speed / 2`，使 UI 倍速与系统「常速 1.0」一一对应。
class FlutterTtsSystemTtsPlatform implements SystemTtsPlatform {
  FlutterTtsSystemTtsPlatform({FlutterTts? tts}) : _tts = tts;

  /// 延迟创建：`FlutterTts()` 构造即向平台通道注册回调，纯 Dart 单测
  /// （未初始化 WidgetsBinding）在 Provider 构建阶段就会断言失败；
  /// 首次真正调用平台能力时再创建。
  FlutterTts? _tts;

  FlutterTts get _client => _tts ??= FlutterTts();

  bool _initDone = false;

  @override
  bool get supportsEngineSelection =>
      defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> init() async {
    if (_initDone) return;
    _initDone = true;
    // Android 的 synthesizeToFile 需 awaitSynthCompletion=true 才在合成完成
    // 后回调；iOS 的 write() 路径不保证 didFinish 回调，故 iOS/桌面走轮询。
    await _client.awaitSynthCompletion(supportsEngineSelection);
    try {
      // 失败（语言未安装等）不阻断：沿用引擎默认语言
      await _client.setLanguage('zh-CN');
    } catch (_) {
      // 忽略：部分平台/引擎不支持显式设置语言
    }
  }

  @override
  Future<List<SystemTtsEngine>> getEngines() async {
    try {
      final raw = await _client.getEngines;
      if (raw is! List) return const [];
      final result = <SystemTtsEngine>[];
      for (final item in raw) {
        if (item is Map) {
          final name = (item['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          result.add(SystemTtsEngine(
            name: name,
            label: (item['label'] ?? name).toString(),
          ));
        } else {
          final name = item.toString().trim();
          if (name.isEmpty) continue;
          result.add(SystemTtsEngine(name: name, label: name));
        }
      }
      return result;
    } catch (_) {
      // 非 Android / 插件不可用：空列表（UI 走空态提示）
      return const [];
    }
  }

  @override
  Future<List<SystemTtsVoice>> getVoices() async {
    try {
      final raw = await _client.getVoices;
      if (raw is! List) return const [];
      final result = <SystemTtsVoice>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString().trim();
        final locale = (item['locale'] ?? '').toString().trim();
        if (name.isEmpty && locale.isEmpty) continue;
        result.add(SystemTtsVoice(name: name, locale: locale));
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> setEngine(String engineName) async {
    await _client.setEngine(engineName);
  }

  @override
  Future<void> resetEngine() async {
    // 插件原生 getDefaultEngine 返回系统「文字转语音」设置里的默认引擎；
    // 取不到时保持当前引擎（不猜测包名，避免设置失败）。
    final name = await _client.getDefaultEngine;
    final trimmed = name is String ? name.trim() : '';
    if (trimmed.isEmpty) return;
    await _client.setEngine(trimmed);
  }

  @override
  Future<void> setVoice(SystemTtsVoice voice) async {
    final result = await _client.setVoice({
      'name': voice.name,
      'locale': voice.locale,
    });
    if (result == 0) {
      throw SystemTtsException('音色不可用：${voice.displayName}');
    }
  }

  @override
  Future<void> clearVoice() async {
    await _client.clearVoice();
  }

  @override
  Future<void> setSpeechRate(double speed) async {
    // UI 倍速 → flutter 刻度（Android 插件内部 ×2 还原为系统 rate）
    await _client.setSpeechRate((speed / 2.0).clamp(0.0, 1.5));
  }

  @override
  Future<void> setPitch(double pitch) async {
    await _client.setPitch(pitch.clamp(0.5, 2.0));
  }

  @override
  Future<void> setVolume(double volume) async {
    await _client.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  Future<void> synthesizeToFile(String text, String fullPath) async {
    await _client.synthesizeToFile(text, fullPath, true);
    if (supportsEngineSelection) return;
    // iOS/桌面：write() 不保证完成回调，轮询文件「存在且大小稳定」
    final file = File(fullPath);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var lastSize = -1;
    var stable = 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!file.existsSync()) continue;
      final size = file.lengthSync();
      if (size > 0 && size == lastSize) {
        stable++;
        if (stable >= 2) return;
      } else {
        stable = 0;
      }
      lastSize = size;
    }
  }

  @override
  Future<void> stop() async {
    await _client.stop();
  }
}

/// 系统 TTS 服务（设置批5a-1）
///
/// 职责：
/// - 封装 flutter_tts 的引擎/音色/参数设置与「合成到文件」；
/// - 合成缓存：文件名 = md5(text|engine|voice|rate|pitch|volume)，命中即复用；
/// - LRU 清理：最多保留 [maxCacheFiles] 个文件，且清理超过 [maxCacheAge]
///   的旧文件，避免缓存无限增长；
/// - 选择态（引擎/音色）持久化到 SharedPreferences，重启后由首次合成读回。
///
/// 播放仍复用 [StreamAudioPlayer.playLocalFile]，与 HTTP 引擎路径同源，
/// 段落推进/失败回落语义保持一致。
class SystemTtsService {
  SystemTtsService({
    SystemTtsPlatform? platform,
    Future<Directory> Function()? baseDirectoryProvider,
    this.maxCacheFiles = 50,
    this.maxCacheAge = const Duration(hours: 48),
  })  : _platform = platform ?? FlutterTtsSystemTtsPlatform(),
        _baseDirectoryProvider =
            baseDirectoryProvider ?? getTemporaryDirectory;

  /// 缓存子目录名（位于应用临时目录下）
  static const String cacheDirName = 'system_tts';

  /// 缓存文件上限（按最近修改时间保留最新 N 个）
  final int maxCacheFiles;

  /// 缓存文件最长保留时间
  final Duration maxCacheAge;

  final SystemTtsPlatform _platform;
  final Future<Directory> Function() _baseDirectoryProvider;

  /// 可用性缓存（null = 未探测）
  bool? _available;

  /// 选择态（SharedPreferences 读回一次）
  bool _selectionLoaded = false;
  String? _selectedEngine;
  SystemTtsVoice? _selectedVoice;

  /// 已应用到平台层的参数（避免每段重复 set*）
  String? _appliedEngine;
  SystemTtsVoice? _appliedVoice;
  double? _appliedSpeed;
  double? _appliedPitch;
  double? _appliedVolume;

  /// 同文本/参数的并发合成去重
  final Map<String, Future<String>> _inFlight = {};

  /// 引擎列表（失败/非 Android 返回空）
  Future<List<SystemTtsEngine>> engines() async {
    try {
      await _platform.init();
      return await _platform.getEngines();
    } catch (_) {
      return const [];
    }
  }

  /// 音色列表（失败/非 Android 返回空）
  Future<List<SystemTtsVoice>> voices() async {
    try {
      await _platform.init();
      return await _platform.getVoices();
    } catch (_) {
      return const [];
    }
  }

  /// 系统 TTS 是否可用（未安装引擎 → false）
  ///
  /// 结果缓存；用户可能中途安装引擎，设置页可调 [invalidateAvailability]。
  Future<bool> isAvailable() async {
    final cached = _available;
    if (cached != null) return cached;
    try {
      await _platform.init();
      if (!_platform.supportsEngineSelection) {
        _available = true;
        return true;
      }
      final engines = await _platform.getEngines();
      _available = engines.isNotEmpty;
      return _available!;
    } catch (_) {
      _available = false;
      return false;
    }
  }

  /// 清空可用性缓存（设置页刷新/用户安装引擎后调用）
  void invalidateAvailability() {
    _available = null;
  }

  /// 读回持久化的引擎/音色选择（幂等，只读一次）
  Future<void> loadSelection() async {
    if (_selectionLoaded) return;
    _selectionLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final engine = prefs.getString(PrefKeys.systemTtsEngine);
      _selectedEngine = (engine == null || engine.trim().isEmpty)
          ? null
          : engine.trim();
      final voiceName = prefs.getString(PrefKeys.systemTtsVoice);
      if (voiceName != null && voiceName.trim().isNotEmpty) {
        _selectedVoice = SystemTtsVoice(
          name: voiceName.trim(),
          locale: (prefs.getString(PrefKeys.systemTtsVoiceLocale) ?? '').trim(),
        );
      }
    } catch (e) {
      debugPrint('读取系统 TTS 选择失败（使用系统默认）: $e');
    }
  }

  /// 当前选择的系统引擎（null = 系统默认）
  String? get selectedEngineName => _selectedEngine;

  /// 当前选择的音色（null = 系统默认）
  SystemTtsVoice? get selectedVoice => _selectedVoice;

  /// 选择系统引擎并持久化（null/空串 = 系统默认）
  Future<void> selectEngine(String? engineName) async {
    final name = engineName?.trim();
    _selectedEngine = (name == null || name.isEmpty) ? null : name;
    // 不清空 _appliedEngine：下次合成据此判定是否需要 resetEngine 恢复默认
    _selectionLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_selectedEngine == null) {
        await prefs.remove(PrefKeys.systemTtsEngine);
      } else {
        await prefs.setString(PrefKeys.systemTtsEngine, _selectedEngine!);
      }
    } catch (e) {
      debugPrint('保存系统 TTS 引擎失败: $e');
    }
  }

  /// 选择音色并持久化（null = 系统默认音色）
  Future<void> selectVoice(SystemTtsVoice? voice) async {
    _selectedVoice = voice;
    // 不清空 _appliedVoice：下次合成据此判定是否需要 clearVoice 恢复默认
    _selectionLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (voice == null) {
        await prefs.remove(PrefKeys.systemTtsVoice);
        await prefs.remove(PrefKeys.systemTtsVoiceLocale);
      } else {
        await prefs.setString(PrefKeys.systemTtsVoice, voice.name);
        await prefs.setString(PrefKeys.systemTtsVoiceLocale, voice.locale);
      }
    } catch (e) {
      debugPrint('保存系统 TTS 音色失败: $e');
    }
  }

  /// 合成当前段落并返回本地音频文件路径
  ///
  /// 失败抛 [SystemTtsUnavailableException]（无可用引擎）或
  /// [SystemTtsException]（合成/写文件失败），由调用方展示并回落估算推进。
  Future<String> synthesizeToFile({
    required String text,
    required double speed,
    required double pitch,
    required double volume,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const SystemTtsException('朗读文本为空');
    }
    if (!await isAvailable()) {
      throw const SystemTtsUnavailableException('系统未安装可用的 TTS 引擎');
    }
    await loadSelection();
    final dir = await _cacheDirectory();
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    final key = _cacheKey(trimmed, speed, pitch, volume);
    final path = '${dir.path}${Platform.pathSeparator}$key.wav';
    final existing = File(path);
    if (existing.existsSync() && existing.lengthSync() > 0) {
      // 命中缓存：刷新 mtime 参与 LRU
      try {
        existing.setLastModifiedSync(DateTime.now());
      } catch (_) {}
      return path;
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _synthesizeAndVerify(trimmed, path, speed, pitch, volume);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 停止系统 TTS（当前实现为合成到文件，不涉及播报；保留给设置页试听/中断）
  Future<void> stop() async {
    try {
      await _platform.stop();
    } catch (_) {}
  }

  /// 缓存统计（目录不可用/平台异常时返回空统计）
  Future<SystemTtsCacheStats> cacheStats() async {
    try {
      final dir = await _cacheDirectory();
      if (!dir.existsSync()) return SystemTtsCacheStats.empty;
      var count = 0;
      var bytes = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.wav')) continue;
        count++;
        try {
          bytes += entity.lengthSync();
        } catch (_) {}
      }
      return SystemTtsCacheStats(fileCount: count, totalBytes: bytes);
    } catch (_) {
      return SystemTtsCacheStats.empty;
    }
  }

  /// 清空系统 TTS 缓存，返回删除文件数
  Future<int> clearCache() async {
    try {
      final dir = await _cacheDirectory();
      if (!dir.existsSync()) return 0;
      var deleted = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.wav')) continue;
        try {
          entity.deleteSync();
          deleted++;
        } catch (_) {}
      }
      return deleted;
    } catch (_) {
      return 0;
    }
  }

  /// LRU 清理：删除超过 [maxCacheAge] 的文件，再按 mtime 保留最新
  /// [maxCacheFiles] 个；返回删除数。
  Future<int> pruneCache() async {
    try {
      final dir = await _cacheDirectory();
      if (!dir.existsSync()) return 0;
      final files = <File>[];
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.wav')) {
          files.add(entity);
        }
      }
      final now = DateTime.now();
      final alive = <File>[];
      var deleted = 0;
      for (final file in files) {
        try {
          final modified = file.statSync().modified;
          if (now.difference(modified) > maxCacheAge) {
            file.deleteSync();
            deleted++;
          } else {
            alive.add(file);
          }
        } catch (_) {
          // 单文件异常跳过，不影响其余清理
        }
      }
      alive.sort((a, b) {
        try {
          return b.statSync().modified.compareTo(a.statSync().modified);
        } catch (_) {
          return 0;
        }
      });
      for (var i = maxCacheFiles; i < alive.length; i++) {
        try {
          alive[i].deleteSync();
          deleted++;
        } catch (_) {}
      }
      return deleted;
    } catch (e) {
      debugPrint('清理系统 TTS 缓存失败: $e');
      return 0;
    }
  }

  // ===== 内部 =====

  Future<Directory> _cacheDirectory() async {
    final base = await _baseDirectoryProvider();
    return Directory('${base.path}${Platform.pathSeparator}$cacheDirName');
  }

  /// 缓存键：文本 + 引擎 + 音色 + 参数（任一变化即重新合成）
  String _cacheKey(String text, double speed, double pitch, double volume) {
    final raw = [
      text,
      _selectedEngine ?? '',
      _selectedVoice?.name ?? '',
      _selectedVoice?.locale ?? '',
      speed.toStringAsFixed(3),
      pitch.toStringAsFixed(3),
      volume.toStringAsFixed(3),
    ].join('|');
    return md5.convert(const Utf8Encoder().convert(raw)).toString();
  }

  Future<String> _synthesizeAndVerify(
    String text,
    String path,
    double speed,
    double pitch,
    double volume,
  ) async {
    await _applyPlatformState(speed, pitch, volume);
    try {
      await _platform.synthesizeToFile(text, path);
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() <= 0) {
        throw const SystemTtsException('系统 TTS 未生成音频文件');
      }
      await pruneCache();
      return path;
    } catch (e) {
      // 失败产物（空文件/半文件）不得留在缓存目录被下次误命中
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      if (e is SystemTtsException) rethrow;
      throw SystemTtsException('系统 TTS 合成失败：$e');
    }
  }

  Future<void> _applyPlatformState(
    double speed,
    double pitch,
    double volume,
  ) async {
    final engine = _selectedEngine;
    if (engine == null) {
      // 从「已选引擎」切回「系统默认」：查询系统默认引擎并重新应用
      if (_appliedEngine != null) {
        try {
          await _platform.resetEngine();
        } catch (e) {
          debugPrint('恢复系统默认 TTS 引擎失败（忽略）: $e');
        }
        _appliedEngine = null;
      }
    } else if (engine != _appliedEngine) {
      await _platform.setEngine(engine);
      _appliedEngine = engine;
    }
    final voice = _selectedVoice;
    if (voice == null) {
      // 从「已选音色」切回「系统默认」：调用插件 clearVoice 恢复默认音色
      if (_appliedVoice != null) {
        try {
          await _platform.clearVoice();
        } catch (e) {
          debugPrint('恢复系统默认音色失败（忽略）: $e');
        }
        _appliedVoice = null;
      }
    } else if (_appliedVoice?.name != voice.name ||
        _appliedVoice?.locale != voice.locale) {
      await _platform.setVoice(voice);
      _appliedVoice = voice;
    }
    if (_appliedSpeed != speed) {
      await _platform.setSpeechRate(speed);
      _appliedSpeed = speed;
    }
    if (_appliedPitch != pitch) {
      await _platform.setPitch(pitch);
      _appliedPitch = pitch;
    }
    if (_appliedVolume != volume) {
      await _platform.setVolume(volume);
      _appliedVolume = volume;
    }
  }
}
