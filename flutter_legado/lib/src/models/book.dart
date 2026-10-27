import 'package:freezed_annotation/freezed_annotation.dart';

part 'book.freezed.dart';
part 'book.g.dart';

/// 书籍类型常量（位标记，对齐 Kotlin `BookType.kt`：
/// video=4 / text=8 / updateError=16 / audio=32 / image=64 / webFile=128 /
/// local=256 / notShelf=1024；Rust searchBooks/getBook 返回的 `type` 即此位标记，
/// 判断用位运算 `&`，勿用 `==` 单值比较）
/// [UI-fix v2.0.11 | 2026-08-10] 由 0/1/2 枚举语义修正为位标记 — Reasonix
class BookType {
  static const int video = 4;
  static const int text = 8;
  /// 更新失败（对齐 Kotlin `BookType.updateError`；书架「更新失败」分组与错误态标记）
  static const int updateError = 16;
  static const int audio = 32;
  static const int image = 64;
  static const int webFile = 128;
  static const int local = 0x1000;
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
    final b = base.trim().replaceAll(RegExp(r'/+$'), '');
    final r = relative.trim().replaceAll(RegExp(r'^/+'), '');
    if (r.isEmpty) return b;
    if (b.isEmpty) return r;
    return '$b/$r';
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
