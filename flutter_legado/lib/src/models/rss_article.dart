/// RSS 文章模型
///
/// 原定义于服务层 `services/rust_api.dart`，因 UI 层（`rss_article_detail_screen`
/// 等）需引用该类型而被迫导入服务层，违反 §0.2 分层原则。现迁移至 models 层，
/// 由 `models.dart` 统一导出，UI 层与 `BookApi`/`RustApi` 均经 models 引用。
library;

import 'dart:convert';

/// 历史阅读记录 / 收藏的 `legacy:` 伪主键前缀
///
/// Rust 仓库层对空 `link` 落库为 `legacy:{origin}:{title}[:{sort}]`
/// （E4 维持，契约 §2.5），UI 读取历史记录时必须把这类值视为「无链接」。
const String kRssLegacyLinkPrefix = 'legacy:';

/// 历史记录 `link` 是否可用于打开原文
///
/// 空串与 `legacy:` 伪主键均视为无链接：不传 origin（避免触发规则正文
/// 抓取）、不发起外链跳转（审查 P2-3/P2-6）。
bool hasRssArticleLink(String? link) {
  final value = link?.trim() ?? '';
  return value.isNotEmpty && !value.startsWith(kRssLegacyLinkPrefix);
}

/// 阅读分流类型（对齐原版 `ReadRss.readRss` 取 `rssArticle.type`）
///
/// 文章 `type` 非 0 优先（列表规则解析复制源 `type`）；为 0 时回退源
/// `type`（批15f 用户口径：`RssSource.type` 0 网页 / 1 图片 / 2 视频）。
int resolveRssArticleType({required int articleType, int? sourceType}) {
  return articleType != 0 ? articleType : (sourceType ?? 0);
}

/// 取 `rssSortUrls` JSON 数组首项 `url`（singleUrl 打开地址，批15f）
///
/// 对齐 `RssViewModel.getSingleUrl`：取首项 URL；JSON 形态不符/空数组/
/// 首项无 url → `null`（调用方回退 `sourceUrl`）。
String? firstRssSortUrlFromJson(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List || decoded.isEmpty) return null;
    final first = decoded.first;
    if (first is! Map) return null;
    final url = (first['url'] as String? ?? '').trim();
    return url.isEmpty ? null : url;
  } catch (_) {
    return null;
  }
}

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

  /// 类型：0 网页 / 1 图片 / 2 视频（对齐 Kotlin `RssArticle.type`）
  ///
  /// 列表规则解析取源 `type`（`legado-fetcher::rss::parser_rule`）；默认
  /// 解析恒 0；DB 只读缓存载荷字段为 `type`，列表载荷为 `articleType`
  /// （serde camelCase），解析时两者兼容（批15f）。
  final int type;

  const RssFeedArticle({
    required this.title,
    required this.url,
    this.sort = '',
    this.description,
    this.pubDate,
    this.imageUrl,
    this.content,
    this.type = 0,
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
      type: _asInt(json['type'] ?? json['articleType']),
    );
  }

  /// 数字字段宽松转型（int / num / 数字字符串 → int；其余按 0）
  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
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
