/// 发现分类列表页码控件（对标 Android ExploreShowActivity menuPage）
///
/// [MD3 全量清点] 原 CupertinoButton + CupertinoPicker 弹层 → M3 TextButton
/// + showMd3WheelPickerSheet（ListWheelScrollView 轮式选择，M3 底部弹层外壳）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/explore/explore_show_notifier.dart';
import 'md3_picker_sheet.dart';

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
    final pageLabel = state.displayPage > 0 ? state.displayPage : 1;

    return TextButton(
      onPressed: state.isLoading
          ? null
          : () => _showPagePicker(context, ref, pageLabel),
      child: Text(
        '第 $pageLabel 页',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Future<void> _showPagePicker(
    BuildContext context,
    WidgetRef ref,
    int currentPage,
  ) async {
    final picked = await showMd3WheelPickerSheet(
      context: context,
      title: '选择页码',
      itemCount: maxPage,
      initialIndex: currentPage.clamp(1, maxPage) - 1,
      itemBuilder: (ctx, i) => Text(
        '第 ${i + 1} 页',
        style: Theme.of(ctx).textTheme.bodyLarge,
      ),
    );
    if (picked == null) return;
    ref.read(exploreShowNotifierProvider(args).notifier).skipToPage(picked + 1);
  }
}
