import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_progress_indicator.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../models/models.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/providers.dart';
import '../utils/app_route_observer.dart';
import '../utils/audio_skip_policy.dart';
import '../routes.dart';
import '../services/audio_cache_events.dart';
import '../services/headset_media_button_service.dart';
import '../services/system_tts_service.dart';
import '../widgets/read_aloud_timer_sheet.dart';
import 'source_edit_screen.dart';
import 'source_login_screen.dart';

/// 听书播放页面
class AudioScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 书籍 URL（向后兼容）
  final String bookUrl;

  /// 书名（向后兼容）
  final String bookName;

  const AudioScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.bookName = '',
  });

  /// 获取有效的 bookUrl
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  /// 获取有效的书名
  String get effectiveBookName => book?.name ?? bookName;

  @override
  ConsumerState<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends ConsumerState<AudioScreen> with RouteAware {
  bool _showSettings = false;
  bool _wakeLock = false;

  /// 播放器背景是否透明（设置批5a-1）
  ///
  /// 偏好 `readAloudPlayerBackground`：`solid`（默认，跟随主题）/ `transparent`
  /// （透明露出全局背景图/壁纸）。模糊/流光在设置页置灰未实现。
  bool _transparentBackground = false;

  // ===== [TTS P3 | 2026-11-11] 听书页内联朗读引擎 =====
  //
  // 面板内直接展示当前引擎名并允许切换（对齐「朗读设置 → 引擎与音色」
  // 的数据源）：系统 TTS 引擎（flutter_tts getEngines）+ HTTP 引擎
  // （getHttpTts）。首次展开设置面板时加载；两列表都为空（如模拟器无
  // 系统 TTS 且无 HTTP 引擎）显示「未检测到可用语音引擎」并禁用选择。
  bool _enginesLoading = false;
  bool _enginesLoaded = false;

  /// 是否有任一引擎来源加载失败（与「确实无引擎」区分文案）
  bool _engineLoadFailed = false;
  List<HttpTts> _httpEngines = const [];
  List<SystemTtsEngine> _systemEngines = const [];
  String _effectiveEngineUrl = '';

  /// 当前生效引擎名（系统 TTS 显示具体引擎/系统默认，HTTP 引擎显示配置名）
  String get _selectedEngineLabel {
    final url = normalizeTtsEngineUrl(_effectiveEngineUrl);
    if (url.isEmpty || url == kSystemTtsEngineUrl) {
      final name = ref.read(systemTtsServiceProvider).selectedEngineName;
      if (name == null || name.isEmpty) {
        // 系统 TTS 但设备未安装引擎（如模拟器）：如实提示，不假装可用
        return _systemEngines.isEmpty ? '系统 TTS（未检测到可用引擎）' : '系统默认';
      }
      for (final engine in _systemEngines) {
        if (engine.name == name) return engine.displayName;
      }
      return name;
    }
    for (final engine in _httpEngines) {
      if (normalizeTtsEngineUrl(engine.url) == url) return engine.name;
    }
    return url;
  }

  /// 是否存在可选择的引擎（系统引擎或 HTTP 引擎任一非空）
  bool get _hasEngineOptions =>
      _systemEngines.isNotEmpty || _httpEngines.isNotEmpty;

  /// 引擎行副标题：区分「加载失败可重试」与「确实没有可用引擎」
  String get _engineSubtitle {
    if (_enginesLoading) return '加载中…';
    if (_hasEngineOptions) {
      return _engineLoadFailed
          ? '$_selectedEngineLabel（部分引擎加载失败）'
          : _selectedEngineLabel;
    }
    return _engineLoadFailed ? '朗读引擎加载失败，点击重试' : '未检测到可用语音引擎';
  }

  /// 空列表且加载失败：允许点击重试
  bool get _engineRetryable => !_hasEngineOptions && _engineLoadFailed;

  /// [批9b-5] 耳机媒体键服务（听书页挂载期间按「活动内处理」语义接管
  /// 空闲态播放键，对齐原版 AudioPlayActivity.playButton）
  HeadsetMediaButtonService? _headsetMediaButtonService;

  /// [TTS P3 | 2026-11-11] dispose 阶段不能读 ref：提前捕获朗读 Notifier，
  /// 保证退出听书页的媒体会话释放真正执行（此前 ref 失效时异常被吞，
  /// 会话保留为 STOPPED 记录）。
  late final AudioNotifier _audioNotifier;

  // ===== 音频章节预下载批量状态（契约 §2.48，对齐原版 AudioCacheService 计数）=====
  //
  // 原版为前台服务（ArrayDeque 队列 + 通知 + START_NOT_STICKY，服务编排不上
  // FFI，契约 §2.48 已裁决）：本页循环逐章调用 audioCacheDownload 并自持
  // done/total/fail 计数（与原版通知计数 AudioCacheService.kt:275-301 等价），
  // 「停止」= audioCacheCancel + 停止后续章节调用（对齐 stopAndClear:259-266）。
  bool _audioCacheRunning = false;
  int _audioCacheDone = 0;
  int _audioCacheTotal = 0;
  int _audioCacheFail = 0;

  /// 批次令牌：自增即取消（停止发起后续章节调用）
  int _audioCacheRunToken = 0;

  // ===== 定时停止相关状态 =====
  //
  // [A4 | 2026-10-03] 计时已下沉 AudioNotifier（不随听书页销毁而失效），
  // 本页只订阅展示剩余时间/开关状态；不再持有本地 Timer。
  // [设置批5c | 2026-11-05] 定时入参统一由共享 Sheet 承担，
  // 本页删除重复的预设/自定义输入与控制器。

  @override
  void initState() {
    super.initState();
    // [TTS P3 | 2026-11-11] 先捕获 Notifier：dispose 阶段 WidgetRef 已失效，
    // 不能再用 ref.read 做媒体会话释放。
    _audioNotifier = ref.read(audioNotifierProvider.notifier);
    // [批9b-5] 听书页存在时，空闲态耳机播放键交由本页播放（对齐原版
    // AudioPlayActivity.observeLiveBus → playButton），而不是从最近书启动
    _headsetMediaButtonService = ref.read(headsetMediaButtonServiceProvider);
    _headsetMediaButtonService?.attachActivityHandler(this, _onHeadsetMediaKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = ref.read(audioNotifierProvider.notifier);
      // [设置批5a-1] 播放器背景偏好（纯色/透明）
      unawaited(
        ref
            .read(settingsProvider)
            .getStringPref(
              PrefKeys.readAloudPlayerBackground,
              defaultValue: 'solid',
            )
            .then((value) {
              if (!mounted) return;
              setState(() => _transparentBackground = value == 'transparent');
            }),
      );
      // 音频书 → 流媒体；否则保持 TTS（阅读器朗读入口会强制 TTS）
      notifier.setAudioBookMode(_canCopyPlayUrl);
      notifier.bindBook(widget.book);
      // [A2] 读回并应用书级播放模式/语速（打开听书页/切换书籍）
      unawaited(
        notifier.applyBookPreferences(
          widget.book,
          fallbackBookUrl: widget.effectiveBookUrl,
        ),
      );
      notifier.initMediaSession(bookName: widget.effectiveBookName);
      unawaited(
        notifier.isWakeLockEnabled().then((v) {
          if (mounted) setState(() => _wakeLock = v);
        }),
      );
      if (!ref.read(audioNotifierProvider).hasChapters) {
        notifier.loadChapters(widget.effectiveBookUrl);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // [批9b-5 回修] 订阅路由可见性：被来源编辑/登录等子路由覆盖时注销
    // 耳机键处理器，返回后重新登记（不可见页面不接收媒体键）
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _headsetMediaButtonService?.detachActivityHandler(this);
  }

  @override
  void didPopNext() {
    _headsetMediaButtonService?.attachActivityHandler(this, _onHeadsetMediaKey);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    // [批9b-5] 注销耳机媒体键前台处理器（owner 校验防误清上层页面）
    _headsetMediaButtonService?.detachActivityHandler(this);
    // 页面销毁只清理输入控制器；定时停止计时归 Notifier 所有
    // （[A4] 退出听书页后倒计时/按章停止继续生效）
    // 释放媒体会话资源（后台播放/焦点）
    // [TTS P3 | 2026-11-11] 使用 initState 捕获的 Notifier（dispose 时 ref
    // 已失效，旧实现 try/catch 吞掉异常导致释放未执行、留下 STOPPED 记录）。
    // 空闲态强制释放（无播放可控制，不应保留陈旧会话）；播放/暂停中保持
    // 既有保留语义（后台播放与耳机键控制不被切断）。
    // 延迟到微任务：releaseMediaSession 内部会写 Notifier state 并通知
    // 监听者；若在 unmount 同步栈内写，已 defunct 的
    // ConsumerStatefulElement 会被 markNeedsBuild 触发框架断言。
    scheduleMicrotask(() {
      unawaited(
        _audioNotifier.releaseMediaSession(force: _audioNotifier.isIdle),
      );
    });
    super.dispose();
  }

  // ===== 定时停止 UI（逻辑在 AudioNotifier）=====

  /// 格式化倒计时文本 mm:ss
  String _formatCountdown(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 打开统一朗读定时 Sheet（设置批5c）
  ///
  /// 分钟/章节互斥、预设/滑块/「读完本章再停」与持久化统一在
  /// `read_aloud_timer_sheet.dart`；本页只保留入口与剩余量展示。
  Future<void> _showTimerPicker() => showReadAloudTimerSheet(context);

  // ===== [TTS P3 | 2026-11-11] 设置面板：引擎/音调/音量 =====

  /// 展开/收起设置面板；首次展开加载内联引擎列表
  Future<void> _toggleSettings() async {
    final next = !_showSettings;
    setState(() => _showSettings = next);
    if (next && !_enginesLoaded && !_enginesLoading) {
      await _loadTtsEngines();
    }
  }

  /// 加载可用朗读引擎（系统 TTS getEngines + HTTP 引擎 getHttpTts）
  ///
  /// 两个来源分别兜底：任一来源失败不阻断另一来源；两者皆空时面板显示
  /// 空态。`_engineLoadFailed` 用于区分「某来源加载失败」与「确实无引擎」。
  Future<void> _loadTtsEngines() async {
    setState(() {
      _enginesLoading = true;
      _engineLoadFailed = false;
    });
    final api = ref.read(bookApiProvider);
    final systemTts = ref.read(systemTtsServiceProvider);
    var failed = false;

    var httpEngines = _httpEngines;
    try {
      httpEngines = await api.getHttpTts();
    } catch (e) {
      failed = true;
      debugPrint('加载 HTTP 朗读引擎失败：$e');
    }

    var systemEngines = _systemEngines;
    try {
      // 允许用户在系统设置安装引擎后回到本页即时看到
      systemTts.invalidateAvailability();
      await systemTts.loadSelection();
      systemEngines = await systemTts.engines();
    } catch (e) {
      failed = true;
      debugPrint('加载系统朗读引擎失败：$e');
    }

    var effective = _effectiveEngineUrl;
    try {
      effective = await _audioNotifier.loadEffectiveTtsEngineUrl();
    } catch (e) {
      failed = true;
      debugPrint('读取当前朗读引擎失败：$e');
    }

    if (!mounted) return;
    setState(() {
      _httpEngines = httpEngines;
      _systemEngines = systemEngines;
      _effectiveEngineUrl = effective;
      _engineLoadFailed = failed;
      _enginesLoaded = true;
      _enginesLoading = false;
    });
  }

  /// 重新加载引擎列表（从朗读设置页返回后同步新增/删除/切换结果）
  Future<void> _reloadTtsEngines() async {
    _enginesLoaded = false;
    if (_showSettings) await _loadTtsEngines();
  }

  /// 语速落库（TTS 模式）：与朗读条/设置页同键（[PrefKeys.ttsSpeechRate]）。
  ///
  /// 流媒体听书的语速由书级 `readConfig.playSpeed` 经 Notifier 落库，
  /// 不走本键（避免把音频书语速带到 TTS 朗读）。
  Future<void> _persistTtsSpeed(double speed) async {
    try {
      await ref
          .read(settingsProvider)
          .setIntPref(PrefKeys.ttsSpeechRate, ttsSpeechRateFromSpeed(speed));
      // [TTS P3 回修 | 2026-11-11] 手动调语速即视为脱离「跟随系统」：
      // 与朗读条共用 config 键，避免朗读条仍显示「跟随系统」却用用户值。
      await ref
          .read(bookApiProvider)
          .setConfig(kTtsFollowSysConfigKey, 'false');
    } catch (e) {
      debugPrint('保存朗读语速失败（忽略）：$e');
    }
  }

  /// 音调落库：与朗读设置页同键（[PrefKeys.ttsPitch]），重启后由
  /// `AudioNotifier.initMediaSession` 读回。
  Future<void> _persistTtsPitch(double pitch) async {
    try {
      await ref
          .read(settingsProvider)
          .setIntPref(PrefKeys.ttsPitch, ttsPitchToStored(pitch));
    } catch (e) {
      debugPrint('保存朗读音调失败（忽略）：$e');
    }
  }

  /// 音量落库：与朗读设置页同键（[PrefKeys.ttsVolume]）
  Future<void> _persistTtsVolume(double volume) async {
    try {
      await ref
          .read(settingsProvider)
          .setIntPref(PrefKeys.ttsVolume, ttsVolumeToStored(volume));
    } catch (e) {
      debugPrint('保存朗读音量失败（忽略）：$e');
    }
  }

  /// 内联引擎选择对话框：系统引擎（含系统默认）+ HTTP 引擎
  Future<void> _showInlineEnginePicker() async {
    if (!_hasEngineOptions) return;
    final systemTts = ref.read(systemTtsServiceProvider);
    final currentUrl = normalizeTtsEngineUrl(_effectiveEngineUrl);
    final systemSelected =
        currentUrl.isEmpty || currentUrl == kSystemTtsEngineUrl;
    final currentKey = systemSelected
        ? 'system:${systemTts.selectedEngineName ?? 'default'}'
        : 'http:$currentUrl';
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择朗读引擎'),
        children: [
          // [TTS P3 回修] 系统引擎列表为空也保留「系统默认」：用户从
          // HTTP 引擎切回系统 TTS 时仍可回选，不因设备未装引擎而消失。
          if (platformSupportsSystemTts()) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: Text('系统引擎'),
            ),
            RadioGroup<String>(
              groupValue: currentKey,
              onChanged: (v) {
                if (v != null) Navigator.pop(dialogContext, v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<String>(
                    title: const Text('系统默认'),
                    subtitle: const Text('跟随系统「文字转语音」设置'),
                    value: 'system:default',
                  ),
                  for (final engine in _systemEngines)
                    RadioListTile<String>(
                      title: Text(engine.displayName),
                      subtitle: Text(engine.name),
                      value: 'system:${engine.name}',
                    ),
                ],
              ),
            ),
          ],
          if (_httpEngines.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: Text('HTTP 引擎'),
            ),
            RadioGroup<String>(
              groupValue: currentKey,
              onChanged: (v) {
                if (v != null) Navigator.pop(dialogContext, v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final engine in _httpEngines)
                    RadioListTile<String>(
                      title: Text(engine.name),
                      subtitle: Text(engine.url),
                      value: 'http:${normalizeTtsEngineUrl(engine.url)}',
                    ),
                ],
              ),
            ),
          ],
          const Divider(height: 1),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;

    if (picked.startsWith('http:')) {
      final url = picked.substring('http:'.length);
      await _audioNotifier.setGlobalTtsEngine(url);
      if (!mounted) return;
      setState(
        () => _effectiveEngineUrl = normalizeTtsEngineUrl(
          _audioNotifier.resolveTtsEngineUrl(),
        ),
      );
      final name = () {
        for (final engine in _httpEngines) {
          if (normalizeTtsEngineUrl(engine.url) == url) return engine.name;
        }
        return url;
      }();
      _snack('已切换朗读引擎：$name');
      return;
    }

    // 系统引擎：先应用平台引擎（失败不切换全局值，避免指向不可用引擎）
    final name = picked == 'system:default'
        ? null
        : picked.substring('system:'.length);
    final voices = await systemTts.selectEngine(name);
    if (!mounted) return;
    if (voices == null) {
      _snack('引擎初始化失败');
      return;
    }
    await _audioNotifier.setGlobalTtsEngine(kSystemTtsEngineUrl);
    if (!mounted) return;
    setState(() => _effectiveEngineUrl = kSystemTtsEngineUrl);
    _snack(name == null ? '已使用系统默认引擎' : '已切换系统引擎：$name');
  }

  @override
  Widget build(BuildContext context) {
    // 监听听书状态（替代原 Consumer<AudioProvider>）
    final provider = ref.watch(audioNotifierProvider);
    final notifier = ref.watch(audioNotifierProvider.notifier);
    return ListenableBuilder(
      listenable: notifier,
      builder: (context, _) => AppScaffold(
        // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
        // [设置批5a-1] 播放器背景：透明时露出全局背景图/壁纸层
        backgroundColor: _transparentBackground ? Colors.transparent : null,
        topBar: LegadoAppBar(
          title: Text(
            widget.effectiveBookName.isNotEmpty
                ? widget.effectiveBookName
                : '听书',
          ),
          actions: [
            // 定时停止按钮（状态来自 Notifier，退出页面后仍生效）
            _buildTimerButton(notifier),
            IconButton(
              icon: const Icon(Symbols.settings_rounded),
              // [LAYOUT_PLAN P3] 沉浸域仅顶栏动作行规范：补 tooltip（本体不动）
              tooltip: '设置',
              onPressed: () => unawaited(_toggleSettings()),
            ),
            // [UI-fix v2.0.2 | 2026-08-06] 听书溢出菜单（对标原版 audio_play.xml）。
            // [B1 P1 收口 | 2026-10-04] 预下载入口曾下线（旧页面内循环写旧孤儿键，
            // 与新读面目录/键/标记三重不匹配）。
            // [B2 | 2026-10-03] 按契约 §2.48 恢复「缓存章节范围」「清除本章缓存」
            // 两入口（对齐原版 audio_play.xml menu_audio_cache_range /
            // menu_clear_current_audio_cache，AudioPlayActivity.kt:235-237,281-349）：
            // 批量循环逐章调 audioCacheDownload（写入在 Rust、字节零穿越 FFI），
            // 进度计 done/total/fail（对齐原版通知计数 AudioCacheService.kt:275-301），
            // 「停止」调 audioCacheCancel。旧孤儿键写入路径保持删除、不迁移。
            // 「缓存目录」（原版 SAF 目录选择）**不在本批**：契约 §2.47/§2.48 已冻结
            // 缓存根为 set_audio_cache_dir 注入的应用私有 cache/audio_cache，SAF
            // content:// 树无法作为 Rust std::fs 路径，选择结果对读写面均无效果——
            // 加回入口会误导用户（详见本批报告「SAF 目录与私有缓存根不一致」）。
            PopupMenuButton<String>(
              tooltip: '更多',
              // [LAYOUT_PLAN P3] 沉浸域仅顶栏动作行规范：菜单在顶栏下方展开（本体不动）
              position: PopupMenuPosition.under,
              onSelected: _handleOverflowMenu,
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'changeSource', child: Text('换源')),
                if (_origin.isNotEmpty)
                  const PopupMenuItem(value: 'login', child: Text('登录')),
                if (_canCopyPlayUrl)
                  const PopupMenuItem(
                    value: 'copyAudioUrl',
                    child: Text('复制播放地址'),
                  ),
                // 原版菜单顺序：copy_audio_url → cache_range → clear_current_audio_cache
                if (_canCopyPlayUrl)
                  const PopupMenuItem(
                    value: 'cacheRange',
                    child: Text('缓存章节范围'),
                  ),
                if (_canCopyPlayUrl)
                  const PopupMenuItem(
                    value: 'clearCurrentCache',
                    child: Text('清除本章缓存'),
                  ),
                if (_canCopyPlayUrl)
                  CheckedPopupMenuItem(
                    value: 'wakeLock',
                    checked: _wakeLock,
                    child: const Text('唤醒锁定'),
                  ),
                if (_canCopyPlayUrl)
                  const PopupMenuItem(
                    value: 'skipCredits',
                    child: Text('跳过片头片尾'),
                  ),
                if (_origin.isNotEmpty)
                  const PopupMenuItem(value: 'editSource', child: Text('编辑书源')),
                const PopupMenuItem(value: 'log', child: Text('日志')),
              ],
            ),
          ],
        ),
        body: _buildBody(provider, notifier),
      ),
    );
  }

  /// 听书主体（根据状态展示 loading/error/内容三态）
  Widget _buildBody(AudioState provider, AudioNotifier notifier) {
    if (provider.isLoading && !provider.hasChapters) {
      // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
      return const Center(child: AppCircularProgressIndicator());
    }
    if (provider.state == PlayerState.error && !provider.hasChapters) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.error_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(provider.errorMessage ?? '加载失败'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref
                  .read(audioNotifierProvider.notifier)
                  .loadChapters(widget.effectiveBookUrl),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 音频预下载进度条（对齐原版前台通知标题/文案/停止动作；
        // 契约 §2.48 已知边界：不做常驻通知，进程死即停）
        if (_audioCacheRunning) _buildAudioCacheProgressBar(),
        // 当前章节信息
        _buildNowPlayingCard(provider),
        // 进度条
        _buildProgressBar(provider),
        // 播放控制
        _buildControls(provider),
        // 定时停止显示（激活时）：分钟倒计时或按章剩余
        if (notifier.isSleepTimerActive) _buildCountdownBar(notifier),
        const Divider(),
        // 设置面板：音频书仅保留语速；TTS 保留完整引擎配置
        if (_showSettings) _buildSettingsPanel(provider),
        // 章节列表
        Expanded(child: _buildChapterList(provider)),
        // 后台播放提示
        _buildBackgroundNotice(),
      ],
    );
  }

  /// 定时停止按钮（AppBar 中）
  ///
  /// [设置批5c] 无论是否已设定时都打开共享 Sheet：取消/停止动作在 Sheet
  /// 内完成，与朗读条入口一致（不再直接 cancel，避免两套交互）。
  Widget _buildTimerButton(AudioNotifier notifier) {
    final active = notifier.isSleepTimerActive;
    return IconButton(
      icon: Icon(
        Symbols.timer_rounded,
        color: active ? Theme.of(context).colorScheme.error : null,
      ),
      tooltip: active ? '定时停止（已设置）' : '定时停止',
      onPressed: _showTimerPicker,
    );
  }

  /// 定时停止显示条（控制区域下方，红色文字突出）
  Widget _buildCountdownBar(AudioNotifier notifier) {
    final text = switch (notifier.sleepTimerMode) {
      SleepTimerMode.chapters =>
        '按章停止 剩余 ${notifier.chaptersToStopRemaining} 章',
      SleepTimerMode.duration =>
        '定时停止 ${_formatCountdown(notifier.sleepRemainingSeconds)}',
      SleepTimerMode.finishChapter => '定时停止 读完本章后停止',
      SleepTimerMode.off => '',
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.timer_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: notifier.cancelSleepTimer,
            child: Icon(
              Symbols.close_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }

  /// 音频预下载进度条（对齐原版前台通知的标题/文案/停止动作：
  /// `audio_cache_notification_title`「音频缓存」+
  /// `audio_cache_notification_text`「《%1$s》已缓存 %2$d/%3$d，失败 %4$d」+
  /// 停止动作 `stop`，AudioCacheService.kt:86-98,275-301）。
  /// 契约 §2.48 已知边界：不做常驻通知/保活（进程死即停，已装文件保留）。
  Widget _buildAudioCacheProgressBar() {
    final scheme = Theme.of(context).colorScheme;
    final progress = _audioCacheTotal <= 0
        ? null
        : _audioCacheDone / _audioCacheTotal;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('音频缓存', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  '《${widget.effectiveBookName}》已缓存 '
                  '$_audioCacheDone/$_audioCacheTotal，失败 $_audioCacheFail',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _cancelAudioCacheBatch,
            child: const Text('停止'),
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingCard(AudioState provider) {
    final chapter = provider.currentChapter;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Column(
        children: [
          Icon(
            provider.isPlaying
                ? Symbols.graphic_eq_rounded
                : Symbols.headphones_rounded,
            size: 44,
            color: scheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            chapter?.title ?? '未选择章节',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            provider.isStreamMode ? '音频书' : '朗读',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '${provider.currentIndex + 1} / ${provider.totalChapters}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          // [A1 批 2026-10-03] TTS 合成/播放失败降级提示（播放中可见，不静默）
          if (provider.errorMessage != null &&
              provider.state != PlayerState.error) ...[
            const SizedBox(height: 8),
            Text(
              provider.errorMessage!,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.error),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (provider.isStreamMode &&
              (provider.lyric?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 10),
            Text(
              provider.lyric!.trim(),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.secondary),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressBar(AudioState provider) {
    final isStream = provider.isStreamMode;
    final dur = provider.durationMs;
    final pos = provider.positionMs;
    final streamValue = (isStream && dur > 0)
        ? (pos / dur).clamp(0.0, 1.0)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: streamValue ?? provider.progress,
              minHeight: 3,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isStream && dur > 0
                    ? _formatMs(pos)
                    : '第 ${provider.currentIndex + 1} 章',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                isStream && dur > 0
                    ? _formatMs(dur)
                    : '共 ${provider.totalChapters} 章',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatMs(int ms) {
    final totalSec = (ms / 1000).floor();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildControls(AudioState provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 播放模式
          IconButton(
            icon: Icon(_modeIcon(provider.mode)),
            tooltip: _modeLabel(provider.mode),
            onPressed: () => _cycleMode(provider),
          ),
          const SizedBox(width: 16),
          // 上一章
          IconButton(
            icon: const Icon(Symbols.skip_previous_rounded),
            iconSize: 36,
            onPressed: provider.hasPrevious
                ? ref.read(audioNotifierProvider.notifier).previous
                : null,
          ),
          const SizedBox(width: 16),
          // 播放/暂停
          _buildPlayPauseButton(provider),
          const SizedBox(width: 16),
          // 下一章
          IconButton(
            icon: const Icon(Symbols.skip_next_rounded),
            iconSize: 36,
            onPressed: provider.hasNext
                ? ref.read(audioNotifierProvider.notifier).next
                : null,
          ),
        ],
      ),
    );
  }

  /// [批9b-5] 耳机媒体键前台事件（仅空闲态会分派到这里）
  ///
  /// 对齐原版 `AudioPlayActivity.observeLiveBus`（EventBus.MEDIA_BUTTON →
  /// playButton）：播放中/暂停中的切换由决策层直接处理，不会到本方法。
  void _onHeadsetMediaKey(HeadsetMediaKey key) {
    if (!mounted || key != HeadsetMediaKey.toggle) return;
    final notifier = ref.read(audioNotifierProvider.notifier);
    final state = ref.read(audioNotifierProvider);
    if (state.isPlaying) {
      notifier.pause();
    } else {
      unawaited(notifier.resumeOrPlay());
    }
  }

  Widget _buildPlayPauseButton(AudioState provider) {
    return SizedBox(
      width: 64,
      height: 64,
      child: FloatingActionButton(
        onPressed: () {
          final n = ref.read(audioNotifierProvider.notifier);
          if (provider.isPlaying) {
            n.pause();
          } else {
            unawaited(n.resumeOrPlay());
          }
        },
        child: provider.isLoading
            ? SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  // [MD3 Batch 5] FAB 已走 M3 primaryContainer 底，
                  // 加载圈前景对齐 onPrimaryContainer（原硬编码白色）
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              )
            : Icon(
                provider.isPlaying
                    ? Symbols.pause_rounded
                    : Symbols.play_arrow_rounded,
                size: 32,
              ),
      ),
    );
  }

  Widget _buildSettingsPanel(AudioState provider) {
    final isStream = provider.isStreamMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isStream ? '播放设置' : '朗读设置',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 60, child: Text('语速')),
              Expanded(
                child: Slider(
                  value: provider.config.speed,
                  min: 0.5,
                  max: 3.0,
                  divisions: 25,
                  label: '${provider.config.speed.toStringAsFixed(1)}x',
                  onChanged: (v) => ref
                      .read(audioNotifierProvider.notifier)
                      .updateConfig(speed: v),
                  // [TTS P3 | 2026-11-11] TTS 模式同步落全局语速键；
                  // 音频书语速由 Notifier 写书级 playSpeed。
                  onChangeEnd: isStream
                      ? null
                      : (v) => unawaited(_persistTtsSpeed(v)),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${provider.config.speed.toStringAsFixed(1)}x'),
              ),
            ],
          ),
          if (!isStream) ...[
            Row(
              children: [
                const SizedBox(width: 60, child: Text('音调')),
                Expanded(
                  child: Slider(
                    value: provider.config.pitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: provider.config.pitch.toStringAsFixed(1),
                    onChanged: (v) => ref
                        .read(audioNotifierProvider.notifier)
                        .updateConfig(pitch: v),
                    // [TTS P3 | 2026-11-11] 拖动结束落库（同设置页键），
                    // 退出/重启后由 initMediaSession 读回，不再只改会话配置。
                    onChangeEnd: (v) => unawaited(_persistTtsPitch(v)),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(provider.config.pitch.toStringAsFixed(1)),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 60, child: Text('音量')),
                Expanded(
                  child: Slider(
                    value: provider.config.volume,
                    min: 0.0,
                    max: 1.0,
                    divisions: 10,
                    label: '${(provider.config.volume * 100).toInt()}%',
                    onChanged: (v) => ref
                        .read(audioNotifierProvider.notifier)
                        .updateConfig(volume: v),
                    // [TTS P3 | 2026-11-11] 同音调：拖动结束落库
                    onChangeEnd: (v) => unawaited(_persistTtsVolume(v)),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text('${(provider.config.volume * 100).toInt()}%'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // [TTS P3 | 2026-11-11] 内联朗读引擎：显示当前引擎名并可直接
            // 切换（系统引擎 + HTTP 引擎）。列表为空时明确提示并禁用选择，
            // 避免无引擎设备（如 MuMu）点击后崩溃或误以为可切换。
            ListTile(
              key: const ValueKey('audio-tts-engine-row'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Symbols.record_voice_over_rounded, size: 20),
              title: const Text('朗读引擎'),
              subtitle: Text(_engineSubtitle),
              trailing: _enginesLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _engineRetryable
                          ? Symbols.refresh_rounded
                          : Symbols.chevron_right_rounded,
                      size: 20,
                    ),
              enabled:
                  !_enginesLoading && (_hasEngineOptions || _engineRetryable),
              onTap: _enginesLoading
                  ? null
                  : (_hasEngineOptions
                        ? _showInlineEnginePicker
                        : (_engineRetryable
                              ? () => unawaited(_loadTtsEngines())
                              : null)),
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Symbols.tune_rounded, size: 20),
              title: const Text('朗读设置'),
              subtitle: const Text('引擎/音色/语速与朗读行为'),
              // [设备验收 P1] 指向新三页签页；HTTP 引擎管理在页内可达。
              // [TTS P3 | 2026-11-11] 返回后重载内联引擎列表，同步页内
              // 新增/删除/切换结果。
              onTap: () async {
                await Navigator.pushNamed(context, AppRoutes.readAloudSettings);
                if (!mounted) return;
                await _reloadTtsEngines();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChapterList(AudioState provider) {
    if (provider.chapters.isEmpty) {
      return const Center(child: Text('暂无章节'));
    }
    return ListView.builder(
      itemCount: provider.chapters.length,
      itemBuilder: (context, index) {
        final chapter = provider.chapters[index];
        final isCurrent = index == provider.currentIndex;
        return ListTile(
          leading: isCurrent
              ? Icon(
                  Symbols.play_circle_rounded,
                  color: Theme.of(context).primaryColor,
                )
              : Text('${index + 1}'),
          title: Text(
            chapter.title,
            style: TextStyle(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? Theme.of(context).primaryColor : null,
            ),
          ),
          selected: isCurrent,
          onTap: () => ref.read(audioNotifierProvider.notifier).jumpTo(index),
        );
      },
    );
  }

  Widget _buildBackgroundNotice() {
    final provider = ref.watch(audioNotifierProvider);
    final mediaReady = provider.isMediaSessionReady;
    return Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            mediaReady ? Symbols.headphones_rounded : Symbols.info_rounded,
            size: 16,
            color: mediaReady
                ? Theme.of(context).primaryColor
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            mediaReady ? '后台播放已启用，支持媒体按钮控制' : '支持后台播放，切换应用后音频将继续播放',
            style: TextStyle(
              fontSize: 12,
              color: mediaReady
                  ? Theme.of(context).primaryColor
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  IconData _modeIcon(AudioPlayMode mode) {
    switch (mode) {
      case AudioPlayMode.sequential:
        return Symbols.arrow_forward_rounded;
      case AudioPlayMode.singleLoop:
        return Symbols.repeat_one_rounded;
      case AudioPlayMode.shuffle:
        return Symbols.shuffle_rounded;
    }
  }

  String _modeLabel(AudioPlayMode mode) {
    switch (mode) {
      case AudioPlayMode.sequential:
        return '顺序播放';
      case AudioPlayMode.singleLoop:
        return '单曲循环';
      case AudioPlayMode.shuffle:
        return '随机播放';
    }
  }

  void _cycleMode(AudioState provider) {
    final nextIndex = (provider.mode.index + 1) % AudioPlayMode.values.length;
    ref
        .read(audioNotifierProvider.notifier)
        .setMode(AudioPlayMode.values[nextIndex]);
  }

  // ===== 溢出菜单（对标 audio_play.xml；仅已接通项）— GapAudit P0-2 =====

  /// 溢出菜单分发
  Future<void> _handleOverflowMenu(String value) async {
    switch (value) {
      case 'changeSource':
        _openChangeSource();
      case 'login':
        await _openLogin();
      case 'copyAudioUrl':
        await _copyAudioUrl();
      case 'cacheRange':
        await _showAudioCacheRange();
      case 'clearCurrentCache':
        await _clearCurrentAudioCache();
      case 'wakeLock':
        final next = !_wakeLock;
        await ref.read(audioNotifierProvider.notifier).setWakeLockEnabled(next);
        if (mounted) setState(() => _wakeLock = next);
      case 'skipCredits':
        await _showSkipCreditsSheet();
      case 'editSource':
        _openEditSource();
      case 'log':
        if (mounted) Navigator.pushNamed(context, AppRoutes.appLog);
    }
  }

  /// 当前书源 URL（Book.origin）
  String get _origin => widget.book?.origin ?? '';

  /// 是否可复制真实播放地址（音频书位标记；TTS 朗读无流媒体地址则不展示）
  bool get _canCopyPlayUrl {
    final book = widget.book;
    if (book == null) return false;
    return (book.bookType & BookType.audio) == BookType.audio;
  }

  /// 换源（对标原版从听书页打开 ChangeBookSourceDialog）
  void _openChangeSource() {
    final book = widget.book;
    if (book != null) {
      Navigator.pushNamed(context, AppRoutes.changeSource, arguments: book);
      return;
    }
    Navigator.pushNamed(
      context,
      AppRoutes.changeSource,
      arguments: {
        'bookUrl': widget.effectiveBookUrl,
        'bookName': widget.effectiveBookName,
        'currentSourceUrl': _origin,
      },
    );
  }

  /// 登录（按 book.origin 定位书源后打开登录页）
  Future<void> _openLogin() async {
    if (_origin.isEmpty) {
      _snack('本书无关联书源，无法登录');
      return;
    }
    BookSource? source;
    try {
      final sources = await ref.read(bookApiProvider).getBookSources();
      source = sources.where((s) => s.bookSourceUrl == _origin).firstOrNull;
    } catch (_) {}
    if (!mounted) return;
    if (source == null) {
      _snack('未找到当前书源');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SourceLoginScreen(
          sourceUrl: source!.bookSourceUrl,
          sourceName: source.bookSourceName,
          loginUrl: source.loginUrl,
        ),
      ),
    );
  }

  /// 复制播放地址（对标 menu_copy_audio_url；优先 mediaUrl）
  Future<void> _copyAudioUrl() async {
    final bookUrl = widget.effectiveBookUrl;
    if (bookUrl.isEmpty) {
      _snack('无法获取播放地址');
      return;
    }
    try {
      final api = ref.read(bookApiProvider);
      final audio = ref.read(audioNotifierProvider);
      // 优先当前已解析的播放地址，避免重复取址
      var url = audio.mediaUrl.trim();
      if (url.isEmpty) {
        final media = await api.getAudioChapterMedia(
          bookUrl,
          audio.currentIndex,
        );
        url = (media['mediaUrl'] as String?)?.trim() ?? '';
        if (url.isEmpty) {
          final resource = (media['resourceUrl'] as String?)?.trim() ?? '';
          final chapterUrl = (media['url'] as String?)?.trim() ?? '';
          url = resource.isNotEmpty ? resource : chapterUrl;
        }
      }
      if (url.isEmpty) {
        _snack('当前章节无播放地址');
        return;
      }
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) _snack('播放地址已复制');
    } catch (e) {
      if (mounted) _snack('复制失败：$e');
    }
  }

  /// 编辑书源（对标原版 menu_edit_source）
  void _openEditSource() {
    if (_origin.isEmpty) {
      _snack('本书无关联书源');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SourceEditScreen(sourceUrl: _origin)),
    );
  }

  // ===== 音频章节预下载（契约 §2.48，对齐原版 AudioCacheService 批量循环）=====
  //
  // 原版语义（app/src/main/java/io/legado/app/）：写入与读取同目录同键——
  // 预下载写 AudioCacheManager.cacheChapter（AudioCacheService.kt:217 为全仓
  // 唯一调用方，前台服务），播放第一步读 getCachedAudio（AudioPlay.kt:388-413），
  // 键均为 AudioCacheKey.from(chapter)（AudioCacheKey.kt:20-23），.complete
  // 标记在下载完成并通过 size 校验后才写（AudioCacheManager.kt:174-189）。
  // 我方旧实现（B1 批已删除）写旧孤儿键（hashCode + 章节下标，无 .complete）
  // 落 support/SAF 目录，与新读面三重不匹配——旧写入路径**保持删除、不迁移**
  // （旧键按用户裁决默认不读）。
  //
  // [B2 | 2026-10-03] 写入面下沉 Rust（契约 §2.48：audioCacheDownload 流式
  // 下载安装 + `.complete` 标记，字节零穿越 FFI），本页只做原版服务循环的
  // 等价编排：逐章调 audioCacheDownload 并自持 done/total/fail（AudioCacheService
  // .kt:211-233）；playUrl 取播放链同源 `getAudioChapterMedia.mediaUrl`
  // （AudioPlay.kt:458 WebBook.getContent；**不用** getChapterContentFull——
  // 该路径会应用替换规则/简繁转换，URL 会被污染，见本批报告契约措辞偏差）；
  // 已缓存跳过 = 逐章 audioCacheQuery 按 key 判定（对齐原版 cachedKeys 键
  // 语义，AudioCacheService.kt:208-216）+ Rust 幂等 already_cached 双保险；
  // 运行中防重入（对齐原版单 worker 串行，AudioCacheService.kt:151-158）。
  // 「缓存目录」入口不在本批（SAF 与冻结私有缓存根冲突，见报告）。

  /// 「缓存章节范围」入口（对标原版 menu_audio_cache_range →
  /// AudioPlayActivity.showAudioCacheRange:281-316）
  Future<void> _showAudioCacheRange() async {
    final api = ref.read(bookApiProvider);
    final bookUrl = widget.effectiveBookUrl;
    if (bookUrl.isEmpty) return;
    List<BookChapter> chapters;
    try {
      chapters = await api.getChapters(bookUrl);
    } catch (e) {
      // 原版 ensureChapterList 失败 → 静默中止整段范围（AudioCacheService.kt:199,236-257）
      debugPrint('[audio-cache] 获取章节列表失败（中止缓存范围）：$e');
      return;
    }
    final chapterCount = chapters.length;
    // 原版 chapterCount <= 0 直接 return（AudioPlayActivity.kt:285）
    if (chapterCount <= 0 || !mounted) return;
    final fromIndex = (ref.read(audioNotifierProvider).currentIndex + 1).clamp(
      1,
      chapterCount,
    );
    final startCtrl = TextEditingController(text: '$fromIndex');
    final endCtrl = TextEditingController(text: '$chapterCount');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // 文案逐字对齐原版 values-zh：audio_cache_range / chapter / start / to / end
        title: const Text('缓存章节范围'),
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('章'),
            const SizedBox(width: 6),
            SizedBox(
              width: 64,
              child: TextField(
                controller: startCtrl,
                keyboardType: TextInputType.number,
                maxLength: 5,
                decoration: const InputDecoration(
                  hintText: '开始',
                  isDense: true,
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text('至'),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: TextField(
                controller: endCtrl,
                keyboardType: TextInputType.number,
                maxLength: 5,
                decoration: const InputDecoration(
                  hintText: '结束',
                  isDense: true,
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 原版 1-based 输入 → 0-based，toIntOrNull 失败按 -1（AudioPlayActivity.kt:293-299）
    final start = (int.tryParse(startCtrl.text.trim()) ?? 0) - 1;
    final end = (int.tryParse(endCtrl.text.trim()) ?? 0) - 1;
    final range = _normalizeAudioCacheRange(start, end, chapterCount);
    if (range == null) {
      _snack('请输入正确的范围'); // error_scope_input
      return;
    }
    // P1-1 防重入：原版由前台服务单 worker 串行承担（AudioCacheService.kt:151-158
    // startWorkerLocked 在 worker 存活时不再起第二个），本页无服务队列，运行中拒绝
    // 启动第二批（Rust 侧 (bookUrl,key16) 分片锁为并发兜底）。原版菜单**无**禁用态
    // （AudioPlayActivity.kt:235-237 无 onPrepareOptionsMenu/isEnabled），故不新增禁用。
    if (_audioCacheRunning) {
      _snack('已有缓存任务在运行');
      return;
    }
    unawaited(_runAudioCacheBatch(chapters, range.$1, range.$2));
    _snack('已加入音频缓存队列'); // audio_cache_start_range
  }

  /// 范围规范化（对齐原版 `AudioCachePolicy.normalizeRange:20-23`）：
  /// `start < 0 || endInclusive < start || start >= chapterCount` → null；
  /// 否则 end 截到末章（含端点，0-based 返回 Record）。
  (int, int)? _normalizeAudioCacheRange(
    int start,
    int endInclusive,
    int chapterCount,
  ) {
    if (start < 0 || endInclusive < start || start >= chapterCount) return null;
    final end = endInclusive < chapterCount - 1
        ? endInclusive
        : chapterCount - 1;
    return (start, end);
  }

  /// 批量缓存循环（对齐原版 `AudioCacheService.processTask:187-234`）：
  /// 逐章取址 → audioCacheDownload；分卷跳过不计失败、已缓存跳过；
  /// 每章 done++、失败 fail++；「停止」经令牌中止后续调用。
  Future<void> _runAudioCacheBatch(
    List<BookChapter> chapters,
    int start,
    int end,
  ) async {
    final api = ref.read(bookApiProvider);
    final bookUrl = widget.effectiveBookUrl;
    final token = ++_audioCacheRunToken;
    setState(() {
      _audioCacheRunning = true;
      _audioCacheDone = 0;
      _audioCacheTotal = end - start + 1;
      _audioCacheFail = 0;
    });
    for (var index = start; index <= end; index++) {
      if (!mounted || token != _audioCacheRunToken) return;
      final chapter = index < chapters.length ? chapters[index] : null;
      if (chapter == null) {
        _bumpAudioCacheProgress(fail: true);
        continue;
      }
      // 分卷章节：原版服务循环跳过且不计失败（AudioCacheService.kt:214）
      if (chapter.isVolume) {
        _bumpAudioCacheProgress();
        continue;
      }
      // 已缓存跳过：逐章按 key 判定（对齐原版 `key !in cachedKeys`，
      // AudioCacheService.kt:208-216；键只由 chapterUrl/title 决定）。不用
      // audioCacheList 的下标——它记录的是下载时刻的文件名下标，TOC 重排后
      // 按下标跳过会漏下本章（P2-4）。查询失败按未缓存处理（Rust 侧幂等
      // already_cached 兜底，最多多一次取址）。
      var cached = false;
      try {
        cached = await api.audioCacheQuery(
          bookUrl: bookUrl,
          chapterIndex: index,
          chapterUrl: chapter.url,
          chapterTitle: chapter.title,
        );
      } catch (e) {
        debugPrint('[audio-cache] 查询第 ${index + 1} 章缓存失败（按未缓存处理）：$e');
      }
      if (cached) {
        _bumpAudioCacheProgress();
        continue;
      }
      var failed = false;
      try {
        // playUrl 取内容链（与播放链同源：AudioPlay.kt:458 WebBook.getContent →
        // 我方 getAudioChapterMedia.mediaUrl，含缓存命中路径与空源回退）
        final media = await api.getAudioChapterMedia(bookUrl, index);
        final playUrl = (media['mediaUrl'] as String? ?? '').trim();
        await api.audioCacheDownload(
          bookUrl: bookUrl,
          chapterIndex: index,
          chapterUrl: chapter.url,
          chapterTitle: chapter.title,
          playUrl: playUrl,
        );
      } catch (e) {
        // 写入面上抛不降级（契约 §2.48）：逐章计 failCount，循环继续
        debugPrint('[audio-cache] 第 ${index + 1} 章缓存失败：$e');
        failed = true;
      }
      if (!mounted || token != _audioCacheRunToken) return;
      _bumpAudioCacheProgress(fail: failed);
      // [B2-EVT] 每章缓存成功后发进程内事件（对齐原版循环成功分支
      // postEvent(AUDIO_CACHE_CHANGED)，AudioCacheService.kt:222-225）：
      // 目录页订阅后立即重查 audioCacheList 亮起徽标，不必等 1s 轮询；
      // 失败章不发（原版仅 error == null 分支发事件）
      if (!failed) {
        AudioCacheEvents.instance.notifyChapterCached(
          bookUrl: bookUrl,
          chapterIndex: index,
        );
      }
    }
    if (!mounted || token != _audioCacheRunToken) return;
    setState(() => _audioCacheRunning = false);
  }

  /// 进度计数（对齐原版通知 done/total/fail，AudioCacheService.kt:275-301）
  void _bumpAudioCacheProgress({bool fail = false}) {
    if (!mounted) return;
    setState(() {
      _audioCacheDone++;
      if (fail) _audioCacheFail++;
    });
  }

  /// 停止批量缓存（对齐原版通知 stop 动作 → stopAndClear:259-266）：
  /// 令牌自增停止后续章节调用 + Rust audioCacheCancel 中止在途流式拷贝。
  Future<void> _cancelAudioCacheBatch() async {
    _audioCacheRunToken++;
    if (mounted) setState(() => _audioCacheRunning = false);
    try {
      await ref.read(bookApiProvider).audioCacheCancel();
    } catch (e) {
      debugPrint('[audio-cache] 取消在途下载失败：$e');
    }
  }

  /// 「清除本章缓存」入口（对标原版 menu_clear_current_audio_cache →
  /// AudioPlayActivity.clearCurrentAudioCache:318-349；toast 文案逐字对齐
  /// audio_cache_current_chapter_cleared / _not_found）
  Future<void> _clearCurrentAudioCache() async {
    final api = ref.read(bookApiProvider);
    final bookUrl = widget.effectiveBookUrl;
    final currentIndex = ref.read(audioNotifierProvider).currentIndex;
    if (bookUrl.isEmpty) return;
    BookChapter? chapter;
    try {
      final chapters = await api.getChapters(bookUrl);
      chapter = chapters.where((c) => c.index == currentIndex).firstOrNull;
    } catch (e) {
      debugPrint('[audio-cache] 清除本章缓存前获取章节失败：$e');
      return;
    }
    if (chapter == null) return;
    // 返回数据文件删除数：>0 → 已清除；0 → 本章没有缓存（幂等语义）
    final removed = await api.audioCacheClearChapter(
      bookUrl: bookUrl,
      chapterIndex: currentIndex,
      chapterUrl: chapter.url,
      chapterTitle: chapter.title,
    );
    if (removed > 0) {
      _snack('已清除本章缓存');
    } else {
      _snack('本章没有缓存');
    }
  }

  Future<void> _showSkipCreditsSheet() async {
    final api = ref.read(bookApiProvider);
    final book = widget.book;
    var globalOpen =
        int.tryParse(await api.getConfig(kAudioSkipOpenCreditsKey) ?? '0') ?? 0;
    var globalClose =
        int.tryParse(await api.getConfig(kAudioSkipCloseCreditsKey) ?? '0') ??
        0;
    var useGlobal =
        (book?.readConfig?.openCredits ?? 0) == 0 &&
        (book?.readConfig?.closeCredits ?? 0) == 0;
    var open = useGlobal ? globalOpen : (book?.readConfig?.openCredits ?? 0);
    var close = useGlobal ? globalClose : (book?.readConfig?.closeCredits ?? 0);

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 8,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('跳过片头片尾', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('全局')),
                      ButtonSegment(value: false, label: Text('本书')),
                    ],
                    selected: {useGlobal},
                    onSelectionChanged: (s) {
                      setSheet(() {
                        useGlobal = s.first;
                        if (useGlobal) {
                          open = globalOpen;
                          close = globalClose;
                        } else {
                          open = book?.readConfig?.openCredits ?? globalOpen;
                          close = book?.readConfig?.closeCredits ?? globalClose;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Text('片头 $open 秒'),
                  Slider(
                    value: open.toDouble().clamp(0, 120),
                    max: 120,
                    divisions: 120,
                    label: '$open',
                    onChanged: (v) => setSheet(() => open = v.round()),
                  ),
                  Text('片尾 $close 秒'),
                  Slider(
                    value: close.toDouble().clamp(0, 120),
                    max: 120,
                    divisions: 120,
                    label: '$close',
                    onChanged: (v) => setSheet(() => close = v.round()),
                  ),
                  FilledButton(
                    onPressed: () async {
                      if (useGlobal) {
                        await api.setConfig(kAudioSkipOpenCreditsKey, '$open');
                        await api.setConfig(
                          kAudioSkipCloseCreditsKey,
                          '$close',
                        );
                        if (book != null) {
                          final cfg = book.readConfig ?? const ReadConfig();
                          await api.updateBook(
                            book.copyWith(
                              readConfig: cfg.copyWith(
                                openCredits: 0,
                                closeCredits: 0,
                              ),
                            ),
                          );
                        }
                      } else if (book != null) {
                        final cfg = book.readConfig ?? const ReadConfig();
                        await api.updateBook(
                          book.copyWith(
                            readConfig: cfg.copyWith(
                              openCredits: open,
                              closeCredits: close,
                            ),
                          ),
                        );
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ref.read(audioNotifierProvider.notifier).bindBook(book);
                        _snack('已保存片头片尾设置');
                      }
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 统一 snackbar 提示
  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
