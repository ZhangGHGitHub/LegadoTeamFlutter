// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'source_match.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$SourceMatchImpl _$$SourceMatchImplFromJson(Map<String, dynamic> json) =>
    _$SourceMatchImpl(
      sourceUrl: json['source_url'] as String? ?? '',
      sourceName: json['source_name'] as String? ?? '',
      bookUrl: json['book_url'] as String? ?? '',
      bookName: json['book_name'] as String? ?? '',
      author: json['author'] as String? ?? '',
      latestChapter: json['latest_chapter'] as String?,
      wordCount: json['word_count'] as String?,
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
      chapterWordCountText: json['chapter_word_count_text'] as String?,
      chapterWordCount: (json['chapter_word_count'] as num?)?.toInt() ?? -1,
      respondTime: (json['respond_time'] as num?)?.toInt() ?? -1,
      originOrder: (json['origin_order'] as num?)?.toInt() ?? 0,
      bookScore: (json['book_score'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$SourceMatchImplToJson(_$SourceMatchImpl instance) =>
    <String, dynamic>{
      'source_url': instance.sourceUrl,
      'source_name': instance.sourceName,
      'book_url': instance.bookUrl,
      'book_name': instance.bookName,
      'author': instance.author,
      'latest_chapter': instance.latestChapter,
      'word_count': instance.wordCount,
      'score': instance.score,
      'chapter_word_count_text': instance.chapterWordCountText,
      'chapter_word_count': instance.chapterWordCount,
      'respond_time': instance.respondTime,
      'origin_order': instance.originOrder,
      'book_score': instance.bookScore,
    };
