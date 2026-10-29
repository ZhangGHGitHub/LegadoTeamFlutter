// 目录章节「已缓存」显示判定（批39）
//
// 对齐参考版 `TocViewModel.kt:293-320`：
// - 显示用**宽松**判定：有正文即算已缓存（缺图不再判为未缓存）；
// - 下载/缓存链路仍用**严格**口径（正文 + 图片），且不消费本判定
//   （Rust `cache_download_api` 逐章抓取；数据侧证据见
//   `cache_download_api::tests::test_download_strict_even_when_loose_cache_exists`）。
//
// 本仓的「有正文」由 Rust `listCachedChapterUrls` / `listCachedChapters`
// 过滤空 `content` 行保证（§2.43.5/§2.43.6），Dart 侧只负责按书型选择
// 数据源（本地书恒已缓存 / 音频书下标集合 / 文本书 URL 集合）。

/// 目录行缓存徽标三态（对齐参考版 LOCAL / SUCCESS / NONE 显示分支）
enum TocChapterCacheBadge {
  /// 本地书：恒视为已缓存但不显示徽标（原版 `isLocalBook` 语义）
  none,

  /// 已缓存（宽松：有正文即命中）
  cached,

  /// 未缓存（可点击下载）
  uncached,
}

/// 目录行缓存徽标判定（宽松）
///
/// - 本地书：[_Badge.none]（恒视为已缓存，不显示对勾）；
/// - 音频书：按音频缓存下标集合（契约 §2.47）；
/// - 文本书：按已缓存章节 URL 集合（契约 §2.43.5，Rust 侧已过滤空正文行，
///   缺图不影响）。
TocChapterCacheBadge tocChapterCacheBadge({
  required bool isLocal,
  required bool isAudioBook,
  required bool audioCached,
  required bool textCached,
}) {
  if (isLocal) return TocChapterCacheBadge.none;
  return (isAudioBook ? audioCached : textCached)
      ? TocChapterCacheBadge.cached
      : TocChapterCacheBadge.uncached;
}

// 注意：下载侧严格判定（正文 + 图片，参考版
// `BookHelp.isChapterCacheComplete`）在本仓位于 Rust
// `cache_download_api::download_one`（逐章抓取，不读显示集合），
// Dart 侧不重复实现，避免两套判定漂移。
