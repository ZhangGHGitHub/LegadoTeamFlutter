import 'package:freezed_annotation/freezed_annotation.dart';

part 'rss_read_record_row.freezed.dart';
part 'rss_read_record_row.g.dart';

/// RSS 已读记录行（镜像 Rust `RssReadRecordRow`，snake_case 序列化）
///
/// 由 `BookApi.rssListReadRecords` 返回的 Map 解析而来（按阅读时间降序，
/// 契约见 API_CONTRACT.md §2.35）。Rust 侧当前返回列为
/// `origin` / `title` / `link` / `read_time`（legado-db
/// `RssReadRecordRow`，serde 默认 snake_case）；待 §4.2 P0-2 v96→97
/// 迁移对齐 Room v95 全列后扩展字段。
@freezed
class RssReadRecordRow with _$RssReadRecordRow {
  const factory RssReadRecordRow({
    /// 来源 URL
    @Default('') String origin,

    /// 文章标题
    @Default('') String title,

    /// 文章链接
    String? link,

    /// 阅读时间（Unix 毫秒）
    @Default(0) @JsonKey(name: 'read_time') int readTime,
  }) = _RssReadRecordRow;

  factory RssReadRecordRow.fromJson(Map<String, dynamic> json) =>
      _$RssReadRecordRowFromJson(json);
}
