// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'source_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$SourceState {
  /// 全部书源列表
  List<BookSource> get sources => throw _privateConstructorUsedError;

  /// 是否正在加载
  bool get loading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 搜索过滤关键词
  String get filterKeyword => throw _privateConstructorUsedError;

  /// 选中分组（null = 全部）
  String? get selectedGroup => throw _privateConstructorUsedError;

  /// 排序方式
  SourceSort get sort => throw _privateConstructorUsedError;

  /// 是否升序
  bool get sortAscending => throw _privateConstructorUsedError;

  /// 是否处于批量选择模式
  bool get batchMode => throw _privateConstructorUsedError;

  /// 批量选中的书源 URL 集合
  Set<String> get selectedUrls => throw _privateConstructorUsedError;

  /// 最近一次导入结果
  ImportResult? get lastImportResult => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $SourceStateCopyWith<SourceState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SourceStateCopyWith<$Res> {
  factory $SourceStateCopyWith(
          SourceState value, $Res Function(SourceState) then) =
      _$SourceStateCopyWithImpl<$Res, SourceState>;
  @useResult
  $Res call(
      {List<BookSource> sources,
      bool loading,
      String? error,
      String filterKeyword,
      String? selectedGroup,
      SourceSort sort,
      bool sortAscending,
      bool batchMode,
      Set<String> selectedUrls,
      ImportResult? lastImportResult});
}

