import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import 'group_manage_dialog.dart';

/// 书源分组管理弹窗（对标原版 `ui/book/source/manage/GroupManageDialog`）
///
/// [B2 统一批] 实现已收敛至泛型壳 [GroupManageDialog]（原 295 行同型重复
/// 实现 → 薄包装；书源域差异：分组字段 `bookSourceGroup` + `updateBookSource`）。
/// 分组的推导/重命名/删除/添加逻辑与 UI 均在壳内，行为与收敛前一致。
/// 返回 true 表示数据有变更，调用方需刷新列表。
class BookSourceGroupManageDialog extends ConsumerWidget {
  /// 当前全部书源（分组推导与批量更新的数据基础）
  final List<BookSource> sources;

  const BookSourceGroupManageDialog({super.key, required this.sources});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GroupManageDialog<BookSource>(
      itemNoun: '书源',
      items: sources,
      groupOf: (s) => s.bookSourceGroup,
      copyWithGroup: (s, g) => s.copyWith(bookSourceGroup: g),
      update: (s) => ref.read(bookApiProvider).updateBookSource(s),
    );
  }
}
