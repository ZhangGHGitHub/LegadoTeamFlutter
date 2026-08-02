// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'dict_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$DictState {
  /// 在线词典规则列表
  List<DictRule> get rules => throw _privateConstructorUsedError;

  /// 当前查询的单词（null 表示尚未查询）
  String? get queriedWord => throw _privateConstructorUsedError;

  /// 本地词典命中结果（null 表示未查询或未收录）
  DictEntry? get result => throw _privateConstructorUsedError;

  /// 正在加载规则
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $DictStateCopyWith<DictState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $DictStateCopyWith<$Res> {
  factory $DictStateCopyWith(DictState value, $Res Function(DictState) then) =
      _$DictStateCopyWithImpl<$Res, DictState>;
  @useResult
  $Res call(
      {List<DictRule> rules,
      String? queriedWord,
      DictEntry? result,
      bool isLoading,
      String? error});

  $DictEntryCopyWith<$Res>? get result;
}

/// @nodoc
class _$DictStateCopyWithImpl<$Res, $Val extends DictState>
    implements $DictStateCopyWith<$Res> {
  _$DictStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? rules = null,
    Object? queriedWord = freezed,
    Object? result = freezed,
    Object? isLoading = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      rules: null == rules
          ? _value.rules
          : rules // ignore: cast_nullable_to_non_nullable
              as List<DictRule>,
      queriedWord: freezed == queriedWord
          ? _value.queriedWord
          : queriedWord // ignore: cast_nullable_to_non_nullable
              as String?,
      result: freezed == result
          ? _value.result
          : result // ignore: cast_nullable_to_non_nullable
              as DictEntry?,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }

  @override
  @pragma('vm:prefer-inline')
  $DictEntryCopyWith<$Res>? get result {
    if (_value.result == null) {
      return null;
    }

    return $DictEntryCopyWith<$Res>(_value.result!, (value) {
      return _then(_value.copyWith(result: value) as $Val);
    });
  }
}

/// @nodoc
abstract class _$$DictStateImplCopyWith<$Res>
    implements $DictStateCopyWith<$Res> {
  factory _$$DictStateImplCopyWith(
          _$DictStateImpl value, $Res Function(_$DictStateImpl) then) =
      __$$DictStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<DictRule> rules,
      String? queriedWord,
      DictEntry? result,
      bool isLoading,
      String? error});

  @override
  $DictEntryCopyWith<$Res>? get result;
}

/// @nodoc
class __$$DictStateImplCopyWithImpl<$Res>
    extends _$DictStateCopyWithImpl<$Res, _$DictStateImpl>
    implements _$$DictStateImplCopyWith<$Res> {
  __$$DictStateImplCopyWithImpl(
      _$DictStateImpl _value, $Res Function(_$DictStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? rules = null,
    Object? queriedWord = freezed,
    Object? result = freezed,
    Object? isLoading = null,
    Object? error = freezed,
  }) {
    return _then(_$DictStateImpl(
      rules: null == rules
          ? _value._rules
          : rules // ignore: cast_nullable_to_non_nullable
              as List<DictRule>,
      queriedWord: freezed == queriedWord
          ? _value.queriedWord
          : queriedWord // ignore: cast_nullable_to_non_nullable
              as String?,
      result: freezed == result
          ? _value.result
          : result // ignore: cast_nullable_to_non_nullable
              as DictEntry?,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$DictStateImpl implements _DictState {
  const _$DictStateImpl(
      {final List<DictRule> rules = const [],
      this.queriedWord,
      this.result,
      this.isLoading = false,
      this.error})
      : _rules = rules;

  /// 在线词典规则列表
  final List<DictRule> _rules;

  /// 在线词典规则列表
  @override
  @JsonKey()
  List<DictRule> get rules {
    if (_rules is EqualUnmodifiableListView) return _rules;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_rules);
  }

  /// 当前查询的单词（null 表示尚未查询）
  @override
  final String? queriedWord;

  /// 本地词典命中结果（null 表示未查询或未收录）
  @override
  final DictEntry? result;

  /// 正在加载规则
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'DictState(rules: $rules, queriedWord: $queriedWord, result: $result, isLoading: $isLoading, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$DictStateImpl &&
            const DeepCollectionEquality().equals(other._rules, _rules) &&
            (identical(other.queriedWord, queriedWord) ||
                other.queriedWord == queriedWord) &&
            (identical(other.result, result) || other.result == result) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_rules),
      queriedWord,
      result,
      isLoading,
      error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$DictStateImplCopyWith<_$DictStateImpl> get copyWith =>
      __$$DictStateImplCopyWithImpl<_$DictStateImpl>(this, _$identity);
}

abstract class _DictState implements DictState {
  const factory _DictState(
      {final List<DictRule> rules,
      final String? queriedWord,
      final DictEntry? result,
      final bool isLoading,
      final String? error}) = _$DictStateImpl;

  @override

  /// 在线词典规则列表
  List<DictRule> get rules;
  @override

  /// 当前查询的单词（null 表示尚未查询）
  String? get queriedWord;
  @override

  /// 本地词典命中结果（null 表示未查询或未收录）
  DictEntry? get result;
  @override

  /// 正在加载规则
  bool get isLoading;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$DictStateImplCopyWith<_$DictStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
