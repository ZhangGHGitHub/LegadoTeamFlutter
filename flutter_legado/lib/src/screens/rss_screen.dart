import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/rss_provider.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_articles_screen.dart';

/// RSS 源列表页面
class RssScreen extends StatefulWidget {
  const RssScreen({super.key});

  @override
  State<RssScreen> createState() => _RssScreenState();
}

class _RssScreenState extends State<RssScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RssProvider>().loadSources();
    });
  }

  void _showAddSourceDialog() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加 RSS 源'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：少数派',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入名称' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'RSS 地址',
                  hintText: 'https://sspai.com/feed',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入 RSS 地址';
                  if (!v.startsWith('http')) return '地址必须以 http(s) 开头';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(dialogContext);
                context.read<RssProvider>().addSource(
                      nameController.text.trim(),
                      urlController.text.trim(),
                    );
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteSource(RssSource source) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除 RSS 源'),
        content: Text('确定要删除「${source.sourceName}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              context.read<RssProvider>().removeSource(source.sourceUrl);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSS 订阅'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => context.read<RssProvider>().loadSources(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddSourceDialog,
        icon: const Icon(Icons.add),
        label: const Text('添加源'),
      ),
      body: Consumer<RssProvider>(
        builder: (context, provider, _) {
          if (provider.isLoadingSources && provider.sources.isEmpty) {
            return const LoadingIndicator(message: '加载 RSS 源...');
          }

          if (provider.error != null && provider.sources.isEmpty) {
            return ErrorView(
              message: provider.error!,
              onRetry: () => provider.loadSources(),
            );
          }

          if (provider.isEmpty) {
            return const EmptyState(
              icon: Icons.rss_feed,
              title: '暂无 RSS 订阅',
              subtitle: '点击右下角按钮添加 RSS 源',
            );
          }

          return RefreshIndicator(
            onRefresh: () => provider.loadSources(),
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisExtent: 160,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: provider.sources.length,
              itemBuilder: (context, index) {
                final source = provider.sources[index];
                return _buildSourceCard(context, source);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildSourceCard(BuildContext context, RssSource source) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => RssArticlesScreen(source: source),
            ),
          );
        },
        onLongPress: () => _confirmDeleteSource(source),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图标
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    child: source.sourceIcon.isNotEmpty
                        ? ClipOval(
                            child: Image.network(
                              source.sourceIcon,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              errorBuilder: (_, e, s) => Text(
                                source.sourceName.isNotEmpty
                                    ? source.sourceName[0].toUpperCase()
                                    : 'R',
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                          )
                        : Text(
                            source.sourceName.isNotEmpty
                                ? source.sourceName[0].toUpperCase()
                                : 'R',
                            style: theme.textTheme.titleMedium,
                          ),
                  ),
                  const SizedBox(width: 8),
                  if (!source.enabled)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '已禁用',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // 名称
              Text(
                source.sourceName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              // 分组信息
              if (source.sourceGroup != null &&
                  source.sourceGroup!.isNotEmpty)
                Text(
                  source.sourceGroup!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
