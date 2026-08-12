import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/book.dart';
import '../../services/audio_service.dart';
import '../../services/book_api.dart';
import '../../services/stream_audio_player.dart';
import '../../utils/audio_skip_policy.dart';
import '../providers.dart';
import 'audio_state.dart';

export 'audio_state.dart';

/// 听书播放器 Riverpod Notifier
///
/// 双路径：
/// - 音频书（BookType.audio）：getAudioChapterMedia 取址 → StreamAudioPlayer
/// - TTS 朗读：段落化 audioSpeak（阅读器朗读入口）
///
/// — Auto + UI｜2026-08-12（P0-2 流媒体接线）
class AudioNotifier extends Notifier<AudioState> with ChangeNotifier {
  late final AudioService _audioService;
  final StreamAudioPlayer _streamPlayer = StreamAudioPlayer();

  StreamSubscription<MediaButtonEvent>? _mediaButtonSub;
  StreamSubscription<AudioFocusEvent>? _audioFocusSub;

  BookApi get _api => ref.read(bookApiProvider);

  static const double _kCharsPerSecond = 5.0;
  static const Duration _kMinParagraphDuration = Duration(milliseconds: 800);
  static const Duration _kMaxParagraphDuration = Duration(seconds: 90);
  static const int _kProgressThrottleMs = 400;

  List<String> _paragraphs = [];
  int _paragraphIndex = 0;
  Timer? _paragraphTimer;
  int _playToken = 0;
  int? _pendingParagraphIndex;
  bool _introSkipEvaluated = false;
  AudioSkipWindow? _skipWindow;
  Book? _book;
  bool _disposed = false;
  int _lastProgressEmitMs = 0;

  int get currentParagraphIndex => _paragraphIndex;
  int get paragraphCount => _paragraphs.length;
  bool get hasPrevParagraph => _paragraphs.isNotEmpty && _paragraphIndex > 0;
  bool get hasNextParagraph =>
      _paragraphs.isNotEmpty && _paragraphIndex < _paragraphs.length - 1;
  bool get isAudioBookMode => state.isStreamMode;
  String? get currentMediaUrl =>
      state.mediaUrl.isEmpty ? null : state.mediaUrl;
  int get streamPositionMs => state.positionMs;
  int get streamDurationMs => state.durationMs;

  void setAudioBookMode(bool isAudioBook) {
    if (state.isStreamMode == isAudioBook) return;
    state = state.copyWith(
      isStreamMode: isAudioBook,
      mediaUrl: isAudioBook ? state.mediaUrl : '',
      positionMs: 0,
      durationMs: 0,
      lyric: isAudioBook ? state.lyric : null,
    );
  }

