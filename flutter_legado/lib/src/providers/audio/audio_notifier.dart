import 'dart:async';

import 'package:flutter/foundation.dart';
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

  // [UI-fix v2.0.1 | 2026-08-06] 阅读器底栏朗读入口：打通 底栏按钮 →
  // ReaderScreen → AudioNotifier.startReadAloud → play() → BookApi.audioSpeak
  // 的朗读链路，对齐原版 ReadBookActivity.onClickReadAloud 启动流程 — Qoder
  /// 启动指定书籍的朗读（阅读器底栏「朗读」按钮入口）
  ///
  /// 流程（对标原版 ReadBookActivity 朗读启动）：
  /// 初始化媒体会话 → 加载章节列表 → 定位到当前阅读章节 → 开始播放。
  /// 重复调用同一本书时从当前状态续播。
  Future<void> startReadAloud({
    required String bookUrl,
    required String bookName,
    int chapterIndex = 0,
  }) async {
    // 换书或章节未加载时需要重新拉取章节列表
    final needReload = state.chapters.isEmpty || state.bookUrl != bookUrl;
    state = state.copyWith(bookUrl: bookUrl, bookName: bookName);
    await initMediaSession(bookName: bookName);

    if (needReload) {
      await loadChapters(bookUrl);
    }
    if (state.chapters.isEmpty) return; // 章节加载失败时保持错误态

    // 未配置朗读引擎时取首个 HTTP TTS 引擎作为默认引擎
    if (state.config.engineUrl.isEmpty) {
      await _ensureDefaultEngine();
    }

    // 定位到阅读器当前章节后开始朗读
    final target = chapterIndex.clamp(0, state.chapters.length - 1).toInt();
    if (target != state.currentIndex) {
      state = state.copyWith(currentIndex: target);
    }
    await play();
  }

  /// 从 HTTP TTS 引擎列表取首个作为默认朗读引擎
  ///
  /// [UI-fix v2.0.1 | 2026-08-06] 真实 TTS 管线待批次2（Rust audioSpeak 缺口②） — Qoder
  /// 当前仅用于探活链路打通；批次2应改为读取用户偏好引擎配置。
  Future<void> _ensureDefaultEngine() async {
    try {
      final list = await _api.getHttpTts();
      if (list.isEmpty) return;
      // 原版引擎 URL 格式为 "url,{header/body 配置}"，探活仅取逗号前的 URL 部分
      final raw = list.first.url;
      final commaIndex = raw.indexOf(',');
      final url = commaIndex > 0 ? raw.substring(0, commaIndex) : raw;
      if (url.isNotEmpty) updateConfig(engineUrl: url);
    } catch (e) {
      debugPrint('获取默认朗读引擎失败: $e');
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
        // [UI-fix v2.0.1 | 2026-08-06] 真实 TTS 管线待批次2（Rust audioSpeak 缺口②） — Qoder
        // 当前 audioSpeak 为探活级实现（http.get 探活），探活失败不阻断朗读 UI
        // 状态机，仅留痕便于排障；批次2接入真实管线后移除该保护。
        try {
          await _api.audioSpeak(
            text: state.chapters[state.currentIndex].text,
            engineUrl: config.engineUrl,
            speed: config.speed,
            pitch: config.pitch,
            volume: config.volume,
            voiceName: config.voiceName,
          );
        } catch (e) {
          debugPrint('audioSpeak 探活失败（不影响朗读 UI 状态）: $e');
        }
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
