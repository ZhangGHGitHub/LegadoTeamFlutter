import 'package:freezed_annotation/freezed_annotation.dart';

import 'rule/rule.dart';

part 'book_source.freezed.dart';
part 'book_source.g.dart';

/// 书源类型常量
class BookSourceType {
  static const int text = 0;
  static const int audio = 1;
  static const int image = 2;
  static const int file = 3;
  static const int video = 4;
}

/// 书源实体
@freezed
class BookSource with _$BookSource {
  const factory BookSource({
    @Default('') @JsonKey(name: 'bookSourceUrl') String bookSourceUrl,
    @Default('') @JsonKey(name: 'bookSourceName') String bookSourceName,
    @JsonKey(name: 'bookSourceGroup') String? bookSourceGroup,
    @Default(0) @JsonKey(name: 'bookSourceType') int bookSourceType,
    @JsonKey(name: 'bookUrlPattern') String? bookUrlPattern,
    @Default(0) @JsonKey(name: 'customOrder') int customOrder,
    @Default(true) bool enabled,
    @Default(true) @JsonKey(name: 'enabledExplore') bool enabledExplore,
    @JsonKey(name: 'jsLib') String? jsLib,
    @JsonKey(name: 'enabledCookieJar') bool? enabledCookieJar,
    @JsonKey(name: 'concurrentRate') String? concurrentRate,
    String? header,
    @JsonKey(name: 'loginUrl') String? loginUrl,
    @JsonKey(name: 'loginUi') String? loginUi,
    @JsonKey(name: 'loginCheckJs') String? loginCheckJs,
    @JsonKey(name: 'coverDecodeJs') String? coverDecodeJs,
    @JsonKey(name: 'bookSourceComment') String? bookSourceComment,
    @JsonKey(name: 'variableComment') String? variableComment,
    // 书源自定义变量（契约 §2.3，台账 §5.11-3，Task #63 冻结 / #64-65 实现）：
    // 对齐原版 BookSource.variable 字段（Rust 书源查询接口自然带出）。
    // 评审 C1：改 @Default('') 非空——String? 的 toJson 恒输出 "variable": null，
    // 会击穿 Rust serde 解析；非空串 + Rust lenient_string 双侧双保险 — Qoder
    @Default('') String variable,
    @Default(0) @JsonKey(name: 'lastUpdateTime') int lastUpdateTime,
    @Default(180000) @JsonKey(name: 'respondTime') int respondTime,
    @Default(0) int weight,
    @JsonKey(name: 'exploreUrl') String? exploreUrl,
    @JsonKey(name: 'exploreScreen') String? exploreScreen,
    @JsonKey(name: 'ruleExplore') ExploreRule? ruleExplore,
    @JsonKey(name: 'searchUrl') String? searchUrl,
    @JsonKey(name: 'ruleSearch') SearchRule? ruleSearch,
    @JsonKey(name: 'ruleBookInfo') BookInfoRule? ruleBookInfo,
    @JsonKey(name: 'ruleToc') TocRule? ruleToc,
    @JsonKey(name: 'ruleContent') ContentRule? ruleContent,
    @JsonKey(name: 'ruleReview') ReviewRule? ruleReview,
    @JsonKey(name: 'mainJs') String? mainJs,
    @Default(false) @JsonKey(name: 'eventListener') bool eventListener,
    @Default(false) @JsonKey(name: 'customButton') bool customButton,
  }) = _BookSource;

  factory BookSource.fromJson(Map<String, dynamic> json) =>
      _$BookSourceFromJson(json);
}

// Extension for groupName alias (matches Android's BookSource.groupName)
extension BookSourceExtension on BookSource {
  /// 书源分组别名（映射到 bookSourceGroup）
  String? get groupName => bookSourceGroup;
}
