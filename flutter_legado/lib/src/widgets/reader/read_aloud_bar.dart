import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/audio/audio_notifier.dart';
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
/// - iv_play_prev / iv_play_next（上一段/下一段）→ UI 呈现，禁用待批次2
///   （段落级定位依赖真实 TTS 播放进度，Rust audioSpeak 缺口②）
/// - ivTimer / SleepTimerDialog（定时停止）→ 留批次2（听书页已有定时实现可复用）
/// - ll_catalog / ll_setting / ll_to_backstage（目录/朗读设置/转后台）→ 已实现
class ReadAloudBar extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(audioNotifierProvider);
    final notifier = ref.read(audioNotifierProvider.notifier);
    final theme = Theme.of(context);

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
              _buildHeader(context, audio, theme),
              _buildTransport(context, audio, notifier, theme),
              _buildSpeedRow(context, audio, notifier),
              _buildBottomActions(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 第一行：朗读状态 + 章节信息 + 收起按钮
  Widget _buildHeader(BuildContext context, AudioState audio, ThemeData theme) {
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
          IconButton(
            icon: const Icon(Icons.expand_more),
            tooltip: '收起朗读面板',
            onPressed: onDismiss,
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
          // [UI-fix v2.0.1 | 2026-08-06] 段落级切换依赖真实 TTS 播放进度，
          // UI 先行呈现并禁用，待批次2（Rust audioSpeak 缺口②）接线 — Qoder
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一段（待批次2：真实 TTS 进度）',
            onPressed: null,
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
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一段（待批次2：真实 TTS 进度）',
            onPressed: null,
          ),
          TextButton(
            onPressed: audio.hasNext ? notifier.next : null,
            child: const Text('下一章'),
          ),
        ],
      ),
    );
  }

  /// 第三行：停止 + 语速（对标 iv_stop + seekTtsSpeechRate）
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
              onDismiss();
            },
          ),
          const SizedBox(width: 8),
          const Text('语速'),
          Expanded(
            child: Slider(
              value: audio.config.speed,
              min: 0.5,
              max: 3.0,
              divisions: 25,
              label: '${audio.config.speed.toStringAsFixed(1)}x',
              onChanged: (v) => notifier.updateConfig(speed: v),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text('${audio.config.speed.toStringAsFixed(1)}x'),
          ),
        ],
      ),
    );
  }

  /// 第四行：目录/朗读设置/转后台（对标 ll_catalog/ll_setting/ll_to_backstage）
  Widget _buildBottomActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.toc, size: 18),
            label: const Text('目录'),
            onPressed: onOpenCatalog,
          ),
          TextButton.icon(
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('朗读设置'),
            onPressed: () =>
                Navigator.pushNamed(context, AppRoutes.readAloudConfig),
          ),
          TextButton.icon(
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('转后台'),
            onPressed: onBackstage,
          ),
        ],
      ),
    );
  }

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
