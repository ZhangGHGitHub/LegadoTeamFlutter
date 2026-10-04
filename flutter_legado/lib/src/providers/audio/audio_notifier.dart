import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/book.dart';
import '../../services/audio_service.dart';
import '../../services/book_api.dart';
import '../../services/stream_audio_player.dart';
import '../../utils/audio_skip_policy.dart';
import '../providers.dart';
import 'audio_state.dart';
import 'http_tts_seed.dart';

export 'audio_state.dart';

/// 无可用朗读引擎时的一次性温和提示
///
/// 展示面复用 [AudioState.errorMessage]（阅读器朗读条警示条 / 听书页错误行），
/// 不新造 UI；同一朗读会话内只提示一次，用户配置引擎后自动清除。
/// [A4 | 2026-10-03]
const String kNoUsableEngineHint = '未配置可用朗读引擎，将按估算节奏朗读';

/// 朗读引擎 URL 归一：把历史「名称,URL」复合形态还原为裸 URL 模板
///
/// [P0 | 2026-10-03] 朗读条引擎选择器曾把 `'名称,URL'` 复合串写入
/// [TtsConfig.engineUrl]（read_aloud_bar.dart），而 Rust `tts_speak` 把该值
/// 原样当 URL 模板与缓存键（rust/legado-ffi/src/api/tts_speak_api.rs:57-59），
/// 请求以「名称」开头必然失败 → 选完引擎合成仍报错、朗读落降级提示。
/// 选择器已改为只存裸 URL；本函数是消费端（audioSpeak 前）的向后兼容兜底，
/// 兼容同一进程内残留的旧形态状态。
///
/// 归一策略（测试钉死）：
/// - 整串已以 `http://`/`https://` 开头 → 原样返回（URL 自身含逗号也不拆）；
/// - 否则取「首个其后紧跟 http(s):// 的逗号」之后的部分——名称本身含逗号
///   （`甲,乙,http://…`）时仍能定位真正的 URL 起点；
/// - 逗号后不是 http(s) 开头（如原版 POST 模板 `url,{json}`）→ 原样返回，
///   不做猜测性截断，交由合成管线报错。
///
/// 不采用「首个逗号硬拆」：名称可能含逗号，硬拆会把名称残段混进 URL。
String normalizeTtsEngineUrl(String engineUrl) {
  final trimmed = engineUrl.trim();
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  var index = trimmed.indexOf(',');
  while (index >= 0) {
    final rest = trimmed.substring(index + 1).trim();
    if (rest.startsWith('http://') || rest.startsWith('https://')) {
      return rest;
    }
    index = trimmed.indexOf(',', index + 1);
  }
  return trimmed;
}

/// 流媒体进度写库的位置增量阈值（毫秒）
///
/// 播放中高频 onProgress 回调下仅做内存比较，累计播放位置增量达到该阈值
/// 才真正写库（避免高频 IO）；生命周期节点（完成/切章/暂停/停止/退出）
/// 不受该阈值限制。[A3 | 2026-10-03]
const int kStreamProgressSaveDeltaMs = 5000;

/// 书级语速写库防抖窗口（滑条拖动期间合并为一次写库）[A2 | 2026-10-03]
const Duration kSpeedPersistDebounce = Duration(milliseconds: 600);

/// 分钟倒计时上限——对齐原版 SleepTimerDialog.MAX_MINUTES = 180
/// [A4 | 2026-10-03]
const int kMaxSleepTimerMinutes = 180;

/// 按章停止上限——对齐原版 MAX_CHAPTER_STOP_COUNT = 99
/// （ChapterStopTimer.kt:3）[A4 | 2026-10-03]
const int kMaxChapterStopCount = 99;

/// 恢复进度「接近章尾」容差（毫秒）
///
/// [P1 竞态修复 | 2026-10-03] 存量进度 ≥ duration - 该值 时视为「本章已播完」，
/// 恢复时不再 seek（否则 seek 到章尾会立即触发完成回调 → 秒完切章级联）。
/// 依据：原版无对应恢复判定——完成的章不落可恢复位置：AudioPlay.next() 在
/// completeCurrentChapter 之后立即把 durChapterPos 清零；末章播完由
/// isPlayToEnd() 走 playNew() 从头播（AudioPlay.kt:615-621、752-778）。
/// 故按最小防护取「从头播」。取 1s：覆盖本应用完成判定
/// （stream_audio_player.dart：position ≥ duration-200ms 且停止）写入的完成值，
/// 并给真机时长/位置上报粒度留余量；不取 95% 比例阈值，避免长章节尾部真实
/// 续听位置（如 3 小时章的最后 2 分钟）被误判为播完。
const int kStreamRestoreNearEndToleranceMs = 1000;

