import 'package:flutter/material.dart';

import 'md3_loading_indicator.dart';

/// 全局加载遮罩 — 覆盖在内容上的加载指示器
///
/// [MD3 Expressive] 遮罩走 onSurface 24% + surfaceContainer 模糊等效层，
/// 指示器为波浪加载环（与 LoadingIndicator 同一签名）。
class LoadingOverlay extends StatelessWidget {
  final bool isLoading;
  final Widget child;
  final String? message;

  const LoadingOverlay({
    super.key,
    required this.isLoading,
    required this.child,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        child,
        if (isLoading)
          Positioned.fill(
            child: ColoredBox(
              color: colorScheme.onSurface.withValues(alpha: 0.24),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Md3LoadingIndicator(color: colorScheme.primary),
                      if (message != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          message!,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
