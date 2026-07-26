import 'package:freezed_annotation/freezed_annotation.dart';

part 'rule.freezed.dart';
part 'rule.g.dart';

// ─── BookInfoRule ─────────────────────────────────────────

/// 书籍详情页规则
@freezed
class BookInfoRule with _$BookInfoRule {
  const factory BookInfoRule({
    String? init,
    String? name,
    String? author,
    String? intro,
    String? kind,
    @JsonKey(name: 'lastChapter') String? lastChapter,
    @JsonKey(name: 'updateTime') String? updateTime,
    @JsonKey(name: 'coverUrl') String? coverUrl,
    @JsonKey(name: 'tocUrl') String? tocUrl,
    @JsonKey(name: 'wordCount') String? wordCount,
    @JsonKey(name: 'canReName') String? canReName,
    @JsonKey(name: 'downloadUrls') String? downloadUrls,
  }) = _BookInfoRule;

  factory BookInfoRule.fromJson(Map<String, dynamic> json) =>
      _$BookInfoRuleFromJson(json);
}

// ─── SearchRule ───────────────────────────────────────────

/// 搜索结果处理规则
@freezed
class SearchRule with _$SearchRule {
  const factory SearchRule({
    @JsonKey(name: 'checkKeyWord') String? checkKeyWord,
    @JsonKey(name: 'bookList') String? bookList,
    String? name,
    String? author,
    String? intro,
    String? kind,
    @JsonKey(name: 'lastChapter') String? lastChapter,
    @JsonKey(name: 'updateTime') String? updateTime,
    @JsonKey(name: 'bookUrl') String? bookUrl,
    @JsonKey(name: 'coverUrl') String? coverUrl,
    @JsonKey(name: 'wordCount') String? wordCount,
  }) = _SearchRule;

  factory SearchRule.fromJson(Map<String, dynamic> json) =>
      _$SearchRuleFromJson(json);
}

// ─── TocRule ──────────────────────────────────────────────

/// 目录页规则
@freezed
class TocRule with _$TocRule {
  const factory TocRule({
    @JsonKey(name: 'preUpdateJs') String? preUpdateJs,
    @JsonKey(name: 'chapterList') String? chapterList,
    @JsonKey(name: 'chapterName') String? chapterName,
    @JsonKey(name: 'chapterUrl') String? chapterUrl,
    @JsonKey(name: 'formatJs') String? formatJs,
    @JsonKey(name: 'isVolume') String? isVolume,
    @JsonKey(name: 'isVip') String? isVip,
    @JsonKey(name: 'isPay') String? isPay,
    @JsonKey(name: 'updateTime') String? updateTime,
    @JsonKey(name: 'nextTocUrl') String? nextTocUrl,
  }) = _TocRule;

  factory TocRule.fromJson(Map<String, dynamic> json) =>
      _$TocRuleFromJson(json);
}

// ─── ContentRule ──────────────────────────────────────────

/// 正文处理规则
@freezed
class ContentRule with _$ContentRule {
  const factory ContentRule({
    String? content,
    @JsonKey(name: 'subContent') String? subContent,
    String? title,
    @JsonKey(name: 'nextContentUrl') String? nextContentUrl,
    @JsonKey(name: 'webJs') String? webJs,
    @JsonKey(name: 'sourceRegex') String? sourceRegex,
    @JsonKey(name: 'replaceRegex') String? replaceRegex,
    @JsonKey(name: 'imageStyle') String? imageStyle,
    @JsonKey(name: 'imageDecode') String? imageDecode,
    @JsonKey(name: 'payAction') String? payAction,
    @JsonKey(name: 'callBackJs') String? callBackJs,
  }) = _ContentRule;

  factory ContentRule.fromJson(Map<String, dynamic> json) =>
      _$ContentRuleFromJson(json);
}

// ─── ExploreRule ──────────────────────────────────────────

/// 发现结果规则
@freezed
class ExploreRule with _$ExploreRule {
  const factory ExploreRule({
    @JsonKey(name: 'bookList') String? bookList,
    String? name,
    String? author,
    String? intro,
    String? kind,
    @JsonKey(name: 'lastChapter') String? lastChapter,
    @JsonKey(name: 'updateTime') String? updateTime,
    @JsonKey(name: 'bookUrl') String? bookUrl,
    @JsonKey(name: 'coverUrl') String? coverUrl,
    @JsonKey(name: 'wordCount') String? wordCount,
  }) = _ExploreRule;

  factory ExploreRule.fromJson(Map<String, dynamic> json) =>
      _$ExploreRuleFromJson(json);
}

// ─── ReviewRule ───────────────────────────────────────────

