import 'dart:math' as math;
import 'dart:ui';

class CurlCorner {
  const CurlCorner({required this.cornerX, required this.cornerY});

  final int cornerX;
  final int cornerY;
}

class CurlPoints {
  const CurlPoints({
    required this.touchX,
    required this.touchY,
    required this.bezierStart1,
    required this.bezierControl1,
    required this.bezierVertex1,
    required this.bezierEnd1,
    required this.bezierStart2,
    required this.bezierControl2,
    required this.bezierVertex2,
    required this.bezierEnd2,
    required this.isRtOrLb,
    required this.degrees,
    required this.touchToCornerDis,
  });

  final double touchX;
  final double touchY;
  final Offset bezierStart1;
  final Offset bezierControl1;
  final Offset bezierVertex1;
  final Offset bezierEnd1;
  final Offset bezierStart2;
  final Offset bezierControl2;
  final Offset bezierVertex2;
  final Offset bezierEnd2;
  final bool isRtOrLb;
  final double degrees;
  final double touchToCornerDis;
}

CurlCorner calcCornerXY({
  required double x,
  required double y,
  required double viewWidth,
  required double viewHeight,
}) {
  final cornerX = x <= viewWidth / 2 ? 0 : viewWidth.toInt();
  final cornerY = y <= viewHeight / 2 ? 0 : viewHeight.toInt();
  return CurlCorner(cornerX: cornerX, cornerY: cornerY);
}

CurlPoints calcPoints({
  required double touchX,
  required double touchY,
  required int cornerX,
  required int cornerY,
  required double viewWidth,
  required double viewHeight,
}) {
  final isRtOrLb =
      (cornerX == 0 && cornerY == viewHeight.toInt()) ||
      (cornerY == 0 && cornerX == viewWidth.toInt());

  var mTouchX = touchX;
  var mTouchY = touchY;

  var mMiddleX = (mTouchX + cornerX) / 2;
  var mMiddleY = (mTouchY + cornerY) / 2;

  var bezierControl1 = Offset(
    mMiddleX -
        (cornerY - mMiddleY) * (cornerY - mMiddleY) / (cornerX - mMiddleX),
    cornerY.toDouble(),
  );
  var bezierControl2 = Offset(cornerX.toDouble(), 0);

  final f4 = cornerY - mMiddleY;
  if (f4 == 0) {
    bezierControl2 = Offset(
      bezierControl2.dx,
      mMiddleY - (cornerX - mMiddleX) * (cornerX - mMiddleX) / 0.1,
    );
  } else {
    bezierControl2 = Offset(
      bezierControl2.dx,
      mMiddleY -
          (cornerX - mMiddleX) * (cornerX - mMiddleX) / (cornerY - mMiddleY),
    );
  }

  var bezierStart1 = Offset(
    bezierControl1.dx - (cornerX - bezierControl1.dx) / 2,
    cornerY.toDouble(),
  );

  if (mTouchX > 0 && mTouchX < viewWidth) {
    if (bezierStart1.dx < 0 || bezierStart1.dx > viewWidth) {
      if (bezierStart1.dx < 0) {
        bezierStart1 = Offset(viewWidth - bezierStart1.dx, bezierStart1.dy);
      }

      final f1 = (cornerX - mTouchX).abs();
      final f2 = viewWidth * f1 / bezierStart1.dx;
      mTouchX = (cornerX - f2).abs();

      final f3 = (cornerX - mTouchX).abs() * (cornerY - mTouchY).abs() / f1;
      mTouchY = (cornerY - f3).abs();

      mMiddleX = (mTouchX + cornerX) / 2;
      mMiddleY = (mTouchY + cornerY) / 2;

      bezierControl1 = Offset(
        mMiddleX -
            (cornerY - mMiddleY) * (cornerY - mMiddleY) / (cornerX - mMiddleX),
        cornerY.toDouble(),
      );
      bezierControl2 = Offset(cornerX.toDouble(), 0);

      final f5 = cornerY - mMiddleY;
      if (f5 == 0) {
        bezierControl2 = Offset(
          bezierControl2.dx,
          mMiddleY - (cornerX - mMiddleX) * (cornerX - mMiddleX) / 0.1,
        );
      } else {
        bezierControl2 = Offset(
          bezierControl2.dx,
          mMiddleY -
              (cornerX - mMiddleX) *
                  (cornerX - mMiddleX) /
                  (cornerY - mMiddleY),
        );
      }

      bezierStart1 = Offset(
        bezierControl1.dx - (cornerX - bezierControl1.dx) / 2,
        bezierStart1.dy,
      );
    }
  }

  final bezierStart2 = Offset(
    cornerX.toDouble(),
    bezierControl2.dy - (cornerY - bezierControl2.dy) / 2,
  );

  final touchToCornerDis = math.sqrt(
    (mTouchX - cornerX) * (mTouchX - cornerX) +
        (mTouchY - cornerY) * (mTouchY - cornerY),
  );

  final bezierEnd1 = _getCross(
    Offset(mTouchX, mTouchY),
    bezierControl1,
    bezierStart1,
    bezierStart2,
  );
  final bezierEnd2 = _getCross(
    Offset(mTouchX, mTouchY),
    bezierControl2,
    bezierStart1,
    bezierStart2,
  );

  final bezierVertex1 = Offset(
    (bezierStart1.dx + 2 * bezierControl1.dx + bezierEnd1.dx) / 4,
    (2 * bezierControl1.dy + bezierStart1.dy + bezierEnd1.dy) / 4,
  );
  final bezierVertex2 = Offset(
    (bezierStart2.dx + 2 * bezierControl2.dx + bezierEnd2.dx) / 4,
    (2 * bezierControl2.dy + bezierStart2.dy + bezierEnd2.dy) / 4,
  );

  final degrees =
      math.atan2(bezierControl1.dx - cornerX, bezierControl2.dy - cornerY) *
      180 /
      math.pi;

  return CurlPoints(
    touchX: mTouchX,
    touchY: mTouchY,
    bezierStart1: bezierStart1,
    bezierControl1: bezierControl1,
    bezierVertex1: bezierVertex1,
    bezierEnd1: bezierEnd1,
    bezierStart2: bezierStart2,
    bezierControl2: bezierControl2,
    bezierVertex2: bezierVertex2,
    bezierEnd2: bezierEnd2,
    isRtOrLb: isRtOrLb,
    degrees: degrees,
    touchToCornerDis: touchToCornerDis,
  );
}

/// Solves intersection of line P1P2 and line P3P4.
Offset _getCross(Offset p1, Offset p2, Offset p3, Offset p4) {
  final a1 = (p2.dy - p1.dy) / (p2.dx - p1.dx);
  final b1 = (p1.dx * p2.dy - p2.dx * p1.dy) / (p1.dx - p2.dx);
  final a2 = (p4.dy - p3.dy) / (p4.dx - p3.dx);
  final b2 = (p3.dx * p4.dy - p4.dx * p3.dy) / (p3.dx - p4.dx);
  final x = (b2 - b1) / (a1 - a2);
  final y = a1 * x + b1;
  return Offset(x, y);
}
