import 'dart:async';

import 'package:flutter/material.dart';

/// MD3 垂直快速滚动条（对齐参考仓 VerticalFastScroller：长列表右侧拖拽快速定位）
///
/// 包裹任意可滚动子组件：右侧显示拖拽滑块，位置/高度按滚动比例同步；
/// 拖拽滑块线性映射到滚动偏移。列表内容不足一屏时自动隐藏。
/// [UI_SYNC_REFACTOR R2] 滑块形态对齐参考仓：idle 36dp×4dp outlineVariant@0.8
/// → 激活（拖拽/滚动中）48dp×12dp primary，AnimatedContainer 250ms 形变，
/// 滚动停止 3s 后保持激活渐隐 250ms（对齐 IdleThumbAlpha 0.8/激活保持语义）。
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
  // [UI_SYNC_REFACTOR R2] 激活保持 3s + 渐隐 250ms（对齐参考仓常量）
  static const _activeHold = Duration(seconds: 3);
  static const _fade = Duration(milliseconds: 250);
  Timer? _holdTimer;
  bool _active = false;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _markActive() {
    _holdTimer?.cancel();
    if (!_active) setState(() => _active = true);
    _holdTimer = Timer(_activeHold, () {
      if (mounted && !_dragging) setState(() => _active = false);
    });
  }

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
              right: _active ? 2 : 5,
              top: 0,
              bottom: 0,
              width: 16,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) {
                  setState(() => _dragging = true);
                  _markActive();
                },
                onVerticalDragUpdate: (details) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null || !box.hasSize) return;
                  final track = box.size.height - 16 - thumbHeight;
                  final y = (details.localPosition.dy - 8 - thumbHeight / 2)
                      .clamp(0.0, track);
                  widget.controller.jumpTo(
                    position.maxScrollExtent * (y / (track == 0 ? 1 : track)),
                  );
                  _markActive();
                },
                onVerticalDragEnd: (_) {
                  setState(() => _dragging = false);
                  _markActive();
                },
                onVerticalDragCancel: () {
                  setState(() => _dragging = false);
                  _markActive();
                },
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(top: thumbTop),
                    child: AnimatedContainer(
                      duration: _fade,
                      curve: Curves.fastOutSlowIn,
                      width: _active ? 12 : 4,
                      height: _active ? thumbHeight : thumbHeight * 0.75,
                      decoration: BoxDecoration(
                        color: _active
                            ? scheme.primary
                            : scheme.outlineVariant.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(6),
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
