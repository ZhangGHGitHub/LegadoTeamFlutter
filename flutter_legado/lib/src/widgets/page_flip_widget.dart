import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 仿真翻页 Widget（移植自 Kotlin SimulationPageDelegate.kt）
///
/// 核心算法：
/// - 基于手指拖拽点 (touchX, touchY) 和页脚角点 (cornerX, cornerY) 计算贝塞尔曲线
/// - 使用两条二次贝塞尔曲线构建翻页折痕
/// - 绘制当前页、下一页、翻页背面和多层阴影
///
/// 参考源码：app/src/main/java/io/legado/app/ui/book/read/page/delegate/SimulationPageDelegate.kt
class SimulationPageFlipWidget extends StatefulWidget {
  /// 当前页构建器
  final WidgetBuilder currentBuilder;

  /// 下一页构建器
  final WidgetBuilder nextBuilder;

  /// 上一页构建器
  final WidgetBuilder prevBuilder;

  /// 翻页完成回调：+1 = 下一页, -1 = 上一页
  final ValueChanged<int>? onPageTurned;

  /// 动画时长
  final Duration animDuration;

  const SimulationPageFlipWidget({
    super.key,
    required this.currentBuilder,
    required this.nextBuilder,
    required this.prevBuilder,
    this.onPageTurned,
    this.animDuration = const Duration(milliseconds: 500),
  });

  @override
  State<SimulationPageFlipWidget> createState() =>
      _SimulationPageFlipWidgetState();
}

