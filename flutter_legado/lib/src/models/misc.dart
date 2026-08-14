import 'package:freezed_annotation/freezed_annotation.dart';

import 'rule/rule.dart';

part 'misc.freezed.dart';
part 'misc.g.dart';

// ─── SearchBook ───────────────────────────────────────────

/// 搜索结果书籍
@freezed
class SearchBook with _$SearchBook {
  const factory SearchBook({
    @Default('') @JsonKey(name: 'bookUrl') String bookUrl,
    @Default('') String origin,
    @Default('') @JsonKey(name: 'originName') String originName,
    @Default(0) @JsonKey(name: 'type') int bookType,
    @Default('') String name,
    @Default('') String author,
    String? kind,
    @JsonKey(name: 'coverUrl') String? coverUrl,
    String? intro,
    @JsonKey(name: 'wordCount') String? wordCount,
    @JsonKey(name: 'latestChapterTitle') String? latestChapterTitle,
    @Default('') @JsonKey(name: 'tocUrl') String tocUrl,
    @Default(0) int time,
    String? variable,
    @Default(0) @JsonKey(name: 'originOrder') int originOrder,
    @JsonKey(name: 'chapterWordCountText') String? chapterWordCountText,
    @Default(-1) @JsonKey(name: 'chapterWordCount') int chapterWordCount,
    @Default(-1) @JsonKey(name: 'respondTime') int respondTime,
  }) = _SearchBook;

  factory SearchBook.fromJson(Map<String, dynamic> json) =>
      _$SearchBookFromJson(json);
}

// ─── ExploreCategory ────────────────────────────────────────

/// 发现分类项（对标 Android ExploreKind）
///
/// 由 Rust 侧 parse_explore_url 解析 exploreUrl 后返回
class ExploreCategory {
  /// 分类标题
  final String title;

  /// 分类 URL（可能包含页码占位符；分组标题行可为 null）
  final String? url;

  /// 控件类型：url / text / button / toggle / select
  final String type;

  /// button/toggle/select 的 JS action
  final String? action;

  /// toggle/select 可选值列表
  final List<String>? chars;

  /// toggle/select 默认值
  final String? defaultValue;

  /// 动态标题 JS 或字面量
  final String? viewName;

  /// Flexbox 布局样式（wide/cell 等，对标 FlexChildStyle）
  final FlexChildStyle? style;

  const ExploreCategory({
    required this.title,
    this.url,
    this.type = 'url',
    this.action,
    this.chars,
    this.defaultValue,
    this.viewName,
    this.style,
  });

