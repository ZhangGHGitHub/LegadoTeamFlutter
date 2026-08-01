// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rule.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$BookInfoRuleImpl _$$BookInfoRuleImplFromJson(Map<String, dynamic> json) =>
    _$BookInfoRuleImpl(
      init: json['init'] as String?,
      name: json['name'] as String?,
      author: json['author'] as String?,
      intro: json['intro'] as String?,
      kind: json['kind'] as String?,
      lastChapter: json['lastChapter'] as String?,
      updateTime: json['updateTime'] as String?,
      coverUrl: json['coverUrl'] as String?,
      tocUrl: json['tocUrl'] as String?,
      wordCount: json['wordCount'] as String?,
      canReName: json['canReName'] as String?,
      downloadUrls: json['downloadUrls'] as String?,
    );

Map<String, dynamic> _$$BookInfoRuleImplToJson(_$BookInfoRuleImpl instance) =>
    <String, dynamic>{
      'init': instance.init,
      'name': instance.name,
      'author': instance.author,
      'intro': instance.intro,
      'kind': instance.kind,
      'lastChapter': instance.lastChapter,
      'updateTime': instance.updateTime,
      'coverUrl': instance.coverUrl,
      'tocUrl': instance.tocUrl,
      'wordCount': instance.wordCount,
      'canReName': instance.canReName,
      'downloadUrls': instance.downloadUrls,
    };

_$SearchRuleImpl _$$SearchRuleImplFromJson(Map<String, dynamic> json) =>
    _$SearchRuleImpl(
      checkKeyWord: json['checkKeyWord'] as String?,
      bookList: json['bookList'] as String?,
      name: json['name'] as String?,
      author: json['author'] as String?,
      intro: json['intro'] as String?,
      kind: json['kind'] as String?,
      lastChapter: json['lastChapter'] as String?,
      updateTime: json['updateTime'] as String?,
      bookUrl: json['bookUrl'] as String?,
      coverUrl: json['coverUrl'] as String?,
      wordCount: json['wordCount'] as String?,
    );

Map<String, dynamic> _$$SearchRuleImplToJson(_$SearchRuleImpl instance) =>
    <String, dynamic>{
      'checkKeyWord': instance.checkKeyWord,
      'bookList': instance.bookList,
      'name': instance.name,
      'author': instance.author,
      'intro': instance.intro,
      'kind': instance.kind,
      'lastChapter': instance.lastChapter,
      'updateTime': instance.updateTime,
      'bookUrl': instance.bookUrl,
      'coverUrl': instance.coverUrl,
      'wordCount': instance.wordCount,
    };

_$TocRuleImpl _$$TocRuleImplFromJson(Map<String, dynamic> json) =>
    _$TocRuleImpl(
      preUpdateJs: json['preUpdateJs'] as String?,
      chapterList: json['chapterList'] as String?,
      chapterName: json['chapterName'] as String?,
      chapterUrl: json['chapterUrl'] as String?,
      formatJs: json['formatJs'] as String?,
      isVolume: json['isVolume'] as String?,
      isVip: json['isVip'] as String?,
      isPay: json['isPay'] as String?,
      updateTime: json['updateTime'] as String?,
      nextTocUrl: json['nextTocUrl'] as String?,
    );

Map<String, dynamic> _$$TocRuleImplToJson(_$TocRuleImpl instance) =>
    <String, dynamic>{
      'preUpdateJs': instance.preUpdateJs,
      'chapterList': instance.chapterList,
      'chapterName': instance.chapterName,
      'chapterUrl': instance.chapterUrl,
      'formatJs': instance.formatJs,
      'isVolume': instance.isVolume,
      'isVip': instance.isVip,
      'isPay': instance.isPay,
      'updateTime': instance.updateTime,
      'nextTocUrl': instance.nextTocUrl,
    };

_$ContentRuleImpl _$$ContentRuleImplFromJson(Map<String, dynamic> json) =>
    _$ContentRuleImpl(
      content: json['content'] as String?,
      subContent: json['subContent'] as String?,
      title: json['title'] as String?,
      nextContentUrl: json['nextContentUrl'] as String?,
      webJs: json['webJs'] as String?,
      sourceRegex: json['sourceRegex'] as String?,
      replaceRegex: json['replaceRegex'] as String?,
      imageStyle: json['imageStyle'] as String?,
      imageDecode: json['imageDecode'] as String?,
      payAction: json['payAction'] as String?,
      callBackJs: json['callBackJs'] as String?,
    );

