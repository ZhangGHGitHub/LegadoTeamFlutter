// 书签角标（批4d）
//
// 参考 ReaderBookmarkBadge.kt:15-39 / ReaderBookmarkBadgeRenderer.kt:88-91：
// - 宽=size，高=2×size，右内缩 6dp，顶部=正文顶 +2dp；
// - 默认 #FFC107 书签带；
// - 自定义图按 cover 裁切，缺失/损坏回落默认。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/bookmark_badge_image_store.dart';

/// 默认琥珀色（参考 0xffffc107）
const Color kBookmarkBadgeDefaultColor = Color(0xFFFFC107);

/// 角标几何常量（相对正文内容区）
///
/// 参考默认书签带按 12×24 视口绘制：可见 ribbon x∈[2,10]、y∈[2,22]，
/// 缺口底部中心 y=17（深度 25%）。渲染时按 size 宽/2×size 高等比缩放，
/// 故可见宽 = size×2/3、可见高 = 2×size×5/6；path 自带 2/24 顶部内缩，
/// 外层 topInset 归 0。
abstract final class ReaderBookmarkBadgeGeometry {
  static const double topInset = 0;
  static const double rightInset = 6;

  /// 参考绘制视口与 ribbon 顶点（painter 按此坐标系绘制后缩放）
  static const double referenceWidth = 12;
  static const double referenceHeight = 24;
  static const double ribbonLeft = 2;
  static const double ribbonRight = 10;
  static const double ribbonTop = 2;
  static const double ribbonBottom = 22;
  static const double ribbonNotchY = 17;

  static double width(int size) => size <= 0 ? 0 : size.toDouble();
  static double height(int size) => width(size) * 2;

  /// 可见宽（reference 内 8/12 = 2/3）
  static double visibleWidth(int size) =>
      width(size) * (ribbonRight - ribbonLeft) / referenceWidth;

  /// 可见高（reference 内 20/24 = 5/6）
  static double visibleHeight(int size) =>
      height(size) * (ribbonBottom - ribbonTop) / referenceHeight;

  /// 底部缺口深度占比（(22-17)/(22-2) = 25%）
  static double get notchDepthRatio =>
      (ribbonBottom - ribbonNotchY) / (ribbonBottom - ribbonTop);
}

class ReaderBookmarkBadge extends StatelessWidget {
  final int size;

  /// 应用内相对标识（空/缺失时显示默认书签带）
  final String image;

  const ReaderBookmarkBadge({super.key, required this.size, this.image = ''});

  @override
  Widget build(BuildContext context) {
    final width = ReaderBookmarkBadgeGeometry.width(size);
    if (width <= 0) return const SizedBox.shrink();
    final path = BookmarkBadgeImageStore.resolveSync(image);
    return SizedBox(
      width: width,
      height: ReaderBookmarkBadgeGeometry.height(size),
      child: ClipRect(
        child: path == null
            ? const _DefaultBookmarkRibbon()
            : Image.file(
                File(path),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const _DefaultBookmarkRibbon(),
              ),
      ),
    );
  }
}

class _DefaultBookmarkRibbon extends StatelessWidget {
  const _DefaultBookmarkRibbon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: const ValueKey('bookmark-badge-default'),
      painter: _BookmarkRibbonPainter(),
    );
  }
}

class _BookmarkRibbonPainter extends CustomPainter {
  static const double _refW = ReaderBookmarkBadgeGeometry.referenceWidth;
  static const double _refH = ReaderBookmarkBadgeGeometry.referenceHeight;
  static const double _left = ReaderBookmarkBadgeGeometry.ribbonLeft;
  static const double _right = ReaderBookmarkBadgeGeometry.ribbonRight;
  static const double _top = ReaderBookmarkBadgeGeometry.ribbonTop;
  static const double _bottom = ReaderBookmarkBadgeGeometry.ribbonBottom;
  static const double _notchY = ReaderBookmarkBadgeGeometry.ribbonNotchY;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.scale(size.width / _refW, size.height / _refH);
    final path = Path()
      ..moveTo(_left, _top)
      ..lineTo(_right, _top)
      ..lineTo(_right, _bottom)
      ..lineTo((_left + _right) / 2, _notchY)
      ..lineTo(_left, _bottom)
      ..close();
    canvas.drawPath(path, Paint()..color = kBookmarkBadgeDefaultColor);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BookmarkRibbonPainter oldDelegate) => false;
}
