// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'search_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$SearchState {
  /// 当前搜索关键词
  String get keyword => throw _privateConstructorUsedError;

  /// 搜索结果列表（已按书名+作者聚合，对齐原版 mergeItems）
  List<SearchResult> get results => throw _privateConstructorUsedError;

  /// 是否正在搜索
  bool get isLoading => throw _privateConstructorUsedError;

  /// 渐进搜索：已完成书源数（对齐原版 onSearchProgress searched）
  int get searchedCount => throw _privateConstructorUsedError;

  /// 渐进搜索：书源总数（对齐原版 onSearchProgress total）
  int get totalCount => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  /// 精准搜索：选中的书源 URL
  Set<String> get selectedSourceUrls => throw _privateConstructorUsedError;

  /// 精准搜索：选中的分组
  Set<String> get selectedGroups => throw _privateConstructorUsedError;

  /// 搜索历史（最近 20 条，经 BookApi 持久化至 Rust search_keywords 表）
  /// [审计修复 §4.5] 清理陈旧注释（实际已不走 SharedPreferences） — Qoder
  List<String> get searchHistory => throw _privateConstructorUsedError;

  /// 输入框实时文本（用于联想过滤，区别于已提交的 [keyword]）
  String get inputText => throw _privateConstructorUsedError;

  /// 活动搜索会话的当前页码（批次B G-B-01：新关键词 → 重置为 1；
  /// 同关键词续页 → searchPage++，对齐原版 SearchModel.searchPage）
  int get searchPage => throw _privateConstructorUsedError;

  /// 是否有下一页（批次B G-B-02：当前页非空批次的 OR，Rust 侧 has_more
  /// 累积字段；新搜索开始时乐观置 true，每批事件覆写）
  bool get hasMore => throw _privateConstructorUsedError;

  /// 软挂起态（批次B G-B-04：仅门控未派发书源，已派发任务继续；
  /// 对齐原版 repeatOnLifecycle(RESUMED) → viewModel.pause/resume）
  bool get isPaused => throw _privateConstructorUsedError;

  /// 用户手动停止了本次搜索（对齐原版 SearchActivity.isManualStopSearch）：
  /// 抑制 play FAB 与滚动自动加载，直至新关键词搜索重置
  bool get isManualStop => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $SearchStateCopyWith<SearchState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SearchStateCopyWith<$Res> {
  factory $SearchStateCopyWith(
          SearchState value, $Res Function(SearchState) then) =
      _$SearchStateCopyWithImpl<$Res, SearchState>;
  @useResult
  $Res call(
      {String keyword,
      List<SearchResult> results,
      bool isLoading,
      int searchedCount,
      int totalCount,
      String? error,
      Set<String> selectedSourceUrls,
      Set<String> selectedGroups,
      List<String> searchHistory,
      String inputText,
      int searchPage,
      bool hasMore,
      bool isPaused,
      bool isManualStop});
}

