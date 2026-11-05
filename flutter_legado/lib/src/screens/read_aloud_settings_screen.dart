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
import '../services/settings_service.dart';
import '../services/system_tts_service.dart';
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
    extends ConsumerState<ReadAloudSettingsScreen> {
  SettingsService get _settings => ref.read(settingsProvider);

  bool _loading = true;

  // ===== 常规 =====
  String _defaultInterface = 'classic';
  String _playerBackground = 'solid';
  bool _ignoreAudioFocus = false;
  bool _readAloudWakeLock = false;
  bool _keepReadAloudOnExit = false;
  bool _mediaButtonPerNext = false;

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
  bool? _batteryOptimizationIgnored;

  /// 当前是否 Android（仅 Android 动作的可用性判定；测试可经
  /// `debugDefaultTargetPlatformOverride` 覆盖）
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  SystemTtsService get _systemTts => ref.read(systemTtsServiceProvider);

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
    _load();
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
      final rate = await s.getIntPrefOrNull(PrefKeys.ttsSpeechRate);
      final pitch = await s.getIntPrefOrNull(PrefKeys.ttsPitch);
      final volume = await s.getIntPrefOrNull(PrefKeys.ttsVolume);

      if (!mounted) return;
      setState(() {
        _effectiveEngine = effective;
        _httpEngines = httpEngines;
        _systemEngines = systemEngines;
        _systemVoices = systemVoices;
        _selectedSystemEngine = systemTts.selectedEngineName;
        _selectedSystemVoice = systemTts.selectedVoice;
        _cacheStats = stats;
        _batteryOptimizationIgnored = batteryIgnored;
        _defaultInterface = defaultInterface == 'player' ? 'player' : 'classic';
        _playerBackground =
            playerBackground == 'transparent' ? 'transparent' : 'solid';
        _ignoreAudioFocus = ignoreAudioFocus;
        _readAloudWakeLock = wakeLock;
        _keepReadAloudOnExit = keepOnExit;
        _mediaButtonPerNext = perNext;
        _speed = ttsSpeedFromSpeechRate(rate);
        _pitch = ttsPitchFromStored(pitch);
        _volume = ttsVolumeFromStored(volume);
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
    await _systemTts.selectEngine(engineName);
    if (!mounted) return;
    setState(() => _selectedSystemEngine = engineName);
    _toast(engineName == null ? '已使用系统默认引擎' : '已切换系统引擎');
  }

  Future<void> _pickSystemVoice() async {
    final sorted = [..._systemVoices]..sort((a, b) {
        final aZh = a.locale.toLowerCase().startsWith('zh');
        final bZh = b.locale.toLowerCase().startsWith('zh');
        if (aZh != bZh) return aZh ? -1 : 1;
        return a.displayName.compareTo(b.displayName);
      });
    final options = <(String?, String, String)>[
      (null, '系统默认', '跟随系统 TTS 设置'),
      for (final voice in sorted) (voice.name, voice.displayName, voice.locale),
    ];
    final result = await _showChoiceDialog<String?>(
      title: '系统 TTS 音色',
      options: options,
      current: _selectedSystemVoice?.name,
    );
    if (result.cancelled) return;
    final name = result.value;
    SystemTtsVoice? voice;
    if (name != null) {
      voice = sorted.firstWhere(
        (v) => v.name == name,
        orElse: () => SystemTtsVoice(name: name, locale: ''),
      );
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

  /// 语速/音调/音量：本地即时生效 + 持久化（参考刻度）
  Future<void> _persistVoiceParams() async {
    await _settings.setIntPref(
      PrefKeys.ttsSpeechRate,
      ttsSpeechRateFromSpeed(_speed),
    );
    await _settings.setIntPref(PrefKeys.ttsPitch, ttsPitchToStored(_pitch));
    await _settings.setIntPref(PrefKeys.ttsVolume, ttsVolumeToStored(_volume));
  }

  // ===== 缓存 =====

  Future<void> _reloadCacheStats() async {
    final stats = await _systemTts.cacheStats();
    if (!mounted) return;
    setState(() => _cacheStats = stats);
  }

  Future<void> _showCacheDialog() async {
    await _reloadCacheStats();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('TTS 缓存'),
        content: Text(
          '系统 TTS 合成缓存：${_cacheStats.fileCount} 个文件，'
          '共 ${_formatBytes(_cacheStats.totalBytes)}。\n'
          '缓存仅用于加速重复段落朗读，清理后可随时重新生成。',
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
    );
    if (confirmed != true) return;
    final deleted = await _systemTts.clearCache();
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
            : TabBarView(
                children: [
                  _GeneralTab(),
                  _EngineTab(),
                  _RoleTab(),
                ],
              ),
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

  _ChoiceResult.cancelled()
      : value = null,
        cancelled = true;

  final T? value;
  final bool cancelled;
}

// ===== 页签内容 =====
//
// 页签是页面 State 的内部视图：通过 `context.findAncestorStateOfType` 取
// 状态，避免把十余个回调逐个下传（页面私有，不对外复用）。

_ReadAloudSettingsScreenState _stateOf(BuildContext context) {
  final state =
      context.findAncestorStateOfType<_ReadAloudSettingsScreenState>();
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
                state._settings.setBoolPref(
                  PrefKeys.keepReadAloudOnExit,
                  v,
                );
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
        const IosSectionHeader('缓存'),
        IosGroup(
          flat: true,
          children: [
            IosListTile(
              title: 'TTS 缓存',
              subtitle:
                  '${state._cacheStats.fileCount} 个文件 · '
                  '${_ReadAloudSettingsScreenState._formatBytes(state._cacheStats.totalBytes)}',
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
              subtitle: '使用系统内置语音引擎（无需网络）',
              trailing: Icon(
                systemSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: systemSelected
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              onTap: () => state._selectGlobalEngine(kSystemTtsEngineUrl),
            ),
            for (final engine in state._httpEngines)
              Builder(builder: (context) {
                final url = normalizeTtsEngineUrl(engine.url);
                final selected = !systemSelected && state._effectiveEngine == url;
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
              }),
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
              subtitle: state._systemVoices.isEmpty
                  ? '无可用音色'
                  : '选择系统 TTS 音色',
              value: selectedVoiceLabel,
              enabled: state._systemVoices.isNotEmpty,
              onTap: state._systemVoices.isNotEmpty
                  ? state._pickSystemVoice
                  : null,
            ),
            IosListTile(
              title: '系统 TTS 设置',
              subtitle: isAndroid
                  ? '打开系统「文字转语音」设置'
                  : '仅 Android 支持',
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
                state.ref
                    .read(audioNotifierProvider.notifier)
                    .updateConfig(speed: v);
              },
              onChangeEnd: state._persistVoiceParams,
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
              onChangeEnd: state._persistVoiceParams,
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
              onChangeEnd: state._persistVoiceParams,
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
