// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'remote_book_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$RemoteBookState {
  /// 正在导入
  bool get isImporting => throw _privateConstructorUsedError;

  /// 最近一次成功导入的数量（null 表示尚未导入）
  int? get importedCount => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $RemoteBookStateCopyWith<RemoteBookState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $RemoteBookStateCopyWith<$Res> {
  factory $RemoteBookStateCopyWith(
          RemoteBookState value, $Res Function(RemoteBookState) then) =
      _$RemoteBookStateCopyWithImpl<$Res, RemoteBookState>;
  @useResult
  $Res call({bool isImporting, int? importedCount, String? error});
}

/// @nodoc
class _$RemoteBookStateCopyWithImpl<$Res, $Val extends RemoteBookState>
    implements $RemoteBookStateCopyWith<$Res> {
  _$RemoteBookStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? isImporting = null,
    Object? importedCount = freezed,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      isImporting: null == isImporting
          ? _value.isImporting
          : isImporting // ignore: cast_nullable_to_non_nullable
              as bool,
      importedCount: freezed == importedCount
          ? _value.importedCount
          : importedCount // ignore: cast_nullable_to_non_nullable
              as int?,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$RemoteBookStateImplCopyWith<$Res>
    implements $RemoteBookStateCopyWith<$Res> {
  factory _$$RemoteBookStateImplCopyWith(_$RemoteBookStateImpl value,
          $Res Function(_$RemoteBookStateImpl) then) =
      __$$RemoteBookStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({bool isImporting, int? importedCount, String? error});
}

/// @nodoc
class __$$RemoteBookStateImplCopyWithImpl<$Res>
    extends _$RemoteBookStateCopyWithImpl<$Res, _$RemoteBookStateImpl>
    implements _$$RemoteBookStateImplCopyWith<$Res> {
  __$$RemoteBookStateImplCopyWithImpl(
      _$RemoteBookStateImpl _value, $Res Function(_$RemoteBookStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? isImporting = null,
    Object? importedCount = freezed,
    Object? error = freezed,
  }) {
    return _then(_$RemoteBookStateImpl(
      isImporting: null == isImporting
          ? _value.isImporting
          : isImporting // ignore: cast_nullable_to_non_nullable
              as bool,
      importedCount: freezed == importedCount
          ? _value.importedCount
          : importedCount // ignore: cast_nullable_to_non_nullable
              as int?,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$RemoteBookStateImpl implements _RemoteBookState {
  const _$RemoteBookStateImpl(
      {this.isImporting = false, this.importedCount, this.error});

  /// 正在导入
  @override
  @JsonKey()
  final bool isImporting;

  /// 最近一次成功导入的数量（null 表示尚未导入）
  @override
  final int? importedCount;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'RemoteBookState(isImporting: $isImporting, importedCount: $importedCount, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$RemoteBookStateImpl &&
            (identical(other.isImporting, isImporting) ||
                other.isImporting == isImporting) &&
            (identical(other.importedCount, importedCount) ||
                other.importedCount == importedCount) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, isImporting, importedCount, error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$RemoteBookStateImplCopyWith<_$RemoteBookStateImpl> get copyWith =>
      __$$RemoteBookStateImplCopyWithImpl<_$RemoteBookStateImpl>(
          this, _$identity);
}

abstract class _RemoteBookState implements RemoteBookState {
  const factory _RemoteBookState(
      {final bool isImporting,
      final int? importedCount,
      final String? error}) = _$RemoteBookStateImpl;

  @override

  /// 正在导入
  bool get isImporting;
  @override

  /// 最近一次成功导入的数量（null 表示尚未导入）
  int? get importedCount;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$RemoteBookStateImplCopyWith<_$RemoteBookStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
