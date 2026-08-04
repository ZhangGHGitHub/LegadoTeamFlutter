// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'bookshelf_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$BookshelfState {
  /// Rust 返回的书籍列表（已排序，UI 层不做排序）
  List<Book> get books => throw _privateConstructorUsedError;

  /// 是否正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 展示层：网格/列表视图模式
  bool get isGridView => throw _privateConstructorUsedError;

  /// 展示层：分组显示模式
  GroupMode get groupMode => throw _privateConstructorUsedError;

  /// 用户偏好：是否显示最近阅读区域
  bool get showRecentReading => throw _privateConstructorUsedError;

  /// 用户偏好：是否显示阅读统计
  bool get showStats => throw _privateConstructorUsedError;

  /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
  List<BookGroup> get groups => throw _privateConstructorUsedError;

  /// 当前选中的分组 Tab 索引（对标原版 AppConfig.saveTabPosition）
  int get selectedGroupIndex => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $BookshelfStateCopyWith<BookshelfState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $BookshelfStateCopyWith<$Res> {
  factory $BookshelfStateCopyWith(
          BookshelfState value, $Res Function(BookshelfState) then) =
      _$BookshelfStateCopyWithImpl<$Res, BookshelfState>;
  @useResult
  $Res call(
      {List<Book> books,
      bool isLoading,
      String? error,
      bool isGridView,
      GroupMode groupMode,
      bool showRecentReading,
      bool showStats,
      List<BookGroup> groups,
      int selectedGroupIndex});
}

