import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../providers/reader/reader_notifier.dart';
import '../ios_widgets.dart';

/// 阅读设置底部弹出面板
///
/// 对齐安卓原版 ReadStyleDialog / BgTextConfigDialog：
/// 字体大小 / 行距 / 背景色 / 翻页模式
class ReaderSettingsSheet extends ConsumerWidget {
  const ReaderSettingsSheet({super.key});

  /// 便捷弹出方法
  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // iOS sheet 顶部短横条
            const Center(child: IosGrabber()),
            const SizedBox(height: 12),
            Text(AppStrings.readingSettingsTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),

            // 字体大小
            Text(AppStrings.fontSizeLabel,
                style: Theme.of(context).textTheme.bodyMedium),
            Row(
              children: [
                Text(AppStrings.fontSmall,
                    style: const TextStyle(fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: state.fontSize,
                    min: 12,
                    max: 32,
                    divisions: 20,
                    label: state.fontSize.round().toString(),
                    onChanged: (v) => notifier.updateFontSize(v),
                  ),
                ),
                Text(AppStrings.fontLarge,
                    style: const TextStyle(fontSize: 20)),
              ],
            ),

            // 行距
            Text(AppStrings.lineHeightLabel,
                style: Theme.of(context).textTheme.bodyMedium),
            Row(
              children: [
                for (final value in [1.2, 1.6, 2.0, 2.5])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('${value}x'),
                      selected: state.lineHeight == value,
                      onSelected: (_) => notifier.updateLineHeight(value),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // 背景色
            Text(AppStrings.bgColor,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Row(
              children: List.generate(ReaderBackground.presets.length, (i) {
                final color = ReaderBackground.presets[i];
                final label = ReaderBackground.labels[i];
                final isSelected = state.backgroundColor == color;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () => notifier.updateBackgroundColor(color),
                    child: Column(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outlineVariant,
                              width: isSelected ? 3 : 1,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(label,
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),

            // 翻页模式
            Text(AppStrings.flipModeLabel,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(AppStrings.coverMode),
                  selected: state.pageTurnMode == PageTurnMode.cover,
                  onSelected: (_) =>
                      notifier.updatePageTurnMode(PageTurnMode.cover),
                ),
                ChoiceChip(
                  label: Text(AppStrings.slideMode),
                  selected: state.pageTurnMode == PageTurnMode.slide,
                  onSelected: (_) =>
                      notifier.updatePageTurnMode(PageTurnMode.slide),
                ),
                ChoiceChip(
                  label: Text(AppStrings.simulateMode),
                  selected: state.pageTurnMode == PageTurnMode.simulate,
                  onSelected: (_) =>
                      notifier.updatePageTurnMode(PageTurnMode.simulate),
                ),
                ChoiceChip(
                  label: Text(AppStrings.scrollMode),
                  selected: state.pageTurnMode == PageTurnMode.scroll,
                  onSelected: (_) =>
                      notifier.updatePageTurnMode(PageTurnMode.scroll),
                ),
                ChoiceChip(
                  label: Text(AppStrings.noneMode),
                  selected: state.pageTurnMode == PageTurnMode.none,
                  onSelected: (_) =>
                      notifier.updatePageTurnMode(PageTurnMode.none),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
