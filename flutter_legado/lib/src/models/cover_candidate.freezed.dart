// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'cover_candidate.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

CoverCandidate _$CoverCandidateFromJson(Map<String, dynamic> json) {
  return _CoverCandidate.fromJson(json);
}

/// @nodoc
mixin _$CoverCandidate {
  /// 封面图片 URL
  String get url => throw _privateConstructorUsedError;

  /// 图片宽度（像素，0 表示未知）
  int get width => throw _privateConstructorUsedError;

  /// 图片高度（像素，0 表示未知）
  int get height => throw _privateConstructorUsedError;

  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;
  @JsonKey(ignore: true)
  $CoverCandidateCopyWith<CoverCandidate> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $CoverCandidateCopyWith<$Res> {
  factory $CoverCandidateCopyWith(
          CoverCandidate value, $Res Function(CoverCandidate) then) =
      _$CoverCandidateCopyWithImpl<$Res, CoverCandidate>;
  @useResult
  $Res call({String url, int width, int height});
}

/// @nodoc
class _$CoverCandidateCopyWithImpl<$Res, $Val extends CoverCandidate>
    implements $CoverCandidateCopyWith<$Res> {
  _$CoverCandidateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? url = null,
    Object? width = null,
    Object? height = null,
  }) {
    return _then(_value.copyWith(
      url: null == url
          ? _value.url
          : url // ignore: cast_nullable_to_non_nullable
              as String,
      width: null == width
          ? _value.width
          : width // ignore: cast_nullable_to_non_nullable
              as int,
      height: null == height
          ? _value.height
          : height // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$CoverCandidateImplCopyWith<$Res>
    implements $CoverCandidateCopyWith<$Res> {
  factory _$$CoverCandidateImplCopyWith(_$CoverCandidateImpl value,
          $Res Function(_$CoverCandidateImpl) then) =
      __$$CoverCandidateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String url, int width, int height});
}

/// @nodoc
class __$$CoverCandidateImplCopyWithImpl<$Res>
    extends _$CoverCandidateCopyWithImpl<$Res, _$CoverCandidateImpl>
    implements _$$CoverCandidateImplCopyWith<$Res> {
  __$$CoverCandidateImplCopyWithImpl(
      _$CoverCandidateImpl _value, $Res Function(_$CoverCandidateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? url = null,
    Object? width = null,
    Object? height = null,
  }) {
    return _then(_$CoverCandidateImpl(
      url: null == url
          ? _value.url
          : url // ignore: cast_nullable_to_non_nullable
              as String,
      width: null == width
          ? _value.width
          : width // ignore: cast_nullable_to_non_nullable
              as int,
      height: null == height
          ? _value.height
          : height // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$CoverCandidateImpl implements _CoverCandidate {
  const _$CoverCandidateImpl({this.url = '', this.width = 0, this.height = 0});

  factory _$CoverCandidateImpl.fromJson(Map<String, dynamic> json) =>
      _$$CoverCandidateImplFromJson(json);

  /// 封面图片 URL
  @override
  @JsonKey()
  final String url;

  /// 图片宽度（像素，0 表示未知）
  @override
  @JsonKey()
  final int width;

  /// 图片高度（像素，0 表示未知）
  @override
  @JsonKey()
  final int height;

  @override
  String toString() {
    return 'CoverCandidate(url: $url, width: $width, height: $height)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$CoverCandidateImpl &&
            (identical(other.url, url) || other.url == url) &&
            (identical(other.width, width) || other.width == width) &&
            (identical(other.height, height) || other.height == height));
  }

  @JsonKey(ignore: true)
  @override
  int get hashCode => Object.hash(runtimeType, url, width, height);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$CoverCandidateImplCopyWith<_$CoverCandidateImpl> get copyWith =>
      __$$CoverCandidateImplCopyWithImpl<_$CoverCandidateImpl>(
          this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$CoverCandidateImplToJson(
      this,
    );
  }
}

abstract class _CoverCandidate implements CoverCandidate {
  const factory _CoverCandidate(
      {final String url,
      final int width,
      final int height}) = _$CoverCandidateImpl;

  factory _CoverCandidate.fromJson(Map<String, dynamic> json) =
      _$CoverCandidateImpl.fromJson;

  @override

  /// 封面图片 URL
  String get url;
  @override

  /// 图片宽度（像素，0 表示未知）
  int get width;
  @override

  /// 图片高度（像素，0 表示未知）
  int get height;
  @override
  @JsonKey(ignore: true)
  _$$CoverCandidateImplCopyWith<_$CoverCandidateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
