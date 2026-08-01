// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'explore_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ExploreState {
  /// 发现书源列表（已按 Android ExploreFragment 规则过滤：enabledExplore && exploreUrl 非空）
  List<BookSource> get bookSources => throw _privateConstructorUsedError;

  /// 是否正在加载书源列表
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 展示层：实时搜索关键词
  String get searchKeyword => throw _privateConstructorUsedError;

  /// 展示层：选中分组（空字符串表示全部）
  String get selectedGroup => throw _privateConstructorUsedError;

  /// 分类缓存：sourceUrl → 解析出的分类列表（对齐 exploreParseUrl）
  Map<String, List<ExploreCategory>> get categoriesCache =>
      throw _privateConstructorUsedError;

  /// 正在加载分类的书源 URL 集合
  Set<String> get loadingCategories => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ExploreStateCopyWith<ExploreState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ExploreStateCopyWith<$Res> {
  factory $ExploreStateCopyWith(
          ExploreState value, $Res Function(ExploreState) then) =
      _$ExploreStateCopyWithImpl<$Res, ExploreState>;
  @useResult
  $Res call(
      {List<BookSource> bookSources,
      bool isLoading,
      String? error,
      String searchKeyword,
      String selectedGroup,
      Map<String, List<ExploreCategory>> categoriesCache,
      Set<String> loadingCategories});
}

