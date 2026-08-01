// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'audio_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$AudioState {
  /// 播放器状态机
  PlayerState get state => throw _privateConstructorUsedError;

  /// 播放模式
  AudioPlayMode get mode => throw _privateConstructorUsedError;

  /// TTS 配置（构造时由 Notifier 注入默认实例）
  TtsConfig get config => throw _privateConstructorUsedError;

  /// 章节列表
  List<AudioChapter> get chapters => throw _privateConstructorUsedError;

  /// 当前章节索引
  int get currentIndex => throw _privateConstructorUsedError;

  /// 错误信息（null 表示无错误）
  String? get errorMessage => throw _privateConstructorUsedError;

  /// 当前听书书籍 URL
  String get bookUrl => throw _privateConstructorUsedError;

  /// 当前听书书名
  String get bookName => throw _privateConstructorUsedError;

  /// 媒体会话是否已就绪（用于 UI 显示后台播放状态）
  bool get isMediaSessionReady => throw _privateConstructorUsedError;

  @JsonKey(ignore: true)
  $AudioStateCopyWith<AudioState> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $AudioStateCopyWith<$Res> {
  factory $AudioStateCopyWith(
          AudioState value, $Res Function(AudioState) then) =
      _$AudioStateCopyWithImpl<$Res, AudioState>;
  @useResult
  $Res call(
      {PlayerState state,
      AudioPlayMode mode,
      TtsConfig config,
      List<AudioChapter> chapters,
      int currentIndex,
      String? errorMessage,
      String bookUrl,
      String bookName,
      bool isMediaSessionReady});
}

