import 'package:flutter/material.dart';

/// 通用底部弹窗 — 带标题的底部弹窗
class AppBottomSheet extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  const AppBottomSheet({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // [UI_SYNC_REFACTOR S5] 标题栏（titleMedium+Medium 强调，对齐参考
          // AppModalBottomSheet titleMediumEmphasized；把手由主题
          // showDragHandle 统一提供，消双把手；标题下无分隔线）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                // ignore: use_null_aware_elements
                if (trailing != null) trailing!,
              ],
            ),
          ),
          // 内容
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 显示底部弹窗的便捷方法
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required List<Widget> children,
    Widget? trailing,
    bool isScrollControlled = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      // [LAYOUT_PLAN P4] 对话框 Sheet 半径对齐 Expressive 28dp（原 16dp）。
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => AppBottomSheet(
        title: title,
        trailing: trailing,
        children: children,
      ),
    );
  }
}