class _SimulationPageFlipWidgetState extends State<SimulationPageFlipWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  /// 手指触摸点（不让 x,y 为 0，否则计算会有问题，同 Kotlin 版）
  double _touchX = 0.1;
  double _touchY = 0.1;

  /// 起始触摸点
  double _startX = 0;
  double _startY = 0;

  /// 拖拽点对应的页脚角坐标
  double _cornerX = 0;
  double _cornerY = 0;

  /// 是否属于右上/左下
  bool _isRtOrLb = false;

  /// 翻页方向
  _FlipDir _direction = _FlipDir.none;

  /// 是否正在拖拽
  bool _isDragging = false;

  /// 动画运行中
  bool _isAnimating = false;

  /// 取消翻页
  bool _isCancel = false;

  /// 页面尺寸
  double _viewWidth = 0;
  double _viewHeight = 0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: widget.animDuration,
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  // ─── 触摸事件 ────────────────────────────────────────────

  void _onPanStart(DragStartDetails details, BoxConstraints constraints) {
    if (_isAnimating) return; // 动画进行中不响应拖拽
    _viewWidth = constraints.maxWidth;
    _viewHeight = constraints.maxHeight;
    _startX = details.localPosition.dx;
    _startY = details.localPosition.dy;
    _touchX = _startX.clamp(0.1, _viewWidth - 0.1);
    _touchY = _startY.clamp(0.1, _viewHeight - 0.1);
    _isDragging = true;
    _isCancel = false;
    _isAnimating = false;
    _animController.stop();

    _calcCornerXY(_startX, _startY);

    // 根据起始位置判断方向
    if (_startX > _viewWidth / 2) {
      _direction = _FlipDir.prev; // 右半屏向左翻 → 上一页
    } else {
      _direction = _FlipDir.next; // 左半屏向右翻 → 下一页
    }

    setState(() {});
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    setState(() {
      _touchX = details.localPosition.dx.clamp(0.1, _viewWidth - 0.1);
      _touchY = details.localPosition.dy.clamp(0.1, _viewHeight - 0.1);

      // 同 Kotlin 版：中间区域拖拽时固定 touchY
      if ((_startY > _viewHeight / 3 && _startY < _viewHeight * 2 / 3) ||
          _direction == _FlipDir.prev) {
        _touchY = _viewHeight;
      }
      if (_startY > _viewHeight / 3 &&
          _startY < _viewHeight / 2 &&
          _direction == _FlipDir.next) {
        _touchY = 0.1;
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;
    _isAnimating = true;

    // 判断是否取消翻页
    final dx = _touchX - _startX;
    const threshold = 50.0;
    if ((_direction == _FlipDir.next && dx > -threshold) ||
        (_direction == _FlipDir.prev && dx < threshold)) {
      _isCancel = true;
    }

    _startAnimation();
  }

  void _startAnimation() {
    double targetX;
    double targetY;

    if (_isCancel) {
      // 回弹到起始位置
      targetX = _startX;
      targetY = _startY;
    } else {
      // 翻到对角
      if (_cornerX > _viewWidth / 2) {
        targetX = _viewWidth;
      } else {
        targetX = 0;
      }
      targetY = _cornerY;
    }

    final startTouchX = _touchX;
    final startTouchY = _touchY;

    _animController.reset();
    _animController.addListener(() {
      final t = Curves.easeInOut.transform(_animController.value);
      setState(() {
        _touchX = startTouchX + (targetX - startTouchX) * t;
        _touchY = startTouchY + (targetY - startTouchY) * t;
      });
    });

    _animController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _isAnimating = false;
        if (!_isCancel) {
          widget.onPageTurned
              ?.call(_direction == _FlipDir.next ? 1 : -1);
        }
        setState(() {
          _direction = _FlipDir.none;
          _touchX = 0.1;
          _touchY = 0.1;
        });
      }
    });

    _animController.forward();
  }

  /// 计算拖拽点对应的拖拽脚（移植自 Kotlin calcCornerXY）
  void _calcCornerXY(double x, double y) {
    _cornerX = x <= _viewWidth / 2 ? 0 : _viewWidth;
    _cornerY = y <= _viewHeight / 2 ? 0 : _viewHeight;
    _isRtOrLb = (_cornerX == 0 && _cornerY == _viewHeight) ||
        (_cornerY == 0 && _cornerX == _viewWidth);
  }

  // ─── 贝塞尔曲线计算（移植自 Kotlin calcPoints）────────────────

  _BezierPoints _calcPoints() {
    final bp = _BezierPoints();

    bp.touchX = _touchX;
    bp.touchY = _touchY;

    final middleX = (_touchX + _cornerX) / 2;
    final middleY = (_touchY + _cornerY) / 2;

    // 贝塞尔控制点 1
    bp.ctrl1X = middleX -
        (_cornerY - middleY) * (_cornerY - middleY) / (middleX - _cornerX);
    bp.ctrl1Y = _cornerY;

    // 贝塞尔控制点 2
    bp.ctrl2X = _cornerX;
    final f4 = _cornerY - middleY;
    if (f4 == 0) {
      bp.ctrl2Y = middleY -
          (_cornerX - middleX) * (_cornerX - middleX) / 0.1;
    } else {
      bp.ctrl2Y = middleY -
          (_cornerX - middleX) * (_cornerX - middleX) / (_cornerY - middleY);
    }

    // 贝塞尔起始点 1
    bp.start1X = bp.ctrl1X - (_cornerX - bp.ctrl1X) / 2;
    bp.start1Y = _cornerY;

    // 边界修正（同 Kotlin 版）
    if (_touchX > 0 && _touchX < _viewWidth) {
      if (bp.start1X < 0 || bp.start1X > _viewWidth) {
        if (bp.start1X < 0) bp.start1X = _viewWidth - bp.start1X;

        final f1 = (_cornerX - _touchX).abs();
        final f2 = _viewWidth * f1 / bp.start1X;
        bp.touchX = (_cornerX - f2).abs();

        final f3 = (_cornerX - bp.touchX).abs() *
            (_cornerY - _touchY).abs() /
            f1;
        bp.touchY = (_cornerY - f3).abs();

        // 重新计算
        final mx = (bp.touchX + _cornerX) / 2;
        final my = (bp.touchY + _cornerY) / 2;
        bp.ctrl1X = mx - (_cornerY - my) * (_cornerY - my) / (mx - _cornerX);
        bp.ctrl1Y = _cornerY;
        bp.ctrl2X = _cornerX;
        final f5 = _cornerY - my;
        if (f5 == 0) {
          bp.ctrl2Y =
              my - (_cornerX - mx) * (_cornerX - mx) / 0.1;
        } else {
          bp.ctrl2Y =
              my - (_cornerX - mx) * (_cornerX - mx) / (_cornerY - my);
        }
        bp.start1X = bp.ctrl1X - (_cornerX - bp.ctrl1X) / 2;
      }
    }

    // 贝塞尔起始点 2
    bp.start2X = _cornerX;
    bp.start2Y = bp.ctrl2Y - (_cornerY - bp.ctrl2Y) / 2;

    // 触点到角点的距离
    bp.touchToCornerDis = math.sqrt(
      math.pow(bp.touchX - _cornerX, 2) +
          math.pow(bp.touchY - _cornerY, 2),
    );

    // 贝塞尔结束点（直线交点）
    final end1 = _getCross(
      bp.touchX,
      bp.touchY,
      bp.ctrl1X,
      bp.ctrl1Y,
      bp.start1X,
      bp.start1Y,
      bp.start2X,
      bp.start2Y,
    );
    bp.end1X = end1.$1;
    bp.end1Y = end1.$2;

    final end2 = _getCross(
      bp.touchX,
      bp.touchY,
      bp.ctrl2X,
      bp.ctrl2Y,
      bp.start1X,
      bp.start1Y,
      bp.start2X,
      bp.start2Y,
    );
    bp.end2X = end2.$1;
    bp.end2Y = end2.$2;

    // 贝塞尔顶点
    bp.vertex1X = (bp.start1X + 2 * bp.ctrl1X + bp.end1X) / 4;
    bp.vertex1Y = (2 * bp.ctrl1Y + bp.start1Y + bp.end1Y) / 4;
    bp.vertex2X = (bp.start2X + 2 * bp.ctrl2X + bp.end2X) / 4;
    bp.vertex2Y = (2 * bp.ctrl2Y + bp.start2Y + bp.end2Y) / 4;

    bp.degrees = math.atan2(
          bp.ctrl1X - _cornerX,
          bp.ctrl2Y - _cornerY,
        ) *
        180 /
        math.pi;

    bp.middleX = (_touchX + _cornerX) / 2;
    bp.middleY = (_touchY + _cornerY) / 2;
    bp.isRtOrLb = _isRtOrLb;
    bp.cornerX = _cornerX;
    bp.cornerY = _cornerY;

    return bp;
  }

  /// 求解直线 P1P2 和直线 P3P4 的交点坐标（移植自 Kotlin getCross）
  (double, double) _getCross(
    double p1x,
    double p1y,
    double p2x,
    double p2y,
    double p3x,
    double p3y,
    double p4x,
    double p4y,
  ) {
    final dx1 = p2x - p1x;
    final dx2 = p4x - p3x;
    if (dx1 == 0 || dx2 == 0) return (p1x, p3y);
    final a1 = (p2y - p1y) / dx1;
    final b1 = (p1x * p2y - p2x * p1y) / (p1x - p2x);
    final a2 = (p4y - p3y) / dx2;
    final b2 = (p3x * p4y - p4x * p3y) / (p3x - p4x);
    final x = (b2 - b1) / (a1 - a2);
    final y = a1 * x + b1;
    return (x, y);
  }

  // ─── 构建 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onPanStart: (d) => _onPanStart(d, constraints),
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _direction != _FlipDir.none
                ? _SimulationPagePainter(
                    points: _calcPoints(),
                    direction: _direction,
                    viewWidth: constraints.maxWidth,
                    viewHeight: constraints.maxHeight,
                    bgColor: Theme.of(context).scaffoldBackgroundColor,
                  )
                : null,
            child: widget.currentBuilder(context),
          ),
        );
      },
    );
  }
}

