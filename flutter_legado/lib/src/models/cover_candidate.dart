import 'package:freezed_annotation/freezed_annotation.dart';

part 'cover_candidate.freezed.dart';
part 'cover_candidate.g.dart';

/// 网络封面候选项（镜像未来 Rust `searchCover` 返回项，snake_case 序列化）
///
/// 由 `BookApi.searchCover(bookName)` 返回的 Map 解析而来（契约见
/// API_CONTRACT.md §3 需求 3）。Rust 轨交付前，`ChangeCoverNotifier` 以 Mock
/// 数据先行驱动该模型；交付后将 Notifier 内 Mock 切换为 `searchCover` 调用即可，
/// 模型字段即为冻结契约。
@freezed
class CoverCandidate with _$CoverCandidate {
  const factory CoverCandidate({
    /// 封面图片 URL
    @Default('') String url,

    /// 图片宽度（像素，0 表示未知）
    @Default(0) int width,

    /// 图片高度（像素，0 表示未知）
    @Default(0) int height,
  }) = _CoverCandidate;

  factory CoverCandidate.fromJson(Map<String, dynamic> json) =>
      _$CoverCandidateFromJson(json);
}
