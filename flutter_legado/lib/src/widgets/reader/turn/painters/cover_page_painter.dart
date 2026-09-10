import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../page_direction.dart';

/// Jingshiro `CoverPageDelegate.setViewSize` uses raw px `30` for shadow.
/// Convert with [devicePixelRatio]: logical = 30 / dpr.
const double kCoverShadowWidthPx = 30;

/// Jingshiro `CoverPageDelegate.onDraw` — assumes a live/current page sits
/// underneath the canvas (we draw that base in [ReaderTurnView]).
class CoverPagePainter extends CustomPainter {
  CoverPagePainter({
    required this.cur,
    required this.prev,
    required this.next,
    required this.direction,
    required this.touchX,
    required this.startX,
    required this.viewSize,
    required this.isRunning,
    this.devicePixelRatio = 1,
  });

  final ui.Image? cur;
  final ui.Image? prev;
  final ui.Image? next;
  final PageTurnDirection direction;
  final double touchX;
  final double startX;
  final Size viewSize;
  final bool isRunning;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    // Jingshiro CoverPageDelegate.onDraw: if (!isRunning) return.
    if (!isRunning) {
      return;
    }

    final viewWidth = viewSize.width;
    final offsetX = touchX - startX;

    // KT: invalid drag direction → return (underlay shows).
    if ((direction == PageTurnDirection.next && offsetX > 0) ||
        (direction == PageTurnDirection.prev && offsetX < 0)) {
      return;
    }

    final distanceX = offsetX > 0 ? offsetX - viewWidth : offsetX + viewWidth;

    if (direction == PageTurnDirection.prev) {
      // Underlay = current page (Jingshiro live curPage). Only draw prev + shadow.
      if (offsetX <= viewWidth) {
        // withTranslation(distanceX) { prevRecorder.draw(canvas) } — same Canvas.
        _drawPageTranslated(canvas, prev, distanceX, size);
        _addShadow(canvas, distanceX, size, devicePixelRatio);
      } else {
        _drawPage(canvas, prev, size);
      }
    } else if (direction == PageTurnDirection.next) {
      final width = viewSize.width;
      final height = viewSize.height;
      // withClip(width + offsetX, 0, width, height) { next.draw }
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(width + offsetX, 0, width, height));
      _drawPage(canvas, next, size);
      canvas.restore();
      // withTranslation(distanceX - viewWidth) { cur.draw }
      _drawPageTranslated(canvas, cur, distanceX - viewWidth, size);
      _addShadow(canvas, distanceX, size, devicePixelRatio);
    }
  }

  @override
  bool shouldRepaint(covariant CoverPagePainter oldDelegate) {
    return oldDelegate.cur != cur ||
        oldDelegate.prev != prev ||
        oldDelegate.next != next ||
        oldDelegate.direction != direction ||
        oldDelegate.touchX != touchX ||
        oldDelegate.startX != startX ||
        oldDelegate.viewSize != viewSize ||
        oldDelegate.isRunning != isRunning ||
        oldDelegate.devicePixelRatio != devicePixelRatio;
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

void _addShadow(
  Canvas canvas,
  double left,
  Size size,
  double devicePixelRatio,
) {
  if (left == 0) {
    return;
  }
  final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
  final shadowW = kCoverShadowWidthPx / dpr;
  final dx = left < 0 ? left + size.width : left;
  final shadowRect = Rect.fromLTWH(0, 0, shadowW, size.height);
  canvas.save();
  canvas.translate(dx, 0);
  canvas.drawRect(
    shadowRect,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Color(0x66111111), Color(0x00000000)],
      ).createShader(shadowRect),
  );
  canvas.restore();
}
