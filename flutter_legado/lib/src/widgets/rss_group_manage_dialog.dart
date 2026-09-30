import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import 'group_manage_dialog.dart';

/// 订阅源分组管理弹窗（对标原版 GroupManageDialog）
///
/// [B2 统一批] 实现已收敛至泛型壳 [GroupManageDialog]（原 283 行同型重复
/// 实现 → 薄包装；订阅源域差异：分组字段 `sourceGroup` + `updateRssSource`）。
/// 原版分组存独立分组表；Flutter FFI 无分组表 API，分组只能从各源
/// sourceGroup 推导，故重命名/删除通过批量更新源实现，添加分组收拢未分组源。
/// 返回 true 表示数据有变更，调用方需刷新列表。
class RssGroupManageDialog extends ConsumerWidget {
  /// 当前全部订阅源（分组推导与批量更新的数据基础）
  final List<RssSource> sources;

  const RssGroupManageDialog({super.key, required this.sources});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GroupManageDialog<RssSource>(
      itemNoun: '订阅源',
      items: sources,
      groupOf: (s) => s.sourceGroup,
      copyWithGroup: (s, g) => s.copyWith(sourceGroup: g),
      update: (s) => ref.read(bookApiProvider).updateRssSource(s),
    );
  }
}
