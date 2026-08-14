import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/app_log/app_log_notifier.dart';

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
  static const _tabLabels = ['消息', '崩溃', 'HTTP'];

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
        title: Text(all ? '清空全部日志' : '清空当前级别日志'),
        content: Text(all ? '将清空 message/crash/http 全部级别日志，确定吗？' : '确定清空当前级别的日志吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final notifier = ref.read(appLogNotifierProvider.notifier);
    await (all ? notifier.clearAll() : notifier.clearCurrentLevel());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(all ? '已清空全部日志' : '已清空当前级别日志')),
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
        ).showSnackBar(const SnackBar(content: Text('暂无日志可导出')));
        return;
      }
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已复制到剪贴板（${text.length} 字符）')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appLogNotifierProvider);
    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('应用日志'),
        // AppBar 内 TabBar 必须白色系前景（设计规范 §5.1 / 既往缺陷模式）
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          // 全局 tabBarTheme 设了 TabAlignment.start，仅可滚动 TabBar 合法；
          // 非 scrollable 须显式 fill（对齐 toc_screen 处理）— 登录红屏修复
          tabAlignment: TabAlignment.fill,
          tabs: _tabLabels.map((label) => Tab(text: label)).toList(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => ref
                .read(appLogNotifierProvider.notifier)
                .load(state.currentLevel),
          ),
          PopupMenuButton<String>(
            tooltip: '日志操作',
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
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear_level', child: Text('清空当前级别')),
              PopupMenuItem(value: 'clear_all', child: Text('清空全部')),
              PopupMenuItem(value: 'export', child: Text('导出到剪贴板')),
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
            '加载失败：${state.error}',
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
          '暂无 ${state.currentLevel} 级别日志',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: state.logs.length,
      itemBuilder: (context, index) {
        final entry = state.logs[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.3,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
