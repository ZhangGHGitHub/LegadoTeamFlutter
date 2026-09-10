import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../page_direction.dart';

/// Jingshiro `SlidePageDelegate.onDraw` — current page underlay is drawn by
/// [ReaderTurnView] when the painter early-returns (invalid offset / idle).
class SlidePagePainter extends CustomPainter {
  SlidePagePainter({
    required this.cur,
    required this.prev,
    required this.next,
    required this.direction,
    required this.touchX,
    required this.startX,
    required this.viewSize,
    required this.isRunning,
  });

  final ui.Image? cur;
  final ui.Image? prev;
  final ui.Image? next;
  final PageTurnDirection direction;
  final double touchX;
  final double startX;
  final Size viewSize;
  final bool isRunning;

  @override
  void paint(Canvas canvas, Size size) {
    final viewWidth = viewSize.width;
    final offsetX = touchX - startX;

    // Jingshiro SlidePageDelegate.onDraw order: invalid offset → distanceX → !isRunning.
    if ((direction == PageTurnDirection.next && offsetX > 0) ||
        (direction == PageTurnDirection.prev && offsetX < 0)) {
      return;
    }

    final distanceX = offsetX > 0 ? offsetX - viewWidth : offsetX + viewWidth;
    if (!isRunning) {
      return;
    }

    if (direction == PageTurnDirection.prev) {
      _drawPageTranslated(canvas, cur, distanceX + viewWidth, size);
      _drawPageTranslated(canvas, prev, distanceX, size);
    } else if (direction == PageTurnDirection.next) {
      _drawPageTranslated(canvas, next, distanceX, size);
      _drawPageTranslated(canvas, cur, distanceX - viewWidth, size);
    }
  }

  @override
  bool shouldRepaint(covariant SlidePagePainter oldDelegate) {
    return oldDelegate.cur != cur ||
        oldDelegate.prev != prev ||
        oldDelegate.next != next ||
        oldDelegate.direction != direction ||
        oldDelegate.touchX != touchX ||
        oldDelegate.startX != startX ||
        oldDelegate.viewSize != viewSize ||
        oldDelegate.isRunning != isRunning;
  }
}

void _drawPage(Canvas canvas, ui.Image? image, Size size) {
  if (image == null) {
    return;
  }
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.medium,
  );
}

void _drawPageTranslated(Canvas canvas, ui.Image? image, double dx, Size size) {
  if (image == null) {
    return;
  }
  canvas.save();
  canvas.translate(dx, 0);
  _drawPage(canvas, image, size);
  canvas.restore();
}
