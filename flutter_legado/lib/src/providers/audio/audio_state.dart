import 'package:freezed_annotation/freezed_annotation.dart';

part 'audio_state.freezed.dart';

/// 播放状态
enum PlayerState {
  idle,
  playing,
  paused,
  loading,
  error,
}

/// 播放模式
enum AudioPlayMode {
  sequential,
  singleLoop,
  shuffle,
}

/// TTS 配置
class TtsConfig {
  String engineUrl;
  String? voiceName;
  double speed;
  double pitch;
  double volume;

  TtsConfig({
    this.engineUrl = '',
    this.voiceName,
    this.speed = 1.0,
    this.pitch = 1.0,
    this.volume = 1.0,
  });

  Map<String, dynamic> toJson() => {
        'engine_url': engineUrl,
        'voice_name': voiceName,
        'speed': speed,
        'pitch': pitch,
        'volume': volume,
      };
}

/// 音频章节信息
class AudioChapter {
  final int index;
  final String title;
  final String text;
  final int? durationEstimateMs;

  AudioChapter({
    required this.index,
    required this.title,
    required this.text,
    this.durationEstimateMs,
  });

  factory AudioChapter.fromJson(Map<String, dynamic> json) {
    return AudioChapter(
      index: json['index'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      text: json['text'] as String? ?? '',
      durationEstimateMs: json['duration_estimate_ms'] as int?,
    );
  }
}

/// 听书播放器 UI 状态（immutable）
///
/// 由原 AudioProvider（ChangeNotifier）的可观察字段迁移而来，逐字段对齐：
/// - [state]：播放器状态机（idle/playing/paused/loading/error）
/// - [mode]：播放模式（顺序/单曲循环/随机）
/// - [config]：TTS 配置（引擎/语速/音调/音量/音色）
/// - [chapters] / [currentIndex]：章节列表与当前章节索引
/// - [errorMessage]：错误信息（null 表示无错误）
/// - [bookUrl] / [bookName]：当前听书的书籍标识
/// - [isMediaSessionReady]：媒体会话是否已就绪（用于 UI 显示后台播放状态）
@freezed
class AudioState with _$AudioState {
  const factory AudioState({
    /// 播放器状态机
    @Default(PlayerState.idle) PlayerState state,

    /// 播放模式
    @Default(AudioPlayMode.sequential) AudioPlayMode mode,

    /// TTS 配置（构造时由 Notifier 注入默认实例）
    required TtsConfig config,

    /// 章节列表
    @Default(<AudioChapter>[]) List<AudioChapter> chapters,

    /// 当前章节索引
    @Default(0) int currentIndex,

    /// 错误信息（null 表示无错误）
    String? errorMessage,

    /// 当前听书书籍 URL
    @Default('') String bookUrl,

    /// 当前听书书名
    @Default('') String bookName,

    /// 媒体会话是否已就绪（用于 UI 显示后台播放状态）
    @Default(false) bool isMediaSessionReady,
  }) = _AudioState;
}

/// 听书播放器展示扩展 —— 纯派生逻辑，与原 AudioProvider 的 getter 语义一一对应
extension AudioStateDerived on AudioState {
  /// 是否正在播放
  bool get isPlaying => state == PlayerState.playing;

  /// 是否正在加载
  bool get isLoading => state == PlayerState.loading;

  /// 是否已有章节
  bool get hasChapters => chapters.isNotEmpty;

  /// 章节总数
  int get totalChapters => chapters.length;

  /// 当前章节（越界或为空时返回 null）
  AudioChapter? get currentChapter {
    if (chapters.isEmpty || currentIndex >= chapters.length) return null;
    return chapters[currentIndex];
  }

  /// 是否存在上一章
  bool get hasPrevious => currentIndex > 0;

  /// 是否存在下一章
  bool get hasNext => currentIndex < chapters.length - 1;

  /// 播放进度（0.0 ~ 1.0）
  double get progress {
    if (chapters.isEmpty) return 0.0;
    return (currentIndex + 1) / chapters.length;
  }
}
