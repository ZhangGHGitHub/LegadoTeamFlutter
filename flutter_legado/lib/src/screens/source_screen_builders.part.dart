// source_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SourceBuilders 承载：工具栏/批量栏/列表/源项构建。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'source_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SourceBuilders on _SourceScreenState {
  PreferredSizeWidget _buildAppBar(BuildContext context, SourceState state) {
    return LegadoAppBar(
      // 原版 TitleBar 内嵌 view_search：搜索框与菜单图标同行，无标题文字
      // 收紧 titleSpacing 保证搜索框宽度，「搜索书源」提示不被截断
      titleSpacing: 8,
      title: SizedBox(
        height: 36,
        child: TextField(
          controller: _searchCtrl,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          decoration: InputDecoration(
            hintText: '搜索书源',
            hintStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            filled: true,
            fillColor: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            prefixIcon: Icon(Symbols.search_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            // 压缩前缀图标占位，为提示文字腾出完整显示空间
            prefixIconConstraints: const BoxConstraints(
              minWidth: 36,
              minHeight: 36,
            ),
            suffixIcon: state.filterKeyword.isNotEmpty
                ? IconButton(
                    icon: Icon(Symbols.close_rounded,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    onPressed: () {
                      _searchCtrl.clear();
                      ref
                          .read(sourceNotifierProvider.notifier)
                          .clearFilter();
                    },
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (v) =>
              ref.read(sourceNotifierProvider.notifier).setFilter(v),
        ),
      ),
      actions: [
        // 安卓原版 book_source.xml：排序按钮常驻顶栏（action_sort）
        PopupMenuButton<String>(
          icon: const Icon(Symbols.sort_rounded),
          tooltip: '排序',
          // 菜单在顶栏下方展开，不覆盖顶栏
          position: PopupMenuPosition.under,
          onSelected: (value) => _handleSortAction(context, value),
          itemBuilder: (_) => _buildSortMenuItems(context),
        ),
        // 安卓原版：分组按钮常驻顶栏（menu_group 子菜单）
        PopupMenuButton<String>(
          icon: const Icon(Symbols.groups_rounded),
          tooltip: '分组',
          // 菜单在顶栏下方展开，不覆盖顶栏
          position: PopupMenuPosition.under,
          onSelected: (value) => _handleGroupAction(context, value),
          itemBuilder: (context) => [
            const PopupMenuItem(
              enabled: false,
              child:
                  Text('分组', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const PopupMenuItem(value: 'group_manage', child: Text('分组管理')),
            CheckedPopupMenuItem(
              value: SourceSpecialGroup.enabled,
              checked: state.selectedGroup == SourceSpecialGroup.enabled,
              child: const Text('已启用'),
            ),
            CheckedPopupMenuItem(
              value: SourceSpecialGroup.disabled,
              checked: state.selectedGroup == SourceSpecialGroup.disabled,
              child: const Text('已禁用'),
            ),
            CheckedPopupMenuItem(
              value: SourceSpecialGroup.login,
              checked: state.selectedGroup == SourceSpecialGroup.login,
              child: const Text('需登录'),
            ),
            CheckedPopupMenuItem(
              value: '未分组',
              checked: state.selectedGroup == '未分组',
              child: const Text('未分组'),
            ),
            CheckedPopupMenuItem(
              value: SourceSpecialGroup.exploreOn,
              checked: state.selectedGroup == SourceSpecialGroup.exploreOn,
              child: const Text('发现已启用'),
            ),
            CheckedPopupMenuItem(
              value: SourceSpecialGroup.exploreOff,
              checked: state.selectedGroup == SourceSpecialGroup.exploreOff,
              child: const Text('发现已禁用'),
            ),
            for (final group in state.groups.where((g) => g != '未分组'))
              CheckedPopupMenuItem(
                value: group,
                checked: state.selectedGroup == group,
                child: Text(group),
              ),
          ],
        ),
        PopupMenuButton<String>(
          // 原版无 tooltip 时系统默认提示 Show menu（长按被误读为
          // "shou menu"），此处显式指定中文提示
          tooltip: '更多选项',
          // 菜单在顶栏下方展开，不覆盖顶栏（默认 over 会盖住搜索栏）
          position: PopupMenuPosition.under,
          onSelected: (value) => _handleAction(context, value),
          itemBuilder: (_) => [
            // 对标原版 book_source.xml 溢出菜单（JS 书源编辑器未移植前隐藏入口，避免假菜单）
            const PopupMenuItem(
              value: 'new',
              child: _MenuRow(icon: Symbols.add_rounded, label: '新建书源'),
            ),
            const PopupMenuItem(
              value: 'new_js',
              child: _MenuRow(icon: Symbols.code_rounded, label: '新建 JS 书源'),
            ),
            const PopupMenuItem(
              value: 'import_file',
              child: _MenuRow(icon: Symbols.download_rounded, label: '本地导入'),
            ),
            const PopupMenuItem(
              value: 'import_url',
              child:
                  _MenuRow(icon: Symbols.cloud_download_rounded, label: '网络导入'),
            ),
            const PopupMenuItem(
              value: 'import_qr',
              child: _MenuRow(icon: Symbols.qr_code_rounded, label: '二维码导入'),
            ),
            PopupMenuItem(
              value: 'group_by_domain',
              child: _MenuRow(
                icon: Symbols.domain_rounded,
                label: _groupByDomain ? '按域名分组显示 ✓' : '按域名分组显示',
              ),
            ),
            const PopupMenuItem(
              value: 'help',
              child: _MenuRow(icon: Symbols.help_rounded, label: '帮助'),
            ),
          ],
        ),
      ],
    );
  }

  /// 批量模式顶栏（对标原版 SelectActionBar：关闭 + 已选计数）
  ///
  /// 全选/反选/更多操作统一收进底部操作栏，与原版底部操作区一致。
  PreferredSizeWidget _buildBatchAppBar(
      BuildContext context, SourceState state) {
    return LegadoAppBar(
      leading: IconButton(
        icon: const Icon(Symbols.close_rounded),
        tooltip: '退出批量模式',
        onPressed: () =>
            ref.read(sourceNotifierProvider.notifier).exitBatchMode(),
      ),
      title: Text('已选择 ${state.selectedCount} 项'),
    );
  }

  /// 底部常驻批量操作栏（对标原版 SelectActionBar：全选/反选 +
  /// book_source_sel.xml 更多操作菜单）；非批量模式下点击
  /// 全选/反选自动进入批量模式
  Widget _buildBatchBottomBar(BuildContext context, SourceState state) {
    final colorScheme = Theme.of(context).colorScheme;
    final filteredCount = state.filteredSources.length;

    Widget barButton({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
      Color? color,
    }) {
      final effective = color ?? colorScheme.onSurface;
      // 不包 Expanded：宽度由调用处控制（全选 Expanded / 反选删除固定宽）
      return InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: onPressed == null
                  ? effective.withValues(alpha: 0.35)
                  : effective),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: onPressed == null
                      ? effective.withValues(alpha: 0.35)
                      : effective,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        // iOS hairline 上边线
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.6),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          // 对齐原版 SelectActionBar：paddingLeft 16dp / paddingRight 8dp，
          // 全选 weight=1 占剩余、反选/删除内容宽（min 72dp）、更多 36dp 图标
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              // 全选/取消全选（带当前进度 n/m，对齐原版「全选（0/968）」）
              Expanded(
                child: barButton(
                  icon: state.isAllSelected
                      ? Symbols.check_box_rounded
                      : Symbols.check_box_outline_blank_rounded,
                  label: '全选（${state.selectedCount}/$filteredCount）',
                  onPressed: () {
                    final notifier =
                        ref.read(sourceNotifierProvider.notifier);
                    if (!state.batchMode) notifier.enterBatchMode();
                    if (state.isAllSelected) {
                      notifier.deselectAll();
                    } else {
                      notifier.selectAll();
                    }
                  },
                ),
              ),
              // 反选（对齐原版 btn_revert_selection：minWidth 72dp + margin）
              SizedBox(
                width: 82,
                child: barButton(
                  icon: Symbols.flip_rounded,
                  label: '反选',
                  onPressed: state.filteredSources.isEmpty
                      ? null
                      : () {
                          final notifier =
                              ref.read(sourceNotifierProvider.notifier);
                          if (!state.batchMode) notifier.enterBatchMode();
                          notifier.revertSelection();
                        },
                ),
              ),
              // 删除（危险操作标红，对标原版 delete）
              SizedBox(
                width: 82,
                child: barButton(
                  icon: Symbols.delete_rounded,
                  label: '删除',
                  color: colorScheme.error,
                  onPressed: state.selectedCount == 0
                      ? null
                      : () => _handleBatchAction(context, 'delete'),
                ),
              ),
              // 更多选项（book_source_sel.xml 全量选择操作菜单）
              SizedBox(
                width: 36,
                child: PopupMenuButton<String>(
                  tooltip: '更多选项',
                  enabled: state.selectedCount > 0,
                  onSelected: (value) =>
                      _handleBatchAction(context, value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.more_horiz_rounded,
                          size: 22,
                          color: state.selectedCount == 0
                              ? colorScheme.onSurface
                                  .withValues(alpha: 0.35)
                              : colorScheme.onSurface,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '更多选项',
                          style: TextStyle(
                            fontSize: 12,
                            color: state.selectedCount == 0
                                ? colorScheme.onSurface
                                    .withValues(alpha: 0.35)
                                : colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                  itemBuilder: (_) => [
                    // 对标原版 book_source_sel.xml 12 项选择操作
                    const PopupMenuItem(
                        value: 'enable', child: Text('启用所选')),
                    const PopupMenuItem(
                        value: 'disable', child: Text('禁用所选')),
                    const PopupMenuItem(
                        value: 'add_group', child: Text('添加分组')),
                    const PopupMenuItem(
                        value: 'remove_group', child: Text('移除分组')),
                    const PopupMenuItem(
                        value: 'enable_explore', child: Text('启用发现')),
                    const PopupMenuItem(
                        value: 'disable_explore', child: Text('禁用发现')),
                    const PopupMenuItem(
                        value: 'top', child: Text('置顶所选')),
                    const PopupMenuItem(
                        value: 'bottom', child: Text('置底所选')),
                    const PopupMenuItem(
                        value: 'export', child: Text('导出所选')),
                    const PopupMenuItem(
                        value: 'share', child: Text('分享选中源')),
                    const PopupMenuItem(
                        value: 'check', child: Text('校验所选')),
                    const PopupMenuItem(
                        value: 'select_range', child: Text('选中所选区间')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final state = ref.watch(sourceNotifierProvider);

    if (state.loading && state.sources.isEmpty) {
      return const LoadingIndicator(message: '加载书源...');
    }

    if (state.error != null && state.sources.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(sourceNotifierProvider.notifier).loadSources(),
      );
    }

    // 原版仅单一列表；分组/启用状态筛选均在顶栏分组菜单（无 Tab/Chip 行）
    // 校验进行中/结束后顶部展示进度/结果横幅（对标原版 snackbar 持续进度）
    final checkState = ref.watch(checkSourceNotifierProvider);
    final showCheckBanner =
        checkState.checking || (checkState.hasSession && !_checkToastShown);
    final previousChecking = _checkingForToast;
    _checkingForToast = checkState.checking;
    if (previousChecking && !checkState.checking && checkState.hasSession) {
      _checkToastShown = true;
      final invalid = checkState.invalidCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(checkState.cancelled
              ? '已取消校验（完成 $invalid 个失效）'
              : (invalid > 0
                  ? '校验完成：$invalid 个失效源已归入「失效」分组'
                  : '校验完成：全部书源可用')),
        ));
      });
    }

    return Column(
      children: [
        if (showCheckBanner) _buildCheckBanner(checkState),
        Expanded(
          child: _buildSourceList(
            context,
            _displaySources(state.filteredSources),
          ),
        ),
      ],
    );
  }

  /// 展示用列表：开启域名分组时按二级域名排序（对标 upBookSource）
  List<BookSource> _displaySources(List<BookSource> sources) {
    if (!_groupByDomain) return sources;
    final list = List<BookSource>.of(sources);
    list.sort((a, b) {
      final ha = _sourceHost(a.bookSourceUrl);
      final hb = _sourceHost(b.bookSourceUrl);
      final aHash = ha == '#' ? 1 : 0;
      final bHash = hb == '#' ? 1 : 0;
      final byHash = aHash.compareTo(bHash);
      if (byHash != 0) return byHash;
      final byHost = ha.compareTo(hb);
      if (byHost != 0) return byHost;
      return b.lastUpdateTime.compareTo(a.lastUpdateTime);
    });
    return list;
  }

  /// 从书源 URL 取二级域名（对标 NetworkUtils.getSubDomainOrNull，失败为 `#`）
  String _sourceHost(String origin) {
    final trimmed = origin.trim();
    if (trimmed.isEmpty) return '#';
    try {
      final uri = Uri.parse(trimmed.contains('://') ? trimmed : 'http://$trimmed');
      final host = uri.host;
      if (host.isEmpty) return '#';
      final parts = host.split('.').where((p) => p.isNotEmpty).toList();
      if (parts.length >= 2) {
        return parts.sublist(parts.length - 2).join('.');
      }
      return host;
    } catch (_) {
      return '#';
    }
  }

  /// 校验进度/结果横幅（对标原版持续 Snackbar：进度 n/total + 当前源名）
  Widget _buildCheckBanner(CheckSourceState checkState) {
    final colorScheme = Theme.of(context).colorScheme;
    final checking = checkState.checking;
    return Material(
      color: checking
          ? colorScheme.primary.withValues(alpha: 0.08)
          : colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (checking) const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              if (checking) const SizedBox(width: 12),
              Expanded(
                child: Text(
                  checking
                      ? '校验中 ${checkState.done}/${checkState.total}：'
                          '${checkState.currentName}'
                      : '校验结束：${checkState.done}/${checkState.total}'
                          '，失效 ${checkState.invalidCount} 个',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
              if (checking)
                TextButton(
                  onPressed: () => ref
                      .read(checkSourceNotifierProvider.notifier)
                      .cancel(),
                  child: const Text('取消'),
                )
              else
                IconButton(
                  icon: const Icon(Symbols.close_rounded, size: 18),
                  tooltip: '关闭校验结果',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(() => _checkToastShown = false);
                    ref
                        .read(checkSourceNotifierProvider.notifier)
                        .clearMessages();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceList(BuildContext context, List<BookSource> sources) {
    if (sources.isEmpty) {
      return const EmptyState(
        icon: Symbols.library_books_rounded,
        title: '暂无书源',
        subtitle: '点击右上角菜单「新建书源」新建，或导入书源',
      );
    }

    final state = ref.watch(sourceNotifierProvider);

    // 域名分组：插入域名头行（对标 adapter.isItemHeader / getHeaderText）
    if (_groupByDomain) {
      final rows = <_SourceListRow>[];
      String? lastHost;
      for (final source in sources) {
        final host = _sourceHost(source.bookSourceUrl);
        if (host != lastHost) {
          rows.add(_SourceListRow.header(host));
          lastHost = host;
        }
        rows.add(_SourceListRow.item(source));
      }
      // [快速滚动条] 千级书源列表右侧拖拽定位（对齐原版 FastScroller）
      return Md3FastScroller(
        controller: _listController,
        child: ListView.builder(
          controller: _listController,
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            if (row.isHeader) {
              return _buildDomainHeader(context, row.header!);
            }
            final source = row.source!;
            return state.batchMode
                ? _buildBatchSourceItem(context, source, state)
                : _buildSourceItem(context, source);
          },
        ),
      );
    }

    return Md3FastScroller(
      controller: _listController,
      child: ListView.separated(
        controller: _listController,
        itemCount: sources.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
        itemBuilder: (context, index) {
          final source = sources[index];
          return state.batchMode
              ? _buildBatchSourceItem(context, source, state)
              : _buildSourceItem(context, source);
        },
      ),
    );
  }

  /// 域名分组头（轻量列表分组，对齐原版 sticky 域名条信息架构）
  Widget _buildDomainHeader(BuildContext context, String host) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Text(
        host,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 书源列表项（对标原版 item_book_source.xml：源名 16sp + 发现绿点 +
  /// Switch + 编辑图标 + 更多图标，无头像/分组副标题）
  Widget _buildSourceItem(BuildContext context, BookSource source) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasExplore =
        source.exploreUrl != null && source.exploreUrl!.isNotEmpty;
    // 校验结果消息（对标原版列表项 checkSourceMessage：绿=通过，红=失效）
    final checkMessage =
        ref.watch(checkSourceNotifierProvider).messages[source.bookSourceUrl];
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceEditScreen(sourceUrl: source.bookSourceUrl),
          ),
        );
      },
      onLongPress: () {
        // 对标原版 BookSourceAdapter：长按进入多选模式并选中该项
        final notifier = ref.read(sourceNotifierProvider.notifier);
        if (!ref.read(sourceNotifierProvider).batchMode) {
          notifier.enterBatchMode();
        }
        notifier.toggleSelection(source.bookSourceUrl);
      },
      child: Padding(
        // 对齐原版 item_book_source 行高（137px ≈ 68.5dp）：
        // padding 14dp×2 + 内容（开关/图标按钮 ~40dp），
        // 行高由内容自然撑起
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // 源名（对标原版 cb_book_source 文本 16sp）+ 分组标签
            //（对齐原版行内分组标注，如「懒人听书app本地源（同人） (同人书源)」）
            // + 校验消息副标题
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.bookSourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if ((source.bookSourceGroup ?? '').trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '(${source.bookSourceGroup!.trim()})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (checkMessage != null)
                    Text(
                      checkMessage.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: checkMessage.ok
                            ? AppColors.iosGreenLight
                            : AppColors.iosRedLight,
                      ),
                    ),
                ],
              ),
            ),
            // 启用开关（对标 swt_enabled + 原版行内 ON 文字）
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  source.enabled ? 'ON' : 'OFF',
                  style: TextStyle(
                    fontSize: 12,
                    color: source.enabled
                        ? AppColors.iosGreenLight
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
                Switch(
                  value: source.enabled,
                  // 压缩触控/视觉高度（对齐原版 ThemeSwitch 行高 ~36.5dp，
                  // 避免 Material 默认 48dp 把整行撑高）
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => ref
                      .read(sourceNotifierProvider.notifier)
                      .toggleSource(source.bookSourceUrl),
                ),
              ],
            ),
            // 编辑图标（对标 iv_edit）
            IconButton(
              icon: const Icon(Symbols.edit_rounded, size: 20),
              tooltip: '编辑',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        SourceEditScreen(sourceUrl: source.bookSourceUrl),
                  ),
                );
              },
            ),
            // 更多图标（对标 iv_menu_more）+ 发现角标（iv_explore：
            // 绿=有发现且启用，红=有发现未启用，无=无发现）
            Stack(
              children: [
                IconButton(
                  icon: const Icon(Symbols.more_vert_rounded, size: 20),
                  // 对齐原版内容描述「更多菜单」
                  tooltip: '更多菜单',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showSourceMenu(context, source),
                ),
                if (hasExplore)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Semantics(
                      // 对齐原版「标志:发现已启用」内容描述
                      label: source.enabledExplore
                          ? '标志:发现已启用'
                          : '标志:发现未启用',
                      child: Container(
                        width: 8,
                        height: 8,
                        // 发现启用=系统绿；有发现但未启用=系统红
                        decoration: BoxDecoration(
                          color: source.enabledExplore
                              ? AppColors.iosGreenLight
                              : AppColors.iosRedLight,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 批量模式列表项：对标原版选择态仍保留完整行控件
  /// （勾选框 + 源名 + 启用开关 + 编辑 + 更多 + 发现角标），
  /// 整行点击切换选中；开关/编辑/更多各自独立响应，与原版一致
  Widget _buildBatchSourceItem(
      BuildContext context, BookSource source, SourceState state) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = state.isSelected(source.bookSourceUrl);
    final hasExplore =
        source.exploreUrl != null && source.exploreUrl!.isNotEmpty;
    // 校验结果消息（对标原版列表项 checkSourceMessage：绿=通过，红=失效）
    final checkMessage =
        ref.watch(checkSourceNotifierProvider).messages[source.bookSourceUrl];
    return InkWell(
      onTap: () => ref
          .read(sourceNotifierProvider.notifier)
          .toggleSelection(source.bookSourceUrl),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 8, top: 4, bottom: 4),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: (_) => ref
                  .read(sourceNotifierProvider.notifier)
                  .toggleSelection(source.bookSourceUrl),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.bookSourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 16, color: colorScheme.onSurface),
                        ),
                      ),
                      if ((source.bookSourceGroup ?? '').trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            '(${source.bookSourceGroup!.trim()})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (checkMessage != null)
                    Text(
                      checkMessage.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: checkMessage.ok
                            ? AppColors.iosGreenLight
                            : AppColors.iosRedLight,
                      ),
                    ),
                ],
              ),
            ),
            // 启用开关（对标 swt_enabled + 原版行内 ON 文字）
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  source.enabled ? 'ON' : 'OFF',
                  style: TextStyle(
                    fontSize: 12,
                    color: source.enabled
                        ? AppColors.iosGreenLight
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
                Switch(
                  value: source.enabled,
                  // 压缩触控/视觉高度（对齐原版 ThemeSwitch 行高 ~36.5dp，
                  // 避免 Material 默认 48dp 把整行撑高）
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => ref
                      .read(sourceNotifierProvider.notifier)
                      .toggleSource(source.bookSourceUrl),
                ),
              ],
            ),
            // 编辑图标（对标 iv_edit）
            IconButton(
              icon: const Icon(Symbols.edit_rounded, size: 20),
              tooltip: '编辑',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        SourceEditScreen(sourceUrl: source.bookSourceUrl),
                  ),
                );
              },
            ),
            // 更多图标（对标 iv_menu_more）+ 发现角标
            Stack(
              children: [
                IconButton(
                  icon: const Icon(Symbols.more_vert_rounded, size: 20),
                  tooltip: '更多选项',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showSourceMenu(context, source),
                ),
                if (hasExplore)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: source.enabledExplore
                            ? AppColors.iosGreenLight
                            : AppColors.iosRedLight,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 书源长按/更多按钮菜单（对标原版 BookSourceAdapter.showMenu）：
  /// 置顶/置底（仅手动排序）、登录（有 loginUrl）、搜索、调试、删除、
  /// 启用|禁用发现（有 exploreUrl，按 enabledExplore 切换文案）
  Future<void> _showSourceMenu(BuildContext context, BookSource source) async {
    final state = ref.read(sourceNotifierProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final manualSort = state.sort == SourceSort.manual;
    final hasLoginUrl = (source.loginUrl ?? '').trim().isNotEmpty;
    final hasExplore =
        (source.exploreUrl ?? '').trim().isNotEmpty;

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 4),
                child: IosGrabber(),
              ),
              ListTile(
                leading: const Icon(Symbols.vertical_align_top_rounded),
                title: const Text('置顶'),
                enabled: manualSort,
                onTap: () => Navigator.pop(ctx, 'top'),
              ),
              ListTile(
                leading: const Icon(Symbols.vertical_align_bottom_rounded),
                title: const Text('置底'),
                enabled: manualSort,
                onTap: () => Navigator.pop(ctx, 'bottom'),
              ),
              if (hasLoginUrl)
                ListTile(
                  leading: const Icon(Symbols.person_rounded),
                  title: const Text('登录'),
                  onTap: () => Navigator.pop(ctx, 'login'),
                ),
              ListTile(
                leading: const Icon(Symbols.search_rounded),
                title: const Text('搜索'),
                onTap: () => Navigator.pop(ctx, 'search'),
              ),
              ListTile(
                leading: const Icon(Symbols.bug_report_rounded),
                title: const Text('调试'),
                onTap: () => Navigator.pop(ctx, 'debug'),
              ),
              ListTile(
                leading: Icon(Symbols.delete_rounded, color: colorScheme.error),
                title: Text('删除',
                    style: TextStyle(color: colorScheme.error)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
              if (hasExplore)
                ListTile(
                  leading: Icon(source.enabledExplore
                      ? Symbols.explore_off_rounded
                      : Symbols.explore_rounded),
                  title:
                      Text(source.enabledExplore ? '禁用发现' : '启用发现'),
                  onTap: () => Navigator.pop(ctx, 'toggle_explore'),
                ),
            ],
          ),
        ),
      ),
    );

    if (action == null || !context.mounted) return;

    final notifier = ref.read(sourceNotifierProvider.notifier);
    switch (action) {
      case 'top':
        await notifier.moveSource(source.bookSourceUrl, toTop: true);
      case 'bottom':
        await notifier.moveSource(source.bookSourceUrl, toTop: false);
      case 'login':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceLoginScreen(
              sourceUrl: source.bookSourceUrl,
              sourceName: source.bookSourceName,
              loginUrl: source.loginUrl,
            ),
          ),
        );
      case 'search':
        // 对标原版 BookSourceActivity → SearchActivity.start(this, bookSource)
        final search = ref.read(searchNotifierProvider.notifier);
        search.clearAllFilter();
        search.toggleSource(source.bookSourceUrl);
        Navigator.of(context).pushNamed(AppRoutes.search);
      case 'debug':
        Navigator.of(context)
            .pushNamed(AppRoutes.sourceDebug, arguments: source.bookSourceUrl);
      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: '删除书源',
          content: '确定要删除书源「${source.bookSourceName}」吗？',
          confirmText: '删除',
          isDestructive: true,
        );
        if (confirmed && context.mounted) {
          notifier.deleteSource(source.bookSourceUrl);
        }
      case 'toggle_explore':
        await notifier.toggleExplore(source.bookSourceUrl);
    }
  }

  /// 书源管理帮助页（对标原版 showHelp("SourceMBookHelp")）
}
