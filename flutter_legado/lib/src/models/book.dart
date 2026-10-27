import 'package:freezed_annotation/freezed_annotation.dart';

part 'book.freezed.dart';
part 'book.g.dart';

/// 书籍类型常量（位标记，对齐 Kotlin `BookType.kt`：
/// video=4 / text=8 / updateError=16 / audio=32 / image=64 / webFile=128 /
/// notShelf=1024；判断用位运算 `&`，勿用 `==` 单值比较）
///
/// **local 位双标准（必读）**：原版 Kotlin `BookType.local = 256`（0x100，
/// BookType.kt:44），本地书 `type = text|local = 264`、压缩包内书籍
/// `type = text|local|archive = 776`（LocalBook.kt:295 / importArchiveFile）；
/// 本仓库 Rust 域使用 `local = 0x1000`（legado-core `book_type::LOCAL`）。
/// 原版 zip 备份恢复不做类型归一（backup_api.rs 直接 serde 落库），
/// 故 [isLocalBook] 必须同时识别两套位（批22b P1-1）。
/// [UI-fix v2.0.11 | 2026-08-10] 由 0/1/2 枚举语义修正为位标记 — Reasonix
class BookType {
  static const int video = 4;
  static const int text = 8;
  /// 更新失败（对齐 Kotlin `BookType.updateError`；书架「更新失败」分组与错误态标记）
  static const int updateError = 16;
  static const int audio = 32;
  static const int image = 64;
  static const int webFile = 128;
  /// 本地书位（本仓库 Rust 域：`legado-core` `book_type::LOCAL = 0x1000`）
  static const int local = 0x1000;

  /// 原版 Kotlin `BookType.local = 0b100000000`（=256，即 0x100；
  /// BookType.kt:44）。原版本地书 `type = text|local = 264`，压缩包内
  /// 书籍再叠加 `archive(512)` = 776（LocalBook.kt:295、importArchiveFile）。
  /// 本仓库 Rust 域写入 [local]（0x1000），两套位域并存；
  /// [isLocalBook] 读取时双位兼容（批22b P1-1）。
  static const int kotlinLocal = 0x100;
  /// 未入书架的临时书（对齐 Kotlin `BookType.notShelf`；搜索/发现打开在线书阅读时临时落库）
  static const int notShelf = 0x400;
  static const String localTag = 'loc_book';

  /// 原版 WebDAV 书籍 origin 前缀（对齐 Kotlin
  /// `BookType.webDavTag = "webDav::"`，BookType.kt:76）。
  ///
  /// 新写入一律使用该前缀；原版/参考版导入的远程书也是该格式，
  /// 形如 `webDav::https://host/dav/books/x.epub,{"serverID":12}`
  /// （自定义服务器带 serverID 属性，默认 WebDAV 服务器不带）。
  static const String webDavTag = 'webDav::';

  /// 历史遗留 WebDAV origin 前缀（批18b 前本仓库写入的存量数据）。
  ///
  /// 仅保留**读取兼容**：新写入不再使用，也不做存量迁移（避免大范围
  /// 写库）；[isWebDavOrigin] / [webDavPathOf] 双前缀均识别。
  static const String legacyWebDavTag = 'dav:';

  /// origin 是否为 WebDAV 书（新 `webDav::` 或旧 `dav:` 双前缀）
  static bool isWebDavOrigin(String origin) =>
      origin.startsWith(webDavTag) || origin.startsWith(legacyWebDavTag);

  /// origin 是否为本地书（`loc_book` 或 WebDAV 书）
  ///
  /// 对应 Kotlin `Book.isLocal` 的 origin 判定分支
  /// （BookExtensions.kt:50-56）：`origin == localTag ||
  /// origin.startsWith(webDavTag)`，此处额外兼容存量 `dav:`。
  static bool isLocalOrigin(String origin) =>
      origin == localTag || isWebDavOrigin(origin);

