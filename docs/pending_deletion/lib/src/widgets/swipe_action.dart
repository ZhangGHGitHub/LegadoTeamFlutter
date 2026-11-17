import 'package:flutter/material.dart';

/// 滑动操作按钮项
class SwipeActionItem {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const SwipeActionItem({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

/// 滑动操作组件 — 列表项滑动显示操作按钮
class SwipeAction extends StatefulWidget {
  final Widget child;
  final List<SwipeActionItem> actions;

  const SwipeAction({
    super.key,
    required this.child,
    required this.actions,
  });

  @override
  State<SwipeAction> createState() => _SwipeActionState();
}

class _SwipeActionState extends State<SwipeAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _offsetAnimation;
  double _dragExtent = 0;
  bool _isOpen = false;

  static const double _actionWidth = 80.0;

  double get _maxDragExtent => widget.actions.length * _actionWidth;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _offsetAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragExtent += details.delta.dx;
    _dragExtent = _dragExtent.clamp(-_maxDragExtent, 0);
    final offset = Offset(_dragExtent / _maxDragExtent, 0);
    setState(() {
      _offsetAnimation = Tween<Offset>(
        begin: offset,
        end: offset,
      ).animate(_controller);
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    final threshold = -_maxDragExtent * 0.4;
    setState(() {
      _isOpen = _dragExtent < threshold;
      final targetOffset = _isOpen ? -1.0 : 0.0;
      _offsetAnimation = Tween<Offset>(
        begin: Offset(_dragExtent / _maxDragExtent, 0),
        end: Offset(targetOffset, 0),
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
      _controller.forward(from: 0);
      _dragExtent = _isOpen ? -_maxDragExtent : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      child: Stack(
        children: [
          // 操作按钮背景
          Positioned.fill(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: widget.actions.map((action) {
                return SizedBox(
                  width: _actionWidth,
                  child: Material(
                    color: action.color,
                    child: InkWell(
                      onTap: () {
                        action.onTap();
                        _close();
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(action.icon, color: Colors.white, size: 22),
                          const SizedBox(height: 4),
                          Text(
                            action.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // 前景内容
          AnimatedBuilder(
            animation: _offsetAnimation,
            builder: (context, child) {
              return FractionalTranslation(
                translation: _offsetAnimation.value,
                child: child,
              );
            },
            child: widget.child,
          ),
        ],
      ),
    );
  }

  void _close() {
    setState(() {
      _isOpen = false;
      _offsetAnimation = Tween<Offset>(
        begin: Offset(_dragExtent / _maxDragExtent, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
      _controller.forward(from: 0);
      _dragExtent = 0;
    });
  }
}
