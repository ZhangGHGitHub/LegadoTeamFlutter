// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'change_source_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ChangeSourceState {
  /// 匹配到的候选书源列表（Rust 已按评分降序排序，UI 直接渲染）
  List<SourceMatch> get results => throw _privateConstructorUsedError;

  /// 是否正在搜索
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  /// 正在应用切换的书源 URL（null 表示无切换进行中）
  String? get applyingUrl => throw _privateConstructorUsedError;

  /// 本轮搜索的书源数量（仅 isLoading 时非 null；体检 U1 等待反馈，
  /// T6 流式 API 落地前暂以「源数量+时长」替代逐源 x/y 进度）
  int? get searchingCount => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ChangeSourceStateCopyWith<ChangeSourceState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ChangeSourceStateCopyWith<$Res> {
  factory $ChangeSourceStateCopyWith(
          ChangeSourceState value, $Res Function(ChangeSourceState) then) =
      _$ChangeSourceStateCopyWithImpl<$Res, ChangeSourceState>;
  @useResult
  $Res call(
      {List<SourceMatch> results,
      bool isLoading,
      String? error,
      String? applyingUrl,
      int? searchingCount});
}

/// @nodoc
class _$ChangeSourceStateCopyWithImpl<$Res, $Val extends ChangeSourceState>
    implements $ChangeSourceStateCopyWith<$Res> {
  _$ChangeSourceStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? results = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? applyingUrl = freezed,
    Object? searchingCount = freezed,
  }) {
    return _then(_value.copyWith(
      results: null == results
          ? _value.results
          : results // ignore: cast_nullable_to_non_nullable
              as List<SourceMatch>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      applyingUrl: freezed == applyingUrl
          ? _value.applyingUrl
          : applyingUrl // ignore: cast_nullable_to_non_nullable
              as String?,
      searchingCount: freezed == searchingCount
          ? _value.searchingCount
          : searchingCount // ignore: cast_nullable_to_non_nullable
              as int?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ChangeSourceStateImplCopyWith<$Res>
    implements $ChangeSourceStateCopyWith<$Res> {
  factory _$$ChangeSourceStateImplCopyWith(_$ChangeSourceStateImpl value,
          $Res Function(_$ChangeSourceStateImpl) then) =
      __$$ChangeSourceStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<SourceMatch> results,
      bool isLoading,
      String? error,
      String? applyingUrl,
      int? searchingCount});
}

/// @nodoc
class __$$ChangeSourceStateImplCopyWithImpl<$Res>
    extends _$ChangeSourceStateCopyWithImpl<$Res, _$ChangeSourceStateImpl>
    implements _$$ChangeSourceStateImplCopyWith<$Res> {
  __$$ChangeSourceStateImplCopyWithImpl(_$ChangeSourceStateImpl _value,
      $Res Function(_$ChangeSourceStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? results = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? applyingUrl = freezed,
    Object? searchingCount = freezed,
  }) {
    return _then(_$ChangeSourceStateImpl(
      results: null == results
          ? _value._results
          : results // ignore: cast_nullable_to_non_nullable
              as List<SourceMatch>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      applyingUrl: freezed == applyingUrl
          ? _value.applyingUrl
          : applyingUrl // ignore: cast_nullable_to_non_nullable
              as String?,
      searchingCount: freezed == searchingCount
          ? _value.searchingCount
          : searchingCount // ignore: cast_nullable_to_non_nullable
              as int?,
    ));
  }
}

/// @nodoc

class _$ChangeSourceStateImpl implements _ChangeSourceState {
  const _$ChangeSourceStateImpl(
      {final List<SourceMatch> results = const [],
      this.isLoading = false,
      this.error,
      this.applyingUrl,
      this.searchingCount})
      : _results = results;

  /// 匹配到的候选书源列表（Rust 已按评分降序排序，UI 直接渲染）
  final List<SourceMatch> _results;

  /// 匹配到的候选书源列表（Rust 已按评分降序排序，UI 直接渲染）
  @override
  @JsonKey()
  List<SourceMatch> get results {
    if (_results is EqualUnmodifiableListView) return _results;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_results);
  }

  /// 是否正在搜索
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息
  @override
  final String? error;

  /// 正在应用切换的书源 URL（null 表示无切换进行中）
  @override
  final String? applyingUrl;

  /// 本轮搜索的书源数量（仅 isLoading 时非 null；体检 U1 等待反馈，
  /// T6 流式 API 落地前暂以「源数量+时长」替代逐源 x/y 进度）
  @override
  final int? searchingCount;

  @override
  String toString() {
    return 'ChangeSourceState(results: $results, isLoading: $isLoading, error: $error, applyingUrl: $applyingUrl, searchingCount: $searchingCount)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ChangeSourceStateImpl &&
            const DeepCollectionEquality().equals(other._results, _results) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.applyingUrl, applyingUrl) ||
                other.applyingUrl == applyingUrl) &&
            (identical(other.searchingCount, searchingCount) ||
                other.searchingCount == searchingCount));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_results),
      isLoading,
      error,
      applyingUrl,
      searchingCount);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ChangeSourceStateImplCopyWith<_$ChangeSourceStateImpl> get copyWith =>
      __$$ChangeSourceStateImplCopyWithImpl<_$ChangeSourceStateImpl>(
          this, _$identity);
}

abstract class _ChangeSourceState implements ChangeSourceState {
  const factory _ChangeSourceState(
      {final List<SourceMatch> results,
      final bool isLoading,
      final String? error,
      final String? applyingUrl,
      final int? searchingCount}) = _$ChangeSourceStateImpl;

  @override

  /// 匹配到的候选书源列表（Rust 已按评分降序排序，UI 直接渲染）
  List<SourceMatch> get results;
  @override

  /// 是否正在搜索
  bool get isLoading;
  @override

  /// 错误信息
  String? get error;
  @override

  /// 正在应用切换的书源 URL（null 表示无切换进行中）
  String? get applyingUrl;
  @override

  /// 本轮搜索的书源数量（仅 isLoading 时非 null；体检 U1 等待反馈，
  /// T6 流式 API 落地前暂以「源数量+时长」替代逐源 x/y 进度）
  int? get searchingCount;
  @override
  @JsonKey(ignore: true)
  _$$ChangeSourceStateImplCopyWith<_$ChangeSourceStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
