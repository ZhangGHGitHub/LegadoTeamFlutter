import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/reading_stats_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 阅读统计页面
class ReadingStatsScreen extends StatefulWidget {
  const ReadingStatsScreen({super.key});

  @override
  State<ReadingStatsScreen> createState() => _ReadingStatsScreenState();
}

class _ReadingStatsScreenState extends State<ReadingStatsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ReadingStatsProvider>().loadStats();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读统计'),
        actions: [
          Consumer<ReadingStatsProvider>(
            builder: (context, provider, _) => SegmentedButton<StatsPeriod>(
              segments: const [
                ButtonSegment(value: StatsPeriod.week, label: Text('周')),
                ButtonSegment(value: StatsPeriod.month, label: Text('月')),
              ],
              selected: {provider.period},
              onSelectionChanged: (s) => provider.setPeriod(s.first),
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Consumer<ReadingStatsProvider>(
        builder: (context, provider, _) {
          if (provider.loading && provider.dailyStats.isEmpty) {
            return const LoadingIndicator(message: '加载统计数据...');
          }
          if (provider.error != null && provider.dailyStats.isEmpty) {
            return ErrorView(
              message: provider.error!,
              onRetry: () => provider.loadStats(),
            );
          }
          return RefreshIndicator(
            onRefresh: () => provider.loadStats(),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTodayCards(context, provider),
                  const SizedBox(height: 24),
                  _buildDailyBarChart(context, provider),
                  const SizedBox(height: 24),
                  _buildBookDistribution(context, provider),
                  const SizedBox(height: 24),
                  _buildHeatmap(context, provider),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ===== 今日统计卡片 =====

  Widget _buildTodayCards(BuildContext context, ReadingStatsProvider provider) {
    final stats = provider.today;
    return Row(
      children: [
        Expanded(
          child: _StatsCard(
            icon: Icons.access_time,
            label: '今日阅读',
            value: _formatDuration(stats.durationSeconds),
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatsCard(
            icon: Icons.text_fields,
            label: '阅读字数',
            value: _formatWordCount(stats.wordCount),
            color: Theme.of(context).colorScheme.tertiary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatsCard(
            icon: Icons.speed,
            label: '阅读速度',
            value: '${stats.readingSpeed} 字/分',
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
      ],
    );
  }

  // ===== 每日阅读时长柱状图 =====

  Widget _buildDailyBarChart(
      BuildContext context, ReadingStatsProvider provider) {
    final daily = provider.dailyStats;
    final sortedKeys = daily.keys.toList()..sort();
    final values = sortedKeys.map((k) => daily[k] ?? 0).toList();
    final maxVal = values.isEmpty
        ? 1
        : values.reduce((a, b) => a > b ? a : b).clamp(1, 999999);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          provider.period == StatsPeriod.week ? '本周阅读时长' : '本月阅读时长',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(sortedKeys.length, (i) {
              final ratio = values[i] / maxVal;
              final label = sortedKeys[i].substring(5); // MM-DD
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        _formatDurationShort(values[i]),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontSize: 9,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      FractionallySizedBox(
                        heightFactor: ratio.clamp(0.05, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        label,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontSize: 9,
                            ),
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  // ===== 各书籍阅读时间占比 =====

  Widget _buildBookDistribution(
      BuildContext context, ReadingStatsProvider provider) {
    final bookStats = provider.bookStats;
    if (bookStats.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '书籍阅读分布',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          const Center(child: Text('暂无数据')),
        ],
      );
    }
    final total = provider.totalBookDuration;
    final sorted = bookStats.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '书籍阅读分布',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 12),
        ...sorted.map((entry) {
          final pct = total > 0 ? entry.value / total : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${(pct * 100).toStringAsFixed(1)}%',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct,
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ===== 阅读热力图 =====

  Widget _buildHeatmap(BuildContext context, ReadingStatsProvider provider) {
    final heatmap = provider.heatmap;
    if (heatmap.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '阅读日历（最近30天）',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 12),
          const Center(child: Text('暂无数据')),
        ],
      );
    }
    final sortedKeys = heatmap.keys.toList()..sort();
    final maxVal = heatmap.values
        .reduce((a, b) => a > b ? a : b)
        .clamp(1, 999999);
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '阅读日历（最近30天）',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 3,
          runSpacing: 3,
          children: sortedKeys.map((key) {
            final val = heatmap[key] ?? 0;
            final intensity = val / maxVal;
            final dayLabel = key.length >= 10 ? key.substring(8) : key;
            return Tooltip(
              message: '$key：${_formatDuration(val)}',
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: val == 0
                      ? colorScheme.surfaceContainerHighest
                      : colorScheme.primary.withValues(alpha: (intensity * 0.9 + 0.1)),
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: Text(
                  dayLabel,
                  style: TextStyle(
                    fontSize: 8,
                    color: intensity > 0.5 ? Colors.white : null,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('少', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 4),
            for (final alpha in [0.1, 0.3, 0.5, 0.7, 0.9])
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(left: 2),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: alpha),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 4),
            Text('多', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ],
    );
  }

  // ===== 格式化工具 =====

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '0分钟';
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) return '$hours时$mins分';
    return '$mins分钟';
  }

  String _formatDurationShort(int seconds) {
    if (seconds <= 0) return '0';
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) return '${hours}h${mins}m';
    return '${mins}m';
  }

  String _formatWordCount(int count) {
    if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万';
    return '$count';
  }
}

/// 统计卡片组件
class _StatsCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatsCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 8),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
