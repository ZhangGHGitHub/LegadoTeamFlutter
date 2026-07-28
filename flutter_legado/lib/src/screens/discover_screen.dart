import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/discover_provider.dart';
import '../routes.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 发现页面（首页 Tab）
///
/// 提供分类浏览、排行榜入口、推荐书源列表以及热门搜索建议。
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  /// 浏览分类（热门 / 新书 / 完结 + 题材标签）
  static const _browseCategories = [
    '热门',
    '新书',
    '完结',
    '玄幻',
    '都市',
    '科幻',
    '历史',
    '武侠',
    '悬疑',
    '游戏',
  ];

  /// 排行榜入口
  static const _rankings = [
    _RankingEntry('热搜榜', Icons.local_fire_department_rounded, 0xFFE57373),
    _RankingEntry('新书榜', Icons.auto_stories_rounded, 0xFF4FC3F7),
    _RankingEntry('完结榜', Icons.done_all_rounded, 0xFF81C784),
    _RankingEntry('飙升榜', Icons.trending_up_rounded, 0xFFFFB74D),
  ];

  /// 热门搜索建议
  static const _hotKeywords = [
    '凡人修仙传',
    '诡秘之主',
    '大奉打更人',
    '夜的命名术',
    '宿命之环',
    '道诡异仙',
  ];

  String _selectedCategory = '热门';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DiscoverProvider>().loadSources();
    });
  }

  void _openSearch() => Navigator.pushNamed(context, AppRoutes.search);

  void _searchKeyword(String keyword) {
    // 搜索页暂未支持预填关键词，先写入剪贴板再打开搜索
    Clipboard.setData(ClipboardData(text: keyword));
    Navigator.pushNamed(context, AppRoutes.search);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制「$keyword」，可粘贴搜索'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: _openSearch,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _buildSearchBar(theme),
          _buildSectionHeader(theme, '分类浏览'),
          _buildCategoryChips(theme),
          _buildSectionHeader(theme, '排行榜'),
          _buildRankings(theme),
          _buildSectionHeader(theme, '大家都在搜'),
          _buildHotKeywords(theme),
          _buildSectionHeader(theme, '推荐书源'),
          _buildRecommendedSources(theme),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: _openSearch,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.search, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Text(
                  '搜索书名、作者',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryChips(ThemeData theme) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _browseCategories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = _browseCategories[index];
          final selected = category == _selectedCategory;
          return ChoiceChip(
            label: Text(category),
            selected: selected,
            onSelected: (_) => setState(() => _selectedCategory = category),
          );
        },
      ),
    );
  }

  Widget _buildRankings(ThemeData theme) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _rankings.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final entry = _rankings[index];
          return _RankingCard(entry: entry, onTap: _openSearch);
        },
      ),
    );
  }

  Widget _buildHotKeywords(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _hotKeywords
            .map((keyword) => ActionChip(
                  avatar: const Icon(Icons.trending_up, size: 16),
                  label: Text(keyword),
                  onPressed: () => _searchKeyword(keyword),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildRecommendedSources(ThemeData theme) {
    final provider = context.watch<DiscoverProvider>();

    if (provider.loading && provider.recommended.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: LoadingIndicator(),
      );
    }

    if (provider.error != null && provider.recommended.isEmpty) {
      return SizedBox(
        height: 200,
        child: ErrorView(
          message: provider.error!,
          onRetry: () => provider.loadSources(),
        ),
      );
    }

    final sources = provider.recommended;
    if (sources.isEmpty) {
      return const SizedBox(
        height: 200,
        child: EmptyState(
          icon: Icons.explore_outlined,
          title: '暂无推荐书源',
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (final source in sources)
            _RecommendedSourceTile(
              source: source,
              installed: provider.isInstalled(source.source.bookSourceUrl),
              onInstall: () => _install(provider, source),
            ),
        ],
      ),
    );
  }

  Future<void> _install(
      DiscoverProvider provider, RecommendedSource source) async {
    final ok = await provider.installSource(source);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已安装：${source.name}' : '安装失败'),
        duration: const Duration(seconds: 1),
      ),
    );
  }
}

/// 排行榜入口数据
class _RankingEntry {
  final String title;
  final IconData icon;
  final int color;

  const _RankingEntry(this.title, this.icon, this.color);
}

/// 排行榜卡片
class _RankingCard extends StatelessWidget {
  final _RankingEntry entry;
  final VoidCallback onTap;

  const _RankingCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = Color(entry.color);
    return SizedBox(
      width: 132,
      child: Material(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(entry.icon, color: color, size: 28),
                Text(
                  entry.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color.withValues(alpha: 0.95),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 推荐书源条目
class _RecommendedSourceTile extends StatelessWidget {
  final RecommendedSource source;
  final bool installed;
  final VoidCallback onInstall;

  const _RecommendedSourceTile({
    required this.source,
    required this.installed,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _iconFor(source.category),
                color: colorScheme.onPrimaryContainer,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    source.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            installed
                ? Icon(Icons.check_circle, color: colorScheme.primary, size: 22)
                : FilledButton.tonal(
                    onPressed: onInstall,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('安装'),
                  ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String category) {
    switch (category) {
      case '精选':
        return Icons.star_rounded;
      case '小说':
        return Icons.menu_book_rounded;
      case '漫画':
        return Icons.image_rounded;
      case '新闻':
        return Icons.article_rounded;
      default:
        return Icons.source_rounded;
    }
  }
}
