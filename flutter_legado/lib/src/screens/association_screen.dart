import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/association/association_notifier.dart';
import '../routes.dart';

/// 统一关联导入页面
///
/// 支持导入类型：书源、RSS 源、替换规则、主题配置
/// 导入方式：从 URL 导入、从文件导入、从剪贴板导入、扫码导入（预留）
class AssociationScreen extends ConsumerStatefulWidget {
  const AssociationScreen({super.key});

  @override
  ConsumerState<AssociationScreen> createState() => _AssociationScreenState();
}

class _AssociationScreenState extends ConsumerState<AssociationScreen> {
  final _urlController = TextEditingController();
  bool _bootstrapped = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bootstrapped) return;
    _bootstrapped = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final url = args['url'];
      final typeName = args['type'];
      final autoLoad = args['autoLoad'] == true;
      if (url is String && url.isNotEmpty) {
        _urlController.text = url;
        final type = _parseType(typeName);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(associationNotifierProvider.notifier).bootstrapFromDeepLink(
                type: type,
                srcUrl: url,
                autoLoad: autoLoad && type != null,
              );
        });
      }
    }
  }

  ImportType? _parseType(Object? name) {
    return switch (name) {
      'bookSource' => ImportType.bookSource,
      'rssSource' => ImportType.rssSource,
      'replaceRule' => ImportType.replaceRule,
      'theme' => ImportType.theme,
      _ => null,
    };
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(associationNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('关联导入'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码导入',
            onPressed: () async {
              final navigator = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);
              // [fix Task#24 | 2026-08-08] 去掉 <String> 泛型，避免 routes 表
              // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
              final raw = await navigator.pushNamed(AppRoutes.qrcode);
              final result = raw is String ? raw : null;
              if (result != null && result.isNotEmpty) {
                _urlController.text = result;
                messenger.showSnackBar(
                  const SnackBar(content: Text('扫码内容已填入，请继续导入流程')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重置',
            onPressed: () =>
                ref.read(associationNotifierProvider.notifier).reset(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStepIndicator(context, state),
          const Divider(height: 1),
          Expanded(
            child: _buildStepContent(context, state),
          ),
        ],
      ),
    );
  }

  /// 步骤指示器
  Widget _buildStepIndicator(BuildContext context, AssociationState state) {
    final steps = ['选择类型', '输入来源', '预览内容', '完成'];
    final currentIndex = state.step.index;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: List.generate(steps.length, (index) {
          final isActive = index <= currentIndex;
          final isCurrent = index == currentIndex;

          return Expanded(
            child: Row(
              children: [
                if (index > 0)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  child: Center(
                    child: index < currentIndex
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isCurrent
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isActive
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
                if (index < steps.length - 1)
                  Expanded(
                    child: Container(
                      height: 2,
                      color: index < currentIndex
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  /// 步骤内容
  Widget _buildStepContent(BuildContext context, AssociationState state) {
    switch (state.step) {
      case ImportStep.selectType:
        return _buildSelectTypeStep(context, state);
      case ImportStep.inputSource:
        return _buildInputSourceStep(context, state);
      case ImportStep.preview:
        return _buildPreviewStep(context, state);
      case ImportStep.done:
        return _buildDoneStep(context, state);
    }
  }

  /// 步骤 1：选择导入类型
  Widget _buildSelectTypeStep(BuildContext context, AssociationState state) {
    final types = [
      (ImportType.bookSource, Icons.menu_book, '书源', '导入网络书源规则'),
      (ImportType.rssSource, Icons.rss_feed, 'RSS 源', '导入 RSS 订阅源'),
      (ImportType.replaceRule, Icons.find_replace, '替换规则', '导入内容替换规则'),
      (ImportType.theme, Icons.palette, '主题配置', '导入应用主题配置'),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '选择导入类型',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        ...types.map((item) {
          final (type, icon, title, subtitle) = item;
          final isSelected = state.type == type;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: isSelected ? 2 : 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () =>
                  ref.read(associationNotifierProvider.notifier).setType(type),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 32,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () =>
              ref.read(associationNotifierProvider.notifier).nextStep(),
          child: const Text('下一步'),
        ),
      ],
    );
  }

  /// 步骤 2：输入来源
  Widget _buildInputSourceStep(BuildContext context, AssociationState state) {
    final sources = [
      (ImportSource.url, Icons.link, 'URL', '从网络地址导入'),
      (ImportSource.file, Icons.file_open, '文件', '从本地文件导入'),
      (ImportSource.clipboard, Icons.content_paste, '剪贴板', '从剪贴板内容导入'),
      (ImportSource.qrCode, Icons.qr_code_scanner, '扫码', '扫描二维码导入（预留）'),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '选择导入方式',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        ...sources.map((item) {
          final (source, icon, title, subtitle) = item;
          final isSelected = state.source == source;
          final isDisabled = source == ImportSource.qrCode;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: isSelected ? 2 : 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: isDisabled
                  ? null
                  : () => ref
                      .read(associationNotifierProvider.notifier)
                      .setSource(source),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 28,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        // URL 输入框
        if (state.source == ImportSource.url) ...[
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '书源 URL',
              hintText: 'https://example.com/sources.json',
              prefixIcon: Icon(Icons.link),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            onChanged: (value) => ref
                .read(associationNotifierProvider.notifier)
                .setUrlInput(value),
          ),
          const SizedBox(height: 16),
        ],
        // 错误提示
        if (state.error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    state.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        // 加载按钮
        if (state.isLoading)
          const Center(child: CircularProgressIndicator())
        else
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => ref
                      .read(associationNotifierProvider.notifier)
                      .previousStep(),
                  child: const Text('上一步'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton(
                  onPressed: () => _loadPreview(context, state),
                  child: const Text('加载预览'),
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// 步骤 3：预览内容
  Widget _buildPreviewStep(BuildContext context, AssociationState state) {
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                state.error!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => ref
                    .read(associationNotifierProvider.notifier)
                    .previousStep(),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.previewItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              '没有可导入的内容',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => ref
                  .read(associationNotifierProvider.notifier)
                  .previousStep(),
              child: const Text('返回'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 统计信息
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 12),
              Text(
                '发现 ${state.previewCount} 个${state.typeName}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        // 预览列表
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: state.previewItems.length,
            itemBuilder: (context, index) {
              final item = state.previewItems[index];
              return _buildPreviewItem(context, item, index);
            },
          ),
        ),
        // 操作按钮
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => ref
                      .read(associationNotifierProvider.notifier)
                      .previousStep(),
                  child: const Text('返回'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () => _confirmImport(context),
                  icon: const Icon(Icons.download),
                  label: Text('确认导入 (${state.previewCount})'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 预览项
  Widget _buildPreviewItem(BuildContext context, dynamic item, int index) {
    String title = '项目 ${index + 1}';
    String? subtitle;

    if (item is Map<String, dynamic>) {
      // 尝试获取常见字段作为标题
      title = item['bookSourceName'] as String? ??
          item['sourceName'] as String? ??
          item['name'] as String? ??
          item['title'] as String? ??
          title;
      subtitle = item['bookSourceUrl'] as String? ??
          item['sourceUrl'] as String? ??
          item['url'] as String?;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            '${index + 1}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
      ),
    );
  }

  /// 步骤 4：完成
  Widget _buildDoneStep(BuildContext context, AssociationState state) {
    final result = state.lastResult;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              result != null && result.failed == 0
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              size: 64,
              color: result != null && result.failed == 0
                  ? Colors.green
                  : Colors.orange,
            ),
            const SizedBox(height: 16),
            Text(
              '导入完成',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            if (result != null) ...[
              Text(
                result.summary,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (result.hasErrors) ...[
                const SizedBox(height: 16),
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: result.errors
                        .map((e) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '• $e',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onErrorContainer,
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      ref.read(associationNotifierProvider.notifier).reset(),
                  child: const Text('继续导入'),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 加载预览
  Future<void> _loadPreview(
      BuildContext context, AssociationState state) async {
    final notifier = ref.read(associationNotifierProvider.notifier);
    switch (state.source) {
      case ImportSource.url:
        final url = _urlController.text.trim();
        if (url.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请输入 URL')),
          );
          return;
        }
        await notifier.loadFromUrl(url);
        break;
      case ImportSource.file:
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json', 'txt'],
        );
        if (result == null || result.files.isEmpty) return;
        final path = result.files.single.path;
        if (path == null) return;
        await notifier.loadFromFile(path);
        break;
      case ImportSource.clipboard:
        await notifier.loadFromClipboard();
        break;
      case ImportSource.qrCode:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('扫码功能需要移动设备，Windows 桌面端不支持'),
          ),
        );
        return;
    }

    // 如果加载成功且有预览项，进入下一步
    final currentState = ref.read(associationNotifierProvider);
    if (currentState.error == null && currentState.previewItems.isNotEmpty) {
      notifier.nextStep();
    }
  }

  /// 确认导入
  Future<void> _confirmImport(BuildContext context) async {
    final result =
        await ref.read(associationNotifierProvider.notifier).confirmImport();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.summary),
          backgroundColor: result.failed == 0 ? Colors.green : Colors.orange,
        ),
      );
    }
  }
}
