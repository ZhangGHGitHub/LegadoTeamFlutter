import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/search/search_notifier.dart';
import '../routes.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/md3_animated_text_line.dart';

/// 书源分组拆分正则（对标原版 AppPattern.splitGroupRegex：[,;，；]）
final _splitGroupRegex = RegExp(r'[,;，；]');

/// 搜索页面
///
/// 状态由 [SearchNotifier]（Riverpod）管理；加书架过渡期仍用 BookshelfProvider。
class SearchScreen extends ConsumerStatefulWidget {
  /// 初始搜索词（对齐原版 SearchActivity.start(context, query)）
  final String? initialQuery;

  /// 预选书源 URL 列表（对齐原版 SearchActivity.start(context, bookSource)：
  /// 从发现页「搜索」菜单进入时按指定书源搜索）— 发现页修复 R2
  final List<String>? initialSourceUrls;

  /// 预选分组列表（对齐原版 receiptIntent searchScope）
  final List<String>? initialGroups;

  const SearchScreen({
    super.key,
    this.initialQuery,
    this.initialSourceUrls,
    this.initialGroups,
  });

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState
    extends ConsumerState<SearchScreen>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  final _resultsScrollController = ScrollController();
  // [fix v2.0.102] 构造期捕获 notifier 实例：riverpod 在 state.dispose() 执行前
  // 已将 element 标记为 disposed，dispose 内任何 ref.read 都会抛
  // 「Cannot use ref after the widget was disposed」；state getter 为 protected，
  // 故另存最近一次 build 的 state 供 dispose 判断 isLoading — Qoder UI
  late final SearchNotifier _searchNotifier;
  SearchState? _lastBuiltState;
  // 精准搜索开关（对标原版 menu_precision_search，展示层精确书名过滤）
  bool _precision = false;
  // 标识读过的书籍（对标原版 AppConfig.showSearchReadRecord）
  bool _showReadRecord = false;
  static const _prefsShowReadRecord = 'showSearchReadRecord';
  // 输入帮助层显隐（对标原版 ll_input_help / setOnQueryTextFocusChangeListener）
  bool _showInputHelp = true;
  // 空结果智能引导弹窗：每次搜索最多弹一次
  int _searchSessionId = 0;
  int _emptyDialogShownForSession = -1;
  // [UI-fix v2.0.3 | 2026-08-07] 锚定菜单定位键：分组 PopupMenu 锚定三点按钮下方 — Qoder
  final _menuButtonKey = GlobalKey();
  // 溢出菜单动态分组条目的书源缓存（对标原版 onMenuOpened 每次打开实时查询；
  // 进入时预载，返回书源管理页后刷新）— Cursor UI
  List<BookSource>? _menuSources;

