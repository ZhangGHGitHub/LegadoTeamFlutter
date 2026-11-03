import 'dart:async';

import 'package:flutter/material.dart';

/// MD3 垂直快速滚动条（对齐参考仓 VerticalFastScroller：长列表右侧拖拽快速定位）
///
/// 包裹任意可滚动子组件：右侧显示拖拽滑块，位置/高度按滚动比例同步；
/// 拖拽滑块线性映射到滚动偏移。列表内容不足一屏时自动隐藏。
/// [UI_SYNC_REFACTOR R2] 滑块形态对齐参考仓：idle 36dp×4dp outlineVariant@0.8
/// → 激活（拖拽/滚动中）48dp×12dp primary，AnimatedContainer 250ms 形变，
/// 滚动停止 3s 后保持激活渐隐 250ms（对齐 IdleThumbAlpha 0.8/激活保持语义）。
///
/// [2b-2c 复核] 防御 `ScrollController` 多 position：
/// 同一个 controller 可能短暂挂两个 ScrollPosition（如「源列表 + 内容」
/// 双栏在宽度变化时切换父子结构，旧 Scrollable 在帧末才 unmount，而新
/// Scrollable 同帧 attach）。`ScrollController.position` 在多 position 时
/// 直接断言（设备验收 `Bad state: Too many elements`），故本组件一律经
/// [positions] 选择**本组件子树内**的 position；无法判定时退化到首个
/// 视口就绪的垂直 position，避免崩溃。拖拽 jump 复用同一 position。
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

  /// 子组件子树锚点：用于在多 position 时定位「本组件自己的」Scrollable。
  final GlobalKey _childKey = GlobalKey();

  /// 缓存的本子树 position（帧末解析；build 期间禁止 visitChildElements）
  ScrollPosition? _ownPosition;

  /// 是否已调度帧末位置刷新
  bool _positionRefreshScheduled = false;

  /// 首帧布局后补一次 rebuild（首帧 build 时无 viewport 尺寸，滑块需在
  /// 布局完成后才能按比例显示；controller 布局阶段不会通知监听者）。
  bool _layoutRefreshScheduled = false;

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

  /// 本组件子树内、且挂在该 controller 上的第一个 Scrollable position。
  ///
  /// 布局切换过渡帧里旧 position 仍在 controller.positions 中，但不在本
  /// 子树内；按子树定位可避免把滑块映射到即将销毁的旧列表。
  ScrollPosition? _subtreePosition() {
    final root = _childKey.currentContext;
    if (root is! Element) return null;
    ScrollPosition? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (widget.controller.positions.contains(position)) {
          found = position;
          return;
        }
      }
      element.visitChildElements(visit);
    }

    visit(root);
    return found;
  }

  /// 帧末解析本子树 position（build 期间调用 visitChildElements 会被断言）
  void _scheduleOwnPositionRefresh() {
    if (_positionRefreshScheduled) return;
    _positionRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _positionRefreshScheduled = false;
      if (!mounted) return;
      final own = _subtreePosition();
      if (own != null && own != _ownPosition) {
        setState(() => _ownPosition = own);
      }
    });
  }

  /// 当前用于滑块/拖拽的 position（多 position 时选本子树内的一个）。
  ///
  /// 顺序：缓存的子树 position（帧末解析）→ 唯一 position → 多 position
  /// 过渡帧取最后 attach 的一个（新树；旧 Scrollable 帧末才 unmount）。
  /// 全程不调用 [ScrollController.position]，避免多 position 断言。
  ScrollPosition? _resolvePosition() {
    final positions = widget.controller.positions;
    final cached = _ownPosition;
    if (cached != null && positions.contains(cached)) return cached;
    if (positions.isEmpty) return null;
    if (positions.length == 1) {
      _ownPosition = positions.first;
      return positions.first;
    }
    _scheduleOwnPositionRefresh();
    final list = positions.toList();
    for (final position in list.reversed) {
      if (position.axis == Axis.vertical && position.hasViewportDimension) {
        return position;
      }
    }
    return list.last;
  }

  /// 是否可显示滑块（列表内容超过一屏）
  bool _canScroll(ScrollPosition position) =>
      position.hasContentDimensions &&
      position.hasViewportDimension &&
      position.maxScrollExtent > 0;

  @override
  Widget build(BuildContext context) {
    if (!_layoutRefreshScheduled) {
      _layoutRefreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        KeyedSubtree(key: _childKey, child: widget.child),
        // 滑块层：仅在可滚动时叠加
        AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final position = _resolvePosition();
            if (position == null || !_canScroll(position)) {
              return const SizedBox.shrink();
            }
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
                  // 拖拽与滑块计算使用同一选中 position（不用
                  // controller.jumpTo，多 position 会断言）。
                  final target = _resolvePosition();
                  if (target == null || !_canScroll(target)) return;
                  final track = box.size.height - 16 - thumbHeight;
                  final y = (details.localPosition.dy - 8 - thumbHeight / 2)
                      .clamp(0.0, track);
                  target.jumpTo(
                    target.maxScrollExtent * (y / (track == 0 ? 1 : track)),
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
