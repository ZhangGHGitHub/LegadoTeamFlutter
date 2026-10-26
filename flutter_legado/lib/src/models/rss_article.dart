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

  /// 解析 Rust `RssArticleItem` / Mock 列表项（camelCase 字段）
  ///
  /// 字段口径见契约 §2.5：`link` 为文章链接（旧字段 `url` 兼容）、
  /// `image` 为封面（旧字段 `imageUrl` 兼容）；类型安全显式转型。
  factory RssFeedArticle.fromJson(Map<String, dynamic> json) {
    return RssFeedArticle(
      title: json['title'] as String? ?? '',
      url: (json['link'] ?? json['url']) as String? ?? '',
      sort: json['sort'] as String? ?? '',
      description: json['description'] as String?,
      pubDate: json['pubDate'] as String?,
      imageUrl: (json['image'] ?? json['imageUrl']) as String?,
      content: json['content'] as String?,
    );
  }
}

/// RSS 分类项（`sortUrl` 解析结果，契约 §2.5 `rssSortUrls`）
///
/// 对齐原版 `RssSortActivity` 的 `Pair<name, url>`：`name` 为分类显示名
/// （默认分类/无配置时为空串），`url` 为分类列表请求地址。
class RssSort {
  final String name;
  final String url;

  const RssSort({required this.name, required this.url});

  /// 解析 `[{"name","url"}]` 数组项（空值归一为空串）
  factory RssSort.fromJson(Map<String, dynamic> json) {
    return RssSort(
      name: (json['name'] as String? ?? '').trim(),
      url: (json['url'] as String? ?? '').trim(),
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'url': url};

  @override
  bool operator ==(Object other) =>
      other is RssSort && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);

  @override
  String toString() => 'RssSort(name: $name, url: $url)';
}
