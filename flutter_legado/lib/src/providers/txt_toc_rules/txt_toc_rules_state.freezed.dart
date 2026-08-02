// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'txt_toc_rules_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$TxtTocRulesState {
  /// 规则列表（按 serialNumber 语义排序）
  List<TxtTocRule> get rules => throw _privateConstructorUsedError;

  /// 正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $TxtTocRulesStateCopyWith<TxtTocRulesState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $TxtTocRulesStateCopyWith<$Res> {
  factory $TxtTocRulesStateCopyWith(
          TxtTocRulesState value, $Res Function(TxtTocRulesState) then) =
      _$TxtTocRulesStateCopyWithImpl<$Res, TxtTocRulesState>;
  @useResult
  $Res call({List<TxtTocRule> rules, bool isLoading, String? error});
}

/// @nodoc
class _$TxtTocRulesStateCopyWithImpl<$Res, $Val extends TxtTocRulesState>
    implements $TxtTocRulesStateCopyWith<$Res> {
  _$TxtTocRulesStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? rules = null,
    Object? isLoading = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      rules: null == rules
          ? _value.rules
          : rules // ignore: cast_nullable_to_non_nullable
              as List<TxtTocRule>,
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
}

/// @nodoc
abstract class _$$TxtTocRulesStateImplCopyWith<$Res>
    implements $TxtTocRulesStateCopyWith<$Res> {
  factory _$$TxtTocRulesStateImplCopyWith(_$TxtTocRulesStateImpl value,
          $Res Function(_$TxtTocRulesStateImpl) then) =
      __$$TxtTocRulesStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<TxtTocRule> rules, bool isLoading, String? error});
}

/// @nodoc
class __$$TxtTocRulesStateImplCopyWithImpl<$Res>
    extends _$TxtTocRulesStateCopyWithImpl<$Res, _$TxtTocRulesStateImpl>
    implements _$$TxtTocRulesStateImplCopyWith<$Res> {
  __$$TxtTocRulesStateImplCopyWithImpl(_$TxtTocRulesStateImpl _value,
      $Res Function(_$TxtTocRulesStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? rules = null,
    Object? isLoading = null,
    Object? error = freezed,
  }) {
    return _then(_$TxtTocRulesStateImpl(
      rules: null == rules
          ? _value._rules
          : rules // ignore: cast_nullable_to_non_nullable
              as List<TxtTocRule>,
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

class _$TxtTocRulesStateImpl implements _TxtTocRulesState {
  const _$TxtTocRulesStateImpl(
      {final List<TxtTocRule> rules = const [],
      this.isLoading = false,
      this.error})
      : _rules = rules;

  /// 规则列表（按 serialNumber 语义排序）
  final List<TxtTocRule> _rules;

  /// 规则列表（按 serialNumber 语义排序）
  @override
  @JsonKey()
  List<TxtTocRule> get rules {
    if (_rules is EqualUnmodifiableListView) return _rules;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_rules);
  }

  /// 正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'TxtTocRulesState(rules: $rules, isLoading: $isLoading, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$TxtTocRulesStateImpl &&
            const DeepCollectionEquality().equals(other._rules, _rules) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(runtimeType,
      const DeepCollectionEquality().hash(_rules), isLoading, error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$TxtTocRulesStateImplCopyWith<_$TxtTocRulesStateImpl> get copyWith =>
      __$$TxtTocRulesStateImplCopyWithImpl<_$TxtTocRulesStateImpl>(
          this, _$identity);
}

abstract class _TxtTocRulesState implements TxtTocRulesState {
  const factory _TxtTocRulesState(
      {final List<TxtTocRule> rules,
      final bool isLoading,
      final String? error}) = _$TxtTocRulesStateImpl;

  @override

  /// 规则列表（按 serialNumber 语义排序）
  List<TxtTocRule> get rules;
  @override

  /// 正在加载
  bool get isLoading;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$TxtTocRulesStateImplCopyWith<_$TxtTocRulesStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
