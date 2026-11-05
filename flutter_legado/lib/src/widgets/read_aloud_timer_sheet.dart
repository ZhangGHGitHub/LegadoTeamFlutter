import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/audio/audio_notifier.dart';
import '../services/read_aloud_timer_settings.dart';

/// 打开统一朗读定时 Sheet（设置批5c）
///
/// 朗读条与听书页共用：读取持久化设置（模式/分钟/章节/读完本章开关）后
/// 回显，但**不恢复运行中的倒计时**。运行中剩余量由 [AudioNotifier]
/// 单一数据源实时展示。
Future<void> showReadAloudTimerSheet(BuildContext context) async {
  final config = await ReadAloudTimerSettings.load();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => ReadAloudTimerSheet(initialConfig: config),
  );
}

/// 统一朗读定时设置 Sheet
///
/// 对齐参考版 `ReadAloudTimerSheet`：
/// - 分钟 / 章节两页签互斥；
/// - 分钟预设 0/10/20/30/60/90/120/180，滑块 0–180；
/// - 章节预设 0/1/2/3/5/10/20/50，滑块 0–50；
/// - 「读完本章再停」仅分钟模式显示（章节模式本身停在章末，隐藏并说明）；
/// - 运行中显示剩余量，并提供开始 / 取消 / 停止定时。
class ReadAloudTimerSheet extends ConsumerStatefulWidget {
  const ReadAloudTimerSheet({super.key, required this.initialConfig});

  final ReadAloudTimerConfig initialConfig;

  @override
  ConsumerState<ReadAloudTimerSheet> createState() =>
      _ReadAloudTimerSheetState();
}

