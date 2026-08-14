/// 发现分类列表页码控件（对标 Android ExploreShowActivity menuPage）
///
/// 右上角「第 X 页」按钮 + 页码选择对话框（对标 NumberPickerDialog）。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/explore/explore_show_notifier.dart';

/// 发现分类页码按钮（AppBar actions 或双栏右栏顶栏）
class ExplorePageControl extends ConsumerWidget {
  final ExploreShowArgs args;

  /// 最大可选页码（对标原版 NumberPicker maxValue=999）
  final int maxPage;

  const ExplorePageControl({
    super.key,
    required this.args,
    this.maxPage = 999,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(exploreShowNotifierProvider(args));
    final pageLabel = state.displayPage > 0 ? state.displayPage : 1;

    return TextButton(
      onPressed: state.isLoading
          ? null
          : () => _showPagePicker(context, ref, pageLabel),
      child: Text(
        '第 $pageLabel 页',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Future<void> _showPagePicker(
    BuildContext context,
    WidgetRef ref,
    int currentPage,
  ) async {
    var picked = currentPage.clamp(1, maxPage);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择页码',
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        ref
                            .read(exploreShowNotifierProvider(args).notifier)
                            .skipToPage(picked);
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 216,
                child: CupertinoPicker(
                  scrollController: FixedExtentScrollController(
                    initialItem: picked - 1,
                  ),
                  itemExtent: 36,
                  onSelectedItemChanged: (index) => picked = index + 1,
                  children: List.generate(
                    maxPage,
                    (i) => Center(child: Text('第 ${i + 1} 页')),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