/// @nodoc
class _$BookshelfStateCopyWithImpl<$Res, $Val extends BookshelfState>
    implements $BookshelfStateCopyWith<$Res> {
  _$BookshelfStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? books = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? isGridView = null,
    Object? groupMode = null,
    Object? showRecentReading = null,
    Object? showStats = null,
    Object? groups = null,
    Object? selectedGroupIndex = null,
  }) {
    return _then(_value.copyWith(
      books: null == books
          ? _value.books
          : books // ignore: cast_nullable_to_non_nullable
              as List<Book>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      isGridView: null == isGridView
          ? _value.isGridView
          : isGridView // ignore: cast_nullable_to_non_nullable
              as bool,
      groupMode: null == groupMode
          ? _value.groupMode
          : groupMode // ignore: cast_nullable_to_non_nullable
              as GroupMode,
      showRecentReading: null == showRecentReading
          ? _value.showRecentReading
          : showRecentReading // ignore: cast_nullable_to_non_nullable
              as bool,
      showStats: null == showStats
          ? _value.showStats
          : showStats // ignore: cast_nullable_to_non_nullable
              as bool,
      groups: null == groups
          ? _value.groups
          : groups // ignore: cast_nullable_to_non_nullable
              as List<BookGroup>,
      selectedGroupIndex: null == selectedGroupIndex
          ? _value.selectedGroupIndex
          : selectedGroupIndex // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$BookshelfStateImplCopyWith<$Res>
    implements $BookshelfStateCopyWith<$Res> {
  factory _$$BookshelfStateImplCopyWith(_$BookshelfStateImpl value,
          $Res Function(_$BookshelfStateImpl) then) =
      __$$BookshelfStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<Book> books,
      bool isLoading,
      String? error,
      bool isGridView,
      GroupMode groupMode,
      bool showRecentReading,
      bool showStats,
      List<BookGroup> groups,
      int selectedGroupIndex});
}

/// @nodoc
class __$$BookshelfStateImplCopyWithImpl<$Res>
    extends _$BookshelfStateCopyWithImpl<$Res, _$BookshelfStateImpl>
    implements _$$BookshelfStateImplCopyWith<$Res> {
  __$$BookshelfStateImplCopyWithImpl(
      _$BookshelfStateImpl _value, $Res Function(_$BookshelfStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? books = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? isGridView = null,
    Object? groupMode = null,
    Object? showRecentReading = null,
    Object? showStats = null,
    Object? groups = null,
    Object? selectedGroupIndex = null,
  }) {
    return _then(_$BookshelfStateImpl(
      books: null == books
          ? _value._books
          : books // ignore: cast_nullable_to_non_nullable
              as List<Book>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      isGridView: null == isGridView
          ? _value.isGridView
          : isGridView // ignore: cast_nullable_to_non_nullable
              as bool,
      groupMode: null == groupMode
          ? _value.groupMode
          : groupMode // ignore: cast_nullable_to_non_nullable
              as GroupMode,
      showRecentReading: null == showRecentReading
          ? _value.showRecentReading
          : showRecentReading // ignore: cast_nullable_to_non_nullable
              as bool,
      showStats: null == showStats
          ? _value.showStats
          : showStats // ignore: cast_nullable_to_non_nullable
              as bool,
      groups: null == groups
          ? _value._groups
          : groups // ignore: cast_nullable_to_non_nullable
              as List<BookGroup>,
      selectedGroupIndex: null == selectedGroupIndex
          ? _value.selectedGroupIndex
          : selectedGroupIndex // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class _$BookshelfStateImpl implements _BookshelfState {
  const _$BookshelfStateImpl(
      {final List<Book> books = const [],
      this.isLoading = false,
      this.error,
      this.isGridView = true,
      this.groupMode = GroupMode.none,
      this.showRecentReading = true,
      this.showStats = true,
      final List<BookGroup> groups = const [],
      this.selectedGroupIndex = 0})
      : _books = books,
        _groups = groups;

  /// Rust 返回的书籍列表（已排序，UI 层不做排序）
  final List<Book> _books;

  /// Rust 返回的书籍列表（已排序，UI 层不做排序）
  @override
  @JsonKey()
  List<Book> get books {
    if (_books is EqualUnmodifiableListView) return _books;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_books);
  }

  /// 是否正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  /// 展示层：网格/列表视图模式
  @override
  @JsonKey()
  final bool isGridView;

  /// 展示层：分组显示模式
  @override
  @JsonKey()
  final GroupMode groupMode;

  /// 用户偏好：是否显示最近阅读区域
  @override
  @JsonKey()
  final bool showRecentReading;

  /// 用户偏好：是否显示阅读统计
  @override
  @JsonKey()
  final bool showStats;

  /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
  final List<BookGroup> _groups;

  /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
  @override
  @JsonKey()
  List<BookGroup> get groups {
    if (_groups is EqualUnmodifiableListView) return _groups;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_groups);
  }

  /// 当前选中的分组 Tab 索引（对标原版 AppConfig.saveTabPosition）
  @override
  @JsonKey()
  final int selectedGroupIndex;

  @override
  String toString() {
    return 'BookshelfState(books: $books, isLoading: $isLoading, error: $error, isGridView: $isGridView, groupMode: $groupMode, showRecentReading: $showRecentReading, showStats: $showStats, groups: $groups, selectedGroupIndex: $selectedGroupIndex)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$BookshelfStateImpl &&
            const DeepCollectionEquality().equals(other._books, _books) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.isGridView, isGridView) ||
                other.isGridView == isGridView) &&
            (identical(other.groupMode, groupMode) ||
                other.groupMode == groupMode) &&
            (identical(other.showRecentReading, showRecentReading) ||
                other.showRecentReading == showRecentReading) &&
            (identical(other.showStats, showStats) ||
                other.showStats == showStats) &&
            const DeepCollectionEquality().equals(other._groups, _groups) &&
            (identical(other.selectedGroupIndex, selectedGroupIndex) ||
                other.selectedGroupIndex == selectedGroupIndex));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_books),
      isLoading,
      error,
      isGridView,
      groupMode,
      showRecentReading,
      showStats,
      const DeepCollectionEquality().hash(_groups),
      selectedGroupIndex);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$BookshelfStateImplCopyWith<_$BookshelfStateImpl> get copyWith =>
      __$$BookshelfStateImplCopyWithImpl<_$BookshelfStateImpl>(
          this, _$identity);
}

abstract class _BookshelfState implements BookshelfState {
  const factory _BookshelfState(
      {final List<Book> books,
      final bool isLoading,
      final String? error,
      final bool isGridView,
      final GroupMode groupMode,
      final bool showRecentReading,
      final bool showStats,
      final List<BookGroup> groups,
      final int selectedGroupIndex}) = _$BookshelfStateImpl;

  @override

  /// Rust 返回的书籍列表（已排序，UI 层不做排序）
  List<Book> get books;
  @override

  /// 是否正在加载
  bool get isLoading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 展示层：网格/列表视图模式
  bool get isGridView;
  @override

  /// 展示层：分组显示模式
  GroupMode get groupMode;
  @override

  /// 用户偏好：是否显示最近阅读区域
  bool get showRecentReading;
  @override

  /// 用户偏好：是否显示阅读统计
  bool get showStats;
  @override

  /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
  List<BookGroup> get groups;
  @override

  /// 当前选中的分组 Tab 索引（对标原版 AppConfig.saveTabPosition）
  int get selectedGroupIndex;
  @override
  @JsonKey(ignore: true)
  _$$BookshelfStateImplCopyWith<_$BookshelfStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
