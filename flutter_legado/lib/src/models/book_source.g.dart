// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'book_source.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$BookSourceImpl _$$BookSourceImplFromJson(Map<String, dynamic> json) =>
    _$BookSourceImpl(
      bookSourceUrl: json['bookSourceUrl'] as String? ?? '',
      bookSourceName: json['bookSourceName'] as String? ?? '',
      bookSourceGroup: json['bookSourceGroup'] as String?,
      bookSourceType: (json['bookSourceType'] as num?)?.toInt() ?? 0,
      bookUrlPattern: json['bookUrlPattern'] as String?,
      customOrder: (json['customOrder'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      enabledExplore: json['enabledExplore'] as bool? ?? true,
      jsLib: json['jsLib'] as String?,
      enabledCookieJar: json['enabledCookieJar'] as bool?,
      concurrentRate: json['concurrentRate'] as String?,
      header: json['header'] as String?,
      loginUrl: json['loginUrl'] as String?,
      loginUi: json['loginUi'] as String?,
      loginCheckJs: json['loginCheckJs'] as String?,
      coverDecodeJs: json['coverDecodeJs'] as String?,
      bookSourceComment: json['bookSourceComment'] as String?,
      variableComment: json['variableComment'] as String?,
      lastUpdateTime: (json['lastUpdateTime'] as num?)?.toInt() ?? 0,
      respondTime: (json['respondTime'] as num?)?.toInt() ?? 180000,
      weight: (json['weight'] as num?)?.toInt() ?? 0,
      exploreUrl: json['exploreUrl'] as String?,
      exploreScreen: json['exploreScreen'] as String?,
      ruleExplore: json['ruleExplore'] == null
          ? null
          : ExploreRule.fromJson(json['ruleExplore'] as Map<String, dynamic>),
      searchUrl: json['searchUrl'] as String?,
      ruleSearch: json['ruleSearch'] == null
          ? null
          : SearchRule.fromJson(json['ruleSearch'] as Map<String, dynamic>),
      ruleBookInfo: json['ruleBookInfo'] == null
          ? null
          : BookInfoRule.fromJson(json['ruleBookInfo'] as Map<String, dynamic>),
      ruleToc: json['ruleToc'] == null
          ? null
          : TocRule.fromJson(json['ruleToc'] as Map<String, dynamic>),
      ruleContent: json['ruleContent'] == null
          ? null
          : ContentRule.fromJson(json['ruleContent'] as Map<String, dynamic>),
      ruleReview: json['ruleReview'] == null
          ? null
          : ReviewRule.fromJson(json['ruleReview'] as Map<String, dynamic>),
      mainJs: json['mainJs'] as String?,
      eventListener: json['eventListener'] as bool? ?? false,
      customButton: json['customButton'] as bool? ?? false,
    );

Map<String, dynamic> _$$BookSourceImplToJson(_$BookSourceImpl instance) =>
    <String, dynamic>{
      'bookSourceUrl': instance.bookSourceUrl,
      'bookSourceName': instance.bookSourceName,
      'bookSourceGroup': instance.bookSourceGroup,
      'bookSourceType': instance.bookSourceType,
      'bookUrlPattern': instance.bookUrlPattern,
      'customOrder': instance.customOrder,
      'enabled': instance.enabled,
      'enabledExplore': instance.enabledExplore,
      'jsLib': instance.jsLib,
      'enabledCookieJar': instance.enabledCookieJar,
      'concurrentRate': instance.concurrentRate,
      'header': instance.header,
      'loginUrl': instance.loginUrl,
      'loginUi': instance.loginUi,
      'loginCheckJs': instance.loginCheckJs,
      'coverDecodeJs': instance.coverDecodeJs,
      'bookSourceComment': instance.bookSourceComment,
      'variableComment': instance.variableComment,
      'lastUpdateTime': instance.lastUpdateTime,
      'respondTime': instance.respondTime,
      'weight': instance.weight,
      'exploreUrl': instance.exploreUrl,
      'exploreScreen': instance.exploreScreen,
      'ruleExplore': instance.ruleExplore,
      'searchUrl': instance.searchUrl,
      'ruleSearch': instance.ruleSearch,
      'ruleBookInfo': instance.ruleBookInfo,
      'ruleToc': instance.ruleToc,
      'ruleContent': instance.ruleContent,
      'ruleReview': instance.ruleReview,
      'mainJs': instance.mainJs,
      'eventListener': instance.eventListener,
      'customButton': instance.customButton,
    };
