// search_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SearchBuilders 承载：主体 / 结果项 / 搜索历史 / 范围汇总等构建方法。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/
// didChangeAppLifecycleState/build）留在主类。
part of 'search_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

/// [C2 N1 / U4 | 台账 0917] 是否残留未渲染的书源模板变量（`{{...}}` 或
/// `{$...}` 占位，如 ngmlc 源 kind 规则 `{{$.categoryInfoV4##...}}`
/// 未命中时残留的 `{{$categoryInfoV4}}`；**未闭合形亦算**——书源 JS
/// 截断可产出 `{{$.categoryInfoV4`（无闭合 `}}`），2.0.277 瀚海书阁
/// kind 实锤）。合法正文/标签不含 `{{`/`{$` 序列，命中即脏数据。
/// 判据与 Rust 解析层 `contains_unrendered_template` 同源。
bool _hasUnrenderedTemplate(String v) => RegExp(r'\{\{|\{\$').hasMatch(v);

/// [R-NaN | 2026-09-17] 第三方书源占位串（来源不可控：书源 JS 规则
/// `x || '暂无简介'` 式回退文案 / 搜索结果页页面文案；全仓 grep（Rust+Dart）
/// 证实我方代码无生成处——「暂无专辑」在仓库任何代码/数据文件均无来源，
/// 「暂无简介」仅见于第三方书源 JSON 的 JS 规则文本与原版 strings.xml
/// 详情页专用键）。按任务裁决：来源不可控 → 渲染层过滤并注释，
/// 不做 UI 隐藏兜底（不渲染整行/标签，与空数据同语义）。
const Set<String> _placeholderTexts = {'暂无专辑', '暂无简介'};

