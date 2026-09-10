import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import 'page_direction.dart';
import 'simulation_curl_math.dart';

/// Jingshiro `ReadView.defaultAnimationSpeed`.
const int kDefaultPageAnimSpeed = 300;

/// Jingshiro `PageDelegate.startScroll` duration (milliseconds).
int pageTurnSettleDurationMs({
  required double dx,
  required double dy,
  required double viewWidth,
  required double viewHeight,
  required int animationSpeed,
}) {
  final durationMs = dx != 0
      ? (animationSpeed * dx.abs()) ~/ viewWidth
      : (animationSpeed * dy.abs()) ~/ viewHeight;
  return math.max(durationMs, 1);
}

/// Cover/Slide vs Simulation use different `onAnimStart` endpoints.
enum PageTurnSettleStyle { simulation, horizontal }

/// Jingshiro `CoverPageDelegate` / `SlidePageDelegate.onAnimStart` (dy = 0).
Offset pageTurnHorizontalSettleDelta({
  required PageTurnDirection direction,
  required bool isCancel,
  required double touchX,
  required double startX,
  required double viewWidth,
}) {
  final double distanceX;
  if (direction == PageTurnDirection.next) {
    if (isCancel) {
      var dis = viewWidth - startX + touchX;
      if (dis > viewWidth) {
        dis = viewWidth;
      }
      distanceX = viewWidth - dis;
    } else {
      distanceX = -(touchX + (viewWidth - startX));
    }
  } else {
    // PREV (and NONE treated as PREV branch in KT `else`)
    if (isCancel) {
      distanceX = -(touchX - startX);
    } else {
      distanceX = viewWidth - (touchX - startX);
    }
  }
  return Offset(distanceX, 0);
}

class PageTurnController extends ChangeNotifier {
  PageTurnDirection direction = PageTurnDirection.none;
  double touchX = 0;
  double touchY = 0;
  double startX = 0;
  double startY = 0;
  bool isDragging = false;
  bool isSettling = false;
  bool isCancel = false;

  bool _isMoved = false;
  double _lastX = 0;
  int _cornerX = 1;
  int _cornerY = 1;

  int get cornerX => _cornerX;
  int get cornerY => _cornerY;
  AnimationController? _settleController;
  VoidCallback? _settleListener;

  void onPointerDown(Offset p, {double? viewWidth, double? viewHeight}) {
    _abortSettle(applyCompletion: false);
    _isMoved = false;
    isDragging = false;
    isSettling = false;
    isCancel = false;
    direction = PageTurnDirection.none;
    startX = p.dx;
    startY = p.dy;
    touchX = p.dx;
    touchY = p.dy;
    _lastX = p.dx;
    if (viewWidth != null && viewHeight != null) {
      final corner = calcCornerXY(
        x: p.dx,
        y: p.dy,
        viewWidth: viewWidth,
        viewHeight: viewHeight,
      );
      _cornerX = corner.cornerX;
      _cornerY = corner.cornerY;
    }
    notifyListeners();
  }

  bool onPointerMove(
    Offset p, {
    required bool hasPrev,
    required bool hasNext,
    required double slop,
    double? viewWidth,
    double? viewHeight,
  }) {
    final slopSquare = slop * slop;
    if (!_isMoved) {
      final deltaX = (p.dx - startX).round();
      final deltaY = (p.dy - startY).round();
      final distance = deltaX * deltaX + deltaY * deltaY;
      if (distance <= slopSquare) {
        return false;
      }
      _isMoved = true;
      if (p.dx - startX > 0) {
        if (!hasPrev) {
          return false;
        }
        direction = PageTurnDirection.prev;
      } else {
        if (!hasNext) {
          return false;
        }
        direction = PageTurnDirection.next;
      }
      startX = p.dx;
      startY = p.dy;
      if (viewWidth != null && viewHeight != null) {
        _updateCornerForDirection(viewWidth: viewWidth, viewHeight: viewHeight);
      }
    }

    if (_isMoved && direction != PageTurnDirection.none) {
      isCancel = direction == PageTurnDirection.next
          ? p.dx > _lastX
          : p.dx < _lastX;
      isDragging = true;
      touchX = p.dx;
      touchY = p.dy;
      _lastX = p.dx;
      notifyListeners();
      return true;
    }

    if (_isMoved) {
      touchX = p.dx;
      touchY = p.dy;
      _lastX = p.dx;
      notifyListeners();
    }
    return false;
  }

  Future<void> onPointerUp({
    required TickerProvider vsync,
    required double viewWidth,
    required double viewHeight,
    required void Function(PageTurnDirection) onCompleted,
    PageTurnSettleStyle settleStyle = PageTurnSettleStyle.simulation,
    int animationSpeed = kDefaultPageAnimSpeed,
  }) {
    if (!_isMoved || direction == PageTurnDirection.none) {
      _resetAfterGesture();
      return Future.value();
    }
    return _startSettle(
      vsync: vsync,
      viewWidth: viewWidth,
      viewHeight: viewHeight,
      onCompleted: onCompleted,
      settleStyle: settleStyle,
      animationSpeed: animationSpeed,
    );
  }

