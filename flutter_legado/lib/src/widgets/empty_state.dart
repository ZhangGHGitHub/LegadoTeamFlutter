import 'dart:math';

import 'package:flutter/material.dart';

import 'contained_loading_indicator.dart';
import 'md3_animated_text_line.dart';

/// 空状态组件
///
/// 支持三种模式：
/// - [simple] = true：安卓原版范式，纯居中灰字（无图标、无副标题）
/// - [simple] = false（默认）：图标 + 提示文字 + 可选操作按钮
/// - [kaomoji] = true：颜文字彩蛋（用户授权新增，AGENTS 红线 2026-08-29
///   口径）——对齐参考仓库 EmptyMessage：32sp 随机颜文字，点击换一个，
///   提示文字随变化翻滚（Md3AnimatedTextLine）
class EmptyState extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  /// 安卓原版空状态范式：纯居中灰字，无图标无副标题
  final bool simple;

  /// 颜文字彩蛋模式（点击切换颜文字；对齐参考仓库 EmptyMessage）
  final bool kaomoji;

  /// 加载中时显示 Contained 指示器代替空态（对齐 HapeLee EmptyMessage
  /// isLoading 分支，M2）
  final bool isLoading;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.simple = false,
    this.kaomoji = false,
    this.isLoading = false,
  });

  @override
  State<EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<EmptyState> {
  /// 颜文字池（参考仓库 EmptyMessage 默认集）
  static const _faces = [
    '(；′⌒`)',
    '(つ﹏⊂)',
    '(•̀ᴗ•́)و',
    '(๑•́ ₃ •̀๑)',
    '(눈‸눈)',
    '(ಥ﹏ಥ)',
    '(｡•́︿•̀｡)',
  ];

  late String _face =
      _faces[Random().nextInt(_faces.length)];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // 加载中：Contained 指示器（HapeLee isLoading 分支）
    if (widget.isLoading) {
      return const Center(child: ContainedLoadingIndicator());
    }

    // 安卓原版范式：纯居中灰字（对标 Android 空状态 TextView）
    if (widget.simple) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            widget.title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
          ),
        ),
      );
    }

    // 颜文字彩蛋模式（用户授权）：点击换颜文字 + 提示文字翻滚
    // [LAYOUT_MOTION_AUDIT M2] message 约束最大宽 240dp（HapeLee widthIn）
    if (widget.kaomoji) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() {
                    // 池内随机换一个（与当前不同）
                    var next = _face;
                    while (next == _face) {
                      next = _faces[Random().nextInt(_faces.length)];
                    }
                    _face = next;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Md3AnimatedTextLine(
                      text: _face,
                      style: TextStyle(
                        fontSize: 32,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Md3AnimatedTextLine(
                  text: widget.title,
                  maxLines: 2,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                ),
                if (widget.subtitle != null) ...[
                  Text(
                    widget.subtitle!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                  ),
                ],
                if (widget.action != null) ...[
                  widget.action!,
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.icon,
              size: 80,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
              ),
            ],
            if (widget.action != null) ...[
              const SizedBox(height: 24),
              widget.action!,
            ],
          ],
        ),
      ),
    );
  }
}
