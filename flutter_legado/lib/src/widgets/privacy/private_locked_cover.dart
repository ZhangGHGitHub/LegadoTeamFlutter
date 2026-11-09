// 私密内容锁定外观（批9c）
//
// 对齐参考版 `PrivateLockedCover` / `PrivateLockedCoverOverlay`：
// 封面强模糊 + 深色遮罩 + 点阵 + 锁标；不渲染任何真实书名/作者文本。
// 低版本无真模糊时退化为深色遮罩（仍不泄露封面细节）。
//
// 编写：全栈工程师（批9c） ｜ 2026-11-09
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../book_cover.dart';

/// 锁定封面叠层：深色遮罩 + 点阵 + 居中锁标
class PrivateLockedCoverOverlay extends StatelessWidget {
  const PrivateLockedCoverOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: colorScheme.surface.withValues(alpha: 0.45)),
          ColoredBox(color: Colors.black.withValues(alpha: 0.32)),
          const CustomPaint(painter: _LockedDotsPainter()),
          Center(
            child: Container(
              key: const ValueKey('private-lock-icon'),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Symbols.lock_rounded,
                size: 17,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 锁定封面（模糊封面 + 遮罩；无封面 URL 时退化为纯色书形占位）
class PrivateLockedCover extends StatelessWidget {
  const PrivateLockedCover({
    super.key,
    required this.width,
    required this.height,
    this.coverUrl,
    this.bookName,
    this.bookAuthor,
    this.sourceOrigin,
    this.heroTag,
    this.borderRadius = 4,
    this.adaptAspectRatio = false,
    this.adaptiveMinHeight,
    this.adaptiveMaxHeight,
  });

  final double width;
  final double height;
  final String? coverUrl;
  final String? bookName;
  final String? bookAuthor;
  final String? sourceOrigin;
  final String? heroTag;
  final double borderRadius;
  final bool adaptAspectRatio;
  final double? adaptiveMinHeight;
  final double? adaptiveMaxHeight;

  @override
  Widget build(BuildContext context) {
    final hasCover = coverUrl != null && coverUrl!.isNotEmpty;
    final cover = hasCover
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: BookCover(
              coverUrl: coverUrl,
              bookName: bookName,
              bookAuthor: bookAuthor,
              width: width,
              height: height,
              borderRadius: borderRadius,
              sourceOrigin: sourceOrigin,
              heroTag: heroTag,
              adaptAspectRatio: adaptAspectRatio,
              adaptiveMinHeight: adaptiveMinHeight,
              adaptiveMaxHeight: adaptiveMaxHeight,
            ),
          )
        : Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Theme.of(context).colorScheme.surfaceContainerHigh,
                  Theme.of(context).colorScheme.surfaceContainerHighest,
                ],
              ),
            ),
            child: Icon(
              Symbols.menu_book_rounded,
              size: 26,
              color: Theme.of(context).colorScheme.outline,
            ),
          );

    return Semantics(
      container: true,
      label: '已隐藏',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [cover, const PrivateLockedCoverOverlay()],
            ),
          ),
        ),
      ),
    );
  }
}

/// 点阵纹理（对齐参考版“点阵”遮罩）
class _LockedDotsPainter extends CustomPainter {
  const _LockedDotsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.22);
    const spacing = 9.0;
    for (var y = spacing / 2; y < size.height; y += spacing) {
      for (var x = spacing / 2; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LockedDotsPainter oldDelegate) => false;
}
