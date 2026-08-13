// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'source_match.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

SourceMatch _$SourceMatchFromJson(Map<String, dynamic> json) {
  return _SourceMatch.fromJson(json);
}

/// @nodoc
mixin _$SourceMatch {
  /// 书源 URL
  @JsonKey(name: 'source_url')
  String get sourceUrl => throw _privateConstructorUsedError;

  /// 书源名称
  @JsonKey(name: 'source_name')
  String get sourceName => throw _privateConstructorUsedError;

  /// 书籍详情页 URL
  @JsonKey(name: 'book_url')
  String get bookUrl => throw _privateConstructorUsedError;

  /// 书籍名称
  @JsonKey(name: 'book_name')
  String get bookName => throw _privateConstructorUsedError;

  /// 作者
  String get author => throw _privateConstructorUsedError;

  /// 最新章节
  @JsonKey(name: 'latest_chapter')
  String? get latestChapter => throw _privateConstructorUsedError;

  /// 字数信息
  @JsonKey(name: 'word_count')
  String? get wordCount => throw _privateConstructorUsedError;

  /// 匹配度评分（0.0 ~ 100.0）
  double get score => throw _privateConstructorUsedError;

  /// 试读章节字数展示
  @JsonKey(name: 'chapter_word_count_text')
  String? get chapterWordCountText => throw _privateConstructorUsedError;

  /// 试读章节字数（-1=未知）
  @JsonKey(name: 'chapter_word_count')
  int get chapterWordCount => throw _privateConstructorUsedError;

  /// 取字耗时毫秒
  @JsonKey(name: 'respond_time')
  int get respondTime => throw _privateConstructorUsedError;

  /// 书源 customOrder
  @JsonKey(name: 'origin_order')
  int get originOrder => throw _privateConstructorUsedError;

  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;
  @JsonKey(ignore: true)
  $SourceMatchCopyWith<SourceMatch> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SourceMatchCopyWith<$Res> {
  factory $SourceMatchCopyWith(
          SourceMatch value, $Res Function(SourceMatch) then) =
      _$SourceMatchCopyWithImpl<$Res, SourceMatch>;
  @useResult
  $Res call(
      {@JsonKey(name: 'source_url') String sourceUrl,
      @JsonKey(name: 'source_name') String sourceName,
      @JsonKey(name: 'book_url') String bookUrl,
      @JsonKey(name: 'book_name') String bookName,
      String author,
      @JsonKey(name: 'latest_chapter') String? latestChapter,
      @JsonKey(name: 'word_count') String? wordCount,
      double score,
      @JsonKey(name: 'chapter_word_count_text') String? chapterWordCountText,
      @JsonKey(name: 'chapter_word_count') int chapterWordCount,
      @JsonKey(name: 'respond_time') int respondTime,
      @JsonKey(name: 'origin_order') int originOrder});
}

/// @nodoc
class _$SourceMatchCopyWithImpl<$Res, $Val extends SourceMatch>
    implements $SourceMatchCopyWith<$Res> {
  _$SourceMatchCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? sourceUrl = null,
    Object? sourceName = null,
    Object? bookUrl = null,
    Object? bookName = null,
    Object? author = null,
    Object? latestChapter = freezed,
    Object? wordCount = freezed,
    Object? score = null,
    Object? chapterWordCountText = freezed,
    Object? chapterWordCount = null,
    Object? respondTime = null,
    Object? originOrder = null,
  }) {
    return _then(_value.copyWith(
      sourceUrl: null == sourceUrl
          ? _value.sourceUrl
          : sourceUrl // ignore: cast_nullable_to_non_nullable
              as String,
      sourceName: null == sourceName
          ? _value.sourceName
          : sourceName // ignore: cast_nullable_to_non_nullable
              as String,
      bookUrl: null == bookUrl
          ? _value.bookUrl
          : bookUrl // ignore: cast_nullable_to_non_nullable
              as String,
      bookName: null == bookName
          ? _value.bookName
          : bookName // ignore: cast_nullable_to_non_nullable
              as String,
      author: null == author
          ? _value.author
          : author // ignore: cast_nullable_to_non_nullable
              as String,
      latestChapter: freezed == latestChapter
          ? _value.latestChapter
          : latestChapter // ignore: cast_nullable_to_non_nullable
              as String?,
      wordCount: freezed == wordCount
          ? _value.wordCount
          : wordCount // ignore: cast_nullable_to_non_nullable
              as String?,
      score: null == score
          ? _value.score
          : score // ignore: cast_nullable_to_non_nullable
              as double,
      chapterWordCountText: freezed == chapterWordCountText
          ? _value.chapterWordCountText
          : chapterWordCountText // ignore: cast_nullable_to_non_nullable
              as String?,
      chapterWordCount: null == chapterWordCount
          ? _value.chapterWordCount
          : chapterWordCount // ignore: cast_nullable_to_non_nullable
              as int,
      respondTime: null == respondTime
          ? _value.respondTime
          : respondTime // ignore: cast_nullable_to_non_nullable
              as int,
      originOrder: null == originOrder
          ? _value.originOrder
          : originOrder // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SourceMatchImplCopyWith<$Res>
    implements $SourceMatchCopyWith<$Res> {
  factory _$$SourceMatchImplCopyWith(
          _$SourceMatchImpl value, $Res Function(_$SourceMatchImpl) then) =
      __$$SourceMatchImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {@JsonKey(name: 'source_url') String sourceUrl,
      @JsonKey(name: 'source_name') String sourceName,
      @JsonKey(name: 'book_url') String bookUrl,
      @JsonKey(name: 'book_name') String bookName,
      String author,
      @JsonKey(name: 'latest_chapter') String? latestChapter,
      @JsonKey(name: 'word_count') String? wordCount,
      double score,
      @JsonKey(name: 'chapter_word_count_text') String? chapterWordCountText,
      @JsonKey(name: 'chapter_word_count') int chapterWordCount,
      @JsonKey(name: 'respond_time') int respondTime,
      @JsonKey(name: 'origin_order') int originOrder});
}

/// @nodoc
class __$$SourceMatchImplCopyWithImpl<$Res>
    extends _$SourceMatchCopyWithImpl<$Res, _$SourceMatchImpl>
    implements _$$SourceMatchImplCopyWith<$Res> {
  __$$SourceMatchImplCopyWithImpl(
      _$SourceMatchImpl _value, $Res Function(_$SourceMatchImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? sourceUrl = null,
    Object? sourceName = null,
    Object? bookUrl = null,
    Object? bookName = null,
    Object? author = null,
    Object? latestChapter = freezed,
    Object? wordCount = freezed,
    Object? score = null,
    Object? chapterWordCountText = freezed,
    Object? chapterWordCount = null,
    Object? respondTime = null,
    Object? originOrder = null,
  }) {
    return _then(_$SourceMatchImpl(
      sourceUrl: null == sourceUrl
          ? _value.sourceUrl
          : sourceUrl // ignore: cast_nullable_to_non_nullable
              as String,
      sourceName: null == sourceName
          ? _value.sourceName
          : sourceName // ignore: cast_nullable_to_non_nullable
              as String,
      bookUrl: null == bookUrl
          ? _value.bookUrl
          : bookUrl // ignore: cast_nullable_to_non_nullable
              as String,
      bookName: null == bookName
          ? _value.bookName
          : bookName // ignore: cast_nullable_to_non_nullable
              as String,
      author: null == author
          ? _value.author
          : author // ignore: cast_nullable_to_non_nullable
              as String,
      latestChapter: freezed == latestChapter
          ? _value.latestChapter
          : latestChapter // ignore: cast_nullable_to_non_nullable
              as String?,
      wordCount: freezed == wordCount
          ? _value.wordCount
          : wordCount // ignore: cast_nullable_to_non_nullable
              as String?,
      score: null == score
          ? _value.score
          : score // ignore: cast_nullable_to_non_nullable
              as double,
      chapterWordCountText: freezed == chapterWordCountText
          ? _value.chapterWordCountText
          : chapterWordCountText // ignore: cast_nullable_to_non_nullable
              as String?,
      chapterWordCount: null == chapterWordCount
          ? _value.chapterWordCount
          : chapterWordCount // ignore: cast_nullable_to_non_nullable
              as int,
      respondTime: null == respondTime
          ? _value.respondTime
          : respondTime // ignore: cast_nullable_to_non_nullable
              as int,
      originOrder: null == originOrder
          ? _value.originOrder
          : originOrder // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$SourceMatchImpl implements _SourceMatch {
  const _$SourceMatchImpl(
      {@JsonKey(name: 'source_url') this.sourceUrl = '',
      @JsonKey(name: 'source_name') this.sourceName = '',
      @JsonKey(name: 'book_url') this.bookUrl = '',
      @JsonKey(name: 'book_name') this.bookName = '',
      this.author = '',
      @JsonKey(name: 'latest_chapter') this.latestChapter,
      @JsonKey(name: 'word_count') this.wordCount,
      this.score = 0.0,
      @JsonKey(name: 'chapter_word_count_text') this.chapterWordCountText,
      @JsonKey(name: 'chapter_word_count') this.chapterWordCount = -1,
      @JsonKey(name: 'respond_time') this.respondTime = -1,
      @JsonKey(name: 'origin_order') this.originOrder = 0});

  factory _$SourceMatchImpl.fromJson(Map<String, dynamic> json) =>
      _$$SourceMatchImplFromJson(json);

  /// 书源 URL
  @override
  @JsonKey(name: 'source_url')
  final String sourceUrl;

  /// 书源名称
  @override
  @JsonKey(name: 'source_name')
  final String sourceName;

  /// 书籍详情页 URL
  @override
  @JsonKey(name: 'book_url')
  final String bookUrl;

  /// 书籍名称
  @override
  @JsonKey(name: 'book_name')
  final String bookName;

  /// 作者
  @override
  @JsonKey()
  final String author;

  /// 最新章节
  @override
  @JsonKey(name: 'latest_chapter')
  final String? latestChapter;

  /// 字数信息
  @override
  @JsonKey(name: 'word_count')
  final String? wordCount;

  /// 匹配度评分（0.0 ~ 100.0）
  @override
  @JsonKey()
  final double score;

  /// 试读章节字数展示
  @override
  @JsonKey(name: 'chapter_word_count_text')
  final String? chapterWordCountText;

  /// 试读章节字数（-1=未知）
  @override
  @JsonKey(name: 'chapter_word_count')
  final int chapterWordCount;

  /// 取字耗时毫秒
  @override
  @JsonKey(name: 'respond_time')
  final int respondTime;

  /// 书源 customOrder
  @override
  @JsonKey(name: 'origin_order')
  final int originOrder;

  @override
  String toString() {
    return 'SourceMatch(sourceUrl: $sourceUrl, sourceName: $sourceName, bookUrl: $bookUrl, bookName: $bookName, author: $author, latestChapter: $latestChapter, wordCount: $wordCount, score: $score, chapterWordCountText: $chapterWordCountText, chapterWordCount: $chapterWordCount, respondTime: $respondTime, originOrder: $originOrder)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SourceMatchImpl &&
            (identical(other.sourceUrl, sourceUrl) ||
                other.sourceUrl == sourceUrl) &&
            (identical(other.sourceName, sourceName) ||
                other.sourceName == sourceName) &&
            (identical(other.bookUrl, bookUrl) || other.bookUrl == bookUrl) &&
            (identical(other.bookName, bookName) ||
                other.bookName == bookName) &&
            (identical(other.author, author) || other.author == author) &&
            (identical(other.latestChapter, latestChapter) ||
                other.latestChapter == latestChapter) &&
            (identical(other.wordCount, wordCount) ||
                other.wordCount == wordCount) &&
            (identical(other.score, score) || other.score == score) &&
            (identical(other.chapterWordCountText, chapterWordCountText) ||
                other.chapterWordCountText == chapterWordCountText) &&
            (identical(other.chapterWordCount, chapterWordCount) ||
                other.chapterWordCount == chapterWordCount) &&
            (identical(other.respondTime, respondTime) ||
                other.respondTime == respondTime) &&
            (identical(other.originOrder, originOrder) ||
                other.originOrder == originOrder));
  }

  @JsonKey(ignore: true)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      sourceUrl,
      sourceName,
      bookUrl,
      bookName,
      author,
      latestChapter,
      wordCount,
      score,
      chapterWordCountText,
      chapterWordCount,
      respondTime,
      originOrder);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$SourceMatchImplCopyWith<_$SourceMatchImpl> get copyWith =>
      __$$SourceMatchImplCopyWithImpl<_$SourceMatchImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$SourceMatchImplToJson(
      this,
    );
  }
}

abstract class _SourceMatch implements SourceMatch {
  const factory _SourceMatch(
          {@JsonKey(name: 'source_url') final String sourceUrl,
          @JsonKey(name: 'source_name') final String sourceName,
          @JsonKey(name: 'book_url') final String bookUrl,
          @JsonKey(name: 'book_name') final String bookName,
          final String author,
          @JsonKey(name: 'latest_chapter') final String? latestChapter,
          @JsonKey(name: 'word_count') final String? wordCount,
          final double score,
          @JsonKey(name: 'chapter_word_count_text')
          final String? chapterWordCountText,
          @JsonKey(name: 'chapter_word_count') final int chapterWordCount,
          @JsonKey(name: 'respond_time') final int respondTime,
          @JsonKey(name: 'origin_order') final int originOrder}) =
      _$SourceMatchImpl;

  factory _SourceMatch.fromJson(Map<String, dynamic> json) =
      _$SourceMatchImpl.fromJson;

  @override

  /// 书源 URL
  @JsonKey(name: 'source_url')
  String get sourceUrl;
  @override

  /// 书源名称
  @JsonKey(name: 'source_name')
  String get sourceName;
  @override

  /// 书籍详情页 URL
  @JsonKey(name: 'book_url')
  String get bookUrl;
  @override

  /// 书籍名称
  @JsonKey(name: 'book_name')
  String get bookName;
  @override

  /// 作者
  String get author;
  @override

  /// 最新章节
  @JsonKey(name: 'latest_chapter')
  String? get latestChapter;
  @override

  /// 字数信息
  @JsonKey(name: 'word_count')
  String? get wordCount;
  @override

  /// 匹配度评分（0.0 ~ 100.0）
  double get score;
  @override

  /// 试读章节字数展示
  @JsonKey(name: 'chapter_word_count_text')
  String? get chapterWordCountText;
  @override

  /// 试读章节字数（-1=未知）
  @JsonKey(name: 'chapter_word_count')
  int get chapterWordCount;
  @override

  /// 取字耗时毫秒
  @JsonKey(name: 'respond_time')
  int get respondTime;
  @override

  /// 书源 customOrder
  @JsonKey(name: 'origin_order')
  int get originOrder;
  @override
  @JsonKey(ignore: true)
  _$$SourceMatchImplCopyWith<_$SourceMatchImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