/// @nodoc
class _$AudioStateCopyWithImpl<$Res, $Val extends AudioState>
    implements $AudioStateCopyWith<$Res> {
  _$AudioStateCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? state = null,
    Object? mode = null,
    Object? config = null,
    Object? chapters = null,
    Object? currentIndex = null,
    Object? errorMessage = freezed,
    Object? bookUrl = null,
    Object? bookName = null,
    Object? isMediaSessionReady = null,
  }) {
    return _then(_value.copyWith(
      state: null == state
          ? _value.state
          : state // ignore: cast_nullable_to_non_nullable
              as PlayerState,
      mode: null == mode
          ? _value.mode
          : mode // ignore: cast_nullable_to_non_nullable
              as AudioPlayMode,
      config: null == config
          ? _value.config
          : config // ignore: cast_nullable_to_non_nullable
              as TtsConfig,
      chapters: null == chapters
          ? _value.chapters
          : chapters // ignore: cast_nullable_to_non_nullable
              as List<AudioChapter>,
      currentIndex: null == currentIndex
          ? _value.currentIndex
          : currentIndex // ignore: cast_nullable_to_non_nullable
              as int,
      errorMessage: freezed == errorMessage
          ? _value.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      bookUrl: null == bookUrl
          ? _value.bookUrl
          : bookUrl // ignore: cast_nullable_to_non_nullable
              as String,
      bookName: null == bookName
          ? _value.bookName
          : bookName // ignore: cast_nullable_to_non_nullable
              as String,
      isMediaSessionReady: null == isMediaSessionReady
          ? _value.isMediaSessionReady
          : isMediaSessionReady // ignore: cast_nullable_to_non_nullable
              as bool,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$AudioStateImplCopyWith<$Res>
    implements $AudioStateCopyWith<$Res> {
  factory _$$AudioStateImplCopyWith(
          _$AudioStateImpl value, $Res Function(_$AudioStateImpl) then) =
      __$$AudioStateImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {PlayerState state,
      AudioPlayMode mode,
      TtsConfig config,
      List<AudioChapter> chapters,
      int currentIndex,
      String? errorMessage,
      String bookUrl,
      String bookName,
      bool isMediaSessionReady});
}

/// @nodoc
class __$$AudioStateImplCopyWithImpl<$Res>
    extends _$AudioStateCopyWithImpl<$Res, _$AudioStateImpl>
    implements _$$AudioStateImplCopyWith<$Res> {
  __$$AudioStateImplCopyWithImpl(
      _$AudioStateImpl _value, $Res Function(_$AudioStateImpl) _then)
      : super(_value, _then);

  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? state = null,
    Object? mode = null,
    Object? config = null,
    Object? chapters = null,
    Object? currentIndex = null,
    Object? errorMessage = freezed,
    Object? bookUrl = null,
    Object? bookName = null,
    Object? isMediaSessionReady = null,
  }) {
    return _then(_$AudioStateImpl(
      state: null == state
          ? _value.state
          : state // ignore: cast_nullable_to_non_nullable
              as PlayerState,
      mode: null == mode
          ? _value.mode
          : mode // ignore: cast_nullable_to_non_nullable
              as AudioPlayMode,
      config: null == config
          ? _value.config
          : config // ignore: cast_nullable_to_non_nullable
              as TtsConfig,
      chapters: null == chapters
          ? _value._chapters
          : chapters // ignore: cast_nullable_to_non_nullable
              as List<AudioChapter>,
      currentIndex: null == currentIndex
          ? _value.currentIndex
          : currentIndex // ignore: cast_nullable_to_non_nullable
              as int,
      errorMessage: freezed == errorMessage
          ? _value.errorMessage
          : errorMessage // ignore: cast_nullable_to_non_nullable
              as String?,
      bookUrl: null == bookUrl
          ? _value.bookUrl
          : bookUrl // ignore: cast_nullable_to_non_nullable
              as String,
      bookName: null == bookName
          ? _value.bookName
          : bookName // ignore: cast_nullable_to_non_nullable
              as String,
      isMediaSessionReady: null == isMediaSessionReady
          ? _value.isMediaSessionReady
          : isMediaSessionReady // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _$AudioStateImpl implements _AudioState {
  const _$AudioStateImpl(
      {this.state = PlayerState.idle,
      this.mode = AudioPlayMode.sequential,
      required this.config,
      final List<AudioChapter> chapters = const <AudioChapter>[],
      this.currentIndex = 0,
      this.errorMessage,
      this.bookUrl = '',
      this.bookName = '',
      this.isMediaSessionReady = false})
      : _chapters = chapters;

  /// 播放器状态机
  @override
  @JsonKey()
  final PlayerState state;

  /// 播放模式
  @override
  @JsonKey()
  final AudioPlayMode mode;

  /// TTS 配置（构造时由 Notifier 注入默认实例）
  @override
  final TtsConfig config;

  /// 章节列表
  final List<AudioChapter> _chapters;

  /// 章节列表
  @override
  @JsonKey()
  List<AudioChapter> get chapters {
    if (_chapters is EqualUnmodifiableListView) return _chapters;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_chapters);
  }

  /// 当前章节索引
  @override
  @JsonKey()
  final int currentIndex;

  /// 错误信息（null 表示无错误）
  @override
  final String? errorMessage;

  /// 当前听书书籍 URL
  @override
  @JsonKey()
  final String bookUrl;

  /// 当前听书书名
  @override
  @JsonKey()
  final String bookName;

  /// 媒体会话是否已就绪（用于 UI 显示后台播放状态）
  @override
  @JsonKey()
  final bool isMediaSessionReady;

  @override
  String toString() {
    return 'AudioState(state: $state, mode: $mode, config: $config, chapters: $chapters, currentIndex: $currentIndex, errorMessage: $errorMessage, bookUrl: $bookUrl, bookName: $bookName, isMediaSessionReady: $isMediaSessionReady)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AudioStateImpl &&
            (identical(other.state, state) || other.state == state) &&
            (identical(other.mode, mode) || other.mode == mode) &&
            (identical(other.config, config) || other.config == config) &&
            const DeepCollectionEquality().equals(other._chapters, _chapters) &&
            (identical(other.currentIndex, currentIndex) ||
                other.currentIndex == currentIndex) &&
            (identical(other.errorMessage, errorMessage) ||
                other.errorMessage == errorMessage) &&
            (identical(other.bookUrl, bookUrl) || other.bookUrl == bookUrl) &&
            (identical(other.bookName, bookName) ||
                other.bookName == bookName) &&
            (identical(other.isMediaSessionReady, isMediaSessionReady) ||
                other.isMediaSessionReady == isMediaSessionReady));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      state,
      mode,
      config,
      const DeepCollectionEquality().hash(_chapters),
      currentIndex,
      errorMessage,
      bookUrl,
      bookName,
      isMediaSessionReady);

  @JsonKey(ignore: true)
  @override
  @pragma('vm:prefer-inline')
  _$$AudioStateImplCopyWith<_$AudioStateImpl> get copyWith =>
      __$$AudioStateImplCopyWithImpl<_$AudioStateImpl>(this, _$identity);
}

abstract class _AudioState implements AudioState {
  const factory _AudioState(
      {final PlayerState state,
      final AudioPlayMode mode,
      required final TtsConfig config,
      final List<AudioChapter> chapters,
      final int currentIndex,
      final String? errorMessage,
      final String bookUrl,
      final String bookName,
      final bool isMediaSessionReady}) = _$AudioStateImpl;

  @override

  /// 播放器状态机
  PlayerState get state;
  @override

  /// 播放模式
  AudioPlayMode get mode;
  @override

  /// TTS 配置（构造时由 Notifier 注入默认实例）
  TtsConfig get config;
  @override

  /// 章节列表
  List<AudioChapter> get chapters;
  @override

  /// 当前章节索引
  int get currentIndex;
  @override

  /// 错误信息（null 表示无错误）
  String? get errorMessage;
  @override

  /// 当前听书书籍 URL
  String get bookUrl;
  @override

  /// 当前听书书名
  String get bookName;
  @override

  /// 媒体会话是否已就绪（用于 UI 显示后台播放状态）
  bool get isMediaSessionReady;
  @override
  @JsonKey(ignore: true)
  _$$AudioStateImplCopyWith<_$AudioStateImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
