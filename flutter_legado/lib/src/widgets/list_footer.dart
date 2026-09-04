import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import 'contained_loading_indicator.dart';

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
/// [LAYOUT_PLAN P4 收尾] loading 态走 Contained 指示器（对齐 HapeLee LoadMoreFooter）
class ListLoadMoreFooter extends StatelessWidget {
  const ListLoadMoreFooter({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(child: ContainedLoadingIndicator()),
    );
  }
}

/// 列表底部三态 footer（对齐 HapeLee LoadMoreFooter）
///
/// loading：指示器 + 加载中（bodySmall outline）；
/// error：errorContainer 卡 + 重试；
/// end：surfaceContainer 卡（复用 ListBottomLineFooter 文案）。
/// [LAYOUT_MOTION_AUDIT M2] 新增。
enum ListFooterState { loading, error, end }

class ListMoreFooter extends StatelessWidget {
  final ListFooterState state;
  final String? loadingText;
  final VoidCallback? onRetry;

  const ListMoreFooter({
    super.key,
    required this.state,
    this.loadingText,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    switch (state) {
      case ListFooterState.loading:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Column(
              children: [
                // [LAYOUT_PLAN P4 收尾] footer loading 态走 Contained 指示器
                const ContainedLoadingIndicator(),
                const SizedBox(height: 12),
                Text(
                  loadingText ?? AppStrings.loading,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.outline,
                  ),
                ),
              ],
            ),
          ),
        );
      case ListFooterState.error:
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.errorContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, color: cs.error),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppStrings.loadFailed,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onErrorContainer,
                    ),
                  ),
                ),
                if (onRetry != null)
                  TextButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ),
        );
      case ListFooterState.end:
        return const ListBottomLineFooter();
    }
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
