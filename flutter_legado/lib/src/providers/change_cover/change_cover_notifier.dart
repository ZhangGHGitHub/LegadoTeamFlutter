import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'change_cover_state.dart';

export 'change_cover_state.dart';

/// 更换封面页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 网络封面搜索的数据获取由本 Notifier 负责，UI 层不再内联制造假数据。
/// - 封面候选经 `BookApi.searchCover` 委托 Rust（多书源搜索提取封面 URL，
///   契约见 API_CONTRACT.md §3 需求 3），返回项经 [CoverCandidate.fromJson]
///   解析（width/height 未知时为 0，渲染不依赖尺寸）。
/// - 本地选图为纯 UI 编排（FilePicker），不经过本 Notifier。
class ChangeCoverNotifier extends Notifier<ChangeCoverState> {
  @override
  ChangeCoverState build() => const ChangeCoverState();

  /// 按书名搜索网络封面候选（经 BookApi.searchCover 委托 Rust）
  ///
  /// 空字符串 / 纯空白被忽略；无候选时 Rust 返回空列表（非异常）。
  Future<void> searchCovers(String bookName) async {
    final keyword = bookName.trim();
    if (keyword.isEmpty) return;
    state = state.copyWith(isSearching: true, error: null);
    try {
      final raw = await ref.read(bookApiProvider).searchCover(keyword);
      final candidates = raw
          .whereType<Map<String, dynamic>>()
          .map(CoverCandidate.fromJson)
          .toList();
      state = state.copyWith(candidates: candidates, isSearching: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isSearching: false);
    }
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 更换封面 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(changeCoverNotifierProvider);
/// ref.read(changeCoverNotifierProvider.notifier).searchCovers(bookName);
/// ```
final changeCoverNotifierProvider =
    NotifierProvider<ChangeCoverNotifier, ChangeCoverState>(
  ChangeCoverNotifier.new,
);
