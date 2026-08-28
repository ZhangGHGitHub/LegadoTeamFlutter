import 'package:flutter/material.dart';

/// MD3 动画文本行（对齐参考仓库 legado-with-MD3 的 AnimatedTextLine：
/// 文本变化时旧文本向上滑出、新文本自下滑入的翻滚效果，无淡入淡出）
///
/// 典型用途：搜索结果行的来源数角标——聚合搜索流式返回时，同一本书
/// 每被一个新源命中，数字即向上翻滚 +1。
class Md3AnimatedTextLine extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Duration duration;
  final int maxLines;

  const Md3AnimatedTextLine({
    super.key,
    required this.text,
    this.style,
    this.duration = const Duration(milliseconds: 200),
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          // 当前文本自下滑入，旧文本向上滑出（对齐参考 transitionSpec）
          final isIncoming = child.key == ValueKey<String>(text);
          final slide = Tween<Offset>(
            begin: Offset(0, isIncoming ? 1 : -1),
            end: Offset.zero,
          ).animate(animation);
          return SlideTransition(position: slide, child: child);
        },
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.centerLeft,
          children: [
            ...previousChildren,
            ?currentChild,
          ],
        ),
        child: Text(
          text,
          key: ValueKey<String>(text),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}
