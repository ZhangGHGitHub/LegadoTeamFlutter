// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'rss_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$RssState {
  /// 全部 RSS 源列表
  List<RssSource> get sources => throw _privateConstructorUsedError;

  /// 当前选中源的文章列表
  List<RssFeedArticle> get articles => throw _privateConstructorUsedError;

  /// 当前选中的源（null 表示未选中）
  RssSource? get selectedSource => throw _privateConstructorUsedError;

  /// 是否正在加载源列表
  bool get isLoadingSources => throw _privateConstructorUsedError;

  /// 是否正在加载文章列表
  bool get isLoadingArticles => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  /// 当前选中的分组筛选；null 表示「全部」
  String? get selectedGroup => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $RssStateCopyWith<RssState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $RssStateCopyWith<$Res> {
  factory $RssStateCopyWith(RssState value, $Res Function(RssState) then) =
      _$RssStateCopyWithImpl<$Res, RssState>;
  @useResult
  $Res call(
      {List<RssSource> sources,
      List<RssFeedArticle> articles,
      RssSource? selectedSource,
      bool isLoadingSources,
      bool isLoadingArticles,
      String? error,
      String? selectedGroup});

  $RssSourceCopyWith<$Res>? get selectedSource;
}

/// @nodoc
class _$RssStateCopyWithImpl<$Res, $Val extends RssState>
    implements $RssStateCopyWith<$Res> {
  _$RssStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? sources = null,
    Object? articles = null,
    Object? selectedSource = freezed,
    Object? isLoadingSources = null,
    Object? isLoadingArticles = null,
    Object? error = freezed,
    Object? selectedGroup = freezed,
  }) {
    return _then(_value.copyWith(
      sources: null == sources
          ? _value.sources
          : sources // ignore: cast_nullable_to_non_nullable
              as List<RssSource>,
      articles: null == articles
          ? _value.articles
          : articles // ignore: cast_nullable_to_non_nullable
              as List<RssFeedArticle>,
      selectedSource: freezed == selectedSource
          ? _value.selectedSource
          : selectedSource // ignore: cast_nullable_to_non_nullable
              as RssSource?,
      isLoadingSources: null == isLoadingSources
          ? _value.isLoadingSources
          : isLoadingSources // ignore: cast_nullable_to_non_nullable
              as bool,
      isLoadingArticles: null == isLoadingArticles
          ? _value.isLoadingArticles
          : isLoadingArticles // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      selectedGroup: freezed == selectedGroup
          ? _value.selectedGroup
          : selectedGroup // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }

  @override
  @pragma('vm:prefer-inline')
  $RssSourceCopyWith<$Res>? get selectedSource {
    if (_value.selectedSource == null) {
      return null;
    }

    return $RssSourceCopyWith<$Res>(_value.selectedSource!, (value) {
      return _then(_value.copyWith(selectedSource: value) as $Val);
    });
  }
}

/// @nodoc
abstract class _$$RssStateImplCopyWith<$Res>
    implements $RssStateCopyWith<$Res> {
  factory _$$RssStateImplCopyWith(
          _$RssStateImpl value, $Res Function(_$RssStateImpl) then) =
      __$$RssStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {List<RssSource> sources,
      List<RssFeedArticle> articles,
      RssSource? selectedSource,
      bool isLoadingSources,
      bool isLoadingArticles,
      String? error,
      String? selectedGroup});

  @override
  $RssSourceCopyWith<$Res>? get selectedSource;
}

/// @nodoc
class __$$RssStateImplCopyWithImpl<$Res>
    extends _$RssStateCopyWithImpl<$Res, _$RssStateImpl>
    implements _$$RssStateImplCopyWith<$Res> {
  __$$RssStateImplCopyWithImpl(
      _$RssStateImpl _value, $Res Function(_$RssStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? sources = null,
    Object? articles = null,
    Object? selectedSource = freezed,
    Object? isLoadingSources = null,
    Object? isLoadingArticles = null,
    Object? error = freezed,
    Object? selectedGroup = freezed,
  }) {
    return _then(_$RssStateImpl(
      sources: null == sources
          ? _value._sources
          : sources // ignore: cast_nullable_to_non_nullable
              as List<RssSource>,
      articles: null == articles
          ? _value._articles
          : articles // ignore: cast_nullable_to_non_nullable
              as List<RssFeedArticle>,
      selectedSource: freezed == selectedSource
          ? _value.selectedSource
          : selectedSource // ignore: cast_nullable_to_non_nullable
              as RssSource?,
      isLoadingSources: null == isLoadingSources
          ? _value.isLoadingSources
          : isLoadingSources // ignore: cast_nullable_to_non_nullable
              as bool,
      isLoadingArticles: null == isLoadingArticles
          ? _value.isLoadingArticles
          : isLoadingArticles // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
      selectedGroup: freezed == selectedGroup
          ? _value.selectedGroup
          : selectedGroup // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$RssStateImpl implements _RssState {
  const _$RssStateImpl(
      {final List<RssSource> sources = const [],
      final List<RssFeedArticle> articles = const [],
      this.selectedSource,
      this.isLoadingSources = false,
      this.isLoadingArticles = false,
      this.error,
      this.selectedGroup})
      : _sources = sources,
        _articles = articles;

  /// 全部 RSS 源列表
  final List<RssSource> _sources;

  /// 全部 RSS 源列表
  @override
  @JsonKey()
  List<RssSource> get sources {
    if (_sources is EqualUnmodifiableListView) return _sources;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_sources);
  }

  /// 当前选中源的文章列表
  final List<RssFeedArticle> _articles;

  /// 当前选中源的文章列表
  @override
  @JsonKey()
  List<RssFeedArticle> get articles {
    if (_articles is EqualUnmodifiableListView) return _articles;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_articles);
  }

  /// 当前选中的源（null 表示未选中）
  @override
  final RssSource? selectedSource;

  /// 是否正在加载源列表
  @override
  @JsonKey()
  final bool isLoadingSources;

  /// 是否正在加载文章列表
  @override
  @JsonKey()
  final bool isLoadingArticles;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  /// 当前选中的分组筛选；null 表示「全部」
  @override
  final String? selectedGroup;

  @override
  String toString() {
    return 'RssState(sources: $sources, articles: $articles, selectedSource: $selectedSource, isLoadingSources: $isLoadingSources, isLoadingArticles: $isLoadingArticles, error: $error, selectedGroup: $selectedGroup)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$RssStateImpl &&
            const DeepCollectionEquality().equals(other._sources, _sources) &&
            const DeepCollectionEquality().equals(other._articles, _articles) &&
            (identical(other.selectedSource, selectedSource) ||
                other.selectedSource == selectedSource) &&
            (identical(other.isLoadingSources, isLoadingSources) ||
                other.isLoadingSources == isLoadingSources) &&
            (identical(other.isLoadingArticles, isLoadingArticles) ||
                other.isLoadingArticles == isLoadingArticles) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.selectedGroup, selectedGroup) ||
                other.selectedGroup == selectedGroup));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_sources),
      const DeepCollectionEquality().hash(_articles),
      selectedSource,
      isLoadingSources,
      isLoadingArticles,
      error,
      selectedGroup);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$RssStateImplCopyWith<_$RssStateImpl> get copyWith =>
      __$$RssStateImplCopyWithImpl<_$RssStateImpl>(this, _$identity);
}

abstract class _RssState implements RssState {
  const factory _RssState(
      {final List<RssSource> sources,
      final List<RssFeedArticle> articles,
      final RssSource? selectedSource,
      final bool isLoadingSources,
      final bool isLoadingArticles,
      final String? error,
      final String? selectedGroup}) = _$RssStateImpl;

  @override

  /// 全部 RSS 源列表
  List<RssSource> get sources;
  @override

  /// 当前选中源的文章列表
  List<RssFeedArticle> get articles;
  @override

  /// 当前选中的源（null 表示未选中）
  RssSource? get selectedSource;
  @override

  /// 是否正在加载源列表
  bool get isLoadingSources;
  @override

  /// 是否正在加载文章列表
  bool get isLoadingArticles;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override

  /// 当前选中的分组筛选；null 表示「全部」
  String? get selectedGroup;
  @override
  @JsonKey(ignore: true)
  _$$RssStateImplCopyWith<_$RssStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