/// 翻页方向
enum _FlipDir { none, next, prev }

/// 贝塞尔曲线计算结果
class _BezierPoints {
  double touchX = 0;
  double touchY = 0;
  double middleX = 0;
  double middleY = 0;
  double cornerX = 0;
  double cornerY = 0;
  bool isRtOrLb = false;

  double ctrl1X = 0, ctrl1Y = 0;
  double ctrl2X = 0, ctrl2Y = 0;
  double start1X = 0, start1Y = 0;
  double start2X = 0, start2Y = 0;
  double end1X = 0, end1Y = 0;
  double end2X = 0, end2Y = 0;
  double vertex1X = 0, vertex1Y = 0;
  double vertex2X = 0, vertex2Y = 0;

  double touchToCornerDis = 0;
  double degrees = 0;

  /// 构建翻起页贝塞尔路径（mPath0）
  ui.Path buildCurrentPagePath() {
    final path = ui.Path();
    path.moveTo(start1X, start1Y);
    path.quadraticBezierTo(ctrl1X, ctrl1Y, end1X, end1Y);
    path.lineTo(touchX, touchY);
    path.lineTo(end2X, end2Y);
    path.quadraticBezierTo(ctrl2X, ctrl2Y, start2X, start2Y);
    path.lineTo(cornerX, cornerY);
    path.close();
    return path;
  }