Map<String, dynamic> _$$ContentRuleImplToJson(_$ContentRuleImpl instance) =>
    <String, dynamic>{
      'content': instance.content,
      'subContent': instance.subContent,
      'title': instance.title,
      'nextContentUrl': instance.nextContentUrl,
      'webJs': instance.webJs,
      'sourceRegex': instance.sourceRegex,
      'replaceRegex': instance.replaceRegex,
      'imageStyle': instance.imageStyle,
      'imageDecode': instance.imageDecode,
      'payAction': instance.payAction,
      'callBackJs': instance.callBackJs,
    };

_$ExploreRuleImpl _$$ExploreRuleImplFromJson(Map<String, dynamic> json) =>
    _$ExploreRuleImpl(
      bookList: json['bookList'] as String?,
      name: json['name'] as String?,
      author: json['author'] as String?,
      intro: json['intro'] as String?,
      kind: json['kind'] as String?,
      lastChapter: json['lastChapter'] as String?,
      updateTime: json['updateTime'] as String?,
      bookUrl: json['bookUrl'] as String?,
      coverUrl: json['coverUrl'] as String?,
      wordCount: json['wordCount'] as String?,
    );

Map<String, dynamic> _$$ExploreRuleImplToJson(_$ExploreRuleImpl instance) =>
    <String, dynamic>{
      'bookList': instance.bookList,
      'name': instance.name,
      'author': instance.author,
      'intro': instance.intro,
      'kind': instance.kind,
      'lastChapter': instance.lastChapter,
      'updateTime': instance.updateTime,
      'bookUrl': instance.bookUrl,
      'coverUrl': instance.coverUrl,
      'wordCount': instance.wordCount,
    };

_$ReviewRuleImpl _$$ReviewRuleImplFromJson(Map<String, dynamic> json) =>
    _$ReviewRuleImpl(
      reviewUrl: json['reviewUrl'] as String?,
      avatarRule: json['avatarRule'] as String?,
      contentRule: json['contentRule'] as String?,
      postTimeRule: json['postTimeRule'] as String?,
      reviewQuoteUrl: json['reviewQuoteUrl'] as String?,
      voteUpUrl: json['voteUpUrl'] as String?,
      voteDownUrl: json['voteDownUrl'] as String?,
      postReviewUrl: json['postReviewUrl'] as String?,
      postQuoteUrl: json['postQuoteUrl'] as String?,
      deleteUrl: json['deleteUrl'] as String?,
      enabled: json['enabled'] as bool? ?? false,
      reviewSummaryUrl: json['reviewSummaryUrl'] as String?,
      summaryListRule: json['summaryListRule'] as String?,
      summaryParagraphIndexRule: json['summaryParagraphIndexRule'] as String?,
      summaryParagraphDataRule: json['summaryParagraphDataRule'] as String?,
      summaryCountRule: json['summaryCountRule'] as String?,
      reviewDetailUrl: json['reviewDetailUrl'] as String?,
      reviewDetailNextPageUrl: json['reviewDetailNextPageUrl'] as String?,
      detailListRule: json['detailListRule'] as String?,
      detailIdRule: json['detailIdRule'] as String?,
      detailAvatarRule: json['detailAvatarRule'] as String?,
      detailNameRule: json['detailNameRule'] as String?,
      detailBadgeRule: json['detailBadgeRule'] as String?,
      detailContentRule: json['detailContentRule'] as String?,
      replyListRule: json['replyListRule'] as String?,
      replyIdRule: json['replyIdRule'] as String?,
      replyAvatarRule: json['replyAvatarRule'] as String?,
      replyNameRule: json['replyNameRule'] as String?,
      replyBadgeRule: json['replyBadgeRule'] as String?,
      replyContentRule: json['replyContentRule'] as String?,
    );

