// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'book_source.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

BookSource _$BookSourceFromJson(Map<String, dynamic> json) {
  return _BookSource.fromJson(json);
}

/// @nodoc
mixin _$BookSource {
  @JsonKey(name: 'bookSourceUrl')
  String get bookSourceUrl => throw _privateConstructorUsedError;
  @JsonKey(name: 'bookSourceName')
  String get bookSourceName => throw _privateConstructorUsedError;
  @JsonKey(name: 'bookSourceGroup')
  String? get bookSourceGroup => throw _privateConstructorUsedError;
  @JsonKey(name: 'bookSourceType')
  int get bookSourceType => throw _privateConstructorUsedError;
  @JsonKey(name: 'bookUrlPattern')
  String? get bookUrlPattern => throw _privateConstructorUsedError;
  @JsonKey(name: 'customOrder')
  int get customOrder => throw _privateConstructorUsedError;
  bool get enabled => throw _privateConstructorUsedError;
  @JsonKey(name: 'enabledExplore')
  bool get enabledExplore => throw _privateConstructorUsedError;
  @JsonKey(name: 'jsLib')
  String? get jsLib => throw _privateConstructorUsedError;
  @JsonKey(name: 'enabledCookieJar')
  bool? get enabledCookieJar => throw _privateConstructorUsedError;
  @JsonKey(name: 'concurrentRate')
  String? get concurrentRate => throw _privateConstructorUsedError;
  String? get header => throw _privateConstructorUsedError;
  @JsonKey(name: 'loginUrl')
  String? get loginUrl => throw _privateConstructorUsedError;
  @JsonKey(name: 'loginUi')
  String? get loginUi => throw _privateConstructorUsedError;
  @JsonKey(name: 'loginCheckJs')
  String? get loginCheckJs => throw _privateConstructorUsedError;
  @JsonKey(name: 'coverDecodeJs')
  String? get coverDecodeJs => throw _privateConstructorUsedError;
  @JsonKey(name: 'bookSourceComment')
  String? get bookSourceComment => throw _privateConstructorUsedError;
  @JsonKey(name: 'variableComment')
  String? get variableComment => throw _privateConstructorUsedError;
  @JsonKey(name: 'lastUpdateTime')
  int get lastUpdateTime => throw _privateConstructorUsedError;
  @JsonKey(name: 'respondTime')
  int get respondTime => throw _privateConstructorUsedError;
  int get weight => throw _privateConstructorUsedError;
  @JsonKey(name: 'exploreUrl')
  String? get exploreUrl => throw _privateConstructorUsedError;
  @JsonKey(name: 'exploreScreen')
  String? get exploreScreen => throw _privateConstructorUsedError;
  @JsonKey(name: 'ruleExplore')
  ExploreRule? get ruleExplore => throw _privateConstructorUsedError;
  @JsonKey(name: 'searchUrl')
  String? get searchUrl => throw _privateConstructorUsedError;
  @JsonKey(name: 'ruleSearch')
  SearchRule? get ruleSearch => throw _privateConstructorUsedError;
  @JsonKey(name: 'ruleBookInfo')
  BookInfoRule? get ruleBookInfo => throw _privateConstructorUsedError;
  @JsonKey(name: 'ruleToc')
  TocRule? get ruleToc => throw _privateConstructorUsedError;
  @JsonKey(name: 'ruleContent')
  ContentRule? get ruleContent => throw _privateConstructorUsedError;
  @JsonKey(name: 'ruleReview')
  ReviewRule? get ruleReview => throw _privateConstructorUsedError;
  @JsonKey(name: 'mainJs')
  String? get mainJs => throw _privateConstructorUsedError;
  @JsonKey(name: 'eventListener')
  bool get eventListener => throw _privateConstructorUsedError;
  @JsonKey(name: 'customButton')
  bool get customButton => throw _privateConstructorUsedError;

  /// Serializes this BookSource to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $BookSourceCopyWith<BookSource> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $BookSourceCopyWith<$Res> {
  factory $BookSourceCopyWith(
    BookSource value,
    $Res Function(BookSource) then,
  ) = _$BookSourceCopyWithImpl<$Res, BookSource>;
  @useResult
  $Res call({
    @JsonKey(name: 'bookSourceUrl') String bookSourceUrl,
    @JsonKey(name: 'bookSourceName') String bookSourceName,
    @JsonKey(name: 'bookSourceGroup') String? bookSourceGroup,
    @JsonKey(name: 'bookSourceType') int bookSourceType,
    @JsonKey(name: 'bookUrlPattern') String? bookUrlPattern,
    @JsonKey(name: 'customOrder') int customOrder,
    bool enabled,
    @JsonKey(name: 'enabledExplore') bool enabledExplore,
    @JsonKey(name: 'jsLib') String? jsLib,
    @JsonKey(name: 'enabledCookieJar') bool? enabledCookieJar,
    @JsonKey(name: 'concurrentRate') String? concurrentRate,
    String? header,
    @JsonKey(name: 'loginUrl') String? loginUrl,
    @JsonKey(name: 'loginUi') String? loginUi,
    @JsonKey(name: 'loginCheckJs') String? loginCheckJs,
    @JsonKey(name: 'coverDecodeJs') String? coverDecodeJs,
    @JsonKey(name: 'bookSourceComment') String? bookSourceComment,
    @JsonKey(name: 'variableComment') String? variableComment,
    @JsonKey(name: 'lastUpdateTime') int lastUpdateTime,
    @JsonKey(name: 'respondTime') int respondTime,
    int weight,
    @JsonKey(name: 'exploreUrl') String? exploreUrl,
    @JsonKey(name: 'exploreScreen') String? exploreScreen,
    @JsonKey(name: 'ruleExplore') ExploreRule? ruleExplore,
    @JsonKey(name: 'searchUrl') String? searchUrl,
    @JsonKey(name: 'ruleSearch') SearchRule? ruleSearch,
    @JsonKey(name: 'ruleBookInfo') BookInfoRule? ruleBookInfo,
    @JsonKey(name: 'ruleToc') TocRule? ruleToc,
    @JsonKey(name: 'ruleContent') ContentRule? ruleContent,
    @JsonKey(name: 'ruleReview') ReviewRule? ruleReview,
    @JsonKey(name: 'mainJs') String? mainJs,
    @JsonKey(name: 'eventListener') bool eventListener,
    @JsonKey(name: 'customButton') bool customButton,
  });

  $ExploreRuleCopyWith<$Res>? get ruleExplore;
  $SearchRuleCopyWith<$Res>? get ruleSearch;
  $BookInfoRuleCopyWith<$Res>? get ruleBookInfo;
  $TocRuleCopyWith<$Res>? get ruleToc;
  $ContentRuleCopyWith<$Res>? get ruleContent;
  $ReviewRuleCopyWith<$Res>? get ruleReview;
}

