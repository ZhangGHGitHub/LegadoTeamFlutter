import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'change_source_state.freezed.dart';

/// 换源页不可变状态
///
/// 由 [ChangeSourceNotifier] 维护，对标原 change_source_screen 内部字段
/// （_results/_isSearching/_error/_applyingUrl）迁移至 Riverpod 后的表达。
@freezed
class ChangeSourceState with _$ChangeSourceState {
  const factory ChangeSourceState({
    /// 匹配到的候选书源列表（Rust 已按评分降序排序，UI 直接渲染）
    @Default([]) List<SourceMatch> results,

    /// 是否正在搜索
    @Default(false) bool isLoading,

    /// 错误信息
    String? error,

    /// 正在应用切换的书源 URL（null 表示无切换进行中）
    String? applyingUrl,

    /// 本轮搜索的书源数量（仅 isLoading 时非 null；体检 U1 等待反馈，
    /// T6 流式 API 落地前暂以「源数量+时长」替代逐源 x/y 进度）
    int? searchingCount,

    /// 已完成书源数（T6 流式：批次 finished_count，搜索中非 null）
    int? progressFinished,

    /// 参与搜索的书源总数（T6 流式：批次 total_count，权威值来自 Rust）
    int? progressTotal,

    /// 最后完成的书源名（2026-09-24 换源感知等待：批次 source_name，
    /// 对齐上游 changeSourceProgress 进度串「结果 N，当前进度 M/K: 源名」，
    /// upstream values-zh/strings.xml:1457）
    String? progressLastSourceName,
  }) = _ChangeSourceState;
}

/// 展示层派生属性
extension ChangeSourceStateDisplay on ChangeSourceState {
  /// 是否有匹配结果
  bool get hasResults => results.isNotEmpty;

  /// 是否正在切换书源
  bool get isApplying => applyingUrl != null;

  /// T6 流式进度文案（2026-09-24 换源感知等待：对齐上游 zh「结果 %1$d,
  /// 当前进度 %2$d / %3$d: %4$s」，upstream values-zh/strings.xml:1457 +
  /// ChangeBookSourceDialog.kt L286-298）：结果数 N + 进度 M/K + 最后完成源名
  /// （[progressLastSourceName] 缺失/为空时退化为「结果 N，进度 M/K」）
  String loadingProgressLabel(int resultCount) {
    final x = progressFinished;
    final y = progressTotal;
    if (x != null && y != null && y > 0) {
      final name = progressLastSourceName;
      return name != null && name.isNotEmpty
          ? '结果 $resultCount，进度 $x/$y：$name'
          : '结果 $resultCount，进度 $x/$y';
    }
    return '结果 $resultCount，搜索中…';
  }
}