/// @nodoc
class _$SearchStateCopyWithImpl<$Res, $Val extends SearchState>
    implements $SearchStateCopyWith<$Res> {
  _$SearchStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? keyword = null,
    Object? results = null,
    Object? isLoading = null,
    Object? searchedCount = null,
    Object? totalCount = null,
    Object? error = freezed,
    Object? selectedSourceUrls = null,
    Object? selectedGroups = null,
    Object? searchHistory = null,
    Object? inputText = null,
    Object? searchPage = null,
    Object? hasMore = null,
    Object? isPaused = null,
    Object? isManualStop = null,
  }) {
    return _then(_value.copyWith(
      keyword: null == keyword
          ? _value.keyword
          : keyword // ignore: cast_nullable_to_non_nullable
              as String,
      results: null == results
          ? _value.results
          : results // ignore: cast_nullable_to_non_nullable
              as List<SearchResult>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      searchedCount: null == searchedCount
          ? _value.searchedCount
          : searchedCount // ignore: cast_nullable_to_non_nullable
              as int,
      totalCount: null == totalCount
          ? _value.totalCount
          : totalCount // ignore: cast_nullable_to_non_nullable
              as int,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      selectedSourceUrls: null == selectedSourceUrls
          ? _value.selectedSourceUrls
          : selectedSourceUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      selectedGroups: null == selectedGroups
          ? _value.selectedGroups
          : selectedGroups // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      searchHistory: null == searchHistory
          ? _value.searchHistory
          : searchHistory // ignore: cast_nullable_to_non_nullable
              as List<String>,
      inputText: null == inputText
          ? _value.inputText
          : inputText // ignore: cast_nullable_to_non_nullable
              as String,
      searchPage: null == searchPage
          ? _value.searchPage
          : searchPage // ignore: cast_nullable_to_non_nullable
              as int,
      hasMore: null == hasMore
          ? _value.hasMore
          : hasMore // ignore: cast_nullable_to_non_nullable
              as bool,
      isPaused: null == isPaused
          ? _value.isPaused
          : isPaused // ignore: cast_nullable_to_non_nullable
              as bool,
      isManualStop: null == isManualStop
          ? _value.isManualStop
          : isManualStop // ignore: cast_nullable_to_non_nullable
              as bool,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SearchStateImplCopyWith<$Res>
    implements $SearchStateCopyWith<$Res> {
  factory _$$SearchStateImplCopyWith(
          _$SearchStateImpl value, $Res Function(_$SearchStateImpl) then) =
      __$$SearchStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String keyword,
      List<SearchResult> results,
      bool isLoading,
      int searchedCount,
      int totalCount,
      String? error,
      Set<String> selectedSourceUrls,
      Set<String> selectedGroups,
      List<String> searchHistory,
      String inputText,
      int searchPage,
      bool hasMore,
      bool isPaused,
      bool isManualStop});
}

/// @nodoc
class __$$SearchStateImplCopyWithImpl<$Res>
    extends _$SearchStateCopyWithImpl<$Res, _$SearchStateImpl>
    implements _$$SearchStateImplCopyWith<$Res> {
  __$$SearchStateImplCopyWithImpl(
      _$SearchStateImpl _value, $Res Function(_$SearchStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? keyword = null,
    Object? results = null,
    Object? isLoading = null,
    Object? searchedCount = null,
    Object? totalCount = null,
    Object? error = freezed,
    Object? selectedSourceUrls = null,
    Object? selectedGroups = null,
    Object? searchHistory = null,
    Object? inputText = null,
    Object? searchPage = null,
    Object? hasMore = null,
    Object? isPaused = null,
    Object? isManualStop = null,
  }) {
    return _then(_$SearchStateImpl(
      keyword: null == keyword
          ? _value.keyword
          : keyword // ignore: cast_nullable_to_non_nullable
              as String,
      results: null == results
          ? _value._results
          : results // ignore: cast_nullable_to_non_nullable
              as List<SearchResult>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      searchedCount: null == searchedCount
          ? _value.searchedCount
          : searchedCount // ignore: cast_nullable_to_non_nullable
              as int,
      totalCount: null == totalCount
          ? _value.totalCount
          : totalCount // ignore: cast_nullable_to_non_nullable
              as int,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      selectedSourceUrls: null == selectedSourceUrls
          ? _value._selectedSourceUrls
          : selectedSourceUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      selectedGroups: null == selectedGroups
          ? _value._selectedGroups
          : selectedGroups // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      searchHistory: null == searchHistory
          ? _value._searchHistory
          : searchHistory // ignore: cast_nullable_to_non_nullable
              as List<String>,
      inputText: null == inputText
          ? _value.inputText
          : inputText // ignore: cast_nullable_to_non_nullable
              as String,
      searchPage: null == searchPage
          ? _value.searchPage
          : searchPage // ignore: cast_nullable_to_non_nullable
              as int,
      hasMore: null == hasMore
          ? _value.hasMore
          : hasMore // ignore: cast_nullable_to_non_nullable
              as bool,
      isPaused: null == isPaused
          ? _value.isPaused
          : isPaused // ignore: cast_nullable_to_non_nullable
              as bool,
      isManualStop: null == isManualStop
          ? _value.isManualStop
          : isManualStop // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _$SearchStateImpl implements _SearchState {
  const _$SearchStateImpl(
      {this.keyword = '',
      final List<SearchResult> results = const [],
      this.isLoading = false,
      this.searchedCount = 0,
      this.totalCount = 0,
      this.error,
      final Set<String> selectedSourceUrls = const <String>{},
      final Set<String> selectedGroups = const <String>{},
      final List<String> searchHistory = const [],
      this.inputText = '',
      this.searchPage = 1,
      this.hasMore = false,
      this.isPaused = false,
      this.isManualStop = false})
      : _results = results,
        _selectedSourceUrls = selectedSourceUrls,
        _selectedGroups = selectedGroups,
        _searchHistory = searchHistory;

  /// 当前搜索关键词
  @override
  @JsonKey()
  final String keyword;

  /// 搜索结果列表（已按书名+作者聚合，对齐原版 mergeItems）
  final List<SearchResult> _results;

  /// 搜索结果列表（已按书名+作者聚合，对齐原版 mergeItems）
  @override
  @JsonKey()
  List<SearchResult> get results {
    if (_results is EqualUnmodifiableListView) return _results;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_results);
  }

  /// 是否正在搜索
  @override
  @JsonKey()
  final bool isLoading;

  /// 渐进搜索：已完成书源数（对齐原版 onSearchProgress searched）
  @override
  @JsonKey()
  final int searchedCount;

  /// 渐进搜索：书源总数（对齐原版 onSearchProgress total）
  @override
  @JsonKey()
  final int totalCount;

  /// 错误信息
  @override
  final String? error;

  /// 精准搜索：选中的书源 URL
  final Set<String> _selectedSourceUrls;

  /// 精准搜索：选中的书源 URL
  @override
  @JsonKey()
  Set<String> get selectedSourceUrls {
    if (_selectedSourceUrls is EqualUnmodifiableSetView)
      return _selectedSourceUrls;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_selectedSourceUrls);
  }

  /// 精准搜索：选中的分组
  final Set<String> _selectedGroups;

  /// 精准搜索：选中的分组
  @override
  @JsonKey()
  Set<String> get selectedGroups {
    if (_selectedGroups is EqualUnmodifiableSetView) return _selectedGroups;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_selectedGroups);
  }

  /// 搜索历史（最近 20 条，经 BookApi 持久化至 Rust search_keywords 表）
  /// [审计修复 §4.5] 清理陈旧注释（实际已不走 SharedPreferences） — Qoder
  final List<String> _searchHistory;

  /// 搜索历史（最近 20 条，经 BookApi 持久化至 Rust search_keywords 表）
  /// [审计修复 §4.5] 清理陈旧注释（实际已不走 SharedPreferences） — Qoder
  @override
  @JsonKey()
  List<String> get searchHistory {
    if (_searchHistory is EqualUnmodifiableListView) return _searchHistory;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_searchHistory);
  }

  /// 输入框实时文本（用于联想过滤，区别于已提交的 [keyword]）
  @override
  @JsonKey()
  final String inputText;

  /// 活动搜索会话的当前页码（批次B G-B-01：新关键词 → 重置为 1；
  /// 同关键词续页 → searchPage++，对齐原版 SearchModel.searchPage）
  @override
  @JsonKey()
  final int searchPage;

  /// 是否有下一页（批次B G-B-02：当前页非空批次的 OR，Rust 侧 has_more
  /// 累积字段；新搜索开始时乐观置 true，每批事件覆写）
  @override
  @JsonKey()
  final bool hasMore;

  /// 软挂起态（批次B G-B-04：仅门控未派发书源，已派发任务继续；
  /// 对齐原版 repeatOnLifecycle(RESUMED) → viewModel.pause/resume）
  @override
  @JsonKey()
  final bool isPaused;

  /// 用户手动停止了本次搜索（对齐原版 SearchActivity.isManualStopSearch）：
  /// 抑制 play FAB 与滚动自动加载，直至新关键词搜索重置
  @override
  @JsonKey()
  final bool isManualStop;

  @override
  String toString() {
    return 'SearchState(keyword: $keyword, results: $results, isLoading: $isLoading, searchedCount: $searchedCount, totalCount: $totalCount, error: $error, selectedSourceUrls: $selectedSourceUrls, selectedGroups: $selectedGroups, searchHistory: $searchHistory, inputText: $inputText, searchPage: $searchPage, hasMore: $hasMore, isPaused: $isPaused, isManualStop: $isManualStop)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SearchStateImpl &&
            (identical(other.keyword, keyword) || other.keyword == keyword) &&
            const DeepCollectionEquality().equals(other._results, _results) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.searchedCount, searchedCount) ||
                other.searchedCount == searchedCount) &&
            (identical(other.totalCount, totalCount) ||
                other.totalCount == totalCount) &&
            (identical(other.error, error) || other.error == error) &&
            const DeepCollectionEquality()
                .equals(other._selectedSourceUrls, _selectedSourceUrls) &&
            const DeepCollectionEquality()
                .equals(other._selectedGroups, _selectedGroups) &&
            const DeepCollectionEquality()
                .equals(other._searchHistory, _searchHistory) &&
            (identical(other.inputText, inputText) ||
                other.inputText == inputText) &&
            (identical(other.searchPage, searchPage) ||
                other.searchPage == searchPage) &&
            (identical(other.hasMore, hasMore) || other.hasMore == hasMore) &&
            (identical(other.isPaused, isPaused) ||
                other.isPaused == isPaused) &&
            (identical(other.isManualStop, isManualStop) ||
                other.isManualStop == isManualStop));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      keyword,
      const DeepCollectionEquality().hash(_results),
      isLoading,
      searchedCount,
      totalCount,
      error,
      const DeepCollectionEquality().hash(_selectedSourceUrls),
      const DeepCollectionEquality().hash(_selectedGroups),
      const DeepCollectionEquality().hash(_searchHistory),
      inputText,
      searchPage,
      hasMore,
      isPaused,
      isManualStop);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$SearchStateImplCopyWith<_$SearchStateImpl> get copyWith =>
      __$$SearchStateImplCopyWithImpl<_$SearchStateImpl>(this, _$identity);
}

