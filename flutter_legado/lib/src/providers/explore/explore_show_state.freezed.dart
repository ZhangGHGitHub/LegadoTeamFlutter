// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'explore_show_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ExploreShowState {
  /// 当前书源
  BookSource? get source => throw _privateConstructorUsedError;

  /// 分类名称（用于标题显示）
  String get categoryName => throw _privateConstructorUsedError;

  /// 分类 URL
  String get categoryUrl => throw _privateConstructorUsedError;

  /// 已加载的书籍列表（累积去重）
  List<SearchBook> get books => throw _privateConstructorUsedError;

  /// 下一待抓取页码（对标 Android ExplorePaginationState.nextPage）
  int get page => throw _privateConstructorUsedError;

  /// 当前展示页码（对标 Android pageLiveData，0 表示尚未完成首次加载）
  int get displayPage => throw _privateConstructorUsedError;

  /// 是否正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 是否还有更多数据
  bool get hasMore => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ExploreShowStateCopyWith<ExploreShowState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ExploreShowStateCopyWith<$Res> {
  factory $ExploreShowStateCopyWith(
          ExploreShowState value, $Res Function(ExploreShowState) then) =
      _$ExploreShowStateCopyWithImpl<$Res, ExploreShowState>;
  @useResult
  $Res call(
      {BookSource? source,
      String categoryName,
      String categoryUrl,
      List<SearchBook> books,
      int page,
      int displayPage,
      bool isLoading,
      bool hasMore,
      String? error});

  $BookSourceCopyWith<$Res>? get source;
}

/// @nodoc
class _$ExploreShowStateCopyWithImpl<$Res, $Val extends ExploreShowState>
    implements $ExploreShowStateCopyWith<$Res> {
  _$ExploreShowStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? source = freezed,
    Object? categoryName = null,
    Object? categoryUrl = null,
    Object? books = null,
    Object? page = null,
    Object? displayPage = null,
    Object? isLoading = null,
    Object? hasMore = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      source: freezed == source
          ? _value.source
          : source // ignore: cast_nullable_to_non_nullable
              as BookSource?,
      categoryName: null == categoryName
          ? _value.categoryName
          : categoryName // ignore: cast_nullable_to_non_nullable
              as String,
      categoryUrl: null == categoryUrl
          ? _value.categoryUrl
          : categoryUrl // ignore: cast_nullable_to_non_nullable
              as String,
      books: null == books
          ? _value.books
          : books // ignore: cast_nullable_to_non_nullable
              as List<SearchBook>,
      page: null == page
          ? _value.page
          : page // ignore: cast_nullable_to_non_nullable
              as int,
      displayPage: null == displayPage
          ? _value.displayPage
          : displayPage // ignore: cast_nullable_to_non_nullable
              as int,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      hasMore: null == hasMore
          ? _value.hasMore
          : hasMore // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }

  @override
  @pragma('vm:prefer-inline')
  $BookSourceCopyWith<$Res>? get source {
    if (_value.source == null) {
      return null;
    }

    return $BookSourceCopyWith<$Res>(_value.source!, (value) {
      return _then(_value.copyWith(source: value) as $Val);
    });
  }
}

/// @nodoc
abstract class _$$ExploreShowStateImplCopyWith<$Res>
    implements $ExploreShowStateCopyWith<$Res> {
  factory _$$ExploreShowStateImplCopyWith(_$ExploreShowStateImpl value,
          $Res Function(_$ExploreShowStateImpl) then) =
      __$$ExploreShowStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {BookSource? source,
      String categoryName,
      String categoryUrl,
      List<SearchBook> books,
      int page,
      int displayPage,
      bool isLoading,
      bool hasMore,
      String? error});

  @override
  $BookSourceCopyWith<$Res>? get source;
}

