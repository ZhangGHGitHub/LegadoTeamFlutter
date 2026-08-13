import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../providers/association/association_state.dart';
import '../providers/search/search_notifier.dart';
import '../providers/source/source_notifier.dart';
import '../providers/source_check/check_source_notifier.dart';
import '../routes.dart';
import '../services/source_import_service.dart' show SourcePreview;
import '../theme/app_colors.dart';
import '../utils/legado_deep_link.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/book_source_group_manage_dialog.dart';
import '../widgets/confirm_dialog.dart';
import 'source_edit_screen.dart';
import 'js_source_edit_screen.dart';
import 'source_import_confirm_screen.dart';
import 'source_login_screen.dart';

/// 书源管理页面
class SourceScreen extends ConsumerStatefulWidget {
  const SourceScreen({super.key});

  @override
  ConsumerState<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends ConsumerState<SourceScreen> {
  /// 顶栏搜索框（对标原版 activity_book_source.xml 的 view_search）
  final _searchCtrl = TextEditingController();

  /// 校验会话结束后的总结 SnackBar 是否已展示（防 build 重复触发）
  bool _checkToastShown = false;

  /// 按域名分组显示（对标原版 menu_group_sources_by_domain）
  bool _groupByDomain = false;

  /// 上一帧的校验进行中状态（检测结束瞬间）
  bool _checkingForToast = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // [Task #70 D2 修复 | 2026-08-10] 搜索框 controller 随 State 重建
      //（初始为空），但 filterKeyword 位于全局 sourceNotifierProvider：
      // 若不同步重置，离屏返回时搜索框为空而过滤关键词残留，
      // filteredSources 恒空 → 整表误显示「暂无书源」（69 实机回归
      // D2 观察项根因，重启进程后 provider 重建才恢复） — Qoder
      ref.read(sourceNotifierProvider.notifier).clearFilter();
      ref.read(sourceNotifierProvider.notifier).loadSources();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sourceNotifierProvider);

