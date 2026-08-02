// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'change_cover_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ChangeCoverState {
  /// 网络封面候选列表
  List<CoverCandidate> get candidates => throw _privateConstructorUsedError;

  /// 正在搜索封面
  bool get isSearching => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ChangeCoverStateCopyWith<ChangeCoverState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ChangeCoverStateCopyWith<$Res> {
  factory $ChangeCoverStateCopyWith(
          ChangeCoverState value, $Res Function(ChangeCoverState) then) =
      _$ChangeCoverStateCopyWithImpl<$Res, ChangeCoverState>;
  @useResult
  $Res call({List<CoverCandidate> candidates, bool isSearching, String? error});
}

/// @nodoc
class _$ChangeCoverStateCopyWithImpl<$Res, $Val extends ChangeCoverState>
    implements $ChangeCoverStateCopyWith<$Res> {
  _$ChangeCoverStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? candidates = null,
    Object? isSearching = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      candidates: null == candidates
          ? _value.candidates
          : candidates // ignore: cast_nullable_to_non_nullable
              as List<CoverCandidate>,
      isSearching: null == isSearching
          ? _value.isSearching
          : isSearching // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ChangeCoverStateImplCopyWith<$Res>
    implements $ChangeCoverStateCopyWith<$Res> {
  factory _$$ChangeCoverStateImplCopyWith(_$ChangeCoverStateImpl value,
          $Res Function(_$ChangeCoverStateImpl) then) =
      __$$ChangeCoverStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<CoverCandidate> candidates, bool isSearching, String? error});
}

/// @nodoc
class __$$ChangeCoverStateImplCopyWithImpl<$Res>
    extends _$ChangeCoverStateCopyWithImpl<$Res, _$ChangeCoverStateImpl>
    implements _$$ChangeCoverStateImplCopyWith<$Res> {
  __$$ChangeCoverStateImplCopyWithImpl(_$ChangeCoverStateImpl _value,
      $Res Function(_$ChangeCoverStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? candidates = null,
    Object? isSearching = null,
    Object? error = freezed,
  }) {
    return _then(_$ChangeCoverStateImpl(
      candidates: null == candidates
          ? _value._candidates
          : candidates // ignore: cast_nullable_to_non_nullable
              as List<CoverCandidate>,
      isSearching: null == isSearching
          ? _value.isSearching
          : isSearching // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$ChangeCoverStateImpl implements _ChangeCoverState {
  const _$ChangeCoverStateImpl(
      {final List<CoverCandidate> candidates = const [],
      this.isSearching = false,
      this.error})
      : _candidates = candidates;

  /// 网络封面候选列表
  final List<CoverCandidate> _candidates;

  /// 网络封面候选列表
  @override
  @JsonKey()
  List<CoverCandidate> get candidates {
    if (_candidates is EqualUnmodifiableListView) return _candidates;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_candidates);
  }

  /// 正在搜索封面
  @override
  @JsonKey()
  final bool isSearching;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'ChangeCoverState(candidates: $candidates, isSearching: $isSearching, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ChangeCoverStateImpl &&
            const DeepCollectionEquality()
                .equals(other._candidates, _candidates) &&
            (identical(other.isSearching, isSearching) ||
                other.isSearching == isSearching) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(runtimeType,
      const DeepCollectionEquality().hash(_candidates), isSearching, error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ChangeCoverStateImplCopyWith<_$ChangeCoverStateImpl> get copyWith =>
      __$$ChangeCoverStateImplCopyWithImpl<_$ChangeCoverStateImpl>(
          this, _$identity);
}

abstract class _ChangeCoverState implements ChangeCoverState {
  const factory _ChangeCoverState(
      {final List<CoverCandidate> candidates,
      final bool isSearching,
      final String? error}) = _$ChangeCoverStateImpl;

  @override

  /// 网络封面候选列表
  List<CoverCandidate> get candidates;
  @override

  /// 正在搜索封面
  bool get isSearching;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$ChangeCoverStateImplCopyWith<_$ChangeCoverStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