  /// 书籍是否本地书（类型感知，对齐 Kotlin `Book.isLocal`）
  ///
  /// Kotlin `BookExtensions.kt:50-56` 的完整语义：
  /// - `type == 0`（历史数据未写类型）→ 按 [origin] 判定
  ///   （[isLocalOrigin]：`loc_book` / `webDav::` / 存量 `dav:`）；
  /// - `type != 0` → 只看 local 位（[local] 与 [kotlinLocal] 双标准兼容：
  ///   本仓库 Rust 域写 0x1000，原版备份/参考版数据为 0x100）。
  ///
  /// 不能仅用 origin 判定：原版备份导入的 `loc_book::xxx.zip` 等在线书
  /// 可能带非 0 type 而没有 local 位，origin-only 会把它误当本地书
  /// （批22 P3-2）。本批 4 处书架入口（书架分组 / 更新全部目录 /
  /// 批量换源预估与执行）统一经此函数；其余 origin-only 判定点不在
  /// 本批范围。
  static bool isLocalBook(Book book) => book.bookType == 0
      ? isLocalOrigin(book.origin)
      : (book.bookType & (local | kotlinLocal)) != 0;

  /// 「更新全部目录」候选：允许更新且非本地书
  ///
  /// 对齐 Kotlin `updateAllBooks` 的 `it.canUpdate && !it.isLocal` 过滤；
  /// 独立成函数以便单测覆盖双位域（批22b P3-5）。
  static bool canUpdateToc(Book book) => book.canUpdate && !isLocalBook(book);

  /// 提取 WebDAV origin 中的远程路径（去掉前缀与属性后缀）
  ///
  /// - 新格式 `webDav::https://host/books/x.epub,{"serverID":12}`
  ///   → `https://host/books/x.epub`；
  /// - 旧格式 `dav:https://host/books/x.epub` → 原样 URL；
  /// - 旧自定义服务器 `dav:books/x.epub` → 相对路径。
  ///
  /// 非 WebDAV origin 返回 null。属性分隔符对齐 Kotlin
  /// `AnalyzeUrl.paramPattern = "\\s*,\\s*(?=\\{)"`（CustomUrl 序列化）。
  static String? webDavPathOf(String origin) {
    final String rest;
    if (origin.startsWith(webDavTag)) {
      rest = origin.substring(webDavTag.length);
    } else if (origin.startsWith(legacyWebDavTag)) {
      rest = origin.substring(legacyWebDavTag.length);
    } else {
      return null;
    }
    final sep = RegExp(r'\s*,\s*(?=\{)').firstMatch(rest);
    return sep == null ? rest : rest.substring(0, sep.start);
  }

  /// 构造原版格式的 WebDAV origin：`webDav::<完整远程 URL>[,{"serverID":<id>}]`
  ///
  /// [serverId] 为 null 时不追加属性：对齐原版默认 WebDAV 服务器
  /// `RemoteBookWebDav(rootBookUrl, authorization)` 的 `serverID = null`，
  /// 此时 `CustomUrl.putAttribute("serverID", null)` 会移除该键，
  /// 序列化结果只剩 URL（RemoteBookWebDav.kt:101-104）。
  static String buildWebDavOrigin(String remoteUrl, {int? serverId}) {
    if (serverId == null) return '$webDavTag$remoteUrl';
    return '$webDavTag$remoteUrl,{"serverID":$serverId}';
  }

  /// 拼接远程 URL 片段（保证片段之间恰好一个 `/`）
  ///
  /// 原版 `NetworkUtils.getAbsoluteURL` 归一后不会出现 `//`；本仓库
  /// WebDAV 配置的 url 可能带/不带尾斜杠、remote_dir 可能带前斜杠，
  /// 直接字符串相加会产生双斜杠，故统一经此函数拼接。
  static String joinRemoteUrl(String base, String relative) {
    final b = _trimTrailingSlashes(collapseSlashes(base.trim()));
    final r = collapseSlashes(relative.trim()).replaceAll(RegExp(r'^/+'), '');
    if (r.isEmpty) return b;
    if (b.isEmpty) return r;
    return '$b/$r';
  }

