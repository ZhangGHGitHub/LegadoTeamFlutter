import 'package:freezed_annotation/freezed_annotation.dart';

part 'source_match.freezed.dart';
part 'source_match.g.dart';

/// 换源匹配结果（镜像 Rust 侧 `SourceMatch`，snake_case 序列化）
///
/// 由 `BookApi.searchSource` 返回的 Map 解析而来。Rust 侧
/// `SourceMatcher::rank_candidates` 已完成评分与排序（按 [score] 降序），
/// UI 侧直接按返回顺序渲染，不再重排（对齐 UI_RESTRUCTURE_PLAN.md §0.2/§0.3）。
@freezed
class SourceMatch with _$SourceMatch {
  const factory SourceMatch({
    /// 书源 URL
    @Default('') @JsonKey(name: 'source_url') String sourceUrl,

    /// 书源名称
    @Default('') @JsonKey(name: 'source_name') String sourceName,

    /// 书籍详情页 URL
    @Default('') @JsonKey(name: 'book_url') String bookUrl,

    /// 书籍名称
    @Default('') @JsonKey(name: 'book_name') String bookName,

    /// 作者
    @Default('') String author,

    /// 最新章节
    @JsonKey(name: 'latest_chapter') String? latestChapter,

    /// 字数信息
    @JsonKey(name: 'word_count') String? wordCount,

    /// 匹配度评分（0.0 ~ 100.0）
    @Default(0.0) double score,

    /// 试读章节字数展示
    @JsonKey(name: 'chapter_word_count_text') String? chapterWordCountText,

    /// 试读章节字数（-1=未知）
    @Default(-1) @JsonKey(name: 'chapter_word_count') int chapterWordCount,

    /// 取字耗时毫秒
    @Default(-1) @JsonKey(name: 'respond_time') int respondTime,

    /// 书源 customOrder
    @Default(0) @JsonKey(name: 'origin_order') int originOrder,

    /// 用户评分（-1 踩 / 0 无 / 1 赞，对标原版 SourceConfig 书维度评分）
    @Default(0) @JsonKey(name: 'book_score') int bookScore,
  }) = _SourceMatch;

  factory SourceMatch.fromJson(Map<String, dynamic> json) =>
      _$SourceMatchFromJson(json);
}
