// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'reader_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ReaderState {
  /// 当前阅读的书籍
  Book? get currentBook => throw _privateConstructorUsedError;

  /// 章节目录列表（Rust 返回，已排序）
  List<BookChapter> get chapters => throw _privateConstructorUsedError;

  /// 当前章节索引
  int get currentChapterIndex => throw _privateConstructorUsedError;

  /// 当前章节内阅读位置
  int get currentChapterPos => throw _privateConstructorUsedError;

  /// 当前章节正文（Rust 已完成净化/替换的最终文本）
  String get chapterContent => throw _privateConstructorUsedError;

  /// 是否正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 工具栏是否显示
  bool get showControls =>
      throw _privateConstructorUsedError; // ===== 阅读设置 =====
  /// 字体大小
  double get fontSize => throw _privateConstructorUsedError;

  /// 行高倍数
  double get lineHeight => throw _privateConstructorUsedError;

  /// 背景色
  Color get backgroundColor => throw _privateConstructorUsedError;

  /// 翻页模式
  PageTurnMode get pageTurnMode =>
      throw _privateConstructorUsedError; // ===== 跨章节连续分页 =====
  /// 全局页索引（跨章节连续编号，从 0 开始）
  int get globalPageIndex => throw _privateConstructorUsedError;

  /// 全局总页数（所有章节页数之和）
  int get totalPages => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ReaderStateCopyWith<ReaderState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ReaderStateCopyWith<$Res> {
  factory $ReaderStateCopyWith(
          ReaderState value, $Res Function(ReaderState) then) =
      _$ReaderStateCopyWithImpl<$Res, ReaderState>;
  @useResult
  $Res call(
      {Book? currentBook,
      List<BookChapter> chapters,
      int currentChapterIndex,
      int currentChapterPos,
      String chapterContent,
      bool isLoading,
      String? error,
      bool showControls,
      double fontSize,
      double lineHeight,
      Color backgroundColor,
      PageTurnMode pageTurnMode,
      int globalPageIndex,
      int totalPages});

  $BookCopyWith<$Res>? get currentBook;
}

