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

  /// [P2-15 ② | type 回流 2026-09-18] 详情解析 type（WebBookInfo JSON
  /// `type` 键，BookType 位标记）并入书籍 bookType。
  ///
  /// 覆盖语义（对齐上游 analyzeBookInfo：详情解析是书籍模式的权威来源——
  /// JS `book.type=N` 写路径值 > 书源声明值）：
  /// - [fresh] 非零 → 覆盖现有**媒体位**（[typeMask] 内），非媒体标记位
  ///   （local / notShelf / updateError 等）原样保留；
  /// - [fresh] 为 0（含 Rust 侧零值省略不序列化、缺键）→ 保留现有值，
  ///   不用空覆盖。
  ///
  /// 已知风险（与上游一致的取舍）：用户侧若手动改过书籍模式，下次详情
  /// 进入/刷新时 JS `book.type` 写值会再次覆盖（JS 胜出）；本应用当前
  /// 无手动改模式 UI，风险仅对未来功能面。
  static int mergeBookType(int existing, int fresh) {
    final freshBits = fresh & typeMask;
    if (freshBits == 0) return existing;
    return (existing & ~typeMask) | freshBits;
  }

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

  /// [P2-8 | P3-1 对齐 2026-09-18] 「抓取书籍页」地址选择：优先
  /// `originBookUrl`（当前书源下该书的详情页地址，换源事务与 preUpdateJs
  /// 钩子写入；bookUrl 作为稳定主键换源后可能仍是旧源地址），为空时回退
  /// `bookUrl`（未换源书籍与存量库行为不变，向后兼容）。
  ///
  /// 语义与 Rust `Book::book_page_fetch_url()` 完全一致：空值判定按
  /// **trim 后**（纯空白视同空值），返回值取字段原值（不 trim）。
  ///
  /// 详情页联网刷新（webbookInfo / webbookChapters 取址）一律经本方法取址，
  /// 保证换源后刷新用「当前书源详情页」而非「旧源地址」——台账 P2-8 根因
  /// 修复（此前用旧源地址套当前书源规则，字段解析为空/退化值写坏 tocUrl）。
  static String bookFetchUrl(Book book) {
    final origin = book.originBookUrl;
    return origin.trim().isNotEmpty ? origin : book.bookUrl;
  }

  /// [P2-4 | 2026-09-18] DB 记录补全路由带入瘦壳书（author/tocUrl/章节数
  /// 等）：路由非空字段优先保留（最新章标题等实时值），DB 非空字段仅填空。
  /// 本方法为纯函数公共静态（对齐 [mergeWebInfo] 的提取模式，可单测）。
  ///
  /// 唯一例外是 [Book.originBookUrl] —— **DB 优先**：换源事务是该字段的
  /// 唯一权威写者（preUpdateJs 钩子也是经 DB 写入，不写路由对象），路由
  /// 对象可能是未携带该字段或携带旧值的陈旧内存瘦壳；若路由优先会把换源
  /// 事务写入的「当前书源详情页地址」覆盖掉，后续详情刷新取址错误。
  /// 路由值仅作兜底（DB 记录缺该字段且为空时）。
  static Book mergeDbBook(Book routeBook, Book dbBook) {
    return routeBook.copyWith(
      coverUrl: (routeBook.coverUrl?.isNotEmpty ?? false)
          ? routeBook.coverUrl
          : dbBook.coverUrl,
      intro: (routeBook.intro?.isNotEmpty ?? false)
          ? routeBook.intro
          : dbBook.intro,
      tocUrl: routeBook.tocUrl.isNotEmpty ? routeBook.tocUrl : dbBook.tocUrl,
      wordCount: (routeBook.wordCount?.isNotEmpty ?? false)
          ? routeBook.wordCount
          : dbBook.wordCount,
      latestChapterTitle:
          (routeBook.latestChapterTitle?.isNotEmpty ?? false)
              ? routeBook.latestChapterTitle
              : dbBook.latestChapterTitle,
      kind: (routeBook.kind?.isNotEmpty ?? false) ? routeBook.kind : dbBook.kind,
      author: routeBook.author.isNotEmpty ? routeBook.author : dbBook.author,
      totalChapterNum: routeBook.totalChapterNum > 0
          ? routeBook.totalChapterNum
          : dbBook.totalChapterNum,
      // [P2-4] originBookUrl 以 DB 为权威（换源事务唯一权威写者），路由值仅兜底
      originBookUrl: dbBook.originBookUrl.isNotEmpty
          ? dbBook.originBookUrl
          : routeBook.originBookUrl,
    );
  }

  /// 合并 webbookInfo 返回的详情到 book（WebBookInfo 为 snake_case，需手动映射，
  /// 不能直接 Book.fromJson 否则 cover_url/toc_url 等丢失）。
  /// - refresh=false（默认）：仅补全当前缺失字段（首屏补全语义）。
  /// - refresh=true（U7 进入刷新）：更新式合并——刷新非空值覆盖现有字段
  ///   （对齐原版 analyzeBookInfo 覆盖语义，刷新 kind 评分/分类/完结态、字数、
  ///   最新章等陈旧值）；刷新值为空时保留现有值（不用空覆盖）。
  /// - [换源后刷新守卫 | 2026-09-18 | 台账 P2-8] 根因修复后（进入刷新取址已
  ///   走 [bookFetchUrl]，即当前书源详情页），守卫降级为纵深防御：正常书籍页
  ///   解析必得书名（ruleBookInfo.name）；name 缺失即视为「未解析到书籍页」，
  ///   本次刷新整体跳过——宁可保留旧值，也不用错页结果覆盖。
  static Book mergeWebInfo(Book book, String infoJson, {bool refresh = false}) {
    final decoded = jsonDecode(infoJson);
    if (decoded is! Map) return book;
    String? pick(String key) {
      final v = decoded[key];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    if (refresh) {
      final freshName = pick('name');
      if (freshName == null) return book;
      final freshCover = pick('cover_url');
      final freshIntro = pick('intro');
      final freshWord = pick('word_count');
      final freshLast = pick('last_chapter');
      final freshKind = pick('kind');
      final freshToc = pick('toc_url');
      final freshAuthor = pick('author');
      // [P2-15 ②] 详情解析 type 回流：非零覆盖媒体位（JS 写值胜出），
      // 零值/缺键保留现有值（对齐上方 refresh 更新式合并的非空覆盖口径）
      final freshType = (decoded['type'] as num?)?.toInt() ?? 0;
      return book.copyWith(
        coverUrl: freshCover ?? book.coverUrl,
        intro: freshIntro ?? book.intro,
        tocUrl: freshToc ?? book.tocUrl,
        wordCount: freshWord ?? book.wordCount,
        latestChapterTitle: freshLast ?? book.latestChapterTitle,
        kind: freshKind ?? book.kind,
        name: freshName,
        author: freshAuthor ?? book.author,
        bookType: mergeBookType(book.bookType, freshType),
      );
    }

    final hasCover = book.coverUrl != null && book.coverUrl!.isNotEmpty;
    final hasIntro = book.intro != null && book.intro!.isNotEmpty;
    final hasWord = book.wordCount != null && book.wordCount!.isNotEmpty;
    final hasLast =
        book.latestChapterTitle != null && book.latestChapterTitle!.isNotEmpty;
    final hasKind = book.kind != null && book.kind!.isNotEmpty;
    final tocUrl = pick('toc_url');
    final name = pick('name');
    final author = pick('author');
    // [P2-15 ②] type 非「补全缺失」语义：详情解析是书籍模式权威来源
    // （二合一文本源入架时 bookType=8，详情 JS 写 64 → 必须覆盖切漫画
    // 模式），故非零新值同样覆盖媒体位；零值/缺键保留现有值
    final freshType = (decoded['type'] as num?)?.toInt() ?? 0;
    return book.copyWith(
      coverUrl: hasCover ? book.coverUrl : pick('cover_url'),
      intro: hasIntro ? book.intro : pick('intro'),
      // [fix 2026-08-15] tocUrl 用详情解析出的权威值优先（七猫发现列表
      // book.tocUrl 默认=bookUrl，详情 qmBookInfo 生成真实 chapter-list URL）
      tocUrl: tocUrl ?? book.tocUrl,
      wordCount: hasWord ? book.wordCount : pick('word_count'),
      latestChapterTitle: hasLast ? book.latestChapterTitle : pick('last_chapter'),
      kind: hasKind ? book.kind : pick('kind'),
      name: book.name.isNotEmpty ? book.name : (name ?? book.name),
      author: book.author.isNotEmpty ? book.author : (author ?? book.author),
      bookType: mergeBookType(book.bookType, freshType),
    );
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