/// @nodoc
class _$BookSourceCopyWithImpl<$Res, $Val extends BookSource>
    implements $BookSourceCopyWith<$Res> {
  _$BookSourceCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? bookSourceUrl = null,
    Object? bookSourceName = null,
    Object? bookSourceGroup = freezed,
    Object? bookSourceType = null,
    Object? bookUrlPattern = freezed,
    Object? customOrder = null,
    Object? enabled = null,
    Object? enabledExplore = null,
    Object? jsLib = freezed,
    Object? enabledCookieJar = freezed,
    Object? concurrentRate = freezed,
    Object? header = freezed,
    Object? loginUrl = freezed,
    Object? loginUi = freezed,
    Object? loginCheckJs = freezed,
    Object? coverDecodeJs = freezed,
    Object? bookSourceComment = freezed,
    Object? variableComment = freezed,
    Object? lastUpdateTime = null,
    Object? respondTime = null,
    Object? weight = null,
    Object? exploreUrl = freezed,
    Object? exploreScreen = freezed,
    Object? ruleExplore = freezed,
    Object? searchUrl = freezed,
    Object? ruleSearch = freezed,
    Object? ruleBookInfo = freezed,
    Object? ruleToc = freezed,
    Object? ruleContent = freezed,
    Object? ruleReview = freezed,
    Object? mainJs = freezed,
    Object? eventListener = null,
    Object? customButton = null,
  }) {
    return _then(
      _value.copyWith(
            bookSourceUrl: null == bookSourceUrl
                ? _value.bookSourceUrl
                : bookSourceUrl // ignore: cast_nullable_to_non_nullable
                      as String,
            bookSourceName: null == bookSourceName
                ? _value.bookSourceName
                : bookSourceName // ignore: cast_nullable_to_non_nullable
                      as String,
            bookSourceGroup: freezed == bookSourceGroup
                ? _value.bookSourceGroup
                : bookSourceGroup // ignore: cast_nullable_to_non_nullable
                      as String?,
            bookSourceType: null == bookSourceType
                ? _value.bookSourceType
                : bookSourceType // ignore: cast_nullable_to_non_nullable
                      as int,
            bookUrlPattern: freezed == bookUrlPattern
                ? _value.bookUrlPattern
                : bookUrlPattern // ignore: cast_nullable_to_non_nullable
                      as String?,
            customOrder: null == customOrder
                ? _value.customOrder
                : customOrder // ignore: cast_nullable_to_non_nullable
                      as int,
            enabled: null == enabled
                ? _value.enabled
                : enabled // ignore: cast_nullable_to_non_nullable
                      as bool,
            enabledExplore: null == enabledExplore
                ? _value.enabledExplore
                : enabledExplore // ignore: cast_nullable_to_non_nullable
                      as bool,
            jsLib: freezed == jsLib
                ? _value.jsLib
                : jsLib // ignore: cast_nullable_to_non_nullable
                      as String?,
            enabledCookieJar: freezed == enabledCookieJar
                ? _value.enabledCookieJar
                : enabledCookieJar // ignore: cast_nullable_to_non_nullable
                      as bool?,
            concurrentRate: freezed == concurrentRate
                ? _value.concurrentRate
                : concurrentRate // ignore: cast_nullable_to_non_nullable
                      as String?,
            header: freezed == header
                ? _value.header
                : header // ignore: cast_nullable_to_non_nullable
                      as String?,
            loginUrl: freezed == loginUrl
                ? _value.loginUrl
                : loginUrl // ignore: cast_nullable_to_non_nullable
                      as String?,
            loginUi: freezed == loginUi
                ? _value.loginUi
                : loginUi // ignore: cast_nullable_to_non_nullable
                      as String?,
            loginCheckJs: freezed == loginCheckJs
                ? _value.loginCheckJs
                : loginCheckJs // ignore: cast_nullable_to_non_nullable
                      as String?,
            coverDecodeJs: freezed == coverDecodeJs
                ? _value.coverDecodeJs
                : coverDecodeJs // ignore: cast_nullable_to_non_nullable
                      as String?,
            bookSourceComment: freezed == bookSourceComment
                ? _value.bookSourceComment
                : bookSourceComment // ignore: cast_nullable_to_non_nullable
                      as String?,
            variableComment: freezed == variableComment
                ? _value.variableComment
                : variableComment // ignore: cast_nullable_to_non_nullable
                      as String?,
            lastUpdateTime: null == lastUpdateTime
                ? _value.lastUpdateTime
                : lastUpdateTime // ignore: cast_nullable_to_non_nullable
                      as int,
            respondTime: null == respondTime
                ? _value.respondTime
                : respondTime // ignore: cast_nullable_to_non_nullable
                      as int,
            weight: null == weight
                ? _value.weight
                : weight // ignore: cast_nullable_to_non_nullable
                      as int,
            exploreUrl: freezed == exploreUrl
                ? _value.exploreUrl
                : exploreUrl // ignore: cast_nullable_to_non_nullable
                      as String?,
            exploreScreen: freezed == exploreScreen
                ? _value.exploreScreen
                : exploreScreen // ignore: cast_nullable_to_non_nullable
                      as String?,
            ruleExplore: freezed == ruleExplore
                ? _value.ruleExplore
                : ruleExplore // ignore: cast_nullable_to_non_nullable
                      as ExploreRule?,
            searchUrl: freezed == searchUrl
                ? _value.searchUrl
                : searchUrl // ignore: cast_nullable_to_non_nullable
                      as String?,
            ruleSearch: freezed == ruleSearch
                ? _value.ruleSearch
                : ruleSearch // ignore: cast_nullable_to_non_nullable
                      as SearchRule?,
            ruleBookInfo: freezed == ruleBookInfo
                ? _value.ruleBookInfo
                : ruleBookInfo // ignore: cast_nullable_to_non_nullable
                      as BookInfoRule?,
            ruleToc: freezed == ruleToc
                ? _value.ruleToc
                : ruleToc // ignore: cast_nullable_to_non_nullable
                      as TocRule?,
            ruleContent: freezed == ruleContent
                ? _value.ruleContent
                : ruleContent // ignore: cast_nullable_to_non_nullable
                      as ContentRule?,
            ruleReview: freezed == ruleReview
                ? _value.ruleReview
                : ruleReview // ignore: cast_nullable_to_non_nullable
                      as ReviewRule?,
            mainJs: freezed == mainJs
                ? _value.mainJs
                : mainJs // ignore: cast_nullable_to_non_nullable
                      as String?,
            eventListener: null == eventListener
                ? _value.eventListener
                : eventListener // ignore: cast_nullable_to_non_nullable
                      as bool,
            customButton: null == customButton
                ? _value.customButton
                : customButton // ignore: cast_nullable_to_non_nullable
                      as bool,
          )
          as $Val,
    );
  }

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $ExploreRuleCopyWith<$Res>? get ruleExplore {
    if (_value.ruleExplore == null) {
      return null;
    }

    return $ExploreRuleCopyWith<$Res>(_value.ruleExplore!, (value) {
      return _then(_value.copyWith(ruleExplore: value) as $Val);
    });
  }

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $SearchRuleCopyWith<$Res>? get ruleSearch {
    if (_value.ruleSearch == null) {
      return null;
    }

    return $SearchRuleCopyWith<$Res>(_value.ruleSearch!, (value) {
      return _then(_value.copyWith(ruleSearch: value) as $Val);
    });
  }

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $BookInfoRuleCopyWith<$Res>? get ruleBookInfo {
    if (_value.ruleBookInfo == null) {
      return null;
    }

    return $BookInfoRuleCopyWith<$Res>(_value.ruleBookInfo!, (value) {
      return _then(_value.copyWith(ruleBookInfo: value) as $Val);
    });
  }

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $TocRuleCopyWith<$Res>? get ruleToc {
    if (_value.ruleToc == null) {
      return null;
    }

    return $TocRuleCopyWith<$Res>(_value.ruleToc!, (value) {
      return _then(_value.copyWith(ruleToc: value) as $Val);
    });
  }

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $ContentRuleCopyWith<$Res>? get ruleContent {
    if (_value.ruleContent == null) {
      return null;
    }

    return $ContentRuleCopyWith<$Res>(_value.ruleContent!, (value) {
      return _then(_value.copyWith(ruleContent: value) as $Val);
    });
  }

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $ReviewRuleCopyWith<$Res>? get ruleReview {
    if (_value.ruleReview == null) {
      return null;
    }

    return $ReviewRuleCopyWith<$Res>(_value.ruleReview!, (value) {
      return _then(_value.copyWith(ruleReview: value) as $Val);
    });
  }
}

