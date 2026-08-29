import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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
    // [MD3 验收矩阵修复] 内容超高（1.6x 字体缩放 + 长错误信息）时滚动，
    // 常规高度下保持居中——md3_acceptance_matrix_test 抓获 321px 溢出
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.error_rounded, size: 64, color: colorScheme.error),
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
                        icon: const Icon(Symbols.refresh_rounded),
                        label: const Text('重试'),
                      ),
                    ],
                    if (onSecondaryAction != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: onSecondaryAction,
                        icon: Icon(secondaryActionIcon ?? Symbols.swap_horiz_rounded),
                        label: Text(secondaryActionLabel ?? '换源'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
