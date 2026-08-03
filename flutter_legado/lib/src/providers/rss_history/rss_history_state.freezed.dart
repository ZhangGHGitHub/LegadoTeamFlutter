// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'rss_history_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$RssHistoryState {
  /// 已读记录列表（按阅读时间降序）
  List<RssReadRecordRow> get records => throw _privateConstructorUsedError;

  /// 正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 正在清空
  bool get isClearing => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $RssHistoryStateCopyWith<RssHistoryState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $RssHistoryStateCopyWith<$Res> {
  factory $RssHistoryStateCopyWith(
          RssHistoryState value, $Res Function(RssHistoryState) then) =
      _$RssHistoryStateCopyWithImpl<$Res, RssHistoryState>;
  @useResult
  $Res call(
      {List<RssReadRecordRow> records,
      bool isLoading,
      bool isClearing,
      String? error});
}

/// @nodoc
class _$RssHistoryStateCopyWithImpl<$Res, $Val extends RssHistoryState>
    implements $RssHistoryStateCopyWith<$Res> {
  _$RssHistoryStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? records = null,
    Object? isLoading = null,
    Object? isClearing = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      records: null == records
          ? _value.records
          : records // ignore: cast_nullable_to_non_nullable
              as List<RssReadRecordRow>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      isClearing: null == isClearing
          ? _value.isClearing
          : isClearing // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$RssHistoryStateImplCopyWith<$Res>
    implements $RssHistoryStateCopyWith<$Res> {
  factory _$$RssHistoryStateImplCopyWith(_$RssHistoryStateImpl value,
          $Res Function(_$RssHistoryStateImpl) then) =
      __$$RssHistoryStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<RssReadRecordRow> records,
      bool isLoading,
      bool isClearing,
      String? error});
}

/// @nodoc
class __$$RssHistoryStateImplCopyWithImpl<$Res>
    extends _$RssHistoryStateCopyWithImpl<$Res, _$RssHistoryStateImpl>
    implements _$$RssHistoryStateImplCopyWith<$Res> {
  __$$RssHistoryStateImplCopyWithImpl(
      _$RssHistoryStateImpl _value, $Res Function(_$RssHistoryStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? records = null,
    Object? isLoading = null,
    Object? isClearing = null,
    Object? error = freezed,
  }) {
    return _then(_$RssHistoryStateImpl(
      records: null == records
          ? _value._records
          : records // ignore: cast_nullable_to_non_nullable
              as List<RssReadRecordRow>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      isClearing: null == isClearing
          ? _value.isClearing
          : isClearing // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$RssHistoryStateImpl implements _RssHistoryState {
  const _$RssHistoryStateImpl(
      {final List<RssReadRecordRow> records = const [],
      this.isLoading = false,
      this.isClearing = false,
      this.error})
      : _records = records;

  /// 已读记录列表（按阅读时间降序）
  final List<RssReadRecordRow> _records;

  /// 已读记录列表（按阅读时间降序）
  @override
  @JsonKey()
  List<RssReadRecordRow> get records {
    if (_records is EqualUnmodifiableListView) return _records;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_records);
  }

  /// 正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 正在清空
  @override
  @JsonKey()
  final bool isClearing;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'RssHistoryState(records: $records, isLoading: $isLoading, isClearing: $isClearing, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$RssHistoryStateImpl &&
            const DeepCollectionEquality().equals(other._records, _records) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.isClearing, isClearing) ||
                other.isClearing == isClearing) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_records),
      isLoading,
      isClearing,
      error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$RssHistoryStateImplCopyWith<_$RssHistoryStateImpl> get copyWith =>
      __$$RssHistoryStateImplCopyWithImpl<_$RssHistoryStateImpl>(
          this, _$identity);
}

abstract class _RssHistoryState implements RssHistoryState {
  const factory _RssHistoryState(
      {final List<RssReadRecordRow> records,
      final bool isLoading,
      final bool isClearing,
      final String? error}) = _$RssHistoryStateImpl;

  @override

  /// 已读记录列表（按阅读时间降序）
  List<RssReadRecordRow> get records;
  @override

  /// 正在加载
  bool get isLoading;
  @override

  /// 正在清空
  bool get isClearing;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$RssHistoryStateImplCopyWith<_$RssHistoryStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
