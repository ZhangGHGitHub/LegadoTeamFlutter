/// 发现分类列表页码控件（对标参考版 ExploreShow 顶栏页码按钮）
///
/// 参考版行为（`legado-with-MD3/.../ui/book/explore/ExploreShowScreen.kt:439-470`
/// 与 `ExploreShowViewModel.kt:357-380`）：
/// 1. 仅当当前分类规则支持页码（`AnalyzeUrl.supportsPageSelection`）时展示，
///    不支持则整体隐藏；
/// 2. 点击弹数字输入对话框（只收数字、最多 4 位、页码 ≥1 才可确认）；
/// 3. 确认后跳转对应页，列表按该页结果重建（与加载更多互斥）。
///
/// 早期实现是 1..999 的轮式选择器（无规则判断，任意分类都能跳页），
/// 本批按参考版语义改为「规则支持才显示 + 数字输入」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/explore/explore_show_notifier.dart';

/// 页码输入最大位数（对齐参考版 `input.filter(Char::isDigit).take(4)`）
const int explorePageInputMaxLength = 4;

/// 发现分类刷新按钮（批39 审查回修）
///
/// page > 1 时顶部下拉手势归「加载上一页」、下拉刷新被禁用；该按钮在
/// **任何页**都可用，点击回到第 1 页重新加载（与加载上一页/加载更多互斥，
/// 被忽略时提示「正在加载，请稍候再刷新」）。
///
/// 三个宿主（独立发现页 AppBar、平板双栏右栏顶栏、源内容模式分类行）共用。
class ExploreRefreshControl extends ConsumerWidget {
  final ExploreShowArgs args;

  const ExploreRefreshControl({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      key: const ValueKey('explore-refresh-action'),
      tooltip: '刷新',
      icon: const Icon(Symbols.refresh_rounded),
      onPressed: () async {
        final accepted = await ref
            .read(exploreShowNotifierProvider(args).notifier)
            .refresh();
        if (accepted || !context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('正在加载，请稍候再刷新'),
            duration: Duration(seconds: 1),
          ),
        );
      },
    );
  }
}

/// 发现分类页码按钮（AppBar actions 或双栏右栏顶栏）
class ExplorePageControl extends ConsumerWidget {
  final ExploreShowArgs args;

  const ExplorePageControl({super.key, required this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(exploreShowNotifierProvider(args));
    // 规则不支持页码 → 不展示按钮（对齐参考版 canJumpPage 条件）
    if (!state.canJumpPage) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final pageLabel = state.displayPage > 0 ? state.displayPage : 1;

    return TextButton(
      key: const ValueKey('explore-page-control'),
      // 加载中不再静默禁用按钮：点击明确提示，避免「点了没反应」
      // （加载上一页在途时同样互斥，跳页会改写整表）
      onPressed: () {
        final current = ref.read(exploreShowNotifierProvider(args));
        if (current.isLoading || current.isLoadingPrevious) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('正在加载，请加载完成后再跳页'),
              duration: Duration(seconds: 1),
            ),
          );
          return;
        }
        _showPageDialog(context, ref, pageLabel);
      },
      child: Text(
        '第 $pageLabel 页',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Future<void> _showPageDialog(
    BuildContext context,
    WidgetRef ref,
    int currentPage,
  ) async {
    final targetPage = await showDialog<int>(
      context: context,
      builder: (_) => _ExploreJumpPageDialog(currentPage: currentPage),
    );
    if (targetPage == null) return;
    // 跳页与加载更多互斥：Notifier 内部在加载中会忽略本次请求，
    // 跳页成功后 hasMore 由目标页结果决定
    await ref
        .read(exploreShowNotifierProvider(args).notifier)
        .skipToPage(targetPage);
  }
}

/// 页码数字输入弹层（controller 生命周期与弹层 State 绑定）
class _ExploreJumpPageDialog extends StatefulWidget {
  final int currentPage;

  const _ExploreJumpPageDialog({required this.currentPage});

  @override
  State<_ExploreJumpPageDialog> createState() => _ExploreJumpPageDialogState();
}

class _ExploreJumpPageDialogState extends State<_ExploreJumpPageDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentPage.toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 解析输入页码：空/非数字/0 均视为无效（确认按钮禁用）
  int? get _targetPage {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < 1) return null;
    return parsed;
  }

  @override
  Widget build(BuildContext context) {
    final target = _targetPage;
    return AlertDialog(
      title: const Text('跳转到页码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '输入目标页码（1-$_maxPageLabel），跳转后列表从该页开始加载',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(explorePageInputMaxLength),
            ],
            decoration: const InputDecoration(
              hintText: '页码（最多 4 位）',
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              final page = _targetPage;
              if (page != null) Navigator.of(context).pop(page);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: target == null
              ? null
              : () => Navigator.of(context).pop(target),
          child: const Text('确定'),
        ),
      ],
    );
  }

  /// 4 位数字输入的最大页码（9999），仅用于提示文案
  String get _maxPageLabel => '9' * explorePageInputMaxLength;
}
