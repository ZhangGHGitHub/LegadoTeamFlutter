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
  /// Rust 返回的书籍列表（原始顺序；展示层按设置排序）
  List<Book> get books => throw _privateConstructorUsedError;

  /// 是否正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 展示层：分组显示模式
  GroupMode get groupMode => throw _privateConstructorUsedError;

  /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
  List<BookGroup> get groups => throw _privateConstructorUsedError;

  /// 当前选中的分组 Tab 索引（对标原版 AppConfig.saveTabPosition）
  int get selectedGroupIndex => throw _privateConstructorUsedError;

  /// [UI_SYNC_REFACTOR T3] 批量选择模式（对齐参考 SelectionBottomBar 态）
  bool get isBatchMode => throw _privateConstructorUsedError;

  /// 批量选中的书籍 URL 集合
  Set<String> get selectedUrls => throw _privateConstructorUsedError;

  /// [批35] 标签内容 - 用户标签（`Book.customTag`）
  bool get showCustomTags => throw _privateConstructorUsedError;

  /// [批35] 标签内容 - 书源分类（`Book.kind`）
  bool get showSourceTags => throw _privateConstructorUsedError;

  /// [批35] 标签内容 - 字数（`Book.wordCount`）
  bool get showWordCount => throw _privateConstructorUsedError;

  /// [批9c] 单本私密 URL 快照（`privacyGetPrivateBookUrls`）
  ///
  /// 与 `Book.isPrivate` 取并集判定：列表接口可能滞后于刚写入的标记，
  /// 隐私服务快照是私密判定的真源（Rust 侧同库同事务）。
  Set<String> get privateBookUrls => throw _privateConstructorUsedError;

  /// [批9c] 私密分组 ID 快照（`privacyGetPrivateGroupIds`）
  Set<int> get privateGroupIds => throw _privateConstructorUsedError;

  /// [批9c] 私密标记是否已加载完成
  ///
  /// false 时书架先不渲染锁定态（列表与标记并行加载，避免闪烁）；
  /// 加载失败按「未锁定」处理，不误锁整库（见 PrivacyContentService）。
  bool get privacyLoaded => throw _privateConstructorUsedError;

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
      GroupMode groupMode,
      List<BookGroup> groups,
      int selectedGroupIndex,
      bool isBatchMode,
      Set<String> selectedUrls,
      bool showCustomTags,
      bool showSourceTags,
      bool showWordCount,
      Set<String> privateBookUrls,
      Set<int> privateGroupIds,
      bool privacyLoaded});
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
    Object? groupMode = null,
    Object? groups = null,
    Object? selectedGroupIndex = null,
    Object? isBatchMode = null,
    Object? selectedUrls = null,
    Object? showCustomTags = null,
    Object? showSourceTags = null,
    Object? showWordCount = null,
    Object? privateBookUrls = null,
    Object? privateGroupIds = null,
    Object? privacyLoaded = null,
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
      groupMode: null == groupMode
          ? _value.groupMode
          : groupMode // ignore: cast_nullable_to_non_nullable
              as GroupMode,
      groups: null == groups
          ? _value.groups
          : groups // ignore: cast_nullable_to_non_nullable
              as List<BookGroup>,
      selectedGroupIndex: null == selectedGroupIndex
          ? _value.selectedGroupIndex
          : selectedGroupIndex // ignore: cast_nullable_to_non_nullable
              as int,
      isBatchMode: null == isBatchMode
          ? _value.isBatchMode
          : isBatchMode // ignore: cast_nullable_to_non_nullable
              as bool,
      selectedUrls: null == selectedUrls
          ? _value.selectedUrls
          : selectedUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      showCustomTags: null == showCustomTags
          ? _value.showCustomTags
          : showCustomTags // ignore: cast_nullable_to_non_nullable
              as bool,
      showSourceTags: null == showSourceTags
          ? _value.showSourceTags
          : showSourceTags // ignore: cast_nullable_to_non_nullable
              as bool,
      showWordCount: null == showWordCount
          ? _value.showWordCount
          : showWordCount // ignore: cast_nullable_to_non_nullable
              as bool,
      privateBookUrls: null == privateBookUrls
          ? _value.privateBookUrls
          : privateBookUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      privateGroupIds: null == privateGroupIds
          ? _value.privateGroupIds
          : privateGroupIds // ignore: cast_nullable_to_non_nullable
              as Set<int>,
      privacyLoaded: null == privacyLoaded
          ? _value.privacyLoaded
          : privacyLoaded // ignore: cast_nullable_to_non_nullable
              as bool,
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
      GroupMode groupMode,
      List<BookGroup> groups,
      int selectedGroupIndex,
      bool isBatchMode,
      Set<String> selectedUrls,
      bool showCustomTags,
      bool showSourceTags,
      bool showWordCount,
      Set<String> privateBookUrls,
      Set<int> privateGroupIds,
      bool privacyLoaded});
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
    Object? groupMode = null,
    Object? groups = null,
    Object? selectedGroupIndex = null,
    Object? isBatchMode = null,
    Object? selectedUrls = null,
    Object? showCustomTags = null,
    Object? showSourceTags = null,
    Object? showWordCount = null,
    Object? privateBookUrls = null,
    Object? privateGroupIds = null,
    Object? privacyLoaded = null,
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
      groupMode: null == groupMode
          ? _value.groupMode
          : groupMode // ignore: cast_nullable_to_non_nullable
              as GroupMode,
      groups: null == groups
          ? _value._groups
          : groups // ignore: cast_nullable_to_non_nullable
              as List<BookGroup>,
      selectedGroupIndex: null == selectedGroupIndex
          ? _value.selectedGroupIndex
          : selectedGroupIndex // ignore: cast_nullable_to_non_nullable
              as int,
      isBatchMode: null == isBatchMode
          ? _value.isBatchMode
          : isBatchMode // ignore: cast_nullable_to_non_nullable
              as bool,
      selectedUrls: null == selectedUrls
          ? _value._selectedUrls
          : selectedUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      showCustomTags: null == showCustomTags
          ? _value.showCustomTags
          : showCustomTags // ignore: cast_nullable_to_non_nullable
              as bool,
      showSourceTags: null == showSourceTags
          ? _value.showSourceTags
          : showSourceTags // ignore: cast_nullable_to_non_nullable
              as bool,
      showWordCount: null == showWordCount
          ? _value.showWordCount
          : showWordCount // ignore: cast_nullable_to_non_nullable
              as bool,
      privateBookUrls: null == privateBookUrls
          ? _value._privateBookUrls
          : privateBookUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      privateGroupIds: null == privateGroupIds
          ? _value._privateGroupIds
          : privateGroupIds // ignore: cast_nullable_to_non_nullable
              as Set<int>,
      privacyLoaded: null == privacyLoaded
          ? _value.privacyLoaded
          : privacyLoaded // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _$BookshelfStateImpl implements _BookshelfState {
  const _$BookshelfStateImpl(
      {final List<Book> books = const [],
      this.isLoading = false,
      this.error,
      this.groupMode = GroupMode.none,
      final List<BookGroup> groups = const [],
      this.selectedGroupIndex = 0,
      this.isBatchMode = false,
      final Set<String> selectedUrls = const {},
      this.showCustomTags = true,
      this.showSourceTags = true,
      this.showWordCount = true,
      final Set<String> privateBookUrls = const <String>{},
      final Set<int> privateGroupIds = const <int>{},
      this.privacyLoaded = false})
      : _books = books,
        _groups = groups,
        _selectedUrls = selectedUrls,
        _privateBookUrls = privateBookUrls,
        _privateGroupIds = privateGroupIds;

  /// Rust 返回的书籍列表（原始顺序；展示层按设置排序）
  final List<Book> _books;

  /// Rust 返回的书籍列表（原始顺序；展示层按设置排序）
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

  /// 展示层：分组显示模式
  @override
  @JsonKey()
  final GroupMode groupMode;

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

  /// [UI_SYNC_REFACTOR T3] 批量选择模式（对齐参考 SelectionBottomBar 态）
  @override
  @JsonKey()
  final bool isBatchMode;

  /// 批量选中的书籍 URL 集合
  final Set<String> _selectedUrls;

  /// 批量选中的书籍 URL 集合
  @override
  @JsonKey()
  Set<String> get selectedUrls {
    if (_selectedUrls is EqualUnmodifiableSetView) return _selectedUrls;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_selectedUrls);
  }

  /// [批35] 标签内容 - 用户标签（`Book.customTag`）
  @override
  @JsonKey()
  final bool showCustomTags;

  /// [批35] 标签内容 - 书源分类（`Book.kind`）
  @override
  @JsonKey()
  final bool showSourceTags;

  /// [批35] 标签内容 - 字数（`Book.wordCount`）
  @override
  @JsonKey()
  final bool showWordCount;

  /// [批9c] 单本私密 URL 快照（`privacyGetPrivateBookUrls`）
  ///
  /// 与 `Book.isPrivate` 取并集判定：列表接口可能滞后于刚写入的标记，
  /// 隐私服务快照是私密判定的真源（Rust 侧同库同事务）。
  final Set<String> _privateBookUrls;

  /// [批9c] 单本私密 URL 快照（`privacyGetPrivateBookUrls`）
  ///
  /// 与 `Book.isPrivate` 取并集判定：列表接口可能滞后于刚写入的标记，
  /// 隐私服务快照是私密判定的真源（Rust 侧同库同事务）。
  @override
  @JsonKey()
  Set<String> get privateBookUrls {
    if (_privateBookUrls is EqualUnmodifiableSetView) return _privateBookUrls;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_privateBookUrls);
  }

  /// [批9c] 私密分组 ID 快照（`privacyGetPrivateGroupIds`）
  final Set<int> _privateGroupIds;

  /// [批9c] 私密分组 ID 快照（`privacyGetPrivateGroupIds`）
  @override
  @JsonKey()
  Set<int> get privateGroupIds {
    if (_privateGroupIds is EqualUnmodifiableSetView) return _privateGroupIds;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_privateGroupIds);
  }

  /// [批9c] 私密标记是否已加载完成
  ///
  /// false 时书架先不渲染锁定态（列表与标记并行加载，避免闪烁）；
  /// 加载失败按「未锁定」处理，不误锁整库（见 PrivacyContentService）。
  @override
  @JsonKey()
  final bool privacyLoaded;

  @override
  String toString() {
    return 'BookshelfState(books: $books, isLoading: $isLoading, error: $error, groupMode: $groupMode, groups: $groups, selectedGroupIndex: $selectedGroupIndex, isBatchMode: $isBatchMode, selectedUrls: $selectedUrls, showCustomTags: $showCustomTags, showSourceTags: $showSourceTags, showWordCount: $showWordCount, privateBookUrls: $privateBookUrls, privateGroupIds: $privateGroupIds, privacyLoaded: $privacyLoaded)';
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
            (identical(other.groupMode, groupMode) ||
                other.groupMode == groupMode) &&
            const DeepCollectionEquality().equals(other._groups, _groups) &&
            (identical(other.selectedGroupIndex, selectedGroupIndex) ||
                other.selectedGroupIndex == selectedGroupIndex) &&
            (identical(other.isBatchMode, isBatchMode) ||
                other.isBatchMode == isBatchMode) &&
            const DeepCollectionEquality()
                .equals(other._selectedUrls, _selectedUrls) &&
            (identical(other.showCustomTags, showCustomTags) ||
                other.showCustomTags == showCustomTags) &&
            (identical(other.showSourceTags, showSourceTags) ||
                other.showSourceTags == showSourceTags) &&
            (identical(other.showWordCount, showWordCount) ||
                other.showWordCount == showWordCount) &&
            const DeepCollectionEquality()
                .equals(other._privateBookUrls, _privateBookUrls) &&
            const DeepCollectionEquality()
                .equals(other._privateGroupIds, _privateGroupIds) &&
            (identical(other.privacyLoaded, privacyLoaded) ||
                other.privacyLoaded == privacyLoaded));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_books),
      isLoading,
      error,
      groupMode,
      const DeepCollectionEquality().hash(_groups),
      selectedGroupIndex,
      isBatchMode,
      const DeepCollectionEquality().hash(_selectedUrls),
      showCustomTags,
      showSourceTags,
      showWordCount,
      const DeepCollectionEquality().hash(_privateBookUrls),
      const DeepCollectionEquality().hash(_privateGroupIds),
      privacyLoaded);

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
      final GroupMode groupMode,
      final List<BookGroup> groups,
      final int selectedGroupIndex,
      final bool isBatchMode,
      final Set<String> selectedUrls,
      final bool showCustomTags,
      final bool showSourceTags,
      final bool showWordCount,
      final Set<String> privateBookUrls,
      final Set<int> privateGroupIds,
      final bool privacyLoaded}) = _$BookshelfStateImpl;

  @override

  /// Rust 返回的书籍列表（原始顺序；展示层按设置排序）
  List<Book> get books;
  @override

  /// 是否正在加载
  bool get isLoading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 展示层：分组显示模式
  GroupMode get groupMode;
  @override

  /// 书籍分组列表（对标原版 BookGroup，顶栏 Tab 数据源）
  List<BookGroup> get groups;
  @override

  /// 当前选中的分组 Tab 索引（对标原版 AppConfig.saveTabPosition）
  int get selectedGroupIndex;
  @override

  /// [UI_SYNC_REFACTOR T3] 批量选择模式（对齐参考 SelectionBottomBar 态）
  bool get isBatchMode;
  @override

  /// 批量选中的书籍 URL 集合
  Set<String> get selectedUrls;
  @override

  /// [批35] 标签内容 - 用户标签（`Book.customTag`）
  bool get showCustomTags;
  @override

  /// [批35] 标签内容 - 书源分类（`Book.kind`）
  bool get showSourceTags;
  @override

  /// [批35] 标签内容 - 字数（`Book.wordCount`）
  bool get showWordCount;
  @override

  /// [批9c] 单本私密 URL 快照（`privacyGetPrivateBookUrls`）
  ///
  /// 与 `Book.isPrivate` 取并集判定：列表接口可能滞后于刚写入的标记，
  /// 隐私服务快照是私密判定的真源（Rust 侧同库同事务）。
  Set<String> get privateBookUrls;
  @override

  /// [批9c] 私密分组 ID 快照（`privacyGetPrivateGroupIds`）
  Set<int> get privateGroupIds;
  @override

  /// [批9c] 私密标记是否已加载完成
  ///
  /// false 时书架先不渲染锁定态（列表与标记并行加载，避免闪烁）；
  /// 加载失败按「未锁定」处理，不误锁整库（见 PrivacyContentService）。
  bool get privacyLoaded;
  @override
  @JsonKey(ignore: true)
  _$$BookshelfStateImplCopyWith<_$BookshelfStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