  @override
  AudioState build() {
    _audioService = ref.read(audioServiceProvider);
    _streamPlayer.onCompleted = () {
      if (_disposed || !state.isStreamMode) return;
      unawaited(_onStreamCompleted());
    };
    _streamPlayer.onProgress = (pos, dur) {
      if (_disposed || !state.isStreamMode) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastProgressEmitMs < _kProgressThrottleMs &&
          dur.inMilliseconds == state.durationMs) {
        // 片尾仍需检测
        unawaited(_maybeApplySkip(pos.inMilliseconds, dur.inMilliseconds));
        return;
      }
      _lastProgressEmitMs = now;
      state = state.copyWith(
        positionMs: pos.inMilliseconds,
        durationMs: dur.inMilliseconds,
      );
      unawaited(_maybeApplySkip(pos.inMilliseconds, dur.inMilliseconds));
    };
    ref.onDispose(() {
      _disposed = true;
      _mediaButtonSub?.cancel();
      _audioFocusSub?.cancel();
      _paragraphTimer?.cancel();
      unawaited(_streamPlayer.dispose());
      _audioService.dispose();
    });
    return AudioState(config: TtsConfig());
  }

  Future<void> initMediaSession({String bookName = ''}) async {
    if (bookName.isNotEmpty) state = state.copyWith(bookName: bookName);
    if (state.isMediaSessionReady) return;

    await _audioService.init();

    _mediaButtonSub = _audioService.mediaButtonStream.listen((event) {
      switch (event) {
        case MediaButtonEvent.play:
          unawaited(resumeOrPlay());
        case MediaButtonEvent.pause:
          pause();
        case MediaButtonEvent.skipToNext:
          unawaited(next());
        case MediaButtonEvent.skipToPrevious:
          unawaited(previous());
        case MediaButtonEvent.stop:
          stop();
      }
    });

    _audioFocusSub = _audioService.audioFocusStream.listen((event) {
      switch (event) {
        case AudioFocusEvent.gain:
          if (state.state == PlayerState.paused) {
            unawaited(resumeOrPlay());
          }
        case AudioFocusEvent.loss:
          pause();
        case AudioFocusEvent.lossTransient:
          pause();
        case AudioFocusEvent.lossTransientCanDuck:
          break;
      }
    });

    state = state.copyWith(isMediaSessionReady: _audioService.isInitialized);
  }

  Future<void> releaseMediaSession() async {
    _mediaButtonSub?.cancel();
    _mediaButtonSub = null;
    _audioFocusSub?.cancel();
    _audioFocusSub = null;
    await _audioService.dispose();
    state = state.copyWith(isMediaSessionReady: false);
  }

  Future<void> loadChapters(String bookUrl) async {
    state = state.copyWith(
      bookUrl: bookUrl,
      state: PlayerState.loading,
      errorMessage: null,
    );

    try {
      var chapterList = await _api.getChapters(bookUrl);
      final book = await _api.getBook(bookUrl);
      if (chapterList.isEmpty) {
        final origin = book?.origin ?? '';
        if (origin.isNotEmpty) {
          chapterList = await _api.refreshToc(bookUrl, origin);
        }
      }
      final inferredAudio =
          book != null && (book.bookType & BookType.audio) == BookType.audio;
      final chapters = chapterList
          .asMap()
          .entries
          .map(
            (e) => AudioChapter(
              index: e.key,
              title: e.value.title,
              text: '',
            ),
          )
          .toList();
      state = state.copyWith(
        chapters: chapters,
        currentIndex: 0,
        state: PlayerState.idle,
        // 听书页已 setAudioBookMode(true) 时保留；否则按落库 type 位推断
        isStreamMode: state.isStreamMode || inferredAudio,
      );
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString(),
        state: PlayerState.error,
      );
    }
  }

  /// 阅读器朗读入口（固定 TTS，不走音频书流媒体）
  Future<void> startReadAloud({
    required String bookUrl,
    required String bookName,
    int chapterIndex = 0,
    int? startChapterPos,
    String? startParagraphText,
  }) async {
    setAudioBookMode(false);
    await _streamPlayer.stop();
    final needReload = state.chapters.isEmpty || state.bookUrl != bookUrl;
    state = state.copyWith(
      bookUrl: bookUrl,
      bookName: bookName,
      isStreamMode: false,
      mediaUrl: '',
      positionMs: 0,
      durationMs: 0,
      lyric: null,
    );
    await initMediaSession(bookName: bookName);

    if (needReload) {
      await loadChapters(bookUrl);
      // loadChapters 可能按 type 位推断流媒体；朗读入口强制 TTS
      setAudioBookMode(false);
    }
    if (state.chapters.isEmpty) return;

    if (state.config.engineUrl.isEmpty) {
      await _ensureDefaultEngine();
    }

    final target = chapterIndex.clamp(0, state.chapters.length - 1).toInt();
    if (target != state.currentIndex) {
      state = state.copyWith(currentIndex: target);
    }
    _pendingParagraphIndex = null;
    try {
      final content = await _ensureChapterContent(state.currentIndex);
      final pos = startChapterPos;
      if (pos != null && pos > 0) {
        _pendingParagraphIndex = _mapOffsetToParagraph(content, pos);
      }
      final paraText = startParagraphText?.trim();
      if (_pendingParagraphIndex == null &&
          paraText != null &&
          paraText.isNotEmpty) {
        _pendingParagraphIndex = _mapTextToParagraph(content, paraText);
      }
    } catch (e) {
      debugPrint('朗读起点定位失败（回退章首）: $e');
    }
    await play();
  }

  static int? _mapTextToParagraph(String content, String text) {
    final paragraphs = _splitParagraphsWithOffsets(content);
    for (var i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].text == text) return i;
    }
    return null;
  }

  Future<void> _ensureDefaultEngine() async {
    try {
      final list = await _api.getHttpTts();
      if (list.isEmpty) return;
      final raw = list.first.url;
      final commaIndex = raw.indexOf(',');
      final url = commaIndex > 0 ? raw.substring(0, commaIndex) : raw;
      if (url.isNotEmpty) updateConfig(engineUrl: url);
    } catch (e) {
      debugPrint('获取默认朗读引擎失败: $e');
    }
  }

  Future<void> play({int? paragraphIndex}) async {
    if (state.chapters.isEmpty) return;
    if (state.isStreamMode) {
      await _playAudioBookStream();
      return;
    }
    await _playTtsParagraphs(paragraphIndex: paragraphIndex);
  }

  Future<void> _playAudioBookStream() async {
    state = state.copyWith(state: PlayerState.loading, errorMessage: null);
    final token = ++_playToken;
    try {
      var index = state.currentIndex;
      while (index < state.chapters.length) {
        final media = await _api.getAudioChapterMedia(state.bookUrl, index);
        if (token != _playToken || _disposed) return;
        final isVolume = media['isVolume'] == true;
        final mediaUrl = (media['mediaUrl'] as String?)?.trim() ?? '';
        if (isVolume || mediaUrl.isEmpty) {
          if (index + 1 >= state.chapters.length) {
            state = state.copyWith(
              errorMessage: (!isVolume && mediaUrl.isEmpty)
                  ? '未获取到资源链接'
                  : '无可播放章节',
              state: PlayerState.error,
            );
            return;
          }
          index++;
          state = state.copyWith(currentIndex: index);
          continue;
        }
        final lyric = (media['lyric'] as String?)?.trim();
        state = state.copyWith(
          currentIndex: index,
          mediaUrl: mediaUrl,
          positionMs: 0,
          durationMs: 0,
          lyric: (lyric == null || lyric.isEmpty) ? null : lyric,
          state: PlayerState.playing,
        );
        await _streamPlayer.playUrl(mediaUrl, speed: state.config.speed);
        if (token != _playToken || _disposed) return;
        await _syncMediaSession();
        _introSkipEvaluated = false;
        _skipWindow = null;
        // 恢复进度；从头播放时再套用片头跳过
        var restoredPos = 0;
        try {
          final progress = await _api.getAudioProgress(state.bookUrl, index);
          restoredPos = (progress?['position'] as num?)?.toInt() ?? 0;
          if (restoredPos > 1500 && token == _playToken && !_disposed) {
            await _streamPlayer.seek(Duration(milliseconds: restoredPos));
          }
        } catch (e) {
          debugPrint('恢复音频进度失败: $e');
        }
        if (restoredPos <= 1500) {
          await _applyIntroSkipIfNeeded(token);
        }
        return;
      }
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString(),
        state: PlayerState.error,
      );
    }
  }

  Future<void> _onStreamCompleted() async {
    if (!state.isStreamMode || state.state != PlayerState.playing) return;
    if (state.mode == AudioPlayMode.singleLoop) {
      await play();
      return;
    }
    if (state.hasNext) {
      await next();
      return;
    }
    stop();
  }

  Future<void> _playTtsParagraphs({int? paragraphIndex}) async {
    state = state.copyWith(state: PlayerState.loading);
    final token = ++_playToken;
    try {
      final content = await _ensureChapterContent(state.currentIndex);
      if (token != _playToken || _disposed) return;
      final paragraphs =
          _splitParagraphsWithOffsets(content).map((p) => p.text).toList();
      if (paragraphs.isEmpty && content.trim().isNotEmpty) {
        paragraphs.add(content.trim());
      }
      _paragraphs = paragraphs;
      final pending = _pendingParagraphIndex;
      _pendingParagraphIndex = null;
      final target = paragraphIndex ??
          pending ??
          (_paragraphs.isNotEmpty
              ? _paragraphIndex.clamp(0, _paragraphs.length - 1)
              : 0);
      _paragraphIndex =
          _paragraphs.isEmpty ? 0 : target.clamp(0, _paragraphs.length - 1);
      notifyListeners();
      state = state.copyWith(state: PlayerState.playing);
      await _syncMediaSession();
      if (token != _playToken || _disposed) return;
      await _speakCurrentParagraph(token);
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString(),
        state: PlayerState.error,
      );
    }
  }

  Future<String> _ensureChapterContent(int chapterIndex) async {
    final chapter = state.chapters[chapterIndex];
    if (chapter.text.isNotEmpty) return chapter.text;
    final content = await _api.getChapterContent(state.bookUrl, chapterIndex);
    final chapters = [...state.chapters];
    chapters[chapterIndex] = AudioChapter(
      index: chapter.index,
      title: chapter.title,
      text: content,
    );
    state = state.copyWith(chapters: chapters);
    return content;
  }

  static List<({int start, String text})> _splitParagraphsWithOffsets(
    String content,
  ) {
    final result = <({int start, String text})>[];
    if (content.trim().isEmpty) return result;
    final splitter =
        content.contains('\n\n') ? RegExp(r'\n\s*\n') : RegExp('\n');
    var pos = 0;
    void emit(String segment, int segmentStart) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty) return;
      result.add((
        start: segmentStart + segment.indexOf(trimmed),
        text: trimmed,
      ));
    }

    for (final match in splitter.allMatches(content)) {
      emit(content.substring(pos, match.start), pos);
      pos = match.end;
    }
    emit(content.substring(pos), pos);
    return result;
  }

  static int _mapOffsetToParagraph(String content, int offset) {
    final paragraphs = _splitParagraphsWithOffsets(content);
    if (paragraphs.isEmpty) return 0;
    var index = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].start <= offset) index = i;
    }
    return index;
  }

  Future<void> _speakCurrentParagraph(int token) async {
    _paragraphTimer?.cancel();
    if (_paragraphs.isEmpty) return;
    final text = _paragraphs[_paragraphIndex];
    final config = state.config;
    if (config.engineUrl.isNotEmpty) {
      try {
        await _api.audioSpeak(
          text: text,
          engineUrl: config.engineUrl,
          speed: config.speed,
          pitch: config.pitch,
          volume: config.volume,
          voiceName: config.voiceName,
        );
      } catch (e) {
        debugPrint('audioSpeak 失败（不影响朗读 UI 状态）: $e');
      }
    }
    if (token != _playToken || _disposed) return;

    final speed = config.speed <= 0 ? 1.0 : config.speed;
    final seconds = text.length / (_kCharsPerSecond * speed);
    var duration = Duration(milliseconds: (seconds * 1000).round());
    if (duration < _kMinParagraphDuration) {
      duration = _kMinParagraphDuration;
    } else if (duration > _kMaxParagraphDuration) {
      duration = _kMaxParagraphDuration;
    }
    _paragraphTimer = Timer(duration, () {
      if (token != _playToken || _disposed) return;
      unawaited(_onParagraphFinished());
    });
  }

  Future<void> _onParagraphFinished() async {
    if (state.state != PlayerState.playing) return;
    if (_paragraphIndex < _paragraphs.length - 1) {
      _paragraphIndex++;
      notifyListeners();
      await _speakCurrentParagraph(_playToken);
      return;
    }
    if (state.mode == AudioPlayMode.singleLoop) {
      _paragraphIndex = 0;
      notifyListeners();
      await _speakCurrentParagraph(_playToken);
      return;
    }
    if (state.hasNext) {
      await next();
      return;
    }
    stop();
  }

  Future<void> nextParagraph() async {
    if (state.isStreamMode) return;
    if (_paragraphs.isEmpty || state.state == PlayerState.idle) return;
    if (_paragraphIndex < _paragraphs.length - 1) {
      _paragraphIndex++;
      notifyListeners();
      final token = _playToken;
      if (state.isPlaying) await _speakCurrentParagraph(token);
      return;
    }
    if (state.hasNext) {
      _paragraphIndex = 0;
      await next();
    }
  }

  Future<void> prevParagraph() async {
    if (state.isStreamMode) return;
    if (_paragraphs.isEmpty || state.state == PlayerState.idle) return;
    if (_paragraphIndex > 0) {
      _paragraphIndex--;
      notifyListeners();
      final token = _playToken;
      if (state.isPlaying) await _speakCurrentParagraph(token);
      return;
    }
    if (state.hasPrevious) {
      _paragraphIndex = 0;
      await previous();
    }
  }

  Future<void> _syncMediaSession() async {
    if (!state.isMediaSessionReady) return;
    await _audioService.requestAudioFocus();
    final chapter = state.currentChapter;
    final artistPrefix = state.isStreamMode ? '正在播放' : '正在朗读';
    await _audioService.updateMetadata(
      title: chapter?.title ?? '',
      artist: state.bookName.isNotEmpty ? '$artistPrefix: ${state.bookName}' : '',
      album: state.bookName,
    );
    await _audioService.notifyPlaying();
  }

  /// 绑定当前书籍（片头/片尾读 readConfig）
  void bindBook(Book? book) {
    _book = book;
  }

  /// 听书唤醒锁（对齐 audioPlayWakeLock）
  Future<void> setWakeLockEnabled(bool enabled) async {
    await _audioService.setWakeLock(enabled);
    try {
      await _api.setConfig(kAudioPlayWakeLockKey, enabled ? 'true' : 'false');
    } catch (_) {}
  }

  Future<bool> isWakeLockEnabled() async {
    try {
      return await _api.getConfig(kAudioPlayWakeLockKey) == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyIntroSkipIfNeeded(int token) async {
    if (_introSkipEvaluated || token != _playToken || _disposed) return;
    final dur = _streamPlayer.duration.inMilliseconds;
    if (dur <= 0) return;
    final window = await _resolveSkipWindow(dur);
    _skipWindow = window;
    _introSkipEvaluated = true;
    if (window == null) return;
    final seekTo = introSeekPosition(currentPositionMs: 0, window: window);
    if (seekTo == null) return;
    await _streamPlayer.seek(Duration(milliseconds: seekTo));
    state = state.copyWith(positionMs: seekTo, durationMs: dur);
  }

  Future<void> _maybeApplySkip(int positionMs, int durationMs) async {
    if (!state.isStreamMode || state.state != PlayerState.playing) return;
    if (!_introSkipEvaluated && positionMs <= 0) {
      await _applyIntroSkipIfNeeded(_playToken);
    }
    final window = _skipWindow ?? await _resolveSkipWindow(durationMs);
    _skipWindow = window;
    if (window == null) return;
    if (shouldSkipOutro(currentPositionMs: positionMs, window: window)) {
      await _onStreamCompleted();
    }
  }

  Future<AudioSkipWindow?> _resolveSkipWindow(int durationMs) async {
    var globalOpen = 0;
    var globalClose = 0;
    try {
      globalOpen =
          int.tryParse(await _api.getConfig(kAudioSkipOpenCreditsKey) ?? '0') ??
              0;
      globalClose =
          int.tryParse(await _api.getConfig(kAudioSkipCloseCreditsKey) ?? '0') ??
              0;
    } catch (_) {}
    final cfg = _book?.readConfig;
    final cfgMap = cfg == null
        ? null
        : <String, dynamic>{
            'openCredits': cfg.openCredits,
            'closeCredits': cfg.closeCredits,
            // freezed 暂无该字段：有书级非零片头/片尾则视为书级
            'useGlobalAudioSkip':
                cfg.openCredits == 0 && cfg.closeCredits == 0,
          };
    final open = resolveOpenCredits(readConfig: cfgMap, globalOpen: globalOpen);
    final close =
        resolveCloseCredits(readConfig: cfgMap, globalClose: globalClose);
    return resolveAudioSkipWindow(
      durationMs: durationMs,
      introSeconds: open,
      outroSeconds: close,
    );
  }

  void pause() {
    if (state.state == PlayerState.playing) {
      _paragraphTimer?.cancel();
      if (state.isStreamMode) {
        unawaited(_streamPlayer.pause());
        unawaited(
          _api.saveAudioProgress(
            state.bookUrl,
            state.currentIndex,
            state.positionMs,
          ),
        );
      } else {
        _playToken++;
      }
      state = state.copyWith(state: PlayerState.paused);
      _audioService.notifyPaused();
    }
  }

  Future<void> resumeOrPlay() async {
    if (state.state == PlayerState.paused &&
        state.isStreamMode &&
        _streamPlayer.isInitialized) {
      await _streamPlayer.resume();
      state = state.copyWith(state: PlayerState.playing);
      await _syncMediaSession();
      return;
    }
    await play();
  }

  void stop() {
    _paragraphTimer?.cancel();
    _playToken++;
    _paragraphs = [];
    _paragraphIndex = 0;
    unawaited(_streamPlayer.stop());
    notifyListeners();
    state = state.copyWith(
      state: PlayerState.idle,
      mediaUrl: '',
      positionMs: 0,
      durationMs: 0,
      lyric: null,
    );
    _audioService.notifyStopped();
    _audioService.abandonAudioFocus();
  }

  Future<void> next() async {
    if (!state.hasNext && state.mode != AudioPlayMode.singleLoop) return;
    _paragraphTimer?.cancel();
    _paragraphIndex = 0;
    if (state.mode == AudioPlayMode.singleLoop) {
      await play(paragraphIndex: 0);
      return;
    }
    state = state.copyWith(currentIndex: state.currentIndex + 1);
    await play(paragraphIndex: 0);
  }

  Future<void> previous() async {
    if (!state.hasPrevious) return;
    _paragraphTimer?.cancel();
    _paragraphIndex = 0;
    state = state.copyWith(currentIndex: state.currentIndex - 1);
    await play(paragraphIndex: 0);
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.chapters.length) return;
    _paragraphTimer?.cancel();
    _paragraphIndex = 0;
    state = state.copyWith(currentIndex: index);
    await play(paragraphIndex: 0);
  }

  void setMode(AudioPlayMode mode) {
    state = state.copyWith(mode: mode);
  }

  void updateConfig({
    String? engineUrl,
    String? voiceName,
    double? speed,
    double? pitch,
    double? volume,
  }) {
    final config = state.config;
    final updated = TtsConfig(
      engineUrl: engineUrl ?? config.engineUrl,
      voiceName: voiceName ?? config.voiceName,
      speed: speed != null ? speed.clamp(0.5, 3.0) : config.speed,
      pitch: pitch != null ? pitch.clamp(0.5, 2.0) : config.pitch,
      volume: volume != null ? volume.clamp(0.0, 1.0) : config.volume,
    );
    state = state.copyWith(config: updated);
    if (state.isStreamMode &&
        speed != null &&
        _streamPlayer.isInitialized) {
      unawaited(_streamPlayer.setSpeed(updated.speed));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _paragraphTimer?.cancel();
    unawaited(_streamPlayer.dispose());
    super.dispose();
  }
}

final audioNotifierProvider = NotifierProvider<AudioNotifier, AudioState>(
  AudioNotifier.new,
);

final audioServiceProvider = Provider<AudioService>(
  (ref) => AudioService.instance,
);
