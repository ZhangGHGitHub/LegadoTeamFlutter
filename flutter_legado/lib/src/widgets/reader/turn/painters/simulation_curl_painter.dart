import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../page_direction.dart';
import '../simulation_curl_math.dart';

/// Jingshiro `SimulationPageDelegate` shadow color arrays (ARGB).
/// folder: intArrayOf(0x333333, -0x4fcccccd)
const _folderShadowColors = [Color(0x00333333), Color(0xB0333333)];

/// back: intArrayOf(-0xeeeeef, 0x111111)
const _backShadowColors = [Color(0xFF111111), Color(0x00111111)];

/// front: intArrayOf(-0x7feeeeef, 0x111111)
const _frontShadowColors = [Color(0x80111111), Color(0x00111111)];

/// Full Bezier page-curl painter ported from Jingshiro `SimulationPageDelegate`.
class SimulationCurlPainter extends CustomPainter {
  SimulationCurlPainter({
    required this.cur,
    required this.prev,
    required this.next,
    required this.direction,
    required this.touchX,
    required this.touchY,
    required this.cornerX,
    required this.cornerY,
    required this.viewSize,
    required this.isRunning,
    this.backPageColor = const Color(0xFFECECEC),
  });

  final ui.Image? cur;
  final ui.Image? prev;
  final ui.Image? next;
  final PageTurnDirection direction;
  final double touchX;
  final double touchY;
  final int cornerX;
  final int cornerY;
  final Size viewSize;
  final bool isRunning;
  final Color backPageColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (direction == PageTurnDirection.none || !isRunning) {
      _drawPage(canvas, cur, size);
      return;
    }

    final points = calcPoints(
      touchX: touchX,
      touchY: touchY,
      cornerX: cornerX,
      cornerY: cornerY,
      viewWidth: viewSize.width,
      viewHeight: viewSize.height,
    );

