/// 今日阅读统计模型
///
/// 原定义于服务层 `services/rust_api.dart`，因 `book_api.dart`（接口层）与
/// providers 层需引用该类型而形成反向/跨层依赖，现迁移至 models 层，
/// 由 `models.dart` 统一导出（对齐 RssFeedArticle 归位决议，
/// UI_RESTRUCTURE_PLAN.md 6.3/6.11）。保持纯类定义不变，行为零变化。
library;

/// 今日阅读统计
class ReadingStatsToday {
  final int totalSeconds;
  final int bookCount;
  final int durationSeconds;
  final int wordCount;
  final double readingSpeed;

  const ReadingStatsToday({
    this.totalSeconds = 0,
    this.bookCount = 0,
    this.durationSeconds = 0,
    this.wordCount = 0,
    this.readingSpeed = 0,
  });
}