/// 段评规则
@freezed
class ReviewRule with _$ReviewRule {
  const factory ReviewRule({
    @JsonKey(name: 'reviewUrl') String? reviewUrl,
    @JsonKey(name: 'avatarRule') String? avatarRule,
    @JsonKey(name: 'contentRule') String? contentRule,
    @JsonKey(name: 'postTimeRule') String? postTimeRule,
    @JsonKey(name: 'reviewQuoteUrl') String? reviewQuoteUrl,
    @JsonKey(name: 'voteUpUrl') String? voteUpUrl,
    @JsonKey(name: 'voteDownUrl') String? voteDownUrl,
    @JsonKey(name: 'postReviewUrl') String? postReviewUrl,
    @JsonKey(name: 'postQuoteUrl') String? postQuoteUrl,
    @JsonKey(name: 'deleteUrl') String? deleteUrl,
    @Default(false) bool enabled,
    @JsonKey(name: 'reviewSummaryUrl') String? reviewSummaryUrl,
    @JsonKey(name: 'summaryListRule') String? summaryListRule,
    @JsonKey(name: 'summaryParagraphIndexRule') String? summaryParagraphIndexRule,
    @JsonKey(name: 'summaryParagraphDataRule') String? summaryParagraphDataRule,
    @JsonKey(name: 'summaryCountRule') String? summaryCountRule,
    @JsonKey(name: 'reviewDetailUrl') String? reviewDetailUrl,
    @JsonKey(name: 'reviewDetailNextPageUrl') String? reviewDetailNextPageUrl,
    @JsonKey(name: 'detailListRule') String? detailListRule,
    @JsonKey(name: 'detailIdRule') String? detailIdRule,
    @JsonKey(name: 'detailAvatarRule') String? detailAvatarRule,
    @JsonKey(name: 'detailNameRule') String? detailNameRule,
    @JsonKey(name: 'detailBadgeRule') String? detailBadgeRule,
    @JsonKey(name: 'detailContentRule') String? detailContentRule,
    @JsonKey(name: 'replyListRule') String? replyListRule,
    @JsonKey(name: 'replyIdRule') String? replyIdRule,
    @JsonKey(name: 'replyAvatarRule') String? replyAvatarRule,
    @JsonKey(name: 'replyNameRule') String? replyNameRule,
    @JsonKey(name: 'replyBadgeRule') String? replyBadgeRule,
    @JsonKey(name: 'replyContentRule') String? replyContentRule,
  }) = _ReviewRule;

  factory ReviewRule.fromJson(Map<String, dynamic> json) =>
      _$ReviewRuleFromJson(json);
}

// ─── FlexChildStyle ───────────────────────────────────────

/// Flexbox 子元素样式
@freezed
class FlexChildStyle with _$FlexChildStyle {
  const factory FlexChildStyle({
    @Default(0) @JsonKey(name: 'layout_flexGrow') double layoutFlexGrow,
    @Default(1.0) @JsonKey(name: 'layout_flexShrink') double layoutFlexShrink,
    @Default('auto') @JsonKey(name: 'layout_alignSelf') String layoutAlignSelf,
    @Default(-1.0) @JsonKey(name: 'layout_flexBasisPercent') double layoutFlexBasisPercent,
    @Default(false) @JsonKey(name: 'layout_wrapBefore') bool layoutWrapBefore,
    @Default('auto') @JsonKey(name: 'layout_justifySelf') String layoutJustifySelf,
  }) = _FlexChildStyle;

  factory FlexChildStyle.fromJson(Map<String, dynamic> json) =>
      _$FlexChildStyleFromJson(json);
}

// ─── ExploreKind ──────────────────────────────────────────

/// 发现分类
@freezed
class ExploreKind with _$ExploreKind {
  const factory ExploreKind({
    @Default('') String title,
    String? url,
    @Default('url') String type,
    String? action,
    List<String?>? chars,
    @JsonKey(name: 'default') String? defaultValue,
    @JsonKey(name: 'viewName') String? viewName,
    FlexChildStyle? style,
  }) = _ExploreKind;

  factory ExploreKind.fromJson(Map<String, dynamic> json) =>
      _$ExploreKindFromJson(json);
}

// ─── RowUi ────────────────────────────────────────────────

/// 登录表单行UI
@freezed
class RowUi with _$RowUi {
  const factory RowUi({
    @Default('') String name,
    @Default('text') String type,
    String? action,
    List<String?>? chars,
    @JsonKey(name: 'default') String? defaultValue,
    @JsonKey(name: 'viewName') String? viewName,
    FlexChildStyle? style,
  }) = _RowUi;

  factory RowUi.fromJson(Map<String, dynamic> json) => _$RowUiFromJson(json);
}
