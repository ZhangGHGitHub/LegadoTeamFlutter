import '../models/models.dart';
import '../routes.dart';

/// 按 BookType 位标记打开阅读器（对齐原版 `startActivityForBook` /
/// `BookInfoActivity.startReadActivity`）。
///
/// 书架已读直开与详情页「开始阅读」共用，避免分流逻辑复制漂移。
/// — Reasonix + UI
class BookOpenUtils {
  BookOpenUtils._();

  /// 媒体/文本类型位掩码（不含 local / notShelf）
  static const int typeMask = BookType.video |
      BookType.text |
      BookType.audio |
      BookType.image |
      BookType.webFile;

  /// 书源类型 → 书籍类型位标记（对齐原版 BookSourceExtensions.getBookType：
  /// 文本→text(8)、音频→audio(32)、图片→image(64)、文件→text|webFile(136)、
  /// 视频→video(4)）
  static int typeBitsForSource(int bookSourceType) {
    switch (bookSourceType) {
      case 1:
        return BookType.audio;
      case 2:
        return BookType.image;
      case 3:
        return BookType.text | BookType.webFile;
      case 4:
        return BookType.video;
      default:
        return BookType.text;
    }
  }

  /// 从书籍已有 bookType 提取媒体类型位
  static int typeBitsOf(Book book) => book.bookType & typeMask;

  /// 是否在线书籍（非本地、非 WebDAV）
  static bool isOnlineBook(Book book) =>
      book.origin.isNotEmpty &&
      book.origin != BookType.localTag &&
      !book.origin.startsWith(BookType.webDavTag);

  /// type=0 但实为视频源的启发式（MacCMS / 影视频源误标）。
  ///
  /// 设备证据：非凡资源网、量子资源网等 `bookSourceGroup=影视频源` 且
  /// `bookSourceType=0`，正文 `result=baseUrl`（章节 URL 即 m3u8）。
  /// 原版靠 `java.startBrowser` 外开播放；重构必须进 VideoScreen。
  ///
  /// **仅**在 `bookSourceType==0` 时启用；显式 1/2/3/4 以声明为准。
  /// 不用裸 `startBrowser`（小说源也常见）。— Reasonix + UI
  static bool looksLikeVideoSource(BookSource? source) {
    if (source == null) return false;
    if (source.bookSourceType == BookSourceType.video) return true;
    if (source.bookSourceType != BookSourceType.text) return false;

    final group = (source.bookSourceGroup ?? '').toLowerCase();
    final search = (source.searchUrl ?? '').toLowerCase();
    final explore = (source.exploreUrl ?? '').toLowerCase();
    final tocList = (source.ruleToc?.chapterList ?? '').toLowerCase();
    final content = source.ruleContent?.content ?? '';
    final sourceRegex = source.ruleContent?.sourceRegex ?? '';
    final blob = '$group\n$search\n$explore\n$tocList\n'
        '${content.toLowerCase()}\n${sourceRegex.toLowerCase()}';

    // MacCMS / 聚合资源站：目录或接口含 vod_play_url / provide/vod
    if (blob.contains('provide/vod') || blob.contains('vod_play_url')) {
      return true;
    }

    final isVideoGroup =
        group.contains('影视') || group.contains('视频源') || group.contains('视频');
    final playExt =
        RegExp(r'\.(m3u8|mp4|flv)', caseSensitive: false).hasMatch(
      '$content\n$sourceRegex',
    );
    // 非凡等：正文直接把章节 URL（m3u8）当作播放地址
    final returnsBaseUrl = RegExp(
      r'result\s*=\s*baseUrl',
      caseSensitive: false,
    ).hasMatch(content);
    if (isVideoGroup && (playExt || returnsBaseUrl)) {
      return true;
    }

    // sourceRegex 明确指向流媒体（伪七猫等，即使 type 误为 0）
    if (RegExp(r'm3u8|mp4|flv', caseSensitive: false).hasMatch(sourceRegex)) {
      return true;
    }
    return false;
  }

