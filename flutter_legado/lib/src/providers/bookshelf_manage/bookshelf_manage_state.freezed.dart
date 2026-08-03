// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'bookshelf_manage_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$BookshelfManageState {
  /// 书架书籍列表
  List<Book> get books => throw _privateConstructorUsedError;

  /// 已勾选书籍的 bookUrl 集合
  Set<String> get selectedUrls => throw _privateConstructorUsedError;

  /// 正在加载
  bool get isLoading => throw _privateConstructorUsedError;

  /// 正在执行批量操作
  bool get isBusy => throw _privateConstructorUsedError;

  /// 错误信息
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $BookshelfManageStateCopyWith<BookshelfManageState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $BookshelfManageStateCopyWith<$Res> {
  factory $BookshelfManageStateCopyWith(BookshelfManageState value,
          $Res Function(BookshelfManageState) then) =
      _$BookshelfManageStateCopyWithImpl<$Res, BookshelfManageState>;
  @useResult
  $Res call(
      {List<Book> books,
      Set<String> selectedUrls,
      bool isLoading,
      bool isBusy,
      String? error});
}

/// @nodoc
class _$BookshelfManageStateCopyWithImpl<$Res,
        $Val extends BookshelfManageState>
    implements $BookshelfManageStateCopyWith<$Res> {
  _$BookshelfManageStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? books = null,
    Object? selectedUrls = null,
    Object? isLoading = null,
    Object? isBusy = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      books: null == books
          ? _value.books
          : books // ignore: cast_nullable_to_non_nullable
              as List<Book>,
      selectedUrls: null == selectedUrls
          ? _value.selectedUrls
          : selectedUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      isBusy: null == isBusy
          ? _value.isBusy
          : isBusy // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$BookshelfManageStateImplCopyWith<$Res>
    implements $BookshelfManageStateCopyWith<$Res> {
  factory _$$BookshelfManageStateImplCopyWith(_$BookshelfManageStateImpl value,
          $Res Function(_$BookshelfManageStateImpl) then) =
      __$$BookshelfManageStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<Book> books,
      Set<String> selectedUrls,
      bool isLoading,
      bool isBusy,
      String? error});
}

/// @nodoc
class __$$BookshelfManageStateImplCopyWithImpl<$Res>
    extends _$BookshelfManageStateCopyWithImpl<$Res, _$BookshelfManageStateImpl>
    implements _$$BookshelfManageStateImplCopyWith<$Res> {
  __$$BookshelfManageStateImplCopyWithImpl(_$BookshelfManageStateImpl _value,
      $Res Function(_$BookshelfManageStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? books = null,
    Object? selectedUrls = null,
    Object? isLoading = null,
    Object? isBusy = null,
    Object? error = freezed,
  }) {
    return _then(_$BookshelfManageStateImpl(
      books: null == books
          ? _value._books
          : books // ignore: cast_nullable_to_non_nullable
              as List<Book>,
      selectedUrls: null == selectedUrls
          ? _value._selectedUrls
          : selectedUrls // ignore: cast_nullable_to_non_nullable
              as Set<String>,
      isLoading: null == isLoading
          ? _value.isLoading
          : isLoading // ignore: cast_nullable_to_non_nullable
              as bool,
      isBusy: null == isBusy
          ? _value.isBusy
          : isBusy // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$BookshelfManageStateImpl implements _BookshelfManageState {
  const _$BookshelfManageStateImpl(
      {final List<Book> books = const [],
      final Set<String> selectedUrls = const {},
      this.isLoading = false,
      this.isBusy = false,
      this.error})
      : _books = books,
        _selectedUrls = selectedUrls;

  /// 书架书籍列表
  final List<Book> _books;

  /// 书架书籍列表
  @override
  @JsonKey()
  List<Book> get books {
    if (_books is EqualUnmodifiableListView) return _books;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_books);
  }

  /// 已勾选书籍的 bookUrl 集合
  final Set<String> _selectedUrls;

  /// 已勾选书籍的 bookUrl 集合
  @override
  @JsonKey()
  Set<String> get selectedUrls {
    if (_selectedUrls is EqualUnmodifiableSetView) return _selectedUrls;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableSetView(_selectedUrls);
  }

  /// 正在加载
  @override
  @JsonKey()
  final bool isLoading;

  /// 正在执行批量操作
  @override
  @JsonKey()
  final bool isBusy;

  /// 错误信息
  @override
  final String? error;

  @override
  String toString() {
    return 'BookshelfManageState(books: $books, selectedUrls: $selectedUrls, isLoading: $isLoading, isBusy: $isBusy, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$BookshelfManageStateImpl &&
            const DeepCollectionEquality().equals(other._books, _books) &&
            const DeepCollectionEquality()
                .equals(other._selectedUrls, _selectedUrls) &&
            (identical(other.isLoading, isLoading) ||
                other.isLoading == isLoading) &&
            (identical(other.isBusy, isBusy) || other.isBusy == isBusy) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_books),
      const DeepCollectionEquality().hash(_selectedUrls),
      isLoading,
      isBusy,
      error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$BookshelfManageStateImplCopyWith<_$BookshelfManageStateImpl>
      get copyWith =>
          __$$BookshelfManageStateImplCopyWithImpl<_$BookshelfManageStateImpl>(
              this, _$identity);
}

abstract class _BookshelfManageState implements BookshelfManageState {
  const factory _BookshelfManageState(
      {final List<Book> books,
      final Set<String> selectedUrls,
      final bool isLoading,
      final bool isBusy,
      final String? error}) = _$BookshelfManageStateImpl;

  @override

  /// 书架书籍列表
  List<Book> get books;
  @override

  /// 已勾选书籍的 bookUrl 集合
  Set<String> get selectedUrls;
  @override

  /// 正在加载
  bool get isLoading;
  @override

  /// 正在执行批量操作
  bool get isBusy;
  @override

  /// 错误信息
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$BookshelfManageStateImplCopyWith<_$BookshelfManageStateImpl>
      get copyWith => throw _privateConstructorUsedError;
}
