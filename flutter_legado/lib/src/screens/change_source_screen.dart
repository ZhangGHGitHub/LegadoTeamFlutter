import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../bridge/ffi.dart' show BridgeError;
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
  final _scrollController = ScrollController();
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
    _scrollController.dispose();
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
      // flowEnabledGroups）；[审计 D1] 分组分隔符全集 ,;，；，对齐原版
      // splitGroupRegex（仅英文逗号会漏分号分组的组名）
      final sources = await api.getBookSources();
      final groups = <String>{};
      for (final s in sources) {
        if (!s.enabled) continue;
        final g = s.bookSourceGroup ?? '';
        if (g.trim().isEmpty) continue;
        groups.addAll(
          g
              .split(RegExp(r'[,;，；]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty),
        );
      }
      if (mounted) setState(() => _groups = groups.toList()..sort());
    } catch (_) {}
  }

  /// 开关项持久化（键名对齐原版 AppConfig）
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
  ///
  /// [forceRefresh] false（进入页默认）：优先复用搜索阶段写入的 searchBooks
  /// （对齐原版 getDbSearchBooks）；true（刷新列表）：强制网络重搜。
  Future<void> _search({bool forceRefresh = false}) async {
    await ref
        .read(changeSourceNotifierProvider.notifier)
        .search(
          widget.effectiveBookName,
          widget.effectiveAuthor,
          group: _searchGroup,
          loadInfo: _loadInfo,
          loadToc: _loadToc,
          loadWordCount: _loadWordCount,
          forceRefresh: forceRefresh,
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
  Future<void> _applySource(
    SourceMatch result, {
    bool skipConfirm = false,
  }) async {
    // 已有切换进行中时不再重复触发
    if (ref.read(changeSourceNotifierProvider).isApplying) return;

    if (!skipConfirm) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('切换书源'),
          content: Text(
            '确定要将本书切换到「${result.sourceName}」吗？\n'
            '切换后将重新获取目录与章节内容。',
          ),
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
    }

    try {
      final newBookUrl = await ref
          .read(changeSourceNotifierProvider.notifier)
          .applySource(result, bookUrl: widget.effectiveBookUrl);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已切换到「${result.sourceName}」')));
      Navigator.pop(context, newBookUrl);
    } catch (e) {
      if (!mounted) return;
      // [fix Task#24 | 2026-08-08] BridgeError 未重写 toString，直接内插得到
      // 无信息的「Instance of 'BridgeError'」。改用 .message 暴露 Rust 侧真实
      // 错误（如「新书源未解析到任何章节」），便于用户与排查 — Qoder
      final msg = e is BridgeError ? e.message : e.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('换源失败: $msg')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(changeSourceNotifierProvider);
    final results = _filteredResults(state);
    return Scaffold(
      appBar: LegadoAppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.effectiveBookName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (widget.effectiveAuthor.isNotEmpty)
              Text(
                widget.effectiveAuthor,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          // [UI-fix v2.0.2 | 2026-08-06] 搜索筛选入口（对标 menu_screen）— Qoder
          IconButton(
            icon: Icon(
              _searchFilter.isNotEmpty ? Symbols.filter_alt_rounded : Symbols.search_rounded,
            ),
            tooltip: '搜索筛选',
            onPressed: () =>
                setState(() => _searchFilterVisible = !_searchFilterVisible),
          ),
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            tooltip: '重新搜索',
            onPressed: state.isLoading || _stopped
                ? null
                : () => _search(forceRefresh: true),
          ),
          // [UI-fix v2.0.2 | 2026-08-06] 高级选项菜单（对标 change_source.xml）— Qoder
          PopupMenuButton<String>(
            tooltip: '高级选项',
            onSelected: _handleAdvancedMenu,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'startStop',
                child: _menuRow(
                  icon: _stopped ? Symbols.play_arrow_rounded : Symbols.stop_rounded,
                  label: _stopped ? '继续刷新' : '停止刷新',
                ),
              ),
              PopupMenuItem(
                value: 'sourceManage',
                child: _menuRow(icon: Symbols.settings_rounded, label: '书源管理'),
              ),
              PopupMenuItem(
                value: 'refreshList',
                child: _menuRow(icon: Symbols.refresh_rounded, label: '刷新列表'),
              ),
              PopupMenuItem(
                value: 'checkAuthor',
                child: _menuRow(
                  icon: _checkAuthor
                      ? Symbols.check_box_rounded
                      : Symbols.check_box_outline_blank_rounded,
                  label: '校验作者',
                ),
              ),
              PopupMenuItem(
                value: 'loadWordCount',
                child: _menuRow(
                  icon: _loadWordCount
                      ? Symbols.check_box_rounded
                      : Symbols.check_box_outline_blank_rounded,
                  label: '加载字数',
                ),
              ),
              PopupMenuItem(
                value: 'loadInfo',
                child: _menuRow(
                  icon: _loadInfo
                      ? Symbols.check_box_rounded
                      : Symbols.check_box_outline_blank_rounded,
                  label: '加载信息',
                ),
              ),
              PopupMenuItem(
                value: 'loadToc',
                child: _menuRow(
                  icon: _loadToc
                      ? Symbols.check_box_rounded
                      : Symbols.check_box_outline_blank_rounded,
                  label: '加载目录',
                ),
              ),
              PopupMenuItem(
                value: 'group',
                child: _menuRow(
                  icon: Symbols.group_work_rounded,
                  label: _searchGroup.isEmpty ? '源分组：全部' : '源分组：$_searchGroup',
                ),
              ),
              const PopupMenuItem(
                value: 'close',
                child: _MenuRowStatic(icon: Symbols.close_rounded, label: '关闭'),
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
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
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
      body: _buildBody(state, results),
      bottomNavigationBar: _buildBottomBar(state, results),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isLoading || _stopped
            ? null
            : () => _search(forceRefresh: true),
        icon: const Icon(Symbols.search_rounded),
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
        // 对标 menu_refresh_list：强制网络重搜（对齐 startSearch）
        if (!_stopped) await _search(forceRefresh: true);
      case 'checkAuthor':
        // 对标 menu_check_author（AppConfig.changeSourceCheckAuthor）
        setState(() => _checkAuthor = !_checkAuthor);
        _persistBool('changeSourceCheckAuthor', _checkAuthor);
      case 'loadWordCount':
        // 对标 menu_load_word_count（AppConfig.changeSourceLoadWordCount）
        setState(() => _loadWordCount = !_loadWordCount);
        await _persistBool('changeSourceLoadWordCount', _loadWordCount);
        if (_loadWordCount && !_stopped) await _search(forceRefresh: true);
      case 'loadInfo':
        // 对标 menu_load_info（AppConfig.changeSourceLoadInfo）
        setState(() => _loadInfo = !_loadInfo);
        await _persistBool('changeSourceLoadInfo', _loadInfo);
        if (_loadInfo && !_stopped) await _search(forceRefresh: true);
      case 'loadToc':
        // 对标 menu_load_toc（AppConfig.changeSourceLoadToc）
        setState(() => _loadToc = !_loadToc);
        await _persistBool('changeSourceLoadToc', _loadToc);
        if (_loadToc && !_stopped) await _search(forceRefresh: true);
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
    if (!_stopped) await _search(forceRefresh: true);
  }

  Widget _groupRadio(BuildContext ctx, String value, String label) {
    final isSelected = _searchGroup == value;
    return ListTile(
      leading: Icon(
        isSelected ? Symbols.radio_button_checked_rounded : Symbols.radio_button_unchecked_rounded,
        color: isSelected ? Theme.of(ctx).colorScheme.primary : null,
      ),
      title: Text(label),
      onTap: () => Navigator.pop(ctx, value),
    );
  }

  List<SourceMatch> _filteredResults(ChangeSourceState state) {
    var results = state.results;
    if (_searchFilter.isNotEmpty) {
      // [审计 D5 | ChangeBookSourceViewModel.kt:184] 原版筛选只按书名
      // contains，不含源名匹配
      results = results
          .where((r) => r.bookName.contains(_searchFilter))
          .toList();
    }
    return results;
  }

  SourceMatch? _currentSourceItem(List<SourceMatch> results) {
    for (final r in results) {
      if (r.sourceUrl == widget.effectiveCurrentSourceUrl) return r;
    }
    return null;
  }

  void _scrollToCurrentSource(List<SourceMatch> results) {
    final idx = results.indexWhere(
      (r) => r.sourceUrl == widget.effectiveCurrentSourceUrl,
    );
    if (idx < 0 || !_scrollController.hasClients) return;
    _scrollController.animateTo(
      idx * 72.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Widget _buildBottomBar(ChangeSourceState state, List<SourceMatch> results) {
    final colorScheme = Theme.of(context).colorScheme;
    final current = _currentSourceItem(results);
    final label = current?.sourceName.isNotEmpty == true
        ? current!.sourceName
        : (widget.effectiveCurrentSourceUrl.isNotEmpty
              ? widget.effectiveCurrentSourceUrl
              : '当前书源');

    return Material(
      elevation: 8,
      color: colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: results.isEmpty
                      ? null
                      : () => _scrollToCurrentSource(results),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Symbols.vertical_align_top_rounded),
                tooltip: '滚到顶部',
                onPressed: results.isEmpty
                    ? null
                    : () {
                        // hasClients 在布局 attach 后才为 true，须于点击时判定（构建时为 false）
                        if (_scrollController.hasClients) {
                          _scrollController.animateTo(
                            0,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        }
                      },
              ),
              IconButton(
                icon: const Icon(Symbols.vertical_align_bottom_rounded),
                tooltip: '滚到底部',
                onPressed: results.isEmpty
                    ? null
                    : () {
                        if (_scrollController.hasClients) {
                          _scrollController.animateTo(
                            _scrollController.position.maxScrollExtent,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onThumbUp(SourceMatch item) async {
    final newScore = item.bookScore > 0 ? 0 : 1;
    try {
      await ref
          .read(changeSourceNotifierProvider.notifier)
          .updateBookScore(item.bookUrl, newScore);
    } catch (e) {
      if (!mounted) return;
      final msg = e is BridgeError ? e.message : e.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('评分失败: $msg')));
    }
  }

  Future<void> _onThumbDown(SourceMatch item) async {
    final newScore = item.bookScore < 0 ? 0 : -1;
    try {
      await ref
          .read(changeSourceNotifierProvider.notifier)
          .updateBookScore(item.bookUrl, newScore);
    } catch (e) {
      if (!mounted) return;
      final msg = e is BridgeError ? e.message : e.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('评分失败: $msg')));
    }
  }

  Future<void> _showItemActions(SourceMatch item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Symbols.vertical_align_top_rounded),
              title: const Text('置顶'),
              onTap: () => Navigator.pop(ctx, 'top'),
            ),
            ListTile(
              leading: const Icon(Symbols.vertical_align_bottom_rounded),
              title: const Text('置底'),
              onTap: () => Navigator.pop(ctx, 'bottom'),
            ),
            ListTile(
              leading: const Icon(Symbols.edit_rounded),
              title: const Text('编辑书源'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Symbols.block_rounded),
              title: const Text('禁用书源'),
              onTap: () => Navigator.pop(ctx, 'disable'),
            ),
            ListTile(
              leading: Icon(
                Symbols.delete_rounded,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: Text(
                '删除',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    final notifier = ref.read(changeSourceNotifierProvider.notifier);
    switch (action) {
      case 'top':
        notifier.moveToTop(item.bookUrl);
      case 'bottom':
        notifier.moveToBottom(item.bookUrl);
      case 'edit':
        Navigator.pushNamed(context, AppRoutes.sources);
      case 'disable':
        try {
          await notifier.disableAndRemove(item);
        } catch (e) {
          if (!mounted) return;
          final msg = e is BridgeError ? e.message : e.toString();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('禁用失败: $msg')));
        }
      case 'delete':
        await _confirmDeleteItem(item);
    }
  }

  Future<void> _confirmDeleteItem(SourceMatch item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除「${item.sourceName}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final wasCurrent = item.bookUrl == widget.effectiveBookUrl;
    try {
      await ref
          .read(changeSourceNotifierProvider.notifier)
          .deleteSearchBookItem(item.bookUrl);
      if (!mounted) return;
      if (wasCurrent) {
        final next = ref.read(changeSourceNotifierProvider).results.firstOrNull;
        if (next != null) {
          await _applySource(next, skipConfirm: true);
        }
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e is BridgeError ? e.message : e.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败: $msg')));
    }
  }

  Widget _buildBody(ChangeSourceState state, List<SourceMatch> results) {
    if (state.isLoading && results.isEmpty) {
      // 体检 U1：Rust 换源搜索为一次性阻塞调用，流式 API（T6）落地前
      // 以「源数量 + 已等待时长」告知仍在进行，替代无反馈转圈
      return LoadingIndicator(
        message: null,
        subMessage: _SearchWaitMessage(count: state.searchingCount),
      );
    }
    if (state.error != null && results.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () {
          _search(forceRefresh: true);
        },
      );
    }
    if (results.isEmpty) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Symbols.search_off_rounded,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              '未找到可替换的书源',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '请确认已启用足够的书源后重试',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _search(forceRefresh: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.isLoading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              state.isLoading
                  ? '已找到 ${results.length} 个匹配书源，搜索中…'
                  : '找到 ${results.length} 个匹配书源',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              controller: _scrollController,
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
    final score = item.bookScore;
    final goodActive = score > 0;
    final badActive = score < 0;
    const goodColor = Color(0xFFFF5252); // Material Red A200
    const badColor = Color(0xFF448AFF); // Material Blue A200

    return InkWell(
      onTap: isCurrent || state.isApplying ? null : () => _applySource(item),
      onLongPress: () => _showItemActions(item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
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
                  if (item.latestChapter != null &&
                      item.latestChapter!.isNotEmpty)
                    Text(
                      '最新：${item.latestChapter}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (item.wordCount != null && item.wordCount!.isNotEmpty)
                    Text(
                      item.wordCount!,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.outline,
                      ),
                    ),
                  if (_loadWordCount &&
                      item.chapterWordCountText != null &&
                      item.chapterWordCountText!.isNotEmpty)
                    Text(
                      item.chapterWordCountText!,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.outline,
                      ),
                    ),
                  if (_loadWordCount && item.respondTime >= 0)
                    Text(
                      '耗时 ${item.respondTime}ms',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    Symbols.thumb_up_rounded,
                    color: goodActive
                        ? goodColor
                        : colorScheme.outline.withValues(alpha: 0.6),
                  ),
                  tooltip: '赞',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _onThumbUp(item),
                ),
                IconButton(
                  icon: Icon(
                    Symbols.thumb_down_rounded,
                    color: badActive
                        ? badColor
                        : colorScheme.outline.withValues(alpha: 0.6),
                  ),
                  tooltip: '踩',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _onThumbDown(item),
                ),
              ],
            ),
            if (isCurrent)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 12),
                child: Icon(
                  Symbols.check_circle_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
              )
            else if (isApplying)
              const Padding(
                padding: EdgeInsets.only(left: 4, top: 12),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
          ],
        ),
      ),
    );
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
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    );
  }
}


/// 搜索等待反馈文本（体检 U1 · T6 流式化前的过渡方案）
///
/// Rust 换源搜索为一次性阻塞调用（流式 API 落地前无逐源 x/y 进度），
/// 以「参与搜索的源数量 + 已等待时长」告知仍在进行，避免无反馈转圈。
class _SearchWaitMessage extends StatefulWidget {
  final int? count;

  const _SearchWaitMessage({this.count});

  @override
  State<_SearchWaitMessage> createState() => _SearchWaitMessageState();
}

class _SearchWaitMessageState extends State<_SearchWaitMessage> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final count = widget.count;
    final sourceText = (count == null || count <= 0) ? '' : ' $count 个书源';
    return Text(
      '正在搜索$sourceText… 已等待 $_seconds 秒',
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
    );
  }
}
