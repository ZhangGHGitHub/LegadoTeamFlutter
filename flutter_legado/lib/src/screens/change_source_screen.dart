import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/change_source/change_source_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 换源页面 — 搜索替代书源并切换
///
/// 通过 [ChangeSourceNotifier] 经 BookApi 调用 Rust 后端的换源匹配器
/// （`searchSource` / `switchSource`），在所有启用的书源中搜索同名书籍，
/// 按匹配度评分排序（Rust 侧完成），用户选择后切换书籍来源。
///
/// 架构说明（对齐 UI_RESTRUCTURE_PLAN.md §0.2）：本页面不直接调用 bridge/FFI，
/// 全部经 [ChangeSourceNotifier] → BookApi 委托 Rust。
class ChangeSourceScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 以下字段为向后兼容保留，当未传入 Book 对象时使用
  final String bookUrl;
  final String bookName;
  final String author;
  final String currentSourceUrl;

  const ChangeSourceScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.bookName = '',
    this.author = '',
    this.currentSourceUrl = '',
  });

  /// 获取有效的 bookUrl
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  /// 获取有效的书名
  String get effectiveBookName => book?.name ?? bookName;

  /// 获取有效的作者
  String get effectiveAuthor => book?.author ?? author;

  /// 获取有效的当前书源地址
  String get effectiveCurrentSourceUrl => book?.origin ?? currentSourceUrl;

  @override
  ConsumerState<ChangeSourceScreen> createState() => _ChangeSourceScreenState();
}

class _ChangeSourceScreenState extends ConsumerState<ChangeSourceScreen> {
  // [UI-fix v2.0.2 | 2026-08-06] 换源页高级选项（对标原版 change_source.xml：
  // 搜索筛选/停止刷新切换/书源管理入口/刷新列表/校验作者开关/加载字数开关/
  // 加载信息开关/加载目录开关/源分组单选/关闭）；开关项持久化于 config，
  // 键名对齐原版 AppConfig — Qoder
  final _searchFilterCtrl = TextEditingController();
  bool _searchFilterVisible = false;
  String _searchFilter = '';
  bool _stopped = false;
  bool _checkAuthor = false;
  bool _loadWordCount = false;
  bool _loadInfo = false;
  bool _loadToc = false;
  String _searchGroup = '';
  List<String> _groups = const [];

  @override
  void initState() {
    super.initState();
    _loadAdvancedOptions();
    // 进入页面自动搜索一次
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _searchFilterCtrl.dispose();
    super.dispose();
  }

