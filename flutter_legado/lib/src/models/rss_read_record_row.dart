import 'package:freezed_annotation/freezed_annotation.dart';

part 'rss_read_record_row.freezed.dart';
part 'rss_read_record_row.g.dart';

/// RSS 已读记录行（镜像 Rust `RssReadRecordRow`；`read_time` snake_case，
/// 扩展字段 camelCase（`pubDate` / `durPos`））
///
/// 由 `BookApi.rssListReadRecords` 返回的 Map 解析而来（按阅读时间降序，
/// 契约见 API_CONTRACT.md §2.35）。Rust 侧返回列为
/// `origin` / `title` / `link` / `read_time` / `type` / `sort` / `image` /
/// `pubDate` / `durPos`（legado-db `RssReadRecordRow`；`read_time` 为
/// snake_case，其余扩展字段对齐原版 Room 列名）。
///
/// 批20 扩展：`type`（0 网页 / 1 图片 / 2 视频）、`sort` 分类、
/// `image` 封面、`pubDate` 发布时间、`durPos` 阅读进度；旧数据缺省
/// `type=0` / `sort=''` / `durPos=0` / `image`/`pubDate` 为 null。
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

    /// 类型：0 网页 / 1 图片 / 2 视频（旧数据缺省 0）
    @Default(0) int type,

    /// 分类名（旧数据缺省空串）
    @Default('') String sort,

    /// 封面图
    String? image,

    /// 发布时间（原版 Room 列 `pubDate` 为 TEXT）
    String? pubDate,

    /// 阅读进度（旧数据缺省 0）
    @Default(0) int durPos,
  }) = _RssReadRecordRow;

  factory RssReadRecordRow.fromJson(Map<String, dynamic> json) =>
      _$RssReadRecordRowFromJson(json);
}
