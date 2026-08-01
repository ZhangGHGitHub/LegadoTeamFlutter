import 'dart:async';

// 本文件需使用 Riverpod 的 Provider 定义 audioServiceProvider，
// 且未引入 provider 包，故不 hide Provider（仅 ChangeNotifierProvider 无需引用）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/audio_service.dart';
import '../../services/book_api.dart';
import '../providers.dart';
import 'audio_state.dart';

export 'audio_state.dart';

/// 听书播放器 Riverpod Notifier
///
/// 由原 AudioProvider（ChangeNotifier）迁移而来，行为逐一对齐：
/// - 调用 BookApi 获取章节 / 正文 / TTS 合成 → 更新 immutable State
/// - 管理播放状态机（idle/playing/paused/loading/error）
/// - 管理媒体会话（后台播放 + 媒体按钮 + 焦点管理，透传 AudioService）
/// - 管理 TTS 配置与播放模式
class AudioNotifier extends Notifier<AudioState> {
  /// 音频服务（后台媒体按钮 + 焦点管理）
  ///
  /// build() 时捕获实例，便于在 onDispose 中安全释放（避免 dispose 期再读 ref）。
  late final AudioService _audioService;

  /// 媒体按钮事件订阅
  StreamSubscription<MediaButtonEvent>? _mediaButtonSub;

  /// 音频焦点事件订阅
  StreamSubscription<AudioFocusEvent>? _audioFocusSub;

  /// BookApi 读取入口（与 explore/search 模块保持一致的注入方式）
  BookApi get _api => ref.read(bookApiProvider);

  @override
  AudioState build() {
    _audioService = ref.read(audioServiceProvider);
    // 复刻原 AudioProvider.dispose：释放媒体会话资源
    ref.onDispose(() {
      _mediaButtonSub?.cancel();
      _audioFocusSub?.cancel();
      _audioService.dispose();
    });
    // 初始状态：注入默认 TTS 配置，其余字段取默认值
    return AudioState(config: TtsConfig());
  }

  // ===== 操作 =====

  /// 初始化媒体会话（后台播放 + 媒体按钮 + 焦点管理）
  ///
  /// 在听书页面 initState 时调用，完成：
  /// - 初始化 Android MediaSession
  /// - 监听媒体按钮事件（播放/暂停/上一章/下一章/停止）
  /// - 监听音频焦点变化（获得/丢失/暂时丢失）
  Future<void> initMediaSession({String bookName = ''}) async {
    if (bookName.isNotEmpty) state = state.copyWith(bookName: bookName);
    if (state.isMediaSessionReady) return;

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
          if (state.state == PlayerState.paused) {
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

    state = state.copyWith(isMediaSessionReady: _audioService.isInitialized);
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
    state = state.copyWith(isMediaSessionReady: false);
  }

  /// 加载章节列表
  Future<void> loadChapters(String bookUrl) async {
    state = state.copyWith(
      bookUrl: bookUrl,
      state: PlayerState.loading,
      errorMessage: null,
    );

    try {
      // 通过 RustApi 获取章节（复用已有的 reader 接口）
      final chapterList = await _api.getChapters(bookUrl);
      final chapters = chapterList
          .asMap()
          .entries
          .map((e) => AudioChapter(
                index: e.key,
                title: e.value.title,
                text: '', // 内容按需加载
              ))
          .toList();
      state = state.copyWith(
        chapters: chapters,
        currentIndex: 0,
        state: PlayerState.idle,
      );
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString(),
        state: PlayerState.error,
      );
    }
  }

