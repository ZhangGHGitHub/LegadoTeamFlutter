import 'package:flutter/material.dart';

/// M3 骨架占位（对齐 HapeLee SkeletonPlaceholders）
///
/// shimmer：1200ms LinearEasing 无限循环，色 surfaceContainerHighest→High，
/// 线性渐变扫过；默认圆角 8dp。
class SkeletonBox extends StatefulWidget {
  final double? width;
  final double? height;
  final double borderRadius;

  const SkeletonBox({
    super.key,
    this.width,
    this.height,
    this.borderRadius = 8,
  });

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            gradient: LinearGradient(
              begin: Alignment(-1 + _controller.value * 2, 0),
              end: Alignment(1 + _controller.value * 2, 0),
              colors: [
                cs.surfaceContainerHighest,
                cs.surfaceContainerHigh,
                cs.surfaceContainerHighest,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 书架网格骨架项（封面铺满可用高度 + 文两行）
///
/// [设置批6a-1] 书架网格 cell 高随列数/封面宽/书名行数变化，骨架改为
/// 自适应：封面区 Expanded 填充剩余高度，底部两行文字固定约 48dp，
/// 任意 cell 高（360dp 三列 ≈193dp / 横屏七列 ≈207dp）不溢出。
class GridSkeletonItem extends StatelessWidget {
  /// 是否渲染底部书名骨架（网格样式 1 紧凑/2 仅封面不需要）
  final bool showText;

  const GridSkeletonItem({super.key, this.showText = true});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Expanded(
            child: SkeletonBox(borderRadius: 16),
          ),
          if (showText)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 14),
                  SizedBox(height: 4),
                  FractionallySizedBox(
                    widthFactor: 0.8,
                    child: SkeletonBox(height: 14),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 列表骨架项（行高 72 + 圆角 8）
class ListSkeletonItem extends StatelessWidget {
  const ListSkeletonItem({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          SkeletonBox(width: 45, height: 60),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 16),
                SizedBox(height: 6),
                FractionallySizedBox(
                  widthFactor: 0.6,
                  child: SkeletonBox(height: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