/// [R-NaN] NaN 拼接形判定（如 "NaN : NaN"、"NaN,NaN"）：
/// 按常见分隔符切分后，非空片段**全部**为 NaN（忽略大小写）即纯脏数据——
/// 书源 JS 规则把缺失数值（引擎字符串化为 "NaN"）以分隔符拼接进
/// kind 字段的产物（C1 守卫只拦整串精确 "NaN"，拼接形漏判 → 2.0.272 核图
/// 「NaN : NaN」实锤）。片段含任何非 NaN 内容则放行（保守，不误杀）。
bool _isNanJoined(String v) {
  final parts = v
      .split(RegExp(r'[\s:：,，;；、/|+&·~\-_]+'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return false;
  // 注意：toUpperCase 产物为全大写 'NAN'（非 'NaN'），判据必须与 'NAN' 比
  return parts.every((p) => p.toUpperCase() == 'NAN');
}

/// [PARITY C1 S2 / C2 N1 / R-NaN] 空数据判定：空串、"NaN"（书源规则未返回
/// 数值时 JS 侧字符串化）或其拼接形（"NaN : NaN"）、第三方占位串
/// （暂无专辑/暂无简介）、未渲染书源模板串（`{{...}}`/`{$...}` 占位）
/// 均视为无数据，副标题行/标签/简介不渲染。
///
/// 数据源头已同步清洗（Rust `normalize_js_rule_result` 拒收 JS NaN、
/// `word_count_format` 拒收 "NaN"）；本守卫为渲染层兜底——
/// 第三方书源 JS **字符串**拼接产物（如规则显式产出 "NaN : NaN"）与
/// 占位文案不经 Rust 清洗，仍可能到达 UI。
bool _isMeaningfulText(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return false;
  // [R-NaN 2.0.273 核图复修] 原判据 `v.toUpperCase() == 'NaN'` 恒为 false
  //（'NaN'.toUpperCase()=='NAN' 混合大小写永不相等）——精确 "NaN" 与拼接形
  // 双双漏判，2.0.273 真机 dump 实锤仍渲染。改与全大写 'NAN' 比。
  if (v.toUpperCase() == 'NAN') return false;
  if (_isNanJoined(v)) return false;
  // [R-NaN] 第三方书源占位串（见 _placeholderTexts 注释），不渲染
  if (_placeholderTexts.contains(v)) return false;
  // [C2 N1] 未渲染书源模板变量残留视为脏数据，不渲染
  return !_hasUnrenderedTemplate(v);
}

extension _SearchBuilders on _SearchScreenState {

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

  /// [搜索页对齐 | Qoder UI] 圆形 tonal 动作钮（对齐参考版顶栏圆形按钮形态）
  ///
  /// [2.0.275 视觉精修] 非激活态底色 surfaceContainerHighest → surfaceContainerHigh
  /// + 前景 onSurface：与全局顶栏 tonal 中性槽位（TopBarActionStyler）同槽位，
  /// 激活态（筛选开启）保持主题色 primary 区分。
  Widget _circleAction(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: active ? cs.primary : cs.surfaceContainerHigh,
        foregroundColor: active ? cs.onPrimary : cs.onSurfaceVariant,
      ),
    );
  }

  /// [搜索页对齐 | Qoder UI] 输入条（原顶栏胶囊整体迁移至 body 顶部：
  /// 对齐参考版「大标题 + 全宽输入条」形态；constraints.minWidth 0 防窄屏溢出）
  ///
  /// [1-6 ②] 参考版量测：紧凑胶囊高 ≈56dp、hint ≈16sp、灰蓝底走主题槽
  /// surfaceContainerHigh（无阴影，SearchBar 默认即扁平）、两端全圆（Stadium）
  Widget _buildSearchField(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SearchBar(
      controller: _searchController,
      focusNode: _focusNode,
      autoFocus: true,
      hintText: AppStrings.searchBookHint,
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 16)),
      hintStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 16, color: colorScheme.onSurfaceVariant),
      ),
      shape: const WidgetStatePropertyAll(StadiumBorder()),
      // [1-6 ②] 无阴影（SearchBar 默认 elevation 6 会投影，参考版为扁平胶囊）
      elevation: const WidgetStatePropertyAll(0.0),
      backgroundColor: WidgetStatePropertyAll(
        colorScheme.surfaceContainerHigh,
      ),
      constraints: const BoxConstraints(minHeight: 56, maxHeight: 56),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      leading: Icon(
        Symbols.search_rounded,
        size: 20,
        color: colorScheme.onSurfaceVariant,
      ),
      trailing: _searchController.text.isNotEmpty
          ? [
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(Symbols.close_rounded, size: 20),
                onPressed: () {
                  _searchController.clear();
                  ref.read(searchNotifierProvider.notifier).clearResults();
                },
              ),
            ]
          : null,
      textInputAction: TextInputAction.search,
      onSubmitted: (value) {
        _focusNode.unfocus();
        FocusScope.of(context).unfocus();
        ref.read(searchNotifierProvider.notifier).search(value);
      },
      onChanged: (value) {
        final notifier = ref.read(searchNotifierProvider.notifier);
        if (ref.read(searchNotifierProvider).isLoading) {
          notifier.stop();
        }
        notifier.setInput(value);
        setState(() {});
        _updateInputHelpVisibility();
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    // [1-6 ①] 参考版形态：顶栏仅 3 个圆形动作钮（⚙/◯/≡）。
    // 原第 4 钮 ⋮（2.0.255 迁入）移除，其菜单项按语义并入三钮入口（映射见台账 1-6）：
    //   精准搜索/标识读过的书籍/日志/书源管理 → ⚙ 设置弹层
    //   分组或书源/当前书源/全部书源/分组:X → ◯ 搜索范围弹层
    //   搜索结果过滤 → ≡ 筛选弹层
    return LegadoAppBar(
      title: const SizedBox.shrink(),
      actions: [
        // ① 设置⚙ → 设置弹层（书源管理/精准搜索/标识读过的书籍/日志，
        // 原 ⋮ 静态项并入；锚定 ⚙ 钮下方，替代原 _menuButtonKey 定位）
        // 图标对齐参考版：齿轮（Settings，非默认 ⋮），实心深色（onSurface）
        PopupMenuButton<String>(
          key: _menuButtonKey,
          tooltip: '设置',
          icon: Icon(
            Symbols.settings_rounded,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          onSelected: _onSettingsMenuSelected,
          itemBuilder: (_) => _buildSettingsMenuItems(),
        ),
        // ② 定位（center_focus_weak：十字刻线空心圆，对齐参考版 ◯ 形态）
        // → 搜索范围弹层（原 ⋮ 范围项并入；
        // 弹层内分组/书源选择 + 当前书源/全部书源/分组 快捷切换）
        _circleAction(
          context,
          icon: Symbols.center_focus_weak_rounded,
          tooltip: '搜索范围',
          onTap: _showSearchScopeDialog,
        ),
        // ③ 筛选（filter_list：三段递减横线，对齐参考版 ≡ 形态；
        // 已开启态主色底区分）→ 搜索结果过滤（原 ⋮「搜索结果过滤」项
        // 即本钮直达，映射闭环）
        _circleAction(
          context,
          icon: Symbols.filter_list_rounded,
          tooltip: _resultFilterWords.isEmpty
              ? '搜索结果过滤'
              : '搜索结果过滤（已开启）',
          active: _resultFilterWords.isNotEmpty,
          onTap: _showResultFilterDialog,
        ),
      ],
    );
  }

  /// [1-6 ①] ⚙ 设置弹层项（原 ⋮ 菜单「设置类」静态项并入；
  /// 动态范围项归 ◯ 弹层，见 [_SearchScopeSheet] 范围快捷节）
  List<PopupMenuEntry<String>> _buildSettingsMenuItems() {
    return [
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
      // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen
      //（对标原版 menu_log → AppLogDialog） — Qoder
      const PopupMenuItem(value: 'log', child: Text('日志')),
    ];
  }

  /// [1-6 ①] ⚙ 设置弹层选中分发（逻辑与原 ⋮ onSelected 对应分支一致）
  void _onSettingsMenuSelected(String value) {
    switch (value) {
      case 'precision':
        // [UI-fix v2.0.10 | 2026-08-10] 切换联动 notifier（other 桶
        // 保留策略）并重搜（对齐原版 SearchActivity 切换后重新搜索）— Reasonix
        setState(() => _precision = !_precision);
        ref.read(searchNotifierProvider.notifier).setPrecision(_precision);
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
          prefs.setBool(_SearchScreenState._prefsShowReadRecord,
              _showReadRecord);
        });
        break;
      case 'sources':
        // 与顶栏「设置⚙」直达语义一致（原 ⋮ 项并入后仍保留直达）
        _openSourceManage();
        break;
      case 'log':
        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版
        // menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
        break;
    }
  }

  Widget _buildBody(BuildContext context, SearchState state) {
    // 分桶排序在 notifier 批次回调内一次性完成（对齐原版 mergeItems
    // 无条件执行：默认也按匹配度 equal→tags→contains→other 排序，
    // 精准搜索丢弃 other 桶），展示层直接消费 state.results，
    // 避免 build 时全量分桶导致精准搜索卡顿
    // [UI-fix v2.0.10 | 2026-08-10] — Reasonix
    // [A1 形态对齐 | full-stack-engineer + UI] 搜索结果过滤（对齐原版
    // filterSearchResults：屏蔽词每行一个，匹配书名/作者/分类标签，忽略英文
    // 大小写）。展示层在已分桶结果之上做排除过滤，空词表 = 不过滤（原样返回）。
    final results = _filterSearchResults(state.results);

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
      // 渐进搜索：尚无结果时显示加载态（对齐原版 searchProgress）
      // [LAYOUT_PLAN P4] 首屏 Skeleton 接线：列表骨架替代整页 LoadingIndicator
      // （shimmer 1200ms 已在 skeleton.dart 实现）；x/y 进度由顶部统计行保留
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: 8,
        itemBuilder: (_, _) => const ListSkeletonItem(),
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

    // [A1 形态对齐 | full-stack-engineer + UI] 空态判定收敛：无原始结果 /
    // 被精准搜索隐藏 / 被结果过滤隐藏 三者统一——已完成搜索且过滤后列表为空
    // 即显示空态（对齐原版 filterSearchResults 全量屏蔽后的空列表表现）
    if (results.isEmpty && !state.isLoading && state.keyword.isNotEmpty) {
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
        // [PARITY C1 S1] 「搜索: N」/「x/y」文本行已移除：
        // 「结果 N · 进度 x/y」由上方胶囊统一展示；
        // 无过滤 chips 时整行不渲染（对齐参考结果区无统计行）
        if (state.selectedGroups.isNotEmpty ||
            state.selectedSourceUrls.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
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
                    label: Text('${state.selectedSourceUrls.length} '
                        '${AppStrings.sources}'),
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

  /// 搜索结果项（封面 74x104 5:7 圆角 10 + 书名 16sp + 作者/最新章节 12sp +
  /// 简介 3 行 + 右上角来源徽标）
  ///
  /// [2.0.275 视觉精修] 封面由 80x110 缩至 74x104：参考基准图（ref_20260914
  /// 07_search_results）封面实测 220x311px（1080 基准 480dpi → ≈73.3x103.7dp，
  /// 比例 5:7），80x110（240x330px）偏大约 9%；74x104（222x312px）对齐参考。
  Widget _buildResultItem(
      BuildContext context, SearchResult result, Set<String> shelfKeys) {
    final book = result.book;
    // [批次B G-B-05] 在架判定（原版 SearchViewModel.kt L110-116 键集语义）
    final inShelf = _isInBookshelf(book, shelfKeys);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final infoStyle = theme.textTheme.bodySmall?.copyWith(fontSize: 12);
    // 分类/字数标签（对标原版 ll_kind LabelsBar：wordCount 置顶 + kind 逗号/换行拆分）
    // [PARITY C1 S2] 空数据防 NaN：规则返回 "NaN" 视为无数据，不渲染标签
    final kindLabels = <String>[
      if (_isMeaningfulText(book.wordCount)) book.wordCount!,
      ...?book.kind
          ?.split(RegExp('[,，\n]'))
          .map((s) => s.trim())
          .where((s) => _isMeaningfulText(s)),
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
                  // [2.0.275 视觉精修] 80x110 → 74x104（对齐参考 220x311px，5:7）
                  width: 74,
                  height: 104,
                  borderRadius: 10,
                  sourceOrigin: book.origin,
                  // [LAYOUT_MOTION_AUDIT M1] 搜索结果封面补 Hero（进详情过渡）
                  heroTag: 'book-cover:${book.bookUrl}',
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
                        // [UI_MD3_ALIGNMENT_PLAN.md Batch B B6] 阅读记录点走 tonal
                        color: colorScheme.tertiary,
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
                          decoration: BoxDecoration(
                            // [UI_MD3_ALIGNMENT_PLAN.md Batch B B6] 在架点走 tonal
                            color: colorScheme.primary,
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
                      // [PARITY C1 S4] 来源数数字角标（对齐参考 143/13/8：
                      // 灰底圆角盒常驻右对齐顶对齐，聚合搜索流式返回时
                      // 数字向上翻滚 +1；单源也显示 1，不再显示书源名）
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Md3AnimatedTextLine(
                          text: '${result.originsCount}',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                    ],
                  ),
                  // 作者行（对标 tv_author 12sp；[PARITY C1 S2] NaN 视为无数据）
                  if (_isMeaningfulText(book.author))
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
                  // 最新章节行（对标 tv_lasted 12sp；[PARITY C1 S2] NaN 视为无数据）
                  if (_isMeaningfulText(book.latestChapterTitle))
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
                  // [C2 N1] 未渲染书源模板串（如 `{{$categoryInfoV4}}`）不渲染
                  if (_isMeaningfulText(book.intro))
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

  // ===== [A1 形态对齐 | full-stack-engineer + UI] 顶栏三钮共享实现 =====

  /// 打开书源管理页（顶栏「设置⚙」弹层「书源管理」项入口）。
  /// 范围弹层打开时自行实时拉取书源（_showSearchScopeDialog），无需缓存。
  void _openSourceManage() {
    Navigator.pushNamed(context, '/sources');
  }

  /// 解析屏蔽词表（对齐原版 filterSearchResults 词解析：
  /// 每行一个普通文本，trim、忽略空行、去重、小写化以便忽略大小写匹配）
  List<String> get _resultFilterWords {
    final set = <String>{};
    for (final line in _resultFilter.split(RegExp(r'[\r\n]+'))) {
      final word = line.trim().toLowerCase();
      if (word.isNotEmpty) set.add(word);
    }
    return set.toList();
  }

  /// 搜索结果过滤（对齐原版 SearchActivity.filterSearchResults）：
  /// 命中任一屏蔽词（书名/作者/分类标签，忽略英文大小写）即排除该书；
  /// 屏蔽词表为空时原样返回（= 过滤关闭）。
  List<SearchResult> _filterSearchResults(List<SearchResult> results) {
    final words = _resultFilterWords;
    if (words.isEmpty) return results;
    return results
        .where((r) {
          final book = r.book;
          return !words.any((w) =>
              book.name.toLowerCase().contains(w) ||
              book.author.toLowerCase().contains(w) ||
              (book.kind ?? '').toLowerCase().contains(w));
        })
        .toList();
  }

  /// 搜索结果过滤编辑对话框（对齐原版 showSearchResultFilterDialog：
  /// 多行编辑，每行一个屏蔽词，确定后持久化至 PreferKey.searchResultFilter
  /// 并即时过滤当前结果）— [A1 形态对齐 | full-stack-engineer + UI]
  ///
  /// [D1 缺陷修复 | full-stack-engineer + UI] 控制器移入有状态对话框
  /// [_ResultFilterDialog]，生命周期与弹层子树严格一致：
  /// 旧实现把 controller 建在 showDialog 外、在 future 完成时 dispose，
  /// 但弹层退出动画期间子树仍挂载（OverlayEntry maintainState），
  /// 期间任何对弹层子树的重建都会让 TextField 向已 dispose 的
  /// controller 注册监听 → 「A TextEditingController was used after
  /// being disposed」；异常打断 overlay 子树 unmount，残留
  /// _FocusInheritedScope 依赖 → 弹层子树递归去活时
  /// InheritedElement.debugDeactivated 断言 `'_dependents.isEmpty'`
  /// 失败（framework.dart:6268）→ debug 整页红屏、UI 锁死。
  Future<void> _showResultFilterDialog() async {
    // 弹层返回确认后的屏蔽词文本；取消返回 null（不改动既有屏蔽词表）
    final filter = await showDialog<String>(
      context: context,
      builder: (ctx) => _ResultFilterDialog(initialFilter: _resultFilter),
    );
    if (filter == null || !mounted) return;
    setState(() => _resultFilter = filter);
    // 持久化（对齐原版 putPrefString(PreferKey.searchResultFilter, filter)）
    ref.read(bookApiProvider).setConfig('searchResultFilter', filter);
    // 屏蔽词变更不改搜索范围、无需重搜：_buildBody 依据新屏蔽词表即时重过滤
    // 既有结果（对齐原版 adapter.setItems 对现有结果重过滤，非重新搜索）
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
                        // [1-6 ③] 参考版：「搜索历史」标题前缀 history（时钟形）图标
                        Icon(
                          Symbols.history_rounded,
                          size: 18,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
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
                      : Column(
                          // [UI_SYNC_REFACTOR S5 修 | 2026-09-08] 历史形态对齐
                          // 参考版整行卡（行左关键词、行右 × 单删，点击行搜索），
                          // 替换原流式 chip；原长按删除语义由 × 承担 — Qoder
                          children: suggestions.map((keyword) {
                            final theme = Theme.of(context);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Material(
                                color: theme.colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(14),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () => _onHistoryChipTapped(
                                      context, keyword, shelfBooks),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            keyword,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        InkWell(
                                          borderRadius:
                                              BorderRadius.circular(999),
                                          onTap: () async {
                                            await ref
                                                .read(searchNotifierProvider
                                                    .notifier)
                                                .deleteHistoryItem(keyword);
                                            if (!context.mounted) return;
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              SnackBar(
                                                  content:
                                                      Text('已删除「$keyword」')),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(6),
                                            child: Icon(
                                              Symbols.close_rounded,
                                              size: 18,
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
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
                  // [LAYOUT_MOTION_AUDIT M1] 同源书封面补 Hero（进详情过渡）
                  heroTag: 'book-cover:${book.bookUrl}',
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

/// 搜索结果过滤编辑对话框（有状态，控制器生命周期与弹层子树严格一致）
///
/// [D1 缺陷修复 | full-stack-engineer + UI] 旧实现把 [TextEditingController]
/// 建在 showDialog 外、future 完成时即 dispose，但弹层退出动画期间子树仍
/// 挂载（DialogRoute 的 OverlayEntry maintainState=true），子树重建会让
/// TextField 向已 dispose 的 controller 注册监听（"used after being
/// disposed"），异常打断 overlay 子树 unmount 后残留 _FocusInheritedScope
/// 依赖，弹层去活时触发 InheritedElement 断言 `'_dependents.isEmpty'`
/// 红屏锁死。控制器随本 State 创建/销毁后即无该时序缺口。
///
/// 形态对齐原版 showSearchResultFilterDialog：多行编辑（每行一个屏蔽词），
/// 确定时以 pop 结果返回确认文本（取消返回 null，调用方不改动屏蔽词表）。
class _ResultFilterDialog extends StatefulWidget {
  /// 进入编辑的既有屏蔽词表（每行一个）
  final String initialFilter;

  const _ResultFilterDialog({required this.initialFilter});

  @override
  State<_ResultFilterDialog> createState() => _ResultFilterDialogState();
}

class _ResultFilterDialogState extends State<_ResultFilterDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialFilter);
    // 光标置于末尾（对齐原版 editView.setSelection(end)）
    _controller.selection =
        TextSelection.collapsed(offset: widget.initialFilter.length);
  }

  @override
  void dispose() {
    // 与弹层子树同步销毁：子树 unmount 后 controller 随 State 一并 dispose，
    // 期间不再存在「已 dispose 但仍在树上」的窗口
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('搜索结果屏蔽词'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '每行一个普通文本，匹配书名、作者或分类标签，忽略英文字母大小写',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          TextField(
            // Key 供回归测试无歧义定位弹层输入框（页面内另有顶栏搜索框）
            key: const Key('resultFilterDialogInput'),
            controller: _controller,
            minLines: 4,
            maxLines: 8,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '屏蔽词（每行一个）',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          // 取消：返回 null（调用方保持既有屏蔽词表不变）
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          // 确定：返回 trim 后文本（空串 = 清空屏蔽词表）
          onPressed: () =>
              Navigator.pop(context, _controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
