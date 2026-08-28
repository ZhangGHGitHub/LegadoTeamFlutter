import 'package:flutter/material.dart';

import 'md3_loading_indicator.dart';

/// 居中加载动画组件
///
/// [MD3 Expressive] 使用波浪加载指示器（参考 Compose Material3 Expressive
/// 的 LoadingIndicator 签名），页面级加载统一入口；减少动画系统偏好下
/// 自动退化为静态弧。
class LoadingIndicator extends StatelessWidget {
  final String? message;

  const LoadingIndicator({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Md3LoadingIndicator(color: colorScheme.primary),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(
              message!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}