  /// 正文规则是否为「抽取 img HTML」（必应漫画等 type=0 看图源）。
  ///
  /// 原版文本阅读器会把 `<img>` 排进 TextChapterLayout；重构版文本排版尚无
  /// 内嵌图，此类源必须走漫画阅读器，否则用户只看到裸 HTML。
  /// — Reasonix + UI
  static bool looksLikeImageHtmlContentRule(String? contentRule) {
    if (contentRule == null) return false;
    final c = contentRule.trim().toLowerCase();
    if (c.isEmpty) return false;
    if (c.contains('@img@html')) return true;
    if (c.contains('cp_img@html')) return true;
    // 短规则 + @html + 图相关选择器（避免误伤长 JS 小说正文规则）
    if (c.length <= 120 &&
        c.contains('@html') &&
        (c.contains('img') ||
            c.contains('lazy-read') ||
            c.contains('.img') ||
            c.contains('#cp_img'))) {
      return true;
    }
    return false;
  }

  /// 书源是否应按漫画 UI 打开（type=0 但 imageStyle=FULL/SINGLE 且抽图规则）
  static bool isImageHtmlContentSource(BookSource? source) {
    if (source == null) return false;
    // 视频源（含 type=0 MacCMS 启发式）绝不以抽图规则升漫画
    if (looksLikeVideoSource(source)) return false;
    final style =
        (source.ruleContent?.imageStyle ?? '').trim().toUpperCase();
    // TEXT 表示按文字行内小图，仍走文本阅读器
    if (style == 'TEXT') return false;
    if (style.isNotEmpty && style != 'FULL' && style != 'SINGLE') {
      return false;
    }
    return looksLikeImageHtmlContentRule(source.ruleContent?.content);
  }

  /// 文本类型位提升为图片位（保留其它非媒体标记由调用方处理）
  static int promoteImageContentSource(int typeBits, BookSource? source) {
    if (!isImageHtmlContentSource(source)) return typeBits;
    if ((typeBits & (BookType.video | BookType.audio | BookType.image)) != 0) {
      return typeBits;
    }
    return (typeBits & ~BookType.text) | BookType.image;
  }

  /// 统一解析开读类型位（**书源媒体类型 / 视频启发式优先于抽图启发式**）。
  ///
  /// 对齐原版：`book.isVideo` → VideoPlayer，绝不进 ReadManga。
  /// 修复：仅当 `typeBits==0` 才补书源类型时，旧库 text/image 位会挡住
  /// type=4 或 type=0 视频源；抽图提升也曾误伤视频页。— Reasonix + UI
  static int resolveTypeBits(int bookTypeBits, BookSource? source) {
    final existing = bookTypeBits & typeMask;

    if (source != null) {
      final srcType = source.bookSourceType;
      // 显式音频/图片/文件/视频：书源声明优先于书籍旧位
      if (srcType >= BookSourceType.audio &&
          srcType <= BookSourceType.video) {
        return typeBitsForSource(srcType);
      }
      // type=0：视频启发式优先于抽图提升
      if (looksLikeVideoSource(source)) {
        return BookType.video;
      }
      final base = existing == 0 ? BookType.text : existing;
      // 已是视频/音频则不再抽图提升
      if ((base & (BookType.video | BookType.audio)) != 0) {
        return base;
      }
      return promoteImageContentSource(base, source);
    }

    return existing;
  }

  /// 按类型位选择路由名（video→/video、audio→/audio、image→/reader-comic、
  /// 其余→/reader）
  static String routeForTypeBits(int typeBits) {
    if ((typeBits & BookType.video) != 0) return AppRoutes.video;
    if ((typeBits & BookType.audio) != 0) return AppRoutes.audio;
    if ((typeBits & BookType.image) != 0) return AppRoutes.readerComic;
    return AppRoutes.reader;
  }

  /// 路由参数：video/audio 传 [Book]；漫画传 bookUrl；文本阅读器由
  /// ReaderNotifier 持有状态，无 arguments
  static Object? argumentsForRoute(String route, Book book) {
    switch (route) {
      case AppRoutes.video:
      case AppRoutes.audio:
        return book;
      case AppRoutes.readerComic:
        return book.bookUrl;
      default:
        return null;
    }
  }

  /// 是否走文本阅读器（需先 openBook 到 ReaderNotifier）
  static bool needsReaderNotifier(String route) => route == AppRoutes.reader;
}