  /// 播放当前章节
  Future<void> play() async {
    if (state.chapters.isEmpty) return;
    state = state.copyWith(state: PlayerState.loading);

    try {
      // 加载章节文本内容
      final chapter = state.chapters[state.currentIndex];
      if (chapter.text.isEmpty) {
        final content =
            await _api.getChapterContent(state.bookUrl, state.currentIndex);
        final chapters = [...state.chapters];
        chapters[state.currentIndex] = AudioChapter(
          index: chapter.index,
          title: chapter.title,
          text: content,
        );
        state = state.copyWith(chapters: chapters);
      }

      // 调用 TTS 合成语音
      final config = state.config;
      if (config.engineUrl.isNotEmpty) {
        await _api.audioSpeak(
          text: state.chapters[state.currentIndex].text,
          engineUrl: config.engineUrl,
          speed: config.speed,
          pitch: config.pitch,
          volume: config.volume,
          voiceName: config.voiceName,
        );
      }

      state = state.copyWith(state: PlayerState.playing);

      // 通知媒体会话：请求焦点 + 更新元数据 + 更新播放状态
      await _syncMediaSession();
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString(),
        state: PlayerState.error,
      );
    }
  }

  /// 同步媒体会话状态（焦点 + 元数据 + 播放状态）
  Future<void> _syncMediaSession() async {
    if (!state.isMediaSessionReady) return;

    // 请求音频焦点
    await _audioService.requestAudioFocus();

    // 更新媒体元数据（章节标题 / 书名 / 作者）
    final chapter = state.currentChapter;
    await _audioService.updateMetadata(
      title: chapter?.title ?? '',
      artist: state.bookName.isNotEmpty ? '正在朗读: ${state.bookName}' : '',
      album: state.bookName,
    );

    // 更新播放状态
    await _audioService.notifyPlaying();
  }

  /// 暂停
  void pause() {
    if (state.state == PlayerState.playing) {
      state = state.copyWith(state: PlayerState.paused);
      // 通知媒体会话暂停状态
      _audioService.notifyPaused();
    }
  }

  /// 停止播放并释放焦点
  void stop() {
    state = state.copyWith(state: PlayerState.idle);
    _audioService.notifyStopped();
    _audioService.abandonAudioFocus();
  }

  /// 下一章
  Future<void> next() async {
    if (!state.hasNext && state.mode != AudioPlayMode.singleLoop) return;
    if (state.mode == AudioPlayMode.singleLoop) {
      await play();
      return;
    }
    state = state.copyWith(currentIndex: state.currentIndex + 1);
    await play();
  }

  /// 上一章
  Future<void> previous() async {
    if (!state.hasPrevious) return;
    state = state.copyWith(currentIndex: state.currentIndex - 1);
    await play();
  }

  /// 跳转到指定章节
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.chapters.length) return;
    state = state.copyWith(currentIndex: index);
    await play();
  }

  /// 更新播放模式
  void setMode(AudioPlayMode mode) {
    state = state.copyWith(mode: mode);
  }

  /// 更新 TTS 配置
  void updateConfig({
    String? engineUrl,
    String? voiceName,
    double? speed,
    double? pitch,
    double? volume,
  }) {
    final config = state.config;
    // 复刻原 AudioProvider.updateConfig：null 参数不更新对应字段，数值参数按范围 clamp
    final updated = TtsConfig(
      engineUrl: engineUrl ?? config.engineUrl,
      voiceName: voiceName ?? config.voiceName,
      speed: speed != null ? speed.clamp(0.5, 3.0) : config.speed,
      pitch: pitch != null ? pitch.clamp(0.5, 2.0) : config.pitch,
      volume: volume != null ? volume.clamp(0.0, 1.0) : config.volume,
    );
    state = state.copyWith(config: updated);
  }
}

/// 听书播放器 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(audioNotifierProvider);
/// ref.read(audioNotifierProvider.notifier).play();
/// ```
final audioNotifierProvider = NotifierProvider<AudioNotifier, AudioState>(
  AudioNotifier.new,
);

/// AudioService 注入 Provider
///
/// 默认返回全局单例 AudioService.instance（与原 AudioProvider 使用方式一致），
/// 单元测试中可通过 overrideWithValue 注入 MockAudioService。
final audioServiceProvider = Provider<AudioService>(
  (ref) => AudioService.instance,
);
