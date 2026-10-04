import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/misc.dart';
import '../../providers/audio/audio_notifier.dart';
import '../../providers/providers.dart';
import '../../routes.dart';
import '../app_progress_indicator.dart';

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
  //
  // [A4 下沉 | 2026-10-04] 计时归 AudioNotifier（startSleepTimer /
  // startChapterStop / cancelSleepTimer，audio_notifier.dart:1040-1075），
  // 朗读条只做入口与显示。原本地 Timer 与 _chapterStopTarget 已删除：二者
  // 与 Notifier 计时互不感知，导致双倒计时并行、幽灵暂停、收起阅读器即
  // 静默失效。到点动作对齐原版 doDs 的 ReadAloud.stop
  // （BaseReadAloudService.kt:594）。
  final TextEditingController _customMinutesCtrl = TextEditingController();

  // ===== 语速跟随系统（原版默认 true） =====
  bool _followSystemSpeed = true;

  // [LAYOUT_PLAN P4] 朗读条显隐 fade（180ms）：挂载后下一帧置 true。
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFollowSystem());
    // [LAYOUT_PLAN P4] 触发朗读条 fade 进场（替代底栏时的显隐逻辑不变）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  void dispose() {
    _customMinutesCtrl.dispose();
    super.dispose();
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

  /// 定时按钮 tooltip：剩余量/按章剩余均取 Notifier 单一数据源
  String _timerTooltip(AudioNotifier notifier) {
    switch (notifier.sleepTimerMode) {
      case SleepTimerMode.duration:
        return '定时停止：剩余 '
            '${_formatCountdown(notifier.sleepRemainingSeconds)}';
      case SleepTimerMode.chapters:
        return '定时停止：读完 ${notifier.chaptersToStopRemaining} 章后停止';
      case SleepTimerMode.off:
        return '定时停止';
    }
  }

  String _formatCountdown(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// 定时停止选择面板（预设时长 + 自定义 + 按章停 + 取消）
  ///
  /// [A4 下沉 | 2026-10-04] 设定/取消直接调 AudioNotifier 既有计时入口
  /// （startSleepTimer / startChapterStop / cancelSleepTimer），朗读条不再持有
  /// 任何计时状态；面板状态与剩余量取自 Notifier，与听书页/通知栏同一份。
  void _showTimerPicker() {
    final notifier = ref.read(audioNotifierProvider.notifier);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: false,
      builder: (sheetContext) {
        return SafeArea(
          // [2026-10-04] 面板内容超过弹窗默认最大高度（9/16 屏高）时
          // RenderFlex 溢出：与听书页定时面板同型包 SingleChildScrollView，
          // 小屏/窄高窗口下可滚动（原实现缺此包裹，为既有溢出问题）
          child: SingleChildScrollView(
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
                      notifier.startSleepTimer(minutes);
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
                    if (value > 0 && value <= kMaxSleepTimerMinutes) {
                      Navigator.pop(sheetContext);
                      notifier.startSleepTimer(value);
                    }
                  },
                ),
                // 按章停：当前章自然读完即停（对标原版按章定时；Notifier 在章末
                // 完成边界计数，到点 stop —— BaseReadAloudService.kt:886-892）
                ListTile(
                  leading: const Icon(Icons.menu_book_outlined),
                  title: const Text('读完本章后停止'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    notifier.startChapterStop(1);
                  },
                ),
                if (notifier.isSleepTimerActive)
                  ListTile(
                    leading: const Icon(Icons.timer_off_outlined),
                    title: const Text('取消定时'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      notifier.cancelSleepTimer();
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 引擎选择对话框（getHttpTts 列表，对标原版引擎下拉）
  Future<void> _showEngineDialog() async {
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
    // [引擎双持久化 | 2026-10-04] 当前值取「有效引擎」（书级优先、空则全局
    // 回退），对齐原版对话框 `ttsEngine = ReadAloud.ttsEngine`
    // （SpeakEngineDialog.kt:57）；此前只看全局内存值，书级生效时会高亮错误项。
    final notifier = ref.read(audioNotifierProvider.notifier);
    final currentUrl = normalizeTtsEngineUrl(notifier.resolveTtsEngineUrl());
    String? currentName;
    HttpTts? currentEngine;
    if (currentUrl.isNotEmpty) {
      for (final engine in engines) {
        if (normalizeTtsEngineUrl(engine.url) == currentUrl) {
          currentName = engine.name;
          currentEngine = engine;
          break;
        }
      }
    }
    // 双持久化按钮作用的引擎（dialog 回调闭包捕获需 final）
    final selectedEngine = currentEngine;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择朗读引擎'),
        children: [
          RadioGroup<String>(
            groupValue: currentName,
            onChanged: (v) {
              // [UX 修复 | 2026-10-03] 未选中项：RadioGroup 回传新值；已选中项：
              // RadioListTile 开启 toggleable 后回传 null（点已选项不产生新值）。
              // 两种点击都要关闭对话框——对齐原版 SpeakEngineDialog 点击任意项
              // 均 upTts（已选项为幂等重确认），此前已选项点击走不到关闭逻辑。
              final name = v ?? currentName;
              if (name == null) return;
              final engine = engines.firstWhere((e) => e.name == name);
              Navigator.pop(dialogContext);
              // [P0 | 2026-10-03] 只存裸 URL：合成管线（Rust tts_speak）把
              // engineUrl 当 URL 模板与缓存键，存「名称,URL」必然合成失败。
              // [引擎双持久化 | 2026-10-04] 快捷切换按原版「全局」语义落库
              // （先清书级覆盖再写全局，SpeakEngineDialog.kt:171-177）：书级
              // 优先下若只写全局内存值，该书仍会继续用书级引擎，切换不生效。
              unawaited(
                notifier.setGlobalTtsEngine(engine.url),
              );
              _snack('已切换引擎：${engine.name}');
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final engine in engines)
                  RadioListTile<String>(
                    title: Text(engine.name),
                    value: engine.name,
                    // 已选中项默认吞掉点击（Flutter _handleListTileTap 对
                    // checked 且非 toggleable 直接 return，本版 RadioListTile
                    // 未暴露 onTap 参数）；toggleable 让已选项点击回传 null，
                    // 交给上面的 onChanged 统一处理
                    toggleable: true,
                  ),
              ],
            ),
          ),
          // [引擎双持久化 | 2026-10-04] 底部动作对齐原版 SpeakEngineDialog
          // 布局（dialog_recycler_view.xml:94-141：左侧「书」，右侧「取消」
          // 「全局」）与文案（values-zh/strings.xml：book=书:264、
          // general=全局:1207）。语义照原版按钮 onClick（:164-177）：
          // 「书」只写当前书 readConfig.ttsEngine；「全局」先清书级再写全局。
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(
              children: [
                TextButton(
                  onPressed: selectedEngine == null
                      ? null
                      : () => _applyEngine(
                            dialogContext,
                            selectedEngine,
                            bookLevel: true,
                          ),
                  child: const Text('书'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: selectedEngine == null
                      ? null
                      : () => _applyEngine(
                            dialogContext,
                            selectedEngine,
                            bookLevel: false,
                          ),
                  child: const Text('全局'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 双击持久化路径的落库动作
  ///
  /// [bookLevel] true = 「书」按钮：只写当前书 readConfig.ttsEngine（原版
  /// `ReadBook.book?.setTtsEngine(ttsEngine)`，SpeakEngineDialog.kt:164-170）；
  /// false = 「全局」按钮：先清书级覆盖再写全局（原版 :171-177）。
  Future<void> _applyEngine(
    BuildContext dialogContext,
    HttpTts engine, {
    required bool bookLevel,
  }) async {
    final navigator = Navigator.of(dialogContext);
    final notifier = ref.read(audioNotifierProvider.notifier);
    var ok = true;
    if (bookLevel) {
      ok = await notifier.setBookTtsEngine(engine.url);
    } else {
      await notifier.setGlobalTtsEngine(engine.url);
    }
    if (!mounted) return;
    navigator.pop();
    if (bookLevel && !ok) {
      // 对齐原版空安全语义：无当前书时不写、如实告知（不静默假装成功）
      _snack('未打开书籍，无法设为本书引擎');
      return;
    }
    _snack(bookLevel ? '已设为本书引擎：${engine.name}' : '已设为全局引擎：${engine.name}');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final audio = ref.watch(audioNotifierProvider);
    final notifier = ref.read(audioNotifierProvider.notifier);
    final theme = Theme.of(context);

    // [A4 下沉 | 2026-10-04] 段落进度与定时剩余量统一经 ListenableBuilder
    // 订阅 Notifier（照听书页 audio_screen.dart 同型）。定时计时已不在本条，
    // 重建/卸载不影响在途倒计时；按章停止的边界计数亦由 Notifier 承担。
    return ListenableBuilder(
      listenable: notifier,
      builder: (context, _) => Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        // [LAYOUT_PLAN P4] 朗读条显隐 fade（180ms；替代底栏时的挂载逻辑不变）。
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _entered ? 1.0 : 0.0,
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
                  // [A1 批 2026-10-03] 合成/播放失败降级提示（errorMessage 为
                  // 播放中仍可见的非致命提示；error 态另有状态文案） — Auto
                  if (audio.errorMessage != null)
                    _buildErrorBanner(audio, theme),
                  _buildTransport(context, audio, notifier, theme),
                  _buildSpeedRow(context, audio, notifier),
                  _buildBottomActions(context, audio),
                ],
              ),
            ),
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
          // [A4 下沉 | 2026-10-04] 定时入口状态与剩余量全部取 Notifier
          // （单一数据源，与听书页/通知栏展示同一份剩余量）
          IconButton(
            icon: Icon(
              notifier.isSleepTimerActive
                  ? Icons.timer
                  : Icons.timer_outlined,
              color: notifier.isSleepTimerActive
                  ? theme.colorScheme.primary
                  : null,
            ),
            tooltip: _timerTooltip(notifier),
            onPressed: _showTimerPicker,
          ),
          if (notifier.sleepTimerMode == SleepTimerMode.duration)
            Text(
              _formatCountdown(notifier.sleepRemainingSeconds),
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

  /// 失败降级提示条（合成/播放失败按估算时长继续时展示，不静默）
  Widget _buildErrorBanner(AudioState audio, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              audio.errorMessage!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
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
                  // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（保留 2dp 实参）
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: AppCircularProgressIndicator(strokeWidth: 2),
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
            onPressed: () => _showEngineDialog(),
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