/// @nodoc
class _$ReaderStateCopyWithImpl<$Res, $Val extends ReaderState>
    implements $ReaderStateCopyWith<$Res> {
  _$ReaderStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? currentBook = freezed,
    Object? chapters = null,
    Object? currentChapterIndex = null,
    Object? currentChapterPos = null,
    Object? chapterContent = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? showControls = null,
    Object? fontSize = null,
    Object? lineHeight = null,
    Object? backgroundColor = null,
    Object? pageTurnMode = null,
    Object? globalPageIndex = null,
    Object? totalPages = null,
  }) {
    return _then(_value.copyWith(
      currentBook: freezed == currentBook
          ? _value.currentBook
          : currentBook // ignore: cast_nullable_to_non_nullable
              as Book?,
      chapters: null == chapters
          ? _value.chapters
          : chapters // ignore: cast_nullable_to_non_nullable
              as List<BookChapter>,
      currentChapterIndex: null == currentChapterIndex
          ? _value.currentChapterIndex
          : currentChapterIndex // ignore: cast_nullable_to_non_nullable
              as int,
      currentChapterPos: null == currentChapterPos
          ? _value.currentChapterPos
          : currentChapterPos // ignore: cast_nullable_to_non_nullable
              as int,
      chapterContent: null == chapterContent
          ? _value.chapterContent
          : chapterContent // ignore: cast_nullable_to_non_nullable
              as String,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      showControls: null == showControls
          ? _value.showControls
          : showControls // ignore: cast_nullable_to_non_nullable
              as bool,
      fontSize: null == fontSize
          ? _value.fontSize
          : fontSize // ignore: cast_nullable_to_non_nullable
              as double,
      lineHeight: null == lineHeight
          ? _value.lineHeight
          : lineHeight // ignore: cast_nullable_to_non_nullable
              as double,
      backgroundColor: null == backgroundColor
          ? _value.backgroundColor
          : backgroundColor // ignore: cast_nullable_to_non_nullable
              as Color,
      pageTurnMode: null == pageTurnMode
          ? _value.pageTurnMode
          : pageTurnMode // ignore: cast_nullable_to_non_nullable
              as PageTurnMode,
      globalPageIndex: null == globalPageIndex
          ? _value.globalPageIndex
          : globalPageIndex // ignore: cast_nullable_to_non_nullable
              as int,
      totalPages: null == totalPages
          ? _value.totalPages
          : totalPages // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }

  @override
  @pragma('vm:prefer-inline')
  $BookCopyWith<$Res>? get currentBook {
    if (_value.currentBook == null) {
      return null;
    }

    return $BookCopyWith<$Res>(_value.currentBook!, (value) {
      return _then(_value.copyWith(currentBook: value) as $Val);
    });
  }
}

/// @nodoc
abstract class _$$ReaderStateImplCopyWith<$Res>
    implements $ReaderStateCopyWith<$Res> {
  factory _$$ReaderStateImplCopyWith(
          _$ReaderStateImpl value, $Res Function(_$ReaderStateImpl) then) =
      __$$ReaderStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {Book? currentBook,
      List<BookChapter> chapters,
      int currentChapterIndex,
      int currentChapterPos,
      String chapterContent,
      bool isLoading,
      String? error,
      bool showControls,
      double fontSize,
      double lineHeight,
      Color backgroundColor,
      PageTurnMode pageTurnMode,
      int globalPageIndex,
      int totalPages});

  @override
  $BookCopyWith<$Res>? get currentBook;
}

/// @nodoc
class __$$ReaderStateImplCopyWithImpl<$Res>
    extends _$ReaderStateCopyWithImpl<$Res, _$ReaderStateImpl>
    implements _$$ReaderStateImplCopyWith<$Res> {
  __$$ReaderStateImplCopyWithImpl(
      _$ReaderStateImpl _value, $Res Function(_$ReaderStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? currentBook = freezed,
    Object? chapters = null,
    Object? currentChapterIndex = null,
    Object? currentChapterPos = null,
    Object? chapterContent = null,
    Object? isLoading = null,
    Object? error = freezed,
    Object? showControls = null,
    Object? fontSize = null,
    Object? lineHeight = null,
    Object? backgroundColor = null,
    Object? pageTurnMode = null,
    Object? globalPageIndex = null,
    Object? totalPages = null,
  }) {
    return _then(_$ReaderStateImpl(
      currentBook: freezed == currentBook
          ? _value.currentBook
          : currentBook // ignore: cast_nullable_to_non_nullable
              as Book?,
      chapters: null == chapters
          ? _value._chapters
          : chapters // ignore: cast_nullable_to_non_nullable
              as List<BookChapter>,
      currentChapterIndex: null == currentChapterIndex
          ? _value.currentChapterIndex
          : currentChapterIndex // ignore: cast_nullable_to_non_nullable
              as int,
      currentChapterPos: null == currentChapterPos
          ? _value.currentChapterPos
          : currentChapterPos // ignore: cast_nullable_to_non_nullable
              as int,
      chapterContent: null == chapterContent
          ? _value.chapterContent
          : chapterContent // ignore: cast_nullable_to_non_nullable
              as String,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      showControls: null == showControls
          ? _value.showControls
          : showControls // ignore: cast_nullable_to_non_nullable
              as bool,
      fontSize: null == fontSize
          ? _value.fontSize
          : fontSize // ignore: cast_nullable_to_non_nullable
              as double,
      lineHeight: null == lineHeight
          ? _value.lineHeight
          : lineHeight // ignore: cast_nullable_to_non_nullable
              as double,
      backgroundColor: null == backgroundColor
          ? _value.backgroundColor
          : backgroundColor // ignore: cast_nullable_to_non_nullable
              as Color,
      pageTurnMode: null == pageTurnMode
          ? _value.pageTurnMode
          : pageTurnMode // ignore: cast_nullable_to_non_nullable
              as PageTurnMode,
      globalPageIndex: null == globalPageIndex
          ? _value.globalPageIndex
          : globalPageIndex // ignore: cast_nullable_to_non_nullable
              as int,
      totalPages: null == totalPages
          ? _value.totalPages
          : totalPages // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class _$ReaderStateImpl implements _ReaderState {
  const _$ReaderStateImpl(
      {this.currentBook,
      final List<BookChapter> chapters = const [],
      this.currentChapterIndex = 0,
      this.currentChapterPos = 0,
      this.chapterContent = '',
      this.isLoading = false,
      this.error,
      this.showControls = false,
      this.fontSize = 18.0,
      this.lineHeight = 1.6,
      this.backgroundColor = ReaderBackground.white,
      this.pageTurnMode = PageTurnMode.cover,
      this.globalPageIndex = 0,
      this.totalPages = 0})
      : _chapters = chapters;

  /// 当前阅读的书籍
  @override
  final Book? currentBook;

  /// 章节目录列表（Rust 返回，已排序）
  final List<BookChapter> _chapters;

  /// 章节目录列表（Rust 返回，已排序）
  @override
  @JsonKey()
  List<BookChapter> get chapters {
    if (_chapters is EqualUnmodifiableListView) return _chapters;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_chapters);
  }

  /// 当前章节索引
  @override
  @JsonKey()
  final int currentChapterIndex;

  /// 当前章节内阅读位置
  @override
  @JsonKey()
  final int currentChapterPos;

  /// 当前章节正文（Rust 已完成净化/替换的最终文本）
  @override
  @JsonKey()
  final String chapterContent;

  /// 是否正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  /// 工具栏是否显示
  @override
  @JsonKey()
  final bool showControls;
// ===== 阅读设置 =====
  /// 字体大小
  @override
  @JsonKey()
  final double fontSize;

  /// 行高倍数
  @override
  @JsonKey()
  final double lineHeight;

  /// 背景色
  @override
  @JsonKey()
  final Color backgroundColor;

  /// 翻页模式
  @override
  @JsonKey()
  final PageTurnMode pageTurnMode;
// ===== 跨章节连续分页 =====
  /// 全局页索引（跨章节连续编号，从 0 开始）
  @override
  @JsonKey()
  final int globalPageIndex;

  /// 全局总页数（所有章节页数之和）
  @override
  @JsonKey()
  final int totalPages;

  @override
  String toString() {
    return 'ReaderState(currentBook: $currentBook, chapters: $chapters, currentChapterIndex: $currentChapterIndex, currentChapterPos: $currentChapterPos, chapterContent: $chapterContent, isLoading: $isLoading, error: $error, showControls: $showControls, fontSize: $fontSize, lineHeight: $lineHeight, backgroundColor: $backgroundColor, pageTurnMode: $pageTurnMode, globalPageIndex: $globalPageIndex, totalPages: $totalPages)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ReaderStateImpl &&
            (identical(other.currentBook, currentBook) ||
                other.currentBook == currentBook) &&
            const DeepCollectionEquality().equals(other._chapters, _chapters) &&
            (identical(other.currentChapterIndex, currentChapterIndex) ||
                other.currentChapterIndex == currentChapterIndex) &&
            (identical(other.currentChapterPos, currentChapterPos) ||
                other.currentChapterPos == currentChapterPos) &&
            (identical(other.chapterContent, chapterContent) ||
                other.chapterContent == chapterContent) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.showControls, showControls) ||
                other.showControls == showControls) &&
            (identical(other.fontSize, fontSize) ||
                other.fontSize == fontSize) &&
            (identical(other.lineHeight, lineHeight) ||
                other.lineHeight == lineHeight) &&
            (identical(other.backgroundColor, backgroundColor) ||
                other.backgroundColor == backgroundColor) &&
            (identical(other.pageTurnMode, pageTurnMode) ||
                other.pageTurnMode == pageTurnMode) &&
            (identical(other.globalPageIndex, globalPageIndex) ||
                other.globalPageIndex == globalPageIndex) &&
            (identical(other.totalPages, totalPages) ||
                other.totalPages == totalPages));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      currentBook,
      const DeepCollectionEquality().hash(_chapters),
      currentChapterIndex,
      currentChapterPos,
      chapterContent,
      isLoading,
      error,
      showControls,
      fontSize,
      lineHeight,
      backgroundColor,
      pageTurnMode,
      globalPageIndex,
      totalPages);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ReaderStateImplCopyWith<_$ReaderStateImpl> get copyWith =>
      __$$ReaderStateImplCopyWithImpl<_$ReaderStateImpl>(this, _$identity);
}

