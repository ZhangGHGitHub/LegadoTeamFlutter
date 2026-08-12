import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../providers/dict/dict_notifier.dart';

/// 词典查询 Dialog（对标原版 `ui/dict/DictDialog`）
///
/// 阅读器选词调用本 Dialog；「我的 → 词典规则」仍走全屏 [DictScreen] 做规则管理。
Future<void> showDictDialog(BuildContext context, {required String word}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DictDialog(word: word),
  );
}

/// 词典查询面板（底部 Sheet）
class DictDialog extends ConsumerStatefulWidget {
  final String word;

  const DictDialog({super.key, required this.word});

  @override
  ConsumerState<DictDialog> createState() => _DictDialogState();
}

class _DictDialogState extends ConsumerState<DictDialog>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(dictNotifierProvider.notifier);
      await notifier.loadRules();
      await notifier.lookup(widget.word);
      if (!mounted) return;
      final rules = ref.read(dictNotifierProvider).rules;
      // 本地结果 + 各在线规则各一页（对齐原版 TabLayout）
      _tabController?.dispose();
      setState(() {
        _tabController = TabController(length: 1 + rules.length, vsync: this);
      });
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<void> _launchOnline(DictRule rule) async {
    final uri = Uri.tryParse(rule.buildUrl(widget.word.trim()));
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开在线词典')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = ref.watch(dictNotifierProvider);
    final height = MediaQuery.sizeOf(context).height * 0.55;
    final tabs = <String>['本地', ...state.rules.map((r) => r.name)];

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              widget.word.trim(),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_tabController != null && tabs.length == _tabController!.length)
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [for (final t in tabs) Tab(text: t)],
            ),
          const Divider(height: 1),
          Expanded(
            child: state.isLoading && state.result == null
                ? const Center(child: CircularProgressIndicator())
                : _tabController == null
                    ? const Center(child: CircularProgressIndicator())
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildLocalBody(theme, state),
                          for (final rule in state.rules)
                            _buildOnlineBody(theme, rule),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalBody(ThemeData theme, DictState state) {
    if (state.error != null) {
      return Center(child: Text(state.error!));
    }
    final entry = state.result;
    if (entry == null || entry.definitions.isEmpty) {
      return Center(
        child: Text(
          '本地词典未收录',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (entry.phonetic.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              entry.phonetic,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.secondary,
              ),
            ),
          ),
        for (final def in entry.definitions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(def, style: theme.textTheme.bodyLarge),
          ),
      ],
    );
  }

  Widget _buildOnlineBody(ThemeData theme, DictRule rule) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '在 ${rule.name} 中查询「${widget.word.trim()}」',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _launchOnline(rule),
            icon: const Icon(Icons.open_in_browser),
            label: const Text('打开在线词典'),
          ),
        ],
      ),
    );
  }
}