/// @nodoc
abstract class _$$BookSourceImplCopyWith<$Res>
    implements $BookSourceCopyWith<$Res> {
  factory _$$BookSourceImplCopyWith(
    _$BookSourceImpl value,
    $Res Function(_$BookSourceImpl) then,
  ) = __$$BookSourceImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    @JsonKey(name: 'bookSourceUrl') String bookSourceUrl,
    @JsonKey(name: 'bookSourceName') String bookSourceName,
    @JsonKey(name: 'bookSourceGroup') String? bookSourceGroup,
    @JsonKey(name: 'bookSourceType') int bookSourceType,
    @JsonKey(name: 'bookUrlPattern') String? bookUrlPattern,
    @JsonKey(name: 'customOrder') int customOrder,
    bool enabled,
    @JsonKey(name: 'enabledExplore') bool enabledExplore,
    @JsonKey(name: 'jsLib') String? jsLib,
    @JsonKey(name: 'enabledCookieJar') bool? enabledCookieJar,
    @JsonKey(name: 'concurrentRate') String? concurrentRate,
    String? header,
    @JsonKey(name: 'loginUrl') String? loginUrl,
    @JsonKey(name: 'loginUi') String? loginUi,
    @JsonKey(name: 'loginCheckJs') String? loginCheckJs,
    @JsonKey(name: 'coverDecodeJs') String? coverDecodeJs,
    @JsonKey(name: 'bookSourceComment') String? bookSourceComment,
    @JsonKey(name: 'variableComment') String? variableComment,
    @JsonKey(name: 'lastUpdateTime') int lastUpdateTime,
    @JsonKey(name: 'respondTime') int respondTime,
    int weight,
    @JsonKey(name: 'exploreUrl') String? exploreUrl,
    @JsonKey(name: 'exploreScreen') String? exploreScreen,
    @JsonKey(name: 'ruleExplore') ExploreRule? ruleExplore,
    @JsonKey(name: 'searchUrl') String? searchUrl,
    @JsonKey(name: 'ruleSearch') SearchRule? ruleSearch,
    @JsonKey(name: 'ruleBookInfo') BookInfoRule? ruleBookInfo,
    @JsonKey(name: 'ruleToc') TocRule? ruleToc,
    @JsonKey(name: 'ruleContent') ContentRule? ruleContent,
    @JsonKey(name: 'ruleReview') ReviewRule? ruleReview,
    @JsonKey(name: 'mainJs') String? mainJs,
    @JsonKey(name: 'eventListener') bool eventListener,
    @JsonKey(name: 'customButton') bool customButton,
  });

  @override
  $ExploreRuleCopyWith<$Res>? get ruleExplore;
  @override
  $SearchRuleCopyWith<$Res>? get ruleSearch;
  @override
  $BookInfoRuleCopyWith<$Res>? get ruleBookInfo;
  @override
  $TocRuleCopyWith<$Res>? get ruleToc;
  @override
  $ContentRuleCopyWith<$Res>? get ruleContent;
  @override
  $ReviewRuleCopyWith<$Res>? get ruleReview;
}