/// 流媒体章节归属标识
///
/// [_playAudioBookStream] 发起 `playUrl` 时绑定，[StreamAudioPlayer] 在进度/
/// 完成回调中原样回传；回调先与当前 state.bookUrl/currentIndex 比对，归属
/// 不一致（切章后迟到的旧章事件）整条丢弃——旧章最终位置不得写进新章进度键，
/// 这是 P1 级联跳章的根因修复。[P1 竞态修复 | 2026-10-03]
typedef StreamChapterTag = ({String bookUrl, int chapterIndex});

/// 听书播放器 Riverpod Notifier
///
/// 双路径：
/// - 音频书（BookType.audio）：getAudioChapterMedia 取址 → StreamAudioPlayer
/// - TTS 朗读：段落化 audioSpeak → 合成产物本地文件播放，完成回调驱动段落推进
///
/// — Auto + UI｜2026-08-12（P0-2 流媒体接线；A1 批 TTS 真实播放 2026-10-03）
class AudioNotifier extends Notifier<AudioState> with ChangeNotifier {
  late final AudioService _audioService;
  late final StreamAudioPlayer _streamPlayer;

  StreamSubscription<MediaButtonEvent>? _mediaButtonSub;
  StreamSubscription<AudioFocusEvent>? _audioFocusSub;

  BookApi get _api {
    final cached = _apiCache;
    if (cached != null) return cached;
    final api = ref.read(bookApiProvider);
    _apiCache = api;
    return api;
  }

  BookApi? _apiCache;

  static const double _kCharsPerSecond = 5.0;
  static const Duration _kMinParagraphDuration = Duration(milliseconds: 800);
  static const Duration _kMaxParagraphDuration = Duration(seconds: 90);
  static const int _kProgressThrottleMs = 400;

  List<String> _paragraphs = [];
  int _paragraphIndex = 0;
  Timer? _paragraphTimer;
  int _playToken = 0;

  /// 段落级合成/播放代数：手动切段时使旧的在途合成失效，避免旧段覆盖新段
  int _speakGeneration = 0;
  int? _pendingParagraphIndex;
  bool _introSkipEvaluated = false;
  AudioSkipWindow? _skipWindow;
  Book? _book;
  bool _disposed = false;
  int _lastProgressEmitMs = 0;

  /// A4：无可用引擎提示是否已在本朗读会话展示（一次性语义）
  bool _noEngineHintShown = false;

  /// [第2项] 最近一次推送到通知/锁屏的媒体元数据签名（去重节流，见
  /// [_pushMediaSessionMetadata]）
  String _lastMediaMetadataSignature = '';

  /// A3：流媒体进度写库节流状态（bookUrl:chapterIndex → 最近写入位置）
  String _lastProgressSaveKey = '';
  int _lastProgressSavedPosMs = 0;

  /// A2：书级语速写库防抖（拖动期间合并；仅绑定书籍后落库）
  Timer? _speedPersistTimer;
  ({String bookUrl, double speed})? _pendingSpeedPersist;
  String _lastSpeedPersistKey = '';
  double? _lastSpeedPersistValue;

  /// A4：定时停止（下沉 Notifier，退出听书页不失效）
  ///
  /// 分钟倒计时剩余秒数（>0 时 duration 模式生效）
  int _sleepRemainingSeconds = 0;

  /// 按章停止剩余章数（>0 时 chapters 模式生效）
  int _chaptersToStopRemaining = 0;

  /// 分钟倒计时 ticker：1s 粒度仅用于 UI 展示；递减语义对齐原版
  /// doDs 的 60s 循环（`if (!pause)` 守卫，暂停期间冻结）
  Timer? _sleepTicker;

  /// 定时停止模式（分钟与按章互斥；均未启用为 off）
  SleepTimerMode get sleepTimerMode {
    if (_chaptersToStopRemaining > 0) return SleepTimerMode.chapters;
    if (_sleepRemainingSeconds > 0) return SleepTimerMode.duration;
    return SleepTimerMode.off;
  }

  /// 是否启用了定时停止（分钟倒计时或按章停止）
  bool get isSleepTimerActive => sleepTimerMode != SleepTimerMode.off;

  /// 分钟倒计时剩余秒数（未启用时为 0）
  int get sleepRemainingSeconds => _sleepRemainingSeconds;

  /// 按章停止剩余章数（未启用时为 0）
  int get chaptersToStopRemaining => _chaptersToStopRemaining;

