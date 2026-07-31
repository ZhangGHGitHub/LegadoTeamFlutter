import 'dart:async';

import 'package:flutter/material.dart';

import '../services/audio_service.dart';
import '../services/book_api.dart';
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
  final BookApi _api;

  /// 音频服务（后台媒体按钮 + 焦点管理）
  final AudioService _audioService = AudioService.instance;

  /// 媒体按钮事件订阅
  StreamSubscription<MediaButtonEvent>? _mediaButtonSub;

  /// 音频焦点事件订阅
  StreamSubscription<AudioFocusEvent>? _audioFocusSub;

  /// 媒体会话是否已初始化
  bool _mediaSessionReady = false;

  AudioProvider(this._api);

  PlayerState _state = PlayerState.idle;
  AudioPlayMode _mode = AudioPlayMode.sequential;
  final TtsConfig _config = TtsConfig();
  List<AudioChapter> _chapters = [];
  int _currentIndex = 0;
  String? _errorMessage;
  String _bookUrl = '';
  String _bookName = '';

  // ===== Getters =====

  PlayerState get state => _state;
  AudioPlayMode get mode => _mode;
  TtsConfig get config => _config;
  List<AudioChapter> get chapters => _chapters;
  int get currentIndex => _currentIndex;
  String? get errorMessage => _errorMessage;
  String get bookUrl => _bookUrl;
  String get bookName => _bookName;
  bool get isPlaying => _state == PlayerState.playing;
  bool get isLoading => _state == PlayerState.loading;
  bool get hasChapters => _chapters.isNotEmpty;
  int get totalChapters => _chapters.length;

  /// 媒体会话是否已就绪（用于 UI 显示后台播放状态）
  bool get isMediaSessionReady => _mediaSessionReady;

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

  /// 初始化媒体会话（后台播放 + 媒体按钮 + 焦点管理）
  ///
  /// 在听书页面 initState 时调用，完成：
  /// - 初始化 Android MediaSession
  /// - 监听媒体按钮事件（播放/暂停/上一章/下一章/停止）
  /// - 监听音频焦点变化（获得/丢失/暂时丢失）
  Future<void> initMediaSession({String bookName = ''}) async {
    if (bookName.isNotEmpty) _bookName = bookName;
    if (_mediaSessionReady) return;

    await _audioService.init();

    // 监听媒体按钮事件，回调到对应操作
    _mediaButtonSub = _audioService.mediaButtonStream.listen((event) {
      switch (event) {
        case MediaButtonEvent.play:
          play();
        case MediaButtonEvent.pause:
          pause();
        case MediaButtonEvent.skipToNext:
          next();
        case MediaButtonEvent.skipToPrevious:
          previous();
        case MediaButtonEvent.stop:
          stop();
      }
    });

    // 监听音频焦点变化（复刻原版 BaseReadAloudService.onAudioFocusChange）
    _audioFocusSub = _audioService.audioFocusStream.listen((event) {
      switch (event) {
        case AudioFocusEvent.gain:
          // 重新获得焦点，恢复播放
          if (_state == PlayerState.paused) {
            play();
          }
        case AudioFocusEvent.loss:
          // 永久丢失焦点，暂停播放
          pause();
        case AudioFocusEvent.lossTransient:
          // 暂时丢失焦点，暂停（之后 gain 会恢复）
          pause();
        case AudioFocusEvent.lossTransientCanDuck:
          // 短暂丢失（可降低音量），暂不处理
          break;
      }
    });

    _mediaSessionReady = _audioService.isInitialized;
    notifyListeners();
  }

  /// 释放媒体会话资源
  ///
  /// 在听书页面 dispose 时调用。
  Future<void> releaseMediaSession() async {
    _mediaButtonSub?.cancel();
    _mediaButtonSub = null;
    _audioFocusSub?.cancel();
    _audioFocusSub = null;
    await _audioService.dispose();
    _mediaSessionReady = false;
  }

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

      // 通知媒体会话：请求焦点 + 更新元数据 + 更新播放状态
      await _syncMediaSession();
    } catch (e) {
      _errorMessage = e.toString();
      _state = PlayerState.error;
    }
    notifyListeners();
  }

  /// 同步媒体会话状态（焦点 + 元数据 + 播放状态）
  Future<void> _syncMediaSession() async {
    if (!_mediaSessionReady) return;

    // 请求音频焦点
    await _audioService.requestAudioFocus();

    // 更新媒体元数据（章节标题 / 书名 / 作者）
    final chapter = currentChapter;
    await _audioService.updateMetadata(
      title: chapter?.title ?? '',
      artist: _bookName.isNotEmpty ? '正在朗读: $_bookName' : '',
      album: _bookName,
    );

    // 更新播放状态
    await _audioService.notifyPlaying();
  }

  /// 暂停
  void pause() {
    if (_state == PlayerState.playing) {
      _state = PlayerState.paused;
      // 通知媒体会话暂停状态
      _audioService.notifyPaused();
      notifyListeners();
    }
  }

  /// 停止播放并释放焦点
  void stop() {
    _state = PlayerState.idle;
    _audioService.notifyStopped();
    _audioService.abandonAudioFocus();
    notifyListeners();
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

  @override
  void dispose() {
    // 释放媒体会话资源
    _mediaButtonSub?.cancel();
    _audioFocusSub?.cancel();
    _audioService.dispose();
    super.dispose();
  }
}
