// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cover_candidate.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$CoverCandidateImpl _$$CoverCandidateImplFromJson(Map<String, dynamic> json) =>
    _$CoverCandidateImpl(
      url: json['url'] as String? ?? '',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$CoverCandidateImplToJson(
        _$CoverCandidateImpl instance) =>
    <String, dynamic>{
      'url': instance.url,
      'width': instance.width,
      'height': instance.height,
    };
