// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'association_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$AssociationState {
  /// 导入类型（由内容自动识别或深度链接指定）
  ImportType get type => throw _privateConstructorUsedError;

  /// 内容地址输入
  String get urlInput => throw _privateConstructorUsedError;

  /// 正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误消息（null = 无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 解析出的导入条目
  List<AssociationItem> get items => throw _privateConstructorUsedError;

  /// 最近一次导入结果
  ImportResult? get lastResult => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $AssociationStateCopyWith<AssociationState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $AssociationStateCopyWith<$Res> {
  factory $AssociationStateCopyWith(
          AssociationState value, $Res Function(AssociationState) then) =
      _$AssociationStateCopyWithImpl<$Res, AssociationState>;
  @useResult
  $Res call(
      {ImportType type,
      String urlInput,
      bool isLoading,
      String? error,
      List<AssociationItem> items,
      ImportResult? lastResult});
}

/// @nodoc
class _$AssociationStateCopyWithImpl<$Res, $Val extends AssociationState>
    implements $AssociationStateCopyWith<$Res> {
  _$AssociationStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? type = null,
    Object? urlInput = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? items = null,
    Object? lastResult = freezed,
  }) {
    return _then(_value.copyWith(
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as ImportType,
      urlInput: null == urlInput
          ? _value.urlInput
          : urlInput // ignore: cast_nullable_to_non_nullable
              as String,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      items: null == items
          ? _value.items
          : items // ignore: cast_nullable_to_non_nullable
              as List<AssociationItem>,
      lastResult: freezed == lastResult
          ? _value.lastResult
          : lastResult // ignore: cast_nullable_to_non_nullable
              as ImportResult?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$AssociationStateImplCopyWith<$Res>
    implements $AssociationStateCopyWith<$Res> {
  factory _$$AssociationStateImplCopyWith(_$AssociationStateImpl value,
          $Res Function(_$AssociationStateImpl) then) =
      __$$AssociationStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {ImportType type,
      String urlInput,
      bool isLoading,
      String? error,
      List<AssociationItem> items,
      ImportResult? lastResult});
}

/// @nodoc
class __$$AssociationStateImplCopyWithImpl<$Res>
    extends _$AssociationStateCopyWithImpl<$Res, _$AssociationStateImpl>
    implements _$$AssociationStateImplCopyWith<$Res> {
  __$$AssociationStateImplCopyWithImpl(_$AssociationStateImpl _value,
      $Res Function(_$AssociationStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? type = null,
    Object? urlInput = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? items = null,
    Object? lastResult = freezed,
  }) {
    return _then(_$AssociationStateImpl(
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as ImportType,
      urlInput: null == urlInput
          ? _value.urlInput
          : urlInput // ignore: cast_nullable_to_non_nullable
              as String,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      items: null == items
          ? _value._items
          : items // ignore: cast_nullable_to_non_nullable
              as List<AssociationItem>,
      lastResult: freezed == lastResult
          ? _value.lastResult
          : lastResult // ignore: cast_nullable_to_non_nullable
              as ImportResult?,
    ));
  }
}

/// @nodoc

class _$AssociationStateImpl implements _AssociationState {
  const _$AssociationStateImpl(
      {this.type = ImportType.bookSource,
      this.urlInput = '',
      this.isLoading = false,
      this.error,
      final List<AssociationItem> items = const [],
      this.lastResult})
      : _items = items;

  /// 导入类型（由内容自动识别或深度链接指定）
  @override
  @JsonKey()
  final ImportType type;

  /// 内容地址输入
  @override
  @JsonKey()
  final String urlInput;

  /// 正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误消息（null = 无错误）
  @override
  final String? error;

  /// 解析出的导入条目
  final List<AssociationItem> _items;

  /// 解析出的导入条目
  @override
  @JsonKey()
  List<AssociationItem> get items {
    if (_items is EqualUnmodifiableListView) return _items;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_items);
  }

  /// 最近一次导入结果
  @override
  final ImportResult? lastResult;

  @override
  String toString() {
    return 'AssociationState(type: $type, urlInput: $urlInput, isLoading: $isLoading, error: $error, items: $items, lastResult: $lastResult)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AssociationStateImpl &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.urlInput, urlInput) ||
                other.urlInput == urlInput) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error) &&
            const DeepCollectionEquality().equals(other._items, _items) &&
            (identical(other.lastResult, lastResult) ||
                other.lastResult == lastResult));
  }

  @override
  int get hashCode => Object.hash(runtimeType, type, urlInput, isLoading, error,
      const DeepCollectionEquality().hash(_items), lastResult);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$AssociationStateImplCopyWith<_$AssociationStateImpl> get copyWith =>
      __$$AssociationStateImplCopyWithImpl<_$AssociationStateImpl>(
          this, _$identity);
}

abstract class _AssociationState implements AssociationState {
  const factory _AssociationState(
      {final ImportType type,
      final String urlInput,
      final bool isLoading,
      final String? error,
      final List<AssociationItem> items,
      final ImportResult? lastResult}) = _$AssociationStateImpl;

  @override

  /// 导入类型（由内容自动识别或深度链接指定）
  ImportType get type;
  @override

  /// 内容地址输入
  String get urlInput;
  @override

  /// 正在加载
  bool get isLoading;
  @override

  /// 错误消息（null = 无错误）
  String? get error;
  @override

  /// 解析出的导入条目
  List<AssociationItem> get items;
  @override

  /// 最近一次导入结果
  ImportResult? get lastResult;
  @override
  @JsonKey(ignore: true)
  _$$AssociationStateImplCopyWith<_$AssociationStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
