/// 发现分类列表页码控件（对标 Android ExploreShowActivity menuPage）
///
/// iOS 风格：中性灰文案 + Cupertino 滚轮选页，无系统蓝强调。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/explore/explore_show_notifier.dart';

/// 发现分类页码按钮（AppBar actions 或双栏右栏顶栏）
class ExplorePageControl extends ConsumerWidget {
  final ExploreShowArgs args;

  /// 最大可选页码（对标原版 NumberPicker maxValue=999）
  final int maxPage;

  const ExplorePageControl({
    super.key,
    required this.args,
    this.maxPage = 999,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(exploreShowNotifierProvider(args));
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final pageLabel = state.displayPage > 0 ? state.displayPage : 1;

    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      minimumSize: const Size(0, 36),
      onPressed: state.isLoading
          ? null
          : () => _showPagePicker(context, ref, pageLabel, colorScheme, theme),
      child: Text(
        '第 $pageLabel 页',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Future<void> _showPagePicker(
    BuildContext context,
    WidgetRef ref,
    int currentPage,
    ColorScheme colorScheme,
    ThemeData theme,
  ) async {
    var picked = currentPage.clamp(1, maxPage);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) {
        return Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Row(
                      children: [
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          onPressed: () => Navigator.pop(sheetContext),
                          child: Text(
                            '取消',
                            style: TextStyle(color: colorScheme.onSurface),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '选择页码',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            ref
                                .read(
                                    exploreShowNotifierProvider(args).notifier)
                                .skipToPage(picked);
                          },
                          child: Text(
                            '确定',
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 216,
                    child: CupertinoPicker(
                      scrollController: FixedExtentScrollController(
                        initialItem: picked - 1,
                      ),
                      itemExtent: 36,
                      onSelectedItemChanged: (index) => picked = index + 1,
                      children: List.generate(
                        maxPage,
                        (i) => Center(
                          child: Text(
                            '第 ${i + 1} 页',
                            style: theme.textTheme.bodyLarge,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
