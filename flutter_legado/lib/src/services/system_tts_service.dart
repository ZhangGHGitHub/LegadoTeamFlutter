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

/// 参考刻度语速范围（0–80，参考版内部刻度；UI 0.5–3.0x 对应 0–25）
const int kTtsSpeechRateMin = 0;
const int kTtsSpeechRateMax = 80;

/// 参考刻度音调范围（5–20，即 0.5–2.0；默认 10 = 1.0）
const int kTtsPitchStoredMin = 5;
const int kTtsPitchStoredMax = 20;

/// 参考刻度音量范围（0–100，即 0–1）
const int kTtsVolumeStoredMin = 0;
const int kTtsVolumeStoredMax = 100;

/// UI 倍速 → 参考刻度语速（0.5x→0、1.0x→5、2.0x→15、3.0x→25）
///
/// [设置批5a-1 审查回修] 口径对齐参考版 `(rate + 5) / 10` 的逆运算：
/// 参考版内部 rate 刻度以 5 表示常速、15 表示 2 倍速、25 表示 3 倍速。
/// 本项目 UI 保留 0.5–3.0 倍速显示，持久化统一落参考刻度，读写只经
/// 本组纯函数，避免两套刻度漂移。
int ttsSpeechRateFromSpeed(double speed) {
  final clamped = speed.clamp(kMinTtsSpeed, kMaxTtsSpeed);
  return ((clamped * 10) - 5).round().clamp(
    kTtsSpeechRateMin,
    kTtsSpeechRateMax,
  );
}

/// 参考刻度语速 → UI 倍速（`(rate + 5) / 10`；UI 收敛到 0.5–3.0）
///
/// 参考刻度允许 0–80（历史/外部写入可能超过 UI 上限），读回时收敛到
/// 滑块范围，避免滑块越界显示。
double ttsSpeedFromSpeechRate(int? rate, {double fallback = 1.0}) {
  if (rate == null) return fallback;
  final clamped = rate.clamp(kTtsSpeechRateMin, kTtsSpeechRateMax);
  return ((clamped + 5) / 10.0).clamp(kMinTtsSpeed, kMaxTtsSpeed);
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
  const SystemTtsCacheStats({
    required this.fileCount,
    required this.totalBytes,
  });

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

  /// 是否支持「合成到文件」（Android/iOS/macOS true；Windows/Linux false）
  ///
  /// [审查回修 P2-1] flutter_tts 在 Windows 无 `synthesizeToFile` 实现，
  /// 若不在此判定会形成「可点但永远失败」的死开关；不支持平台直接按
  /// 「系统 TTS 不可用」处理（回落估算 + 一次性提示）。
  bool get supportsSynthesis;

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

  /// 丢弃当前平台客户端并重置初始化状态（尽力 stop 旧客户端）
  ///
  /// [审查回修 P2] 引擎初始化超时后，迟到的 setEngine 仍可能落在旧实例上；
  /// 调用本方法丢弃旧客户端（下次使用重新创建），避免后续合成继续使用
  /// 失败的引擎实例。
  Future<void> resetClient();
}