  /// 恢复高级开关持久化状态与源分组列表
  Future<void> _loadAdvancedOptions() async {
    final api = ref.read(bookApiProvider);
    try {
      final results = await Future.wait([
        api.getConfig('changeSourceCheckAuthor'),
        api.getConfig('changeSourceLoadWordCount'),
        api.getConfig('changeSourceLoadInfo'),
        api.getConfig('changeSourceLoadToc'),
        api.getConfig('searchGroup'),
      ]);
      if (mounted) {
        setState(() {
          _checkAuthor = results[0] == 'true';
          _loadWordCount = results[1] == 'true';
          _loadInfo = results[2] == 'true';
          _loadToc = results[3] == 'true';
          _searchGroup = results[4] ?? '';
        });
      }
    } catch (_) {}
    try {
      // 源分组从启用书源的 bookSourceGroup 字段聚合（对标原版
      // flowEnabledGroups），逗号分隔多分组展开
      final sources = await api.getBookSources();
      final groups = <String>{};
      for (final s in sources) {
        if (!s.enabled) continue;
        final g = s.bookSourceGroup ?? '';
        if (g.trim().isEmpty) continue;
        groups.addAll(
          g.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty),
        );
      }
      if (mounted) setState(() => _groups = groups.toList()..sort());
    } catch (_) {}
  }

  /// 开关项持久化（键名对齐原版 AppConfig；TODO: 待 Rust 匹配器
  /// searchSource 读取这些 config 后全链生效）— Qoder
  Future<void> _persistBool(String key, bool value) async {
    try {
      await ref.read(bookApiProvider).setConfig(key, value ? 'true' : 'false');
    } catch (_) {}
  }

  /// 搜索可替换书源
  ///
  /// [UI-fix v2.0.3 | 2026-08-06] 留项#12（Task #131）：传入当前选中分组，
  /// 分组过滤全链生效（Rust sourceSwitchSearch 的 sourceUrlsJson） — Qoder
  /// [UI-fix v2.0.3 | 2026-08-08] 留项#12（Task #145）：Rust 侧已原生读取
  /// searchGroup config 过滤；搜索完成后分组过滤零结果时弹
  /// 「是否切换到全部分组」对话框（对标 ChangeChapterSourceDialog L90-97） — Qoder
  Future<void> _search() async {
    await ref
        .read(changeSourceNotifierProvider.notifier)
        .search(
          widget.effectiveBookName,
          widget.effectiveAuthor,
          group: _searchGroup,
        );
    if (!mounted) return;
    final state = ref.read(changeSourceNotifierProvider);
    if (state.error == null &&
        state.results.isEmpty &&
        _searchGroup.isNotEmpty) {
      _showEmptyGroupResultDialog();
    }
  }

  /// [UI-fix v2.0.3 | 2026-08-08] 分组搜索结果为空对话框（Task #145，对标原版
  /// ChangeChapterSourceDialog L90-97：「xx分组搜索结果为空,是否切换到全部分组」，
  /// 确认后清空 searchGroup config 并重搜） — Qoder
  Future<void> _showEmptyGroupResultDialog() async {
    final group = _searchGroup;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索结果为空'),
        content: Text('$group分组搜索结果为空，是否切换到全部分组'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _searchGroup = '');
    try {
      await ref.read(bookApiProvider).setConfig('searchGroup', '');
    } catch (_) {}
    if (mounted && !_stopped) await _search();
  }

  /// 应用选中的书源
  Future<void> _applySource(SourceMatch result) async {
    // 已有切换进行中时不再重复触发
    if (ref.read(changeSourceNotifierProvider).isApplying) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换书源'),
        content: Text('确定要将本书切换到「${result.sourceName}」吗？\n'
            '切换后将重新获取目录与章节内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final newBookUrl = await ref
          .read(changeSourceNotifierProvider.notifier)
          .applySource(result, bookUrl: widget.effectiveBookUrl);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到「${result.sourceName}」')),
      );
      Navigator.pop(context, newBookUrl);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('换源失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(changeSourceNotifierProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('换源 - ${widget.effectiveBookName}'),
        actions: [
          // [UI-fix v2.0.2 | 2026-08-06] 搜索筛选入口（对标 menu_screen）— Qoder
          IconButton(
            icon: Icon(
              _searchFilter.isNotEmpty
                  ? Icons.filter_alt
                  : Icons.search,
            ),
            tooltip: '搜索筛选',
            onPressed: () => setState(
              () => _searchFilterVisible = !_searchFilterVisible,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新搜索',
            onPressed: state.isLoading || _stopped ? null : _search,
          ),
          // [UI-fix v2.0.2 | 2026-08-06] 高级选项菜单（对标 change_source.xml）— Qoder
          PopupMenuButton<String>(
            tooltip: '高级选项',
            onSelected: _handleAdvancedMenu,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'startStop',
                child: _menuRow(
                  icon: _stopped ? Icons.play_arrow : Icons.stop,
                  label: _stopped ? '继续刷新' : '停止刷新',
                ),
              ),
              PopupMenuItem(
                value: 'sourceManage',
                child: _menuRow(icon: Icons.settings, label: '书源管理'),
              ),
              PopupMenuItem(
                value: 'refreshList',
                child: _menuRow(icon: Icons.refresh, label: '刷新列表'),
              ),
              PopupMenuItem(
                value: 'checkAuthor',
                child: _menuRow(
                  icon: _checkAuthor ? Icons.check_box : Icons.check_box_outline_blank,
                  label: '校验作者',
                ),
              ),
              PopupMenuItem(
                value: 'loadWordCount',
                child: _menuRow(
                  icon: _loadWordCount
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  label: '加载字数',
                ),
              ),
              PopupMenuItem(
                value: 'loadInfo',
                child: _menuRow(
                  icon: _loadInfo ? Icons.check_box : Icons.check_box_outline_blank,
                  label: '加载信息',
                ),
              ),
              PopupMenuItem(
                value: 'loadToc',
                child: _menuRow(
                  icon: _loadToc ? Icons.check_box : Icons.check_box_outline_blank,
                  label: '加载目录',
                ),
              ),
              PopupMenuItem(
                value: 'group',
                child: _menuRow(
                  icon: Icons.group_work,
                  label: _searchGroup.isEmpty
                      ? '源分组：全部'
                      : '源分组：$_searchGroup',
                ),
              ),
              const PopupMenuItem(
                value: 'close',
                child: _MenuRowStatic(icon: Icons.close, label: '关闭'),
              ),
            ],
          ),
        ],
        bottom: _searchFilterVisible
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    controller: _searchFilterCtrl,
                    onChanged: (v) => setState(() => _searchFilter = v.trim()),
                    decoration: InputDecoration(
                      hintText: '按书源名称筛选',
                      isDense: true,
                      filled: true,
                      fillColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              )
            : null,
      ),
      body: _buildBody(state),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isLoading || _stopped ? null : _search,
        icon: const Icon(Icons.search),
        label: const Text('搜索'),
      ),
    );
  }

  /// 菜单行（动态勾选态）
  Widget _menuRow({required IconData icon, required String label}) =>
      _MenuRowStatic(icon: icon, label: label);

  /// 高级选项菜单分发（对标 change_source.xml 各 menu 项）
  Future<void> _handleAdvancedMenu(String value) async {
    switch (value) {
      case 'startStop':
        // 对标 menu_start_stop：停止/继续刷新（会话态，不持久化）
        setState(() => _stopped = !_stopped);
      case 'sourceManage':
        // 对标 menu_source_manage → SourceActivity
        Navigator.pushNamed(context, AppRoutes.sources);
      case 'refreshList':
        // 对标 menu_refresh_list：重新搜索并刷新列表
        if (!_stopped) await _search();
      case 'checkAuthor':
        // 对标 menu_check_author（AppConfig.changeSourceCheckAuthor）
        setState(() => _checkAuthor = !_checkAuthor);
        _persistBool('changeSourceCheckAuthor', _checkAuthor);
      case 'loadWordCount':
        // 对标 menu_load_word_count（AppConfig.changeSourceLoadWordCount）
        setState(() => _loadWordCount = !_loadWordCount);
        _persistBool('changeSourceLoadWordCount', _loadWordCount);
      case 'loadInfo':
        // 对标 menu_load_info（AppConfig.changeSourceLoadInfo）
        setState(() => _loadInfo = !_loadInfo);
        _persistBool('changeSourceLoadInfo', _loadInfo);
      case 'loadToc':
        // 对标 menu_load_toc（AppConfig.changeSourceLoadToc）
        setState(() => _loadToc = !_loadToc);
        _persistBool('changeSourceLoadToc', _loadToc);
      case 'group':
        await _showGroupPicker();
      case 'close':
        // 对标 menu_close
        if (mounted) Navigator.pop(context);
    }
  }

  /// 源分组单选（对标 menu_group/source_group：AppConfig.searchGroup，
  /// 留项#12 已于 Task #131 闭合：选中后按分组过滤重搜全链生效）— Qoder
  Future<void> _showGroupPicker() async {
    final selected = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('源分组'),
        children: [
          _groupRadio(ctx, '', '全部'),
          for (final g in _groups) _groupRadio(ctx, g, g),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _searchGroup = selected);
    try {
      await ref.read(bookApiProvider).setConfig('searchGroup', selected);
    } catch (_) {}
    if (!_stopped) await _search();
  }

  Widget _groupRadio(BuildContext ctx, String value, String label) {
    final isSelected = _searchGroup == value;
    return ListTile(
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: isSelected ? Theme.of(ctx).colorScheme.primary : null,
      ),
      title: Text(label),
      onTap: () => Navigator.pop(ctx, value),
    );
  }

  Widget _buildBody(ChangeSourceState state) {
    // [UI-fix v2.0.2 | 2026-08-06] 搜索筛选（对标 menu_screen SearchView：
    // 客户端按书源名/书名关键字过滤结果列表）— Qoder
    var results = state.results;
    if (_searchFilter.isNotEmpty) {
      results = results
          .where(
            (r) =>
                r.sourceName.contains(_searchFilter) ||
                r.bookName.contains(_searchFilter),
          )
          .toList();
    }
    if (state.isLoading && results.isEmpty) {
      return const LoadingIndicator(message: '正在搜索可替换书源...');
    }
    if (state.error != null && results.isEmpty) {
      return ErrorView(message: state.error!, onRetry: _search);
    }
    if (results.isEmpty) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text('未找到可替换的书源',
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 16)),
            const SizedBox(height: 4),
            Text('请确认已启用足够的书源后重试',
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _search,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.isLoading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '找到 ${results.length} 个匹配书源（按匹配度排序）',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildResultTile(context, results[index], state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultTile(
    BuildContext context,
    SourceMatch item,
    ChangeSourceState state,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final isCurrent = item.sourceUrl == widget.effectiveCurrentSourceUrl;
    final isApplying = state.applyingUrl == item.sourceUrl;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: _scoreColor(item.score).withValues(alpha: 0.15),
        child: Text(
          item.score.toStringAsFixed(0),
          style: TextStyle(
            color: _scoreColor(item.score),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              item.sourceName.isEmpty ? '未知书源' : item.sourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isCurrent ? colorScheme.primary : null,
              ),
            ),
          ),
          if (isCurrent) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '当前',
                style: TextStyle(
                  fontSize: 10,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.latestChapter != null && item.latestChapter!.isNotEmpty)
            Text(
              '最新：${item.latestChapter}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          if (item.wordCount != null && item.wordCount!.isNotEmpty)
            Text(
              item.wordCount!,
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
        ],
      ),
      trailing: isCurrent
          ? const Icon(Icons.check_circle, size: 20)
          : isApplying
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.chevron_right, color: colorScheme.outline),
      enabled: !isCurrent && !state.isApplying,
      onTap: () => _applySource(item),
    );
  }

  /// 根据匹配度评分返回对应颜色
  Color _scoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 50) return Colors.orange;
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }
}

/// [UI-fix v2.0.2 | 2026-08-06] 菜单行（图标 + 文案） — Qoder
class _MenuRowStatic extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRowStatic({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}
