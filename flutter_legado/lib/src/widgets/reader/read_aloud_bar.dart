import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/misc.dart';
import '../../providers/audio/audio_notifier.dart';
import '../../providers/providers.dart';
import '../../routes.dart';

/// 阅读器朗读控制条
///
/// [UI-fix v2.0.1 | 2026-08-06] 新增：对标原版 ReadAloudDialog（dialog_read_aloud）
/// 的朗读控制面板，朗读激活时替代底部功能栏常驻显示 — Qoder
///
/// 原版控制项对照：
/// - tv_pre / tv_next（上一章/下一章）→ 已实现
/// - iv_play_pause（播放/暂停）/ iv_stop（停止）→ 已实现
/// - seekTtsSpeechRate（语速）→ 已实现（Slider 0.5x~3.0x）
/// - iv_play_prev / iv_play_next（上一段/下一段）→
///   [UI-fix v2.0.3 | 2026-08-08] 已接入 AudioNotifier 段落化队列（留项4） — Qoder
/// - [UI-fix v2.0.2 | 2026-08-06] ivTimer/SleepTimerDialog 定时停止 +
///   按章停 + 引擎选择 + 语速跟随系统开关 — Qoder
/// - ll_catalog / ll_setting / ll_to_backstage（目录/朗读设置/转后台）→ 已实现
class ReadAloudBar extends ConsumerStatefulWidget {
  /// 收起控制条（朗读继续，仅隐藏面板）
  final VoidCallback onDismiss;

  /// 打开目录（对标 ll_catalog → openChapterList）
  final VoidCallback onOpenCatalog;

  /// 转后台：退出阅读器，朗读继续（对标 ll_to_backstage → finish）
  final VoidCallback onBackstage;

  const ReadAloudBar({
    super.key,
    required this.onDismiss,
    required this.onOpenCatalog,
    required this.onBackstage,
  });

  @override
  ConsumerState<ReadAloudBar> createState() => _ReadAloudBarState();
}

class _ReadAloudBarState extends ConsumerState<ReadAloudBar> {
  /// 定时停止预设（分钟），复用听书页 SleepTimer 模式
  static const _kPresetMinutes = [10, 20, 30, 60];

  /// 语速跟随系统开关持久化键（对齐原版 PreferKey / AppConfig.ttsFlowSys）
  static const _keyFollowSystem = 'ttsFollowSys';

  /// [UI-fix v2.0.3 | 2026-08-08] 留项5：语速跟随系统时使用的默认语速常量
  /// （对标原版 AppConfig.speechRatePlay = if (ttsFlowSys) defaultSpeechRate(=5)）：
  /// 原版并非实时读系统语速，而是回落到默认语速常量；Flutter 侧默认倍速 1.0x
  /// 即原版 defaultSpeechRate=5（0-10 刻度中位）的等价映射 — Qoder
  static const double _kFollowSystemDefaultSpeed = 1.0;

  // ===== 定时停止状态 =====
  Timer? _stopTimer;
  int _remainingSeconds = 0;
  final TextEditingController _customMinutesCtrl = TextEditingController();

  // ===== 按章停状态 =====

  /// 目标章节索引：朗读 currentIndex 到达后自动暂停（null=未启用）
  int? _chapterStopTarget;

  // ===== 语速跟随系统（原版默认 true） =====
  bool _followSystemSpeed = true;

