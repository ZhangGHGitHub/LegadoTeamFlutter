// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'misc.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$SearchBookImpl _$$SearchBookImplFromJson(Map<String, dynamic> json) =>
    _$SearchBookImpl(
      bookUrl: json['bookUrl'] as String? ?? '',
      origin: json['origin'] as String? ?? '',
      originName: json['originName'] as String? ?? '',
      bookType: (json['type'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      author: json['author'] as String? ?? '',
      kind: json['kind'] as String?,
      coverUrl: json['coverUrl'] as String?,
      intro: json['intro'] as String?,
      wordCount: json['wordCount'] as String?,
      latestChapterTitle: json['latestChapterTitle'] as String?,
      tocUrl: json['tocUrl'] as String? ?? '',
      time: (json['time'] as num?)?.toInt() ?? 0,
      variable: json['variable'] as String?,
      originOrder: (json['originOrder'] as num?)?.toInt() ?? 0,
      chapterWordCountText: json['chapterWordCountText'] as String?,
      chapterWordCount: (json['chapterWordCount'] as num?)?.toInt() ?? -1,
      respondTime: (json['respondTime'] as num?)?.toInt() ?? -1,
    );

Map<String, dynamic> _$$SearchBookImplToJson(_$SearchBookImpl instance) =>
    <String, dynamic>{
      'bookUrl': instance.bookUrl,
      'origin': instance.origin,
      'originName': instance.originName,
      'type': instance.bookType,
      'name': instance.name,
      'author': instance.author,
      'kind': instance.kind,
      'coverUrl': instance.coverUrl,
      'intro': instance.intro,
      'wordCount': instance.wordCount,
      'latestChapterTitle': instance.latestChapterTitle,
      'tocUrl': instance.tocUrl,
      'time': instance.time,
      'variable': instance.variable,
      'originOrder': instance.originOrder,
      'chapterWordCountText': instance.chapterWordCountText,
      'chapterWordCount': instance.chapterWordCount,
      'respondTime': instance.respondTime,
    };

_$ReplaceRuleImpl _$$ReplaceRuleImplFromJson(Map<String, dynamic> json) =>
    _$ReplaceRuleImpl(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      group: json['group'] as String?,
      pattern: json['pattern'] as String? ?? '',
      replacement: json['replacement'] as String? ?? '',
      scope: json['scope'] as String?,
      scopeTitle: json['scopeTitle'] as bool? ?? false,
      scopeContent: json['scopeContent'] as bool? ?? true,
      excludeScope: json['excludeScope'] as String?,
      isEnabled: json['isEnabled'] as bool? ?? true,
      isRegex: json['isRegex'] as bool? ?? true,
      timeoutMillisecond: (json['timeoutMillisecond'] as num?)?.toInt() ?? 3000,
      order: (json['sortOrder'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$ReplaceRuleImplToJson(_$ReplaceRuleImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'group': instance.group,
      'pattern': instance.pattern,
      'replacement': instance.replacement,
      'scope': instance.scope,
      'scopeTitle': instance.scopeTitle,
      'scopeContent': instance.scopeContent,
      'excludeScope': instance.excludeScope,
      'isEnabled': instance.isEnabled,
      'isRegex': instance.isRegex,
      'timeoutMillisecond': instance.timeoutMillisecond,
      'sortOrder': instance.order,
    };

_$HttpTtsImpl _$$HttpTtsImplFromJson(Map<String, dynamic> json) =>
    _$HttpTtsImpl(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      contentType: json['contentType'] as String?,
      pauseDuration: (json['pauseDuration'] as num?)?.toInt() ?? 0,
      concurrentRate: json['concurrentRate'] as String?,
      loginUrl: json['loginUrl'] as String?,
      loginUi: json['loginUi'] as String?,
      header: json['header'] as String?,
      jsLib: json['jsLib'] as String?,
      enabledCookieJar: json['enabledCookieJar'] as bool?,
      loginCheckJs: json['loginCheckJs'] as String?,
      lastUpdateTime: (json['lastUpdateTime'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$HttpTtsImplToJson(_$HttpTtsImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'url': instance.url,
      'contentType': instance.contentType,
      'pauseDuration': instance.pauseDuration,
      'concurrentRate': instance.concurrentRate,
      'loginUrl': instance.loginUrl,
      'loginUi': instance.loginUi,
      'header': instance.header,
      'jsLib': instance.jsLib,
      'enabledCookieJar': instance.enabledCookieJar,
      'loginCheckJs': instance.loginCheckJs,
      'lastUpdateTime': instance.lastUpdateTime,
    };

_$BookmarkImpl _$$BookmarkImplFromJson(Map<String, dynamic> json) =>
    _$BookmarkImpl(
      id: (json['id'] as num?)?.toInt() ?? 0,
      time: (json['time'] as num?)?.toInt() ?? 0,
      bookName: json['bookName'] as String? ?? '',
      bookAuthor: json['bookAuthor'] as String? ?? '',
      chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
      chapterPos: (json['chapterPos'] as num?)?.toInt() ?? 0,
      chapterName: json['chapterName'] as String? ?? '',
      bookText: json['bookText'] as String? ?? '',
      content: json['content'] as String? ?? '',
    );

Map<String, dynamic> _$$BookmarkImplToJson(_$BookmarkImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'time': instance.time,
      'bookName': instance.bookName,
      'bookAuthor': instance.bookAuthor,
      'chapterIndex': instance.chapterIndex,
      'chapterPos': instance.chapterPos,
      'chapterName': instance.chapterName,
      'bookText': instance.bookText,
      'content': instance.content,
    };

_$BookGroupImpl _$$BookGroupImplFromJson(Map<String, dynamic> json) =>
    _$BookGroupImpl(
      groupId: (json['groupId'] as num?)?.toInt() ?? 1,
      groupName: json['groupName'] as String? ?? '',
      cover: json['cover'] as String?,
      order: (json['order'] as num?)?.toInt() ?? 0,
      enableRefresh: json['enableRefresh'] as bool? ?? true,
      show: json['show'] as bool? ?? true,
      bookSort: (json['bookSort'] as num?)?.toInt() ?? -1,
      onlyUpdateRead: json['onlyUpdateRead'] as bool? ?? false,
    );

Map<String, dynamic> _$$BookGroupImplToJson(_$BookGroupImpl instance) =>
    <String, dynamic>{
      'groupId': instance.groupId,
      'groupName': instance.groupName,
      'cover': instance.cover,
      'order': instance.order,
      'enableRefresh': instance.enableRefresh,
      'show': instance.show,
      'bookSort': instance.bookSort,
      'onlyUpdateRead': instance.onlyUpdateRead,
    };

_$AutoTaskRuleImpl _$$AutoTaskRuleImplFromJson(Map<String, dynamic> json) =>
    _$AutoTaskRuleImpl(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      enable: json['enable'] as bool? ?? true,
      cron: json['cron'] as String?,
      loginUrl: json['loginUrl'] as String?,
      loginUi: json['loginUi'] as String?,
      loginCheckJs: json['loginCheckJs'] as String?,
      comment: json['comment'] as String?,
      script: json['script'] as String? ?? '',
      header: json['header'] as String?,
      jsLib: json['jsLib'] as String?,
      concurrentRate: json['concurrentRate'] as String?,
      enabledCookieJar: json['enabledCookieJar'] as bool? ?? true,
      customOrder: (json['customOrder'] as num?)?.toInt() ?? 0,
      lastRunAt: (json['lastRunAt'] as num?)?.toInt() ?? 0,
      lastResult: json['lastResult'] as String?,
      lastError: json['lastError'] as String?,
      lastLog: json['lastLog'] as String?,
    );

Map<String, dynamic> _$$AutoTaskRuleImplToJson(_$AutoTaskRuleImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'enable': instance.enable,
      'cron': instance.cron,
      'loginUrl': instance.loginUrl,
      'loginUi': instance.loginUi,
      'loginCheckJs': instance.loginCheckJs,
      'comment': instance.comment,
      'script': instance.script,
      'header': instance.header,
      'jsLib': instance.jsLib,
      'concurrentRate': instance.concurrentRate,
      'enabledCookieJar': instance.enabledCookieJar,
      'customOrder': instance.customOrder,
      'lastRunAt': instance.lastRunAt,
      'lastResult': instance.lastResult,
      'lastError': instance.lastError,
      'lastLog': instance.lastLog,
    };

_$RssArticleImpl _$$RssArticleImplFromJson(Map<String, dynamic> json) =>
    _$RssArticleImpl(
      origin: json['origin'] as String? ?? '',
      sort: json['sort'] as String? ?? '',
      title: json['title'] as String? ?? '',
      order: (json['order'] as num?)?.toInt() ?? 0,
      link: json['link'] as String? ?? '',
      pubDate: json['pubDate'] as String?,
      description: json['description'] as String?,
      content: json['content'] as String?,
      image: json['image'] as String?,
      group: json['group'] as String? ?? '默认分组',
      read: json['read'] as bool? ?? false,
      variable: json['variable'] as String?,
      articleType: (json['type'] as num?)?.toInt() ?? 0,
      durPos: (json['durPos'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$RssArticleImplToJson(_$RssArticleImpl instance) =>
    <String, dynamic>{
      'origin': instance.origin,
      'sort': instance.sort,
      'title': instance.title,
      'order': instance.order,
      'link': instance.link,
      'pubDate': instance.pubDate,
      'description': instance.description,
      'content': instance.content,
      'image': instance.image,
      'group': instance.group,
      'read': instance.read,
      'variable': instance.variable,
      'type': instance.articleType,
      'durPos': instance.durPos,
    };

_$RssStarImpl _$$RssStarImplFromJson(Map<String, dynamic> json) =>
    _$RssStarImpl(
      origin: json['origin'] as String? ?? '',
      sort: json['sort'] as String? ?? '',
      title: json['title'] as String? ?? '',
      starTime: (json['starTime'] as num?)?.toInt() ?? 0,
      link: json['link'] as String? ?? '',
      pubDate: json['pubDate'] as String?,
      description: json['description'] as String?,
      content: json['content'] as String?,
      image: json['image'] as String?,
      group: json['group'] as String? ?? '默认分组',
      variable: json['variable'] as String?,
      starType: (json['type'] as num?)?.toInt() ?? 0,
      durPos: (json['durPos'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$RssStarImplToJson(_$RssStarImpl instance) =>
    <String, dynamic>{
      'origin': instance.origin,
      'sort': instance.sort,
      'title': instance.title,
      'starTime': instance.starTime,
      'link': instance.link,
      'pubDate': instance.pubDate,
      'description': instance.description,
      'content': instance.content,
      'image': instance.image,
      'group': instance.group,
      'variable': instance.variable,
      'type': instance.starType,
      'durPos': instance.durPos,
    };

_$CookieImpl _$$CookieImplFromJson(Map<String, dynamic> json) => _$CookieImpl(
  url: json['url'] as String? ?? '',
  cookie: json['cookie'] as String? ?? '',
);

Map<String, dynamic> _$$CookieImplToJson(_$CookieImpl instance) =>
    <String, dynamic>{'url': instance.url, 'cookie': instance.cookie};

_$CacheImpl _$$CacheImplFromJson(Map<String, dynamic> json) => _$CacheImpl(
  key: json['key'] as String? ?? '',
  value: json['value'] as String?,
  deadline: (json['deadline'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$$CacheImplToJson(_$CacheImpl instance) =>
    <String, dynamic>{
      'key': instance.key,
      'value': instance.value,
      'deadline': instance.deadline,
    };

_$DictRuleImpl _$$DictRuleImplFromJson(Map<String, dynamic> json) =>
    _$DictRuleImpl(
      name: json['name'] as String? ?? '',
      urlRule: json['urlRule'] as String? ?? '',
      showRule: json['showRule'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      sortNumber: (json['sortNumber'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$DictRuleImplToJson(_$DictRuleImpl instance) =>
    <String, dynamic>{
      'name': instance.name,
      'urlRule': instance.urlRule,
      'showRule': instance.showRule,
      'enabled': instance.enabled,
      'sortNumber': instance.sortNumber,
    };

_$ServerImpl _$$ServerImplFromJson(Map<String, dynamic> json) => _$ServerImpl(
  id: (json['id'] as num?)?.toInt() ?? 0,
  name: json['name'] as String? ?? '',
  serverType: json['type'] as String? ?? 'WEBDAV',
  config: json['config'] as String?,
  sortNumber: (json['sortNumber'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$$ServerImplToJson(_$ServerImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'type': instance.serverType,
      'config': instance.config,
      'sortNumber': instance.sortNumber,
    };

_$WebDavConfigImpl _$$WebDavConfigImplFromJson(Map<String, dynamic> json) =>
    _$WebDavConfigImpl(
      url: json['url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
    );

Map<String, dynamic> _$$WebDavConfigImplToJson(_$WebDavConfigImpl instance) =>
    <String, dynamic>{
      'url': instance.url,
      'username': instance.username,
      'password': instance.password,
    };

_$BookSourcePartImpl _$$BookSourcePartImplFromJson(Map<String, dynamic> json) =>
    _$BookSourcePartImpl(
      bookSourceUrl: json['bookSourceUrl'] as String? ?? '',
      bookSourceName: json['bookSourceName'] as String? ?? '',
      bookSourceGroup: json['bookSourceGroup'] as String?,
      customOrder: (json['customOrder'] as num?)?.toInt() ?? 0,
      enabled: json['enabled'] as bool? ?? true,
      enabledExplore: json['enabledExplore'] as bool? ?? true,
      hasLoginUrl: json['hasLoginUrl'] as bool? ?? false,
      lastUpdateTime: (json['lastUpdateTime'] as num?)?.toInt() ?? 0,
      respondTime: (json['respondTime'] as num?)?.toInt() ?? 180000,
      weight: (json['weight'] as num?)?.toInt() ?? 0,
      hasExploreUrl: json['hasExploreUrl'] as bool? ?? false,
      eventListener: json['eventListener'] as bool? ?? false,
      bookSourceType: (json['bookSourceType'] as num?)?.toInt() ?? 0,
      hasJs: json['hasJs'] as bool? ?? false,
    );

Map<String, dynamic> _$$BookSourcePartImplToJson(
  _$BookSourcePartImpl instance,
) => <String, dynamic>{
  'bookSourceUrl': instance.bookSourceUrl,
  'bookSourceName': instance.bookSourceName,
  'bookSourceGroup': instance.bookSourceGroup,
  'customOrder': instance.customOrder,
  'enabled': instance.enabled,
  'enabledExplore': instance.enabledExplore,
  'hasLoginUrl': instance.hasLoginUrl,
  'lastUpdateTime': instance.lastUpdateTime,
  'respondTime': instance.respondTime,
  'weight': instance.weight,
  'hasExploreUrl': instance.hasExploreUrl,
  'eventListener': instance.eventListener,
  'bookSourceType': instance.bookSourceType,
  'hasJs': instance.hasJs,
};

_$SearchKeywordImpl _$$SearchKeywordImplFromJson(Map<String, dynamic> json) =>
    _$SearchKeywordImpl(
      word: json['word'] as String? ?? '',
      usage: (json['usage'] as num?)?.toInt() ?? 1,
      lastUseTime: (json['lastUseTime'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$SearchKeywordImplToJson(_$SearchKeywordImpl instance) =>
    <String, dynamic>{
      'word': instance.word,
      'usage': instance.usage,
      'lastUseTime': instance.lastUseTime,
    };

_$RuleSubImpl _$$RuleSubImplFromJson(Map<String, dynamic> json) =>
    _$RuleSubImpl(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      subType: (json['type'] as num?)?.toInt() ?? 0,
      customOrder: (json['customOrder'] as num?)?.toInt() ?? 0,
      autoUpdate: json['autoUpdate'] as bool? ?? false,
      update: (json['update'] as num?)?.toInt() ?? 0,
      updateInterval: (json['updateInterval'] as num?)?.toInt() ?? 0,
      silentUpdate: json['silentUpdate'] as bool? ?? false,
      js: json['js'] as String?,
      showRule: json['showRule'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
    );

Map<String, dynamic> _$$RuleSubImplToJson(_$RuleSubImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'url': instance.url,
      'type': instance.subType,
      'customOrder': instance.customOrder,
      'autoUpdate': instance.autoUpdate,
      'update': instance.update,
      'updateInterval': instance.updateInterval,
      'silentUpdate': instance.silentUpdate,
      'js': instance.js,
      'showRule': instance.showRule,
      'sourceUrl': instance.sourceUrl,
    };

_$TxtTocRuleImpl _$$TxtTocRuleImplFromJson(Map<String, dynamic> json) =>
    _$TxtTocRuleImpl(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      rule: json['rule'] as String? ?? '',
      replacement: json['replacement'] as String? ?? '',
      example: json['example'] as String?,
      serialNumber: (json['serialNumber'] as num?)?.toInt() ?? -1,
      enable: json['enable'] as bool? ?? true,
    );

Map<String, dynamic> _$$TxtTocRuleImplToJson(_$TxtTocRuleImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'rule': instance.rule,
      'replacement': instance.replacement,
      'example': instance.example,
      'serialNumber': instance.serialNumber,
      'enable': instance.enable,
    };

_$BookChapterReviewImpl _$$BookChapterReviewImplFromJson(
  Map<String, dynamic> json,
) => _$BookChapterReviewImpl(
  bookId: (json['bookId'] as num?)?.toInt() ?? 0,
  chapterId: (json['chapterId'] as num?)?.toInt() ?? 0,
  summaryUrl: json['summaryUrl'] as String? ?? '',
);

Map<String, dynamic> _$$BookChapterReviewImplToJson(
  _$BookChapterReviewImpl instance,
) => <String, dynamic>{
  'bookId': instance.bookId,
  'chapterId': instance.chapterId,
  'summaryUrl': instance.summaryUrl,
};

_$KeyboardAssistImpl _$$KeyboardAssistImplFromJson(Map<String, dynamic> json) =>
    _$KeyboardAssistImpl(
      assistType: (json['type'] as num?)?.toInt() ?? 0,
      key: json['key'] as String? ?? '',
      value: json['value'] as String? ?? '',
      serialNo: (json['serialNo'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$KeyboardAssistImplToJson(
  _$KeyboardAssistImpl instance,
) => <String, dynamic>{
  'type': instance.assistType,
  'key': instance.key,
  'value': instance.value,
  'serialNo': instance.serialNo,
};

_$ReadRecordImpl _$$ReadRecordImplFromJson(Map<String, dynamic> json) =>
    _$ReadRecordImpl(
      deviceId: json['deviceId'] as String? ?? '',
      bookName: json['bookName'] as String? ?? '',
      readTime: (json['readTime'] as num?)?.toInt() ?? 0,
      lastRead: (json['lastRead'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$ReadRecordImplToJson(_$ReadRecordImpl instance) =>
    <String, dynamic>{
      'deviceId': instance.deviceId,
      'bookName': instance.bookName,
      'readTime': instance.readTime,
      'lastRead': instance.lastRead,
    };

_$RssReadRecordImpl _$$RssReadRecordImplFromJson(Map<String, dynamic> json) =>
    _$RssReadRecordImpl(
      record: json['record'] as String? ?? '',
      title: json['title'] as String?,
      readTime: (json['readTime'] as num?)?.toInt(),
      read: json['read'] as bool? ?? true,
      origin: json['origin'] as String? ?? '',
      sort: json['sort'] as String? ?? '',
      image: json['image'] as String?,
      recordType: (json['type'] as num?)?.toInt() ?? 0,
      durPos: (json['durPos'] as num?)?.toInt() ?? 0,
      pubDate: json['pubDate'] as String?,
    );

Map<String, dynamic> _$$RssReadRecordImplToJson(_$RssReadRecordImpl instance) =>
    <String, dynamic>{
      'record': instance.record,
      'title': instance.title,
      'readTime': instance.readTime,
      'read': instance.read,
      'origin': instance.origin,
      'sort': instance.sort,
      'image': instance.image,
      'type': instance.recordType,
      'durPos': instance.durPos,
      'pubDate': instance.pubDate,
    };

_$BookProgressImpl _$$BookProgressImplFromJson(Map<String, dynamic> json) =>
    _$BookProgressImpl(
      name: json['name'] as String? ?? '',
      author: json['author'] as String? ?? '',
      durChapterIndex: (json['durChapterIndex'] as num?)?.toInt() ?? 0,
      durChapterPos: (json['durChapterPos'] as num?)?.toInt() ?? 0,
      durChapterTime: (json['durChapterTime'] as num?)?.toInt() ?? 0,
      durChapterTitle: json['durChapterTitle'] as String?,
    );

Map<String, dynamic> _$$BookProgressImplToJson(_$BookProgressImpl instance) =>
    <String, dynamic>{
      'name': instance.name,
      'author': instance.author,
      'durChapterIndex': instance.durChapterIndex,
      'durChapterPos': instance.durChapterPos,
      'durChapterTime': instance.durChapterTime,
      'durChapterTitle': instance.durChapterTitle,
    };

_$ReplaceBookImpl _$$ReplaceBookImplFromJson(Map<String, dynamic> json) =>
    _$ReplaceBookImpl(
      bookUrl: json['bookUrl'] as String? ?? '',
      origin: json['origin'] as String? ?? '',
      originName: json['originName'] as String? ?? '',
      bookType: (json['type'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      author: json['author'] as String? ?? '',
      kind: json['kind'] as String?,
      coverUrl: json['coverUrl'] as String?,
      intro: json['intro'] as String?,
      wordCount: json['wordCount'] as String?,
      latestChapterTitle: json['latestChapterTitle'] as String?,
      tocUrl: json['tocUrl'] as String? ?? '',
      originOrder: (json['originOrder'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$ReplaceBookImplToJson(_$ReplaceBookImpl instance) =>
    <String, dynamic>{
      'bookUrl': instance.bookUrl,
      'origin': instance.origin,
      'originName': instance.originName,
      'type': instance.bookType,
      'name': instance.name,
      'author': instance.author,
      'kind': instance.kind,
      'coverUrl': instance.coverUrl,
      'intro': instance.intro,
      'wordCount': instance.wordCount,
      'latestChapterTitle': instance.latestChapterTitle,
      'tocUrl': instance.tocUrl,
      'originOrder': instance.originOrder,
    };

_$BookCacheInfoImpl _$$BookCacheInfoImplFromJson(Map<String, dynamic> json) =>
    _$BookCacheInfoImpl(
      bookUrl: json['bookUrl'] as String? ?? '',
      name: json['name'] as String? ?? '',
      origin: json['origin'] as String? ?? '',
      originName: json['originName'] as String? ?? '',
      bookType: (json['type'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$BookCacheInfoImplToJson(_$BookCacheInfoImpl instance) =>
    <String, dynamic>{
      'bookUrl': instance.bookUrl,
      'name': instance.name,
      'origin': instance.origin,
      'originName': instance.originName,
      'type': instance.bookType,
    };

_$ReadRecordShowImpl _$$ReadRecordShowImplFromJson(Map<String, dynamic> json) =>
    _$ReadRecordShowImpl(
      bookName: json['bookName'] as String? ?? '',
      readTime: (json['readTime'] as num?)?.toInt() ?? 0,
      lastRead: (json['lastRead'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$ReadRecordShowImplToJson(
  _$ReadRecordShowImpl instance,
) => <String, dynamic>{
  'bookName': instance.bookName,
  'readTime': instance.readTime,
  'lastRead': instance.lastRead,
};