  Future<void> turnByAnim(
    PageTurnDirection dir, {
    required TickerProvider vsync,
    required double viewWidth,
    required double viewHeight,
    required void Function(PageTurnDirection) onCompleted,
    required bool hasPrev,
    required bool hasNext,
    PageTurnSettleStyle settleStyle = PageTurnSettleStyle.simulation,
    int animationSpeed = kDefaultPageAnimSpeed,
  }) {
    _abortSettle(applyCompletion: false);
    if (dir == PageTurnDirection.next) {
      if (!hasNext) {
        return Future.value();
      }
      direction = PageTurnDirection.next;
      final y = startY > viewHeight / 2 ? viewHeight * 0.9 : 1.0;
      startX = viewWidth * 0.9;
      startY = y;
      touchX = startX;
      touchY = startY;
      isCancel = false;
      _isMoved = true;
    } else if (dir == PageTurnDirection.prev) {
      if (!hasPrev) {
        return Future.value();
      }
      direction = PageTurnDirection.prev;
      startX = 0;
      startY = viewHeight;
      touchX = startX;
      touchY = startY;
      isCancel = false;
      _isMoved = true;
    } else {
      return Future.value();
    }
    isDragging = false;
    notifyListeners();
    return _startSettle(
      vsync: vsync,
      viewWidth: viewWidth,
      viewHeight: viewHeight,
      onCompleted: onCompleted,
      settleStyle: settleStyle,
      animationSpeed: animationSpeed,
    );
  }

  void _updateCornerForDirection({
    required double viewWidth,
    required double viewHeight,
  }) {
    switch (direction) {
      case PageTurnDirection.prev:
        final corner = startX > viewWidth / 2
            ? calcCornerXY(
                x: startX,
                y: viewHeight,
                viewWidth: viewWidth,
                viewHeight: viewHeight,
              )
            : calcCornerXY(
                x: viewWidth - startX,
                y: viewHeight,
                viewWidth: viewWidth,
                viewHeight: viewHeight,
              );
        _cornerX = corner.cornerX;
        _cornerY = corner.cornerY;
      case PageTurnDirection.next:
        if (viewWidth / 2 > startX) {
          final corner = calcCornerXY(
            x: viewWidth - startX,
            y: startY,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
          );
          _cornerX = corner.cornerX;
          _cornerY = corner.cornerY;
        }
      case PageTurnDirection.none:
        break;
    }
  }

  Offset _settleDelta({
    required double viewWidth,
    required double viewHeight,
    required PageTurnSettleStyle settleStyle,
  }) {
    if (settleStyle == PageTurnSettleStyle.horizontal) {
      return pageTurnHorizontalSettleDelta(
        direction: direction,
        isCancel: isCancel,
        touchX: touchX,
        startX: startX,
        viewWidth: viewWidth,
      );
    }

    late double dx;
    late double dy;
    if (isCancel) {
      if (_cornerX > 0 && direction == PageTurnDirection.next) {
        dx = viewWidth - touchX;
      } else {
        dx = -touchX;
      }
      if (direction != PageTurnDirection.next) {
        dx = -(viewWidth + touchX);
      }
      dy = _cornerY > 0 ? viewHeight - touchY : -touchY;
    } else {
      if (_cornerX > 0 && direction == PageTurnDirection.next) {
        dx = -(viewWidth + touchX);
      } else {
        dx = viewWidth - touchX;
      }
      dy = _cornerY > 0 ? viewHeight - touchY : 1 - touchY;
    }
    return Offset(dx, dy);
  }

  Future<void> _startSettle({
    required TickerProvider vsync,
    required double viewWidth,
    required double viewHeight,
    required void Function(PageTurnDirection) onCompleted,
    required PageTurnSettleStyle settleStyle,
    required int animationSpeed,
  }) {
    if (settleStyle == PageTurnSettleStyle.simulation) {
      _updateCornerForDirection(viewWidth: viewWidth, viewHeight: viewHeight);
    }
    final delta = _settleDelta(
      viewWidth: viewWidth,
      viewHeight: viewHeight,
      settleStyle: settleStyle,
    );
    final fromX = touchX;
    final fromY = touchY;
    final completedDirection = direction;
    final cancelled = isCancel;

    final durationMs = pageTurnSettleDurationMs(
      dx: delta.dx,
      dy: delta.dy,
      viewWidth: viewWidth,
      viewHeight: viewHeight,
      animationSpeed: animationSpeed,
    );
    final duration = Duration(milliseconds: durationMs);

    isDragging = false;
    isSettling = true;
    notifyListeners();

    final controller = AnimationController(vsync: vsync, duration: duration);
    _settleController = controller;

    void listener() {
      final t = controller.value;
      touchX = fromX + delta.dx * t;
      touchY = fromY + delta.dy * t;
      notifyListeners();
    }

    _settleListener = listener;
    controller.addListener(listener);

    final completer = Completer<void>();
    controller.addStatusListener((status) {
      if (status != AnimationStatus.completed) {
        return;
      }
      controller.removeListener(listener);
      _settleController = null;
      _settleListener = null;
      if (!cancelled) {
        onCompleted(completedDirection);
      }
      _resetAfterGesture();
      completer.complete();
    });

    controller.forward();
    return completer.future;
  }

  void _abortSettle({required bool applyCompletion}) {
    final controller = _settleController;
    if (controller == null) {
      return;
    }
    final listener = _settleListener;
    if (listener != null) {
      controller.removeListener(listener);
    }
    controller.stop();
    controller.dispose();
    _settleController = null;
    _settleListener = null;
    isSettling = false;
  }

  void resetGesture() {
    _abortSettle(applyCompletion: false);
    _resetAfterGesture();
  }

  void _resetAfterGesture() {
    _isMoved = false;
    isDragging = false;
    isSettling = false;
    isCancel = false;
    direction = PageTurnDirection.none;
    notifyListeners();
  }

  @override
  void dispose() {
    _abortSettle(applyCompletion: false);
    super.dispose();
  }
}
