// 书籍详情页「相关书」数据 Provider（R42 阶段 1）
//
// 契约 §2.55：`BookApi.getRelatedBooks({bookUrl}) → Future<String>`，返回
// `{"modules":[{key,title,url,resolvedUrl,books:[…]}]}`；Rust 侧无配置 /
// 全部模块失败 / 过滤当前书后全空一律返回 `{"modules":[]}`（**不抛错**）。
//
// 职责边界（UI 层不含业务逻辑）：
// - 本文件负责 FFI 调用 + JSON 解析 + 降级，产出不可变 Domain Model；
// - UI 只消费 `List<RelatedBooksModule>`，不做任何 jsonDecode。
//
// 降级语义（与参考版 RelatedBooks.load 一致）：
// - 请求异常 / JSON 非法 / 结构不符 → 空模块列表（区块隐藏，不打扰用户）；
// - 单本书条目解析失败 → 跳过该书，保留同模块其余书；
// - 无 books 的模块 → 跳过（Rust 已过滤，此处为纵深防御）。
//
// `books[]` 元素是 Rust `WebSearchResult` 的 serde 序列化（snake_case：
// `book_url` / `cover_url` / `source_url` / `latest_chapter` / `word_count`），
// 与 `SearchBook.fromJson` 期望的 camelCase 键不一致，故此处显式归一化
// （与 `rust_api_discovery_cache.part.dart::_searchBookFromExplore` 同口径），
// 再经 `SearchResult.fromSearchBook` 转成 UI 侧 `Book`。
//
// 编写：全栈工程师 ｜ 2026-11-21
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../providers.dart';

/// 单个相关书模块（不可变 Domain Model）
///
/// 对齐参考版 `RelatedBooks.Module`：一个模块 = 一个标题 + 一批书。
@immutable
class RelatedBooksModule {
  /// 模块标识（书源配置 `key`，缺省回退 title）
  final String key;

  /// 模块标题（可为空：空标题时 UI 只渲染书列表）
  final String title;

  /// 配置里的原始 url（未做变量替换）
  final String url;

  /// 变量替换 + 重定向后的最终 url
  final String resolvedUrl;

  /// 书籍列表（已过滤当前书）
  final List<Book> books;

  const RelatedBooksModule({
    this.key = '',
    this.title = '',
    this.url = '',
    this.resolvedUrl = '',
    this.books = const [],
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RelatedBooksModule &&
          key == other.key &&
          title == other.title &&
          url == other.url &&
          resolvedUrl == other.resolvedUrl &&
          listEquals(books, other.books);

  @override
  int get hashCode => Object.hash(key, title, url, resolvedUrl, books.length);
}

/// 解析 `getRelatedBooks` 返回的 JSON
///
/// 纯函数（无 IO），便于单元测试；任何异常/非法结构一律返回空列表。
List<RelatedBooksModule> parseRelatedBooksJson(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    debugPrint('[相关书] 返回 JSON 解析失败，按无数据处理：$e');
    return const [];
  }
  if (decoded is! Map) return const [];
  final rawModules = decoded['modules'];
  if (rawModules is! List) return const [];

  final modules = <RelatedBooksModule>[];
  for (final item in rawModules) {
    if (item is! Map) continue;
    final books = <Book>[];
    final rawBooks = item['books'];
    if (rawBooks is List) {
      for (final entry in rawBooks) {
        if (entry is! Map) continue;
        final book = _bookFromWebSearchResult(entry.cast<String, dynamic>());
        if (book != null) books.add(book);
      }
    }
    // 无书的模块不渲染（对齐参考版 takeIf { filtered.isNotEmpty() }）
    if (books.isEmpty) continue;
    modules.add(
      RelatedBooksModule(
        key: _str(item['key']),
        title: _str(item['title']),
        url: _str(item['url']),
        resolvedUrl: _str(item['resolvedUrl']),
        books: List.unmodifiable(books),
      ),
    );
  }
  return List.unmodifiable(modules);
}

/// 相关书 Provider（family + autoDispose）
///
/// family key = 书籍稳定主键 `bookUrl`：不同书各自独立缓存，离开详情页
/// 即释放。空 bookUrl 不发请求（空态详情页不触发 FFI）。
final relatedBooksProvider =
    FutureProvider.autoDispose.family<List<RelatedBooksModule>, String>((
      ref,
      bookUrl,
    ) async {
      final url = bookUrl.trim();
      if (url.isEmpty) return const [];
      try {
        final raw = await ref
            .read(bookApiProvider)
            .getRelatedBooks(bookUrl: url);
        return parseRelatedBooksJson(raw);
      } catch (e) {
        // 相关书是可选内容：任何失败都降级为空（不向 UI 抛错）
        debugPrint('[相关书] 加载失败，按无数据处理：$e');
        return const [];
      }
    });

// ─── 归一化辅助 ─────────────────────────────────────────────

/// Rust `WebSearchResult`（snake_case）→ Dart `Book`
///
/// 兼容 snake_case 与 camelCase 两种键名；`origin` 取 `source_url`（相关书
/// 与当前书同源，Rust 侧已填书源 URL）。书名/书址为空视为无效条目返回 null。
Book? _bookFromWebSearchResult(Map<String, dynamic> json) {
  final origin = _pick(json, 'origin', 'source_url') ?? '';
  final bookUrl = _absoluteUrl(
    origin,
    _pick(json, 'bookUrl', 'book_url'),
  );
  final name = _pick(json, 'name', 'name') ?? '';
  if (bookUrl.isEmpty || name.isEmpty) return null;
  final searchBook = SearchBook(
    bookUrl: bookUrl,
    origin: origin,
    originName: _pick(json, 'originName', 'source_name') ?? '',
    name: name,
    author: _pick(json, 'author', 'author') ?? '',
    kind: _pick(json, 'kind', 'kind'),
    coverUrl: _absoluteUrlOrNull(
      origin,
      _pick(json, 'coverUrl', 'cover_url'),
    ),
    intro: _pick(json, 'intro', 'intro'),
    wordCount: _pick(json, 'wordCount', 'word_count'),
    latestChapterTitle: _pick(
      json,
      'latestChapterTitle',
      'latest_chapter',
    ),
    tocUrl: _pick(json, 'tocUrl', 'toc_url') ?? '',
    bookType: _intOf(json['type']),
  );
  return SearchResult.fromSearchBook(searchBook).book;
}

/// 取 camelCase 优先、回落 snake_case 的非空字符串
String? _pick(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  final s = v?.toString();
  return (s != null && s.isNotEmpty) ? s : null;
}

String _str(Object? v) => v?.toString() ?? '';

int _intOf(Object? v) {
  if (v is int) return v;
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

/// 相对 URL 按书源基地址补齐（Rust explore 已给绝对地址，此处为纵深防御）
String _absoluteUrl(String base, String? url) {
  final u = (url ?? '').trim();
  if (u.isEmpty || base.isEmpty) return u;
  if (u.contains('://') || u.startsWith('data:')) return u;
  try {
    return Uri.parse(base).resolve(u).toString();
  } catch (_) {
    return u;
  }
}

String? _absoluteUrlOrNull(String base, String? url) {
  final u = _absoluteUrl(base, url);
  return u.isEmpty ? null : u;
}
