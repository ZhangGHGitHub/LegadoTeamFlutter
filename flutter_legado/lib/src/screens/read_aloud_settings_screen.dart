import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../models/models.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../services/platform_channel.dart';
import '../services/read_aloud_timer_settings.dart';
import '../services/settings_service.dart';
import '../services/system_tts_service.dart';
import '../utils/read_aloud_content_split.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/legado_app_bar.dart';

/// 朗读设置页（设置批5a-1）
///
/// 对齐参考版阅读器内「朗读设置」三页签卡片
/// （`ReadAloudConfigContent.kt`：常规 / 引擎与音色 / 角色与配乐）：
/// - **常规**：默认朗读界面、播放器背景、忽略音频焦点（自「其他设置」迁入）、
///   朗读唤醒锁、退出阅读继续朗读、媒体键翻章、电池优化入口、TTS 缓存；
/// - **引擎与音色**：系统 TTS / HTTP 引擎选择、系统引擎/音色、语速/音调/音量；
/// - **角色与配乐**：多角色/BGM/AI 场景等本批未实现项，统一置灰「暂未支持」。
///
/// 红线：**不允许「可点但无效」**——未接线项一律 `enabled: false` 并在副题
/// 明确「暂未支持 / 仅 Android 支持」；Android-only 动作在非 Android 平台
/// 同样置灰。
///
/// — 实现代理 ｜ 2026-11-04
class ReadAloudSettingsScreen extends ConsumerStatefulWidget {
  const ReadAloudSettingsScreen({super.key});

  @override
  ConsumerState<ReadAloudSettingsScreen> createState() =>
      _ReadAloudSettingsScreenState();
}

