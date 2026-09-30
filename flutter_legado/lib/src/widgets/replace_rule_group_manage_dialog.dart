import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import 'group_manage_dialog.dart';

/// 替换规则分组管理弹窗（对标原版 `ui/replace/GroupManageDialog`）
///
/// [B2 统一批] 实现已收敛至泛型壳 [GroupManageDialog]（原 286 行同型重复
/// 实现 → 薄包装；替换规则域差异：分组字段 `group` + `updateReplaceRule`）。
/// 分组推导/重命名/删除/添加逻辑与 UI 均在壳内，行为与收敛前一致。
/// 返回 true 表示数据有变更，调用方需刷新列表。
class ReplaceRuleGroupManageDialog extends ConsumerWidget {
  /// 当前全部替换规则（分组推导与批量更新的数据基础）
  final List<ReplaceRule> rules;

  const ReplaceRuleGroupManageDialog({super.key, required this.rules});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GroupManageDialog<ReplaceRule>(
      itemNoun: '规则',
      items: rules,
      groupOf: (r) => r.group,
      copyWithGroup: (r, g) => r.copyWith(group: g),
      update: (r) => ref.read(bookApiProvider).updateReplaceRule(r),
    );
  }
}
