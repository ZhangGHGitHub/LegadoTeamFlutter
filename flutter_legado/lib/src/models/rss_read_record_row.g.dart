// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'rss_read_record_row.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$RssReadRecordRowImpl _$$RssReadRecordRowImplFromJson(
        Map<String, dynamic> json) =>
    _$RssReadRecordRowImpl(
      origin: json['origin'] as String? ?? '',
      title: json['title'] as String? ?? '',
      link: json['link'] as String?,
      readTime: (json['read_time'] as num?)?.toInt() ?? 0,
      type: (json['type'] as num?)?.toInt() ?? 0,
      sort: json['sort'] as String? ?? '',
      image: json['image'] as String?,
      pubDate: json['pubDate'] as String?,
      durPos: (json['durPos'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$RssReadRecordRowImplToJson(
        _$RssReadRecordRowImpl instance) =>
    <String, dynamic>{
      'origin': instance.origin,
      'title': instance.title,
      'link': instance.link,
      'read_time': instance.readTime,
      'type': instance.type,
      'sort': instance.sort,
      'image': instance.image,
      'pubDate': instance.pubDate,
      'durPos': instance.durPos,
    };
