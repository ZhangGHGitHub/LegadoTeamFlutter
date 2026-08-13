import 'book.dart';
import 'misc.dart';

/// 搜索结果包装（对齐原版 SearchBook：同名同作者可聚合多 origin）
///
/// 原定义于服务层 `services/rust_api.dart`，因 `book_api.dart`（接口层）与
/// providers/UI 层需引用该类型而形成反向/跨层依赖，现迁移至 models 层，
/// 由 `models.dart` 统一导出（对齐 ReadingStatsToday 归位决议，
/// UI_RESTRUCTURE_PLAN.md 6.11）。
class SearchResult {
  final Book book;
  final String sourceName;

  /// 同书多源 origin 集合（对齐原版 `SearchBook.origins`）
  ///
  /// 单源命中时通常仅含 [book.origin]；mergeItems 聚合后可含多个书源 URL。
  final Set<String> origins;

  /// 是否有阅读记录（Rust 流式搜索附加 `hasReadRecord`，对齐原版橙点）
  final bool hasReadRecord;

  const SearchResult({
    required this.book,
    this.sourceName = '',
    Set<String>? origins,
    this.hasReadRecord = false,
  }) : origins = origins ?? const {};

  /// 有效来源数（对齐原版 `origins.size` / `bv_originCount`）
  int get originsCount {
    final e = effectiveOrigins;
    return e.isEmpty ? 1 : e.length;
  }

  /// 展示用 origins（保证至少含当前 book.origin）
  Set<String> get effectiveOrigins {
    if (origins.isNotEmpty) return origins;
    final o = book.origin;
    return o.isEmpty ? const {} : {o};
  }

  SearchResult copyWith({
    Book? book,
    String? sourceName,
    Set<String>? origins,
    bool? hasReadRecord,
  }) {
    return SearchResult(
      book: book ?? this.book,
      sourceName: sourceName ?? this.sourceName,
      origins: origins ?? this.origins,
      hasReadRecord: hasReadRecord ?? this.hasReadRecord,
    );
  }

  /// 合并另一来源（对齐原版 `SearchBook.addOrigin`：保留首条元数据，追加 origin）
  SearchResult withAddedOrigin(SearchResult other) {
    final next = {...effectiveOrigins, ...other.effectiveOrigins};
    if (other.book.origin.isNotEmpty) next.add(other.book.origin);
    return copyWith(
      origins: next,
      // 任一来源有阅读记录即保留标识
      hasReadRecord: hasReadRecord || other.hasReadRecord,
    );
  }

  factory SearchResult.fromSearchBook(
    SearchBook sb, {
    bool hasReadRecord = false,
  }) {
    final origin = sb.origin;
    return SearchResult(
      sourceName: sb.originName,
      origins: origin.isEmpty ? const {} : {origin},
      hasReadRecord: hasReadRecord,
      book: Book(
        bookUrl: sb.bookUrl,
        tocUrl: sb.tocUrl,
        origin: sb.origin,
        originName: sb.originName,
        name: sb.name,
        author: sb.author,
        kind: sb.kind,
        coverUrl: sb.coverUrl,
        intro: sb.intro,
        bookType: sb.bookType,
        latestChapterTitle: sb.latestChapterTitle,
        wordCount: sb.wordCount,
        originOrder: sb.originOrder,
      ),
    );
  }
}
