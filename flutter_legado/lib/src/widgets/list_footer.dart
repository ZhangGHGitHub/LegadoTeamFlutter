import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// 列表底部「我是有底线的」提示（对标 Android LoadMoreView.noMore）
class ListBottomLineFooter extends StatelessWidget {
  /// 自定义文案；默认对齐原版 R.string.bottom_line
  final String? message;

  const ListBottomLineFooter({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          message ?? AppStrings.bottomLine,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }
}

/// 列表底部加载中指示器（对标 Android LoadMoreView.startLoad）
class ListLoadMoreFooter extends StatelessWidget {
  const ListLoadMoreFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

/// 顶栏 indeterminate 加载条（对标 Android RefreshProgressBar / SwipeRefresh）
class TopNetworkLoadingBar extends StatelessWidget {
  final bool isLoading;

  const TopNetworkLoadingBar({super.key, required this.isLoading});

  @override
  Widget build(BuildContext context) {
    if (!isLoading) return const SizedBox.shrink();
    return const LinearProgressIndicator(minHeight: 2);
  }
}
