import 'package:freezed_annotation/freezed_annotation.dart';

part 'rss_source.freezed.dart';
part 'rss_source.g.dart';

/// RSS源实体
@freezed
class RssSource with _$RssSource {
  const factory RssSource({
    @Default('') @JsonKey(name: 'sourceUrl') String sourceUrl,
    @Default('') @JsonKey(name: 'sourceName') String sourceName,
    @Default('') @JsonKey(name: 'sourceIcon') String sourceIcon,
    @JsonKey(name: 'sourceGroup') String? sourceGroup,
    @JsonKey(name: 'sourceComment') String? sourceComment,
    @Default(true) bool enabled,
    @JsonKey(name: 'variableComment') String? variableComment,
    @JsonKey(name: 'jsLib') String? jsLib,
    @JsonKey(name: 'enabledCookieJar') bool? enabledCookieJar,
    @JsonKey(name: 'concurrentRate') String? concurrentRate,
    String? header,
    @JsonKey(name: 'loginUrl') String? loginUrl,
    @JsonKey(name: 'loginUi') String? loginUi,
    @JsonKey(name: 'loginCheckJs') String? loginCheckJs,
    @JsonKey(name: 'coverDecodeJs') String? coverDecodeJs,
    @JsonKey(name: 'sortUrl') String? sortUrl,
    @Default(false) @JsonKey(name: 'singleUrl') bool singleUrl,
    @Default(0) @JsonKey(name: 'articleStyle') int articleStyle,
    @JsonKey(name: 'ruleArticles') String? ruleArticles,
    @JsonKey(name: 'ruleNextPage') String? ruleNextPage,
    @JsonKey(name: 'ruleTitle') String? ruleTitle,
    @JsonKey(name: 'rulePubDate') String? rulePubDate,
    @JsonKey(name: 'ruleDescription') String? ruleDescription,
    @JsonKey(name: 'ruleImage') String? ruleImage,
    @JsonKey(name: 'ruleLink') String? ruleLink,
    @JsonKey(name: 'ruleContent') String? ruleContent,
    @JsonKey(name: 'contentWhitelist') String? contentWhitelist,
    @JsonKey(name: 'contentBlacklist') String? contentBlacklist,
    @JsonKey(name: 'shouldOverrideUrlLoading') String? shouldOverrideUrlLoading,
    String? style,
    @Default(true) @JsonKey(name: 'enableJs') bool enableJs,
    @Default(true) @JsonKey(name: 'loadWithBaseUrl') bool loadWithBaseUrl,
    @JsonKey(name: 'injectJs') String? injectJs,
    @JsonKey(name: 'preloadJs') String? preloadJs,
    @JsonKey(name: 'startHtml') String? startHtml,
    @JsonKey(name: 'startStyle') String? startStyle,
    @JsonKey(name: 'startJs') String? startJs,
    @Default(false) @JsonKey(name: 'showWebLog') bool showWebLog,
    @Default(0) @JsonKey(name: 'lastUpdateTime') int lastUpdateTime,
    @Default(0) @JsonKey(name: 'customOrder') int customOrder,
    @Default(0) @JsonKey(name: 'type') int rssType,
    @Default(false) bool preload,
    @Default(false) @JsonKey(name: 'cacheFirst') bool cacheFirst,
    @JsonKey(name: 'searchUrl') String? searchUrl,
  }) = _RssSource;

  factory RssSource.fromJson(Map<String, dynamic> json) =>
      _$RssSourceFromJson(json);
}