  /// 折叠字符串中连续的 `/`（只归一 path，保留 query/fragment/userinfo）
  ///
  /// WebDAV 配置的 url / remote_dir 来自用户输入与旧偏好，可能出现
  /// `https://host//dav//` 或 `//legado//` 等重复斜杠；Rust `WebDavClient`
  /// 以 `url + remote_dir + path` 直拼，Dart 侧必须在写入配置前归一
  /// （批22 P3）。
  ///
  /// 旧实现按整串折叠，会破坏 `?x=http://y` 的 query、含 `//` 的
  /// userinfo、协议相对 `//host/...`，并把空 host 的 `https://` 折成
  /// `https:`（批22b P2-3）。现改为 `Uri` 解析后**只替换 path**：
  /// - query / fragment / userinfo / 端口原样保留；
  /// - 协议相对 `//host` 由 Uri 的 authority 分支原样保留前导双斜杠；
  /// - 无法解析、userinfo 含歧义 `/`（Dart 会把 `us//er@host` 误解析为
  ///   host=us）、或绝对 URL 空 host 时保留原值，交由上层校验；
  /// - 非 URL 的纯相对路径仍按正则折叠，避免 Uri 对空格/中文做
  ///   百分号编码而改变用户输入。
  static String collapseSlashes(String value) {
    final isAbsolute = value.contains('://');
    final isProtocolRelative = value.startsWith('//');
    if (!isAbsolute && !isProtocolRelative) {
      return value.replaceAll(RegExp(r'/{2,}'), '/');
    }

    // authority 内 userinfo 含 `/` 时 Dart Uri 会截断 host 并误解析
    // （实测 `https://us//er@host//a` → host=us、path=//er@host//a），
    // 此类歧义串整体保留原值，不做 path 归一。
    final authorityStart = isAbsolute ? value.indexOf('://') + 3 : 2;
    final beforeQuery = value.split(RegExp(r'[?#]')).first;
    final at = beforeQuery.indexOf('@', authorityStart);
    if (at >= 0 && beforeQuery.substring(authorityStart, at).contains('/')) {
      return value;
    }

    final Uri uri;
    try {
      uri = Uri.parse(value);
    } on FormatException {
      // 无法解析：保留原值
      return value;
    }
    if (uri.hasScheme && uri.host.isEmpty) {
      // `https://` 等空 host：保留原值，不得归一成 `https:`
      return value;
    }
    final path = uri.path.replaceAll(RegExp(r'/{2,}'), '/');
    if (path == uri.path) return value;
    return uri.replace(path: path).toString();
  }

  /// 去掉末尾 `/`，但空 host 的 `scheme://` 原样保留
  ///
  /// 避免 `https://` 在归一化尾部斜杠时被折成 `https:`（批22b P2-3）。
  static String _trimTrailingSlashes(String value) {
    if (value.isEmpty) return value;
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme && uri.host.isEmpty) return value;
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  /// 归一 WebDAV 配置的「根 URL + 远端子目录」（供 Rust
  /// `url + remote_dir + path` 直拼，保证任意组合都不产生 `//`）
  ///
  /// 返回命名记录：
  /// - `url`：折叠重复斜杠并去掉末尾 `/`；
  /// - `remoteDir`：形如 `/legado/`（首尾各一个 `/`；空目录归一为 `/`）。
  ///
  /// 例：`('https://host/dav/', '/legado/')` →
  /// `('https://host/dav', '/legado/')`，直拼后 `https://host/dav/legado/x`。
  static ({String url, String remoteDir}) normalizeWebDavConfig(
    String url,
    String remoteDir,
  ) {
    final base = _trimTrailingSlashes(collapseSlashes(url.trim()));
    final dir = collapseSlashes(remoteDir.trim())
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    return (url: base, remoteDir: dir.isEmpty ? '/' : '/$dir/');
  }
}

/// 阅读配置
@freezed
class ReadConfig with _$ReadConfig {
  const factory ReadConfig({
    @Default(false) @JsonKey(name: 'reverseToc') bool reverseToc,
    @JsonKey(name: 'pageAnim') int? pageAnim,
    @Default(false) @JsonKey(name: 'reSegment') bool reSegment,
    @JsonKey(name: 'imageStyle') String? imageStyle,
    @JsonKey(name: 'useReplaceRule') bool? useReplaceRule,
    @Default(0) @JsonKey(name: 'delTag') int delTag,
    @JsonKey(name: 'ttsEngine') String? ttsEngine,
    @Default(true) @JsonKey(name: 'splitLongChapter') bool splitLongChapter,
    @Default(false) @JsonKey(name: 'readSimulating') bool readSimulating,
    @JsonKey(name: 'startDate') String? startDate,
    @JsonKey(name: 'startChapter') int? startChapter,
    @Default(3) @JsonKey(name: 'dailyChapters') int dailyChapters,
    @Default(0) @JsonKey(name: 'openCredits') int openCredits,
    @Default(0) @JsonKey(name: 'closeCredits') int closeCredits,
    @Default(0) @JsonKey(name: 'playMode') int playMode,
    @Default(1.0) @JsonKey(name: 'playSpeed') double playSpeed,
    /// [漫画设置作用域 2026-10-01] 书级翻页模式覆盖（null = 未覆盖，跟随
    /// 全局 [MangaConfigKeys.scrollMode]）。对齐参考版 `Book.ReadConfig.mangaScrollMode`
    /// 与 MangaReaderViewModel 有效值优先级 `book?.scrollMode ?: settings.scrollMode`。
    @JsonKey(name: 'mangaScrollMode') int? mangaScrollMode,
    /// [漫画设置作用域 2026-10-01] 书级条漫侧边留白覆盖（null = 未覆盖，
    /// 跟随全局 [MangaConfigKeys.sidePadding]）。
    ///
    /// 键名对齐参考版 `Book.ReadConfig.webtoonSidePaddingDp`，但数值沿用
    /// Flutter 既有百分比口径 0..45（每侧留白 = 视口宽 × p/100），与参考版
    /// 字段仅做作用域对齐，**不做 dp/百分比换算**（无明确换算规则前禁止混用单位）。
    @JsonKey(name: 'webtoonSidePaddingDp') int? webtoonSidePaddingDp,
  }) = _ReadConfig;

