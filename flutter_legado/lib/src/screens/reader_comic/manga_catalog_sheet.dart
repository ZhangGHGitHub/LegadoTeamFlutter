import 'package:flutter/material.dart';

import '../../models/models.dart';

/// [P4-3 M1] 目录 bottom sheet（章节列表 + 当前章高亮 + 点击跳章）
///
/// 取证（参考版）：参考版目录是**模态 bottom sheet**——
/// - ReaderBookSheet.kt L279-374：`AppModalBottomSheet`
///   （maxHeight = 屏高 × 0.72），内含书籍头（封面 + 书名/作者 +
///   章节位置）+ 标签行（信息/章节列表/书签/笔记）+ HorizontalPager；
/// - ReadMangaActivity.kt L80-110：`initialTab = Toc`，
///   `onChapterClick(index) → DismissSheet + OpenChapter`；
/// - 章节列表 tab = 虚拟化章节列表（当前章高亮、点击跳章）。
///
/// 本实现取目录 tab 的核心语义（章节列表 + 高亮 + 跳章）：
/// - 列表用 [ListView.builder] 虚拟化（章节数可超 1000）；
/// - 标题「目录(N)」，N = 章节数（参考版 chapter_list_size L184/407）；
/// - 当前章高亮（primaryContainer 底 + primary 文字），点击 →
///   关 sheet + 跳章（屏幕层 [_goToChapter]）。
/// 未做（汇报项）：书籍头/信息/书签/笔记 tab（本方无对应面板）。
class MangaCatalogSheet extends StatelessWidget {
  final List<BookChapter> chapters;

  /// 当前章节索引（高亮用）
  final int currentIndex;

  /// 点击章节（sheet 内先弹 sheet 再回调；对齐参考版
  /// DismissSheet + OpenChapter 次序）
  final ValueChanged<int> onSelected;

  const MangaCatalogSheet({
    super.key,
    required this.chapters,
    required this.currentIndex,
    required this.onSelected,
  });

  /// 弹出目录 sheet（样式先例 manga_config_sheet.dart：
  /// isScrollControlled + 透明背景 + 自绘圆角容器）
  static Future<void> show(
    BuildContext context, {
    required List<BookChapter> chapters,
    required int currentIndex,
    required ValueChanged<int> onSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MangaCatalogSheet(
        chapters: chapters,
        currentIndex: currentIndex,
        onSelected: onSelected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;
    return Container(
      // 参考版 ReaderBookSheet maxHeight = 屏高 × 0.72
      constraints: BoxConstraints(maxHeight: screenHeight * 0.72),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          // 拖动把手（样式先例 manga_config_sheet.dart：outlineVariant）
          Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                // 参考版 chapter_list_size：目录(N)，N = 章节数
                '目录(${chapters.length})',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
          // 章节列表（ListView.builder 虚拟化；章节数可超 1000）
          Flexible(
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
              itemCount: chapters.length,
              itemBuilder: (context, index) => _MangaCatalogTile(
                number: index + 1,
                title: chapters[index].title,
                isCurrent: index == currentIndex,
                onTap: () {
                  final navigator = Navigator.of(context);
                  onSelected(index);
                  navigator.pop();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 章节行（序号 + 标题；当前章高亮 = primaryContainer 底 + primary 文字）
class _MangaCatalogTile extends StatelessWidget {
  final int number;
  final String title;
  final bool isCurrent;
  final VoidCallback onTap;

  const _MangaCatalogTile({
    required this.number,
    required this.title,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: isCurrent
            ? BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              )
            : null,
        child: Row(
          children: [
            // 章节序号（右对齐 4 位宽，1000+ 章不挤占标题）
            SizedBox(
              width: 36,
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: 12,
                  color: isCurrent
                      ? scheme.primary
                      : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                textAlign: TextAlign.right,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                  color: isCurrent ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
