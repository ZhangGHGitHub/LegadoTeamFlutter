import 'package:flutter/material.dart';

/// MD3 垂直快速滚动条（对齐原版 FastScroller：长列表右侧拖拽快速定位）
///
/// 包裹任意可滚动子组件：右侧显示拖拽滑块，位置/高度按滚动比例同步；
/// 拖拽滑块线性映射到滚动偏移。列表内容不足一屏时自动隐藏。
/// 滑块样式：4dp 圆条（拖拽时 8dp、primary 色）。
class Md3FastScroller extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  const Md3FastScroller({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  State<Md3FastScroller> createState() => _Md3FastScrollerState();
}

class _Md3FastScrollerState extends State<Md3FastScroller> {
  bool _dragging = false;

  bool get _scrollable =>
      widget.controller.hasClients &&
      // 布局完成前维度未就绪，直接访问 maxScrollExtent 会触发空断言
      widget.controller.position.hasContentDimensions &&
      widget.controller.position.hasViewportDimension &&
      widget.controller.position.maxScrollExtent > 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        widget.child,
        // 滑块层：仅在可滚动时叠加
        AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            if (!_scrollable) return const SizedBox.shrink();
            final position = widget.controller.position;
            final viewport = position.viewportDimension;
            final trackHeight = viewport - 16;
            final thumbHeight = (viewport * viewport /
                    (position.maxScrollExtent + viewport))
                .clamp(48.0, trackHeight);
            final fraction =
                (position.pixels / position.maxScrollExtent).clamp(0.0, 1.0);
            final thumbTop = 8 + fraction * (trackHeight - thumbHeight);

            return Positioned(
              right: _dragging ? 2 : 3,
              top: 0,
              bottom: 0,
              width: 12,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) => setState(() => _dragging = true),
                onVerticalDragUpdate: (details) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null || !box.hasSize) return;
                  final track = box.size.height - 16 - thumbHeight;
                  final y = (details.localPosition.dy - 8 - thumbHeight / 2)
                      .clamp(0.0, track);
                  widget.controller.jumpTo(
                    position.maxScrollExtent * (y / (track == 0 ? 1 : track)),
                  );
                },
                onVerticalDragEnd: (_) => setState(() => _dragging = false),
                onVerticalDragCancel: () =>
                    setState(() => _dragging = false),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(top: thumbTop),
                    child: Container(
                      width: _dragging ? 8 : 4,
                      height: thumbHeight,
                      decoration: BoxDecoration(
                        color: _dragging
                            ? scheme.primary
                            : scheme.onSurfaceVariant.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
