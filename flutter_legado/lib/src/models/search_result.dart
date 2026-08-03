import 'book.dart';
import 'misc.dart';

/// 搜索结果包装
///
/// 原定义于服务层 `services/rust_api.dart`，因 `book_api.dart`（接口层）与
/// providers/UI 层需引用该类型而形成反向/跨层依赖，现迁移至 models 层，
/// 由 `models.dart` 统一导出（对齐 ReadingStatsToday 归位决议，
/// UI_RESTRUCTURE_PLAN.md 6.11）。保持定义不变，行为零变化。
class SearchResult {
  final Book book;
  final String sourceName;

  const SearchResult({required this.book, this.sourceName = ''});

  factory SearchResult.fromSearchBook(SearchBook sb) {
    return SearchResult(
      sourceName: sb.originName,
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
