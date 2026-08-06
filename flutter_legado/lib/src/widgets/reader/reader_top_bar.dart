import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import 'reader_settings_sheet.dart';

/// 阅读器顶部工具栏
///
/// 对齐安卓原版 ReadMenu 顶部 TitleBar 与 book_read.xml 菜单：
/// 返回键 + 书名 + 阅读进度百分比 + 换源/刷新/缓存（在线书）
/// + 夜间模式 + 正文搜索 + 书签 + 溢出菜单（高级设置等）
class ReaderTopBar extends ConsumerWidget {
  final VoidCallback onOpenContentSearch;
  final VoidCallback onAddBookmark;
  final VoidCallback onOpenAdvancedConfig;

  const ReaderTopBar({
    super.key,
    required this.onOpenContentSearch,
    required this.onAddBookmark,
    required this.onOpenAdvancedConfig,
  });

  void _todo(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」后续版本支持')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final isDark = state.isDarkBackground;
    final progressPct = (state.readingProgress * 100).toStringAsFixed(1);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        // iOS 风格：无阴影 + hairline 底边
        elevation: 0,
        shape: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerTheme.color ??
                Theme.of(context).dividerColor,
            width: 0.0,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    state.currentBook?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // 阅读进度百分比
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '$progressPct%',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                // 安卓原版 book_read.xml：换源/刷新/缓存（menu_group_on_line）
                if (state.currentBook != null) ...[
                  IconButton(
                    icon: const Icon(Icons.swap_horiz),
                    tooltip: '换源',
                    onPressed: () => Navigator.pushNamed(
                      context,
                      AppRoutes.changeSource,
                      arguments: state.currentBook,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新',
                    onPressed: () async {
                      final book = state.currentBook;
                      if (book == null) return;
                      await notifier.openBook(book);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已刷新')),
                        );
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.download_outlined),
                    tooltip: '缓存',
                    onPressed: () => _todo(context, '离线缓存'),
                  ),
                ],
                // 夜间模式快速切换
                IconButton(
                  icon: Icon(
                    isDark ? Icons.light_mode : Icons.dark_mode,
                  ),
                  tooltip: isDark ? '日间模式' : '夜间模式',
                  onPressed: () {
                    notifier.updateBackgroundColor(
                      isDark ? ReaderBackground.white : ReaderBackground.dark,
                    );
                  },
                ),
                // 正文搜索
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '搜索正文',
                  onPressed: onOpenContentSearch,
                ),
                // 书签按钮
                IconButton(
                  icon: const Icon(Icons.bookmark_add_outlined),
                  tooltip: '添加书签',
                  onPressed: onAddBookmark,
                ),
                // 安卓原版：溢出菜单（book_read.xml never 项）
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    switch (value) {
                      case 'advanced':
                        onOpenAdvancedConfig();
                        break;
                      case 'highlightRule':
                        // 对标原版 ReadMenu → HighlightRuleActivity
                        Navigator.pushNamed(context, AppRoutes.highlightRules);
                        break;
                      case 'pageAnim':
                        // [UI-fix v2.0.1 | 2026-08-06] 翻页动画接阅读设置面板
                        // （面板内含翻页模式设置，对标原版 ReadStyleDialog） — Qoder
                        ReaderSettingsSheet.show(context);
                        break;
                      case 'log':
                        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
                        Navigator.pushNamed(context, AppRoutes.appLog);
                        break;
                      default:
                        const names = {
                          'editContent': '编辑内容',
                          'reverseContent': '反转内容',
                          'simulatedReading': '模拟追读',
                          'enableReplace': '替换规则',
                          'reSegment': '重新分段',
                          'imageStyle': '图片样式',
                          'updateToc': '更新目录',
                          'help': '帮助',
                        };
                        _todo(context, names[value] ?? value);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'advanced',
                      child: Text('高级设置'),
                    ),
                    const PopupMenuItem(
                      value: 'highlightRule',
                      child: Text('高亮规则'),
                    ),
                    const PopupMenuItem(
                      value: 'editContent',
                      child: Text('编辑内容'),
                    ),
                    const PopupMenuItem(value: 'pageAnim', child: Text('翻页动画')),
                    const PopupMenuItem(
                      value: 'reverseContent',
                      child: Text('反转内容'),
                    ),
                    const PopupMenuItem(
                      value: 'simulatedReading',
                      child: Text('模拟追读'),
                    ),
                    const PopupMenuItem(
                      value: 'enableReplace',
                      child: Text('替换规则'),
                    ),
                    const PopupMenuItem(value: 'reSegment', child: Text('重新分段')),
                    const PopupMenuItem(
                      value: 'imageStyle',
                      child: Text('图片样式'),
                    ),
                    const PopupMenuItem(value: 'updateToc', child: Text('更新目录')),
                    const PopupMenuItem(value: 'log', child: Text('日志')),
                    const PopupMenuItem(value: 'help', child: Text('帮助')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
