// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'reading_stats_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ReadingStatsState {
  /// 今日阅读统计
  ReadingStatsToday get today => throw _privateConstructorUsedError;

  /// 每日阅读时长（日期 → 秒）
  Map<String, int> get dailyStats => throw _privateConstructorUsedError;

  /// 各书籍阅读时长（书名 → 秒）
  Map<String, int> get bookStats => throw _privateConstructorUsedError;

  /// 阅读热力图（日期 → 时长）
  Map<String, int> get heatmap => throw _privateConstructorUsedError;

  /// 当前统计周期（默认周）
  StatsPeriod get period => throw _privateConstructorUsedError;

  /// 是否正在加载
  bool get loading => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get error => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $ReadingStatsStateCopyWith<ReadingStatsState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ReadingStatsStateCopyWith<$Res> {
  factory $ReadingStatsStateCopyWith(
          ReadingStatsState value, $Res Function(ReadingStatsState) then) =
      _$ReadingStatsStateCopyWithImpl<$Res, ReadingStatsState>;
  @useResult
  $Res call(
      {ReadingStatsToday today,
      Map<String, int> dailyStats,
      Map<String, int> bookStats,
      Map<String, int> heatmap,
      StatsPeriod period,
      bool loading,
      String? error});
}

/// @nodoc
class _$ReadingStatsStateCopyWithImpl<$Res, $Val extends ReadingStatsState>
    implements $ReadingStatsStateCopyWith<$Res> {
  _$ReadingStatsStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? today = null,
    Object? dailyStats = null,
    Object? bookStats = null,
    Object? heatmap = null,
    Object? period = null,
    Object? loading = null,
    Object? error = freezed,
  }) {
    return _then(_value.copyWith(
      today: null == today
          ? _value.today
          : today // ignore: cast_nullable_to_non_nullable
              as ReadingStatsToday,
      dailyStats: null == dailyStats
          ? _value.dailyStats
          : dailyStats // ignore: cast_nullable_to_non_nullable
              as Map<String, int>,
      bookStats: null == bookStats
          ? _value.bookStats
          : bookStats // ignore: cast_nullable_to_non_nullable
              as Map<String, int>,
      heatmap: null == heatmap
          ? _value.heatmap
          : heatmap // ignore: cast_nullable_to_non_nullable
              as Map<String, int>,
      period: null == period
          ? _value.period
          : period // ignore: cast_nullable_to_non_nullable
              as StatsPeriod,
      loading: null == loading
          ? _value.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ReadingStatsStateImplCopyWith<$Res>
    implements $ReadingStatsStateCopyWith<$Res> {
  factory _$$ReadingStatsStateImplCopyWith(_$ReadingStatsStateImpl value,
          $Res Function(_$ReadingStatsStateImpl) then) =
      __$$ReadingStatsStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {ReadingStatsToday today,
      Map<String, int> dailyStats,
      Map<String, int> bookStats,
      Map<String, int> heatmap,
      StatsPeriod period,
      bool loading,
      String? error});
}

/// @nodoc
class __$$ReadingStatsStateImplCopyWithImpl<$Res>
    extends _$ReadingStatsStateCopyWithImpl<$Res, _$ReadingStatsStateImpl>
    implements _$$ReadingStatsStateImplCopyWith<$Res> {
  __$$ReadingStatsStateImplCopyWithImpl(_$ReadingStatsStateImpl _value,
      $Res Function(_$ReadingStatsStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? today = null,
    Object? dailyStats = null,
    Object? bookStats = null,
    Object? heatmap = null,
    Object? period = null,
    Object? loading = null,
    Object? error = freezed,
  }) {
    return _then(_$ReadingStatsStateImpl(
      today: null == today
          ? _value.today
          : today // ignore: cast_nullable_to_non_nullable
              as ReadingStatsToday,
      dailyStats: null == dailyStats
          ? _value._dailyStats
          : dailyStats // ignore: cast_nullable_to_non_nullable
              as Map<String, int>,
      bookStats: null == bookStats
          ? _value._bookStats
          : bookStats // ignore: cast_nullable_to_non_nullable
              as Map<String, int>,
      heatmap: null == heatmap
          ? _value._heatmap
          : heatmap // ignore: cast_nullable_to_non_nullable
              as Map<String, int>,
      period: null == period
          ? _value.period
          : period // ignore: cast_nullable_to_non_nullable
              as StatsPeriod,
      loading: null == loading
          ? _value.loading
          : loading // ignore: cast_nullable_to_non_nullable
              as bool,
      error: freezed == error
          ? _value.error
          : error // ignore: cast_nullable_to_non_nullable
              as String?,
    ));
  }
}

/// @nodoc

class _$ReadingStatsStateImpl implements _ReadingStatsState {
  const _$ReadingStatsStateImpl(
      {this.today = const ReadingStatsToday(),
      final Map<String, int> dailyStats = const <String, int>{},
      final Map<String, int> bookStats = const <String, int>{},
      final Map<String, int> heatmap = const <String, int>{},
      this.period = StatsPeriod.week,
      this.loading = false,
      this.error})
      : _dailyStats = dailyStats,
        _bookStats = bookStats,
        _heatmap = heatmap;

  /// 今日阅读统计
  @override
  @JsonKey()
  final ReadingStatsToday today;

  /// 每日阅读时长（日期 → 秒）
  final Map<String, int> _dailyStats;

  /// 每日阅读时长（日期 → 秒）
  @override
  @JsonKey()
  Map<String, int> get dailyStats {
    if (_dailyStats is EqualUnmodifiableMapView) return _dailyStats;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_dailyStats);
  }

  /// 各书籍阅读时长（书名 → 秒）
  final Map<String, int> _bookStats;

  /// 各书籍阅读时长（书名 → 秒）
  @override
  @JsonKey()
  Map<String, int> get bookStats {
    if (_bookStats is EqualUnmodifiableMapView) return _bookStats;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_bookStats);
  }

  /// 阅读热力图（日期 → 时长）
  final Map<String, int> _heatmap;

  /// 阅读热力图（日期 → 时长）
  @override
  @JsonKey()
  Map<String, int> get heatmap {
    if (_heatmap is EqualUnmodifiableMapView) return _heatmap;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableMapView(_heatmap);
  }

  /// 当前统计周期（默认周）
  @override
  @JsonKey()
  final StatsPeriod period;

  /// 是否正在加载
  @override
  @JsonKey()
  final bool loading;

  /// 错误信息（null 表示无错误）
  @override
  final String? error;

  @override
  String toString() {
    return 'ReadingStatsState(today: $today, dailyStats: $dailyStats, bookStats: $bookStats, heatmap: $heatmap, period: $period, loading: $loading, error: $error)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ReadingStatsStateImpl &&
            (identical(other.today, today) || other.today == today) &&
            const DeepCollectionEquality()
                .equals(other._dailyStats, _dailyStats) &&
            const DeepCollectionEquality()
                .equals(other._bookStats, _bookStats) &&
            const DeepCollectionEquality().equals(other._heatmap, _heatmap) &&
            (identical(other.period, period) || other.period == period) &&
            (identical(other.loading, loading) || other.loading == loading) &&
            (identical(other.error, error) || other.error == error));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      today,
      const DeepCollectionEquality().hash(_dailyStats),
      const DeepCollectionEquality().hash(_bookStats),
      const DeepCollectionEquality().hash(_heatmap),
      period,
      loading,
      error);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$ReadingStatsStateImplCopyWith<_$ReadingStatsStateImpl> get copyWith =>
      __$$ReadingStatsStateImplCopyWithImpl<_$ReadingStatsStateImpl>(
          this, _$identity);
}

abstract class _ReadingStatsState implements ReadingStatsState {
  const factory _ReadingStatsState(
      {final ReadingStatsToday today,
      final Map<String, int> dailyStats,
      final Map<String, int> bookStats,
      final Map<String, int> heatmap,
      final StatsPeriod period,
      final bool loading,
      final String? error}) = _$ReadingStatsStateImpl;

  @override

  /// 今日阅读统计
  ReadingStatsToday get today;
  @override

  /// 每日阅读时长（日期 → 秒）
  Map<String, int> get dailyStats;
  @override

  /// 各书籍阅读时长（书名 → 秒）
  Map<String, int> get bookStats;
  @override

  /// 阅读热力图（日期 → 时长）
  Map<String, int> get heatmap;
  @override

  /// 当前统计周期（默认周）
  StatsPeriod get period;
  @override

  /// 是否正在加载
  bool get loading;
  @override

  /// 错误信息（null 表示无错误）
  String? get error;
  @override
  @JsonKey(ignore: true)
  _$$ReadingStatsStateImplCopyWith<_$ReadingStatsStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