  factory ExploreCategory.fromJson(Map<String, dynamic> json) {
    final rawChars = json['chars'];
    List<String>? chars;
    if (rawChars is List) {
      chars = rawChars
          .map((e) => e?.toString())
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
    }
    return ExploreCategory(
      title: json['title'] as String? ?? '',
      url: _parseOptionalString(json['url']),
      type: json['type'] as String? ?? 'url',
      action: _parseOptionalString(json['action']),
      chars: chars?.isEmpty ?? true ? null : chars,
      defaultValue: _parseOptionalString(json['default']),
      viewName: _parseOptionalString(json['viewName']),
      style: json['style'] is Map<String, dynamic>
          ? FlexChildStyle.fromJson(json['style'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        if (url != null) 'url': url,
        if (type != 'url') 'type': type,
        if (action != null) 'action': action,
        if (chars != null) 'chars': chars,
        if (defaultValue != null) 'default': defaultValue,
        if (viewName != null) 'viewName': viewName,
        if (style != null) 'style': style!.toJson(),
      };

  static String? _parseOptionalString(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  @override
  String toString() =>
      'ExploreCategory(title: $title, url: $url, type: $type, style: $style)';
}

// ─── ReplaceRule ──────────────────────────────────────────

/// 替换规则
@freezed
class ReplaceRule with _$ReplaceRule {
  const factory ReplaceRule({
    @Default(0) int id,
    @Default('') String name,
    String? group,
    @Default('') String pattern,
    @Default('') String replacement,
    String? scope,
    @Default(false) @JsonKey(name: 'scopeTitle') bool scopeTitle,
    @Default(true) @JsonKey(name: 'scopeContent') bool scopeContent,
    @JsonKey(name: 'excludeScope') String? excludeScope,
    @Default(true) @JsonKey(name: 'isEnabled') bool isEnabled,
    @Default(true) @JsonKey(name: 'isRegex') bool isRegex,
    @Default(3000) @JsonKey(name: 'timeoutMillisecond') int timeoutMillisecond,
    @Default(0) @JsonKey(name: 'sortOrder') int order,
  }) = _ReplaceRule;

  factory ReplaceRule.fromJson(Map<String, dynamic> json) =>
      _$ReplaceRuleFromJson(json);
}

// ─── HttpTTS ──────────────────────────────────────────────

/// 在线朗读引擎
@freezed
class HttpTts with _$HttpTts {
  const factory HttpTts({
    @Default(0) int id,
    @Default('') String name,
    @Default('') String url,
    @JsonKey(name: 'contentType') String? contentType,
    @Default(0) @JsonKey(name: 'pauseDuration') int pauseDuration,
    @JsonKey(name: 'concurrentRate') String? concurrentRate,
    @JsonKey(name: 'loginUrl') String? loginUrl,
    @JsonKey(name: 'loginUi') String? loginUi,
    String? header,
    @JsonKey(name: 'jsLib') String? jsLib,
    @JsonKey(name: 'enabledCookieJar') bool? enabledCookieJar,
    @JsonKey(name: 'loginCheckJs') String? loginCheckJs,
    @Default(0) @JsonKey(name: 'lastUpdateTime') int lastUpdateTime,
  }) = _HttpTts;

  factory HttpTts.fromJson(Map<String, dynamic> json) =>
      _$HttpTtsFromJson(json);
}

// ─── Bookmark ─────────────────────────────────────────────

/// 书签
@freezed
class Bookmark with _$Bookmark {
  const factory Bookmark({
    @Default(0) int id,
    @Default(0) int time,
    @Default('') @JsonKey(name: 'bookName') String bookName,
    @Default('') @JsonKey(name: 'bookAuthor') String bookAuthor,
    @Default(0) @JsonKey(name: 'chapterIndex') int chapterIndex,
    @Default(0) @JsonKey(name: 'chapterPos') int chapterPos,
    @Default('') @JsonKey(name: 'chapterName') String chapterName,
    @Default('') @JsonKey(name: 'bookText') String bookText,
    @Default('') String content,
  }) = _Bookmark;

  factory Bookmark.fromJson(Map<String, dynamic> json) =>
      _$BookmarkFromJson(json);
}

// ─── BookGroup ────────────────────────────────────────────

/// 书籍分组
@freezed
class BookGroup with _$BookGroup {
  const factory BookGroup({
    @Default(1) @JsonKey(name: 'groupId') int groupId,
    @Default('') @JsonKey(name: 'groupName') String groupName,
    String? cover,
    @Default(0) int order,
    @Default(true) @JsonKey(name: 'enableRefresh') bool enableRefresh,
    @Default(true) bool show,
    @Default(-1) @JsonKey(name: 'bookSort') int bookSort,
    @Default(false) @JsonKey(name: 'onlyUpdateRead') bool onlyUpdateRead,
  }) = _BookGroup;

  factory BookGroup.fromJson(Map<String, dynamic> json) =>
      _$BookGroupFromJson(json);
}

// ─── AutoTaskRule ─────────────────────────────────────────

/// 自动任务规则
@freezed
class AutoTaskRule with _$AutoTaskRule {
  const factory AutoTaskRule({
    @Default('') String id,
    @Default('') String name,
    @Default(true) bool enable,
    String? cron,
    @JsonKey(name: 'loginUrl') String? loginUrl,
    @JsonKey(name: 'loginUi') String? loginUi,
    @JsonKey(name: 'loginCheckJs') String? loginCheckJs,
    String? comment,
    @Default('') String script,
    String? header,
    @JsonKey(name: 'jsLib') String? jsLib,
    @JsonKey(name: 'concurrentRate') String? concurrentRate,
    @Default(true) @JsonKey(name: 'enabledCookieJar') bool enabledCookieJar,
    @Default(0) @JsonKey(name: 'customOrder') int customOrder,
    @Default(0) @JsonKey(name: 'lastRunAt') int lastRunAt,
    @JsonKey(name: 'lastResult') String? lastResult,
    @JsonKey(name: 'lastError') String? lastError,
    @JsonKey(name: 'lastLog') String? lastLog,
  }) = _AutoTaskRule;

  factory AutoTaskRule.fromJson(Map<String, dynamic> json) =>
      _$AutoTaskRuleFromJson(json);
}

// ─── RssArticle ───────────────────────────────────────────

/// RSS文章
@freezed
class RssArticle with _$RssArticle {
  const factory RssArticle({
    @Default('') String origin,
    @Default('') String sort,
    @Default('') String title,
    @Default(0) int order,
    @Default('') String link,
    @JsonKey(name: 'pubDate') String? pubDate,
    String? description,
    String? content,
    String? image,
    @Default('默认分组') String group,
    @Default(false) bool read,
    String? variable,
    @Default(0) @JsonKey(name: 'type') int articleType,
    @Default(0) @JsonKey(name: 'durPos') int durPos,
  }) = _RssArticle;

  factory RssArticle.fromJson(Map<String, dynamic> json) =>
      _$RssArticleFromJson(json);
}

// ─── RssStar ──────────────────────────────────────────────

/// RSS收藏
@freezed
class RssStar with _$RssStar {
  const factory RssStar({
    @Default('') String origin,
    @Default('') String sort,
    @Default('') String title,
    @Default(0) @JsonKey(name: 'starTime') int starTime,
    @Default('') String link,
    @JsonKey(name: 'pubDate') String? pubDate,
    String? description,
    String? content,
    String? image,
    @Default('默认分组') String group,
    String? variable,
    @Default(0) @JsonKey(name: 'type') int starType,
    @Default(0) @JsonKey(name: 'durPos') int durPos,
  }) = _RssStar;

  factory RssStar.fromJson(Map<String, dynamic> json) =>
      _$RssStarFromJson(json);
}

// ─── Cookie ───────────────────────────────────────────────

/// Cookie存储
@freezed
class Cookie with _$Cookie {
  const factory Cookie({
    @Default('') String url,
    @Default('') String cookie,
  }) = _Cookie;

  factory Cookie.fromJson(Map<String, dynamic> json) =>
      _$CookieFromJson(json);
}

// ─── Cache ────────────────────────────────────────────────

/// 缓存
@freezed
class Cache with _$Cache {
  const factory Cache({
    @Default('') String key,
    String? value,
    @Default(0) int deadline,
  }) = _Cache;

  factory Cache.fromJson(Map<String, dynamic> json) => _$CacheFromJson(json);
}

// ─── DictRule ─────────────────────────────────────────────

/// 字典规则
@freezed
class DictRule with _$DictRule {
  const factory DictRule({
    @Default('') String name,
    @Default('') @JsonKey(name: 'urlRule') String urlRule,
    @Default('') @JsonKey(name: 'showRule') String showRule,
    @Default(true) bool enabled,
    @Default(0) @JsonKey(name: 'sortNumber') int sortNumber,
  }) = _DictRule;

  factory DictRule.fromJson(Map<String, dynamic> json) =>
      _$DictRuleFromJson(json);
}

/// 字典规则 URL 构造扩展
extension DictRuleUrl on DictRule {
  /// 将 [urlRule] 中的 `{{key}}` 占位符替换为查询单词，生成跳转 URL
  String buildUrl(String key) => urlRule.replaceAll('{{key}}', key);
}

// ─── Server ───────────────────────────────────────────────

/// 服务器
@freezed
class Server with _$Server {
  const factory Server({
    @Default(0) int id,
    @Default('') String name,
    @Default('WEBDAV') @JsonKey(name: 'type') String serverType,
    String? config,
    @Default(0) @JsonKey(name: 'sortNumber') int sortNumber,
  }) = _Server;

  factory Server.fromJson(Map<String, dynamic> json) =>
      _$ServerFromJson(json);
}

/// WebDav配置
@freezed
class WebDavConfig with _$WebDavConfig {
  const factory WebDavConfig({
    @Default('') String url,
    @Default('') String username,
    @Default('') String password,
  }) = _WebDavConfig;

  factory WebDavConfig.fromJson(Map<String, dynamic> json) =>
      _$WebDavConfigFromJson(json);
}

// ─── BookSourcePart ───────────────────────────────────────

/// 书源部分信息（数据库视图）
@freezed
class BookSourcePart with _$BookSourcePart {
  const factory BookSourcePart({
    @Default('') @JsonKey(name: 'bookSourceUrl') String bookSourceUrl,
    @Default('') @JsonKey(name: 'bookSourceName') String bookSourceName,
    @JsonKey(name: 'bookSourceGroup') String? bookSourceGroup,
    @Default(0) @JsonKey(name: 'customOrder') int customOrder,
    @Default(true) bool enabled,
    @Default(true) @JsonKey(name: 'enabledExplore') bool enabledExplore,
    @Default(false) @JsonKey(name: 'hasLoginUrl') bool hasLoginUrl,
    @Default(0) @JsonKey(name: 'lastUpdateTime') int lastUpdateTime,
    @Default(180000) @JsonKey(name: 'respondTime') int respondTime,
    @Default(0) int weight,
    @Default(false) @JsonKey(name: 'hasExploreUrl') bool hasExploreUrl,
    @Default(false) @JsonKey(name: 'eventListener') bool eventListener,
    @Default(0) @JsonKey(name: 'bookSourceType') int bookSourceType,
    @Default(false) @JsonKey(name: 'hasJs') bool hasJs,
  }) = _BookSourcePart;

  factory BookSourcePart.fromJson(Map<String, dynamic> json) =>
      _$BookSourcePartFromJson(json);
}

// ─── SearchKeyword ────────────────────────────────────────

/// 搜索关键词
@freezed
class SearchKeyword with _$SearchKeyword {
  const factory SearchKeyword({
    @Default('') String word,
    @Default(1) int usage,
    @Default(0) @JsonKey(name: 'lastUseTime') int lastUseTime,
  }) = _SearchKeyword;

  factory SearchKeyword.fromJson(Map<String, dynamic> json) =>
      _$SearchKeywordFromJson(json);
}

// ─── RuleSub ──────────────────────────────────────────────

// RuleSub 已迁移至 rule_sub.dart（手写模型，对齐契约 §2.39
// RuleSubRecord JSON：sub_type 字符串 / is_enabled / last_update 等）

// ─── TxtTocRule ───────────────────────────────────────────

/// TXT目录规则
@freezed
class TxtTocRule with _$TxtTocRule {
  const factory TxtTocRule({
    @Default(0) int id,
    @Default('') String name,
    @Default('') String rule,
    @Default('') String replacement,
    String? example,
    @Default(-1) @JsonKey(name: 'serialNumber') int serialNumber,
    @Default(true) bool enable,
  }) = _TxtTocRule;

  factory TxtTocRule.fromJson(Map<String, dynamic> json) =>
      _$TxtTocRuleFromJson(json);
}

// ─── BookChapterReview ────────────────────────────────────

/// 章节段评关联
@freezed
class BookChapterReview with _$BookChapterReview {
  const factory BookChapterReview({
    @Default(0) @JsonKey(name: 'bookId') int bookId,
    @Default(0) @JsonKey(name: 'chapterId') int chapterId,
    @Default('') @JsonKey(name: 'summaryUrl') String summaryUrl,
  }) = _BookChapterReview;

  factory BookChapterReview.fromJson(Map<String, dynamic> json) =>
      _$BookChapterReviewFromJson(json);
}

// ─── KeyboardAssist ───────────────────────────────────────

/// 键盘辅助
@freezed
class KeyboardAssist with _$KeyboardAssist {
  const factory KeyboardAssist({
    @Default(0) @JsonKey(name: 'type') int assistType,
    @Default('') String key,
    @Default('') String value,
    @Default(0) @JsonKey(name: 'serialNo') int serialNo,
  }) = _KeyboardAssist;

  factory KeyboardAssist.fromJson(Map<String, dynamic> json) =>
      _$KeyboardAssistFromJson(json);
}

// ─── ReadRecord ───────────────────────────────────────────

/// 阅读记录
@freezed
class ReadRecord with _$ReadRecord {
  const factory ReadRecord({
    @Default('') @JsonKey(name: 'deviceId') String deviceId,
    @Default('') @JsonKey(name: 'bookName') String bookName,
    @Default(0) @JsonKey(name: 'readTime') int readTime,
    @Default(0) @JsonKey(name: 'lastRead') int lastRead,
  }) = _ReadRecord;

  factory ReadRecord.fromJson(Map<String, dynamic> json) =>
      _$ReadRecordFromJson(json);
}

// ─── RssReadRecord ────────────────────────────────────────

/// RSS阅读记录
@freezed
class RssReadRecord with _$RssReadRecord {
  const factory RssReadRecord({
    @Default('') String record,
    String? title,
    @JsonKey(name: 'readTime') int? readTime,
    @Default(true) bool read,
    @Default('') String origin,
    @Default('') String sort,
    String? image,
    @Default(0) @JsonKey(name: 'type') int recordType,
    @Default(0) @JsonKey(name: 'durPos') int durPos,
    @JsonKey(name: 'pubDate') String? pubDate,
  }) = _RssReadRecord;

  factory RssReadRecord.fromJson(Map<String, dynamic> json) =>
      _$RssReadRecordFromJson(json);
}

// ─── BookProgress ─────────────────────────────────────────

/// 书籍阅读进度
@freezed
class BookProgress with _$BookProgress {
  const factory BookProgress({
    @Default('') String name,
    @Default('') String author,
    @Default(0) @JsonKey(name: 'durChapterIndex') int durChapterIndex,
    @Default(0) @JsonKey(name: 'durChapterPos') int durChapterPos,
    @Default(0) @JsonKey(name: 'durChapterTime') int durChapterTime,
    @JsonKey(name: 'durChapterTitle') String? durChapterTitle,
  }) = _BookProgress;

  factory BookProgress.fromJson(Map<String, dynamic> json) =>
      _$BookProgressFromJson(json);
}

// ─── ReplaceBook ──────────────────────────────────────────

/// 替换规则作用范围书籍
@freezed
class ReplaceBook with _$ReplaceBook {
  const factory ReplaceBook({
    @Default('') @JsonKey(name: 'bookUrl') String bookUrl,
    @Default('') String origin,
    @Default('') @JsonKey(name: 'originName') String originName,
    @Default(0) @JsonKey(name: 'type') int bookType,
    @Default('') String name,
    @Default('') String author,
    String? kind,
    @JsonKey(name: 'coverUrl') String? coverUrl,
    String? intro,
    @JsonKey(name: 'wordCount') String? wordCount,
    @JsonKey(name: 'latestChapterTitle') String? latestChapterTitle,
    @Default('') @JsonKey(name: 'tocUrl') String tocUrl,
    @Default(0) @JsonKey(name: 'originOrder') int originOrder,
  }) = _ReplaceBook;

  factory ReplaceBook.fromJson(Map<String, dynamic> json) =>
      _$ReplaceBookFromJson(json);
}

// ─── BookCacheInfo ────────────────────────────────────────

/// 书籍缓存信息
@freezed
class BookCacheInfo with _$BookCacheInfo {
  const factory BookCacheInfo({
    @Default('') @JsonKey(name: 'bookUrl') String bookUrl,
    @Default('') String name,
    @Default('') String origin,
    @Default('') @JsonKey(name: 'originName') String originName,
    @Default(0) @JsonKey(name: 'type') int bookType,
  }) = _BookCacheInfo;

  factory BookCacheInfo.fromJson(Map<String, dynamic> json) =>
      _$BookCacheInfoFromJson(json);
}

// ─── ReadRecordShow ───────────────────────────────────────

/// 阅读记录展示
@freezed
class ReadRecordShow with _$ReadRecordShow {
  const factory ReadRecordShow({
    @Default('') @JsonKey(name: 'bookName') String bookName,
    @Default(0) @JsonKey(name: 'readTime') int readTime,
    @Default(0) @JsonKey(name: 'lastRead') int lastRead,
  }) = _ReadRecordShow;

  factory ReadRecordShow.fromJson(Map<String, dynamic> json) =>
      _$ReadRecordShowFromJson(json);
}

// ─── DictEntry ────────────────────────────────────────────

/// 词典条目（本地内置词典释义）
@freezed
class DictEntry with _$DictEntry {
  const factory DictEntry({
    @Default('') String word,
    @Default('') String phonetic,
    @Default([]) List<String> definitions,
  }) = _DictEntry;

  factory DictEntry.fromJson(Map<String, dynamic> json) =>
      _$DictEntryFromJson(json);
}

// ─── LoginKeyValue ────────────────────────────────────────

/// 书源登录键值对（Cookie / Header）
@freezed
class LoginKeyValue with _$LoginKeyValue {
  const factory LoginKeyValue({
    @Default('') String name,
    @Default('') String value,
  }) = _LoginKeyValue;

  factory LoginKeyValue.fromJson(Map<String, dynamic> json) =>
      _$LoginKeyValueFromJson(json);
}
