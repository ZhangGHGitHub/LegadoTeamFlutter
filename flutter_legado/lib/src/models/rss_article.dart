/// RSS 文章模型
///
/// 原定义于服务层 `services/rust_api.dart`，因 UI 层（`rss_article_detail_screen`
/// 等）需引用该类型而被迫导入服务层，违反 §0.2 分层原则。现迁移至 models 层，
/// 由 `models.dart` 统一导出，UI 层与 `BookApi`/`RustApi` 均经 models 引用。
library;

/// RSS 文章（用于 UI 展示）
class RssFeedArticle {
  final String title;
  final String url;

  /// 分类名（`sortName`；缺省空串）
  ///
  /// 契约 §2.5 批15c：详情页把该值透传给 `rssFetchContent(sort:)`，用于
  /// `(origin, link, sort)` 主键精确写回；缺省按 order DESC 取首行。
  final String sort;
  final String? description;
  final String? pubDate;
  final String? imageUrl;
  final String? content;

  const RssFeedArticle({
    required this.title,
    required this.url,
    this.sort = '',
    this.description,
    this.pubDate,
    this.imageUrl,
    this.content,
  });
}
