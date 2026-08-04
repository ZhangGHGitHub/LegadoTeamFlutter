import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 书架网格项（对标原版 item_bookshelf_grid.xml）
///
/// 结构：
/// - 封面铺满单元格，右上角未读角标（BadgeView bv_unread），
///   封面底部 2dp 阅读进度条（pb_read_progress）
/// - 封面下方书名：12sp、居中、最多 2 行（tv_name）
///
/// 区域分离长按（Flutter 扩展，对齐原版长按打开书籍信息）：
/// - 封面区域长按 → [onCoverLongPress]（打开书籍信息）
/// - 标题区域长按 → [onInfoLongPress]（打开操作菜单）
/// - 点击 → [onTap]（打开阅读/书籍信息）
class BookGridItem extends StatelessWidget {
  final String title;
  final String? coverUrl;

  /// 未读章节数（>0 时显示右上角角标）
  final int unreadNum;

  /// 阅读进度（null 表示无阅读记录，不显示进度条）
  final double? progress;

  /// 点击回调
  final VoidCallback? onTap;

  /// 封面区域长按回调（打开书籍信息页）
  final VoidCallback? onCoverLongPress;

  /// 标题区域长按回调（打开操作菜单）
  final VoidCallback? onInfoLongPress;

  const BookGridItem({
    super.key,
    required this.title,
    this.coverUrl,
    this.unreadNum = 0,
    this.progress,
    this.onTap,
    this.onCoverLongPress,
    this.onInfoLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // 封面区域：右上角标 + 底部进度条；长按打开书籍信息
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            onLongPress: onCoverLongPress,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    // [审计修复 §3.3] 阴影改用 colorScheme.shadow Token — Qoder
                    color: colorScheme.shadow.withValues(alpha: 0.10),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LayoutBuilder(
                builder: (context, constraints) {
                  // 按网格单元实际显示像素宽度限制解码尺寸，避免大图解码
                  final decodeWidth =
                      _decodeWidth(context, constraints.maxWidth);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      (coverUrl != null && coverUrl!.isNotEmpty)
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
                      // 未读角标（对标 bv_unread，右上角）
                      if (unreadNum > 0)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            constraints: const BoxConstraints(
                                minWidth: 18, minHeight: 18),
                            decoration: BoxDecoration(
                              color: colorScheme.error,
                              borderRadius: const BorderRadius.only(
                                topRight: Radius.circular(10),
                                bottomLeft: Radius.circular(8),
                              ),
                            ),
                            child: Text(
                              unreadNum > 99 ? '99+' : '$unreadNum',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: colorScheme.onError,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ),
                      // 封面底部阅读进度条（对标 pb_read_progress，2dp）
                      if (progress != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: progress!.clamp(0.0, 1.0),
                            minHeight: 2,
                            backgroundColor: colorScheme.primary
                                .withValues(alpha: 0.25),
                            valueColor:
                                AlwaysStoppedAnimation(colorScheme.primary),
                          ),
                        ),
                    ],
                  );
                },
              ),
              ),
            ),
          ),
        ),
        // 书名区域：12sp 居中最多 2 行（对标 tv_name）；长按打开操作菜单
        GestureDetector(
          onTap: onTap,
          onLongPress: onInfoLongPress,
          child: SizedBox(
            height: 40,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.topCenter,
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
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
