// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'rss_read_record_row.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

RssReadRecordRow _$RssReadRecordRowFromJson(Map<String, dynamic> json) {
  return _RssReadRecordRow.fromJson(json);
}

/// @nodoc
mixin _$RssReadRecordRow {
  /// 来源 URL
  String get origin => throw _privateConstructorUsedError;

  /// 文章标题
  String get title => throw _privateConstructorUsedError;

  /// 文章链接
  String? get link => throw _privateConstructorUsedError;

  /// 阅读时间（Unix 毫秒）
  @JsonKey(name: 'read_time')
  int get readTime => throw _privateConstructorUsedError;

  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;
  @JsonKey(ignore: true)
  $RssReadRecordRowCopyWith<RssReadRecordRow> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $RssReadRecordRowCopyWith<$Res> {
  factory $RssReadRecordRowCopyWith(
          RssReadRecordRow value, $Res Function(RssReadRecordRow) then) =
      _$RssReadRecordRowCopyWithImpl<$Res, RssReadRecordRow>;
  @useResult
  $Res call(
      {String origin,
      String title,
      String? link,
      @JsonKey(name: 'read_time') int readTime});
}

/// @nodoc
class _$RssReadRecordRowCopyWithImpl<$Res, $Val extends RssReadRecordRow>
    implements $RssReadRecordRowCopyWith<$Res> {
  _$RssReadRecordRowCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? origin = null,
    Object? title = null,
    Object? link = freezed,
    Object? readTime = null,
  }) {
    return _then(_value.copyWith(
      origin: null == origin
          ? _value.origin
          : origin // ignore: cast_nullable_to_non_nullable
              as String,
      title: null == title
          ? _value.title
          : title // ignore: cast_nullable_to_non_nullable
              as String,
      link: freezed == link
          ? _value.link
          : link // ignore: cast_nullable_to_non_nullable
              as String?,
      readTime: null == readTime
          ? _value.readTime
          : readTime // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$RssReadRecordRowImplCopyWith<$Res>
    implements $RssReadRecordRowCopyWith<$Res> {
  factory _$$RssReadRecordRowImplCopyWith(_$RssReadRecordRowImpl value,
          $Res Function(_$RssReadRecordRowImpl) then) =
      __$$RssReadRecordRowImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String origin,
      String title,
      String? link,
      @JsonKey(name: 'read_time') int readTime});
}

/// @nodoc
class __$$RssReadRecordRowImplCopyWithImpl<$Res>
    extends _$RssReadRecordRowCopyWithImpl<$Res, _$RssReadRecordRowImpl>
    implements _$$RssReadRecordRowImplCopyWith<$Res> {
  __$$RssReadRecordRowImplCopyWithImpl(_$RssReadRecordRowImpl _value,
      $Res Function(_$RssReadRecordRowImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? origin = null,
    Object? title = null,
    Object? link = freezed,
    Object? readTime = null,
  }) {
    return _then(_$RssReadRecordRowImpl(
      origin: null == origin
          ? _value.origin
          : origin // ignore: cast_nullable_to_non_nullable
              as String,
      title: null == title
          ? _value.title
          : title // ignore: cast_nullable_to_non_nullable
              as String,
      link: freezed == link
          ? _value.link
          : link // ignore: cast_nullable_to_non_nullable
              as String?,
      readTime: null == readTime
          ? _value.readTime
          : readTime // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$RssReadRecordRowImpl implements _RssReadRecordRow {
  const _$RssReadRecordRowImpl(
      {this.origin = '',
      this.title = '',
      this.link,
      @JsonKey(name: 'read_time') this.readTime = 0});

  factory _$RssReadRecordRowImpl.fromJson(Map<String, dynamic> json) =>
      _$$RssReadRecordRowImplFromJson(json);

  /// 来源 URL
  @override
  @JsonKey()
  final String origin;

  /// 文章标题
  @override
  @JsonKey()
  final String title;

  /// 文章链接
  @override
  final String? link;

  /// 阅读时间（Unix 毫秒）
  @override
  @JsonKey(name: 'read_time')
  final int readTime;

  @override
  String toString() {
    return 'RssReadRecordRow(origin: $origin, title: $title, link: $link, readTime: $readTime)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$RssReadRecordRowImpl &&
            (identical(other.origin, origin) || other.origin == origin) &&
            (identical(other.title, title) || other.title == title) &&
            (identical(other.link, link) || other.link == link) &&
            (identical(other.readTime, readTime) ||
                other.readTime == readTime));
  }

  @JsonKey(ignore: true)
  @override
  int get hashCode => Object.hash(runtimeType, origin, title, link, readTime);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$RssReadRecordRowImplCopyWith<_$RssReadRecordRowImpl> get copyWith =>
      __$$RssReadRecordRowImplCopyWithImpl<_$RssReadRecordRowImpl>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$RssReadRecordRowImplToJson(
      this,
    );
  }
}

abstract class _RssReadRecordRow implements RssReadRecordRow {
  const factory _RssReadRecordRow(
      {final String origin,
      final String title,
      final String? link,
      @JsonKey(name: 'read_time') final int readTime}) = _$RssReadRecordRowImpl;

  factory _RssReadRecordRow.fromJson(Map<String, dynamic> json) =
      _$RssReadRecordRowImpl.fromJson;

  @override

  /// 来源 URL
  String get origin;
  @override

  /// 文章标题
  String get title;
  @override

  /// 文章链接
  String? get link;
  @override

  /// 阅读时间（Unix 毫秒）
  @JsonKey(name: 'read_time')
  int get readTime;
  @override
  @JsonKey(ignore: true)
  _$$RssReadRecordRowImplCopyWith<_$RssReadRecordRowImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
