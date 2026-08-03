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
    );

Map<String, dynamic> _$$RssReadRecordRowImplToJson(
        _$RssReadRecordRowImpl instance) =>
    <String, dynamic>{
      'origin': instance.origin,
      'title': instance.title,
      'link': instance.link,
      'read_time': instance.readTime,
    };
