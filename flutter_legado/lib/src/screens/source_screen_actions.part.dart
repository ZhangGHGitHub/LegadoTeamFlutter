// source_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SourceActions 承载：菜单动作/批量动作/导入对话框/帮助面板。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'source_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SourceActions on _SourceScreenState {
  void _showHelpSheet(BuildContext context) {
    showHelp(context, HelpAssets.sourceMBookHelp);
  }

  /// 分组菜单处理（对标原版 BookSourceActivity 分组子菜单）
  Future<void> _handleGroupAction(BuildContext context, String value) async {
    if (value == 'group_manage') {
      // P1-1：接通书源分组管理（对标 GroupManageDialog）
      final sources = ref.read(sourceNotifierProvider).sources;
      final changed = await showDialog<bool>(
        context: context,
        builder: (_) => BookSourceGroupManageDialog(sources: sources),
      );
      if (changed == true && context.mounted) {
        await ref.read(sourceNotifierProvider.notifier).loadSources();
      }
      return;
    }
    // 再次点击当前特殊分组时取消筛选
    final current = ref.read(sourceNotifierProvider).selectedGroup;
    final isSpecial = [
      SourceSpecialGroup.enabled,
      SourceSpecialGroup.disabled,
      SourceSpecialGroup.login,
      SourceSpecialGroup.exploreOn,
      SourceSpecialGroup.exploreOff,
    ].contains(value);
    ref.read(sourceNotifierProvider.notifier).setGroup(
          isSpecial && current == value ? null : value,
        );
  }

  void _handleAction(BuildContext context, String action) {
    switch (action) {
      case 'new':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SourceEditScreen()),
        );
        break;
      case 'new_js':
        // P0-1：最小可用 JS 书源编辑器（extractJsSource + 保存）
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const JsSourceEditScreen()),
        );
        break;
      case 'import_url':
        _showImportUrlDialog(context);
        break;
      case 'import_file':
        _importFromFile(context);
        break;
      case 'import_qr':
        _importFromQrCode(context);
        break;
      case 'group_by_domain':
        setState(() => _groupByDomain = !_groupByDomain);
        break;
      case 'help':
        // 对标原版 showHelp("SourceMBookHelp")
        _showHelpSheet(context);
        break;
    }
  }

  /// 选中所选区间（对标 adapter.checkSelectedInterval）
  void _selectSelectedInterval() {
    final state = ref.read(sourceNotifierProvider);
    final ordered = _displaySources(state.filteredSources);
    ref.read(sourceNotifierProvider.notifier).selectSelectedInterval(ordered);
  }

  /// 排序菜单项（对标 Android menu_sort_manual/auto/name/url + menu_sort_desc）
  List<PopupMenuEntry<String>> _buildSortMenuItems(BuildContext context) {
    final state = ref.read(sourceNotifierProvider);
    PopupMenuItem<String> sortItem(SourceSort sort, String label) {
      final selected = state.sort == sort;
      return PopupMenuItem(
        value: 'sort_${sort.name}',
        child: Row(
          children: [
            Icon(
              selected ? Symbols.check_rounded : null,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      );
    }

    return [
      PopupMenuItem(
        value: 'sort_desc',
        child: Row(
          children: [
            Icon(
              state.sortAscending ? null : Symbols.check_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('降序'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      sortItem(SourceSort.manual, '手动排序'),
      sortItem(SourceSort.weight, '自动排序（权重）'),
      sortItem(SourceSort.name, '按名称'),
      sortItem(SourceSort.url, '按 URL'),
      sortItem(SourceSort.update, '按更新时间'),
      sortItem(SourceSort.enable, '按启用状态'),
      sortItem(SourceSort.respond, '按响应时间'),
    ];
  }

  void _handleSortAction(BuildContext context, String action) {
    final notifier = ref.read(sourceNotifierProvider.notifier);
    if (action == 'sort_desc') {
      notifier.toggleSortDirection();
      return;
    }
    if (action.startsWith('sort_')) {
      final name = action.substring('sort_'.length);
      final sort = SourceSort.values.firstWhere(
        (e) => e.name == name,
        orElse: () => SourceSort.manual,
      );
      notifier.setSort(sort);
    }
  }

  /// 批量操作处理（对标原版 book_source_sel.xml 选择操作菜单）
  void _handleBatchAction(BuildContext context, String action) async {
    final notifier = ref.read(sourceNotifierProvider.notifier);
    final state = ref.read(sourceNotifierProvider);
    if (state.selectedCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择书源')),
      );
      return;
    }

    switch (action) {
      case 'enable':
        await notifier.batchEnable();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已启用所选书源')),
          );
        }
        break;
      case 'disable':
        await notifier.batchDisable();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已禁用所选书源')),
          );
        }
        break;
      case 'add_group':
        if (context.mounted) _showAddGroupDialog(context);
        break;
      case 'remove_group':
        if (context.mounted) _showRemoveGroupDialog(context);
        break;
      case 'enable_explore':
        await notifier.batchToggleExplore(true);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已启用所选书源发现')),
          );
        }
        break;
      case 'disable_explore':
        await notifier.batchToggleExplore(false);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已禁用所选书源发现')),
          );
        }
        break;
      case 'top':
        await notifier.batchMoveSelection(toTop: true);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已置顶所选书源')),
          );
        }
        break;
      case 'bottom':
        await notifier.batchMoveSelection(toTop: false);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已置底所选书源')),
          );
        }
        break;
      case 'export':
        await _exportBatchSelected(context);
        break;
      case 'share':
        await _shareBatchSelected(context);
        break;
      case 'check':
        await _startCheck(context);
        break;
      case 'select_range':
        _selectSelectedInterval();
        break;
      case 'delete':
        if (!context.mounted) return;
        final confirmed = await showConfirmDialog(
          context,
          title: '删除书源',
          content: '确定要删除选中的 ${state.selectedCount} 个书源吗？',
          confirmText: '删除',
          isDestructive: true,
        );
        if (confirmed && context.mounted) {
          await notifier.batchDelete();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已删除所选书源')),
            );
          }
        }
        break;
    }
  }

  /// 校验所选书源（对标原版 checkSource：关键词弹窗→校验选中源）
  Future<void> _startCheck(BuildContext context) async {
    final state = ref.read(sourceNotifierProvider);
    if (state.selectedCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要校验的书源')),
      );
      return;
    }
    final checkNotifier = ref.read(checkSourceNotifierProvider.notifier);
    if (ref.read(checkSourceNotifierProvider).checking) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('校验进行中，请先取消当前校验')),
      );
      return;
    }
    // 预填上次校验关键词（对标原版 CheckSource.keyword 持久化）
    final initial = await checkNotifier.loadKeyword();
    if (!context.mounted) return;
    // controller 由对话框内容组件自持（随子树卸载释放）
    final keyword = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: '校验所选书源',
        hintText: '输入校验关键词',
        confirmLabel: '开始校验',
        autofocus: true,
        initialText: initial,
      ),
    );
    if (keyword == null || !context.mounted) return;
    // [fix Task#45 | 2026-08-09] 更正当过时注释（Med2）：空关键词回落
    // 持久化（或默认）校验关键词，而非交给 Rust 侧用源自带关键词 — Qoder
    await checkNotifier.start(
      sourceUrls: state.selectedUrls.toList(),
      keyword: keyword,
    );
  }

  /// 添加分组输入框（对标原版 addGroup 弹窗）
  Future<void> _showAddGroupDialog(BuildContext context) async {
    // controller 由对话框内容组件自持（随子树卸载释放）
    final group = await showDialog<String>(
      context: context,
      builder: (_) => const _TextPromptDialog(
        title: '添加分组',
        hintText: '输入分组名称',
        confirmLabel: '确定',
        autofocus: true,
      ),
    );
    if (group == null || group.isEmpty || !context.mounted) return;

    final notifier = ref.read(sourceNotifierProvider.notifier);
    await notifier.batchAddGroup(group);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已为所选书源添加分组「$group」')),
      );
    }
  }

  /// 移除分组选择（对标原版 removeGroup：从选中书源已有分组中选择）
  Future<void> _showRemoveGroupDialog(BuildContext context) async {
    final state = ref.read(sourceNotifierProvider);
    // 收集选中书源的全部分组
    final groups = <String>{};
    for (final source in state.sources) {
      if (!state.selectedUrls.contains(source.bookSourceUrl)) continue;
      for (final g in (source.bookSourceGroup ?? '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)) {
        groups.add(g);
      }
    }
    if (groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所选书源没有可移除的分组')),
      );
      return;
    }

    final group = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('移除分组'),
        children: [
          for (final g in groups.toList()..sort())
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g),
              child: Text(g),
            ),
        ],
      ),
    );
    if (group == null || !context.mounted) return;

    final notifier = ref.read(sourceNotifierProvider.notifier);
    await notifier.batchRemoveGroup(group);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已从所选书源移除分组「$group」')),
      );
    }
  }

  /// 分享选中书源（对标原版 shareSelectedSource：写文件再分享，避免 Intent 过大）
  Future<void> _shareBatchSelected(BuildContext context) async {
    try {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final state = ref.read(sourceNotifierProvider);
      final json = await notifier.backupService
          .exportSelectedSources(state.selectedUrls.toList());
      final dir = await getTemporaryDirectory();
      final name = state.selectedCount == 1
          ? 'bookSource.json'
          : 'bookSource_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = File('${dir.path}/$name');
      await file.writeAsString(json);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        text: '书源分享（${state.selectedCount} 个）',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败：$e')),
        );
      }
    }
  }

  void _showImportUrlDialog(BuildContext context) async {
    // controller 由对话框内容组件自持（随子树卸载释放）：
    // 若在关闭回调中提前 dispose，退场动画中的 TextField 仍挂载着
    // 它，会触发 "used after disposed" 及 _dependents 断言级联
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _TextPromptDialog(
        title: '从 URL 导入书源',
        hintText: '输入书源 URL 地址',
        confirmLabel: '导入',
        requireNonEmpty: true,
      ),
    );
    if (url == null || url.trim().isEmpty || !context.mounted) return;
    // 对标原版：先拉取候选书源，进入导入确认页由用户勾选后入库
    await _fetchAndConfirm(() => ref
        .read(sourceNotifierProvider.notifier)
        .importService
        .fetchSourcesFromUrl(url.trim()));
  }

  /// 从本地文件导入书源（对标 Android menu_import_local，txt/json）
  ///
  /// 注：不使用 FileType.custom 扩展名过滤——低版本 Android（API 28）的
  /// SAF 会因 MIME 匹配问题禁用全部文件；改为任选文件，由解析层容错。
  Future<void> _importFromFile(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.platform.pickFiles();
      if (picked == null || picked.files.isEmpty) return;

      final path = picked.files.single.path;
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('无法获取文件路径')),
        );
        return;
      }

      if (!context.mounted) return;
      // 对标原版：先解析候选书源，进入导入确认页由用户勾选后入库
      await _fetchAndConfirm(() => ref
          .read(sourceNotifierProvider.notifier)
          .importService
          .fetchSourcesFromFile(path));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('从文件导入失败：$e')),
        );
      }
    }
  }

  /// 扫码导入书源（对标 Android menu_import_qr）
  ///
  /// 扫码页返回内容后按类型分流：HTTP URL → 远程拉取；书源 JSON → 直接解析；
  /// legado:// 协议链接 → 提示使用关联导入页（支持多类型）。
  Future<void> _importFromQrCode(BuildContext context) async {
    // [fix Task#24 | 2026-08-08] 去掉 <String> 泛型，避免 routes 表
    // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
    final raw = await Navigator.of(context).pushNamed(AppRoutes.qrcode);
    final content = raw is String ? raw : null;
    if (!context.mounted) return;
    if (content == null || content.trim().isEmpty) return;

    final trimmed = content.trim();
    final messenger = ScaffoldMessenger.of(context);

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      // 对标原版：先拉取候选书源，进入导入确认页由用户勾选后入库
      await _fetchAndConfirm(() => ref
          .read(sourceNotifierProvider.notifier)
          .importService
          .fetchSourcesFromUrl(trimmed));
      return;
    }

    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      await _fetchAndConfirm(() async => ref
          .read(sourceNotifierProvider.notifier)
          .importService
          .parseSourcesText(trimmed));
      return;
    }

    if (trimmed.startsWith('legado://') || trimmed.startsWith('yuedu://')) {
      final parsed = LegadoDeepLink.tryParse(trimmed);
      final srcUrl = parsed?.srcUrl;
      await showAssociationImportDialog(
        context,
        url: (srcUrl == null || srcUrl.isEmpty) ? null : srcUrl,
        type: parsed?.importType,
      );
      return;
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('扫码内容不是可识别的书源数据')),
    );
  }

  /// 拉取/解析候选书源并进入导入确认页
  /// （对标原版：importSource → comparisonSource → ImportBookSourceDialog）
  Future<void> _fetchAndConfirm(
    Future<List<SourcePreview>> Function() fetch,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    List<SourcePreview> sources;
    try {
      sources = await fetch();
    } catch (e) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      messenger.showSnackBar(
        SnackBar(content: Text('获取书源失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭加载指示

    if (sources.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('格式错误，未解析到书源')),
      );
      return;
    }

    final localSources = ref.read(sourceNotifierProvider).sources;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SourceImportConfirmScreen(
          sources: sources,
          localSources: localSources,
        ),
      ),
    );
    if (ok == true && mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('导入完成')));
    }
  }

  Future<void> _exportBatchSelected(BuildContext context) async {
    try {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final state = ref.read(sourceNotifierProvider);
      final json = await notifier.exportSelectedSources();

      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('已导出 ${state.selectedCount} 个书源到剪贴板')),
        );
      }
      notifier.exitBatchMode();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }
}