class _ReadAloudSettingsScreenState
    extends ConsumerState<ReadAloudSettingsScreen>
    with WidgetsBindingObserver {
  SettingsService get _settings => ref.read(settingsProvider);

  bool _loading = true;

  // ===== 常规 =====
  String _defaultInterface = 'classic';
  String _playerBackground = 'solid';
  bool _ignoreAudioFocus = false;
  bool _readAloudWakeLock = false;
  bool _keepReadAloudOnExit = false;
  bool _mediaButtonPerNext = false;

  // ===== 内容分析（设置批5b）=====
  String _speechAnalysisMode = 'rule';
  String _speechAnalysisReasoningLevel = 'OFF';
  ReadAloudContentSplitMode _contentSplitMode =
      ReadAloudContentSplitMode.defaultMode;
  String _contentSplitSymbols = '';
  int _ttsParagraphInterval = kDefaultTtsParagraphIntervalMs;

  // ===== 引擎与音色 =====
  String _effectiveEngine = '';
  List<HttpTts> _httpEngines = const [];
  List<SystemTtsEngine> _systemEngines = const [];
  List<SystemTtsVoice> _systemVoices = const [];
  String? _selectedSystemEngine;
  SystemTtsVoice? _selectedSystemVoice;

  // ===== 语音参数（UI 倍速/音调/音量）=====
  double _speed = 1.0;
  double _pitch = 1.0;
  double _volume = 1.0;

  // ===== 缓存/电池优化 =====
  SystemTtsCacheStats _cacheStats = SystemTtsCacheStats.empty;

  /// 系统 TTS 缓存保留时间（分钟，0 = 即听即焚；设置批5c）
  int _cacheRetentionMinutes = kDefaultReadAloudCacheRetentionMinutes;

  bool? _batteryOptimizationIgnored;

  /// 当前是否 Android（仅 Android 动作的可用性判定；测试可经
  /// `debugDefaultTargetPlatformOverride` 覆盖）
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// 当前平台是否支持系统 TTS 合成（Android/iOS/macOS）
  ///
  /// [审查回修 P2-1/P3] 与平台实现共用 [platformSupportsSystemTts]，
  /// 避免两处 switch 漂移；Windows/Linux 的系统 TTS 与音色项置灰。
  bool get _supportsSystemTts => platformSupportsSystemTts();

  SystemTtsService get _systemTts => ref.read(systemTtsServiceProvider);

  // ===== 内容分析展示（设置批5b）=====

  /// 当前生效标点集合：存储空串按句末标点展示（与朗读实际行为一致）
  Set<String> get _effectiveSplitSymbols =>
      readAloudSymbolSet(_contentSplitSymbols);

  String get _speechAnalysisModeLabel => switch (_speechAnalysisMode) {
    'rule_with_ai' => '规则+AI',
    'ai_understanding' => 'AI 理解',
    _ => '规则',
  };

  String get _speechAnalysisModeSummary => switch (_speechAnalysisMode) {
    'rule_with_ai' || 'ai_understanding' => 'AI 分片暂未支持，实际按规则分片',
    _ => '按标点/段落规则分片',
  };

  String get _reasoningLevelLabel =>
      switch (_speechAnalysisReasoningLevel.toLowerCase()) {
        'off' => '关闭',
        'auto' => '自动',
        'low' => '低',
        'medium' => '中',
        'high' => '高',
        'xhigh' => '极高',
        'max' => '最高',
        _ => _speechAnalysisReasoningLevel,
      };

  String get _contentSplitModeLabel => switch (_contentSplitMode) {
    ReadAloudContentSplitMode.paragraph => '整段',
    ReadAloudContentSplitMode.page => '整页',
    ReadAloudContentSplitMode.symbols => '按符号',
    ReadAloudContentSplitMode.defaultMode => '默认',
  };

  String get _contentSplitModeSummary => switch (_contentSplitMode) {
    ReadAloudContentSplitMode.paragraph => '按空行分段落朗读（保留段内换行）',
    ReadAloudContentSplitMode.page => '按阅读器当前章分页朗读；切章回退整段',
    ReadAloudContentSplitMode.symbols => '按选中标点切分，连续标点同一单元',
    ReadAloudContentSplitMode.defaultMode => '跟随规则分片，当前按整段朗读',
  };

  /// 系统引擎展示名（未选择/已卸载时回退原始值）
  String get systemEngineLabel {
    final name = _selectedSystemEngine;
    if (name == null) return '系统默认';
    for (final engine in _systemEngines) {
      if (engine.name == name) return engine.displayName;
    }
    return name;
  }

  /// 供同库页签视图更新本页状态（State.setState 受 @protected 限制）
  void apply(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// [审查回修 P3] 从系统 TTS 设置页/电池优化页返回时刷新引擎与音色列表
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final s = _settings;
      final notifier = ref.read(audioNotifierProvider.notifier);
      final api = ref.read(bookApiProvider);
      final systemTts = _systemTts;
      // 允许用户在系统设置里新装引擎后回到本页即时看到
      systemTts.invalidateAvailability();
      await systemTts.loadSelection();
      final effective = await notifier.loadEffectiveTtsEngineUrl();
      final httpEngines = await api.getHttpTts();
      final systemEngines = await systemTts.engines();
      final systemVoices = await systemTts.voices();
      final stats = await systemTts.cacheStats();
      final batteryIgnored = _isAndroid
          ? await PlatformChannel.isIgnoringBatteryOptimizations()
          : null;

      final defaultInterface = await s.getStringPref(
        PrefKeys.defaultReadAloudInterface,
        defaultValue: 'classic',
      );
      final playerBackground = await s.getStringPref(
        PrefKeys.readAloudPlayerBackground,
        defaultValue: 'solid',
      );
      final ignoreAudioFocus = await s.getBoolPref(
        PrefKeys.ignoreAudioFocus,
        defaultValue: false,
      );
      final wakeLock = await s.getBoolPref(
        PrefKeys.readAloudWakeLock,
        defaultValue: false,
      );
      final keepOnExit = await s.getBoolPref(
        PrefKeys.keepReadAloudOnExit,
        defaultValue: false,
      );
      final perNext = await s.getBoolPref(
        PrefKeys.mediaButtonPerNext,
        defaultValue: false,
      );
      // [设置批5b] 内容分析偏好：AI 取值只保留展示（选项置灰），未知值归一
      final analysisMode = await s.getStringPref(
        PrefKeys.speechAnalysisMode,
        defaultValue: 'rule',
      );
      final reasoningLevel = await s.getStringPref(
        PrefKeys.speechAnalysisReasoningLevel,
        defaultValue: 'OFF',
      );
      final splitMode = ReadAloudContentSplitMode.fromStorage(
        await s.getStringPref(
          PrefKeys.readAloudContentSplitMode,
          defaultValue: ReadAloudContentSplitMode.defaultMode.storageValue,
        ),
      );
      final splitSymbols = await s.getStringOrStringListPref(
        PrefKeys.readAloudContentSplitSymbols,
        defaultValue: '',
      );
      final paragraphInterval =
          await s.getIntPrefOrNull(PrefKeys.ttsParagraphInterval) ??
          kDefaultTtsParagraphIntervalMs;
      final rate = await s.getIntPrefOrNull(PrefKeys.ttsSpeechRate);
      final pitch = await s.getIntPrefOrNull(PrefKeys.ttsPitch);
      final volume = await s.getIntPrefOrNull(PrefKeys.ttsVolume);
      final cacheRetention = normalizeReadAloudCacheRetentionMinutes(
        await s.getIntPrefOrNull(PrefKeys.readAloudCacheRetentionMinutes) ??
            kDefaultReadAloudCacheRetentionMinutes,
      );
      // [审查回修 P2-4] 偏好缺失时取当前有效 config（可能是书级读回/播放
      // 会话值），不要直接回落 1.0 造成设置页与播放值不一致。
      final cfg = ref.read(audioNotifierProvider).config;

      if (!mounted) return;
      setState(() {
        _effectiveEngine = effective;
        _httpEngines = httpEngines;
        _systemEngines = systemEngines;
        _systemVoices = systemVoices;
        _selectedSystemEngine = systemTts.selectedEngineName;
        _selectedSystemVoice = systemTts.selectedVoice;
        _cacheStats = stats;
        _cacheRetentionMinutes = cacheRetention;
        _batteryOptimizationIgnored = batteryIgnored;
        _defaultInterface = defaultInterface == 'player' ? 'player' : 'classic';
        _playerBackground = playerBackground == 'transparent'
            ? 'transparent'
            : 'solid';
        _ignoreAudioFocus = ignoreAudioFocus;
        _readAloudWakeLock = wakeLock;
        _keepReadAloudOnExit = keepOnExit;
        _mediaButtonPerNext = perNext;
        _speechAnalysisMode = switch (analysisMode) {
          'rule_with_ai' || 'ai_understanding' => analysisMode,
          _ => 'rule',
        };
        _speechAnalysisReasoningLevel = reasoningLevel.trim().isEmpty
            ? 'OFF'
            : reasoningLevel;
        _contentSplitMode = splitMode;
        _contentSplitSymbols = splitSymbols;
        _ttsParagraphInterval = paragraphInterval < 0
            ? 0
            : (paragraphInterval > kMaxTtsParagraphIntervalMs
                  ? kMaxTtsParagraphIntervalMs
                  : paragraphInterval);
        _speed = rate == null ? cfg.speed : ttsSpeedFromSpeechRate(rate);
        _pitch = pitch == null
            ? cfg.pitch
            : ttsPitchFromStored(pitch, fallback: cfg.pitch);
        _volume = volume == null
            ? cfg.volume
            : ttsVolumeFromStored(volume, fallback: cfg.volume);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取朗读设置失败：$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ===== 常规项写入 =====

  Future<void> _setStringPref(String key, String value) async {
    await _settings.setStringPref(key, value);
  }

  Future<void> _pickDefaultInterface() async {
    final result = await _showChoiceDialog<String>(
      title: '默认朗读界面',
      options: const [
        ('classic', '经典', '阅读器内朗读控制条'),
        ('player', '播放器', '启动朗读后进入听书播放器'),
      ],
      current: _defaultInterface,
    );
    if (result.cancelled) return;
    final selected = result.value!;
    setState(() => _defaultInterface = selected);
    await _setStringPref(PrefKeys.defaultReadAloudInterface, selected);
  }

  Future<void> _pickPlayerBackground() async {
    final result = await _showChoiceDialog<String>(
      title: '播放器背景',
      options: const [
        ('solid', '纯色', '跟随当前主题背景'),
        ('transparent', '透明', '露出全局背景图/壁纸'),
        ('blur', '模糊', '暂未支持'),
        ('flow', '流光', '暂未支持'),
      ],
      current: _playerBackground,
      disabledValues: const {'blur', 'flow'},
    );
    if (result.cancelled) return;
    final selected = result.value!;
    setState(() => _playerBackground = selected);
    await _setStringPref(PrefKeys.readAloudPlayerBackground, selected);
  }

  // ===== 内容分析（设置批5b）=====

  /// 章节分片方式：仅「规则」可选；AI 两项保留展示但置灰
  Future<void> _pickSpeechAnalysisMode() async {
    final result = await _showChoiceDialog<String>(
      title: '章节分片方式',
      options: const [
        ('rule', '规则', '按标点/段落规则分片（当前唯一可用）'),
        ('rule_with_ai', '规则+AI', '暂未支持'),
        ('ai_understanding', 'AI 理解', '暂未支持'),
      ],
      current: _speechAnalysisMode,
      disabledValues: const {'rule_with_ai', 'ai_understanding'},
    );
    if (result.cancelled) return;
    final selected = result.value!;
    setState(() => _speechAnalysisMode = selected);
    await _setStringPref(PrefKeys.speechAnalysisMode, selected);
  }

  /// 内容划分方式：default/paragraph/page/symbols
  Future<void> _pickContentSplitMode() async {
    final result = await _showChoiceDialog<ReadAloudContentSplitMode>(
      title: '内容划分方式',
      options: const [
        (ReadAloudContentSplitMode.defaultMode, '默认', '跟随规则分片，当前按整段朗读'),
        (ReadAloudContentSplitMode.paragraph, '整段', '按空行分段落朗读'),
        (ReadAloudContentSplitMode.page, '整页', '按阅读器当前章分页朗读'),
        (ReadAloudContentSplitMode.symbols, '按符号', '按选中标点切分'),
      ],
      current: _contentSplitMode,
    );
    if (result.cancelled) return;
    final selected = result.value!;
    setState(() => _contentSplitMode = selected);
    await _setStringPref(
      PrefKeys.readAloudContentSplitMode,
      selected.storageValue,
    );
    if (!mounted) return;
    // 即时更新内存镜像：下一次起播/切章生效，不打断当前朗读队列
    ref
        .read(audioNotifierProvider.notifier)
        .setContentSplitPreferences(
          mode: selected,
          symbols: _contentSplitSymbols,
        );
  }

  /// 标点多选：至少保留一个；空存储展示句末默认集合
  Future<void> _toggleSplitSymbol(String symbol) async {
    final next = {..._effectiveSplitSymbols};
    if (!next.remove(symbol)) next.add(symbol);
    if (next.isEmpty) {
      _toast('至少保留一个标点');
      return;
    }
    final encoded = encodeReadAloudSymbols(next);
    setState(() => _contentSplitSymbols = encoded);
    // [审查回修 P2-2] 参考版 StringSet 形态：按字符写入 StringList；
    // 读取侧 getStringOrStringListPref 同时兼容历史 String 与外部数组。
    await _settings.setStringListPref(
      PrefKeys.readAloudContentSplitSymbols,
      encoded.split(''),
    );
    if (!mounted) return;
    ref
        .read(audioNotifierProvider.notifier)
        .setContentSplitPreferences(mode: _contentSplitMode, symbols: encoded);
  }

  Future<void> _persistParagraphInterval() => _settings.setIntPref(
    PrefKeys.ttsParagraphInterval,
    _ttsParagraphInterval,
  );

  // ===== 引擎与音色 =====

  /// 当前是否选中系统 TTS（空 = 未配置，同样按系统 TTS 处理）
  bool get _systemSelected =>
      _effectiveEngine.isEmpty || _effectiveEngine == kSystemTtsEngineUrl;

  Future<void> _selectGlobalEngine(String url) async {
    final notifier = ref.read(audioNotifierProvider.notifier);
    await notifier.setGlobalTtsEngine(url);
    if (!mounted) return;
    setState(() => _effectiveEngine = url);
    _toast(url == kSystemTtsEngineUrl ? '已切换为系统 TTS' : '已切换朗读引擎');
  }

  Future<void> _openEngineManager() async {
    await Navigator.pushNamed(context, AppRoutes.readAloudConfig);
    if (!mounted) return;
    await _load();
  }

  Future<void> _pickSystemEngine() async {
    final options = <(String?, String, String)>[
      (null, '系统默认', '跟随系统 TTS 设置'),
      for (final engine in _systemEngines)
        (engine.name, engine.displayName, engine.name),
    ];
    final result = await _showChoiceDialog<String?>(
      title: '系统 TTS 引擎',
      options: options,
      current: _selectedSystemEngine,
    );
    // null 既可能是「取消」也可能是「系统默认」：由结果对象区分
    if (result.cancelled) return;
    final engineName = result.value;
    final hadVoice = _selectedSystemVoice != null;
    // [审查回修 P2-7] 切引擎后立即刷新音色列表；原音色在新引擎不可用时
    // 服务已清除选择并回落默认（返回列表同步到页面）。
    final voices = await _systemTts.selectEngine(engineName);
    if (!mounted) return;
    if (voices == null) {
      // [审查回修 P2-A/P3] 引擎初始化失败/超时：以服务回滚后的选择为准
      // （含持久化），页面同步选中态，不提示「已切换」。
      setState(() {
        _selectedSystemEngine = _systemTts.selectedEngineName;
        _selectedSystemVoice = _systemTts.selectedVoice;
      });
      _toast('引擎初始化失败');
      return;
    }
    final voiceCleared = hadVoice && _systemTts.selectedVoice == null;
    // [审查回修 P3] 页面已用 toast 告知音色回退，消费服务一次性提示，
    // 避免播放时再次弹出同一条提示。
    if (voiceCleared) _systemTts.takeNotice();
    setState(() {
      _selectedSystemEngine = _systemTts.selectedEngineName;
      _systemVoices = voices;
      _selectedSystemVoice = _systemTts.selectedVoice;
    });
    _toast(
      voiceCleared
          ? '已切换系统引擎；原音色不可用，已回退系统默认'
          : (engineName == null ? '已使用系统默认引擎' : '已切换系统引擎'),
    );
  }

  Future<void> _pickSystemVoice() async {
    final sorted = [..._systemVoices]
      ..sort((a, b) {
        final aZh = a.locale.toLowerCase().startsWith('zh');
        final bZh = b.locale.toLowerCase().startsWith('zh');
        if (aZh != bZh) return aZh ? -1 : 1;
        return a.displayName.compareTo(b.displayName);
      });
    // [审查回修 P3] 同名不同 locale 的音色必须可区分：选项值用
    // name+locale 复合键，不用裸 name。
    String voiceKey(SystemTtsVoice voice) =>
        '${voice.name}\u0001${voice.locale}';
    final options = <(String?, String, String)>[
      (null, '系统默认', '跟随系统 TTS 设置'),
      for (final voice in sorted)
        (voiceKey(voice), voice.displayName, voice.locale),
    ];
    final currentVoice = _selectedSystemVoice;
    final result = await _showChoiceDialog<String?>(
      title: '系统 TTS 音色',
      options: options,
      current: currentVoice == null ? null : voiceKey(currentVoice),
    );
    if (result.cancelled) return;
    final key = result.value;
    SystemTtsVoice? voice;
    if (key != null) {
      voice = sorted.firstWhere(
        (v) => voiceKey(v) == key,
        orElse: () => const SystemTtsVoice(name: '', locale: ''),
      );
      if (voice.name.isEmpty && voice.locale.isEmpty) voice = null;
    }
    await _systemTts.selectVoice(voice);
    if (!mounted) return;
    setState(() => _selectedSystemVoice = voice);
    _toast(voice == null ? '已使用系统默认音色' : '已切换系统音色');
  }

  Future<void> _openSystemTtsSettings() async {
    final ok = await PlatformChannel.openTtsSettings();
    if (!mounted) return;
    if (!ok) {
      _toast('无法打开系统设置，请手动进入「系统设置 → 文字转语音」');
    }
  }

  Future<void> _openBatteryOptimizationSettings() async {
    final ok = await PlatformChannel.openBatteryOptimizationSettings();
    if (!mounted) return;
    if (!ok) {
      _toast('无法打开电池优化设置，请手动在系统设置中关闭本应用电池优化');
      return;
    }
    // 用户可能在设置页停留后返回：回到前台时由 _load 刷新状态
    final ignored = await PlatformChannel.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() => _batteryOptimizationIgnored = ignored);
  }

  /// 语速/音调/音量：各滑块只落自身键（审查回修 P2-4）
  ///
  /// 拖动音量不应顺带改写语速偏好；参考刻度换算统一走 service 纯函数。
  Future<void> _persistSpeed() => _settings.setIntPref(
    PrefKeys.ttsSpeechRate,
    ttsSpeechRateFromSpeed(_speed),
  );

  Future<void> _persistPitch() =>
      _settings.setIntPref(PrefKeys.ttsPitch, ttsPitchToStored(_pitch));

  Future<void> _persistVolume() =>
      _settings.setIntPref(PrefKeys.ttsVolume, ttsVolumeToStored(_volume));

  // ===== 缓存 =====

  Future<void> _reloadCacheStats() async {
    final stats = await _systemTts.cacheStats();
    if (!mounted) return;
    setState(() => _cacheStats = stats);
  }

  /// 保存缓存保留时间并即时同步 Notifier（设置批5c）
  Future<void> _persistCacheRetention(int minutes) async {
    final normalized = normalizeReadAloudCacheRetentionMinutes(minutes);
    if (mounted) {
      setState(() => _cacheRetentionMinutes = normalized);
    }
    ref
        .read(audioNotifierProvider.notifier)
        .setCacheRetentionMinutes(normalized);
    await _settings.setIntPref(
      PrefKeys.readAloudCacheRetentionMinutes,
      normalized,
    );
  }

  /// 缓存保留时间选择对话框（设置批5c 设置页行）
  ///
  /// 0 = 即听即焚；其余值在朗读入口/进入缓存行时按 mtime 清理过期文件。
  /// 选择即时持久化并同步 Notifier；本对话框只做设置，不立即删缓存。
  Future<void> _showCacheRetentionDialog() async {
    var draftMinutes = _cacheRetentionMinutes;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('缓存保留时间'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前：${readAloudCacheRetentionLabel(draftMinutes)}',
                  key: const ValueKey('cache-retention-dialog-label'),
                ),
                Slider(
                  key: const ValueKey('cache-retention-dialog-slider'),
                  value: draftMinutes
                      .clamp(
                        kMinReadAloudCacheRetentionMinutes,
                        kMaxReadAloudCacheRetentionMinutes,
                      )
                      .toDouble(),
                  min: kMinReadAloudCacheRetentionMinutes.toDouble(),
                  max: kMaxReadAloudCacheRetentionMinutes.toDouble(),
                  label: readAloudCacheRetentionLabel(draftMinutes),
                  onChanged: (value) {
                    setDialogState(() => draftMinutes = value.round());
                  },
                  onChangeEnd: (value) {
                    final minutes = value.round();
                    setDialogState(() => draftMinutes = minutes);
                    unawaited(_persistCacheRetention(minutes));
                  },
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in const [0, 10, 60, 1440, 10080])
                      ChoiceChip(
                        label: Text(readAloudCacheRetentionLabel(preset)),
                        selected: draftMinutes == preset,
                        onSelected: (_) {
                          setDialogState(() => draftMinutes = preset);
                          unawaited(_persistCacheRetention(preset));
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '0 表示即听即焚：每段系统 TTS 播放完成/失败后立即删除；'
                  '其余值在朗读开始时按修改时间清理过期缓存，正在播放的文件'
                  '始终保留。HTTP 引擎（Rust）缓存不在此策略内。',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCacheDialog() async {
    final notifier = ref.read(audioNotifierProvider.notifier);
    // [设置批5c] 进入缓存行即按保留时间清理一次（失败静默，服务内 debugPrint）
    try {
      await _systemTts.pruneByRetention(
        _cacheRetentionMinutes,
        keepPath: notifier.currentPlaybackFilePath,
      );
    } catch (e) {
      debugPrint('进入缓存设置时清理系统 TTS 缓存失败（忽略）: $e');
    }
    await _reloadCacheStats();
    if (!mounted) return;
    var draftMinutes = _cacheRetentionMinutes;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('TTS 缓存'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '系统 TTS 合成缓存：${_cacheStats.fileCount} 个文件，'
                  '共 ${_formatBytes(_cacheStats.totalBytes)}。\n'
                  '缓存仅用于加速重复段落朗读，清理后可随时重新生成。',
                ),
                const SizedBox(height: 16),
                Text(
                  '保留时间：${readAloudCacheRetentionLabel(draftMinutes)}',
                  key: const ValueKey('tts-cache-retention-label'),
                ),
                Slider(
                  key: const ValueKey('tts-cache-retention-slider'),
                  value: draftMinutes
                      .clamp(
                        kMinReadAloudCacheRetentionMinutes,
                        kMaxReadAloudCacheRetentionMinutes,
                      )
                      .toDouble(),
                  min: kMinReadAloudCacheRetentionMinutes.toDouble(),
                  max: kMaxReadAloudCacheRetentionMinutes.toDouble(),
                  label: readAloudCacheRetentionLabel(draftMinutes),
                  onChanged: (value) {
                    setDialogState(() => draftMinutes = value.round());
                  },
                  onChangeEnd: (value) {
                    final minutes = value.round();
                    setDialogState(() => draftMinutes = minutes);
                    unawaited(_persistCacheRetention(minutes));
                  },
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in const [0, 10, 60, 1440, 10080])
                      ChoiceChip(
                        label: Text(readAloudCacheRetentionLabel(preset)),
                        selected: draftMinutes == preset,
                        onSelected: (_) {
                          setDialogState(() => draftMinutes = preset);
                          unawaited(_persistCacheRetention(preset));
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '0 表示即听即焚：每段系统 TTS 播放完成/失败后立即删除；'
                  'HTTP 引擎（Rust）缓存不在此策略内。',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清理'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    // [设置批5c] 清理不得删除正在播放的文件
    final deleted = await _systemTts.clearCache(
      keepPath: ref
          .read(audioNotifierProvider.notifier)
          .currentPlaybackFilePath,
    );
    await _reloadCacheStats();
    if (!mounted) return;
    _toast('已清理 $deleted 个缓存文件');
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: AppScaffold(
        topBar: LegadoAppBar(
          title: const Text('朗读设置'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '常规'),
              Tab(text: '引擎与音色'),
              Tab(text: '角色与配乐'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            // 页签视图每次重建都新建实例：页签以 `findAncestorStateOfType`
            // 读取本页 State，若沿用 const 实例，Element 会因 widget 全等
            // 跳过 rebuild，开关/选择结果不即时刷新（批5a-1 自测发现）。
            : TabBarView(children: [_GeneralTab(), _EngineTab(), _RoleTab()]),
      ),
    );
  }

  /// 通用选择对话框（返回选中值；取消/点外部关闭返回 [ _ChoiceResult.cancelled ]）
  Future<_ChoiceResult<T>> _showChoiceDialog<T>({
    required String title,
    required List<(T, String, String)> options,
    required T current,
    Set<T> disabledValues = const {},
  }) async {
    final result = await showDialog<_ChoiceResult<T>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final option in options)
                ListTile(
                  enabled: !disabledValues.contains(option.$1),
                  title: Text(option.$2),
                  subtitle: Text(option.$3),
                  trailing: option.$1 == current
                      ? Icon(
                          Icons.radio_button_checked,
                          color: Theme.of(ctx).colorScheme.primary,
                        )
                      : const Icon(Icons.radio_button_unchecked),
                  onTap: disabledValues.contains(option.$1)
                      ? null
                      : () => Navigator.pop(
                          ctx,
                          _ChoiceResult<T>.selected(option.$1),
                        ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ChoiceResult<T>.cancelled()),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    // 点遮罩关闭返回 null：同样按取消处理
    return result ?? _ChoiceResult<T>.cancelled();
  }
}

/// 选择对话框结果：区分「取消」与「选中了 null 值（系统默认）」
class _ChoiceResult<T> {
  const _ChoiceResult.selected(this.value) : cancelled = false;

  _ChoiceResult.cancelled() : value = null, cancelled = true;

  final T? value;
  final bool cancelled;
}

// ===== 页签内容 =====
//
// 页签是页面 State 的内部视图：通过 `context.findAncestorStateOfType` 取
// 状态，避免把十余个回调逐个下传（页面私有，不对外复用）。

_ReadAloudSettingsScreenState _stateOf(BuildContext context) {
  final state = context
      .findAncestorStateOfType<_ReadAloudSettingsScreenState>();
  assert(state != null, '朗读设置页签必须在 ReadAloudSettingsScreen 内使用');
  return state!;
}

/// 常规页签
class _GeneralTab extends StatelessWidget {
  const _GeneralTab();

  @override
  Widget build(BuildContext context) {
    final state = _stateOf(context);
    final isAndroid = state._isAndroid;
    final batterySubtitle = !isAndroid
        ? '仅 Android 支持'
        : switch (state._batteryOptimizationIgnored) {
            true => '已忽略电池优化',
            false => '未忽略电池优化，点击前往设置',
            null => '点击前往系统电池优化设置',
          };
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const IosSectionHeader('界面'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(
              title: '默认朗读界面',
              subtitle: '从阅读器启动朗读时进入的界面',
              value: state._defaultInterface == 'player' ? '播放器' : '经典',
              onTap: state._pickDefaultInterface,
            ),
            IosListTile(
              title: '播放器背景',
              subtitle: '听书播放器页的背景样式',
              value: state._playerBackground == 'transparent' ? '透明' : '纯色',
              onTap: state._pickPlayerBackground,
            ),
            const SettingSwitchRow(
              title: '显示朗读胶囊',
              subtitle: '暂未支持',
              value: false,
              onChanged: null,
            ),
            const SettingSwitchRow(
              title: '自动收缩朗读胶囊',
              subtitle: '暂未支持',
              value: false,
              onChanged: null,
            ),
            const IosListTile(
              title: '重置朗读胶囊位置',
              subtitle: '暂未支持',
              enabled: false,
            ),
          ],
        ),
        const IosSectionHeader('播放'),
        IosGroup(
          flat: true,
          children: [
            SettingSwitchRow(
              title: '忽略音频焦点',
              subtitle: '允许与其他应用同时播放音频',
              value: state._ignoreAudioFocus,
              onChanged: (v) {
                state.apply(() => state._ignoreAudioFocus = v);
                state._settings.setBoolPref(PrefKeys.ignoreAudioFocus, v);
              },
            ),
            SettingSwitchRow(
              title: '朗读唤醒锁',
              subtitle: isAndroid ? '朗读期间保持 CPU 唤醒' : '仅 Android 支持',
              value: state._readAloudWakeLock,
              onChanged: isAndroid
                  ? (v) {
                      state.apply(() => state._readAloudWakeLock = v);
                      state._settings.setBoolPref(
                        PrefKeys.readAloudWakeLock,
                        v,
                      );
                      // 立即应用/释放（不必等下一次朗读会话）
                      state.ref
                          .read(audioNotifierProvider.notifier)
                          .setReadAloudWakeLock(v);
                    }
                  : null,
            ),
            const SettingSwitchRow(
              title: '来电时暂停朗读',
              subtitle: '需电话权限，暂未支持',
              value: false,
              onChanged: null,
            ),
            SettingSwitchRow(
              title: '退出阅读时继续朗读',
              subtitle: '关闭时退出阅读器即停止本次朗读',
              value: state._keepReadAloudOnExit,
              onChanged: (v) {
                state.apply(() => state._keepReadAloudOnExit = v);
                state._settings.setBoolPref(PrefKeys.keepReadAloudOnExit, v);
              },
            ),
            SettingSwitchRow(
              title: '媒体键上一首/下一首翻章',
              subtitle: isAndroid ? '关闭时朗读按段落移动' : '仅 Android 支持',
              value: state._mediaButtonPerNext,
              onChanged: isAndroid
                  ? (v) {
                      state.apply(() => state._mediaButtonPerNext = v);
                      state._settings.setBoolPref(
                        PrefKeys.mediaButtonPerNext,
                        v,
                      );
                      // 立即生效（耳机键服务每次按键读偏好，Notifier 镜像同步）
                      state.ref
                          .read(audioNotifierProvider.notifier)
                          .setMediaButtonPerNext(v);
                    }
                  : null,
            ),
            SettingSwitchRow(
              title: '安卓媒体控制兼容',
              subtitle: isAndroid ? '暂未支持' : '仅 Android 支持',
              value: false,
              onChanged: null,
            ),
            const SettingSwitchRow(
              title: '流式朗读',
              subtitle: '暂未支持',
              value: false,
              onChanged: null,
            ),
            IosListTile(
              title: '后台保活 / 电池优化',
              subtitle: batterySubtitle,
              enabled: isAndroid,
              onTap: isAndroid ? state._openBatteryOptimizationSettings : null,
            ),
          ],
        ),
        const IosSectionHeader('内容分析'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(
              key: const ValueKey('read-aloud-analysis-mode'),
              title: '章节分片方式',
              subtitle: state._speechAnalysisModeSummary,
              value: state._speechAnalysisModeLabel,
              onTap: state._pickSpeechAnalysisMode,
            ),
            IosListTile(
              key: const ValueKey('read-aloud-reasoning-level'),
              title: '推理级别',
              subtitle: '仅 AI 分片时生效（暂未支持）',
              value: state._reasoningLevelLabel,
              enabled: false,
            ),
            IosListTile(
              key: const ValueKey('read-aloud-content-split-mode'),
              title: '内容划分方式',
              subtitle: state._contentSplitModeSummary,
              value: state._contentSplitModeLabel,
              onTap: state._pickContentSplitMode,
            ),
          ],
        ),
        if (state._contentSplitMode == ReadAloudContentSplitMode.symbols)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '切分标点（可多选）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final symbol in kReadAloudSplitSymbols.split(''))
                      FilterChip(
                        key: ValueKey('read-aloud-split-symbol-$symbol'),
                        label: Text(symbol),
                        selected: state._effectiveSplitSymbols.contains(symbol),
                        onSelected: (_) => state._toggleSplitSymbol(symbol),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  state._contentSplitSymbols.trim().isEmpty
                      ? '未选择时按句末标点 。！？… 划分'
                      : '已选 ${state._effectiveSplitSymbols.length} 个标点；'
                            '连续标点归入同一单元',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        IosGroup(
          flat: true,
          footer: const IosSectionFooter('0 表示段间不额外等待；调整后下一次段落推进生效。'),
          children: [
            _SliderRow(
              key: const ValueKey('read-aloud-paragraph-interval-slider'),
              title: '段落间隔',
              valueLabel: '${state._ttsParagraphInterval} ms',
              value: state._ttsParagraphInterval.toDouble(),
              min: 0,
              max: kMaxTtsParagraphIntervalMs.toDouble(),
              divisions: 50,
              onChanged: (v) {
                final ms = v.round();
                state.apply(() => state._ttsParagraphInterval = ms);
                state.ref
                    .read(audioNotifierProvider.notifier)
                    .setTtsParagraphInterval(ms);
              },
              onChangeEnd: state._persistParagraphInterval,
            ),
          ],
        ),
        const IosSectionHeader('缓存'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(
              key: const ValueKey('read-aloud-cache-retention'),
              title: '缓存保留时间',
              subtitle: '0 = 即听即焚；超时缓存在朗读开始时清理',
              value: readAloudCacheRetentionLabel(state._cacheRetentionMinutes),
              onTap: state._showCacheRetentionDialog,
            ),
            IosListTile(
              title: 'TTS 缓存',
              subtitle:
                  '${state._cacheStats.fileCount} 个文件 · '
                  '${_ReadAloudSettingsScreenState._formatBytes(state._cacheStats.totalBytes)} · '
                  '保留 ${readAloudCacheRetentionLabel(state._cacheRetentionMinutes)}',
              onTap: state._showCacheDialog,
            ),
          ],
        ),
      ],
    );
  }
}

/// 引擎与音色页签
class _EngineTab extends StatelessWidget {
  const _EngineTab();

  @override
  Widget build(BuildContext context) {
    final state = _stateOf(context);
    final isAndroid = state._isAndroid;
    final supportsSystemTts = state._supportsSystemTts;
    final systemSelected = state._systemSelected;
    final selectedEngineLabel = state.systemEngineLabel;
    final selectedVoiceLabel =
        state._selectedSystemVoice?.displayName ?? '系统默认';

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const IosSectionHeader('朗读引擎'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(
              key: const ValueKey('read-aloud-engine-system'),
              title: '系统 TTS',
              subtitle: supportsSystemTts
                  ? '使用系统内置语音引擎（无需网络）'
                  : '仅 Android/iOS/macOS 支持',
              trailing: Icon(
                systemSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: systemSelected
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              enabled: supportsSystemTts,
              onTap: supportsSystemTts
                  ? () => state._selectGlobalEngine(kSystemTtsEngineUrl)
                  : null,
            ),
            for (final engine in state._httpEngines)
              Builder(
                builder: (context) {
                  final url = normalizeTtsEngineUrl(engine.url);
                  final selected =
                      !systemSelected && state._effectiveEngine == url;
                  return IosListTile(
                    key: ValueKey('read-aloud-engine-$url'),
                    title: engine.name,
                    subtitle: engine.url,
                    trailing: Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onTap: () => state._selectGlobalEngine(url),
                  );
                },
              ),
            IosListTile(
              title: '管理朗读引擎',
              subtitle: state._httpEngines.isEmpty
                  ? '暂无 HTTP 引擎，点击添加'
                  : '新增、编辑或删除 HTTP TTS 引擎',
              onTap: state._openEngineManager,
            ),
          ],
        ),
        const IosSectionHeader('系统引擎与音色'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(
              key: const ValueKey('read-aloud-system-engine'),
              title: '系统引擎',
              subtitle: !isAndroid
                  ? '仅 Android 支持'
                  : (state._systemEngines.isEmpty
                        ? '系统未安装 TTS 引擎'
                        : '选择系统 TTS 引擎'),
              value: selectedEngineLabel,
              enabled: isAndroid && state._systemEngines.isNotEmpty,
              onTap: isAndroid && state._systemEngines.isNotEmpty
                  ? state._pickSystemEngine
                  : null,
            ),
            IosListTile(
              key: const ValueKey('read-aloud-system-voice'),
              title: '音色',
              subtitle: !supportsSystemTts
                  ? '仅 Android/iOS/macOS 支持'
                  : (state._systemVoices.isEmpty ? '无可用音色' : '选择系统 TTS 音色'),
              value: selectedVoiceLabel,
              enabled: supportsSystemTts && state._systemVoices.isNotEmpty,
              onTap: supportsSystemTts && state._systemVoices.isNotEmpty
                  ? state._pickSystemVoice
                  : null,
            ),
            IosListTile(
              title: '系统 TTS 设置',
              subtitle: isAndroid ? '打开系统「文字转语音」设置' : '仅 Android 支持',
              enabled: isAndroid,
              onTap: isAndroid ? state._openSystemTtsSettings : null,
            ),
          ],
        ),
        const IosSectionHeader('语音参数'),
        IosGroup(
          flat: true,
          footer: const IosSectionFooter(
            '音调/音量仅对系统 TTS 生效；HTTP 引擎当前仅语速生效'
            '（Rust 合成管线限制，已登记）。',
          ),
          children: [
            _SliderRow(
              key: const ValueKey('read-aloud-speed-slider'),
              title: '语速',
              valueLabel: '${state._speed.toStringAsFixed(1)}x',
              value: state._speed,
              min: kMinTtsSpeed,
              max: kMaxTtsSpeed,
              divisions: 25,
              onChanged: (v) {
                state.apply(() => state._speed = v);
                // [审查回修 P2-4] 流媒体听书语速由书级 playSpeed 管理，
                // 此处只落 TTS 全局偏好，不把正在播放的音频书变速。
                final notifier = state.ref.read(audioNotifierProvider.notifier);
                if (!state.ref.read(audioNotifierProvider).isStreamMode) {
                  notifier.updateConfig(speed: v);
                }
              },
              onChangeEnd: state._persistSpeed,
            ),
            _SliderRow(
              key: const ValueKey('read-aloud-pitch-slider'),
              title: '音调',
              valueLabel: state._pitch.toStringAsFixed(1),
              value: state._pitch,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              onChanged: (v) {
                state.apply(() => state._pitch = v);
                state.ref
                    .read(audioNotifierProvider.notifier)
                    .updateConfig(pitch: v);
              },
              onChangeEnd: state._persistPitch,
            ),
            _SliderRow(
              key: const ValueKey('read-aloud-volume-slider'),
              title: '音量',
              valueLabel: '${(state._volume * 100).round()}%',
              value: state._volume,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: (v) {
                state.apply(() => state._volume = v);
                state.ref
                    .read(audioNotifierProvider.notifier)
                    .updateConfig(volume: v);
              },
              onChangeEnd: state._persistVolume,
            ),
          ],
        ),
      ],
    );
  }
}

/// 角色与配乐页签（本批全部置灰）
class _RoleTab extends StatelessWidget {
  const _RoleTab();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: const [
        IosSectionHeader('角色'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(title: '多角色朗读', subtitle: '暂未支持', enabled: false),
            IosListTile(title: '角色分配', subtitle: '暂未支持', enabled: false),
            IosListTile(title: '人物配音', subtitle: '暂未支持', enabled: false),
            IosListTile(title: '声音池', subtitle: '暂未支持', enabled: false),
          ],
        ),
        IosSectionHeader('配乐'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(title: 'BGM 分配', subtitle: '暂未支持', enabled: false),
            IosListTile(title: 'BGM 池', subtitle: '暂未支持', enabled: false),
            IosListTile(title: '本章 BGM', subtitle: '暂未支持', enabled: false),
            IosListTile(title: 'AI 场景识别', subtitle: '暂未支持', enabled: false),
          ],
        ),
      ],
    );
  }
}

/// 滑块行（标题 + 滑块 + 当前值）
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    super.key,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final VoidCallback onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                valueLabel,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
            onChangeEnd: (_) => onChangeEnd(),
          ),
        ],
      ),
    );
  }
}