/// @nodoc
class _$SourceStateCopyWithImpl<$Res, $Val extends SourceState>
    implements $SourceStateCopyWith<$Res> {
  _$SourceStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? sources = null,
    Object? loading = null,
    Object? error = freezed,
    Object? filterKeyword = null,
    Object? selectedGroup = freezed,
    Object? sort = null,
    Object? sortAscending = null,
    Object? batchMode = null,
    Object? selectedUrls = null,
    Object? lastImportResult = freezed,
  }) {
    return _then(_value.copyWith(
      sources: null == sources
          ? _value.sources
          : sources // ignore: cast_nullable_to_non_nullable
              as List<BookSource>,
      loading: null == loading
          ? _value.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      filterKeyword: null == filterKeyword
          ? _value.filterKeyword
          : filterKeyword // ignore: cast_nullable_to_non_nullable
              as String,
      selectedGroup: freezed == selectedGroup
          ? _value.selectedGroup
          : selectedGroup // ignore: cast_nullable_to_non_nullable
              as String?,
      sort: null == sort
          ? _value.sort
          : sort // ignore: cast_nullable_to_non_nullable
              as SourceSort,
      sortAscending: null == sortAscending
          ? _value.sortAscending
          : sortAscending // ignore: cast_nullable_to_non_nullable
              as bool,
      batchMode: null == batchMode
          ? _value.batchMode
          : batchMode // ignore: cast_nullable_to_non_nullable
              as bool,
      selectedUrls: null == selectedUrls
          ? _value.selectedUrls
          : selectedUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      lastImportResult: freezed == lastImportResult
          ? _value.lastImportResult
          : lastImportResult // ignore: cast_nullable_to_non_nullable
              as ImportResult?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SourceStateImplCopyWith<$Res>
    implements $SourceStateCopyWith<$Res> {
  factory _$$SourceStateImplCopyWith(
          _$SourceStateImpl value, $Res Function(_$SourceStateImpl) then) =
      __$$SourceStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<BookSource> sources,
      bool loading,
      String? error,
      String filterKeyword,
      String? selectedGroup,
      SourceSort sort,
      bool sortAscending,
      bool batchMode,
      Set<String> selectedUrls,
      ImportResult? lastImportResult});
}

/// @nodoc
class __$$SourceStateImplCopyWithImpl<$Res>
    extends _$SourceStateCopyWithImpl<$Res, _$SourceStateImpl>
    implements _$$SourceStateImplCopyWith<$Res> {
  __$$SourceStateImplCopyWithImpl(
      _$SourceStateImpl _value, $Res Function(_$SourceStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? sources = null,
    Object? loading = null,
    Object? error = freezed,
    Object? filterKeyword = null,
    Object? selectedGroup = freezed,
    Object? sort = null,
    Object? sortAscending = null,
    Object? batchMode = null,
    Object? selectedUrls = null,
    Object? lastImportResult = freezed,
  }) {
    return _then(_$SourceStateImpl(
      sources: null == sources
          ? _value._sources
          : sources // ignore: cast_nullable_to_non_nullable
              as List<BookSource>,
      loading: null == loading
          ? _value.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      filterKeyword: null == filterKeyword
          ? _value.filterKeyword
          : filterKeyword // ignore: cast_nullable_to_non_nullable
              as String,
      selectedGroup: freezed == selectedGroup
          ? _value.selectedGroup
          : selectedGroup // ignore: cast_nullable_to_non_nullable
              as String?,
      sort: null == sort
          ? _value.sort
          : sort // ignore: cast_nullable_to_non_nullable
              as SourceSort,
      sortAscending: null == sortAscending
          ? _value.sortAscending
          : sortAscending // ignore: cast_nullable_to_non_nullable
              as bool,
      batchMode: null == batchMode
          ? _value.batchMode
          : batchMode // ignore: cast_nullable_to_non_nullable
              as bool,
      selectedUrls: null == selectedUrls
          ? _value._selectedUrls
          : selectedUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      lastImportResult: freezed == lastImportResult
          ? _value.lastImportResult
          : lastImportResult // ignore: cast_nullable_to_non_nullable
              as ImportResult?,
    ));
  }
}

/// @nodoc

class _$SourceStateImpl implements _SourceState {
  const _$SourceStateImpl(
      {final List<BookSource> sources = const [],
      this.loading = false,
      this.error,
      this.filterKeyword = '',
      this.selectedGroup,
      this.sort = SourceSort.manual,
      this.sortAscending = true,
      this.batchMode = false,
      final Set<String> selectedUrls = const <String>{},
      this.lastImportResult})
      : _sources = sources,
        _selectedUrls = selectedUrls;

  /// 全部书源列表
  final List<BookSource> _sources;

  /// 全部书源列表
  @override
  @JsonKey()
  List<BookSource> get sources {
    if (_sources is EqualUnmodifiableListView) return _sources;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_sources);
  }

  /// 是否正在加载
  @override
  @JsonKey()
  final bool loading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  /// 搜索过滤关键词
  @override
  @JsonKey()
  final String filterKeyword;

  /// 选中分组（null = 全部）
  @override
  final String? selectedGroup;

  /// 排序方式
  @override
  @JsonKey()
  final SourceSort sort;

  /// 是否升序
  @override
  @JsonKey()
  final bool sortAscending;

  /// 是否处于批量选择模式
  @override
  @JsonKey()
  final bool batchMode;

  /// 批量选中的书源 URL 集合
  final Set<String> _selectedUrls;

  /// 批量选中的书源 URL 集合
  @override
  @JsonKey()
  Set<String> get selectedUrls {
    if (_selectedUrls is EqualUnmodifiableSetView) return _selectedUrls;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_selectedUrls);
  }

  /// 最近一次导入结果
  @override
  final ImportResult? lastImportResult;

  @override
  String toString() {
    return 'SourceState(sources: $sources, loading: $loading, error: $error, filterKeyword: $filterKeyword, selectedGroup: $selectedGroup, sort: $sort, sortAscending: $sortAscending, batchMode: $batchMode, selectedUrls: $selectedUrls, lastImportResult: $lastImportResult)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SourceStateImpl &&
            const DeepCollectionEquality().equals(other._sources, _sources) &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.filterKeyword, filterKeyword) ||
                other.filterKeyword == filterKeyword) &&
            (identical(other.selectedGroup, selectedGroup) ||
                other.selectedGroup == selectedGroup) &&
            (identical(other.sort, sort) || other.sort == sort) &&
            (identical(other.sortAscending, sortAscending) ||
                other.sortAscending == sortAscending) &&
            (identical(other.batchMode, batchMode) ||
                other.batchMode == batchMode) &&
            const DeepCollectionEquality()
                .equals(other._selectedUrls, _selectedUrls) &&
            (identical(other.lastImportResult, lastImportResult) ||
                other.lastImportResult == lastImportResult));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_sources),
      loading,
      error,
      filterKeyword,
      selectedGroup,
      sort,
      sortAscending,
      batchMode,
      const DeepCollectionEquality().hash(_selectedUrls),
      lastImportResult);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$SourceStateImplCopyWith<_$SourceStateImpl> get copyWith =>
      __$$SourceStateImplCopyWithImpl<_$SourceStateImpl>(this, _$identity);
}

abstract class _SourceState implements SourceState {
  const factory _SourceState(
      {final List<BookSource> sources,
      final bool loading,
      final String? error,
      final String filterKeyword,
      final String? selectedGroup,
      final SourceSort sort,
      final bool sortAscending,
      final bool batchMode,
      final Set<String> selectedUrls,
      final ImportResult? lastImportResult}) = _$SourceStateImpl;

  @override

  /// 全部书源列表
  List<BookSource> get sources;
  @override

  /// 是否正在加载
  bool get loading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 搜索过滤关键词
  String get filterKeyword;
  @override

  /// 选中分组（null = 全部）
  String? get selectedGroup;
  @override

  /// 排序方式
  SourceSort get sort;
  @override

  /// 是否升序
  bool get sortAscending;
  @override

  /// 是否处于批量选择模式
  bool get batchMode;
  @override

  /// 批量选中的书源 URL 集合
  Set<String> get selectedUrls;
  @override

  /// 最近一次导入结果
  ImportResult? get lastImportResult;
  @override
  @JsonKey(ignore: true)
  _$$SourceStateImplCopyWith<_$SourceStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
