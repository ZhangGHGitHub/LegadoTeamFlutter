import 'package:flutter/material.dart';

import '../services/rust_api.dart';

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

/// 听书播放器状态管理
class AudioProvider extends ChangeNotifier {
  final RustApi _api;

  AudioProvider(this._api);

  PlayerState _state = PlayerState.idle;
  AudioPlayMode _mode = AudioPlayMode.sequential;
  final TtsConfig _config = TtsConfig();
  List<AudioChapter> _chapters = [];
  int _currentIndex = 0;
  String? _errorMessage;
  String _bookUrl = '';

  // ===== Getters =====

  PlayerState get state => _state;
  AudioPlayMode get mode => _mode;
  TtsConfig get config => _config;
  List<AudioChapter> get chapters => _chapters;
  int get currentIndex => _currentIndex;
  String? get errorMessage => _errorMessage;
  String get bookUrl => _bookUrl;
  bool get isPlaying => _state == PlayerState.playing;
  bool get isLoading => _state == PlayerState.loading;
  bool get hasChapters => _chapters.isNotEmpty;
  int get totalChapters => _chapters.length;

  AudioChapter? get currentChapter {
    if (_chapters.isEmpty || _currentIndex >= _chapters.length) return null;
    return _chapters[_currentIndex];
  }

  bool get hasPrevious => _currentIndex > 0;
  bool get hasNext => _currentIndex < _chapters.length - 1;

  double get progress {
    if (_chapters.isEmpty) return 0.0;
    return (_currentIndex + 1) / _chapters.length;
  }

  // ===== 操作 =====

  /// 加载章节列表
  Future<void> loadChapters(String bookUrl) async {
    _bookUrl = bookUrl;
    _state = PlayerState.loading;
    _errorMessage = null;
    notifyListeners();

    try {
      // 通过 RustApi 获取章节（复用已有的 reader 接口）
      final chapterList = await _api.getChapters(bookUrl);
      _chapters = chapterList
          .asMap()
          .entries
          .map((e) => AudioChapter(
                index: e.key,
                title: e.value.title,
                text: '', // 内容按需加载
              ))
          .toList();
      _currentIndex = 0;
      _state = PlayerState.idle;
    } catch (e) {
      _errorMessage = e.toString();
      _state = PlayerState.error;
    }
    notifyListeners();
  }

  /// 播放当前章节
  Future<void> play() async {
    if (_chapters.isEmpty) return;
    _state = PlayerState.loading;
    notifyListeners();

    try {
      // 加载章节文本内容
      final chapter = _chapters[_currentIndex];
      if (chapter.text.isEmpty) {
        final content = await _api.getChapterContent(_bookUrl, _currentIndex);
        _chapters[_currentIndex] = AudioChapter(
          index: chapter.index,
          title: chapter.title,
          text: content,
        );
      }

      // 调用 TTS 合成语音
      if (_config.engineUrl.isNotEmpty) {
        await _api.audioSpeak(
          text: _chapters[_currentIndex].text,
          engineUrl: _config.engineUrl,
          speed: _config.speed,
          pitch: _config.pitch,
          volume: _config.volume,
          voiceName: _config.voiceName,
        );
      }

      _state = PlayerState.playing;
    } catch (e) {
      _errorMessage = e.toString();
      _state = PlayerState.error;
    }
    notifyListeners();
  }

  /// 暂停
  void pause() {
    if (_state == PlayerState.playing) {
      _state = PlayerState.paused;
      notifyListeners();
    }
  }

  /// 下一章
  Future<void> next() async {
    if (!hasNext && _mode != AudioPlayMode.singleLoop) return;
    if (_mode == AudioPlayMode.singleLoop) {
      await play();
      return;
    }
    _currentIndex++;
    await play();
  }

  /// 上一章
  Future<void> previous() async {
    if (!hasPrevious) return;
    _currentIndex--;
    await play();
  }

  /// 跳转到指定章节
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    _currentIndex = index;
    await play();
  }

  /// 更新播放模式
  void setMode(AudioPlayMode mode) {
    _mode = mode;
    notifyListeners();
  }

  /// 更新 TTS 配置
  void updateConfig({
    String? engineUrl,
    String? voiceName,
    double? speed,
    double? pitch,
    double? volume,
  }) {
    if (engineUrl != null) _config.engineUrl = engineUrl;
    if (voiceName != null) _config.voiceName = voiceName;
    if (speed != null) _config.speed = speed.clamp(0.5, 3.0);
    if (pitch != null) _config.pitch = pitch.clamp(0.5, 2.0);
    if (volume != null) _config.volume = volume.clamp(0.0, 1.0);
    notifyListeners();
  }
}