    return PopScope(
      canPop: !state.batchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && state.batchMode) {
          ref.read(sourceNotifierProvider.notifier).exitBatchMode();
        }
      },
      child: Scaffold(
        appBar: state.batchMode
            ? _buildBatchAppBar(context, state)
            : _buildAppBar(context, state),
        body: _buildBody(context),
        // 底部常驻批量操作栏（全选/反选/删除/更多选项，
        // 对标原版 SelectActionBar + book_source_sel.xml）；
        // 非批量模式下点击全选/反选会自动进入批量模式
        bottomNavigationBar: _buildBatchBottomBar(context, state),
      ),
    );
  }

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
            prefixIcon: Icon(Icons.search,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            // 压缩前缀图标占位，为提示文字腾出完整显示空间
            prefixIconConstraints: const BoxConstraints(
              minWidth: 36,
              minHeight: 36,
            ),
            suffixIcon: state.filterKeyword.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear,
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
          icon: const Icon(Icons.sort),
          tooltip: '排序',
          // 菜单在顶栏下方展开，不覆盖顶栏
          position: PopupMenuPosition.under,
          onSelected: (value) => _handleSortAction(context, value),
          itemBuilder: (_) => _buildSortMenuItems(context),
        ),
        // 安卓原版：分组按钮常驻顶栏（menu_group 子菜单）
        PopupMenuButton<String>(
          icon: const Icon(Icons.groups),
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
              child: _MenuRow(icon: Icons.add, label: '新建书源'),
            ),
            const PopupMenuItem(
              value: 'new_js',
              child: _MenuRow(icon: Icons.code, label: '新建 JS 书源'),
            ),
            const PopupMenuItem(
              value: 'import_file',
              child: _MenuRow(icon: Icons.download, label: '本地导入'),
            ),
            const PopupMenuItem(
              value: 'import_url',
              child:
                  _MenuRow(icon: Icons.cloud_download, label: '网络导入'),
            ),
            const PopupMenuItem(
              value: 'import_qr',
              child: _MenuRow(icon: Icons.qr_code, label: '二维码导入'),
            ),
            PopupMenuItem(
              value: 'group_by_domain',
              child: _MenuRow(
                icon: Icons.domain,
                label: _groupByDomain ? '按域名分组显示 ✓' : '按域名分组显示',
              ),
            ),
            const PopupMenuItem(
              value: 'help',
              child: _MenuRow(icon: Icons.help_outline, label: '帮助'),
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
        icon: const Icon(Icons.close),
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
      return Expanded(
        child: InkWell(
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              // 全选/取消全选（带当前进度 n/m，对标原版计数文案）
              barButton(
                icon: state.isAllSelected
                    ? Icons.check_box
                    : Icons.check_box_outline_blank,
                label:
                    '全选 ${state.selectedCount}/$filteredCount',
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
              // 反选
              barButton(
                icon: Icons.flip,
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
              // 删除（危险操作标红，对标原版 delete）
              barButton(
                icon: Icons.delete_outline,
                label: '删除',
                color: colorScheme.error,
                onPressed: state.selectedCount == 0
                    ? null
                    : () => _handleBatchAction(context, 'delete'),
              ),
              // 更多选项（book_source_sel.xml 全量选择操作菜单）
              Expanded(
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
                          Icons.more_horiz,
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
                  icon: const Icon(Icons.close, size: 18),
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
        icon: Icons.library_books_outlined,
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
      return ListView.builder(
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
      );
    }

    return ListView.separated(
      itemCount: sources.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, index) {
        final source = sources[index];
        return state.batchMode
            ? _buildBatchSourceItem(context, source, state)
            : _buildSourceItem(context, source);
      },
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // 源名（对标 cb_book_source 文本 16sp）+ 校验消息副标题
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.bookSourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 16, color: colorScheme.onSurface),
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
            // 启用开关（对标 swt_enabled）
            Switch(
              value: source.enabled,
              onChanged: (_) => ref
                  .read(sourceNotifierProvider.notifier)
                  .toggleSource(source.bookSourceUrl),
            ),
            // 编辑图标（对标 iv_edit）
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
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
                  icon: const Icon(Icons.more_vert, size: 20),
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
                      // 发现启用=系统绿；有发现但未启用=系统红
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
                  Text(
                    source.bookSourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16, color: colorScheme.onSurface),
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
            // 启用开关（对标 swt_enabled）
            Switch(
              value: source.enabled,
              onChanged: (_) => ref
                  .read(sourceNotifierProvider.notifier)
                  .toggleSource(source.bookSourceUrl),
            ),
            // 编辑图标（对标 iv_edit）
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
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
                  icon: const Icon(Icons.more_vert, size: 20),
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
                leading: const Icon(Icons.vertical_align_top),
                title: const Text('置顶'),
                enabled: manualSort,
                onTap: () => Navigator.pop(ctx, 'top'),
              ),
              ListTile(
                leading: const Icon(Icons.vertical_align_bottom),
                title: const Text('置底'),
                enabled: manualSort,
                onTap: () => Navigator.pop(ctx, 'bottom'),
              ),
              if (hasLoginUrl)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('登录'),
                  onTap: () => Navigator.pop(ctx, 'login'),
                ),
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('搜索'),
                onTap: () => Navigator.pop(ctx, 'search'),
              ),
              ListTile(
                leading: const Icon(Icons.bug_report_outlined),
                title: const Text('调试'),
                onTap: () => Navigator.pop(ctx, 'debug'),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: colorScheme.error),
                title: Text('删除',
                    style: TextStyle(color: colorScheme.error)),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
              if (hasExplore)
                ListTile(
                  leading: Icon(source.enabledExplore
                      ? Icons.explore_off_outlined
                      : Icons.explore_outlined),
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

  /// 书源管理帮助页（对标原版 showHelp("SourceMBookHelp")，
  /// 内容取自 assets/web/help/md/SourceMBookHelp.md 全文）
  void _showHelpSheet(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget section(String title, [List<String> bullets = const []]) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            for (final bullet in bullets)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('• ',
                        style: textTheme.bodyMedium
                            ?.copyWith(color: colorScheme.primary)),
                    Expanded(
                      child: Text(bullet,
                          style: textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: IosGrabber()),
              const SizedBox(height: 12),
              Text('书源管理界面帮助',
                  style:
                      textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      section('书源右上角标志', [
                        '绿点表示书源有发现，且启用了发现',
                        '红点表示书源有发现，但是未启用',
                        '没有标志表示此书源没有发现',
                      ]),
                      section(
                          '右上角有分组菜单，可以按分组筛选书源'),
                      section('右上角更多菜单里包含', [
                        '新建书源 / 本地导入 / 网络导入 / 二维码导入',
                        '按域名分组显示 / 帮助',
                      ]),
                      section(
                          '选择源的更多操作在底部菜单里面，操作都是针对选择的书源', [
                        '启用所选 / 禁用所选 / 添加分组 / 移除分组',
                        '启用发现 / 禁用发现 / 置顶所选 / 置底所选',
                        '导出所选 / 校验所选',
                      ]),
                      section(
                          '校验书源可批量校验书源，由于网络等原因结果仅供参考', [
                        '“校验成功”是指所选的校验项目全部通过',
                        '可正常识别搜索为空、发现为空、搜索(发现)目录为空、搜索(发现)正文为空、校验超时、js执行错误导致的失效，其余的原因视为网站失效',
                        '校验搜索优先使用书源填写的校验关键词，不存在时使用用户输入的关键词',
                        '校验结束后会自动筛选“失效”书源',
                      ]),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
              selected ? Icons.check : null,
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
              state.sortAscending ? null : Icons.check,
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
      await Navigator.of(context).pushNamed(
        AppRoutes.association,
        arguments: <String, dynamic>{
          'raw': trimmed,
          'url': parsed?.srcUrl ?? '',
          if (parsed?.importType != null)
            'type': switch (parsed!.importType!) {
              ImportType.bookSource => 'bookSource',
              ImportType.rssSource => 'rssSource',
              ImportType.replaceRule => 'replaceRule',
              ImportType.theme => 'theme',
              ImportType.httpTts => 'httpTts',
              ImportType.dictRule => 'dictRule',
              ImportType.txtTocRule => 'txtTocRule',
            },
          'autoLoad': parsed?.importType != null,
        },
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

/// 书源列表行：域名头或书源项（域名分组模式）
class _SourceListRow {
  final String? header;
  final BookSource? source;

  const _SourceListRow.header(this.header) : source = null;
  const _SourceListRow.item(this.source) : header = null;

  bool get isHeader => header != null;
}

/// 溢出菜单图标行（对标原版菜单项的 icon + title 结构）
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    );
  }
}

/// 文本输入对话框内容组件：controller 生命周期绑定对话框子树，
/// 随子树卸载统一释放（避免退场动画期间 dispose 引发框架断言）
class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final String confirmLabel;
  final bool autofocus;

  /// 预填文本（如校验关键词持久化回显）
  final String? initialText;

  /// 为 true 时确认按钮在输入为空时不关闭对话框
  final bool requireNonEmpty;

  const _TextPromptDialog({
    required this.title,
    required this.hintText,
    required this.confirmLabel,
    this.autofocus = false,
    this.initialText,
    this.requireNonEmpty = false,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        decoration: InputDecoration(hintText: widget.hintText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (widget.requireNonEmpty && text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