Map<String, dynamic> _$$ReviewRuleImplToJson(_$ReviewRuleImpl instance) =>
    <String, dynamic>{
      'reviewUrl': instance.reviewUrl,
      'avatarRule': instance.avatarRule,
      'contentRule': instance.contentRule,
      'postTimeRule': instance.postTimeRule,
      'reviewQuoteUrl': instance.reviewQuoteUrl,
      'voteUpUrl': instance.voteUpUrl,
      'voteDownUrl': instance.voteDownUrl,
      'postReviewUrl': instance.postReviewUrl,
      'postQuoteUrl': instance.postQuoteUrl,
      'deleteUrl': instance.deleteUrl,
      'enabled': instance.enabled,
      'reviewSummaryUrl': instance.reviewSummaryUrl,
      'summaryListRule': instance.summaryListRule,
      'summaryParagraphIndexRule': instance.summaryParagraphIndexRule,
      'summaryParagraphDataRule': instance.summaryParagraphDataRule,
      'summaryCountRule': instance.summaryCountRule,
      'reviewDetailUrl': instance.reviewDetailUrl,
      'reviewDetailNextPageUrl': instance.reviewDetailNextPageUrl,
      'detailListRule': instance.detailListRule,
      'detailIdRule': instance.detailIdRule,
      'detailAvatarRule': instance.detailAvatarRule,
      'detailNameRule': instance.detailNameRule,
      'detailBadgeRule': instance.detailBadgeRule,
      'detailContentRule': instance.detailContentRule,
      'replyListRule': instance.replyListRule,
      'replyIdRule': instance.replyIdRule,
      'replyAvatarRule': instance.replyAvatarRule,
      'replyNameRule': instance.replyNameRule,
      'replyBadgeRule': instance.replyBadgeRule,
      'replyContentRule': instance.replyContentRule,
    };

_$FlexChildStyleImpl _$$FlexChildStyleImplFromJson(Map<String, dynamic> json) =>
    _$FlexChildStyleImpl(
      layoutFlexGrow: (json['layout_flexGrow'] as num?)?.toDouble() ?? 0,
      layoutFlexShrink: (json['layout_flexShrink'] as num?)?.toDouble() ?? 1.0,
      layoutAlignSelf: json['layout_alignSelf'] as String? ?? 'auto',
      layoutFlexBasisPercent:
          (json['layout_flexBasisPercent'] as num?)?.toDouble() ?? -1.0,
      layoutWrapBefore: json['layout_wrapBefore'] as bool? ?? false,
      layoutJustifySelf: json['layout_justifySelf'] as String? ?? 'auto',
    );

Map<String, dynamic> _$$FlexChildStyleImplToJson(
        _$FlexChildStyleImpl instance) =>
    <String, dynamic>{
      'layout_flexGrow': instance.layoutFlexGrow,
      'layout_flexShrink': instance.layoutFlexShrink,
      'layout_alignSelf': instance.layoutAlignSelf,
      'layout_flexBasisPercent': instance.layoutFlexBasisPercent,
      'layout_wrapBefore': instance.layoutWrapBefore,
      'layout_justifySelf': instance.layoutJustifySelf,
    };

_$ExploreKindImpl _$$ExploreKindImplFromJson(Map<String, dynamic> json) =>
    _$ExploreKindImpl(
      title: json['title'] as String? ?? '',
      url: json['url'] as String?,
      type: json['type'] as String? ?? 'url',
      action: json['action'] as String?,
      chars:
          (json['chars'] as List<dynamic>?)?.map((e) => e as String?).toList(),
      defaultValue: json['default'] as String?,
      viewName: json['viewName'] as String?,
      style: json['style'] == null
          ? null
          : FlexChildStyle.fromJson(json['style'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$$ExploreKindImplToJson(_$ExploreKindImpl instance) =>
    <String, dynamic>{
      'title': instance.title,
      'url': instance.url,
      'type': instance.type,
      'action': instance.action,
      'chars': instance.chars,
      'default': instance.defaultValue,
      'viewName': instance.viewName,
      'style': instance.style,
    };

_$RowUiImpl _$$RowUiImplFromJson(Map<String, dynamic> json) => _$RowUiImpl(
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'text',
      action: json['action'] as String?,
      chars:
          (json['chars'] as List<dynamic>?)?.map((e) => e as String?).toList(),
      defaultValue: json['default'] as String?,
      viewName: json['viewName'] as String?,
      style: json['style'] == null
          ? null
          : FlexChildStyle.fromJson(json['style'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$$RowUiImplToJson(_$RowUiImpl instance) =>
    <String, dynamic>{
      'name': instance.name,
      'type': instance.type,
      'action': instance.action,
      'chars': instance.chars,
      'default': instance.defaultValue,
      'viewName': instance.viewName,
      'style': instance.style,
    };