  /// 定时剩余量展示文案（通知标题/锁屏副标题组合用；未启用时为空串）
  ///
  /// 形态对齐原版通知标题的括号段（BaseReadAloudService.kt:701-707、
  /// AudioPlayService.kt:873-879）：分钟倒计时为「剩余 N 分钟」，按章停止为
  /// 「剩余 N 章」。分钟数向上取整——与原版 timeMinute 每分钟减一的展示
  /// 节奏一致（开始 5 分钟先显示 5，走过 1 分钟后显示 4）。
  /// 未启用定时时必须为空串，不得让标题出现「剩余 0」字样。[第2项 | 2026-10-03]
  String get sleepTimerRemainingLabel {
    switch (sleepTimerMode) {
      case SleepTimerMode.chapters:
        return '剩余 $_chaptersToStopRemaining 章';
      case SleepTimerMode.duration:
        return '剩余 ${(_sleepRemainingSeconds + 59) ~/ 60} 分钟';
      case SleepTimerMode.off:
        return '';
    }
  }

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
    _streamPlayer = ref.read(streamAudioPlayerProvider);
    // 完成回调按当前模式分发：音频书 → 下一章；TTS → 下一段
    _streamPlayer.onCompleted = (tag) {
      if (_disposed) return;
      if (state.isStreamMode) {
        // [P1] 迟到的旧章完成事件（切章后才送达）：丢弃，避免误触发再切一章
        if (!_isCurrentStreamChapter(tag)) return;
        unawaited(_onStreamCompleted());
        return;
      }
      unawaited(_onTtsParagraphCompleted());
    };
    _streamPlayer.onProgress = (pos, dur, tag) {
      if (_disposed || !state.isStreamMode) return;
      // [P1] 回调必须归属当前章：切章瞬间旧播放器 stop 前送达的最终回调
      // （position≈旧章时长）若按 state.currentIndex 归属会写进新章进度键，
      // 恢复逻辑随即 seek 到新章章尾 → 秒完 → 再切章，形成自持级联；
      // 归属不一致则整条丢弃（不写库、不刷新 UI）。
      if (!_isCurrentStreamChapter(tag)) return;
      // [A3] 播放中周期写进度：显式传入回调位置，位置增量 <5s 时仅内存比较不写库
      unawaited(_persistStreamPosition(positionMs: pos.inMilliseconds));
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
      // [A3] 容器销毁（退出听书/应用生命周期结束）尽力写一次当前进度
      _saveStreamProgressOnDispose();
      _speedPersistTimer?.cancel();
      // [A4] 定时停止 ticker 随容器销毁清理
      _sleepTicker?.cancel();
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
    // 会话释放后原生元数据清空：[第2项] 重置签名，避免下次初始化误跳过推送
    _lastMediaMetadataSignature = '';
    state = state.copyWith(isMediaSessionReady: false);
  }