  @override
  void initState() {
    super.initState();
    _searchNotifier = ref.read(searchNotifierProvider.notifier);
    // 批次B G-B-04：监听 app 生命周期（原版 repeatOnLifecycle(RESUMED)）
    WidgetsBinding.instance.addObserver(this);
    _focusNode.addListener(_onFocusChanged);
    final initial = widget.initialQuery?.trim();
    if (initial != null && initial.isNotEmpty) {
      _searchController.text = initial;
    }
    // 对齐原版：打开搜索页默认不显示上次结果（新 ViewModel 语义，不 auto-search）。
    // Riverpod 禁止在 widget 生命周期内同步修改 provider，
    // 按官方建议延迟到微任务执行。
    Future.microtask(() {
      if (!mounted) return;
      ref.read(searchNotifierProvider.notifier).resetForOpen();
      // 预选分组（路由 searchScope / groups 参数）
      final groups = widget.initialGroups;
      if (groups != null && groups.isNotEmpty) {
        for (final group in groups) {
          ref.read(searchNotifierProvider.notifier).toggleGroup(group);
        }
      }
      // 预选书源（发现页「搜索」入口指定书源，单选取首个）
      final sourceUrls = widget.initialSourceUrls;
      if (sourceUrls != null && sourceUrls.isNotEmpty) {
        ref
            .read(searchNotifierProvider.notifier)
            .toggleSource(sourceUrls.first);
      }
      final q = widget.initialQuery?.trim();
      if (q != null && q.isNotEmpty) {
        ref.read(searchNotifierProvider.notifier).setInput(q);
        ref.read(searchNotifierProvider.notifier).search(q);
      }
    });
    // 恢复「标识读过的书籍」偏好
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _showReadRecord = prefs.getBool(_prefsShowReadRecord) ?? false;
      });
    });
    // 恢复精准搜索偏好（对齐原版 PreferKey.precisionSearch）— Cursor UI
    ref.read(bookApiProvider).getConfig('precisionSearch').then((raw) {
      if (!mounted) return;
      final precision = raw == 'true';
      setState(() => _precision = precision);
      ref.read(searchNotifierProvider.notifier).setPrecision(precision);
    });
    // 预载溢出菜单动态分组条目所需书源列表（对标原版 onMenuOpened 实时查询）— Cursor UI
    _refreshMenuSources();
  }

  /// 刷新溢出菜单用的书源缓存（加载失败时动态分组条目隐藏，静态条目不受影响）
  Future<void> _refreshMenuSources() async {
    try {
      final list = await ref.read(bookApiProvider).getEnabledBookSources();
      if (!mounted) return;
      setState(() => _menuSources = list);
    } catch (_) {
      // 静默：菜单仍显示静态条目
    }
  }

  /// 聚焦变化时更新输入帮助层显隐
  void _onFocusChanged() => _updateInputHelpVisibility();

  /// 对标原版 setOnQueryTextFocusChangeListener + visibleInputHelp
  void _updateInputHelpVisibility() {
    final state = ref.read(searchNotifierProvider);
    final hasFocus = _focusNode.hasFocus;
    final queryNotBlank = _searchController.text.trim().isNotEmpty;
    final shouldShow = !state.isLoading &&
        !(!hasFocus && state.hasResults && queryNotBlank);
    if (_showInputHelp != shouldShow && mounted) {
      setState(() => _showInputHelp = shouldShow);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 对齐原版 SearchActivity 销毁 → scope.cancel()：离开页面取消进行中的搜索，
    // 避免 Rust 侧流在后台继续消耗资源（批次B G-B-04 配套）— Cursor UI
    // [fix v2.0.102] dispose 内不可用 ref（riverpod unmount 时序），改用捕获实例 — Qoder UI
    // [fix v2.0.102] stop() 会同步写 provider 状态，触发 build 中注册的 ref.listen
    // 监听器（_updateInputHelpVisibility → ref.read）；unmount 期间 element 已
    // deactivate（context.mounted=false）→ "Cannot use ref after disposed"。
    // 故经 microtask 延迟到 unmount 全部完成后执行：此时 riverpod 已关闭本
    // element 的 listen 订阅，状态回写不再回调任何 UI 监听器。— Qoder UI
    final shouldStop = _lastBuiltState?.isLoading ?? false;
    _focusNode.removeListener(_onFocusChanged);
    _searchController.dispose();
    _focusNode.dispose();
    _resultsScrollController.dispose();
    super.dispose();
    if (shouldStop) {
      Future.microtask(() => unawaited(_searchNotifier.stop()));
    }
  }

  /// app 退后台软挂起 / 回前台恢复（批次B G-B-04：对齐原版
  /// repeatOnLifecycle(RESUMED) → viewModel.pause()/resume()）— Cursor UI
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    final state = ref.read(searchNotifierProvider);
    final notifier = ref.read(searchNotifierProvider.notifier);
    if (lifecycleState == AppLifecycleState.paused &&
        state.isLoading &&
        !state.isPaused) {
      unawaited(notifier.pauseSearch());
    } else if (lifecycleState == AppLifecycleState.resumed && state.isPaused) {
      unawaited(notifier.resumeSearch());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchNotifierProvider);
    _lastBuiltState = state;

    ref.listen<SearchState>(searchNotifierProvider, (prev, next) {
      if (prev == null) return;
      // 新搜索开始：重置空结果弹窗计数
      if (!prev.isLoading && next.isLoading) {
        _searchSessionId++;
      }
      // 新搜索开始时滚顶（对齐原版 AdapterDataObserver.onItemRangeInserted：
      // 仅当条目插入于 positionStart == 0 —— 即新关键词结果重置重填时滚顶；
      // 流式增量批次与续页追加的 positionStart > 0，不触发）。
      // [2026-08-24] 旧条件在加载中任何长度变化都滚顶：节流增量渲染每 150ms flush
      // 都会 animateTo(0) → 页面被反复拉回顶部、无法滚动。改为仅在「新搜索开始」
      // （isLoading false→true 且关键词变化或结果已清空）时触发。— Qoder UI
      final isNewSearch = !prev.isLoading &&
          next.isLoading &&
          (prev.keyword != next.keyword || next.results.isEmpty);
      if (isNewSearch) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_resultsScrollController.hasClients) {
            _resultsScrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
      _updateInputHelpVisibility();
      // 空结果智能引导（对齐原版 searchFinishLiveData L457-477）
      if (prev.isLoading &&
          !next.isLoading &&
          next.isEmpty &&
          next.hasFilter &&
          _emptyDialogShownForSession != _searchSessionId) {
        _emptyDialogShownForSession = _searchSessionId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showEmptyScopeDialog(next);
        });
      }
    });

    return PopScope(
      // 对标原版 finish()：搜索框聚焦时返回仅失焦不退出
      canPop: !_focusNode.hasFocus,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _focusNode.hasFocus) {
          FocusScope.of(context).unfocus();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(context),
        body: Column(
          children: [
            // 顶部进度条（对齐原版 refresh_progress_bar，2dp）
            if (state.isLoading && state.totalCount > 0)
              LinearProgressIndicator(
                value: state.searchedCount / state.totalCount,
                minHeight: 2,
              ),
            Expanded(child: _buildBody(context, state)),
          ],
        ),
        // 批次B G-B-02：搜索中=stop；空闲且 hasMore=play（原版 fb_start_stop + searchFinally）
        floatingActionButton: state.isLoading
            ? _buildStopFab(context, state)
            : (state.hasMore &&
                    !state.isManualStop &&
                    state.error == null &&
                    state.keyword.isNotEmpty)
                ? _buildNextPageFab()
                : null,
      ),
    );
  }

  /// 搜索中停止 FAB + 浮动 x/y（对齐原版 fb_start_stop + tv_search_progress）
  Widget _buildStopFab(BuildContext context, SearchState state) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (state.totalCount > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            // [翻滚数字] 浮动进度卡同步翻滚
            child: Md3AnimatedTextLine(
              text: '${state.searchedCount}/${state.totalCount}',
              style: theme.textTheme.labelSmall,
            ),
          ),
        FloatingActionButton.small(
          onPressed: () => ref.read(searchNotifierProvider.notifier).stop(),
          tooltip: '停止搜索',
          child: const Icon(Symbols.stop_rounded),
        ),
      ],
    );
  }

  /// 下一页 FAB（批次B G-B-02：原版 searchFinally → Symbols.play_arrow_rounded，
  /// 点击 = 同关键词续页 loadNextPage）— Cursor UI
  Widget _buildNextPageFab() {
    return FloatingActionButton.small(
      onPressed: () => ref.read(searchNotifierProvider.notifier).loadNextPage(),
      tooltip: '加载下一页',
      child: const Icon(Symbols.play_arrow_rounded),
    );
  }

  /// 滚动到底自动加载（批次B G-B-03：原版 SearchActivity 滚动监听）
  ///
  /// 原版语义：触底 && !isSearchLiveData && hasMore && !isManualStopSearch
  /// → viewModel.search("")（同 searchId → page++）。返回 false 不拦截滚动。
  bool _onResultsScroll(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    final controller = _resultsScrollController;
    if (!controller.hasClients) return false;
    final position = controller.position;
    // 触底判定（1px 容差，对齐原版 canScrollVertically(1)==false）
    if (position.pixels < position.maxScrollExtent - 1.0) return false;
    final state = ref.read(searchNotifierProvider);
    if (!state.isLoading &&
        !state.isManualStop &&
        state.hasMore &&
        state.error == null &&
        state.keyword.isNotEmpty) {
      ref.read(searchNotifierProvider.notifier).loadNextPage();
    }
    return false;
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LegadoAppBar(
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
            prefixIcon: const Icon(Symbols.search_rounded, size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 32, minHeight: 32),
                    icon: const Icon(Symbols.close_rounded, size: 20),
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
          onSubmitted: (value) {
            // 对标原版 onQueryTextSubmit → clearFocus
            FocusScope.of(context).unfocus();
            ref.read(searchNotifierProvider.notifier).search(value);
          },
          // 实时驱动联想过滤（对标原版 SearchActivity.upHistory）
          onChanged: (value) {
            final notifier = ref.read(searchNotifierProvider.notifier);
            // 对标原版 onQueryTextChange → viewModel.stop() + 隐藏 FAB
            if (ref.read(searchNotifierProvider).isLoading) {
              notifier.stop();
            }
            notifier.setInput(value);
            setState(() {}); // 刷新清除按钮显隐
            _updateInputHelpVisibility();
          },
        ),
      ),
      actions: [
        // 安卓原版：右侧「>」图标提交搜索
        IconButton(
          icon: const Icon(Symbols.arrow_forward_rounded),
          tooltip: AppStrings.search,
          onPressed: () {
            final text = _searchController.text.trim();
            if (text.isNotEmpty) {
              FocusScope.of(context).unfocus();
              ref.read(searchNotifierProvider.notifier).search(text);
            }
          },
        ),
        // 安卓原版：三点菜单（book_search.xml：精准搜索/显示搜索记录/书源管理/分组或书源/日志）
        // 显式中文 tooltip：原版无 tooltip 时系统默认提示 Show menu（长按被误读为
        // "shou menu"），此处对齐用户预期显示「更多选项」— Cursor UI
        PopupMenuButton<String>(
          key: _menuButtonKey,
          tooltip: '更多选项',
          onSelected: (value) {
            switch (value) {
              case 'precision':
                // [UI-fix v2.0.10 | 2026-08-10] 切换联动 notifier（other 桶
                // 保留策略）并重搜（对齐原版 SearchActivity 切换后重新搜索）— Reasonix
                setState(() => _precision = !_precision);
                ref
                    .read(searchNotifierProvider.notifier)
                    .setPrecision(_precision);
                // 持久化精准搜索偏好（对齐原版 PreferKey.precisionSearch）— Cursor UI
                ref
                    .read(bookApiProvider)
                    .setConfig('precisionSearch', _precision ? 'true' : 'false');
                final kw = ref.read(searchNotifierProvider).keyword;
                if (kw.isNotEmpty) {
                  ref.read(searchNotifierProvider.notifier).search(kw);
                }
                break;
              case 'readRecord':
                // P1-3：对标原版「标识读过的书籍」（show_search_read_record）
                setState(() => _showReadRecord = !_showReadRecord);
                SharedPreferences.getInstance().then((prefs) {
                  prefs.setBool(_prefsShowReadRecord, _showReadRecord);
                });
                break;
              case 'sources':
                // 返回书源管理页后刷新动态分组条目（原版每次打开实时查询）— Cursor UI
                Navigator.pushNamed(context, '/sources')
                    .whenComplete(_refreshMenuSources);
                break;
              case 'scope':
                // 搜索范围底部对话框（对齐原版 SearchScopeDialog：rb_group CheckBox
                // 多选 / rb_source RadioButton 单选 + 名称过滤，全部书源/取消/确定）— Cursor UI
                _showSearchScopeDialog();
                break;
              case '__all_sources__':
                // 动态分组条目：清空范围=全部书源（原版 menu_1 → update("")）— Cursor UI
                ref.read(searchNotifierProvider.notifier).clearAllFilter();
                _autoResearchAfterScopeChange();
                break;
              case '__current_source__':
                // 动态分组条目：当前书源范围，点按清除（原版 remove → ""）— Cursor UI
                ref.read(searchNotifierProvider.notifier).clearSourceFilter();
                _autoResearchAfterScopeChange();
                break;
              case 'log':
                // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
                Navigator.pushNamed(context, AppRoutes.appLog);
                break;
              default:
                // 动态分组条目 'group:X'：点已选=取消（原版 remove(title)）、
                // 点未选=单选替换（原版 update(title)）— Cursor UI
                if (value.startsWith('group:')) {
                  final group = value.substring('group:'.length);
                  final st = ref.read(searchNotifierProvider);
                  final notifier = ref.read(searchNotifierProvider.notifier);
                  if (st.selectedGroups.contains(group)) {
                    notifier.toggleGroup(group);
                  } else {
                    notifier.selectGroupExclusive(group);
                  }
                  _autoResearchAfterScopeChange();
                }
            }
          },
          itemBuilder: (_) => _buildOverflowMenuItems(),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, SearchState state) {
    // 分桶排序在 notifier 批次回调内一次性完成（对齐原版 mergeItems
    // 无条件执行：默认也按匹配度 equal→tags→contains→other 排序，
    // 精准搜索丢弃 other 桶），展示层直接消费 state.results，
    // 避免 build 时全量分桶导致精准搜索卡顿
    // [UI-fix v2.0.10 | 2026-08-10] — Reasonix
    final results = state.results;

    // [批次B G-B-05] 书架实时数据（对标原版 appDb.bookDao.flowAll 响应式流）：
    // 在此 watch，进入搜索页即加载书架；增删/刷新时输入帮助层「书架」节与
    // 结果项绿点实时重绘
    final shelfBooks = ref.watch(bookshelfNotifierProvider).books;
    final shelfKeys = _shelfKeySet(shelfBooks);

    // 有结果时重新聚焦 → 叠加输入帮助层（对标原版 ll_input_help）
    if (state.hasResults && _showInputHelp) {
      return _buildSearchHistory(context, state, shelfBooks);
    }

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
      // [颜文字彩蛋] 搜索无结果空态（用户授权新增，对齐参考 EmptyMessage）
      return EmptyState(
        icon: Symbols.search_off_rounded,
        title: AppStrings.noResults,
        subtitle: AppStrings.noResultsHint,
        kaomoji: true,
      );
    }

    if (!state.hasResults) {
      return _buildSearchHistory(context, state, shelfBooks);
    }

    return Column(
      children: [
        // 结果统计
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // [翻滚数字] 结果计数变化时向上翻滚（参考 AnimatedTextLine）
              Md3AnimatedTextLine(
                text: '${AppStrings.search}: ${results.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              // 渐进搜索进度（对齐原版 x/y；搜索中且已有结果时展示）
              if (state.isLoading && state.totalCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Md3AnimatedTextLine(
                    text: '${state.searchedCount}/${state.totalCount}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const Spacer(),
              if (state.selectedGroups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Symbols.folder_rounded, size: 16),
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
                  avatar: const Icon(Symbols.filter_list_rounded, size: 16),
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
          child: NotificationListener<ScrollNotification>(
            // 批次B G-B-03：触底自动加载下一页（原版 scrollToBottom）
            onNotification: _onResultsScroll,
            // 不 keepAlive：滚出可视区即 dispose，取消排队中的封面解密
            child: ListView.separated(
              controller: _resultsScrollController,
              itemCount: results.length,
              addAutomaticKeepAlives: false,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
              itemBuilder: (context, index) {
                final result = results[index];
                return _buildResultItem(context, result, shelfKeys);
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 搜索结果项（对标原版 item_search.xml：80x110 封面 + 书名 16sp +
  /// 作者/最新章节 12sp + 简介 3 行 + 右上角来源徽标）
  Widget _buildResultItem(
      BuildContext context, SearchResult result, Set<String> shelfKeys) {
    final book = result.book;
    // [批次B G-B-05] 在架判定（原版 SearchViewModel.kt L110-116 键集语义）
    final inShelf = _isInBookshelf(book, shelfKeys);
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
            // 封面 + 阅读记录橙点（对标原版 ivReadRecord）
            Stack(
              children: [
                BookCover(
                  coverUrl: book.coverUrl,
                  width: 80,
                  height: 110,
                  borderRadius: 10,
                  sourceOrigin: book.origin,
                ),
                // 原版 SearchAdapter L122：橙点（阅读记录）与绿点（在架）互斥
                if (_showReadRecord && !inShelf && result.hasReadRecord)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF9800),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colorScheme.surface,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 书名 16sp + 在架绿点 + 右侧同源数徽标
                  // （对标 item_search.xml：iv_in_bookshelf 为 tv_name 行首 8dp 绿色圆点）
                  Row(
                    children: [
                      if (inShelf) ...[
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFF43A047), // md_green_600
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
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
                      // 同源数徽标（对齐参考仓库 TextCard + AnimatedTextLine：
                      // surfaceContainer 底 + 4dp 圆角中性角标，聚合搜索流式
                      // 返回时数字向上翻滚 +1；单源显示书源名便于辨认）
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: result.originsCount > 1
                            ? Md3AnimatedTextLine(
                                text: '${result.originsCount}',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onSurface,
                                      fontWeight: FontWeight.w500,
                                    ),
                              )
                            : Text(
                                result.sourceName.isNotEmpty
                                    ? result.sourceName
                                    : '1',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
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

  /// 溢出菜单条目：5 静态条目 + 动态分组节（对齐原版 onMenuOpened L121-157）
  ///
  /// 动态节顺序与原版一致：当前书源（若有，带勾选，点按清空）→ 全部书源
  ///（无范围时带勾选）→ 全部分组连续排列（已选带勾选/未选无勾选）。
  /// 原版每次打开菜单重建本节；此处用预载的 [_menuSources] 缓存
  ///（进入时预载、返回书源管理页后刷新）。
  /// 自愈：范围非空但已无有效勾选时对标原版 !hasChecked 分支，
  /// 延迟清空为全部书源（searchScope.update("")）。— Cursor UI
  List<PopupMenuEntry<String>> _buildOverflowMenuItems() {
    final state = ref.read(searchNotifierProvider);
    final items = <PopupMenuEntry<String>>[
      CheckedPopupMenuItem(
        value: 'precision',
        checked: _precision,
        child: const Text('精准搜索'),
      ),
      // 对标原版 show_search_read_record：「标识读过的书籍」
      CheckedPopupMenuItem(
        value: 'readRecord',
        checked: _showReadRecord,
        child: const Text('标识读过的书籍'),
      ),
      const PopupMenuItem(value: 'sources', child: Text('书源管理')),
      const PopupMenuItem(value: 'scope', child: Text('分组或书源')),
    ];
    // 动态分组节（原版 onMenuOpened L121-157）
    final sources = _menuSources ?? const <BookSource>[];
    final enabledGroups = _extractGroups(sources);
    if (state.selectedSourceUrls.isNotEmpty) {
      items.add(
        CheckedPopupMenuItem(
          value: '__current_source__',
          checked: true,
          child: Text(_sourceNameOf(sources, state.selectedSourceUrls)),
        ),
      );
    }
    items.add(
      CheckedPopupMenuItem(
        value: '__all_sources__',
        checked: state.selectedGroups.isEmpty &&
            state.selectedSourceUrls.isEmpty,
        child: const Text('全部书源'),
      ),
    );
    for (final group in enabledGroups) {
      items.add(
        CheckedPopupMenuItem(
          value: 'group:$group',
          checked: state.selectedGroups.contains(group),
          child: Text(group),
        ),
      );
    }
    // 自愈（原版 !hasChecked：范围指向已失效分组 → searchScope.update("")）
    final hasChecked = state.selectedSourceUrls.isNotEmpty ||
        state.selectedGroups.isEmpty ||
        enabledGroups.any(state.selectedGroups.contains);
    if (!hasChecked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(searchNotifierProvider.notifier).clearAllFilter();
        }
      });
    }
    items.add(const PopupMenuItem(value: 'log', child: Text('日志')));
    return items;
  }

  /// 当前选中书源名称（动态菜单条目展示用）
  String _sourceNameOf(List<BookSource> sources, Set<String> urls) {
    for (final s in sources) {
      if (urls.contains(s.bookSourceUrl)) return s.bookSourceName;
    }
    return '书源';
  }

  /// 范围变更后自动重搜（对齐原版 stateLiveData 观察者重搜）
  void _autoResearchAfterScopeChange() {
    final st = ref.read(searchNotifierProvider);
    if (st.keyword.isNotEmpty) {
      ref.read(searchNotifierProvider.notifier).search(st.keyword);
    }
  }

  /// 搜索范围底部对话框（对齐原版 SearchScopeDialog：分组多选 / 书源单选，
  /// 全部书源 / 取消 / 确定；rb_group → CheckBox、rb_source → RadioButton +
  /// 名称过滤字段）— Cursor UI
  Future<void> _showSearchScopeDialog() async {
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
    final before = ref.read(searchNotifierProvider);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.75,
        child: _SearchScopeSheet(
          sources: sources,
          initialGroups: {...before.selectedGroups},
          initialSourceUrl: before.selectedSourceUrls.isNotEmpty
              ? before.selectedSourceUrls.first
              : null,
        ),
      ),
    );
    if (!mounted) return;
    final after = ref.read(searchNotifierProvider);
    final changed = !_setEquals(before.selectedGroups, after.selectedGroups) ||
        !_setEquals(before.selectedSourceUrls, after.selectedSourceUrls);
    // 筛选变更且有关键词时自动重搜（对齐原版 scope 变更观察者重搜）
    if (changed && after.keyword.isNotEmpty) {
      ref.read(searchNotifierProvider.notifier).search(after.keyword);
    }
  }

  /// 从书源列表提取全部不重复分组名
  ///
  /// 对标原版 BookSourceDao.dealGroups：按 AppPattern.splitGroupRegex
  ///（[,;，；]）拆分、去重。原版最终按 cnCompare（ICU 简体中文序）排序；
  /// Flutter 轨无拼音 Collator，采用首现序（与 book_source_group_manage_dialog
  /// 聚合惯例一致）。
  List<String> _extractGroups(List<BookSource> sources) {
    final groupSet = <String>{};
    for (final source in sources) {
      final group = source.bookSourceGroup;
      if (group != null && group.isNotEmpty) {
        final parts = group.split(_splitGroupRegex).map((g) => g.trim());
        for (final g in parts) {
          if (g.isNotEmpty) groupSet.add(g);
        }
      }
    }
    return groupSet.toList();
  }

  /// 集合相等比较（元素无序）
  static bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  // ===== [批次B G-B-05] 书架实时匹配（对标原版 SearchViewModel.kt L88-116）=====

  /// 构建书架键集（原版 SearchViewModel.kt L88-97：每本在架书生成三个键
  /// {「书名-作者」, 书名, bookUrl}；notShelf 临时书不参与，对标 filterNot isNotShelf）
  Set<String> _shelfKeySet(List<Book> books) {
    final keys = <String>{};
    for (final book in books) {
      if ((book.bookType & BookType.notShelf) != 0) continue;
      keys.add('${book.name}-${book.author}');
      keys.add(book.name);
      keys.add(book.bookUrl);
    }
    return keys;
  }

  /// 在架判定（原版 SearchViewModel.kt L110-116：key = 作者非空 ? 「书名-作者」 : 书名；
  /// key ∈ 键集 || bookUrl ∈ 键集 即命中）
  bool _isInBookshelf(Book book, Set<String> keys) {
    final key = book.author.isNotEmpty
        ? '${book.name}-${book.author}'
        : book.name;
    return keys.contains(key) || keys.contains(book.bookUrl);
  }

  /// 书架实时搜索建议（原版 BookDao.flowSearch L83：name/author LIKE '%key%' 子串匹配）
  List<Book> _shelfSuggest(String key, List<Book> books) {
    if (key.isEmpty) return const [];
    return books
        .where((b) => (b.bookType & BookType.notShelf) == 0 &&
            (b.name.contains(key) || b.author.contains(key)))
        .toList();
  }

  /// 搜索历史/联想区（无结果时显示，对标安卓原版「输入帮助」区域）
  ///
  /// 输入为空时展示全部历史；输入非空时展示前缀联想词（[SearchState.suggestions]）。
  /// [批次B G-B-05] 书架实时搜索（对标原版 upHistory L389-424）：输入非空时按
  /// 书名/作者子串过滤在架书籍显示「书架」节，点击直达书籍详情页。
  Widget _buildSearchHistory(
      BuildContext context, SearchState state, List<Book> shelfBooks) {
    final suggestions = state.suggestions;
    // 书架实时搜索（原版 BookDao.flowSearch L83：name/author LIKE '%key%'）：
    // 输入为空或无匹配 → 隐藏本节（原版 tvBookShow/rvBookshelfSearch gone）
    final shelfMatches = _shelfSuggest(_searchController.text.trim(), shelfBooks);

    if (state.searchHistory.isEmpty && shelfMatches.isEmpty) {
      // 安卓原版：无历史时显示纯灰字提示
      return const EmptyState(
        icon: Symbols.search_rounded,
        title: '搜索书名、作者',
        simple: true,
      );
    }

    final hasHistory = state.searchHistory.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // [批次B G-B-05] 书架实时搜索节（对标原版 tvBookShow + rvBookshelfSearch）
                if (shelfMatches.isNotEmpty)
                  ..._buildShelfSuggestSection(context, shelfMatches),
                if (hasHistory) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Row(
                      children: [
                        Text(
                          AppStrings.searchHistory,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _confirmClearHistory,
                          icon: const Icon(Symbols.delete_rounded, size: 18),
                          label: Text(AppStrings.clearHistory),
                        ),
                      ],
                    ),
                  ),
                  suggestions.isEmpty
                      // 联想无匹配（原版：联想列表为空时隐藏历史项）
                      ? Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Center(
                            child: Text(
                              '无匹配的历史关键词',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
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
                            return GestureDetector(
                              onLongPress: () async {
                                await ref
                                    .read(searchNotifierProvider.notifier)
                                    .deleteHistoryItem(keyword);
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已删除「$keyword」')),
                                );
                              },
                              child: ActionChip(
                                label: Text(keyword),
                                onPressed: () => _onHistoryChipTapped(
                                    context, keyword, shelfBooks),
                              ),
                            );
                          }).toList(),
                        ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// [批次B G-B-05] 书架实时搜索节（对标原版 tvBookShow 标签 + rvBookshelfSearch 列表）
  ///
  /// 点击 → 直达书籍详情页（原版 showBookInfo(book)）；行 = 封面 + 书名/作者。
  List<Widget> _buildShelfSuggestSection(BuildContext context, List<Book> books) {
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          '书架',
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      for (final book in books)
        InkWell(
          onTap: () => Navigator.pushNamed(context, AppRoutes.bookInfo,
              arguments: book),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                BookCover(
                  coverUrl: book.coverUrl,
                  width: 40,
                  height: 56,
                  borderRadius: 6,
                  sourceOrigin: book.origin,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      if (book.author.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  /// 历史关键词点击（对标原版 SearchActivity.searchHistory L516-532）
  ///
  /// [批次B G-B-05] 在架同名仅填充分支：
  /// ① 输入已等于该关键词 → 直接搜索；
  /// ② 无书名与关键词完全相同的在架书 → 填入并搜索；
  /// ③ 否则（存在同名书）→ 仅填入输入框，不自动搜索。
  void _onHistoryChipTapped(
      BuildContext context, String keyword, List<Book> shelfBooks) {
    final current = _searchController.text.trim();
    if (current != keyword) {
      _searchController.text = keyword;
      ref.read(searchNotifierProvider.notifier).setInput(keyword);
    }
    FocusScope.of(context).unfocus();
    // 原版 findByName 查全表；Flutter 书架数据源（list_books）已排除
    // notShelf 临时书，等价于「无同名真实在架书」判定
    final hasShelfSameName = shelfBooks.any((b) => b.name == keyword);
    if (current == keyword || !hasShelfSameName) {
      ref.read(searchNotifierProvider.notifier).search(keyword);
    }
  }

  /// 清空历史二次确认（对齐原版 alertClearHistory L550-557）— Cursor UI
  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空搜索历史'),
        content: const Text('确定要清空所有搜索历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(searchNotifierProvider.notifier).clearHistory();
    }
  }

  /// 空结果智能引导弹窗（对齐原版 searchFinishLiveData L457-477）— Cursor UI
  Future<void> _showEmptyScopeDialog(SearchState state) async {
    final displayScope = _formatSearchScope(state);
    final message = _precision
        ? '$displayScope分组搜索结果为空，是否关闭精准搜索？'
        : '$displayScope分组搜索结果为空，是否切换到全部分组？';

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索结果为空'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              ctx,
              _precision ? 'disable_precision' : 'clear_scope',
            ),
            child: Text(_precision ? '关闭精准搜索' : '切换全部分组'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;

    final notifier = ref.read(searchNotifierProvider.notifier);
    final kw = state.keyword;
    if (action == 'disable_precision') {
      setState(() => _precision = false);
      notifier.setPrecision(false);
      ref
          .read(bookApiProvider)
          .setConfig('precisionSearch', 'false');
    } else if (action == 'clear_scope') {
      notifier.clearAllFilter();
    }
    if (kw.isNotEmpty) {
      notifier.search(kw);
    }
  }

  /// 格式化筛选范围展示名（对标原版 searchScope.display）
  String _formatSearchScope(SearchState state) {
    if (state.selectedGroups.isNotEmpty) {
      return state.selectedGroups.join('、');
    }
    if (state.selectedSourceUrls.isNotEmpty) {
      return '指定书源';
    }
    return '';
  }
}

/// 搜索范围底部对话框视图（对齐原版 dialog_search_scope.xml）
///
/// 顶部 [分组 | 书源] 分段切换：分组模式 = CheckBox 多选；书源模式 =
/// RadioButton 单选 + 名称过滤字段。底栏：全部书源（清空为全量）|
/// 取消 | 确定（按 rb 语义应用）。iOS 风格：底部弹层、系统列表节奏、
/// 中性灰分段控件、克制的强调色 — Cursor UI
class _SearchScopeSheet extends ConsumerStatefulWidget {
  final List<BookSource> sources;
  final Set<String> initialGroups;
  final String? initialSourceUrl;

  const _SearchScopeSheet({
    required this.sources,
    required this.initialGroups,
    this.initialSourceUrl,
  });

  @override
  ConsumerState<_SearchScopeSheet> createState() => _SearchScopeSheetState();
}

class _SearchScopeSheetState extends ConsumerState<_SearchScopeSheet> {
  bool _sourceMode = false;
  late Set<String> _checkedGroups;
  String? _selectedUrl;
  final _queryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 原版默认 rb_source；若当前已是书源范围则保持书源模式（对齐 tvOk 语义）
    _sourceMode = widget.initialSourceUrl != null;
    _checkedGroups = {...widget.initialGroups};
    _selectedUrl = widget.initialSourceUrl;
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  /// 全部不重复分组名（与 _SearchScreenState._extractGroups 同逻辑：
  /// splitGroupRegex 拆分 + 首现序去重）
  List<String> get _groups {
    final set = <String>{};
    for (final s in widget.sources) {
      final group = s.bookSourceGroup;
      if (group != null && group.isNotEmpty) {
        for (final part in group.split(_splitGroupRegex).map((p) => p.trim())) {
          if (part.isNotEmpty) set.add(part);
        }
      }
    }
    return set.toList();
  }

  /// 书源模式：按名称过滤（原版 toolbar SearchView 同名行为）
  List<BookSource> get _filteredSources {
    final q = _queryController.text.trim().toLowerCase();
    if (q.isEmpty) return widget.sources;
    return widget.sources
        .where((s) => s.bookSourceName.toLowerCase().contains(q))
        .toList();
  }

  void _onOk() {
    final notifier = ref.read(searchNotifierProvider.notifier);
    if (_sourceMode) {
      if (_selectedUrl != null) {
        // 单选替换（原版 selectSource → SearchScope(url)）；未变更则不动作
        final current = ref.read(searchNotifierProvider).selectedSourceUrls;
        if (!current.contains(_selectedUrl)) {
          notifier.toggleSource(_selectedUrl!);
        }
      } else {
        // 原版：selectSource == null → SearchScope(空串) 全量
        notifier.clearAllFilter();
      }
    } else {
      // 分组多选整体替换（原版 CheckBox 组 → SearchScope(selectGroups)）
      notifier.setGroups(_checkedGroups.toList());
    }
    Navigator.of(context).pop();
  }

  void _onAllSources() {
    ref.read(searchNotifierProvider.notifier).clearAllFilter();
    Navigator.of(context).pop();
  }

  /// 分段按钮（MD3 SegmentedButton 视觉：选中 secondaryContainer 底 +
  /// onSecondaryContainer 前景，未选中透明底）
  Widget _segmentButton(String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: selected
            ? scheme.secondaryContainer
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text(
            '搜索范围',
            // [P1b] 17/w600 硬编码收敛至字阶 titleMedium（M3 区块标题）
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.onSurface,
            ),
          ),
        ),
        // 分段切换（原版 rg_scope：rb_group / rb_source）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                _segmentButton('分组', !_sourceMode, () => setState(() {
                  _sourceMode = false;
                })),
                const SizedBox(width: 3),
                _segmentButton('书源', _sourceMode, () => setState(() {
                  _sourceMode = true;
                })),
              ],
            ),
          ),
        ),
        if (_sourceMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: TextField(
              controller: _queryController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索书源',
                hintStyle: TextStyle(
                    fontSize: 14, color: scheme.onSurface.withValues(alpha: 0.5)),
                prefixIcon: Icon(Symbols.search_rounded, size: 20,
                    color: scheme.onSurface.withValues(alpha: 0.5)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _sourceMode
                ? RadioGroup<String>(
                    groupValue: _selectedUrl,
                    onChanged: (v) => setState(() {
                      _selectedUrl = v;
                    }),
                    child: Column(
                      children: [
                        for (final s in _filteredSources)
                          RadioListTile<String>(
                            value: s.bookSourceUrl,
                            title: Text(s.bookSourceName),
                          ),
                        if (_filteredSources.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text('无匹配书源', style: TextStyle(
                                  color:
                                      scheme.onSurface.withValues(alpha: 0.5))),
                            ),
                          ),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      for (final g in _groups)
                        CheckboxListTile(
                          title: Text(g),
                          value: _checkedGroups.contains(g),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _checkedGroups.add(g);
                            } else {
                              _checkedGroups.remove(g);
                            }
                          }),
                        ),
                      if (_groups.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(
                            child: Text('无分组书源', style: TextStyle(
                                color: scheme.onSurface.withValues(alpha: 0.5))),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        // 底栏（原版 tv_all_source / tv_cancel / tv_ok）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              TextButton(
                onPressed: _onAllSources,
                child: Text('全部书源', style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.7))),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('取消', style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.7))),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _onOk,
                child: Text('确定', style: TextStyle(
                    color: scheme.primary, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}