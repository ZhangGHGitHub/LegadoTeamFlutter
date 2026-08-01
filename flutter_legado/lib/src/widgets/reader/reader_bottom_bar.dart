import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../providers/reader/reader_notifier.dart';

/// 阅读器底部工具栏
///
/// 对齐安卓原版 ReadMenu 底部栏：
/// 上一章/章节进度条/下一章 + 目录/设置/夜间模式功能按钮
class ReaderBottomBar extends ConsumerWidget {
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenSettings;

  const ReaderBottomBar({
    super.key,
    required this.onOpenCatalog,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final isDark = state.isDarkBackground;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 4,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: state.hasPreviousChapter
                          ? () => notifier.prevChapter()
                          : null,
                      tooltip: AppStrings.previousChapter,
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
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: state.hasNextChapter
                          ? () => notifier.nextChapter()
                          : null,
                      tooltip: AppStrings.nextChapter,
                    ),
                  ],
                ),
              ),
              // 功能按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildBottomAction(
                    context,
                    Icons.format_list_numbered,
                    AppStrings.catalog,
                    onOpenCatalog,
                  ),
                  _buildBottomAction(
                    context,
                    Icons.settings,
                    AppStrings.settings,
                    onOpenSettings,
                  ),
                  _buildBottomAction(
                    context,
                    Icons.brightness_6,
                    AppStrings.nightMode,
                    () {
                      notifier.updateBackgroundColor(
                        isDark ? ReaderBackground.white : ReaderBackground.dark,
                      );
                    },
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
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 2),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