/// 当前平台是否支持系统 TTS 合成（Android/iOS/macOS）
///
/// [审查回修 P2-A/P3] 平台实现与设置页共用同一判定，避免两处 switch 漂移。
bool platformSupportsSystemTts([TargetPlatform? platform]) {
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.android ||
      target == TargetPlatform.iOS ||
      target == TargetPlatform.macOS;
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
  bool get supportsSynthesis => platformSupportsSystemTts();

  @override
  Future<void> init() async {
    if (_initDone) return;
    // [审查回修 P2-1] 失败不得留下 _initDone=true：否则一次瞬时失败
    // （插件未就绪等）会让本进程永久不可用，无法重试。
    try {
      // Android 的 synthesizeToFile 需 awaitSynthCompletion=true 才在合成完成
      // 后回调；iOS 的 write() 路径不保证 didFinish 回调，故 iOS/桌面走轮询。
      await _client.awaitSynthCompletion(supportsEngineSelection);
      try {
        // 失败（语言未安装等）不阻断：沿用引擎默认语言
        await _client.setLanguage('zh-CN');
      } catch (_) {
        // 忽略：部分平台/引擎不支持显式设置语言
      }
      _initDone = true;
    } catch (e) {
      _initDone = false;
      rethrow;
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
          result.add(
            SystemTtsEngine(
              name: name,
              label: (item['label'] ?? name).toString(),
            ),
          );
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
    // 从未使用过平台（纯音频书/流媒体路径的 stop 也会透传到这里）：
    // 不创建 FlutterTts，避免无谓的平台通道调用与测试挂起。
    if (_tts == null) return;
    await _client.stop();
  }

  @override
  Future<void> resetClient() async {
    final client = _tts;
    // 先丢弃引用：即使旧客户端的 init 迟到完成，也不会再被使用
    _tts = null;
    _initDone = false;
    if (client == null) return;
    try {
      await client.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 尽力而为：旧客户端 stop 失败不影响新客户端重建
    }
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
    this.synthesisTimeout = const Duration(seconds: 45),
  }) : _platform = platform ?? FlutterTtsSystemTtsPlatform(),
       _baseDirectoryProvider = baseDirectoryProvider ?? getTemporaryDirectory;

  /// 缓存子目录名（位于应用临时目录下）
  static const String cacheDirName = 'system_tts';

  /// 缓存文件上限（按最近修改时间保留最新 N 个）
  final int maxCacheFiles;

  /// 缓存文件最长保留时间
  final Duration maxCacheAge;

  /// 单段合成超时（审查回修 P1-1）
  ///
  /// flutter_tts Android 的 onError/ERROR 回调不会完成 synthesizeToFile 的
  /// Future，且插件内部 `speaking`/合成状态不会复位——后续每段都会立即
  /// 报「未生成音频文件」。超时后调用平台 stop 复位 busy 再抛
  /// [SystemTtsException]，保证段落链继续（估算推进）而不是永久挂起。
  final Duration synthesisTimeout;

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

  /// 引擎层状态可疑（审查回修 P2）
  ///
  /// setEngine/resetEngine 超时或失败后，平台可能已切到失败引擎/停在中间态；
  /// 即使 _appliedEngine 已回滚为 null，也必须强制 reset/set 一次，不能
  /// 因「看起来已应用」而跳过。
  bool _engineDirty = false;

  /// 同文本/参数的并发合成去重
  final Map<String, Future<String>> _inFlight = {};

  /// 合成串行队列（审查回修 P2-6）
  ///
  /// flutter_tts 是单实例：跨 key 并发合成会互相打断/排队在插件内部，
  /// 表现为「切段/停止后立即重播 busy」。本队列保证任意时刻只有一次
  /// 平台合成在跑；同 key 请求仍由 [_inFlight] 合并。
  ///
  /// 延迟创建（null = 空闲）：若在构造时创建 `Future.value()`，其 microtask
  /// 会绑定到构造 zone（如测试 setUp 的真实 zone），widget 测试的
  /// FakeAsync pump 无法推进队列；首次入队时在当前调用 zone 创建。
  Future<void>? _synthQueue;

  /// 合成代际（审查回修 P2-B）
  ///
  /// stop() 自增；旧任务失败/超时只允许在代际未变时复位平台、删除文件，
  /// 避免打断 stop 后刚发起的新合成。
  int _epoch = 0;

  /// stop 屏障：stop 进行中（平台 stop 最多 2s）时新合成等待，避免被
  /// 平台 stop 打断；stop 完成后放行。
  Completer<void>? _stopBarrier;

  /// 待展示的一次性提示（如音色失效回退默认），由调用方消费
  String? _pendingNotice;

  /// 取出一次性提示（取后清空；无则 null）
  String? takeNotice() {
    final notice = _pendingNotice;
    _pendingNotice = null;
    return notice;
  }

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
    // [审查回修 P2-1] 平台不支持合成（Windows/Linux）直接判不可用，
    // 不做 init/引擎探测，避免设置页出现永远失败的死开关。
    if (!_platform.supportsSynthesis) {
      _available = false;
      return false;
    }
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
  ///
  /// [审查回修 P2-7] 切换后立即应用引擎（先 setEngine/resetEngine 再
  /// getVoices）并刷新音色列表；已选音色不在新引擎列表时清除并回落默认，
  /// 返回刷新后的音色列表供设置页即时更新。
  ///
  /// [审查回修 P2-A] 引擎初始化（setEngine/resetEngine）加超时；失败/超时
  /// 回滚到切换前的引擎并持久化，返回 null 供页面提示「引擎初始化失败」。
  /// [审查回修 P3] 引擎切换进 [_synthQueue] 串行，避免替换 TTS 实例打断
  /// 在途合成。
  Future<List<SystemTtsVoice>?> selectEngine(String? engineName) async {
    final previousEngine = _selectedEngine;
    final name = engineName?.trim();
    _selectedEngine = (name == null || name.isEmpty) ? null : name;
    _selectionLoaded = true;
    await _persistEngineSelection();
    if (!_platform.supportsSynthesis) return const [];
    var taskEpoch = _epoch;
    try {
      // stop 进行中先等待（最多 2s），避免切换被平台 stop 打断
      while (_stopBarrier != null) {
        await _stopBarrier!.future;
      }
      final epoch = _epoch;
      taskEpoch = epoch;
      final voices = await _enqueue(() async {
        if (epoch != _epoch) {
          throw const SystemTtsException('系统 TTS 引擎切换已取消');
        }
        await _applyEngineOnly();
        return _platform.getVoices();
      });
      // [审查回修 P3] 成功切换后清除旧一次性提示（音色失效提示在下方重设）
      _pendingNotice = null;
      final selected = _selectedVoice;
      if (selected != null &&
          !voices.any(
            (v) => v.name == selected.name && v.locale == selected.locale,
          )) {
        await selectVoice(null);
        _pendingNotice = '原音色在当前引擎不可用，已回退系统默认音色';
      }
      return voices;
    } catch (e) {
      debugPrint('切换系统 TTS 引擎失败: $e');
      // 回滚选择并持久化：下次合成/重启仍使用切换前引擎
      _selectedEngine = previousEngine;
      await _persistEngineSelection();
      _appliedEngine = null;
      _engineDirty = true;
      // [审查回修 P2-B] stop 已推进代际时不复位平台，避免打断新合成
      if (taskEpoch == _epoch) await _resetPlatformBusy();
      return null;
    }
  }

  /// 持久化当前引擎选择（null = 系统默认，移除键）
  Future<void> _persistEngineSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final engine = _selectedEngine;
      if (engine == null) {
        await prefs.remove(PrefKeys.systemTtsEngine);
      } else {
        await prefs.setString(PrefKeys.systemTtsEngine, engine);
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
    // [审查回修 P2-B] stop 进行中先等待平台 stop 完成（最多 2s），
    // 避免新合成被 stop 打断；循环保证等待期间再次 stop 也能正确排队。
    while (_stopBarrier != null) {
      await _stopBarrier!.future;
    }
    final epoch = _epoch;
    final future = _enqueue(
      () => _synthesizeAndVerify(trimmed, path, speed, pitch, volume, epoch),
    );
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      // [审查回修 P2-B] 仅移除自己注册的 future：stop 清表后同 key 的
      // 新任务可能已注册，旧任务的 finally 不得误删新任务。
      if (identical(_inFlight[key], future)) {
        _inFlight.remove(key);
      }
    }
  }

  /// 停止系统 TTS 并放弃当前排队链（审查回修 P1-1/P2-6/P2-B）
  ///
  /// - 自增代际并清空一次性提示；
  /// - 立即放弃旧队列/去重表（旧任务由代际守卫，不再复位平台/删文件）；
  /// - 平台 stop 让 flutter_tts 从 busy 状态复位；期间新合成经
  ///   [_stopBarrier] 等待，避免被 stop 打断。
  Future<void> stop() async {
    _epoch++;
    _pendingNotice = null;
    final barrier = Completer<void>();
    _stopBarrier = barrier;
    _synthQueue = null;
    _inFlight.clear();
    try {
      await _platform.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 平台 stop 失败/超时不影响调用方（停止是尽力而为）
    }
    if (identical(_stopBarrier, barrier)) {
      _stopBarrier = null;
    }
    if (!barrier.isCompleted) barrier.complete();
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
  ///
  /// [keepPath] 非空时保留该文件（正在播放/即将播放的文件不得删除，
  /// 设置批5c）。路径不在缓存目录内时不会误删（[deleteCacheFile] 校验）。
  Future<int> clearCache({String? keepPath}) async {
    try {
      final dir = await _cacheDirectory();
      if (!dir.existsSync()) return 0;
      var deleted = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.wav')) continue;
        if (keepPath != null && _isSamePath(entity.path, keepPath)) continue;
        try {
          entity.deleteSync();
          deleted++;
        } catch (_) {}
      }
      return deleted;
    } catch (e) {
      debugPrint('清空系统 TTS 缓存失败: $e');
      return 0;
    }
  }

  /// 按保留时间清理系统 TTS 缓存（设置批5c）
  ///
  /// - [retentionMinutes] <= 0（即听即焚）不在此清理：0 模式按段删除，
  ///   避免开播时把用户尚未消费的缓存一次性清空；
  /// - 超过保留时长的 `*.wav` 按 mtime 删除；[keepPath] 指向的文件保留
  ///   （正在播放）；
  /// - 失败静默（debugPrint），返回实际删除数。
  Future<int> pruneByRetention(int retentionMinutes, {String? keepPath}) async {
    if (retentionMinutes <= 0) return 0;
    try {
      final dir = await _cacheDirectory();
      if (!dir.existsSync()) return 0;
      final cutoff = DateTime.now().subtract(
        Duration(minutes: retentionMinutes),
      );
      var deleted = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.wav')) continue;
        if (keepPath != null && _isSamePath(entity.path, keepPath)) continue;
        try {
          if (entity.statSync().modified.isBefore(cutoff)) {
            entity.deleteSync();
            deleted++;
          }
        } catch (e) {
          debugPrint('清理过期系统 TTS 缓存失败（跳过）: $e');
        }
      }
      return deleted;
    } catch (e) {
      debugPrint('按保留时间清理系统 TTS 缓存失败: $e');
      return 0;
    }
  }

  /// 删除单个系统 TTS 缓存文件（0 模式即听即焚 / stop 清理）
  ///
  /// 只允许删除缓存目录内的 `*.wav`，避免调用方传入任意路径误删文件；
  /// [keepPath] 指向的文件保留（正在播放）。返回是否实际删除。
  Future<bool> deleteCacheFile(String path, {String? keepPath}) async {
    try {
      final dir = await _cacheDirectory();
      if (!_isInsideDirectory(dir.path, path)) return false;
      if (!path.endsWith('.wav')) return false;
      if (keepPath != null && _isSamePath(path, keepPath)) return false;
      final file = File(path);
      if (!file.existsSync()) return false;
      file.deleteSync();
      return true;
    } catch (e) {
      debugPrint('删除系统 TTS 缓存文件失败（忽略）: $e');
      return false;
    }
  }

  /// 路径归一（跨平台分隔符；Windows 大小写不敏感）
  String _normalizePath(String path) {
    var normalized = path.replaceAll('\\', '/');
    if (Platform.isWindows) normalized = normalized.toLowerCase();
    return normalized;
  }

  bool _isSamePath(String a, String b) =>
      _normalizePath(a) == _normalizePath(b);

  /// [path] 是否位于 [dirPath] 内（归一化后按目录前缀判定）
  bool _isInsideDirectory(String dirPath, String path) {
    final dir = _normalizePath(dirPath);
    final file = _normalizePath(path);
    if (file == dir) return false;
    return file.startsWith(dir.endsWith('/') ? dir : '$dir/');
  }

  /// LRU 清理：可选删除超过 [maxCacheAge] 的文件（[pruneAge]），再按 mtime
  /// 保留最新 [maxCacheFiles] 个；返回删除数。
  ///
  /// [pruneAge] 为 false 时只执行数量上限清理——保留时间策略由
  /// [pruneByRetention] 统一负责，避免 48h 旧默认与用户 7 天设置冲突。
  Future<int> pruneCache({bool pruneAge = true}) async {
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
          if (pruneAge && now.difference(modified) > maxCacheAge) {
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

  /// 串行执行合成任务；错误只回传给对应调用方，不打断后续队列
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    final previous = _synthQueue ?? Future<void>.value();
    _synthQueue = previous.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 平台 stop 复位 flutter_tts busy（失败/超时静默）
  Future<void> _resetPlatformBusy() async {
    try {
      await _platform.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 复位失败不覆盖原始合成错误
    }
  }

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
    int epoch,
  ) async {
    // [审查回修 P2-B] 旧代际任务直接取消：不得再触碰缓存文件（否则可能
    // 删除 stop 后新代际同 key 的产物）。
    if (epoch != _epoch) {
      throw const SystemTtsException('系统 TTS 合成已取消');
    }
    // [审查回修 P3] 上次崩溃可能留下半截文件：合成前先删除，避免
    // 插件跳过写入后被误判为「已有有效产物」。
    try {
      final stale = File(path);
      if (stale.existsSync()) stale.deleteSync();
    } catch (_) {}
    try {
      // [审查回修 P2-A] 引擎初始化也在超时保护内（_applyEngineOnly 自带
      // synthesisTimeout）；此处整体 try 保证失败时按代际复位/清理。
      await _applyPlatformState(speed, pitch, volume);
      // [审查回修 P1-1] flutter_tts 的 onError/ERROR 不完成 Future，
      // 必须超时兜底；超时后 stop 复位 busy 再抛，段落链继续估算推进。
      await _platform.synthesizeToFile(text, path).timeout(synthesisTimeout);
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() <= 0) {
        throw const SystemTtsException('系统 TTS 未生成音频文件');
      }
      // [设置批5c] 只做数量上限清理；保留时间由用户设置
      // （pruneByRetention）统一负责，避免旧的 48h 默认提前删除 7 天缓存。
      if (epoch == _epoch) await pruneCache(pruneAge: false);
      return path;
    } catch (e) {
      // [审查回修 P2-B] 仅当前代际允许复位平台/删除文件；stop 后旧任务
      // 的失败清理不得打断刚发起的新合成。
      if (epoch == _epoch) {
        await _resetPlatformBusy();
        // 失败产物（空文件/半文件）不得留在缓存目录被下次误命中
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {}
      }
      if (e is TimeoutException) {
        throw SystemTtsException('系统 TTS 合成超时（${synthesisTimeout.inSeconds}s）');
      }
      if (e is SystemTtsException) rethrow;
      throw SystemTtsException('系统 TTS 合成失败：$e');
    }
  }

  /// 应用引擎选择；引擎变化时清空其余已应用参数（审查回修 P1-2）
  ///
  /// flutter_tts setEngine 会重建 TextToSpeech 实例，音色/语速/音调/音量
  /// 全部回到默认值；若不清空 _applied*，后续合成会误以为参数仍生效而
  /// 不再下发，导致切引擎后参数丢失。
  Future<void> _applyEngineOnly() async {
    final engine = _selectedEngine;
    if (engine == null) {
      // 从「已选引擎」切回「系统默认」：查询系统默认引擎并重新应用。
      // [审查回修 P2] _engineDirty 时即使 _appliedEngine 为 null 也必须
      // reset：迟到的 setEngine 可能已把平台实际停在失败引擎。
      if (_appliedEngine != null || _engineDirty) {
        var ok = false;
        try {
          // [审查回修 P2-A] setEngine/resetEngine 永不返回时不得永久挂起
          await _platform.resetEngine().timeout(synthesisTimeout);
          ok = true;
        } on TimeoutException {
          _appliedEngine = null;
          _engineDirty = true;
          _clearAppliedParams();
          // 丢弃迟到的引擎 init（可能落在失败引擎上）
          try {
            await _platform.resetClient();
          } catch (_) {}
          throw const SystemTtsException('系统 TTS 引擎初始化超时');
        } catch (e) {
          debugPrint('恢复系统默认 TTS 引擎失败: $e');
        }
        _appliedEngine = null;
        _clearAppliedParams();
        _engineDirty = !ok;
      }
    } else if (engine != _appliedEngine || _engineDirty) {
      try {
        await _platform.setEngine(engine).timeout(synthesisTimeout);
      } on TimeoutException {
        _appliedEngine = null;
        _engineDirty = true;
        _clearAppliedParams();
        try {
          await _platform.resetClient();
        } catch (_) {}
        throw const SystemTtsException('系统 TTS 引擎初始化超时');
      } catch (e) {
        _engineDirty = true;
        rethrow;
      }
      _appliedEngine = engine;
      _engineDirty = false;
      _clearAppliedParams();
    }
  }

  void _clearAppliedParams() {
    _appliedVoice = null;
    _appliedSpeed = null;
    _appliedPitch = null;
    _appliedVolume = null;
  }

  Future<void> _applyPlatformState(
    double speed,
    double pitch,
    double volume,
  ) async {
    await _applyEngineOnly();
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
      try {
        await _platform.setVoice(voice);
        _appliedVoice = voice;
      } catch (e) {
        // [审查回修 P2-7] 音色失效：回落系统默认并清除选择，只提示一次；
        // 不让每段合成都失败（下一段 voice==null 且 applied==null 不再重试）。
        debugPrint('设置系统 TTS 音色失败，回落默认: $e');
        try {
          await _platform.clearVoice();
        } catch (_) {}
        _appliedVoice = null;
        await selectVoice(null);
        _pendingNotice ??= '音色不可用，已回退系统默认音色';
      }
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