/// @nodoc
class __$$BookSourceImplCopyWithImpl<$Res>
    extends _$BookSourceCopyWithImpl<$Res, _$BookSourceImpl>
    implements _$$BookSourceImplCopyWith<$Res> {
  __$$BookSourceImplCopyWithImpl(
    _$BookSourceImpl _value,
    $Res Function(_$BookSourceImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? bookSourceUrl = null,
    Object? bookSourceName = null,
    Object? bookSourceGroup = freezed,
    Object? bookSourceType = null,
    Object? bookUrlPattern = freezed,
    Object? customOrder = null,
    Object? enabled = null,
    Object? enabledExplore = null,
    Object? jsLib = freezed,
    Object? enabledCookieJar = freezed,
    Object? concurrentRate = freezed,
    Object? header = freezed,
    Object? loginUrl = freezed,
    Object? loginUi = freezed,
    Object? loginCheckJs = freezed,
    Object? coverDecodeJs = freezed,
    Object? bookSourceComment = freezed,
    Object? variableComment = freezed,
    Object? lastUpdateTime = null,
    Object? respondTime = null,
    Object? weight = null,
    Object? exploreUrl = freezed,
    Object? exploreScreen = freezed,
    Object? ruleExplore = freezed,
    Object? searchUrl = freezed,
    Object? ruleSearch = freezed,
    Object? ruleBookInfo = freezed,
    Object? ruleToc = freezed,
    Object? ruleContent = freezed,
    Object? ruleReview = freezed,
    Object? mainJs = freezed,
    Object? eventListener = null,
    Object? customButton = null,
  }) {
    return _then(
      _$BookSourceImpl(
        bookSourceUrl: null == bookSourceUrl
            ? _value.bookSourceUrl
            : bookSourceUrl // ignore: cast_nullable_to_non_nullable
                  as String,
        bookSourceName: null == bookSourceName
            ? _value.bookSourceName
            : bookSourceName // ignore: cast_nullable_to_non_nullable
                  as String,
        bookSourceGroup: freezed == bookSourceGroup
            ? _value.bookSourceGroup
            : bookSourceGroup // ignore: cast_nullable_to_non_nullable
                  as String?,
        bookSourceType: null == bookSourceType
            ? _value.bookSourceType
            : bookSourceType // ignore: cast_nullable_to_non_nullable
                  as int,
        bookUrlPattern: freezed == bookUrlPattern
            ? _value.bookUrlPattern
            : bookUrlPattern // ignore: cast_nullable_to_non_nullable
                  as String?,
        customOrder: null == customOrder
            ? _value.customOrder
            : customOrder // ignore: cast_nullable_to_non_nullable
                  as int,
        enabled: null == enabled
            ? _value.enabled
            : enabled // ignore: cast_nullable_to_non_nullable
                  as bool,
        enabledExplore: null == enabledExplore
            ? _value.enabledExplore
            : enabledExplore // ignore: cast_nullable_to_non_nullable
                  as bool,
        jsLib: freezed == jsLib
            ? _value.jsLib
            : jsLib // ignore: cast_nullable_to_non_nullable
                  as String?,
        enabledCookieJar: freezed == enabledCookieJar
            ? _value.enabledCookieJar
            : enabledCookieJar // ignore: cast_nullable_to_non_nullable
                  as bool?,
        concurrentRate: freezed == concurrentRate
            ? _value.concurrentRate
            : concurrentRate // ignore: cast_nullable_to_non_nullable
                  as String?,
        header: freezed == header
            ? _value.header
            : header // ignore: cast_nullable_to_non_nullable
                  as String?,
        loginUrl: freezed == loginUrl
            ? _value.loginUrl
            : loginUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        loginUi: freezed == loginUi
            ? _value.loginUi
            : loginUi // ignore: cast_nullable_to_non_nullable
                  as String?,
        loginCheckJs: freezed == loginCheckJs
            ? _value.loginCheckJs
            : loginCheckJs // ignore: cast_nullable_to_non_nullable
                  as String?,
        coverDecodeJs: freezed == coverDecodeJs
            ? _value.coverDecodeJs
            : coverDecodeJs // ignore: cast_nullable_to_non_nullable
                  as String?,
        bookSourceComment: freezed == bookSourceComment
            ? _value.bookSourceComment
            : bookSourceComment // ignore: cast_nullable_to_non_nullable
                  as String?,
        variableComment: freezed == variableComment
            ? _value.variableComment
            : variableComment // ignore: cast_nullable_to_non_nullable
                  as String?,
        lastUpdateTime: null == lastUpdateTime
            ? _value.lastUpdateTime
            : lastUpdateTime // ignore: cast_nullable_to_non_nullable
                  as int,
        respondTime: null == respondTime
            ? _value.respondTime
            : respondTime // ignore: cast_nullable_to_non_nullable
                  as int,
        weight: null == weight
            ? _value.weight
            : weight // ignore: cast_nullable_to_non_nullable
                  as int,
        exploreUrl: freezed == exploreUrl
            ? _value.exploreUrl
            : exploreUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        exploreScreen: freezed == exploreScreen
            ? _value.exploreScreen
            : exploreScreen // ignore: cast_nullable_to_non_nullable
                  as String?,
        ruleExplore: freezed == ruleExplore
            ? _value.ruleExplore
            : ruleExplore // ignore: cast_nullable_to_non_nullable
                  as ExploreRule?,
        searchUrl: freezed == searchUrl
            ? _value.searchUrl
            : searchUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        ruleSearch: freezed == ruleSearch
            ? _value.ruleSearch
            : ruleSearch // ignore: cast_nullable_to_non_nullable
                  as SearchRule?,
        ruleBookInfo: freezed == ruleBookInfo
            ? _value.ruleBookInfo
            : ruleBookInfo // ignore: cast_nullable_to_non_nullable
                  as BookInfoRule?,
        ruleToc: freezed == ruleToc
            ? _value.ruleToc
            : ruleToc // ignore: cast_nullable_to_non_nullable
                  as TocRule?,
        ruleContent: freezed == ruleContent
            ? _value.ruleContent
            : ruleContent // ignore: cast_nullable_to_non_nullable
                  as ContentRule?,
        ruleReview: freezed == ruleReview
            ? _value.ruleReview
            : ruleReview // ignore: cast_nullable_to_non_nullable
                  as ReviewRule?,
        mainJs: freezed == mainJs
            ? _value.mainJs
            : mainJs // ignore: cast_nullable_to_non_nullable
                  as String?,
        eventListener: null == eventListener
            ? _value.eventListener
            : eventListener // ignore: cast_nullable_to_non_nullable
                  as bool,
        customButton: null == customButton
            ? _value.customButton
            : customButton // ignore: cast_nullable_to_non_nullable
                  as bool,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$BookSourceImpl implements _BookSource {
  const _$BookSourceImpl({
    @JsonKey(name: 'bookSourceUrl') this.bookSourceUrl = '',
    @JsonKey(name: 'bookSourceName') this.bookSourceName = '',
    @JsonKey(name: 'bookSourceGroup') this.bookSourceGroup,
    @JsonKey(name: 'bookSourceType') this.bookSourceType = 0,
    @JsonKey(name: 'bookUrlPattern') this.bookUrlPattern,
    @JsonKey(name: 'customOrder') this.customOrder = 0,
    this.enabled = true,
    @JsonKey(name: 'enabledExplore') this.enabledExplore = true,
    @JsonKey(name: 'jsLib') this.jsLib,
    @JsonKey(name: 'enabledCookieJar') this.enabledCookieJar,
    @JsonKey(name: 'concurrentRate') this.concurrentRate,
    this.header,
    @JsonKey(name: 'loginUrl') this.loginUrl,
    @JsonKey(name: 'loginUi') this.loginUi,
    @JsonKey(name: 'loginCheckJs') this.loginCheckJs,
    @JsonKey(name: 'coverDecodeJs') this.coverDecodeJs,
    @JsonKey(name: 'bookSourceComment') this.bookSourceComment,
    @JsonKey(name: 'variableComment') this.variableComment,
    @JsonKey(name: 'lastUpdateTime') this.lastUpdateTime = 0,
    @JsonKey(name: 'respondTime') this.respondTime = 180000,
    this.weight = 0,
    @JsonKey(name: 'exploreUrl') this.exploreUrl,
    @JsonKey(name: 'exploreScreen') this.exploreScreen,
    @JsonKey(name: 'ruleExplore') this.ruleExplore,
    @JsonKey(name: 'searchUrl') this.searchUrl,
    @JsonKey(name: 'ruleSearch') this.ruleSearch,
    @JsonKey(name: 'ruleBookInfo') this.ruleBookInfo,
    @JsonKey(name: 'ruleToc') this.ruleToc,
    @JsonKey(name: 'ruleContent') this.ruleContent,
    @JsonKey(name: 'ruleReview') this.ruleReview,
    @JsonKey(name: 'mainJs') this.mainJs,
    @JsonKey(name: 'eventListener') this.eventListener = false,
    @JsonKey(name: 'customButton') this.customButton = false,
  });

  factory _$BookSourceImpl.fromJson(Map<String, dynamic> json) =>
      _$$BookSourceImplFromJson(json);

  @override
  @JsonKey(name: 'bookSourceUrl')
  final String bookSourceUrl;
  @override
  @JsonKey(name: 'bookSourceName')
  final String bookSourceName;
  @override
  @JsonKey(name: 'bookSourceGroup')
  final String? bookSourceGroup;
  @override
  @JsonKey(name: 'bookSourceType')
  final int bookSourceType;
  @override
  @JsonKey(name: 'bookUrlPattern')
  final String? bookUrlPattern;
  @override
  @JsonKey(name: 'customOrder')
  final int customOrder;
  @override
  @JsonKey()
  final bool enabled;
  @override
  @JsonKey(name: 'enabledExplore')
  final bool enabledExplore;
  @override
  @JsonKey(name: 'jsLib')
  final String? jsLib;
  @override
  @JsonKey(name: 'enabledCookieJar')
  final bool? enabledCookieJar;
  @override
  @JsonKey(name: 'concurrentRate')
  final String? concurrentRate;
  @override
  final String? header;
  @override
  @JsonKey(name: 'loginUrl')
  final String? loginUrl;
  @override
  @JsonKey(name: 'loginUi')
  final String? loginUi;
  @override
  @JsonKey(name: 'loginCheckJs')
  final String? loginCheckJs;
  @override
  @JsonKey(name: 'coverDecodeJs')
  final String? coverDecodeJs;
  @override
  @JsonKey(name: 'bookSourceComment')
  final String? bookSourceComment;
  @override
  @JsonKey(name: 'variableComment')
  final String? variableComment;
  @override
  @JsonKey(name: 'lastUpdateTime')
  final int lastUpdateTime;
  @override
  @JsonKey(name: 'respondTime')
  final int respondTime;
  @override
  @JsonKey()
  final int weight;
  @override
  @JsonKey(name: 'exploreUrl')
  final String? exploreUrl;
  @override
  @JsonKey(name: 'exploreScreen')
  final String? exploreScreen;
  @override
  @JsonKey(name: 'ruleExplore')
  final ExploreRule? ruleExplore;
  @override
  @JsonKey(name: 'searchUrl')
  final String? searchUrl;
  @override
  @JsonKey(name: 'ruleSearch')
  final SearchRule? ruleSearch;
  @override
  @JsonKey(name: 'ruleBookInfo')
  final BookInfoRule? ruleBookInfo;
  @override
  @JsonKey(name: 'ruleToc')
  final TocRule? ruleToc;
  @override
  @JsonKey(name: 'ruleContent')
  final ContentRule? ruleContent;
  @override
  @JsonKey(name: 'ruleReview')
  final ReviewRule? ruleReview;
  @override
  @JsonKey(name: 'mainJs')
  final String? mainJs;
  @override
  @JsonKey(name: 'eventListener')
  final bool eventListener;
  @override
  @JsonKey(name: 'customButton')
  final bool customButton;

  @override
  String toString() {
    return 'BookSource(bookSourceUrl: $bookSourceUrl, bookSourceName: $bookSourceName, bookSourceGroup: $bookSourceGroup, bookSourceType: $bookSourceType, bookUrlPattern: $bookUrlPattern, customOrder: $customOrder, enabled: $enabled, enabledExplore: $enabledExplore, jsLib: $jsLib, enabledCookieJar: $enabledCookieJar, concurrentRate: $concurrentRate, header: $header, loginUrl: $loginUrl, loginUi: $loginUi, loginCheckJs: $loginCheckJs, coverDecodeJs: $coverDecodeJs, bookSourceComment: $bookSourceComment, variableComment: $variableComment, lastUpdateTime: $lastUpdateTime, respondTime: $respondTime, weight: $weight, exploreUrl: $exploreUrl, exploreScreen: $exploreScreen, ruleExplore: $ruleExplore, searchUrl: $searchUrl, ruleSearch: $ruleSearch, ruleBookInfo: $ruleBookInfo, ruleToc: $ruleToc, ruleContent: $ruleContent, ruleReview: $ruleReview, mainJs: $mainJs, eventListener: $eventListener, customButton: $customButton)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$BookSourceImpl &&
            (identical(other.bookSourceUrl, bookSourceUrl) ||
                other.bookSourceUrl == bookSourceUrl) &&
            (identical(other.bookSourceName, bookSourceName) ||
                other.bookSourceName == bookSourceName) &&
            (identical(other.bookSourceGroup, bookSourceGroup) ||
                other.bookSourceGroup == bookSourceGroup) &&
            (identical(other.bookSourceType, bookSourceType) ||
                other.bookSourceType == bookSourceType) &&
            (identical(other.bookUrlPattern, bookUrlPattern) ||
                other.bookUrlPattern == bookUrlPattern) &&
            (identical(other.customOrder, customOrder) ||
                other.customOrder == customOrder) &&
            (identical(other.enabled, enabled) || other.enabled == enabled) &&
            (identical(other.enabledExplore, enabledExplore) ||
                other.enabledExplore == enabledExplore) &&
            (identical(other.jsLib, jsLib) || other.jsLib == jsLib) &&
            (identical(other.enabledCookieJar, enabledCookieJar) ||
                other.enabledCookieJar == enabledCookieJar) &&
            (identical(other.concurrentRate, concurrentRate) ||
                other.concurrentRate == concurrentRate) &&
            (identical(other.header, header) || other.header == header) &&
            (identical(other.loginUrl, loginUrl) ||
                other.loginUrl == loginUrl) &&
            (identical(other.loginUi, loginUi) || other.loginUi == loginUi) &&
            (identical(other.loginCheckJs, loginCheckJs) ||
                other.loginCheckJs == loginCheckJs) &&
            (identical(other.coverDecodeJs, coverDecodeJs) ||
                other.coverDecodeJs == coverDecodeJs) &&
            (identical(other.bookSourceComment, bookSourceComment) ||
                other.bookSourceComment == bookSourceComment) &&
            (identical(other.variableComment, variableComment) ||
                other.variableComment == variableComment) &&
            (identical(other.lastUpdateTime, lastUpdateTime) ||
                other.lastUpdateTime == lastUpdateTime) &&
            (identical(other.respondTime, respondTime) ||
                other.respondTime == respondTime) &&
            (identical(other.weight, weight) || other.weight == weight) &&
            (identical(other.exploreUrl, exploreUrl) ||
                other.exploreUrl == exploreUrl) &&
            (identical(other.exploreScreen, exploreScreen) ||
                other.exploreScreen == exploreScreen) &&
            (identical(other.ruleExplore, ruleExplore) ||
                other.ruleExplore == ruleExplore) &&
            (identical(other.searchUrl, searchUrl) ||
                other.searchUrl == searchUrl) &&
            (identical(other.ruleSearch, ruleSearch) ||
                other.ruleSearch == ruleSearch) &&
            (identical(other.ruleBookInfo, ruleBookInfo) ||
                other.ruleBookInfo == ruleBookInfo) &&
            (identical(other.ruleToc, ruleToc) || other.ruleToc == ruleToc) &&
            (identical(other.ruleContent, ruleContent) ||
                other.ruleContent == ruleContent) &&
            (identical(other.ruleReview, ruleReview) ||
                other.ruleReview == ruleReview) &&
            (identical(other.mainJs, mainJs) || other.mainJs == mainJs) &&
            (identical(other.eventListener, eventListener) ||
                other.eventListener == eventListener) &&
            (identical(other.customButton, customButton) ||
                other.customButton == customButton));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hashAll([
    runtimeType,
    bookSourceUrl,
    bookSourceName,
    bookSourceGroup,
    bookSourceType,
    bookUrlPattern,
    customOrder,
    enabled,
    enabledExplore,
    jsLib,
    enabledCookieJar,
    concurrentRate,
    header,
    loginUrl,
    loginUi,
    loginCheckJs,
    coverDecodeJs,
    bookSourceComment,
    variableComment,
    lastUpdateTime,
    respondTime,
    weight,
    exploreUrl,
    exploreScreen,
    ruleExplore,
    searchUrl,
    ruleSearch,
    ruleBookInfo,
    ruleToc,
    ruleContent,
    ruleReview,
    mainJs,
    eventListener,
    customButton,
  ]);

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$BookSourceImplCopyWith<_$BookSourceImpl> get copyWith =>
      __$$BookSourceImplCopyWithImpl<_$BookSourceImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$BookSourceImplToJson(this);
  }
}

abstract class _BookSource implements BookSource {
  const factory _BookSource({
    @JsonKey(name: 'bookSourceUrl') final String bookSourceUrl,
    @JsonKey(name: 'bookSourceName') final String bookSourceName,
    @JsonKey(name: 'bookSourceGroup') final String? bookSourceGroup,
    @JsonKey(name: 'bookSourceType') final int bookSourceType,
    @JsonKey(name: 'bookUrlPattern') final String? bookUrlPattern,
    @JsonKey(name: 'customOrder') final int customOrder,
    final bool enabled,
    @JsonKey(name: 'enabledExplore') final bool enabledExplore,
    @JsonKey(name: 'jsLib') final String? jsLib,
    @JsonKey(name: 'enabledCookieJar') final bool? enabledCookieJar,
    @JsonKey(name: 'concurrentRate') final String? concurrentRate,
    final String? header,
    @JsonKey(name: 'loginUrl') final String? loginUrl,
    @JsonKey(name: 'loginUi') final String? loginUi,
    @JsonKey(name: 'loginCheckJs') final String? loginCheckJs,
    @JsonKey(name: 'coverDecodeJs') final String? coverDecodeJs,
    @JsonKey(name: 'bookSourceComment') final String? bookSourceComment,
    @JsonKey(name: 'variableComment') final String? variableComment,
    @JsonKey(name: 'lastUpdateTime') final int lastUpdateTime,
    @JsonKey(name: 'respondTime') final int respondTime,
    final int weight,
    @JsonKey(name: 'exploreUrl') final String? exploreUrl,
    @JsonKey(name: 'exploreScreen') final String? exploreScreen,
    @JsonKey(name: 'ruleExplore') final ExploreRule? ruleExplore,
    @JsonKey(name: 'searchUrl') final String? searchUrl,
    @JsonKey(name: 'ruleSearch') final SearchRule? ruleSearch,
    @JsonKey(name: 'ruleBookInfo') final BookInfoRule? ruleBookInfo,
    @JsonKey(name: 'ruleToc') final TocRule? ruleToc,
    @JsonKey(name: 'ruleContent') final ContentRule? ruleContent,
    @JsonKey(name: 'ruleReview') final ReviewRule? ruleReview,
    @JsonKey(name: 'mainJs') final String? mainJs,
    @JsonKey(name: 'eventListener') final bool eventListener,
    @JsonKey(name: 'customButton') final bool customButton,
  }) = _$BookSourceImpl;

  factory _BookSource.fromJson(Map<String, dynamic> json) =
      _$BookSourceImpl.fromJson;

  @override
  @JsonKey(name: 'bookSourceUrl')
  String get bookSourceUrl;
  @override
  @JsonKey(name: 'bookSourceName')
  String get bookSourceName;
  @override
  @JsonKey(name: 'bookSourceGroup')
  String? get bookSourceGroup;
  @override
  @JsonKey(name: 'bookSourceType')
  int get bookSourceType;
  @override
  @JsonKey(name: 'bookUrlPattern')
  String? get bookUrlPattern;
  @override
  @JsonKey(name: 'customOrder')
  int get customOrder;
  @override
  bool get enabled;
  @override
  @JsonKey(name: 'enabledExplore')
  bool get enabledExplore;
  @override
  @JsonKey(name: 'jsLib')
  String? get jsLib;
  @override
  @JsonKey(name: 'enabledCookieJar')
  bool? get enabledCookieJar;
  @override
  @JsonKey(name: 'concurrentRate')
  String? get concurrentRate;
  @override
  String? get header;
  @override
  @JsonKey(name: 'loginUrl')
  String? get loginUrl;
  @override
  @JsonKey(name: 'loginUi')
  String? get loginUi;
  @override
  @JsonKey(name: 'loginCheckJs')
  String? get loginCheckJs;
  @override
  @JsonKey(name: 'coverDecodeJs')
  String? get coverDecodeJs;
  @override
  @JsonKey(name: 'bookSourceComment')
  String? get bookSourceComment;
  @override
  @JsonKey(name: 'variableComment')
  String? get variableComment;
  @override
  @JsonKey(name: 'lastUpdateTime')
  int get lastUpdateTime;
  @override
  @JsonKey(name: 'respondTime')
  int get respondTime;
  @override
  int get weight;
  @override
  @JsonKey(name: 'exploreUrl')
  String? get exploreUrl;
  @override
  @JsonKey(name: 'exploreScreen')
  String? get exploreScreen;
  @override
  @JsonKey(name: 'ruleExplore')
  ExploreRule? get ruleExplore;
  @override
  @JsonKey(name: 'searchUrl')
  String? get searchUrl;
  @override
  @JsonKey(name: 'ruleSearch')
  SearchRule? get ruleSearch;
  @override
  @JsonKey(name: 'ruleBookInfo')
  BookInfoRule? get ruleBookInfo;
  @override
  @JsonKey(name: 'ruleToc')
  TocRule? get ruleToc;
  @override
  @JsonKey(name: 'ruleContent')
  ContentRule? get ruleContent;
  @override
  @JsonKey(name: 'ruleReview')
  ReviewRule? get ruleReview;
  @override
  @JsonKey(name: 'mainJs')
  String? get mainJs;
  @override
  @JsonKey(name: 'eventListener')
  bool get eventListener;
  @override
  @JsonKey(name: 'customButton')
  bool get customButton;

  /// Create a copy of BookSource
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$BookSourceImplCopyWith<_$BookSourceImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