    final path0 = Path();
    switch (direction) {
      case PageTurnDirection.next:
        _drawCurrentPageArea(canvas, cur, size, points, path0);
        _drawNextPageAreaAndShadow(canvas, next, size, points, path0);
        _drawCurrentPageShadow(canvas, points, path0);
        _drawCurrentBackArea(canvas, cur, size, points, path0);
      case PageTurnDirection.prev:
        _drawCurrentPageArea(canvas, prev, size, points, path0);
        _drawNextPageAreaAndShadow(canvas, cur, size, points, path0);
        _drawCurrentPageShadow(canvas, points, path0);
        _drawCurrentBackArea(canvas, prev, size, points, path0);
      case PageTurnDirection.none:
        break;
    }
  }

  void _drawCurrentPageArea(
    Canvas canvas,
    ui.Image? bitmap,
    Size size,
    CurlPoints p,
    Path path0,
  ) {
    if (bitmap == null) return;

    path0
      ..reset()
      ..moveTo(p.bezierStart1.dx, p.bezierStart1.dy)
      ..quadraticBezierTo(
        p.bezierControl1.dx,
        p.bezierControl1.dy,
        p.bezierEnd1.dx,
        p.bezierEnd1.dy,
      )
      ..lineTo(p.touchX, p.touchY)
      ..lineTo(p.bezierEnd2.dx, p.bezierEnd2.dy)
      ..quadraticBezierTo(
        p.bezierControl2.dx,
        p.bezierControl2.dy,
        p.bezierStart2.dx,
        p.bezierStart2.dy,
      )
      ..lineTo(cornerX.toDouble(), cornerY.toDouble())
      ..close();

    canvas.save();
    canvas.clipPath(_clipOut(path0, size));
    _drawPage(canvas, bitmap, size);
    canvas.restore();
  }

  void _drawNextPageAreaAndShadow(
    Canvas canvas,
    ui.Image? bitmap,
    Size size,
    CurlPoints p,
    Path path0,
  ) {
    if (bitmap == null) return;

    final maxLength = math.sqrt(
      viewSize.width * viewSize.width + viewSize.height * viewSize.height,
    );

    final path1 = Path()
      ..moveTo(p.bezierStart1.dx, p.bezierStart1.dy)
      ..lineTo(p.bezierVertex1.dx, p.bezierVertex1.dy)
      ..lineTo(p.bezierVertex2.dx, p.bezierVertex2.dy)
      ..lineTo(p.bezierStart2.dx, p.bezierStart2.dy)
      ..lineTo(cornerX.toDouble(), cornerY.toDouble())
      ..close();

    final degrees = p.degrees;
    final int leftX;
    final int rightX;
    final List<Color> shadowColors;
    final Alignment begin;
    final Alignment end;
    if (p.isRtOrLb) {
      leftX = p.bezierStart1.dx.toInt();
      rightX = (p.bezierStart1.dx + p.touchToCornerDis / 4).toInt();
      shadowColors = _backShadowColors;
      begin = Alignment.centerLeft;
      end = Alignment.centerRight;
    } else {
      leftX = (p.bezierStart1.dx - p.touchToCornerDis / 4).toInt();
      rightX = p.bezierStart1.dx.toInt();
      shadowColors = _backShadowColors;
      begin = Alignment.centerRight;
      end = Alignment.centerLeft;
    }

    canvas.save();
    canvas.clipPath(path0);
    canvas.clipPath(path1);
    _drawPage(canvas, bitmap, size);
    _rotateAround(canvas, degrees * math.pi / 180, p.bezierStart1);
    final shadowRect = Rect.fromLTRB(
      leftX.toDouble(),
      p.bezierStart1.dy,
      rightX.toDouble(),
      p.bezierStart1.dy + maxLength,
    );
    canvas.drawRect(
      shadowRect,
      Paint()
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: shadowColors,
        ).createShader(shadowRect),
    );
    canvas.restore();
  }

  void _drawCurrentPageShadow(Canvas canvas, CurlPoints p, Path path0) {
    final maxLength = math.sqrt(
      viewSize.width * viewSize.width + viewSize.height * viewSize.height,
    );

    final degree = p.isRtOrLb
        ? math.pi / 4 -
              math.atan2(
                p.bezierControl1.dy - p.touchY,
                p.touchX - p.bezierControl1.dx,
              )
        : math.pi / 4 -
              math.atan2(
                p.touchY - p.bezierControl1.dy,
                p.touchX - p.bezierControl1.dx,
              );

    final d1 = 25.0 * 1.414 * math.cos(degree);
    final d2 = 25.0 * 1.414 * math.sin(degree);
    final x = p.touchX + d1;
    final y = p.isRtOrLb ? p.touchY + d2 : p.touchY - d2;

    // Vertical front shadow
    final path1 = Path()
      ..moveTo(x, y)
      ..lineTo(p.touchX, p.touchY)
      ..lineTo(p.bezierControl1.dx, p.bezierControl1.dy)
      ..lineTo(p.bezierStart1.dx, p.bezierStart1.dy)
      ..close();

    canvas.save();
    canvas.clipPath(_clipOut(path0, viewSize));
    canvas.clipPath(path1);

    late int leftX;
    late int rightX;
    late Alignment begin;
    late Alignment end;
    if (p.isRtOrLb) {
      leftX = p.bezierControl1.dx.toInt();
      rightX = (p.bezierControl1.dx + 25).toInt();
      begin = Alignment.centerLeft;
      end = Alignment.centerRight;
    } else {
      leftX = (p.bezierControl1.dx - 25).toInt();
      rightX = (p.bezierControl1.dx + 1).toInt();
      begin = Alignment.centerRight;
      end = Alignment.centerLeft;
    }

    var rotateDegrees =
        math.atan2(
          p.touchX - p.bezierControl1.dx,
          p.bezierControl1.dy - p.touchY,
        ) *
        180 /
        math.pi;
    _rotateAround(canvas, rotateDegrees * math.pi / 180, p.bezierControl1);
    var shadowRect = Rect.fromLTRB(
      leftX.toDouble(),
      p.bezierControl1.dy - maxLength,
      rightX.toDouble(),
      p.bezierControl1.dy,
    );
    canvas.drawRect(
      shadowRect,
      Paint()
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: _frontShadowColors,
        ).createShader(shadowRect),
    );
    canvas.restore();

    // Horizontal front shadow
    final path2 = Path()
      ..moveTo(x, y)
      ..lineTo(p.touchX, p.touchY)
      ..lineTo(p.bezierControl2.dx, p.bezierControl2.dy)
      ..lineTo(p.bezierStart2.dx, p.bezierStart2.dy)
      ..close();

    canvas.save();
    canvas.clipPath(_clipOut(path0, viewSize));
    canvas.clipPath(path2);

    if (p.isRtOrLb) {
      leftX = p.bezierControl2.dy.toInt();
      rightX = (p.bezierControl2.dy + 25).toInt();
      begin = Alignment.topCenter;
      end = Alignment.bottomCenter;
    } else {
      leftX = (p.bezierControl2.dy - 25).toInt();
      rightX = (p.bezierControl2.dy + 1).toInt();
      begin = Alignment.bottomCenter;
      end = Alignment.topCenter;
    }

    rotateDegrees =
        math.atan2(
          p.bezierControl2.dy - p.touchY,
          p.bezierControl2.dx - p.touchX,
        ) *
        180 /
        math.pi;
    _rotateAround(canvas, rotateDegrees * math.pi / 180, p.bezierControl2);

    final temp = p.bezierControl2.dy < 0
        ? p.bezierControl2.dy - viewSize.height
        : p.bezierControl2.dy;
    final hmg = math.sqrt(
      p.bezierControl2.dx * p.bezierControl2.dx + temp * temp,
    );
    if (hmg > maxLength) {
      shadowRect = Rect.fromLTRB(
        p.bezierControl2.dx - 25 - hmg,
        leftX.toDouble(),
        p.bezierControl2.dx + maxLength - hmg,
        rightX.toDouble(),
      );
    } else {
      shadowRect = Rect.fromLTRB(
        p.bezierControl2.dx - maxLength,
        leftX.toDouble(),
        p.bezierControl2.dx,
        rightX.toDouble(),
      );
    }
    canvas.drawRect(
      shadowRect,
      Paint()
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: _frontShadowColors,
        ).createShader(shadowRect),
    );
    canvas.restore();
  }

  void _drawCurrentBackArea(
    Canvas canvas,
    ui.Image? bitmap,
    Size size,
    CurlPoints p,
    Path path0,
  ) {
    if (bitmap == null) return;

    final maxLength = math.sqrt(
      viewSize.width * viewSize.width + viewSize.height * viewSize.height,
    );

    final i = ((p.bezierStart1.dx + p.bezierControl1.dx) / 2).toInt();
    final f1 = (i - p.bezierControl1.dx).abs();
    final i1 = ((p.bezierStart2.dy + p.bezierControl2.dy) / 2).toInt();
    final f2 = (i1 - p.bezierControl2.dy).abs();
    final f3 = math.min(f1, f2);

    final path1 = Path()
      ..moveTo(p.bezierVertex2.dx, p.bezierVertex2.dy)
      ..lineTo(p.bezierVertex1.dx, p.bezierVertex1.dy)
      ..lineTo(p.bezierEnd1.dx, p.bezierEnd1.dy)
      ..lineTo(p.touchX, p.touchY)
      ..lineTo(p.bezierEnd2.dx, p.bezierEnd2.dy)
      ..close();

    final int left;
    final int right;
    final Alignment begin;
    final Alignment end;
    if (p.isRtOrLb) {
      left = (p.bezierStart1.dx - 1).toInt();
      right = (p.bezierStart1.dx + f3 + 1).toInt();
      begin = Alignment.centerLeft;
      end = Alignment.centerRight;
    } else {
      left = (p.bezierStart1.dx - f3 - 1).toInt();
      right = (p.bezierStart1.dx + 1).toInt();
      begin = Alignment.centerRight;
      end = Alignment.centerLeft;
    }

    canvas.save();
    canvas.clipPath(path0);
    canvas.clipPath(path1);

    final dis = math.sqrt(
      (cornerX - p.bezierControl1.dx) * (cornerX - p.bezierControl1.dx) +
          (p.bezierControl2.dy - cornerY) * (p.bezierControl2.dy - cornerY),
    );
    final f8 = (cornerX - p.bezierControl1.dx) / dis;
    final f9 = (p.bezierControl2.dy - cornerY) / dis;

    // Android Matrix 3x3 reflection → Flutter Matrix4 affine.
    final m0 = 1 - 2 * f9 * f9;
    final m1 = 2 * f8 * f9;
    final m3 = m1;
    final m4 = 1 - 2 * f8 * f8;

    final cx = p.bezierControl1.dx;
    final cy = p.bezierControl1.dy;
    // preTranslate(-cx,-cy) then matrix then postTranslate(cx,cy)
    final matrix = Matrix4.identity()
      ..translateByDouble(cx, cy, 0, 1)
      ..multiply(Matrix4(m0, m3, 0, 0, m1, m4, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1))
      ..translateByDouble(-cx, -cy, 0, 1);

    canvas.drawColor(backPageColor, BlendMode.srcOver);
    canvas.save();
    canvas.transform(matrix.storage);
    _drawPage(canvas, bitmap, size);
    canvas.restore();

    _rotateAround(canvas, p.degrees * math.pi / 180, p.bezierStart1);
    final shadowRect = Rect.fromLTRB(
      left.toDouble(),
      p.bezierStart1.dy,
      right.toDouble(),
      p.bezierStart1.dy + maxLength,
    );
    canvas.drawRect(
      shadowRect,
      Paint()
        ..shader = LinearGradient(
          begin: begin,
          end: end,
          colors: _folderShadowColors,
        ).createShader(shadowRect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SimulationCurlPainter oldDelegate) {
    return oldDelegate.cur != cur ||
        oldDelegate.prev != prev ||
        oldDelegate.next != next ||
        oldDelegate.direction != direction ||
        oldDelegate.touchX != touchX ||
        oldDelegate.touchY != touchY ||
        oldDelegate.cornerX != cornerX ||
        oldDelegate.cornerY != cornerY ||
        oldDelegate.viewSize != viewSize ||
        oldDelegate.isRunning != isRunning ||
        oldDelegate.backPageColor != backPageColor;
  }
}

/// Equivalent to Android `clipOutPath` / `Region.Op.XOR` against the view.
Path _clipOut(Path hole, Size size) {
  final bounds = Path()..addRect(Offset.zero & size);
  return Path.combine(PathOperation.difference, bounds, hole);
}

void _rotateAround(Canvas canvas, double radians, Offset pivot) {
  canvas.translate(pivot.dx, pivot.dy);
  canvas.rotate(radians);
  canvas.translate(-pivot.dx, -pivot.dy);
}

void _drawPage(Canvas canvas, ui.Image? image, Size size) {
  if (image == null) return;
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    Paint(),
  );
}
