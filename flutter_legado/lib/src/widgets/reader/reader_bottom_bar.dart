import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../providers/audio/audio_notifier.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../services/system_brightness.dart';

/// 阅读器底部工具栏
///
/// 对齐安卓原版 ReadMenu 底部栏（view_read_menu.xml）：
/// 亮度行（自动亮度+亮度滑条）+ 上一章/章节进度条/下一章
/// + 目录/朗读/界面/设置四功能按钮
class ReaderBottomBar extends ConsumerStatefulWidget {
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAdvancedConfig;

  /// 朗读按钮回调（启动/切换朗读，由 ReaderScreen 接线到 AudioNotifier）
  final VoidCallback onReadAloud;

  const ReaderBottomBar({
    super.key,
    required this.onOpenCatalog,
    required this.onOpenSettings,
    required this.onOpenAdvancedConfig,
    required this.onReadAloud,
  });

  @override
  ConsumerState<ReaderBottomBar> createState() => _ReaderBottomBarState();
}

class _ReaderBottomBarState extends ConsumerState<ReaderBottomBar> {
  bool _brightnessSupported = false;
  bool _autoBrightness = false;
  double _brightness = 0.5;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBrightness());
  }

  Future<void> _loadBrightness() async {
    try {
      final supported = await SystemBrightness.isSupported();
      if (!supported) return;
      final isAuto = await SystemBrightness.isAutoBrightness();
      final value = await SystemBrightness.getBrightness();
      if (!mounted) return;
      setState(() {
        _brightnessSupported = true;
        _autoBrightness = isAuto;
        _brightness = value;
      });
    } catch (e) {
      // [审计修复 §4.1] 平台通道不可用时（如测试环境）静默降级隐藏亮度行，
      // debugPrint 留痕便于排障 — Qoder
      debugPrint('亮度通道不可用，隐藏亮度行: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    // [UI-fix v2.0.1 | 2026-08-06] 朗读按钮激活：当前书朗读进行中时
    // 按钮切换为实心图标高亮 — Qoder
    final audio = ref.watch(audioNotifierProvider);
    final book = state.currentBook;
    final aloudActive = book != null &&
        audio.bookUrl == book.bookUrl &&
        audio.state != PlayerState.idle;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        // iOS 风格：无阴影 + hairline 顶边
        elevation: 0,
        shape: Border(
          top: BorderSide(
            color: Theme.of(context).dividerTheme.color ??
                Theme.of(context).dividerColor,
            width: 0.0,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 亮度行（对标 ll_brightness：自动亮度 + 亮度滑条）
              if (_brightnessSupported)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _autoBrightness
                              ? Icons.brightness_auto
                              : Icons.brightness_auto_outlined,
                        ),
                        tooltip: _autoBrightness ? '关闭自动亮度' : '自动亮度',
                        onPressed: () async {
                          await SystemBrightness.setAutoBrightness(
                              !_autoBrightness);
                          await _loadBrightness();
                        },
                      ),
                      Expanded(
                        child: Slider(
                          value: _brightness,
                          onChanged: _autoBrightness
                              ? null
                              : (v) {
                                  setState(() => _brightness = v);
                                  unawaited(SystemBrightness.setBrightness(v));
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              // 进度条（对标 tv_pre + seek_read_page + tv_next）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: state.hasPreviousChapter
                          ? () => notifier.prevChapter()
                          : null,
                      child: Text(AppStrings.previousChapter),
                    ),
                    Expanded(
                      child: Slider(
                        value: state.chapters.isNotEmpty
                            ? state.currentChapterIndex.toDouble()
                            : 0,
                        min: 0,
                        max: state.chapters.length > 1
                            ? (state.chapters.length - 1).toDouble()
                            : 1,
                        divisions: state.chapters.length > 1
                            ? state.chapters.length - 1
                            : null,
                        onChanged: (value) {
                          notifier.goToChapter(value.toInt());
                        },
                      ),
                    ),
                    TextButton(
                      onPressed: state.hasNextChapter
                          ? () => notifier.nextChapter()
                          : null,
                      child: Text(AppStrings.nextChapter),
                    ),
                  ],
                ),
              ),
              // 功能按钮（对标 ll_catalog/ll_read_aloud/ll_font/ll_setting）
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildBottomAction(
                    context,
                    Icons.toc,
                    AppStrings.catalog,
                    widget.onOpenCatalog,
                  ),
                  _buildBottomAction(
                    context,
                    // 对标 ll_read_aloud：启动朗读当前章（进行中时点击为播放/暂停切换）
                    aloudActive
                        ? Icons.record_voice_over
                        : Icons.record_voice_over_outlined,
                    AppStrings.readAloud,
                    widget.onReadAloud,
                    highlighted: aloudActive,
                  ),
                  _buildBottomAction(
                    context,
                    Icons.palette_outlined,
                    AppStrings.interfaceSetting,
                    widget.onOpenSettings,
                  ),
                  _buildBottomAction(
                    context,
                    Icons.settings,
                    AppStrings.settings,
                    // 对标 ll_setting：打开更多/高级设置面板
                    widget.onOpenAdvancedConfig,
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool highlighted = false,
  }) {
    final highlightColor = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 22,
              color: highlighted ? highlightColor : null,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: highlighted ? highlightColor : null,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
