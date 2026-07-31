import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 书籍封面组件 — 支持网络图片 + 占位图
///
/// 使用 [CachedNetworkImage] 实现内存 + 磁盘双缓存，
/// 并通过 memCacheWidth 限制解码尺寸，避免大图解码造成内存压力。
class BookCover extends StatelessWidget {
  final String? coverUrl;
  final double width;
  final double height;
  final double borderRadius;

  const BookCover({
    super.key,
    this.coverUrl,
    this.width = 80,
    this.height = 110,
    this.borderRadius = 4,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: (coverUrl != null && coverUrl!.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: coverUrl!,
                fit: BoxFit.cover,
                // 限制解码宽度为实际显示像素宽度，避免大图解码
                // （仅设宽度可保持宽高比；磁盘缓存默认开启）
                memCacheWidth: _decodeWidth(context),
                placeholder: (_, _) => _buildPlaceholder(colorScheme),
                errorWidget: (_, _, _) => _buildPlaceholder(colorScheme),
              )
            : _buildPlaceholder(colorScheme),
      ),
    );
  }

  /// 计算显示宽度对应的解码像素宽度（逻辑宽度 × 设备像素比）
  int _decodeWidth(BuildContext context) {
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return (width * pixelRatio).round();
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.menu_book,
          size: width * 0.4,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
