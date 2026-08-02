import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import 'change_cover_state.dart';

export 'change_cover_state.dart';

/// 更换封面页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 网络封面搜索的数据获取由本 Notifier 负责，UI 层不再内联制造假数据。
/// - Rust 轨交付 `BookApi.searchCover` 前，以 Mock 数据先行驱动 [CoverCandidate]
///   数据流（见 API_CONTRACT.md §3 需求 3）；交付后仅需将 [_mockSearch] 替换为
///   `ref.read(bookApiProvider).searchCover(keyword)` 并解析返回，模型字段即契约。
/// - 本地选图为纯 UI 编排（FilePicker），不经过本 Notifier。
class ChangeCoverNotifier extends Notifier<ChangeCoverState> {
  @override
  ChangeCoverState build() => const ChangeCoverState();

  /// 按书名搜索网络封面候选
  ///
  /// 空字符串 / 纯空白被忽略。当前以 Mock 数据驱动，待 Rust `searchCover` 交付后切换。
  Future<void> searchCovers(String bookName) async {
    final keyword = bookName.trim();
    if (keyword.isEmpty) return;
    state = state.copyWith(isSearching: true, error: null);
    try {
      // TODO(Rust 轨交付 searchCover 后切换为真实契约调用):
      //   import '../providers.dart';
      //   final raw = await ref.read(bookApiProvider).searchCover(keyword);
      //   final candidates = raw
      //       .whereType<Map<String, dynamic>>()
      //       .map(CoverCandidate.fromJson)
      //       .toList();
      final candidates = _mockSearch(keyword);
      state = state.copyWith(candidates: candidates, isSearching: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isSearching: false);
    }
  }

  /// Mock 封面搜索：按书名生成确定性候选（占位数据，待 Rust 契约替换）
  List<CoverCandidate> _mockSearch(String keyword) {
    final base = keyword.hashCode.abs();
    return List.generate(
      8,
      (i) => CoverCandidate(
        url: 'https://picsum.photos/seed/${base + i}/240/320',
        width: 240,
        height: 320,
      ),
    );
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