/// @nodoc
class _$ExploreStateCopyWithImpl<$Res, $Val extends ExploreState>
    implements $ExploreStateCopyWith<$Res> {
  _$ExploreStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? bookSources = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? searchKeyword = null,
    Object? selectedGroup = null,
    Object? categoriesCache = null,
    Object? loadingCategories = null,
  }) {
    return _then(_value.copyWith(
      bookSources: null == bookSources
          ? _value.bookSources
          : bookSources // ignore: cast_nullable_to_non_nullable
              as List<BookSource>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      searchKeyword: null == searchKeyword
          ? _value.searchKeyword
          : searchKeyword // ignore: cast_nullable_to_non_nullable
              as String,
      selectedGroup: null == selectedGroup
          ? _value.selectedGroup
          : selectedGroup // ignore: cast_nullable_to_non_nullable
              as String,
      categoriesCache: null == categoriesCache
          ? _value.categoriesCache
          : categoriesCache // ignore: cast_nullable_to_non_nullable
              as Map<String, List<ExploreCategory>>,
      loadingCategories: null == loadingCategories
          ? _value.loadingCategories
          : loadingCategories // ignore: cast_nullable_to_non_nullable
              as Set<String>,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ExploreStateImplCopyWith<$Res>
    implements $ExploreStateCopyWith<$Res> {
  factory _$$ExploreStateImplCopyWith(
          _$ExploreStateImpl value, $Res Function(_$ExploreStateImpl) then) =
      __$$ExploreStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<BookSource> bookSources,
      bool isLoading,
      String? error,
      String searchKeyword,
      String selectedGroup,
      Map<String, List<ExploreCategory>> categoriesCache,
      Set<String> loadingCategories});
}

/// @nodoc
class __$$ExploreStateImplCopyWithImpl<$Res>
    extends _$ExploreStateCopyWithImpl<$Res, _$ExploreStateImpl>
    implements _$$ExploreStateImplCopyWith<$Res> {
  __$$ExploreStateImplCopyWithImpl(
      _$ExploreStateImpl _value, $Res Function(_$ExploreStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? bookSources = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? searchKeyword = null,
    Object? selectedGroup = null,
    Object? categoriesCache = null,
    Object? loadingCategories = null,
  }) {
    return _then(_$ExploreStateImpl(
      bookSources: null == bookSources
          ? _value._bookSources
          : bookSources // ignore: cast_nullable_to_non_nullable
              as List<BookSource>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      searchKeyword: null == searchKeyword
          ? _value.searchKeyword
          : searchKeyword // ignore: cast_nullable_to_non_nullable
              as String,
      selectedGroup: null == selectedGroup
          ? _value.selectedGroup
          : selectedGroup // ignore: cast_nullable_to_non_nullable
              as String,
      categoriesCache: null == categoriesCache
          ? _value._categoriesCache
          : categoriesCache // ignore: cast_nullable_to_non_nullable
              as Map<String, List<ExploreCategory>>,
      loadingCategories: null == loadingCategories
          ? _value._loadingCategories
          : loadingCategories // ignore: cast_nullable_to_non_nullable
              as Set<String>,
    ));
  }
}

/// @nodoc

class _$ExploreStateImpl implements _ExploreState {
  const _$ExploreStateImpl(
      {final List<BookSource> bookSources = const [],
      this.isLoading = false,
      this.error,
      this.searchKeyword = '',
      this.selectedGroup = '',
      final Map<String, List<ExploreCategory>> categoriesCache =
          const <String, List<ExploreCategory>>{},
      final Set<String> loadingCategories = const <String>{}})
      : _bookSources = bookSources,
        _categoriesCache = categoriesCache,
        _loadingCategories = loadingCategories;

  /// 发现书源列表（已按 Android ExploreFragment 规则过滤：enabledExplore && exploreUrl 非空）
  final List<BookSource> _bookSources;

  /// 发现书源列表（已按 Android ExploreFragment 规则过滤：enabledExplore && exploreUrl 非空）
  @override
  @JsonKey()
  List<BookSource> get bookSources {
    if (_bookSources is EqualUnmodifiableListView) return _bookSources;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_bookSources);
  }

  /// 是否正在加载书源列表
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  /// 展示层：实时搜索关键词
  @override
  @JsonKey()
  final String searchKeyword;

  /// 展示层：选中分组（空字符串表示全部）
  @override
  @JsonKey()
  final String selectedGroup;

  /// 分类缓存：sourceUrl → 解析出的分类列表（对齐 exploreParseUrl）
  final Map<String, List<ExploreCategory>> _categoriesCache;

  /// 分类缓存：sourceUrl → 解析出的分类列表（对齐 exploreParseUrl）
  @override
  @JsonKey()
  Map<String, List<ExploreCategory>> get categoriesCache {
    if (_categoriesCache is EqualUnmodifiableMapView) return _categoriesCache;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_categoriesCache);
  }

  /// 正在加载分类的书源 URL 集合
  final Set<String> _loadingCategories;

  /// 正在加载分类的书源 URL 集合
  @override
  @JsonKey()
  Set<String> get loadingCategories {
    if (_loadingCategories is EqualUnmodifiableSetView)
      return _loadingCategories;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_loadingCategories);
  }

  @override
  String toString() {
    return 'ExploreState(bookSources: $bookSources, isLoading: $isLoading, error: $error, searchKeyword: $searchKeyword, selectedGroup: $selectedGroup, categoriesCache: $categoriesCache, loadingCategories: $loadingCategories)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ExploreStateImpl &&
            const DeepCollectionEquality()
                .equals(other._bookSources, _bookSources) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.searchKeyword, searchKeyword) ||
                other.searchKeyword == searchKeyword) &&
            (identical(other.selectedGroup, selectedGroup) ||
                other.selectedGroup == selectedGroup) &&
            const DeepCollectionEquality()
                .equals(other._categoriesCache, _categoriesCache) &&
            const DeepCollectionEquality()
                .equals(other._loadingCategories, _loadingCategories));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_bookSources),
      isLoading,
      error,
      searchKeyword,
      selectedGroup,
      const DeepCollectionEquality().hash(_categoriesCache),
      const DeepCollectionEquality().hash(_loadingCategories));

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ExploreStateImplCopyWith<_$ExploreStateImpl> get copyWith =>
      __$$ExploreStateImplCopyWithImpl<_$ExploreStateImpl>(this, _$identity);
}

abstract class _ExploreState implements ExploreState {
  const factory _ExploreState(
      {final List<BookSource> bookSources,
      final bool isLoading,
      final String? error,
      final String searchKeyword,
      final String selectedGroup,
      final Map<String, List<ExploreCategory>> categoriesCache,
      final Set<String> loadingCategories}) = _$ExploreStateImpl;

  @override

  /// 发现书源列表（已按 Android ExploreFragment 规则过滤：enabledExplore && exploreUrl 非空）
  List<BookSource> get bookSources;
  @override

  /// 是否正在加载书源列表
  bool get isLoading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 展示层：实时搜索关键词
  String get searchKeyword;
  @override

  /// 展示层：选中分组（空字符串表示全部）
  String get selectedGroup;
  @override

  /// 分类缓存：sourceUrl → 解析出的分类列表（对齐 exploreParseUrl）
  Map<String, List<ExploreCategory>> get categoriesCache;
  @override

  /// 正在加载分类的书源 URL 集合
  Set<String> get loadingCategories;
  @override
  @JsonKey(ignore: true)
  _$$ExploreStateImplCopyWith<_$ExploreStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
