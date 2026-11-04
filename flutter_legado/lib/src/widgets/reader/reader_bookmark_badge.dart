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
abstract final class ReaderBookmarkBadgeGeometry {
  static const double topInset = 2;
  static const double rightInset = 6;

  static double width(int size) => size <= 0 ? 0 : size.toDouble();
  static double height(int size) => width(size) * 2;
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
                fit: BoxFit.cover,
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
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width / 2, size.height * 0.78)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = kBookmarkBadgeDefaultColor);
  }

  @override
  bool shouldRepaint(covariant _BookmarkRibbonPainter oldDelegate) => false;
}