/// @nodoc
class __$$ExploreShowStateImplCopyWithImpl<$Res>
    extends _$ExploreShowStateCopyWithImpl<$Res, _$ExploreShowStateImpl>
    implements _$$ExploreShowStateImplCopyWith<$Res> {
  __$$ExploreShowStateImplCopyWithImpl(_$ExploreShowStateImpl _value,
      $Res Function(_$ExploreShowStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? source = freezed,
    Object? categoryName = null,
    Object? categoryUrl = null,
    Object? books = null,
    Object? page = null,
    Object? displayPage = null,
    Object? isLoading = null,
    Object? hasMore = null,
    Object? error = freezed,
  }) {
    return _then(_$ExploreShowStateImpl(
      source: freezed == source
          ? _value.source
          : source // ignore: cast_nullable_to_non_nullable
              as BookSource?,
      categoryName: null == categoryName
          ? _value.categoryName
          : categoryName // ignore: cast_nullable_to_non_nullable
              as String,
      categoryUrl: null == categoryUrl
          ? _value.categoryUrl
          : categoryUrl // ignore: cast_nullable_to_non_nullable
              as String,
      books: null == books
          ? _value._books
          : books // ignore: cast_nullable_to_non_nullable
              as List<SearchBook>,
      page: null == page
          ? _value.page
          : page // ignore: cast_nullable_to_non_nullable
              as int,
      displayPage: null == displayPage
          ? _value.displayPage
          : displayPage // ignore: cast_nullable_to_non_nullable
              as int,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      hasMore: null == hasMore
          ? _value.hasMore
          : hasMore // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$ExploreShowStateImpl implements _ExploreShowState {
  const _$ExploreShowStateImpl(
      {this.source,
      this.categoryName = '',
      this.categoryUrl = '',
      final List<SearchBook> books = const [],
      this.page = 1,
      this.displayPage = 0,
      this.isLoading = false,
      this.hasMore = true,
      this.error})
      : _books = books;

  /// 当前书源
  @override
  final BookSource? source;

  /// 分类名称（用于标题显示）
  @override
  @JsonKey()
  final String categoryName;

  /// 分类 URL
  @override
  @JsonKey()
  final String categoryUrl;

  /// 已加载的书籍列表（累积去重）
  final List<SearchBook> _books;

  /// 已加载的书籍列表（累积去重）
  @override
  @JsonKey()
  List<SearchBook> get books {
    if (_books is EqualUnmodifiableListView) return _books;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_books);
  }

  /// 下一待抓取页码（对标 Android ExplorePaginationState.nextPage）
  @override
  @JsonKey()
  final int page;

  /// 当前展示页码（对标 Android pageLiveData，0 表示尚未完成首次加载）
  @override
  @JsonKey()
  final int displayPage;

  /// 是否正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 是否还有更多数据
  @override
  @JsonKey()
  final bool hasMore;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'ExploreShowState(source: $source, categoryName: $categoryName, categoryUrl: $categoryUrl, books: $books, page: $page, displayPage: $displayPage, isLoading: $isLoading, hasMore: $hasMore, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ExploreShowStateImpl &&
            (identical(other.source, source) || other.source == source) &&
            (identical(other.categoryName, categoryName) ||
                other.categoryName == categoryName) &&
            (identical(other.categoryUrl, categoryUrl) ||
                other.categoryUrl == categoryUrl) &&
            const DeepCollectionEquality().equals(other._books, _books) &&
            (identical(other.page, page) || other.page == page) &&
            (identical(other.displayPage, displayPage) ||
                other.displayPage == displayPage) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.hasMore, hasMore) || other.hasMore == hasMore) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      source,
      categoryName,
      categoryUrl,
      const DeepCollectionEquality().hash(_books),
      page,
      displayPage,
      isLoading,
      hasMore,
      error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ExploreShowStateImplCopyWith<_$ExploreShowStateImpl> get copyWith =>
      __$$ExploreShowStateImplCopyWithImpl<_$ExploreShowStateImpl>(
          this, _$identity);
}

abstract class _ExploreShowState implements ExploreShowState {
  const factory _ExploreShowState(
      {final BookSource? source,
      final String categoryName,
      final String categoryUrl,
      final List<SearchBook> books,
      final int page,
      final int displayPage,
      final bool isLoading,
      final bool hasMore,
      final String? error}) = _$ExploreShowStateImpl;

  @override

  /// 当前书源
  BookSource? get source;
  @override

  /// 分类名称（用于标题显示）
  String get categoryName;
  @override

  /// 分类 URL
  String get categoryUrl;
  @override

  /// 已加载的书籍列表（累积去重）
  List<SearchBook> get books;
  @override

  /// 下一待抓取页码（对标 Android ExplorePaginationState.nextPage）
  int get page;
  @override

  /// 当前展示页码（对标 Android pageLiveData，0 表示尚未完成首次加载）
  int get displayPage;
  @override

  /// 是否正在加载
  bool get isLoading;
  @override

  /// 是否还有更多数据
  bool get hasMore;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$ExploreShowStateImplCopyWith<_$ExploreShowStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
