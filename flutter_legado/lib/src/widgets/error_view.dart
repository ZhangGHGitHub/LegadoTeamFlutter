import 'package:flutter/material.dart';

/// 错误状态组件 — 显示错误信息 + 重试按钮（可选：次要操作，如「换源」）
class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  /// 可选次要操作（对齐原版：正文/目录加载失败时引导用户「换源」）
  /// [fix Task#24 | 2026-08-08] — Qoder
  final VoidCallback? onSecondaryAction;
  final String? secondaryActionLabel;
  final IconData? secondaryActionIcon;

  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.onSecondaryAction,
    this.secondaryActionLabel,
    this.secondaryActionIcon,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: colorScheme.error),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
            if (onSecondaryAction != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onSecondaryAction,
                icon: Icon(secondaryActionIcon ?? Icons.swap_horiz),
                label: Text(secondaryActionLabel ?? '换源'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