abstract class _ReaderState implements ReaderState {
  const factory _ReaderState(
      {final Book? currentBook,
      final List<BookChapter> chapters,
      final int currentChapterIndex,
      final int currentChapterPos,
      final String chapterContent,
      final bool isLoading,
      final String? error,
      final bool showControls,
      final double fontSize,
      final double lineHeight,
      final Color backgroundColor,
      final PageTurnMode pageTurnMode,
      final int globalPageIndex,
      final int totalPages}) = _$ReaderStateImpl;

  @override

  /// 当前阅读的书籍
  Book? get currentBook;
  @override

  /// 章节目录列表（Rust 返回，已排序）
  List<BookChapter> get chapters;
  @override

  /// 当前章节索引
  int get currentChapterIndex;
  @override

  /// 当前章节内阅读位置
  int get currentChapterPos;
  @override

  /// 当前章节正文（Rust 已完成净化/替换的最终文本）
  String get chapterContent;
  @override

  /// 是否正在加载
  bool get isLoading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 工具栏是否显示
  bool get showControls;
  @override // ===== 阅读设置 =====
  /// 字体大小
  double get fontSize;
  @override

  /// 行高倍数
  double get lineHeight;
  @override

  /// 背景色
  Color get backgroundColor;
  @override

  /// 翻页模式
  PageTurnMode get pageTurnMode;
  @override // ===== 跨章节连续分页 =====
  /// 全局页索引（跨章节连续编号，从 0 开始）
  int get globalPageIndex;
  @override

  /// 全局总页数（所有章节页数之和）
  int get totalPages;
  @override
  @JsonKey(ignore: true)
  _$$ReaderStateImplCopyWith<_$ReaderStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