  /// 构建下一页可见区域路径（mPath1）
  ui.Path buildNextPageAreaPath() {
    final path = ui.Path();
    path.moveTo(start1X, start1Y);
    path.lineTo(vertex1X, vertex1Y);
    path.lineTo(vertex2X, vertex2Y);
    path.lineTo(start2X, start2Y);
    path.lineTo(cornerX, cornerY);
    path.close();
    return path;
  }

  /// 构建翻起页背面路径
  ui.Path buildBackAreaPath() {
    final path = ui.Path();
    path.moveTo(vertex2X, vertex2Y);
    path.lineTo(vertex1X, vertex1Y);
    path.lineTo(end1X, end1Y);
    path.lineTo(touchX, touchY);
    path.lineTo(end2X, end2Y);
    path.close();
    return path;
  }
}

/// 仿真翻页绘制器（移植自 Kotlin onDraw 四个绘制方法）
class _SimulationPagePainter extends CustomPainter {
  final _BezierPoints points;
  final _FlipDir direction;
  final double viewWidth;
  final double viewHeight;
  final Color bgColor;

  _SimulationPagePainter({
    required this.points,
    required this.direction,
    required this.viewWidth,
    required this.viewHeight,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 绘制底层（下一页/上一页）
    _drawNextPageAreaAndShadow(canvas, size);

    // 绘制当前页（被翻起的部分裁剪掉）
    _drawCurrentPageArea(canvas, size);

    // 绘制翻起页阴影
    _drawCurrentPageShadow(canvas, size);

    // 绘制翻起页背面
    _drawCurrentBackArea(canvas, size);
  }

  /// 绘制翻起页区域（同 Kotlin drawCurrentPageArea）
  void _drawCurrentPageArea(Canvas canvas, Size size) {
    final path = points.buildCurrentPagePath();

    canvas.save();
    final fullPath3 = ui.Path()..addRect(Rect.fromLTWH(0, 0, viewWidth, viewHeight));
    final diffPath3 = Path.combine(PathOperation.difference, fullPath3, path);
    canvas.clipPath(diffPath3);

    // 绘制当前页背景
    final pagePaint = Paint()..color = bgColor;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, viewWidth, viewHeight),
      pagePaint,
    );
    canvas.restore();
  }

  /// 绘制下一页区域和阴影（同 Kotlin drawNextPageAreaAndShadow）
  void _drawNextPageAreaAndShadow(Canvas canvas, Size size) {
    final path1 = points.buildNextPageAreaPath();
    final path0 = points.buildCurrentPagePath();

    // 计算阴影参数
    final shadowWidth = (points.touchToCornerDis / 4).clamp(10.0, 80.0);
    final leftX = points.isRtOrLb
        ? points.start1X
        : points.start1X - shadowWidth;
    final rightX = points.isRtOrLb
        ? points.start1X + shadowWidth
        : points.start1X;

    canvas.save();
    canvas.clipPath(path0);
    canvas.clipPath(path1);

    // 绘制下一页背景
    final nextPaint = Paint()
      ..color = bgColor.withValues(alpha: 0.9);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, viewWidth, viewHeight),
      nextPaint,
    );

    // 绘制背面阴影（同 Kotlin mBackShadowDrawable）
    canvas.save();
    canvas.translate(points.start1X, points.start1Y);
    canvas.rotate(points.degrees * math.pi / 180);
    canvas.translate(-points.start1X, -points.start1Y);
    final maxLen = math.sqrt(
      math.pow(viewWidth, 2) + math.pow(viewHeight, 2),
    );
    final shadowGradient = ui.Gradient.linear(
      Offset(leftX, points.start1Y),
      Offset(rightX, points.start1Y),
      [
        const Color(0x11111111),
        const Color(0x33333333),
      ],
    );
    final shadowPaint = Paint()..shader = shadowGradient;
    canvas.drawRect(
      Rect.fromLTRB(leftX, points.start1Y, rightX, points.start1Y + maxLen),
      shadowPaint,
    );
    canvas.restore();

    canvas.restore();
  }

  /// 绘制翻起页的阴影（同 Kotlin drawCurrentPageShadow）
  void _drawCurrentPageShadow(Canvas canvas, Size size) {
    final path0 = points.buildCurrentPagePath();

    // 计算阴影顶点
    final degree = points.isRtOrLb
        ? math.pi / 4 -
            math.atan2(
              points.ctrl1Y - points.touchY,
              points.touchX - points.ctrl1X,
            )
        : math.pi / 4 -
            math.atan2(
              points.touchY - points.ctrl1Y,
              points.touchX - points.ctrl1X,
            );

    final d1 = 25.0 * 1.414 * math.cos(degree);
    final d2 = 25.0 * 1.414 * math.sin(degree);
    final sx = points.touchX + d1;
    final sy = points.isRtOrLb
        ? points.touchY + d2
        : points.touchY - d2;

    // 绘制水平方向阴影
    final shadowPath1 = ui.Path();
    shadowPath1.moveTo(sx, sy);
    shadowPath1.lineTo(points.touchX, points.touchY);
    shadowPath1.lineTo(points.ctrl1X, points.ctrl1Y);
    shadowPath1.lineTo(points.start1X, points.start1Y);
    shadowPath1.close();

    canvas.save();
    // Flutter 不支持 clipOp.difference，用 Path.combine 替代
    final fullPath = ui.Path()..addRect(Rect.fromLTWH(0, 0, viewWidth, viewHeight));
    final diffPath = Path.combine(PathOperation.difference, fullPath, path0);
    final clipPath = Path.combine(PathOperation.intersect, diffPath, shadowPath1);
    canvas.clipPath(clipPath);

    final rotDeg = math.atan2(
          points.touchX - points.ctrl1X,
          points.ctrl1Y - points.touchY,
        );
    canvas.translate(points.ctrl1X, points.ctrl1Y);
    canvas.rotate(rotDeg);
    canvas.translate(-points.ctrl1X, -points.ctrl1Y);

    final maxLen = math.sqrt(
      math.pow(viewWidth, 2) + math.pow(viewHeight, 2),
    );

    final frontShadowL = points.isRtOrLb
        ? ui.Gradient.linear(
            Offset(points.ctrl1X, 0),
            Offset(points.ctrl1X + 25, 0),
            [const Color(0x80111111), const Color(0x00000000)],
          )
        : ui.Gradient.linear(
            Offset(points.ctrl1X - 25, 0),
            Offset(points.ctrl1X, 0),
            [const Color(0x00000000), const Color(0x80111111)],
          );

    final leftBound =
        points.isRtOrLb ? points.ctrl1X : points.ctrl1X - 25;
    final rightBound =
        points.isRtOrLb ? points.ctrl1X + 25 : points.ctrl1X + 1;

    canvas.drawRect(
      Rect.fromLTRB(
          leftBound, points.ctrl1Y - maxLen, rightBound, points.ctrl1Y),
      Paint()..shader = frontShadowL,
    );
    canvas.restore();

    // 绘制垂直方向阴影
    final shadowPath2 = ui.Path();
    shadowPath2.moveTo(sx, sy);
    shadowPath2.lineTo(points.touchX, points.touchY);
    shadowPath2.lineTo(points.ctrl2X, points.ctrl2Y);
    shadowPath2.lineTo(points.start2X, points.start2Y);
    shadowPath2.close();

    canvas.save();
    final fullPath2 = ui.Path()..addRect(Rect.fromLTWH(0, 0, viewWidth, viewHeight));
    final diffPath2 = Path.combine(PathOperation.difference, fullPath2, path0);
    final clipPath2 = Path.combine(PathOperation.intersect, diffPath2, shadowPath2);
    canvas.clipPath(clipPath2);

    final rotDeg2 = math.atan2(
          points.ctrl2Y - points.touchY,
          points.ctrl2X - points.touchX,
        );
    canvas.translate(points.ctrl2X, points.ctrl2Y);
    canvas.rotate(rotDeg2);
    canvas.translate(-points.ctrl2X, -points.ctrl2Y);

    final frontShadowV = points.isRtOrLb
        ? ui.Gradient.linear(
            Offset(0, points.ctrl2Y),
            Offset(0, points.ctrl2Y + 25),
            [const Color(0x80111111), const Color(0x00000000)],
          )
        : ui.Gradient.linear(
            Offset(0, points.ctrl2Y - 25),
            Offset(0, points.ctrl2Y + 1),
            [const Color(0x00000000), const Color(0x80111111)],
          );

    final vTop =
        points.isRtOrLb ? points.ctrl2Y : points.ctrl2Y - 25;
    final vBottom =
        points.isRtOrLb ? points.ctrl2Y + 25 : points.ctrl2Y + 1;

    canvas.drawRect(
      Rect.fromLTRB(
          points.ctrl2X - maxLen, vTop, points.ctrl2X, vBottom),
      Paint()..shader = frontShadowV,
    );
    canvas.restore();
  }

  /// 绘制翻起页背面（同 Kotlin drawCurrentBackArea）
  void _drawCurrentBackArea(Canvas canvas, Size size) {
    final path0 = points.buildCurrentPagePath();
    final path1 = points.buildBackAreaPath();

    // 计算折叠宽度
    final i = ((points.start1X + points.ctrl1X) / 2).toInt();
    final f1 = (i - points.ctrl1X).abs();
    final i1 = ((points.start2Y + points.ctrl2Y) / 2).toInt();
    final f2 = (i1 - points.ctrl2Y).abs();
    final f3 = math.min(f1, f2);

    canvas.save();
    canvas.clipPath(path0);
    canvas.clipPath(path1);

    // 绘制背面底色
    canvas.drawColor(bgColor, ui.BlendMode.src);

    // 绘制折叠阴影（同 Kotlin mFolderShadowDrawable）
    final foldLeft = points.isRtOrLb
        ? points.start1X - 1
        : points.start1X - f3 - 1;
    final foldRight = points.isRtOrLb
        ? points.start1X + f3 + 1
        : points.start1X + 1;

    final maxLen = math.sqrt(
      math.pow(viewWidth, 2) + math.pow(viewHeight, 2),
    );

    final folderShadow = points.isRtOrLb
        ? ui.Gradient.linear(
            Offset(foldLeft, 0),
            Offset(foldRight, 0),
            [const Color(0x33333333), const Color(0xB0333333)],
          )
        : ui.Gradient.linear(
            Offset(foldLeft, 0),
            Offset(foldRight, 0),
            [const Color(0xB0333333), const Color(0x33333333)],
          );

    canvas.translate(points.start1X, points.start1Y);
    canvas.rotate(points.degrees * math.pi / 180);
    canvas.translate(-points.start1X, -points.start1Y);
    canvas.drawRect(
      Rect.fromLTRB(foldLeft, points.start1Y, foldRight,
          points.start1Y + maxLen),
      Paint()..shader = folderShadow,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_SimulationPagePainter oldDelegate) {
    return oldDelegate.points.touchX != points.touchX ||
        oldDelegate.points.touchY != points.touchY;
  }
}
