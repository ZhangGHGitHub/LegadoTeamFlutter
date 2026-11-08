// 封面相册缩略图（设置批6b-2）
//
// 相册卡片 / 选择 Sheet / 图片网格共用：本地文件 `Image.file` 按显示宽度
// 设置 cacheWidth（避免大图整张解码）；文件缺失/损坏回落占位图标。
//
// 编写：全栈工程师（设置批6b-2） ｜ 2026-11-09
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 相册缩略图（5:7 封面比例由调用方尺寸决定）
class CoverAlbumPreview extends StatelessWidget {
  final String? path;
  final double width;
  final double height;
  final double borderRadius;

  const CoverAlbumPreview({
    super.key,
    required this.path,
    this.width = 44,
    this.height = 60,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Symbols.collections_bookmark,
          size: width * 0.5,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final filePath = path;
    final child = filePath == null || filePath.isEmpty
        ? placeholder
        : Image.file(
            File(filePath),
            fit: BoxFit.cover,
            width: width,
            height: height,
            cacheWidth: _cacheWidth(context),
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(width: width, height: height, child: child),
    );
  }

  int _cacheWidth(BuildContext context) {
    final ratio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return (width * ratio).round().clamp(1, 512);
  }
}