abstract class _SearchState implements SearchState {
  const factory _SearchState(
      {final String keyword,
      final List<SearchResult> results,
      final bool isLoading,
      final int searchedCount,
      final int totalCount,
      final String? error,
      final Set<String> selectedSourceUrls,
      final Set<String> selectedGroups,
      final List<String> searchHistory,
      final String inputText,
      final int searchPage,
      final bool hasMore,
      final bool isPaused,
      final bool isManualStop}) = _$SearchStateImpl;

  @override

  /// 当前搜索关键词
  String get keyword;
  @override

  /// 搜索结果列表（已按书名+作者聚合，对齐原版 mergeItems）
  List<SearchResult> get results;
  @override

  /// 是否正在搜索
  bool get isLoading;
  @override

  /// 渐进搜索：已完成书源数（对齐原版 onSearchProgress searched）
  int get searchedCount;
  @override

  /// 渐进搜索：书源总数（对齐原版 onSearchProgress total）
  int get totalCount;
  @override

  /// 错误信息
  String? get error;
  @override

  /// 精准搜索：选中的书源 URL
  Set<String> get selectedSourceUrls;
  @override

  /// 精准搜索：选中的分组
  Set<String> get selectedGroups;
  @override

  /// 搜索历史（最近 20 条，经 BookApi 持久化至 Rust search_keywords 表）
  /// [审计修复 §4.5] 清理陈旧注释（实际已不走 SharedPreferences） — Qoder
  List<String> get searchHistory;
  @override

  /// 输入框实时文本（用于联想过滤，区别于已提交的 [keyword]）
  String get inputText;
  @override

  /// 活动搜索会话的当前页码（批次B G-B-01：新关键词 → 重置为 1；
  /// 同关键词续页 → searchPage++，对齐原版 SearchModel.searchPage）
  int get searchPage;
  @override

  /// 是否有下一页（批次B G-B-02：当前页非空批次的 OR，Rust 侧 has_more
  /// 累积字段；新搜索开始时乐观置 true，每批事件覆写）
  bool get hasMore;
  @override

  /// 软挂起态（批次B G-B-04：仅门控未派发书源，已派发任务继续；
  /// 对齐原版 repeatOnLifecycle(RESUMED) → viewModel.pause/resume）
  bool get isPaused;
  @override

  /// 用户手动停止了本次搜索（对齐原版 SearchActivity.isManualStopSearch）：
  /// 抑制 play FAB 与滚动自动加载，直至新关键词搜索重置
  bool get isManualStop;
  @override
  @JsonKey(ignore: true)
  _$$SearchStateImplCopyWith<_$SearchStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
