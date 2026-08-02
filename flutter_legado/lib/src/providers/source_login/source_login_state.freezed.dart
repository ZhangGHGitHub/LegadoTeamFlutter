// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'source_login_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$SourceLoginState {
  /// Bearer Token / API Key（可选）
  String get token => throw _privateConstructorUsedError;

  /// Cookie 键值对列表
  List<LoginKeyValue> get cookies => throw _privateConstructorUsedError;

  /// Header 键值对列表
  List<LoginKeyValue> get headers => throw _privateConstructorUsedError;

  /// 正在加载已保存的登录信息
  bool get isLoading => throw _privateConstructorUsedError;

  /// 正在保存
  bool get isSaving => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $SourceLoginStateCopyWith<SourceLoginState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SourceLoginStateCopyWith<$Res> {
  factory $SourceLoginStateCopyWith(
          SourceLoginState value, $Res Function(SourceLoginState) then) =
      _$SourceLoginStateCopyWithImpl<$Res, SourceLoginState>;
  @useResult
  $Res call(
      {String token,
      List<LoginKeyValue> cookies,
      List<LoginKeyValue> headers,
      bool isLoading,
      bool isSaving,
      String? error});
}

/// @nodoc
class _$SourceLoginStateCopyWithImpl<$Res, $Val extends SourceLoginState>
    implements $SourceLoginStateCopyWith<$Res> {
  _$SourceLoginStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? token = null,
    Object? cookies = null,
    Object? headers = null,
    Object? isLoading = null,
    Object? isSaving = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      token: null == token
          ? _value.token
          : token // ignore: cast_nullable_to_non_nullable
              as String,
      cookies: null == cookies
          ? _value.cookies
          : cookies // ignore: cast_nullable_to_non_nullable
              as List<LoginKeyValue>,
      headers: null == headers
          ? _value.headers
          : headers // ignore: cast_nullable_to_non_nullable
              as List<LoginKeyValue>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      isSaving: null == isSaving
          ? _value.isSaving
          : isSaving // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SourceLoginStateImplCopyWith<$Res>
    implements $SourceLoginStateCopyWith<$Res> {
  factory _$$SourceLoginStateImplCopyWith(_$SourceLoginStateImpl value,
          $Res Function(_$SourceLoginStateImpl) then) =
      __$$SourceLoginStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String token,
      List<LoginKeyValue> cookies,
      List<LoginKeyValue> headers,
      bool isLoading,
      bool isSaving,
      String? error});
}

/// @nodoc
class __$$SourceLoginStateImplCopyWithImpl<$Res>
    extends _$SourceLoginStateCopyWithImpl<$Res, _$SourceLoginStateImpl>
    implements _$$SourceLoginStateImplCopyWith<$Res> {
  __$$SourceLoginStateImplCopyWithImpl(_$SourceLoginStateImpl _value,
      $Res Function(_$SourceLoginStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? token = null,
    Object? cookies = null,
    Object? headers = null,
    Object? isLoading = null,
    Object? isSaving = null,
    Object? error = freezed,
  }) {
    return _then(_$SourceLoginStateImpl(
      token: null == token
          ? _value.token
          : token // ignore: cast_nullable_to_non_nullable
              as String,
      cookies: null == cookies
          ? _value._cookies
          : cookies // ignore: cast_nullable_to_non_nullable
              as List<LoginKeyValue>,
      headers: null == headers
          ? _value._headers
          : headers // ignore: cast_nullable_to_non_nullable
              as List<LoginKeyValue>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      isSaving: null == isSaving
          ? _value.isSaving
          : isSaving // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$SourceLoginStateImpl implements _SourceLoginState {
  const _$SourceLoginStateImpl(
      {this.token = '',
      final List<LoginKeyValue> cookies = const [],
      final List<LoginKeyValue> headers = const [],
      this.isLoading = false,
      this.isSaving = false,
      this.error})
      : _cookies = cookies,
        _headers = headers;

  /// Bearer Token / API Key（可选）
  @override
  @JsonKey()
  final String token;

  /// Cookie 键值对列表
  final List<LoginKeyValue> _cookies;

  /// Cookie 键值对列表
  @override
  @JsonKey()
  List<LoginKeyValue> get cookies {
    if (_cookies is EqualUnmodifiableListView) return _cookies;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_cookies);
  }

  /// Header 键值对列表
  final List<LoginKeyValue> _headers;

  /// Header 键值对列表
  @override
  @JsonKey()
  List<LoginKeyValue> get headers {
    if (_headers is EqualUnmodifiableListView) return _headers;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_headers);
  }

  /// 正在加载已保存的登录信息
  @override
  @JsonKey()
  final bool isLoading;

  /// 正在保存
  @override
  @JsonKey()
  final bool isSaving;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'SourceLoginState(token: $token, cookies: $cookies, headers: $headers, isLoading: $isLoading, isSaving: $isSaving, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SourceLoginStateImpl &&
            (identical(other.token, token) || other.token == token) &&
            const DeepCollectionEquality().equals(other._cookies, _cookies) &&
            const DeepCollectionEquality().equals(other._headers, _headers) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.isSaving, isSaving) ||
                other.isSaving == isSaving) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      token,
      const DeepCollectionEquality().hash(_cookies),
      const DeepCollectionEquality().hash(_headers),
      isLoading,
      isSaving,
      error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$SourceLoginStateImplCopyWith<_$SourceLoginStateImpl> get copyWith =>
      __$$SourceLoginStateImplCopyWithImpl<_$SourceLoginStateImpl>(
          this, _$identity);
}

abstract class _SourceLoginState implements SourceLoginState {
  const factory _SourceLoginState(
      {final String token,
      final List<LoginKeyValue> cookies,
      final List<LoginKeyValue> headers,
      final bool isLoading,
      final bool isSaving,
      final String? error}) = _$SourceLoginStateImpl;

  @override

  /// Bearer Token / API Key（可选）
  String get token;
  @override

  /// Cookie 键值对列表
  List<LoginKeyValue> get cookies;
  @override

  /// Header 键值对列表
  List<LoginKeyValue> get headers;
  @override

  /// 正在加载已保存的登录信息
  bool get isLoading;
  @override

  /// 正在保存
  bool get isSaving;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$SourceLoginStateImplCopyWith<_$SourceLoginStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
