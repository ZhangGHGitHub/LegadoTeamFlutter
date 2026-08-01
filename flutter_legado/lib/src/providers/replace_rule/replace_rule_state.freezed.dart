// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'replace_rule_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ReplaceRuleState {
  /// 替换规则列表
  List<ReplaceRule> get rules => throw _privateConstructorUsedError;

  /// 是否正在加载规则列表
  bool get loading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ReplaceRuleStateCopyWith<ReplaceRuleState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ReplaceRuleStateCopyWith<$Res> {
  factory $ReplaceRuleStateCopyWith(
          ReplaceRuleState value, $Res Function(ReplaceRuleState) then) =
      _$ReplaceRuleStateCopyWithImpl<$Res, ReplaceRuleState>;
  @useResult
  $Res call({List<ReplaceRule> rules, bool loading, String? error});
}

/// @nodoc
class _$ReplaceRuleStateCopyWithImpl<$Res, $Val extends ReplaceRuleState>
    implements $ReplaceRuleStateCopyWith<$Res> {
  _$ReplaceRuleStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? rules = null,
    Object? loading = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      rules: null == rules
          ? _value.rules
          : rules // ignore: cast_nullable_to_non_nullable
              as List<ReplaceRule>,
      loading: null == loading
          ? _value.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ReplaceRuleStateImplCopyWith<$Res>
    implements $ReplaceRuleStateCopyWith<$Res> {
  factory _$$ReplaceRuleStateImplCopyWith(_$ReplaceRuleStateImpl value,
          $Res Function(_$ReplaceRuleStateImpl) then) =
      __$$ReplaceRuleStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<ReplaceRule> rules, bool loading, String? error});
}

/// @nodoc
class __$$ReplaceRuleStateImplCopyWithImpl<$Res>
    extends _$ReplaceRuleStateCopyWithImpl<$Res, _$ReplaceRuleStateImpl>
    implements _$$ReplaceRuleStateImplCopyWith<$Res> {
  __$$ReplaceRuleStateImplCopyWithImpl(_$ReplaceRuleStateImpl _value,
      $Res Function(_$ReplaceRuleStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? rules = null,
    Object? loading = null,
    Object? error = freezed,
  }) {
    return _then(_$ReplaceRuleStateImpl(
      rules: null == rules
          ? _value._rules
          : rules // ignore: cast_nullable_to_non_nullable
              as List<ReplaceRule>,
      loading: null == loading
          ? _value.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$ReplaceRuleStateImpl implements _ReplaceRuleState {
  const _$ReplaceRuleStateImpl(
      {final List<ReplaceRule> rules = const [],
      this.loading = false,
      this.error})
      : _rules = rules;

  /// 替换规则列表
  final List<ReplaceRule> _rules;

  /// 替换规则列表
  @override
  @JsonKey()
  List<ReplaceRule> get rules {
    if (_rules is EqualUnmodifiableListView) return _rules;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_rules);
  }

  /// 是否正在加载规则列表
  @override
  @JsonKey()
  final bool loading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  @override
  String toString() {
    return 'ReplaceRuleState(rules: $rules, loading: $loading, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ReplaceRuleStateImpl &&
            const DeepCollectionEquality().equals(other._rules, _rules) &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType, const DeepCollectionEquality().hash(_rules), loading, error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ReplaceRuleStateImplCopyWith<_$ReplaceRuleStateImpl> get copyWith =>
      __$$ReplaceRuleStateImplCopyWithImpl<_$ReplaceRuleStateImpl>(
          this, _$identity);
}

abstract class _ReplaceRuleState implements ReplaceRuleState {
  const factory _ReplaceRuleState(
      {final List<ReplaceRule> rules,
      final bool loading,
      final String? error}) = _$ReplaceRuleStateImpl;

  @override

  /// 替换规则列表
  List<ReplaceRule> get rules;
  @override

  /// 是否正在加载规则列表
  bool get loading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$ReplaceRuleStateImplCopyWith<_$ReplaceRuleStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
