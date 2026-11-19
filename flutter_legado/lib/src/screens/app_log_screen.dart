import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../providers/app_log/app_log_notifier.dart';
import '../utils/error_message.dart';

/// 应用日志页面
///
/// [审计修复 §1.2 第二批] 对齐 Android 原版 AppLogDialog（关于页入口，
/// 查看 message/crash/http 三级日志）；数据经 AppLogNotifier → BookApi.appLog*。 — Qoder
class AppLogScreen extends ConsumerStatefulWidget {
  const AppLogScreen({super.key});

  @override
  ConsumerState<AppLogScreen> createState() => _AppLogScreenState();
}

class _AppLogScreenState extends ConsumerState<AppLogScreen>
    with SingleTickerProviderStateMixin {
  /// 页签显示名（与 AppLogNotifier.levels 一一对应）
  static List<String> get _tabLabels => [
        AppStrings.logTabMessage,
        AppStrings.logTabCrash,
        AppStrings.logTabHttp,
      ];

  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: AppLogNotifier.levels.length,
      vsync: this,
    );
    _tabController.addListener(_onTabChanged);
    // 首次加载默认级别
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(appLogNotifierProvider.notifier).load(AppLogNotifier.levels[0]);
    });
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    ref
        .read(appLogNotifierProvider.notifier)
        .load(AppLogNotifier.levels[_tabController.index]);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _confirmAndClear({required bool all}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        title: Text(all
            ? AppStrings.clearAllLogsTitle
            : AppStrings.clearCurrentLevelLogsTitle),
        content: Text(all
            ? AppStrings.clearAllLogsConfirm
            : AppStrings.clearCurrentLevelLogsConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final notifier = ref.read(appLogNotifierProvider.notifier);
    await (all ? notifier.clearAll() : notifier.clearCurrentLevel());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(all
            ? AppStrings.logsClearedAll
            : AppStrings.logsClearedCurrentLevel)),
      );
    }
  }

  Future<void> _export() async {
    try {
      final text = await ref.read(appLogNotifierProvider.notifier).export();
      if (!mounted) return;
      if (text.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
            SnackBar(content: Text(AppStrings.noLogsToExport)));
        return;
      }
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppStrings.logsCopiedToClipboard(text.length))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
          SnackBar(content: Text(AppStrings.exportFailedWithReason(errorMessage(e)))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appLogNotifierProvider);
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: Text(AppStrings.appLogTitle),
        // [MD3 Batch 6] 前景走全局 tabBarTheme（onSurface/onSurfaceVariant +
        // primary 指示器），与 M3 AppBar surface 背景配对（原白色系前瞻
        // 在 iOS 深色 AppBar 时期成立，M3 化后不可见）
        bottom: TabBar(
          controller: _tabController,
          // 全局 tabBarTheme 设了 TabAlignment.start，仅可滚动 TabBar 合法；
          // 非 scrollable 须显式 fill（对齐 toc_screen 处理）— 登录红屏修复
          tabAlignment: TabAlignment.fill,
          tabs: _tabLabels.map((label) => Tab(text: label)).toList(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            tooltip: AppStrings.refreshAction,
            onPressed: () => ref
                .read(appLogNotifierProvider.notifier)
                .load(state.currentLevel),
          ),
          PopupMenuButton<String>(
            tooltip: AppStrings.logActions,
            onSelected: (value) {
              switch (value) {
                case 'clear_level':
                  _confirmAndClear(all: false);
                case 'clear_all':
                  _confirmAndClear(all: true);
                case 'export':
                  _export();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'clear_level',
                  child: Text(AppStrings.clearCurrentLevel)),
              PopupMenuItem(
                  value: 'clear_all', child: Text(AppStrings.clearAllLogs)),
              PopupMenuItem(
                  value: 'export',
                  child: Text(AppStrings.exportToClipboard)),
            ],
          ),
        ],
      ),
      body: _buildBody(context, state),
    );
  }

  Widget _buildBody(BuildContext context, AppLogState state) {
    final theme = Theme.of(context);
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            AppStrings.loadFailedWithReason('${state.error}'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (state.logs.isEmpty) {
      return Center(
        child: Text(
          AppStrings.noLogsForLevel(state.currentLevel),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      // [LAYOUT_PLAN P3] 页面水平边距 12→16（全局标尺）
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: state.logs.length,
      itemBuilder: (context, index) {
        final entry = state.logs[index];
        return Container(
          // [LAYOUT_PLAN P3] 日志卡 margin bottom4→8、圆角 6→8（全局标尺方向收敛）
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.3,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8 方向收敛（原 10/6）
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.timeText,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                entry.message,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