  factory ReadConfig.fromJson(Map<String, dynamic> json) =>
      _$ReadConfigFromJson(json);
}

/// 书籍实体
@freezed
class Book with _$Book {
  const factory Book({
    @Default('') @JsonKey(name: 'bookUrl') String bookUrl,
    @Default('') @JsonKey(name: 'tocUrl') String tocUrl,
    @Default('loc_book') String origin,
    @Default('') @JsonKey(name: 'originName') String originName,
    @Default('') String name,
    @Default('') String author,
    String? kind,
    @JsonKey(name: 'customTag') String? customTag,
    @JsonKey(name: 'coverUrl') String? coverUrl,
    @JsonKey(name: 'customCoverUrl') String? customCoverUrl,
    String? intro,
    @JsonKey(name: 'customIntro') String? customIntro,
    String? charset,
    @Default(0) @JsonKey(name: 'type') int bookType,
    @Default(0) int group,
    @JsonKey(name: 'latestChapterTitle') String? latestChapterTitle,
    @Default(0) @JsonKey(name: 'latestChapterTime') int latestChapterTime,
    @Default(0) @JsonKey(name: 'lastCheckTime') int lastCheckTime,
    @Default(0) @JsonKey(name: 'lastCheckCount') int lastCheckCount,
    @Default(0) @JsonKey(name: 'totalChapterNum') int totalChapterNum,
    @JsonKey(name: 'durChapterTitle') String? durChapterTitle,
    @Default(0) @JsonKey(name: 'durChapterIndex') int durChapterIndex,
    @Default(0) @JsonKey(name: 'durVolumeIndex') int durVolumeIndex,
    @Default(0) @JsonKey(name: 'chapterInVolumeIndex') int chapterInVolumeIndex,
    @Default(0) @JsonKey(name: 'durChapterPos') int durChapterPos,
    @Default(0) @JsonKey(name: 'durChapterTime') int durChapterTime,
    @JsonKey(name: 'wordCount') String? wordCount,
    @Default(true) @JsonKey(name: 'canUpdate') bool canUpdate,
    @Default(0) int order,
    @Default(0) @JsonKey(name: 'originOrder') int originOrder,
    String? variable,
    @JsonKey(name: 'readConfig') ReadConfig? readConfig,
    @Default(0) @JsonKey(name: 'syncTime') int syncTime,
    /// [P2-8] 当前书源下该书的详情页地址（换源事务写入；bookUrl 保持
    /// 稳定主键不变，换源后可能仍是旧源地址）。为空时「抓取书籍页」
    /// 路径回退 bookUrl（未换源书籍与存量库行为不变，向后兼容）。
    @Default('') @JsonKey(name: 'originBookUrl') String originBookUrl,
    /// [批3 P1-3 UI 余项] 文件类书源（type=3）下载地址列表，JSON 数组
    /// 字符串形态。对齐 Kotlin `Book.downloadUrls: List<String>`，本轨
    /// 落库/往返形态对齐 Rust Book serde（`downloadUrls: Option<String>`，
    /// JSON 数组字符串），由 BookOpenUtils.mergeWebInfo 将 WebBookInfo 的
    /// 数组 jsonEncode 写入；详情页文件下载列表消费。
    @JsonKey(name: 'downloadUrls') String? downloadUrls,
  }) = _Book;

  factory Book.fromJson(Map<String, dynamic> json) => _$BookFromJson(json);
}
