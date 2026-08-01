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
  /// 导入类型
  ImportType get type => throw _privateConstructorUsedError;

  /// 导入来源方式
  ImportSource get source => throw _privateConstructorUsedError;

  /// 当前导入步骤
  ImportStep get step => throw _privateConstructorUsedError;

  /// 预览项列表
  List<dynamic> get previewItems => throw _privateConstructorUsedError;

  /// 是否正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 最近一次导入结果
  ImportResult? get lastResult => throw _privateConstructorUsedError;

  /// URL 输入内容
  String get urlInput => throw _privateConstructorUsedError;

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
      ImportSource source,
      ImportStep step,
      List<dynamic> previewItems,
      bool isLoading,
      String? error,
      ImportResult? lastResult,
      String urlInput});
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
    Object? source = null,
    Object? step = null,
    Object? previewItems = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? lastResult = freezed,
    Object? urlInput = null,
  }) {
    return _then(_value.copyWith(
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as ImportType,
      source: null == source
          ? _value.source
          : source // ignore: cast_nullable_to_non_nullable
              as ImportSource,
      step: null == step
          ? _value.step
          : step // ignore: cast_nullable_to_non_nullable
              as ImportStep,
      previewItems: null == previewItems
          ? _value.previewItems
          : previewItems // ignore: cast_nullable_to_non_nullable
              as List<dynamic>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      lastResult: freezed == lastResult
          ? _value.lastResult
          : lastResult // ignore: cast_nullable_to_non_nullable
              as ImportResult?,
      urlInput: null == urlInput
          ? _value.urlInput
          : urlInput // ignore: cast_nullable_to_non_nullable
              as String,
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
      ImportSource source,
      ImportStep step,
      List<dynamic> previewItems,
      bool isLoading,
      String? error,
      ImportResult? lastResult,
      String urlInput});
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
    Object? source = null,
    Object? step = null,
    Object? previewItems = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? lastResult = freezed,
    Object? urlInput = null,
  }) {
    return _then(_$AssociationStateImpl(
      type: null == type
          ? _value.type
          : type // ignore: cast_nullable_to_non_nullable
              as ImportType,
      source: null == source
          ? _value.source
          : source // ignore: cast_nullable_to_non_nullable
              as ImportSource,
      step: null == step
          ? _value.step
          : step // ignore: cast_nullable_to_non_nullable
              as ImportStep,
      previewItems: null == previewItems
          ? _value._previewItems
          : previewItems // ignore: cast_nullable_to_non_nullable
              as List<dynamic>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      lastResult: freezed == lastResult
          ? _value.lastResult
          : lastResult // ignore: cast_nullable_to_non_nullable
              as ImportResult?,
      urlInput: null == urlInput
          ? _value.urlInput
          : urlInput // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$AssociationStateImpl implements _AssociationState {
  const _$AssociationStateImpl(
      {this.type = ImportType.bookSource,
      this.source = ImportSource.url,
      this.step = ImportStep.selectType,
      final List<dynamic> previewItems = const [],
      this.isLoading = false,
      this.error,
      this.lastResult,
      this.urlInput = ''})
      : _previewItems = previewItems;

  /// 导入类型
  @override
  @JsonKey()
  final ImportType type;

  /// 导入来源方式
  @override
  @JsonKey()
  final ImportSource source;

  /// 当前导入步骤
  @override
  @JsonKey()
  final ImportStep step;

  /// 预览项列表
  final List<dynamic> _previewItems;

  /// 预览项列表
  @override
  @JsonKey()
  List<dynamic> get previewItems {
    if (_previewItems is EqualUnmodifiableListView) return _previewItems;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_previewItems);
  }

  /// 是否正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  /// 最近一次导入结果
  @override
  final ImportResult? lastResult;

  /// URL 输入内容
  @override
  @JsonKey()
  final String urlInput;

  @override
  String toString() {
    return 'AssociationState(type: $type, source: $source, step: $step, previewItems: $previewItems, isLoading: $isLoading, error: $error, lastResult: $lastResult, urlInput: $urlInput)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AssociationStateImpl &&
            (identical(other.type, type) || other.type == type) &&
            (identical(other.source, source) || other.source == source) &&
            (identical(other.step, step) || other.step == step) &&
            const DeepCollectionEquality()
                .equals(other._previewItems, _previewItems) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.lastResult, lastResult) ||
                other.lastResult == lastResult) &&
            (identical(other.urlInput, urlInput) ||
                other.urlInput == urlInput));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      type,
      source,
      step,
      const DeepCollectionEquality().hash(_previewItems),
      isLoading,
      error,
      lastResult,
      urlInput);

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
      final ImportSource source,
      final ImportStep step,
      final List<dynamic> previewItems,
      final bool isLoading,
      final String? error,
      final ImportResult? lastResult,
      final String urlInput}) = _$AssociationStateImpl;

  @override

  /// 导入类型
  ImportType get type;
  @override

  /// 导入来源方式
  ImportSource get source;
  @override

  /// 当前导入步骤
  ImportStep get step;
  @override

  /// 预览项列表
  List<dynamic> get previewItems;
  @override

  /// 是否正在加载
  bool get isLoading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 最近一次导入结果
  ImportResult? get lastResult;
  @override

  /// URL 输入内容
  String get urlInput;
  @override
  @JsonKey(ignore: true)
  _$$AssociationStateImplCopyWith<_$AssociationStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
