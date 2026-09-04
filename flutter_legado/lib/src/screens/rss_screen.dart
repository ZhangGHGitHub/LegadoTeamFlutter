import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/rss/rss_notifier.dart';
import '../providers/rss_history/rss_history_notifier.dart';
import '../routes.dart';
import '../utils/responsive.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_articles_screen.dart';
import 'rss_article_detail_screen.dart';

/// RSS 源列表页面
class RssScreen extends ConsumerStatefulWidget {
  const RssScreen({super.key});

  @override
  ConsumerState<RssScreen> createState() => _RssScreenState();
}

class _RssScreenState extends ConsumerState<RssScreen> {
  /// 顶栏搜索框（对齐安卓原版 fragment_rss.xml 的 view_search：
  /// 实时按名称/URL 过滤已启用订阅源）
  final _searchController = TextEditingController();
  String _searchKey = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssNotifierProvider.notifier).loadSources();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 在分组过滤基础上叠加搜索过滤（对标原版 flowEnabled(searchKey)）
  List<RssSource> _applySearch(List<RssSource> sources) {
    final key = _searchKey.trim().toLowerCase();
    if (key.isEmpty) return sources;
    return sources
        .where((s) =>
            s.sourceName.toLowerCase().contains(key) ||
            s.sourceUrl.toLowerCase().contains(key))
        .toList();
  }

  void _confirmDeleteSource(RssSource source) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除 RSS 源'),
        content: Text('确定要删除「${source.sourceName}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              ref.read(rssNotifierProvider.notifier).removeSource(source.sourceUrl);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssNotifierProvider);
    final notifier = ref.read(rssNotifierProvider.notifier);
    return Scaffold(
      appBar: LegadoAppBar(
        // 对标原版 view_search.xml：TitleBar 内嵌胶囊搜索框（hint「订阅」），
        // 与右侧 4 个图标入口同行，无标题文字
        title: SizedBox(
          height: 36,
          child: TextField(
            controller: _searchController,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            decoration: InputDecoration(
              // 安卓原版 queryHint = 订阅
              hintText: AppStrings.rss,
              hintStyle: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              prefixIcon: Icon(Symbols.search_rounded,
                  size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
              suffixIcon: _searchKey.isNotEmpty
                  ? IconButton(
                      icon: Icon(Symbols.close_rounded,
                          size: 18,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchKey = '');
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(35),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (value) => setState(() => _searchKey = value),
          ),
        ),
        actions: [
          // 安卓原版顶栏 4 个功能入口：阅读记录/收藏/分组/订阅源管理
          // （原版 menu_read_record 打开阅读记录对话框，非独立页面）
          IconButton(
            icon: const Icon(Symbols.history_rounded),
            tooltip: '阅读记录',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const _ReadRecordDialog(),
            ),
          ),
          IconButton(
            icon: const Icon(Symbols.star_rounded),
            tooltip: '收藏',
            onPressed: () => Navigator.pushNamed(context, AppRoutes.rssFavorites),
          ),
          // 分组筛选：对齐原版 RssFragment 的分组菜单（ic_groups 图标，linkedSetOf 保序聚合）
          PopupMenuButton<String?>(
            tooltip: '分组',
            icon: const Icon(Symbols.groups_rounded),
            onSelected: (group) => notifier.setGroup(group),
            itemBuilder: (context) => [
              const PopupMenuItem<String?>(
                value: null,
                child: Text('全部'),
              ),
              for (final group in state.groups)
                PopupMenuItem<String?>(
                  value: group,
                  child: Text(group),
                ),
            ],
          ),
          // 原版 menu_rss_config：齿轮图标即订阅源管理入口，
          // 返回后刷新源列表
          IconButton(
            icon: const Icon(Symbols.settings_rounded),
            tooltip: '订阅源管理',
            onPressed: () async {
              await Navigator.pushNamed(context, AppRoutes.rssSourceManage);
              if (mounted) notifier.loadSources();
            },
          ),
        ],
      ),
      // 安卓原版无 FAB：添加订阅源入口在订阅源管理页（对标 RssSourceActivity 菜单）
      body: Builder(
        builder: (context) {
          if (state.isLoadingSources && state.sources.isEmpty) {
            return const LoadingIndicator(message: '加载 RSS 源...');
          }

          if (state.error != null && state.sources.isEmpty) {
            return ErrorView(
              message: state.error!,
              onRetry: () => notifier.loadSources(),
            );
          }

          // 「规则订阅」入口格常驻（对标原版 header）；空态时网格仍在，
          // tvEmptyMsg 叠在 RecyclerView 中央（fragment_rss.xml）
          final displaySources = _applySearch(state.filteredSources);
          final emptyMsg = state.isEmpty
              ? '当前没有订阅源！'
              : (displaySources.isEmpty ? '当前分组暂无订阅源' : null);

          return RefreshIndicator(
            onRefresh: () => notifier.loadSources(),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    Responsive.rssGridColumnsForWidth(constraints.maxWidth);
                final aspectRatio =
                    Responsive.rssGridChildAspectRatio(constraints.maxWidth);
                return Stack(
                  children: [
                    GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                      // 空态也允许下拉刷新（AlwaysScrollable）
                      physics: const AlwaysScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        childAspectRatio: aspectRatio,
                        // [LAYOUT_MOTION_AUDIT L3] 网格间距统一 12dp
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: displaySources.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) return _buildRuleSubEntry(context);
                        final source = displaySources[index - 1];
                        return _buildSourceItem(context, source);
                      },
                    ),
                    if (emptyMsg != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: EmptyState(
                            icon: Symbols.rss_feed_rounded,
                            title: emptyMsg,
                            simple: true,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 打开订阅源（对标 RssFragment.openRss：singleUrl → 阅读页/外链，否则文章列表）
  Future<void> _openRss(RssSource source) async {
    if (!source.singleUrl) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RssArticlesScreen(source: source),
        ),
      );
      return;
    }
    final url = source.sourceUrl.trim();
    if (url.toLowerCase().startsWith('http://') ||
        url.toLowerCase().startsWith('https://')) {
      if (!mounted) return;
      await Navigator.pushNamed(
        context,
        AppRoutes.browser,
        arguments: url,
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// 「规则订阅」入口格（对标原版 RssFragment header：图标 + 文字，
  /// 点击进入 RuleSubActivity 对应页）
  Widget _buildRuleSubEntry(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return RepaintBoundary(
      child: InkWell(
        key: const ValueKey('rule_sub_entry'),
        onTap: () => Navigator.pushNamed(context, AppRoutes.ruleSub),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.all(
            Responsive.isCompact(MediaQuery.sizeOf(context).width) ? 12 : 16,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.10),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Symbols.subscriptions_rounded,
                    size: 26,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              // 间距收紧至 8：为字体放大场景预留两行文本空间，
              // 避免入口格内容溢出网格单元
              const SizedBox(height: 8),
              Text(
                '规则订阅',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 安卓端 item_rss.xml 样式：居中图标(50x50 圆角12dp) + 名称(13sp 居中 最多2行)
  Widget _buildSourceItem(BuildContext context, RssSource source) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // 稳定 ValueKey（sourceUrl）+ RepaintBoundary 隔离网格项重绘区域
    final item = InkWell(
      key: ValueKey(source.sourceUrl),
      onTap: () => _openRss(source),
      onLongPress: () => _confirmDeleteSource(source),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        // 安卓端 item 内边距 16dp；窄屏缩至 12dp 防溢出
        padding: EdgeInsets.all(
          Responsive.isCompact(MediaQuery.sizeOf(context).width) ? 12 : 16,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 图标：50x50 圆角12dp（安卓端 FilletImageView radius=12dp）
            // iOS 风格：圆角图标 + 柔和阴影，类似主屏 App 图标
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.10),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: source.sourceIcon.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: source.sourceIcon,
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        // 限制解码宽度为图标实际显示像素宽度（50），避免大图解码
                        memCacheWidth: (50 *
                                (MediaQuery.maybeOf(context)?.devicePixelRatio ??
                                    1.0))
                            .round(),
                        placeholder: (_, _) => _buildPlaceholderIcon(
                            context, source, colorScheme),
                        errorWidget: (_, _, _) => _buildPlaceholderIcon(
                            context, source, colorScheme),
                      )
                    : _buildPlaceholderIcon(context, source, colorScheme),
              ),
            ),
            // 名称：安卓端 marginTop=16dp, 13sp, secondaryText, 居中, 最多2行
            const SizedBox(height: 16),
            Text(
              source.sourceName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
    return RepaintBoundary(child: item);
  }

  /// 占位图标：显示源名称首字母（iOS 风格柔和填充底）
  Widget _buildPlaceholderIcon(
      BuildContext context, RssSource source, ColorScheme colorScheme) {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Text(
          source.sourceName.isNotEmpty
              ? source.sourceName[0].toUpperCase()
              : 'R',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}

/// 阅读记录对话框（对标原版 ReadRecordDialog：
/// 标题「阅读记录」+ 清除菜单 + 记录列表；点击条目重读并关闭对话框）
class _ReadRecordDialog extends ConsumerStatefulWidget {
  const _ReadRecordDialog();

  @override
  ConsumerState<_ReadRecordDialog> createState() => _ReadRecordDialogState();
}

class _ReadRecordDialogState extends ConsumerState<_ReadRecordDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssHistoryNotifierProvider.notifier).load();
    });
  }

  /// 清除确认（对标原版：sure_del + 记录数 + read_record）
  Future<void> _confirmClear() async {
    final count = ref.read(rssHistoryNotifierProvider).records.length;
    final confirmed = await showConfirmDialog(
      context,
      title: '提示',
      content: '确定要删除？\n$count 条阅读记录',
      confirmText: '删除',
      isDestructive: true,
    );
    if (confirmed && mounted) {
      await ref.read(rssHistoryNotifierProvider.notifier).clear();
    }
  }

  /// 点击记录重读（对标原版 ReadRss.readRss：打开文章阅读页）
  void _openRecord(RssReadRecordRow record) {
    Navigator.of(context).pop(); // 对标原版点击后 dismiss
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RssArticleDetailScreen(
          article: RssFeedArticle(title: record.title, url: record.link ?? ''),
          sourceName: _hostOf(record.origin),
        ),
      ),
    );
  }

  String _hostOf(String origin) {
    final uri = Uri.tryParse(origin);
    return uri?.host.isNotEmpty == true ? uri!.host : origin;
  }

  String _formatTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} '
        '${pad(dt.hour)}:${pad(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssHistoryNotifierProvider);
    final colorScheme = Theme.of(context).colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏（对标原版 toolBar：阅读记录 + 清除菜单）
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '阅读记录',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  TextButton(
                    onPressed: (state.records.isEmpty || state.isClearing)
                        ? null
                        : _confirmClear,
                    child: Text(
                      '清除',
                      style: TextStyle(
                        color: (state.records.isEmpty || state.isClearing)
                            ? colorScheme.onSurfaceVariant
                            : colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(child: _buildList(state)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(RssHistoryState state) {
    // 注意：空态/加载分支不能用 Center（Align 在 loose 约束下会撑满
    // 可用高度，导致对话框被拉至 maxHeight），用 Column(min) 收缩
    if (state.isLoading || state.isClearing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [CircularProgressIndicator()],
        ),
      );
    }
    if (state.records.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('暂无阅读记录', style: TextStyle(fontSize: 14)),
          ],
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: state.records.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, index) {
        final record = state.records[index];
        final time = _formatTime(record.readTime);
        return InkWell(
          onTap: () => _openRecord(record),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.title.isEmpty ? '(无标题)' : record.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  time.isEmpty
                      ? _hostOf(record.origin)
                      : '${_hostOf(record.origin)}  ·  $time',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
