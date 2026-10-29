// 目录「已缓存」显示口径单元测试（批39）
//
// 显示宽松：文本书按 URL 集合命中即已缓存（Rust 侧只过滤空正文行，
// 缺图章节仍在集合内）；音频书按音频缓存下标；本地书不显示徽标。
// 下载严格口径位于 Rust（cache_download_api 逐章抓取），不在此重复。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/toc_cache_state.dart';

void main() {
  group('tocChapterCacheBadge', () {
    test('本地书恒不显示徽标（恒视为已缓存）', () {
      expect(
        tocChapterCacheBadge(
          isLocal: true,
          isAudioBook: false,
          audioCached: false,
          textCached: false,
        ),
        TocChapterCacheBadge.none,
      );
      expect(
        tocChapterCacheBadge(
          isLocal: true,
          isAudioBook: true,
          audioCached: false,
          textCached: false,
        ),
        TocChapterCacheBadge.none,
      );
    });

    test('文本书：URL 命中即已缓存（缺图不影响，宽松口径）', () {
      // Rust listCachedChapterUrls 只过滤空正文行 → 缺图章节仍在集合内
      expect(
        tocChapterCacheBadge(
          isLocal: false,
          isAudioBook: false,
          audioCached: false,
          textCached: true,
        ),
        TocChapterCacheBadge.cached,
      );
      expect(
        tocChapterCacheBadge(
          isLocal: false,
          isAudioBook: false,
          audioCached: false,
          textCached: false,
        ),
        TocChapterCacheBadge.uncached,
      );
    });

    test('音频书：按音频缓存下标集合判定（文本集合不参与）', () {
      expect(
        tocChapterCacheBadge(
          isLocal: false,
          isAudioBook: true,
          audioCached: true,
          textCached: false,
        ),
        TocChapterCacheBadge.cached,
      );
      expect(
        tocChapterCacheBadge(
          isLocal: false,
          isAudioBook: true,
          audioCached: false,
          textCached: true,
        ),
        TocChapterCacheBadge.uncached,
      );
    });
  });
}