  Future<void> loadChapters(String bookUrl) async {
    if (state.bookUrl != bookUrl) {
      // A4：切换书籍视为新朗读会话，重置无引擎提示的一次性标记
      _noEngineHintShown = false;
    }
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
    // A4：新的朗读会话，允许无可用引擎提示再次出现
    _noEngineHintShown = false;
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
      // [D3 | 2026-10-03] 首启/升级导入原版 httpTTS 种子（版本门控；
      // 失败不阻塞，仍按无引擎降级估算）。
      await ensureDefaultHttpTts(_api);
      final list = await _api.getHttpTts();
      if (list.isEmpty) return;
      // [D3] 种子依赖 Rust 合成管线不支持的能力（POST/@js/loginUrl），
      // 自动选默认时只接受「GET + 文本占位符」兼容模板——
      // 避免把失效引擎当作可用（QA 实测种子「1.百度」返回错误 JSON）。
      final compatible =
          list.where((e) => isCompatibleHttpTtsEngineUrl(e.url));
      if (compatible.isEmpty) return;
      final url = compatible.first.url.trim();
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
        // [P1] 绑定本章归属：播放器在进度/完成回调中原样回传，切章后旧播放器
        // 迟到的回调据此被丢弃，不会写进新章进度键
        await _streamPlayer.playUrl(
          mediaUrl,
          speed: state.config.speed,
          tag: (bookUrl: state.bookUrl, chapterIndex: index),
        );
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
            if (_isNearChapterEnd(restoredPos)) {
              // [P1 辅修] 历史污染值/完成值按「本章已播完」处理：不 seek，
              // 从头播（依据见 kStreamRestoreNearEndToleranceMs 注释）
              restoredPos = 0;
            } else {
              await _streamPlayer.seek(Duration(milliseconds: restoredPos));
            }
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

  /// 回调归属校验：tag 是否为当前播放章节（bookUrl + chapterIndex 双匹配）
  ///
  /// 仅流媒体路径的进度/完成回调需要校验（TTS 本地播放不传 tag，恒不匹配）。
  bool _isCurrentStreamChapter(Object? tag) {
    if (tag is! StreamChapterTag) return false;
    return tag.bookUrl == state.bookUrl &&
        tag.chapterIndex == state.currentIndex;
  }

  /// 存量进度是否已到本章末尾（视为已播完）
  ///
  /// 时长未知（未初始化）时不做判定，保持既有恢复行为。
  bool _isNearChapterEnd(int positionMs) {
    final durationMs = _streamPlayer.duration.inMilliseconds;
    if (durationMs <= 0) return false;
    return positionMs >= durationMs - kStreamRestoreNearEndToleranceMs;
  }

  Future<void> _onStreamCompleted() async {
    if (!state.isStreamMode || state.state != PlayerState.playing) return;
    // [A4] 章自然播完：按章停止计数（单曲循环每次完成同样计数，
    // 对齐原版 STATE_ENDED → completeCurrentChapter → onChapterCompleted）
    if (_consumeChapterStopAtBoundary()) {
      stop(); // stop 内 force 写当前章进度（A3）
      return;
    }
    if (state.mode == AudioPlayMode.singleLoop) {
      // [A3] 单曲循环从章首重播：显式清零进度，避免周期写入导致「循环回到结尾」
      await _resetStreamProgress();
      await play();
      return;
    }
    // [A3] 播完（含片尾跳过）/ 自动切章前写当前章进度
    await _persistStreamPosition(force: true);
    if (state.hasNext) {
      await next();
      return;
    }
    stop();
  }

  Future<void> _playTtsParagraphs({int? paragraphIndex}) async {
    state = state.copyWith(state: PlayerState.loading);
    final token = ++_playToken;
    // 切章/重播入口先停掉上一段残留音频：新段合成期间保持静默而非叠音
    await _streamPlayer.stop();
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

  /// 合成并播放当前段落（A1 批主路径）
  ///
  /// 链路：audioSpeak（Rust 合成 MD5 缓存落盘）→ StreamAudioPlayer.playLocalFile
  /// → 播放完成回调（onCompleted）驱动 [_onParagraphFinished] 推进下一段。
  /// 估算时长 Timer 仅在合成/播放失败降级时使用，且失败经
  /// [AudioState.errorMessage] 给用户可见提示（不静默）。
  ///
  /// 段间串行：上一段音频停止后才发起下一段合成，避免新旧音频叠放；
  /// ttsSpeak 为同步 FFI，长段落合成会带来段间短暂静默（预期，未额外
  /// 引入预取，避免扩大本批改动面）。
  Future<void> _speakCurrentParagraph(int token) async {
    _paragraphTimer?.cancel();
    if (_paragraphs.isEmpty) return;
    final gen = ++_speakGeneration;
    // 先停掉上一段残留音频（手动切段/切章时避免叠音）
    await _streamPlayer.stop();
    if (_isSpeakStale(token, gen)) return;

    final text = _paragraphs[_paragraphIndex];
    final config = state.config;
    // [P0] 消费端归一：历史「名称,URL」复合形态在此还原为裸 URL 模板，
    // 避免 Rust tts_speak 把名称前缀当 URL/缓存键（见 normalizeTtsEngineUrl）。
    final engineUrl = normalizeTtsEngineUrl(config.engineUrl);
    if (engineUrl.isEmpty) {
      // [A4] 无可用引擎：温和一次性提示（复用 errorMessage 展示面）后按
      // 估算节奏朗读；不视为失败，无正文时前面的空段落判定已提前返回。
      _showNoEngineHintOnce();
      _scheduleEstimateAdvance(text, config.speed, token, gen);
      return;
    }
    String? audioPath;
    Object? failure;
    try {
      audioPath = await _api.audioSpeak(
        text: text,
        engineUrl: engineUrl,
        speed: config.speed,
        pitch: config.pitch,
        volume: config.volume,
        voiceName: config.voiceName,
      );
    } catch (e) {
      failure = e;
    }
    if (failure == null && (audioPath == null || audioPath.trim().isEmpty)) {
      failure = StateError('TTS 合成未返回音频文件（引擎或缓存异常）');
    }
    if (_isSpeakStale(token, gen)) return;

    if (failure == null && audioPath != null && audioPath.trim().isNotEmpty) {
      try {
        // 语速已由合成侧应用（engineUrl 模板 speakSpeed），播放侧固定 1.0
        await _streamPlayer.playLocalFile(audioPath.trim(), speed: 1.0);
        if (_isSpeakStale(token, gen)) return;
        // [A4] 真实播放恢复：允许后续再次提示（如引擎后续被移除）
        _noEngineHintShown = false;
        if (state.errorMessage != null) {
          // 上一段降级/无引擎提示在恢复真实播放后清除
          state = state.copyWith(errorMessage: null);
        }
        // 正常路径到此为止：推进由 onCompleted 回调触发（见 build 分发）
        return;
      } catch (e) {
        failure = e;
      }
    }
    if (_isSpeakStale(token, gen)) return;

    // 降级：合成/播放失败 → 估算时长推进 + 用户可见提示
    // （无引擎配置时已在上面的空判定提前返回，保持既有静默估算行为）
    if (failure != null) {
      state = state.copyWith(
        errorMessage: '朗读音频不可用，本段按估算时长继续：$failure',
      );
    }
    _scheduleEstimateAdvance(text, config.speed, token, gen);
  }

  /// 段落级失效判定：播放会话 token 或合成代数任一变化即视为过期
  bool _isSpeakStale(int token, int gen) =>
      token != _playToken || gen != _speakGeneration || _disposed;

  /// 降级推进：按字符数估算当前段时长，到点后推进下一段
  void _scheduleEstimateAdvance(
    String text,
    double speed,
    int token,
    int gen,
  ) {
    final s = speed <= 0 ? 1.0 : speed;
    final seconds = text.length / (_kCharsPerSecond * s);
    var duration = Duration(milliseconds: (seconds * 1000).round());
    if (duration < _kMinParagraphDuration) {
      duration = _kMinParagraphDuration;
    } else if (duration > _kMaxParagraphDuration) {
      duration = _kMaxParagraphDuration;
    }
    _paragraphTimer = Timer(duration, () {
      if (_isSpeakStale(token, gen)) return;
      unawaited(_onParagraphFinished());
    });
  }

  /// TTS 段落音频自然播完 → 推进下一段（由 StreamAudioPlayer.onCompleted 驱动）
  Future<void> _onTtsParagraphCompleted() async {
    if (state.isStreamMode || state.state != PlayerState.playing) return;
    await _onParagraphFinished();
  }

  Future<void> _onParagraphFinished() async {
    if (state.state != PlayerState.playing) return;
    if (_paragraphIndex < _paragraphs.length - 1) {
      _paragraphIndex++;
      notifyListeners();
      await _speakCurrentParagraph(_playToken);
      return;
    }
    // [A4] 章末（末段播完）：按章停止计数，归零则在章末停止而不切章
    if (_consumeChapterStopAtBoundary()) {
      stop();
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
    await _pushMediaSessionMetadata();
    await _audioService.notifyPlaying();
  }

  /// 组装并推送媒体元数据（通知标题/锁屏副标题）
  ///
  /// [第2项 | 2026-10-03] 方案：metadata ARTIST 承载组合标题，TITLE 保持章节
  /// 标题（对齐原版 TTS upMediaMetadata 的字段语义，BaseReadAloudService.kt:
  /// 700-720）；Kotlin 侧 PlaybackForegroundService 以 ARTIST 作通知标题、
  /// TITLE 作通知文本（原版 createNotification 形态）。这样通知标题与锁屏
  /// 副标题都能看到剩余量，锁屏标题仍是章节标题、不被污染。
  ///
  /// 去重节流：以「章节标题 + 组合标题 + 书名」为签名，签名未变不调平台
  /// 通道——分钟倒计时每秒 tick 但剩余分钟整数未变时、同章重复同步时均
  /// 不会重推，避免通知频繁重建。
  Future<void> _pushMediaSessionMetadata() async {
    if (!state.isMediaSessionReady) return;
    final title = state.currentChapter?.title ?? '';
    final artist = _composePlaybackLabel();
    final album = state.bookName;
    final signature = '$title\u0001$artist\u0001$album';
    if (signature == _lastMediaMetadataSignature) return;
    _lastMediaMetadataSignature = signature;
    await _audioService.updateMetadata(title: title, artist: artist, album: album);
  }

  /// 通知标题/锁屏副标题文案：正在播放/朗读[(剩余 N 章|分钟)]: 书名
  ///
  /// 未启用定时时为原形态「正在播放/朗读: 书名」；书名未知时返回空串
  /// （保持既有降级行为，由 Kotlin 侧回退为章节标题）。
  String _composePlaybackLabel() {
    if (state.bookName.isEmpty) return '';
    final prefix = state.isStreamMode ? '正在播放' : '正在朗读';
    final remaining = sleepTimerRemainingLabel;
    if (remaining.isEmpty) return '$prefix: ${state.bookName}';
    return '$prefix($remaining): ${state.bookName}';
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

  // ===== 定时停止（A4 批：计时下沉，退出听书页不失效）=====

  /// 启动分钟倒计时：到点停止播放并保存进度（流媒体经 A3 force 写）
  ///
  /// 与按章停止互斥（对齐原版 setTimer → chapterStopTimer.clear()，
  /// BaseReadAloudService.kt:553-559）。递减仅在播放中进行（对齐原版
  /// doDs 的 `if (!pause)` 守卫，BaseReadAloudService.kt:586-601）：
  /// 暂停期间剩余时间冻结，恢复播放后继续。
  void startSleepTimer(int minutes) {
    final normalized = minutes.clamp(0, kMaxSleepTimerMinutes).toInt();
    _clearSleepTimerState();
    if (normalized > 0) {
      _sleepRemainingSeconds = normalized * 60;
      _ensureSleepTicker();
    }
    notifyListeners();
    // [第2项] 定时启用/关闭立即反映到通知标题（签名去重）
    unawaited(_pushMediaSessionMetadata());
  }

  /// 启动按章停止：自然播完 [chapters] 章后在章末停止（不再进入下一章）
  ///
  /// 语义对齐原版 [ChapterStopTimer.onChapterCompleted]（ChapterStopTimer.kt:29-33）：
  /// 每自然播完一章计数减一，归零触发停止；手动切章不计（原版仅在
  /// nextChapter(auto=true) / completeCurrentChapter 中计数）。
  void startChapterStop(int chapters) {
    final normalized = chapters.clamp(0, kMaxChapterStopCount).toInt();
    _clearSleepTimerState();
    if (normalized > 0) {
      _chaptersToStopRemaining = normalized;
    }
    notifyListeners();
    // [第2项] 剩余章数立即反映到通知标题（签名去重）
    unawaited(_pushMediaSessionMetadata());
  }

  /// 取消定时停止（分钟倒计时与按章停止同时清空）
  void cancelSleepTimer() {
    if (!isSleepTimerActive) return;
    _clearSleepTimerState();
    notifyListeners();
    // [第2项] 取消后标题恢复原形态并刷新通知
    unawaited(_pushMediaSessionMetadata());
  }

  void _clearSleepTimerState() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _sleepRemainingSeconds = 0;
    _chaptersToStopRemaining = 0;
  }

  void _ensureSleepTicker() {
    if (_sleepTicker != null) return;
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      // 对齐原版：暂停期间不计时（唤醒恢复后从剩余时间继续）
      if (!state.isPlaying) return;
      if (_sleepRemainingSeconds <= 0) return;
      _sleepRemainingSeconds--;
      if (_sleepRemainingSeconds <= 0) {
        _clearSleepTimerState();
        notifyListeners();
        stop();
        return;
      }
      notifyListeners();
      // [第2项] 每秒 tick 均尝试刷新，内部按签名去重——
      // 仅剩余分钟整数变化时才真正重推通知（节流）
      unawaited(_pushMediaSessionMetadata());
    });
  }

  /// 章末边界计数：返回 true 表示已到按章停止点（调用方应停止而非切章）
  ///
  /// 仅在「章自然播完」路径调用（流媒体完成回调 / TTS 末段完成）；手动
  /// next()/jumpTo 不计数，保持与原版一致。
  bool _consumeChapterStopAtBoundary() {
    if (_chaptersToStopRemaining <= 0) return false;
    _chaptersToStopRemaining--;
    final shouldStop = _chaptersToStopRemaining <= 0;
    if (shouldStop) _chaptersToStopRemaining = 0;
    notifyListeners();
    // [第2项] 剩余章数在章末即时上通知（停止路径 stop() 再推一次，
    // 签名去重不会重复触发）
    unawaited(_pushMediaSessionMetadata());
    return shouldStop;
  }

  void pause() {
    if (state.state == PlayerState.playing) {
      _paragraphTimer?.cancel();
      if (state.isStreamMode) {
        unawaited(_streamPlayer.pause());
        // [A3] 暂停即写（force），派发前读取播放器实际位置
        unawaited(_persistStreamPosition(force: true));
      } else {
        _playToken++;
        // TTS 本地播放：立即停掉当前段音频（恢复时由 play() 重播当前段）
        unawaited(_streamPlayer.stop());
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
    // [A4] 停止即结束本次定时（对齐原版 TTS 服务 onDestroy 清空
    // timeMinute/chapterStopTimer，BaseReadAloudService.kt:309-313）
    _clearSleepTimerState();
    // [第2项] 定时清空后标题恢复原形态（无剩余量）并刷新通知
    unawaited(_pushMediaSessionMetadata());
    // [A3] 停止前写一次当前进度（必须在重置 state 之前发起）
    unawaited(_persistStreamPosition(force: true));
    // A4：停止视为朗读会话结束，下次朗读允许再次提示无引擎
    _noEngineHintShown = false;
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
    // [A3] 切章前写当前章进度（TTS 模式内部直接返回）
    await _persistStreamPosition(force: true);
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
    // [A3] 切章前写当前章进度
    await _persistStreamPosition(force: true);
    _paragraphTimer?.cancel();
    _paragraphIndex = 0;
    state = state.copyWith(currentIndex: state.currentIndex - 1);
    await play(paragraphIndex: 0);
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.chapters.length) return;
    // [A3] 切章前写当前章进度
    await _persistStreamPosition(force: true);
    _paragraphTimer?.cancel();
    _paragraphIndex = 0;
    state = state.copyWith(currentIndex: index);
    await play(paragraphIndex: 0);
  }

  /// 切换播放模式并落库（书级 readConfig.playMode，对齐原版 AudioPlay.changePlayMode）
  Future<void> setMode(AudioPlayMode mode) async {
    if (state.mode == mode) return;
    state = state.copyWith(mode: mode);
    await _persistPlayMode(mode);
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
    if (engineUrl != null && updated.engineUrl.trim().isNotEmpty) {
      // [A4] 用户配置了引擎：清除无引擎提示（可用性由后续合成结果验证）
      _noEngineHintShown = false;
      if (state.errorMessage == kNoUsableEngineHint) {
        state = state.copyWith(errorMessage: null);
      }
    }
    if (speed != null) {
      _scheduleSpeedPersist(updated.speed);
    }
    if (state.isStreamMode &&
        speed != null &&
        _streamPlayer.isInitialized) {
      unawaited(_streamPlayer.setSpeed(updated.speed));
    }
  }

  /// 读回并应用书级听书偏好（播放模式 / 语速）
  ///
  /// 打开听书页初始化、切换书籍时调用；书对象未携带 readConfig 时经
  /// [BookApi.getBook] 补读（对齐原版 AudioPlay.resetData 的 getPlayMode /
  /// getPlaySpeed 读回语义）。[A2 | 2026-10-03]
  Future<void> applyBookPreferences(
    Book? book, {
    String? fallbackBookUrl,
  }) async {
    final url = book != null && book.bookUrl.isNotEmpty
        ? book.bookUrl
        : ((fallbackBookUrl != null && fallbackBookUrl.isNotEmpty)
            ? fallbackBookUrl
            : state.bookUrl);
    if (url.isEmpty) return;

    var target = book;
    if (target == null || target.readConfig == null) {
      // 缓存书可能缺 readConfig：始终向库补读一次，失败沿用传入对象
      try {
        target = await _api.getBook(url) ?? target;
      } catch (e) {
        debugPrint('读取书级听书配置失败: $e');
      }
    }
    if (target != null) _book = target;

    final cfg = target?.readConfig;
    if (cfg == null) return;

    final mode = _audioPlayModeFromIndex(cfg.playMode);
    if (mode != state.mode) {
      state = state.copyWith(mode: mode);
    }
    final speed = cfg.playSpeed;
    if (speed >= 0.5 && speed <= 3.0) {
      // 记录库内值：读回不触发回写（避免打开听书页即写库）
      _lastSpeedPersistKey = url;
      _lastSpeedPersistValue = speed;
      if ((speed - state.config.speed).abs() > 0.001) {
        updateConfig(speed: speed);
      }
    }
  }

  /// readConfig.playMode → AudioPlayMode（越界回退 sequential，
  /// 兼容原版含 LIST_LOOP=3 的存量数据）
  static AudioPlayMode _audioPlayModeFromIndex(int index) {
    if (index <= 0 || index >= AudioPlayMode.values.length) {
      return AudioPlayMode.sequential;
    }
    return AudioPlayMode.values[index];
  }

  /// 无可用引擎提示：同一朗读会话只出现一次
  void _showNoEngineHintOnce() {
    if (_noEngineHintShown) return;
    _noEngineHintShown = true;
    if (state.errorMessage == kNoUsableEngineHint) return;
    state = state.copyWith(errorMessage: kNoUsableEngineHint);
  }

  /// 播放模式落库：audioWithPlayMode FFI 合并 readConfig JSON → updateBook
  ///
  /// [A2] 不做全量覆盖：先经 Rust 侧合并（保留 readConfig 既有字段），
  /// 再以更新后的 Book 快照写库。
  Future<void> _persistPlayMode(AudioPlayMode mode) async {
    final bookUrl = (_book?.bookUrl.isNotEmpty ?? false)
        ? _book!.bookUrl
        : state.bookUrl;
    if (bookUrl.isEmpty) return;
    try {
      final book = await _bookForUrl(bookUrl);
      if (book == null) return;
      final cfg = book.readConfig;
      final mergedJson = await _api.audioWithPlayMode(
        readConfig: cfg == null ? null : jsonEncode(cfg.toJson()),
        playMode: mode.index,
      );
      final decoded = jsonDecode(mergedJson);
      if (decoded is! Map<String, dynamic>) return;
      final updated = book.copyWith(readConfig: ReadConfig.fromJson(decoded));
      _book = updated;
      await _api.updateBook(updated);
    } catch (e) {
      debugPrint('保存书级播放模式失败: $e');
    }
  }

  /// 语速落库（防抖合并；仅听书页绑定书籍后写）
  void _scheduleSpeedPersist(double speed) {
    final book = _book;
    if (book == null) return;
    final bookUrl = book.bookUrl.isNotEmpty ? book.bookUrl : state.bookUrl;
    if (bookUrl.isEmpty) return;
    if (_lastSpeedPersistKey == bookUrl &&
        _lastSpeedPersistValue != null &&
        (_lastSpeedPersistValue! - speed).abs() < 0.001) {
      return; // 与库内一致（含读回后的首次），无需回写
    }
    _pendingSpeedPersist = (bookUrl: bookUrl, speed: speed);
    _speedPersistTimer?.cancel();
    _speedPersistTimer = Timer(kSpeedPersistDebounce, () {
      final pending = _pendingSpeedPersist;
      _pendingSpeedPersist = null;
      if (pending != null) {
        unawaited(_persistSpeed(pending.bookUrl, pending.speed));
      }
    });
  }

  /// 语速写 Book readConfig.playSpeed → updateBook（对齐原版 updateAudioPlaySpeed）
  Future<void> _persistSpeed(String bookUrl, double speed) async {
    try {
      final book = await _bookForUrl(bookUrl);
      if (book == null) return;
      final cfg = book.readConfig ?? const ReadConfig();
      final updated = book.copyWith(readConfig: cfg.copyWith(playSpeed: speed));
      _book = updated;
      await _api.updateBook(updated);
      _lastSpeedPersistKey = bookUrl;
      _lastSpeedPersistValue = speed;
    } catch (e) {
      debugPrint('保存书级语速失败: $e');
    }
  }

  /// 取当前书籍对象（缓存命中直接用；否则按 URL 补读并缓存）
  Future<Book?> _bookForUrl(String bookUrl) async {
    final cached = _book;
    if (cached != null && cached.bookUrl == bookUrl) return cached;
    try {
      final fetched = await _api.getBook(bookUrl);
      if (fetched != null) _book = fetched;
      return fetched;
    } catch (e) {
      debugPrint('读取书籍失败（听书配置持久化）: $e');
      return null;
    }
  }

  /// 流媒体进度写库（A3）
  ///
  /// 节流：同一 bookUrl+chapterIndex 下，非 [force] 调用仅当播放位置增量
  /// ≥ [kStreamProgressSaveDeltaMs] 时写库（onProgress 高频回调下只做内存
  /// 比较）；[force] 用于生命周期节点（暂停/停止/完成/切章/退出）。
  /// 位置优先取播放器实际位置，未初始化时回退 state.positionMs。
  ///
  /// 写入归属恒为调用时刻的 state.currentIndex；播放器回调路径（onProgress）
  /// 必须先在回调入口经 [_isCurrentStreamChapter] 校验归属，切章后迟到的旧章
  /// 回调不得进入本方法。[P1 竞态修复]
  Future<void> _persistStreamPosition({int? positionMs, bool force = false}) async {
    if (!state.isStreamMode) return; // TTS 无毫秒时间轴，不写该键（避免污染流媒体恢复）
    final bookUrl = state.bookUrl;
    if (bookUrl.isEmpty) return;
    final chapterIndex = state.currentIndex;
    final key = '$bookUrl:$chapterIndex';
    // 播放器位置只在同一章内可信（切章后 Fake/真机可能仍持有上一章位置）
    final playerPos = _streamPlayer.position.inMilliseconds;
    final position = positionMs ??
        ((key == _lastProgressSaveKey && playerPos > 0)
            ? playerPos
            : state.positionMs);
    if (position <= 0) return; // 起始 0 位置不写，避免覆盖已存进度
    if (key == _lastProgressSaveKey) {
      final delta = (position - _lastProgressSavedPosMs).abs();
      if (position == _lastProgressSavedPosMs) return; // 同值去重
      if (!force && delta < kStreamProgressSaveDeltaMs) return;
    }
    _lastProgressSaveKey = key;
    _lastProgressSavedPosMs = position;
    try {
      await _api.saveAudioProgress(bookUrl, chapterIndex, position);
    } catch (e) {
      debugPrint('保存音频进度失败: $e');
    }
  }

  /// 单曲循环重播前清零当前章进度
  Future<void> _resetStreamProgress() async {
    final bookUrl = state.bookUrl;
    if (bookUrl.isEmpty) return;
    final chapterIndex = state.currentIndex;
    try {
      await _api.saveAudioProgress(bookUrl, chapterIndex, 0);
      _lastProgressSaveKey = '$bookUrl:$chapterIndex';
      _lastProgressSavedPosMs = 0;
    } catch (e) {
      debugPrint('重置音频进度失败: $e');
    }
  }

  /// 容器销毁时尽力写一次进度（onDispose 内调用，任何异常不得影响销毁）
  void _saveStreamProgressOnDispose() {
    try {
      final s = state;
      if (!s.isStreamMode || s.bookUrl.isEmpty) return;
      final key = '${s.bookUrl}:${s.currentIndex}';
      final playerPos = _streamPlayer.position.inMilliseconds;
      final position = (key == _lastProgressSaveKey && playerPos > 0)
          ? playerPos
          : s.positionMs;
      if (position <= 0) return;
      if (key == _lastProgressSaveKey && position == _lastProgressSavedPosMs) {
        return;
      }
      final api = _api;
      unawaited(
        api.saveAudioProgress(s.bookUrl, s.currentIndex, position).catchError(
          (Object e) {
            debugPrint('退出时保存音频进度失败: $e');
          },
        ),
      );
    } catch (e) {
      debugPrint('退出时保存音频进度失败: $e');
    }
  }

  @override
  void dispose() {
    _saveStreamProgressOnDispose();
    _speedPersistTimer?.cancel();
    _sleepTicker?.cancel();
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

/// StreamAudioPlayer 注入点（单元测试 override 为 Fake/Mock；
/// 生产环境单实例，TTS 与音频书路径共用）
final streamAudioPlayerProvider = Provider<StreamAudioPlayer>(
  (ref) => StreamAudioPlayer(),
);
