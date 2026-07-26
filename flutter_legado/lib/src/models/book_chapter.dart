import 'package:freezed_annotation/freezed_annotation.dart';

part 'book_chapter.freezed.dart';
part 'book_chapter.g.dart';

/// 章节实体
@freezed
class BookChapter with _$BookChapter {
  const factory BookChapter({
    @Default('') String url,
    @Default('') String title,
    @Default(false) @JsonKey(name: 'isVolume') bool isVolume,
    @Default('') @JsonKey(name: 'baseUrl') String baseUrl,
    @Default('') @JsonKey(name: 'bookUrl') String bookUrl,
    @Default(0) int index,
    @Default(false) @JsonKey(name: 'isVip') bool isVip,
    @Default(false) @JsonKey(name: 'isPay') bool isPay,
    @JsonKey(name: 'resourceUrl') String? resourceUrl,
    String? tag,
    @JsonKey(name: 'wordCount') String? wordCount,
    int? start,
    int? end,
    @JsonKey(name: 'startFragmentId') String? startFragmentId,
    @JsonKey(name: 'endFragmentId') String? endFragmentId,
    String? variable,
    @JsonKey(name: 'imgUrl') String? imgUrl,
  }) = _BookChapter;

  factory BookChapter.fromJson(Map<String, dynamic> json) =>
      _$BookChapterFromJson(json);
}
