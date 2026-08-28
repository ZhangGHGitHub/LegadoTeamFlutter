import 'package:flutter/material.dart';

import 'ios_widgets.dart';

/// M3 滚轮选择器底部弹层（UI_MD3_PLAN.md 全量清点：替换 CupertinoPicker 弹层）
///
/// 外壳走全局 bottomSheetTheme（surfaceContainerLow + 28dp 顶角）+ MD3 拖拽
/// 把手；滚轮用 Material 中立的 [ListWheelScrollView]（M3 时间选择器同款
/// 轮式语义），前景全 token 化。
///
/// 返回选中的 index（取消/点击遮罩返回 null）。
Future<int?> showMd3WheelPickerSheet({
  required BuildContext context,
  required String title,
  required int itemCount,
  required int initialIndex,
  required IndexedWidgetBuilder itemBuilder,
  bool showCancel = true,
}) {
  var picked = initialIndex.clamp(0, itemCount - 1);
  return showModalBottomSheet<int>(
    context: context,
    builder: (sheetContext) {
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IosGrabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(sheetContext).textTheme.titleSmall,
                    ),
                  ),
                  if (showCancel)
                    TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('取消'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext, picked),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 216,
              child: ListWheelScrollView.useDelegate(
                controller: FixedExtentScrollController(initialItem: picked),
                itemExtent: 36,
                perspective: 0.004,
                diameterRatio: 1.6,
                onSelectedItemChanged: (i) => picked = i,
                childDelegate: ListWheelChildBuilderDelegate(
                  childCount: itemCount,
                  builder: (ctx, i) => Center(
                    child: itemBuilder(ctx, i),
                  ),
                ),
              ),
            ),
            SizedBox(height: MediaQuery.paddingOf(sheetContext).bottom),
          ],
        ),
      );
    },
  ).then((v) => v?.clamp(0, itemCount - 1));
}