  /// 段落进度订阅的 Notifier 引用（dispose 时安全注销，避免 dispose 期读 ref）
  AudioNotifier? _paragraphSubNotifier;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFollowSystem());
    // [UI-fix v2.0.3 | 2026-08-08] 段落进度订阅：AudioNotifier 混入
    // ChangeNotifier 通知段落切换（freezed State 仅承载章节级状态） — Qoder
    final notifier = ref.read(audioNotifierProvider.notifier);
    _paragraphSubNotifier = notifier;
    notifier.addListener(_onParagraphChanged);
  }

  @override
  void dispose() {
    _paragraphSubNotifier?.removeListener(_onParagraphChanged);
    _paragraphSubNotifier = null;
    _stopTimer?.cancel();
    _customMinutesCtrl.dispose();
    super.dispose();
  }

  void _onParagraphChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFollowSystem() async {
    try {
      final api = ref.read(bookApiProvider);
      // 优先 config（对齐业务数据不经 SharedPreferences）；兼容旧 SP 键迁移
      var raw = await api.getConfig(_keyFollowSystem);
      if (raw == null || raw.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final legacy = prefs.getBool('read_aloud_follow_system_speed');
        if (legacy != null) {
          raw = legacy ? 'true' : 'false';
          await api.setConfig(_keyFollowSystem, raw);
          await prefs.remove('read_aloud_follow_system_speed');
        }
      }
      if (!mounted) return;
      // 缺省对齐原版 AppConfig.ttsFlowSys = true
      final follow = raw == null || raw.isEmpty
          ? true
          : raw == 'true' || raw == '1';
      setState(() => _followSystemSpeed = follow);
      if (follow) {
        ref
            .read(audioNotifierProvider.notifier)
            .updateConfig(speed: _kFollowSystemDefaultSpeed);
      }
    } catch (_) {
      // 读取失败保持原版默认开启
      if (mounted) {
        setState(() => _followSystemSpeed = true);
        ref
            .read(audioNotifierProvider.notifier)
            .updateConfig(speed: _kFollowSystemDefaultSpeed);
      }
    }
  }

  Future<void> _persistFollowSystem(bool follow) async {
    try {
      await ref.read(bookApiProvider).setConfig(
            _keyFollowSystem,
            follow ? 'true' : 'false',
          );
    } catch (_) {}
  }

  bool get _isTimerActive => _remainingSeconds > 0;

  /// 启动定时停止（每秒递减，到时暂停朗读；复用听书页 SleepTimer 逻辑）
  void _startTimer(int minutes) {
    _stopTimer?.cancel();
    final totalSeconds = minutes * 60;
    setState(() => _remainingSeconds = totalSeconds);
    _stopTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _remainingSeconds--;
        if (_remainingSeconds <= 0) {
          timer.cancel();
          _remainingSeconds = 0;
          ref.read(audioNotifierProvider.notifier).pause();
        }
      });
    });
  }

  void _cancelTimer() {
    _stopTimer?.cancel();
    _stopTimer = null;
    setState(() => _remainingSeconds = 0);
  }

  String _formatCountdown(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 定时停止选择面板（预设时长 + 自定义 + 按章停 + 取消）
  void _showTimerPicker(AudioState audio) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '定时停止',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ..._kPresetMinutes.map(
                (minutes) => ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: Text('$minutes 分钟'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _startTimer(minutes);
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Row(
                  children: [
                    const Text('自定义'),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 60,
                      child: TextField(
                        controller: _customMinutesCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          hintText: '分钟',
                          isDense: true,
                          border: UnderlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('分钟'),
                  ],
                ),
                onTap: () {
                  final value = int.tryParse(_customMinutesCtrl.text) ?? 0;
                  if (value > 0 && value <= 180) {
                    Navigator.pop(sheetContext);
                    _startTimer(value);
                  }
                },
              ),
              // 按章停：读完指定章节后自动暂停（对标原版按章定时）
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('读完本章后停止'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() {
                    _chapterStopTarget = audio.currentIndex + 1;
                  });
                },
              ),
              if (_isTimerActive || _chapterStopTarget != null)
                ListTile(
                  leading: const Icon(Icons.timer_off_outlined),
                  title: const Text('取消定时'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _cancelTimer();
                    setState(() => _chapterStopTarget = null);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 引擎选择对话框（getHttpTts 列表，对标原版引擎下拉）
  Future<void> _showEngineDialog(AudioState audio) async {
    List<HttpTts> engines;
    try {
      engines = await ref.read(bookApiProvider).getHttpTts();
    } catch (e) {
      if (mounted) _snack('朗读引擎列表加载失败: $e');
      return;
    }
    if (!mounted) return;
    if (engines.isEmpty) {
      _snack('暂无朗读引擎，请到「朗读设置」添加 HTTP TTS 引擎');
      return;
    }
    // engineUrl 存储格式 "name,url"（与朗读设置页一致），取逗号前部分匹配
    final currentName = audio.config.engineUrl.split(',').first;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择朗读引擎'),
        children: [
          RadioGroup<String>(
            groupValue: currentName,
            onChanged: (v) {
              if (v == null) return;
              final engine = engines.firstWhere((e) => e.name == v);
              Navigator.pop(dialogContext);
              ref
                  .read(audioNotifierProvider.notifier)
                  .updateConfig(engineUrl: '${engine.name},${engine.url}');
              _snack('已切换引擎：${engine.name}');
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final engine in engines)
                  RadioListTile<String>(
                    title: Text(engine.name),
                    value: engine.name,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final audio = ref.watch(audioNotifierProvider);
    final notifier = ref.read(audioNotifierProvider.notifier);
    final theme = Theme.of(context);

    // [UI-fix v2.0.2 | 2026-08-06] 按章停：朗读章节推进越过目标章节即暂停
    // （build 阶段不可同步改 provider，延迟到下一帧执行） — Qoder
    final target = _chapterStopTarget;
    if (target != null &&
        audio.currentIndex >= target &&
        audio.state != PlayerState.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _chapterStopTarget = null);
        ref.read(audioNotifierProvider.notifier).pause();
      });
    }

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        color: theme.colorScheme.surface,
        // 与 ReaderBottomBar 一致：无阴影 + hairline 顶边
        elevation: 0,
        shape: Border(
          top: BorderSide(
            color: theme.dividerTheme.color ?? theme.dividerColor,
            width: 0.0,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(context, audio, notifier, theme),
              _buildTransport(context, audio, notifier, theme),
              _buildSpeedRow(context, audio, notifier),
              _buildBottomActions(context, audio),
            ],
          ),
        ),
      ),
    );
  }

  /// 第一行：朗读状态 + 章节信息 + 定时按钮 + 收起按钮
  Widget _buildHeader(
    BuildContext context,
    AudioState audio,
    AudioNotifier notifier,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
      child: Row(
        children: [
          Icon(
            audio.isPlaying
                ? Icons.graphic_eq
                : audio.isLoading
                    ? Icons.hourglass_top
                    : audio.state == PlayerState.error
                        ? Icons.error_outline
                        : Icons.pause_circle_outline,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            _statusText(audio),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              audio.currentChapter?.title ?? '未选择章节',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium,
            ),
          ),
          Text(
            '${audio.currentIndex + 1}/${audio.totalChapters}',
            style: theme.textTheme.labelSmall,
          ),
          // [UI-fix v2.0.3 | 2026-08-08] 留项4：段落进度指示（对标原版
          // 朗读进度文本的段落维度） — Qoder
          if (notifier.paragraphCount > 0)
            Text(
              '·段${notifier.currentParagraphIndex + 1}/${notifier.paragraphCount}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          // [UI-fix v2.0.2 | 2026-08-06] 定时停止入口（对标原版 ivTimer） — Qoder
          IconButton(
            icon: Icon(
              _isTimerActive || _chapterStopTarget != null
                  ? Icons.timer
                  : Icons.timer_outlined,
              color: _isTimerActive || _chapterStopTarget != null
                  ? theme.colorScheme.primary
                  : null,
            ),
            tooltip: _isTimerActive
                ? '定时停止：剩余 ${_formatCountdown(_remainingSeconds)}'
                : _chapterStopTarget != null
                    ? '定时停止：读完本章后暂停'
                    : '定时停止',
            onPressed: () => _showTimerPicker(audio),
          ),
          if (_isTimerActive)
            Text(
              _formatCountdown(_remainingSeconds),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.expand_more),
            tooltip: '收起朗读面板',
            onPressed: widget.onDismiss,
          ),
        ],
      ),
    );
  }

  /// 第二行：章节/段落切换 + 播放暂停（对标 tv_pre/iv_play_prev/iv_play_pause/iv_play_next/tv_next）
  Widget _buildTransport(
    BuildContext context,
    AudioState audio,
    AudioNotifier notifier,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton(
            onPressed: audio.hasPrevious ? notifier.previous : null,
            child: const Text('上一章'),
          ),
          // [UI-fix v2.0.3 | 2026-08-08] 留项4：上一段接入段落化队列，
          // 对标原版 ivPlayPrev → ReadAloud.prevParagraph — Qoder
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一段',
            onPressed: audio.state != PlayerState.idle &&
                    notifier.paragraphCount > 0
                ? notifier.prevParagraph
                : null,
          ),
          SizedBox(
            width: 56,
            height: 56,
            child: FloatingActionButton(
              heroTag: 'read_aloud_play_pause',
              elevation: 0,
              onPressed: () {
                if (audio.isPlaying) {
                  notifier.pause();
                } else {
                  notifier.play();
                }
              },
              child: audio.isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      audio.isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 30,
                    ),
            ),
          ),
          // [UI-fix v2.0.3 | 2026-08-08] 留项4：下一段接入段落化队列，
          // 对标原版 ivPlayNext → ReadAloud.nextParagraph — Qoder
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一段',
            onPressed: audio.state != PlayerState.idle &&
                    notifier.paragraphCount > 0
                ? notifier.nextParagraph
                : null,
          ),
          TextButton(
            onPressed: audio.hasNext ? notifier.next : null,
            child: const Text('下一章'),
          ),
        ],
      ),
    );
  }

  /// 第三行：停止 + 语速（对标 iv_stop + seekTtsSpeechRate + cbTtsFollowSystem）
  Widget _buildSpeedRow(
    BuildContext context,
    AudioState audio,
    AudioNotifier notifier,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined, size: 28),
            tooltip: '停止朗读',
            onPressed: () {
              notifier.stop();
              widget.onDismiss();
            },
          ),
          const SizedBox(width: 4),
          const Text('语速'),
          Expanded(
            // [UI-fix v2.0.2 | 2026-08-06] 语速跟随系统开关（对标原版
            // cbTtsFollowSystem）：开启时禁用手动滑条。
            // [UI-fix v2.0.3 | 2026-08-08] 留项5 语义对齐原版 speechRatePlay：
            // 跟随系统 = 使用默认语速常量（非实时读系统语速） — Qoder
            child: Slider(
              value: audio.config.speed,
              min: 0.5,
              max: 3.0,
              divisions: 25,
              label: '${audio.config.speed.toStringAsFixed(1)}x',
              onChanged: _followSystemSpeed
                  ? null
                  : (v) => notifier.updateConfig(speed: v),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              _followSystemSpeed
                  ? '默认'
                  : '${audio.config.speed.toStringAsFixed(1)}x',
            ),
          ),
          // 引擎选择（对标原版引擎下拉）
          IconButton(
            icon: const Icon(Icons.record_voice_over_outlined),
            tooltip: '选择朗读引擎',
            onPressed: () => _showEngineDialog(audio),
          ),
        ],
      ),
    );
  }

  /// 第四行：目录/引擎与语速跟随/朗读设置/转后台
  ///
  /// [UI-fix v2.0.3 | 2026-08-08] 窄屏（720px 级）四按钮横排溢出 59px
  /// 黄条：每项套 Expanded 均分宽度 + 紧凑内边距，任意屏宽不溢出 — Qoder
  Widget _buildBottomActions(BuildContext context, AudioState audio) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              icon: const Icon(Icons.toc, size: 18),
              label: const Text('目录'),
              style: _compactButtonStyle,
              onPressed: widget.onOpenCatalog,
            ),
          ),
          Expanded(
            child: TextButton.icon(
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('朗读设置'),
              style: _compactButtonStyle,
              onPressed: () =>
                  Navigator.pushNamed(context, AppRoutes.readAloudConfig),
            ),
          ),
          // [UI-fix v2.0.2 | 2026-08-06] 语速跟随系统开关（显式入口）。
          // [UI-fix v2.0.3 | 2026-08-08] 留项5 闭合：勾选→应用默认语速常量
          // （对标原版 ttsFlowSys 时 speechRatePlay=defaultSpeechRate，
          // 无需系统语速读取通道）。
          // [UI-fix v2.0.41 | 2026-08-13] 默认 true + 持久化迁 config 键 ttsFollowSys — Auto
          Expanded(
            child: TextButton.icon(
              icon: Icon(
                _followSystemSpeed
                    ? Icons.speed
                    : Icons.speed_outlined,
                size: 18,
              ),
              label: Text(_followSystemSpeed ? '语速:跟随系统' : '语速:手动'),
              style: _compactButtonStyle,
              onPressed: () async {
                final next = !_followSystemSpeed;
                await _persistFollowSystem(next);
                if (!mounted) return;
                setState(() => _followSystemSpeed = next);
                if (next) {
                  // 开启跟随：即刻回落到默认语速常量（原版语义）
                  ref
                      .read(audioNotifierProvider.notifier)
                      .updateConfig(speed: _kFollowSystemDefaultSpeed);
                }
              },
            ),
          ),
          Expanded(
            child: TextButton.icon(
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('转后台'),
              style: _compactButtonStyle,
              onPressed: widget.onBackstage,
            ),
          ),
        ],
      ),
    );
  }

  /// 紧凑按钮样式：缩小内边距，窄屏下四按钮可均分不溢出
  ButtonStyle get _compactButtonStyle => TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  String _statusText(AudioState audio) {
    switch (audio.state) {
      case PlayerState.playing:
        return '正在朗读';
      case PlayerState.paused:
        return '已暂停';
      case PlayerState.loading:
        return '加载中';
      case PlayerState.error:
        return '朗读出错';
      case PlayerState.idle:
        return '未开始';
    }
  }
}
