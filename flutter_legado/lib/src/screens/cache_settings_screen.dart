import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../services/cache_service.dart';

/// 缓存管理页面
///
/// 提供缓存统计显示、清理功能和自动过期策略配置。
/// 对应 Android 原版 CacheBookService 的缓存管理功能。
class CacheSettingsScreen extends ConsumerStatefulWidget {
  const CacheSettingsScreen({super.key});

  @override
  ConsumerState<CacheSettingsScreen> createState() => _CacheSettingsScreenState();
}

class _CacheSettingsScreenState extends ConsumerState<CacheSettingsScreen> {
  late final CacheService _cacheService;

  /// 缓存统计加载状态
  bool _loading = true;

  /// 清理操作进行中标记
  bool _clearing = false;

  /// 缓存总大小（字节）
  int _totalSize = 0;

  /// 缓存书籍数量
  int _bookCount = 0;

  /// 缓存章节数量
  int _chapterCount = 0;

  /// 当前自动过期天数（0 = 永不过期）
  int _expireDays = 0;

  /// 过期策略选项
  static const List<Map<String, dynamic>> _expireOptions = [
    {'days': 7, 'label': '7 天'},
    {'days': 30, 'label': '30 天'},
    {'days': 0, 'label': '永不过期'},
  ];

  @override
  void initState() {
    super.initState();
    final api = ref.read(bookApiProvider);
    _cacheService = CacheService(api);
    _loadStats();
    _loadExpireDays();
  }

  /// 加载缓存统计数据
  Future<void> _loadStats() async {
    setState(() => _loading = true);
    try {
      final stats = await _cacheService.getCacheStats();
      if (mounted) {
        setState(() {
          _totalSize = stats['totalSize'] as int;
          _bookCount = stats['bookCount'] as int;
          _chapterCount = stats['chapterCount'] as int;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  /// 加载自动过期天数配置
  Future<void> _loadExpireDays() async {
    final days = await _cacheService.getAutoExpireDays();
    if (mounted) {
      setState(() => _expireDays = days);
    }
  }

  /// 显示清理确认对话框
  void _showClearConfirmDialog() {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除缓存'),
        content: const Text('确定要清除所有缓存数据吗？此操作不可撤销。'),
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
    ).then((confirmed) {
      if (confirmed == true) {
        _doClearCache();
      }
    });
  }

  /// 执行缓存清理
  Future<void> _doClearCache() async {
    setState(() => _clearing = true);
    try {
      final cleared = await _cacheService.clearCache();
      // [Task #55 F4 | 2026-08-10] 清缓存成功后同步清除章级「删除重复
      // 标题」开关的 SP 镜像键，避免阅读器顶栏开关显示态漂移 — Qoder
      await CacheService.clearSameTitleRemovedFlags();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已清除 ${CacheService.formatSize(cleared)} 缓存'),
          ),
        );
        await _loadStats();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除缓存失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  /// 处理过期策略变更
  Future<void> _onExpireDaysChanged(int? days) async {
    if (days == null) return;
    setState(() => _expireDays = days);
    await _cacheService.setAutoExpireDays(days);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('过期策略已更新')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LegadoAppBar(title: const Text('缓存管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const SizedBox(height: 16),
                // ===== 缓存统计区域 =====
                _buildStatsSection(),
                const Divider(),
                // ===== 自动过期策略 =====
                _buildExpireSection(),
                const Divider(),
                // ===== 清理操作 =====
                _buildClearSection(),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  /// 构建缓存统计区域
  Widget _buildStatsSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '缓存统计',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  icon: Symbols.storage_rounded,
                  label: '总大小',
                  value: CacheService.formatSize(_totalSize),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  icon: Symbols.menu_book_rounded,
                  label: '书籍数量',
                  value: '$_bookCount',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  icon: Symbols.article_rounded,
                  label: '章节数量',
                  value: '$_chapterCount',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 构建单个统计卡片
  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建自动过期策略配置区域
  Widget _buildExpireSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自动过期策略',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            initialValue: _expireDays,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Symbols.schedule_rounded),
              labelText: '缓存过期时间',
            ),
            items: _expireOptions.map((option) {
              return DropdownMenuItem<int>(
                value: option['days'] as int,
                child: Text(option['label'] as String),
              );
            }).toList(),
            onChanged: _onExpireDaysChanged,
          ),
          const SizedBox(height: 8),
          Text(
            '超过设定时间的缓存将在下次启动时自动清除',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// 构建清理操作区域
  Widget _buildClearSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '清理操作',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _clearing ? null : _showClearConfirmDialog,
              icon: _clearing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Symbols.cleaning_services_rounded,
                      color: Theme.of(context).colorScheme.error,
                    ),
              label: Text(
                _clearing ? '清理中...' : '清除全部缓存',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Theme.of(context).colorScheme.error),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
