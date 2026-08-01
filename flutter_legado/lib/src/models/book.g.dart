// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'book.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ReadConfigImpl _$$ReadConfigImplFromJson(Map<String, dynamic> json) =>
    _$ReadConfigImpl(
      reverseToc: json['reverseToc'] as bool? ?? false,
      pageAnim: (json['pageAnim'] as num?)?.toInt(),
      reSegment: json['reSegment'] as bool? ?? false,
      imageStyle: json['imageStyle'] as String?,
      useReplaceRule: json['useReplaceRule'] as bool?,
      delTag: (json['delTag'] as num?)?.toInt() ?? 0,
      ttsEngine: json['ttsEngine'] as String?,
      splitLongChapter: json['splitLongChapter'] as bool? ?? true,
      readSimulating: json['readSimulating'] as bool? ?? false,
      startDate: json['startDate'] as String?,
      startChapter: (json['startChapter'] as num?)?.toInt(),
      dailyChapters: (json['dailyChapters'] as num?)?.toInt() ?? 3,
      openCredits: (json['openCredits'] as num?)?.toInt() ?? 0,
      closeCredits: (json['closeCredits'] as num?)?.toInt() ?? 0,
      playMode: (json['playMode'] as num?)?.toInt() ?? 0,
      playSpeed: (json['playSpeed'] as num?)?.toDouble() ?? 1.0,
    );

Map<String, dynamic> _$$ReadConfigImplToJson(_$ReadConfigImpl instance) =>
    <String, dynamic>{
      'reverseToc': instance.reverseToc,
      'pageAnim': instance.pageAnim,
      'reSegment': instance.reSegment,
      'imageStyle': instance.imageStyle,
      'useReplaceRule': instance.useReplaceRule,
      'delTag': instance.delTag,
      'ttsEngine': instance.ttsEngine,
      'splitLongChapter': instance.splitLongChapter,
      'readSimulating': instance.readSimulating,
      'startDate': instance.startDate,
      'startChapter': instance.startChapter,
      'dailyChapters': instance.dailyChapters,
      'openCredits': instance.openCredits,
      'closeCredits': instance.closeCredits,
      'playMode': instance.playMode,
      'playSpeed': instance.playSpeed,
    };

_$BookImpl _$$BookImplFromJson(Map<String, dynamic> json) => _$BookImpl(
      bookUrl: json['bookUrl'] as String? ?? '',
      tocUrl: json['tocUrl'] as String? ?? '',
      origin: json['origin'] as String? ?? 'loc_book',
      originName: json['originName'] as String? ?? '',
      name: json['name'] as String? ?? '',
      author: json['author'] as String? ?? '',
      kind: json['kind'] as String?,
      customTag: json['customTag'] as String?,
      coverUrl: json['coverUrl'] as String?,
      customCoverUrl: json['customCoverUrl'] as String?,
      intro: json['intro'] as String?,
      customIntro: json['customIntro'] as String?,
      charset: json['charset'] as String?,
      bookType: (json['type'] as num?)?.toInt() ?? 0,
      group: (json['group'] as num?)?.toInt() ?? 0,
      latestChapterTitle: json['latestChapterTitle'] as String?,
      latestChapterTime: (json['latestChapterTime'] as num?)?.toInt() ?? 0,
      lastCheckTime: (json['lastCheckTime'] as num?)?.toInt() ?? 0,
      lastCheckCount: (json['lastCheckCount'] as num?)?.toInt() ?? 0,
      totalChapterNum: (json['totalChapterNum'] as num?)?.toInt() ?? 0,
      durChapterTitle: json['durChapterTitle'] as String?,
      durChapterIndex: (json['durChapterIndex'] as num?)?.toInt() ?? 0,
      durVolumeIndex: (json['durVolumeIndex'] as num?)?.toInt() ?? 0,
      chapterInVolumeIndex:
          (json['chapterInVolumeIndex'] as num?)?.toInt() ?? 0,
      durChapterPos: (json['durChapterPos'] as num?)?.toInt() ?? 0,
      durChapterTime: (json['durChapterTime'] as num?)?.toInt() ?? 0,
      wordCount: json['wordCount'] as String?,
      canUpdate: json['canUpdate'] as bool? ?? true,
      order: (json['order'] as num?)?.toInt() ?? 0,
      originOrder: (json['originOrder'] as num?)?.toInt() ?? 0,
      variable: json['variable'] as String?,
      readConfig: json['readConfig'] == null
          ? null
          : ReadConfig.fromJson(json['readConfig'] as Map<String, dynamic>),
      syncTime: (json['syncTime'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$BookImplToJson(_$BookImpl instance) =>
    <String, dynamic>{
      'bookUrl': instance.bookUrl,
      'tocUrl': instance.tocUrl,
      'origin': instance.origin,
      'originName': instance.originName,
      'name': instance.name,
      'author': instance.author,
      'kind': instance.kind,
      'customTag': instance.customTag,
      'coverUrl': instance.coverUrl,
      'customCoverUrl': instance.customCoverUrl,
      'intro': instance.intro,
      'customIntro': instance.customIntro,
      'charset': instance.charset,
      'type': instance.bookType,
      'group': instance.group,
      'latestChapterTitle': instance.latestChapterTitle,
      'latestChapterTime': instance.latestChapterTime,
      'lastCheckTime': instance.lastCheckTime,
      'lastCheckCount': instance.lastCheckCount,
      'totalChapterNum': instance.totalChapterNum,
      'durChapterTitle': instance.durChapterTitle,
      'durChapterIndex': instance.durChapterIndex,
      'durVolumeIndex': instance.durVolumeIndex,
      'chapterInVolumeIndex': instance.chapterInVolumeIndex,
      'durChapterPos': instance.durChapterPos,
      'durChapterTime': instance.durChapterTime,
      'wordCount': instance.wordCount,
      'canUpdate': instance.canUpdate,
      'order': instance.order,
      'originOrder': instance.originOrder,
      'variable': instance.variable,
      'readConfig': instance.readConfig,
      'syncTime': instance.syncTime,
    };
