// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'book_chapter.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$BookChapterImpl _$$BookChapterImplFromJson(Map<String, dynamic> json) =>
    _$BookChapterImpl(
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      isVolume: json['isVolume'] as bool? ?? false,
      baseUrl: json['baseUrl'] as String? ?? '',
      bookUrl: json['bookUrl'] as String? ?? '',
      index: (json['index'] as num?)?.toInt() ?? 0,
      isVip: json['isVip'] as bool? ?? false,
      isPay: json['isPay'] as bool? ?? false,
      resourceUrl: json['resourceUrl'] as String?,
      tag: json['tag'] as String?,
      wordCount: json['wordCount'] as String?,
      start: (json['start'] as num?)?.toInt(),
      end: (json['end'] as num?)?.toInt(),
      startFragmentId: json['startFragmentId'] as String?,
      endFragmentId: json['endFragmentId'] as String?,
      variable: json['variable'] as String?,
      imgUrl: json['imgUrl'] as String?,
    );

Map<String, dynamic> _$$BookChapterImplToJson(_$BookChapterImpl instance) =>
    <String, dynamic>{
      'url': instance.url,
      'title': instance.title,
      'isVolume': instance.isVolume,
      'baseUrl': instance.baseUrl,
      'bookUrl': instance.bookUrl,
      'index': instance.index,
      'isVip': instance.isVip,
      'isPay': instance.isPay,
      'resourceUrl': instance.resourceUrl,
      'tag': instance.tag,
      'wordCount': instance.wordCount,
      'start': instance.start,
      'end': instance.end,
      'startFragmentId': instance.startFragmentId,
      'endFragmentId': instance.endFragmentId,
      'variable': instance.variable,
      'imgUrl': instance.imgUrl,
    };
