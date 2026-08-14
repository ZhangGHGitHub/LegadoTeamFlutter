/// 发现分类控件 action 执行（对标 Android ExploreAdapter.evalButtonClick）
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../services/platform_bridge_service.dart';

/// 发现页控件 JS action 与中途 UI 回放
class ExploreKindActionRunner {
  /// 解析 viewName 字面量（`'标签'` 形式）
  static String? literalViewName(String? viewName) {
    if (viewName == null) return null;
    if (viewName.length >= 3 &&
        viewName.length <= 19 &&
        viewName.startsWith("'") &&
        viewName.endsWith("'")) {
      return viewName.substring(1, viewName.length - 1);
    }
    return null;
  }

  static Future<void> runAction({
    required WidgetRef ref,
    required String sourceJson,
    required String action,
    Future<void> Function()? onRefreshCategories,
  }) async {
    final api = ref.read(bookApiProvider);
    try {
      final result = await api.exploreEvalAction(
        sourceJson: sourceJson,
        actionJs: action,
      );
      final actions = result['actions'];
      if (actions is List && actions.isNotEmpty) {
        await PlatformBridgeService.instance.dispatchActions(actions);
      }
      if (result['refreshExplore'] == true) {
        await onRefreshCategories?.call();
      }
    } catch (e, stack) {
      debugPrint('[ExploreKind] action 执行失败: $e\n$stack');
    }
  }
}
