import 'dart:convert';

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

  /// 实为视频源的启发式（MacCMS / 影视频源误标）。
  ///
  /// 设备证据（emulator-5558 导出）：
  /// - 非凡资源网：`bookSourceType=0` + `group=影视频源` + `provide/vod` /
  ///   `vod_play_url` + 正文 `result=baseUrl`（章节 URL 即 m3u8）
  /// - 红牛资源 / U酷资源：`bookSourceType=2`（误标图片）+ `group=影视频源`
  ///   + 正文规则含 `m3u8` 抽取
  ///
  /// 原版靠 `java.startBrowser` 外开；重构必须进 VideoScreen，**绝不**进 comic。
  /// 对 type=0/2 启用启发式；显式 audio/file/video(1/3/4) 不改写。
  /// 不用裸 `startBrowser`（小说源也常见）。— Reasonix + UI
  static bool looksLikeVideoSource(BookSource? source) {
    if (source == null) return false;
    if (source.bookSourceType == BookSourceType.video) return true;
    // 仅纠正文本(0)与误标图片(2)；音频/文件保持声明
    final st = source.bookSourceType;
    if (st != BookSourceType.text && st != BookSourceType.image) {
      return false;
    }

    final group = (source.bookSourceGroup ?? '').toLowerCase();
    final name = source.bookSourceName.toLowerCase();
    final srcUrl = source.bookSourceUrl.toLowerCase();
    final search = (source.searchUrl ?? '').toLowerCase();
    final explore = (source.exploreUrl ?? '').toLowerCase();
    final tocList = (source.ruleToc?.chapterList ?? '').toLowerCase();
    final content = source.ruleContent?.content ?? '';
    final sourceRegex = source.ruleContent?.sourceRegex ?? '';
    final contentLower = content.toLowerCase();
    final regexLower = sourceRegex.toLowerCase();
    final blob =
        '$group\n$name\n$srcUrl\n$search\n$explore\n$tocList\n$contentLower\n$regexLower';

    // MacCMS / 聚合资源站：目录或接口含 vod_play_url / provide/vod
    if (blob.contains('provide/vod') || blob.contains('vod_play_url')) {
      return true;
    }

    final isVideoGroup = group.contains('影视') ||
        group.contains('视频源') ||
        group.contains('视频');
    // 源名/域名常见 MacCMS 资源站（红牛/非凡/量子/U酷等）
    final isVideoName = (name.contains('资源') &&
            (name.contains('红牛') ||
                name.contains('非凡') ||
                name.contains('量子') ||
                name.contains('乌酷') ||
                name.contains('u酷') ||
                name.contains('最大') ||
                name.contains('影视') ||
                name.contains('视频'))) ||
        srcUrl.contains('hongniu') ||
        srcUrl.contains('ukuzy') ||
        srcUrl.contains('ffzy') ||
        srcUrl.contains('lzizy') ||
        srcUrl.contains('zuidazy');
    final playExt = RegExp(r'\.(m3u8|mp4|flv)', caseSensitive: false)
        .hasMatch('$content\n$sourceRegex');
    final hasStreamToken = RegExp(r'm3u8|mp4|flv|m3u', caseSensitive: false)
        .hasMatch('$content\n$sourceRegex\n$tocList');
    // 非凡等：正文直接把章节 URL（m3u8）当作播放地址
    final returnsBaseUrl = RegExp(
      r'result\s*=\s*baseUrl',
      caseSensitive: false,
    ).hasMatch(content);
    if ((isVideoGroup || isVideoName) &&
        (playExt || hasStreamToken || returnsBaseUrl)) {
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

  /// 统一解析开读类型位（**视频启发式优先于显式 type=2 与抽图提升**）。
  ///
  /// 对齐原版：`book.isVideo` → VideoPlayer，绝不进 ReadManga。
  /// 修复：红牛等 `bookSourceType=2` 误标图片时，旧逻辑直接 `typeBitsForSource(2)`
  /// → comic「暂无图片」；非凡 type=0 进文本刷 m3u8。— Reasonix + UI
  static int resolveTypeBits(int bookTypeBits, BookSource? source) {
    final existing = bookTypeBits & typeMask;

    if (source != null) {
      // 视频启发式优先于显式 image(2)：纠正 MacCMS 误标图片源
      if (looksLikeVideoSource(source)) {
        return BookType.video;
      }
      final srcType = source.bookSourceType;
      // 显式音频/图片/文件/视频：书源声明优先于书籍旧位
      if (srcType >= BookSourceType.audio &&
          srcType <= BookSourceType.video) {
        return typeBitsForSource(srcType);
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

  /// DB 记录是否已入书架（对标原版 inBookshelf = bookDao 有记录且非 notShelf）
  static bool isInBookshelf(Book? dbBook) =>
      dbBook != null && (dbBook.bookType & BookType.notShelf) == 0;

  /// refresh_toc 历史占位行：库内无名无作者，路由带完整元数据
  static bool isRefreshTocPlaceholder(Book dbBook, Book? routeBook) {
    if (routeBook == null) return false;
    return dbBook.name.trim().isEmpty &&
        dbBook.author.trim().isEmpty &&
        routeBook.name.trim().isNotEmpty;
  }

  /// 详情/目录页在架判定（排除 notShelf 与 refresh_toc 误插入占位）
  static bool resolveInBookshelf(Book? dbBook, Book? routeBook) {
    if (dbBook == null) return false;
    if ((dbBook.bookType & BookType.notShelf) != 0) return false;
    if (isRefreshTocPlaceholder(dbBook, routeBook)) return false;
    return true;
  }

  /// 解析 webbookChapters 返回的 WebChapter 数组（snake_case）
  static List<BookChapter> parseWebChapters(String json, String bookUrl) {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map)
          BookChapter(
            index: (e['index'] as num?)?.toInt() ?? 0,
            title: e['title']?.toString() ?? '',
            url: e['url']?.toString() ?? '',
            bookUrl: bookUrl,
            isVolume: e['is_volume'] == true,
            isVip: e['is_vip'] == true,
          ),
    ];
  }
}
