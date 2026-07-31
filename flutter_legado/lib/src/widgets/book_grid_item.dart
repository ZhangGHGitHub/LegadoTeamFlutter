import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 书架网格项 — 含封面/进度/作者
///
/// 区域分离长按（对齐安卓原版）：
/// - 封面区域长按 → [onCoverLongPress]（打开书籍信息）
/// - 标题/信息区域长按 → [onInfoLongPress]（打开操作菜单）
/// - 点击 → [onTap]（打开阅读器）
class BookGridItem extends StatelessWidget {
  final String title;
  final String? coverUrl;
  final String? author;
  final double? progress;

  /// 点击回调（打开阅读器）
  final VoidCallback? onTap;

  /// 封面区域长按回调（打开书籍信息页）
  final VoidCallback? onCoverLongPress;

  /// 标题/信息区域长按回调（打开操作菜单）
  final VoidCallback? onInfoLongPress;

  const BookGridItem({
    super.key,
    required this.title,
    this.coverUrl,
    this.author,
    this.progress,
    this.onTap,
    this.onCoverLongPress,
    this.onInfoLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 封面区域：长按打开书籍信息
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            onLongPress: onCoverLongPress,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 按网格单元实际显示像素宽度限制解码尺寸，避免大图解码
                  final decodeWidth =
                      _decodeWidth(context, constraints.maxWidth);
                  return SizedBox(
                    width: double.infinity,
                    child: (coverUrl != null && coverUrl!.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: coverUrl!,
                            fit: BoxFit.cover,
                            memCacheWidth: decodeWidth,
                            placeholder: (_, _) =>
                                _buildPlaceholder(colorScheme),
                            errorWidget: (_, _, _) =>
                                _buildPlaceholder(colorScheme),
                          )
                        : _buildPlaceholder(colorScheme),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 标题/信息区域：长按打开操作菜单
        GestureDetector(
          onTap: onTap,
          onLongPress: onInfoLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (author != null)
                Text(
                  author!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (progress != null) ...[
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 根据显示宽度计算解码像素宽度（防护无界约束）
  int? _decodeWidth(BuildContext context, double displayWidth) {
    if (!displayWidth.isFinite || displayWidth <= 0) return null;
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return (displayWidth * pixelRatio).round();
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.menu_book,
          size: 40,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
