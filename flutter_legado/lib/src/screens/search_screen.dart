import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/search/search_notifier.dart';
import '../routes.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/search_filter_panel.dart';

/// 搜索页面
///
/// 状态由 [SearchNotifier]（Riverpod）管理；加书架过渡期仍用 BookshelfProvider。
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  // 精准搜索开关（对标原版 menu_precision_search，展示层精确书名过滤）
  bool _precision = false;
  // [UI-fix v2.0.3 | 2026-08-07] 锚定菜单定位键：分组 PopupMenu 锚定三点按钮下方 — Qoder
  final _menuButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 对齐原版：打开搜索页默认不显示上次结果（新 ViewModel 语义，不 auto-search）。
    // Riverpod 禁止在 widget 生命周期内同步修改 provider，
    // 按官方建议延迟到微任务执行。
    Future.microtask(() {
      if (mounted) {
        ref.read(searchNotifierProvider.notifier).resetForOpen();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context),
      body: _buildBody(context),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppBar(
      title: Container(
        height: 36,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          // 对标原版 SearchActivity：进入即聚焦弹出键盘
          autofocus: true,
          // [UI-fix v2.0.11 | 2026-08-10] 文字垂直裁切修复：isDense 压缩
          // 行高、textAlignVertical 垂直居中，suffixIcon 收敛到 32x32 约束，
          // 避免默认 IconButton 48px 高度撑破 36px 容器导致文字显示不全 — Reasonix
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            isDense: true,
            hintText: AppStrings.searchBookHint,
            // 安卓端 bg_searchview: 35dp圆角胶囊形、半透明填充、0.5dp描边
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _searchController.clear();
                      ref.read(searchNotifierProvider.notifier).clearResults();
                    },
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide(
                color: colorScheme.surfaceContainerHighest,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide(
                color: colorScheme.primary.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (value) =>
              ref.read(searchNotifierProvider.notifier).search(value),
          // 实时驱动联想过滤（对标原版 SearchActivity.upHistory）
          onChanged: (value) =>
              ref.read(searchNotifierProvider.notifier).setInput(value),
        ),
      ),
      actions: [
        // 安卓原版：右侧「>」图标提交搜索
        IconButton(
          icon: const Icon(Icons.arrow_forward),
          tooltip: AppStrings.search,
          onPressed: () {
            final text = _searchController.text.trim();
            if (text.isNotEmpty) {
              ref.read(searchNotifierProvider.notifier).search(text);
            }
          },
        ),
        // 安卓原版：三点菜单（book_search.xml：精准搜索/显示搜索记录/书源管理/分组或书源/日志）
        PopupMenuButton<String>(
          key: _menuButtonKey,
          onSelected: (value) {
            switch (value) {
              case 'precision':
                // [UI-fix v2.0.10 | 2026-08-10] 切换联动 notifier（other 桶
                // 保留策略）并重搜（对齐原版 SearchActivity 切换后重新搜索）— Reasonix
                setState(() => _precision = !_precision);
                ref
                    .read(searchNotifierProvider.notifier)
                    .setPrecision(_precision);
                final kw = ref.read(searchNotifierProvider).keyword;
                if (kw.isNotEmpty) {
                  ref.read(searchNotifierProvider.notifier).search(kw);
                }
                break;
              case 'readRecord':
                _todo(context, '显示搜索记录');
                break;
              case 'sources':
                Navigator.pushNamed(context, '/sources');
                break;
              case 'scope':
                // [UI-fix v2.0.3 | 2026-08-07] 分组选择改原版锚定菜单：
                // 弹出锚定三点按钮下方的分组 PopupMenu（带勾选、点选即生效
                // 自动重搜），替代原底部弹窗分组 Tab；书源多选经菜单内
                // 「书源多选…」入口保留 — Qoder
                _showGroupScopeMenu();
                break;
              case 'log':
                // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
                Navigator.pushNamed(context, AppRoutes.appLog);
                break;
            }
          },
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'precision',
              checked: _precision,
              child: const Text('精准搜索'),
            ),
            const PopupMenuItem(value: 'readRecord', child: Text('显示搜索记录')),
            const PopupMenuItem(value: 'sources', child: Text('书源管理')),
            const PopupMenuItem(value: 'scope', child: Text('分组或书源')),
            const PopupMenuItem(value: 'log', child: Text('日志')),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final state = ref.watch(searchNotifierProvider);
    // 分桶排序在 notifier 批次回调内一次性完成（对齐原版 mergeItems
    // 无条件执行：默认也按匹配度 equal→tags→contains→other 排序，
    // 精准搜索丢弃 other 桶），展示层直接消费 state.results，
    // 避免 build 时全量分桶导致精准搜索卡顿
    // [UI-fix v2.0.10 | 2026-08-10] — Reasonix
    final results = state.results;

    if (state.isLoading && !state.hasResults) {
      // 渐进搜索：尚无结果时显示加载态（带 x/y 进度，对齐原版 searchProgress）
      return LoadingIndicator(
        message: state.totalCount > 0
            ? '${AppStrings.searching} ${state.searchedCount}/${state.totalCount}'
            : AppStrings.searching,
      );
    }

    if (state.error != null) {
      return ErrorView(
        message: state.error!,
        onRetry: () {
          if (state.keyword.isNotEmpty) {
            ref.read(searchNotifierProvider.notifier).search(state.keyword);
          }
        },
      );
    }

    if (state.isEmpty || (_precision && results.isEmpty)) {
      return EmptyState(
        icon: Icons.search_off,
        title: AppStrings.noResults,
        subtitle: AppStrings.noResultsHint,
      );
    }

    if (!state.hasResults) {
      return _buildSearchHistory(context, state);
    }

    return Column(
      children: [
        // 结果统计
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '${AppStrings.search}: ${results.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              // 渐进搜索进度（对齐原版 x/y；搜索中且已有结果时展示）
              if (state.isLoading && state.totalCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '${state.searchedCount}/${state.totalCount}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const Spacer(),
              if (state.selectedGroups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Icons.folder, size: 16),
                    // 展示实际分组名（粘性可见），点击清除并重搜
                    label: Text(state.selectedGroups.length == 1
                        ? state.selectedGroups.first
                        : '${state.selectedGroups.length} 分组'),
                    onPressed: () {
                      final kw = state.keyword;
                      ref
                          .read(searchNotifierProvider.notifier)
                          .clearGroupFilter();
                      if (kw.isNotEmpty) {
                        ref.read(searchNotifierProvider.notifier).search(kw);
                      }
                    },
                  ),
                ),
              if (state.selectedSourceUrls.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.filter_list, size: 16),
                  label: Text(
                      '${state.selectedSourceUrls.length} ${AppStrings.sources}'),
                  onPressed: () {
                    final kw = state.keyword;
                    ref
                        .read(searchNotifierProvider.notifier)
                        .clearSourceFilter();
                    if (kw.isNotEmpty) {
                      ref.read(searchNotifierProvider.notifier).search(kw);
                    }
                  },
                ),
            ],
          ),
        ),
        // 结果列表
        Expanded(
          // 不 keepAlive：滚出可视区即 dispose，取消排队中的封面解密
          child: ListView.separated(
            itemCount: results.length,
            addAutomaticKeepAlives: false,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
            itemBuilder: (context, index) {
              final result = results[index];
              return _buildResultItem(context, result);
            },
          ),
        ),
      ],
    );
  }

  /// 搜索结果项（对标原版 item_search.xml：80x110 封面 + 书名 16sp +
  /// 作者/最新章节 12sp + 简介 3 行 + 右上角来源徽标）
  Widget _buildResultItem(BuildContext context, SearchResult result) {
    final book = result.book;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final infoStyle = theme.textTheme.bodySmall?.copyWith(fontSize: 12);
    // 分类/字数标签（对标原版 ll_kind LabelsBar：wordCount 置顶 + kind 逗号/换行拆分）
    final kindLabels = <String>[
      if ((book.wordCount ?? '').isNotEmpty) book.wordCount!,
      ...?book.kind
          ?.split(RegExp('[,，\\n]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty),
    ];
    // 稳定 ValueKey（来源+书址）避免结果列表整表重建；RepaintBoundary 隔离重绘区域
    final tile = InkWell(
      key: ValueKey('${result.sourceName}:${book.bookUrl}'),
      // [UI-fix v2.0.3 | 2026-08-06] 搜索结果直达书详情页（对齐原版 SearchActivity→BookInfoActivity，含开始阅读入口） — Qoder
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.bookInfo,
        arguments: result.book,
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(
              coverUrl: book.coverUrl,
              width: 80,
              height: 110,
              // iOS 风格圆角封面
              borderRadius: 10,
              sourceOrigin: book.origin,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 书名 16sp + 右侧同源数徽标（对标 tv_name + bv_originCount）
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      // 同源数徽标：对齐原版红数字；单源时显示书源名便于辨认
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: result.originsCount > 1
                              ? colorScheme.primary
                              : colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          result.originsCount > 1
                              ? '${result.originsCount}'
                              : (result.sourceName.isNotEmpty
                                  ? result.sourceName
                                  : '1'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: result.originsCount > 1
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: result.originsCount > 1
                                ? colorScheme.onPrimary
                                : colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // 作者行（对标 tv_author 12sp）
                  if (book.author.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: infoStyle,
                      ),
                    ),
                  // 分类/字数标签行（对标 ll_kind LabelsBar，位于作者与最新章节之间）
                  if (kindLabels.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final label in kindLabels)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  // 最新章节行（对标 tv_lasted 12sp）
                  if ((book.latestChapterTitle ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '最新：${book.latestChapterTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: infoStyle,
                      ),
                    ),
                  // 简介（对标 tv_introduce 12sp 最多 3 行）
                  if (book.intro != null && book.intro!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        book.intro!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: infoStyle?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return RepaintBoundary(child: tile);
  }

  /// 未移植功能提示
  void _todo(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」后续版本支持')),
    );
  }

  /// [UI-fix v2.0.3 | 2026-08-07] 原版锚定菜单方式的分组选择：
  /// 对齐 SearchActivity.onMenuOpened——「全部书源」+ 各分组（当前选中带勾选），
  /// 锚定三点按钮下方弹出；点未选分组=单选替换（原版 update(title)）、
  /// 点已选分组=取消（原版 remove(title)）、点「全部书源」=清空；
  /// 点选即生效且有关键词时自动重搜（原版 stateLiveData 观察者行为），
  /// 无需确定按钮；菜单高度自适应、分组多时自动滚动不截断。
  /// 「书源多选…」入口保留 SearchFilterPanel 书源多选弹窗 — Qoder
  Future<void> _showGroupScopeMenu() async {
    List<BookSource> sources;
    try {
      sources = await ref.read(bookApiProvider).getEnabledBookSources();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('书源加载失败: $e')));
      }
      return;
    }
    if (!mounted) return;
    final groups = _extractGroups(sources);
    final state = ref.read(searchNotifierProvider);

    // 锚定位置：三点菜单按钮正下方（对标原版溢出菜单锚定顶栏按钮）
    final buttonBox =
        _menuButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (buttonBox == null || overlayBox == null || !buttonBox.attached) return;
    final buttonRect = Rect.fromPoints(
      buttonBox.localToGlobal(Offset.zero, ancestor: overlayBox),
      buttonBox.localToGlobal(buttonBox.size.bottomRight(Offset.zero),
          ancestor: overlayBox),
    );
    final position =
        RelativeRect.fromRect(buttonRect, Offset.zero & overlayBox.size);

    final selectedSourceCount = state.selectedSourceUrls.length;
    final selected = await showMenu<String>(
      context: context,
      position: position,
      items: [
        CheckedPopupMenuItem<String>(
          value: '__all__',
          checked:
              state.selectedGroups.isEmpty && selectedSourceCount == 0,
          child: const Text('全部书源'),
        ),
        for (final group in groups)
          CheckedPopupMenuItem<String>(
            value: 'group:$group',
            checked: state.selectedGroups.contains(group),
            child: Text(group),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '__sources__',
          child: Text(selectedSourceCount > 0
              ? '书源多选（已选 $selectedSourceCount）'
              : '书源多选…'),
        ),
      ],
    );
    if (!mounted || selected == null) return;

    final notifier = ref.read(searchNotifierProvider.notifier);
    if (selected == '__sources__') {
      // 书源多选保留底部弹窗（已加高），关闭后筛选变更且有关键词自动重搜
      await _showScopePanelAndAutoSearch();
      return;
    }
    if (selected == '__all__') {
      notifier.clearAllFilter();
    } else if (selected.startsWith('group:')) {
      final group = selected.substring('group:'.length);
      if (state.selectedGroups.contains(group) &&
          state.selectedGroups.length == 1 &&
          state.selectedSourceUrls.isEmpty) {
        // 点已勾选唯一分组 = 取消（对标原版 menu_group_1 → remove）
        notifier.toggleGroup(group);
      } else {
        // 点未勾选/切换分组 = 单选原子替换（对标原版 menu_group_2 → update）
        // 使用 selectGroupExclusive 避免 clear+toggle 竞态丢分组
        notifier.selectGroupExclusive(group);
      }
    } else {
      return;
    }
    // 点选即生效：有关键词时自动重搜（对标原版 scope 变更观察者重搜）
    final after = ref.read(searchNotifierProvider);
    if (after.keyword.isNotEmpty) {
      notifier.search(after.keyword);
    }
  }

  /// 从书源列表中提取所有不重复的分组名（与 SearchFilterPanel 同逻辑）
  List<String> _extractGroups(List<BookSource> sources) {
    final groupSet = <String>{};
    for (final source in sources) {
      final group = source.bookSourceGroup;
      if (group != null && group.isNotEmpty) {
        // 书源分组可能包含多个组名（逗号分隔）
        final parts = group.split(RegExp(r'[,，]')).map((g) => g.trim());
        for (final g in parts) {
          if (g.isNotEmpty) groupSet.add(g);
        }
      }
    }
    return groupSet.toList()..sort();
  }

  /// 弹出搜索范围面板，关闭后若筛选变更且已有搜索关键词则自动重搜
  /// （留项#12，Task #131）
  Future<void> _showScopePanelAndAutoSearch() async {
    final before = ref.read(searchNotifierProvider);
    final prevGroups = {...before.selectedGroups};
    final prevUrls = {...before.selectedSourceUrls};
    await SearchFilterPanel.show(context);
    if (!mounted) return;
    final after = ref.read(searchNotifierProvider);
    final filterChanged = !_setEquals(prevGroups, after.selectedGroups) ||
        !_setEquals(prevUrls, after.selectedSourceUrls);
    if (filterChanged && after.keyword.isNotEmpty) {
      ref.read(searchNotifierProvider.notifier).search(after.keyword);
    }
  }

  /// 集合相等比较（元素无序）
  static bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  /// 搜索历史/联想区（无结果时显示，对标安卓原版「输入帮助」区域）
  ///
  /// 输入为空时展示全部历史；输入非空时展示前缀联想词（[SearchState.suggestions]）。
  Widget _buildSearchHistory(BuildContext context, SearchState state) {
    final suggestions = state.suggestions;
    if (state.searchHistory.isEmpty) {
      // 安卓原版：无历史时显示纯灰字提示
      return const EmptyState(
        icon: Icons.search,
        title: '搜索书名、作者',
        simple: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                AppStrings.searchHistory,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () =>
                    ref.read(searchNotifierProvider.notifier).clearHistory(),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(AppStrings.clearHistory),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: suggestions.isEmpty
                // 联想无匹配（原版：联想列表为空时隐藏历史项）
                ? Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Center(
                      child: Text(
                        '无匹配的历史关键词',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: suggestions.map((keyword) {
                      return ActionChip(
                        label: Text(keyword),
                        onPressed: () {
                          _searchController.text = keyword;
                          ref
                              .read(searchNotifierProvider.notifier)
                              .setInput(keyword);
                          ref
                              .read(searchNotifierProvider.notifier)
                              .search(keyword);
                        },
                      );
                    }).toList(),
                  ),
          ),
        ),
      ],
    );
  }
}