class _ReadAloudTimerSheetState extends ConsumerState<ReadAloudTimerSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late ReadAloudTimerMode _mode;
  late double _minutes;
  late double _chapters;
  late bool _finishChapter;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialConfig.mode;
    _minutes = widget.initialConfig.minutes.toDouble();
    _chapters = widget.initialConfig.chapters.toDouble();
    _finishChapter = widget.initialConfig.finishCurrentChapterAfterTimer;
    _tabController = TabController(
      length: 2,
      initialIndex: _mode == ReadAloudTimerMode.chapter ? 1 : 0,
      vsync: this,
    )..addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  /// 切换页签即切换模式并持久化（对齐参考版「不留只选模式未设值的中间态」）
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final next = _tabController.index == 1
        ? ReadAloudTimerMode.chapter
        : ReadAloudTimerMode.minute;
    if (next == _mode) return;
    setState(() => _mode = next);
    unawaited(ReadAloudTimerSettings.saveMode(next));
  }

  void _selectMinutes(int minutes) {
    final normalized = normalizeReadAloudTimerMinutes(minutes);
    setState(() => _minutes = normalized.toDouble());
    unawaited(ReadAloudTimerSettings.saveMinutes(normalized));
  }

  void _selectChapters(int chapters) {
    final normalized = normalizeReadAloudTimerChapters(chapters);
    setState(() => _chapters = normalized.toDouble());
    unawaited(ReadAloudTimerSettings.saveChapters(normalized));
  }

  void _setFinishChapter(bool enabled) {
    setState(() => _finishChapter = enabled);
    // 同步内存镜像并持久化（分钟到点判定使用 Notifier 镜像）
    ref
        .read(audioNotifierProvider.notifier)
        .setFinishCurrentChapterAfterTimer(enabled);
  }

  void _start() {
    final notifier = ref.read(audioNotifierProvider.notifier);
    if (_mode == ReadAloudTimerMode.chapter) {
      final chapters = normalizeReadAloudTimerChapters(_chapters.round());
      unawaited(ReadAloudTimerSettings.saveMode(ReadAloudTimerMode.chapter));
      unawaited(ReadAloudTimerSettings.saveChapters(chapters));
      if (chapters <= 0) {
        notifier.cancelSleepTimer();
      } else {
        notifier.startChapterStop(chapters);
      }
    } else {
      final minutes = normalizeReadAloudTimerMinutes(_minutes.round());
      unawaited(ReadAloudTimerSettings.saveMode(ReadAloudTimerMode.minute));
      unawaited(ReadAloudTimerSettings.saveMinutes(minutes));
      notifier.setFinishCurrentChapterAfterTimer(_finishChapter);
      if (minutes <= 0) {
        notifier.cancelSleepTimer();
      } else {
        notifier.startSleepTimer(minutes);
      }
    }
    Navigator.pop(context);
  }

  void _stop() {
    ref.read(audioNotifierProvider.notifier).cancelSleepTimer();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notifier = ref.read(audioNotifierProvider.notifier);
    return SafeArea(
      top: true,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: notifier,
            builder: (context, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '定时停止',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TabBar(
                    controller: _tabController,
                    tabs: const [
                      Tab(text: '分钟'),
                      Tab(text: '章节'),
                    ],
                  ),
                  if (notifier.isSleepTimerActive)
                    _buildActiveStatus(context, notifier),
                  const SizedBox(height: 8),
                  if (_mode == ReadAloudTimerMode.minute)
                    _buildMinutePanel(context)
                  else
                    _buildChapterPanel(context),
                  const Divider(height: 24),
                  _buildActions(context, notifier),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 运行中剩余量（分钟倒计时 / 按章剩余 / 读完本章后停止）
  Widget _buildActiveStatus(BuildContext context, AudioNotifier notifier) {
    final theme = Theme.of(context);
    final text = switch (notifier.sleepTimerMode) {
      SleepTimerMode.duration =>
        '剩余 ${_formatCountdown(notifier.sleepRemainingSeconds)}',
      SleepTimerMode.chapters => '剩余 ${notifier.chaptersToStopRemaining} 章',
      SleepTimerMode.finishChapter => '读完本章后停止',
      SleepTimerMode.off => '',
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('read-aloud-timer-active-status'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.timer_outlined,
            size: 18,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMinutePanel(BuildContext context) {
    final value = _minutes.round();
    return Column(
      key: const ValueKey('read-aloud-timer-minute-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final preset in kReadAloudTimerMinutePresets)
              ChoiceChip(
                label: Text(preset == 0 ? '关闭' : '$preset 分钟'),
                selected: value == preset,
                onSelected: (_) => _selectMinutes(preset),
              ),
          ],
        ),
        Row(
          children: [
            const Text('分钟'),
            Expanded(
              child: Slider(
                key: const ValueKey('read-aloud-timer-minutes-slider'),
                value: _minutes.clamp(0, kMaxReadAloudTimerMinutes.toDouble()),
                min: 0,
                max: kMaxReadAloudTimerMinutes.toDouble(),
                divisions: kMaxReadAloudTimerMinutes,
                label: value == 0 ? '关闭' : '$value 分钟',
                onChanged: (v) => setState(() => _minutes = v),
                onChangeEnd: (v) {
                  _selectMinutes(v.round());
                },
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                value == 0 ? '关闭' : '$value 分钟',
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        SwitchListTile(
          key: const ValueKey('read-aloud-timer-finish-chapter-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('读完本章再停'),
          subtitle: const Text('到点后继续读完当前章，再在章末停止'),
          value: _finishChapter,
          onChanged: _setFinishChapter,
        ),
      ],
    );
  }

  Widget _buildChapterPanel(BuildContext context) {
    final theme = Theme.of(context);
    final value = _chapters.round();
    return Column(
      key: const ValueKey('read-aloud-timer-chapter-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final preset in kReadAloudTimerChapterPresets)
              ChoiceChip(
                label: Text(preset == 0 ? '关闭' : '$preset 章'),
                selected: value == preset,
                onSelected: (_) => _selectChapters(preset),
              ),
          ],
        ),
        Row(
          children: [
            const Text('章节'),
            Expanded(
              child: Slider(
                key: const ValueKey('read-aloud-timer-chapters-slider'),
                value: _chapters.clamp(
                  0,
                  kMaxReadAloudTimerChapters.toDouble(),
                ),
                min: 0,
                max: kMaxReadAloudTimerChapters.toDouble(),
                divisions: kMaxReadAloudTimerChapters,
                label: value == 0 ? '关闭' : '$value 章',
                onChanged: (v) => setState(() => _chapters = v),
                onChangeEnd: (v) {
                  _selectChapters(v.round());
                },
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                value == 0 ? '关闭' : '$value 章',
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '章节模式会在读完设定章数后的章末停止，无需「读完本章再停」。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildActions(BuildContext context, AudioNotifier notifier) {
    final isOff = _mode == ReadAloudTimerMode.minute
        ? _minutes.round() <= 0
        : _chapters.round() <= 0;
    // 窄屏/大字体下按钮自动换行，避免 Row 溢出
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (notifier.isSleepTimerActive)
          TextButton(
            key: const ValueKey('read-aloud-timer-stop-button'),
            onPressed: _stop,
            child: const Text('停止定时'),
          ),
        FilledButton(
          key: const ValueKey('read-aloud-timer-start-button'),
          onPressed: _start,
          child: Text(isOff ? '关闭定时' : '开始'),
        ),
      ],
    );
  }

  String _formatCountdown(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
