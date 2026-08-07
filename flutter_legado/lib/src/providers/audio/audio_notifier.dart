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
///
/// [UI-fix v2.0.3 | 2026-08-08] 段落化朗读（留项4）：章节正文按段拆分逐段
/// 送 audioSpeak（对标原版 BaseReadAloudService contentList/nowSpeak 段落队列），
/// 段落进度经 ChangeNotifier 混入通知（不动 freezed State，避免 codegen） — Qoder
class AudioNotifier extends Notifier<AudioState> with ChangeNotifier {
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

  // ===== [UI-fix v2.0.3 | 2026-08-08] 段落化朗读状态（留项4） — Qoder =====

  /// 中文 TTS 平均语速（字/秒，1.0x 基准），用于段落时长估算
  ///
  /// 探活级 audioSpeak 无真实播放完成回调（原版 TTS 引擎有 utterance 完成
  /// 回调、HttpReadAloudService 有 MediaPlayer 完成回调），段落推进暂以
  /// 字数/语速估算时长驱动；真实 TTS 管线接入后改接完成回调。
  static const double _kCharsPerSecond = 5.0;

  /// 段落播放时长下限/上限（避免极短/极长段落体验失衡）
  static const Duration _kMinParagraphDuration = Duration(milliseconds: 800);
  static const Duration _kMaxParagraphDuration = Duration(seconds: 90);

  /// 当前章拆分后的段落文本队列（对标原版 contentList）
  List<String> _paragraphs = [];

  /// 当前朗读段落索引（对标原版 nowSpeak）
  int _paragraphIndex = 0;

  /// 段落自动推进定时器（对标原版引擎播放完成回调）
  Timer? _paragraphTimer;

  /// 播放令牌：每次起播/停止递增，令陈旧异步回调与定时器失效
  int _playToken = 0;

  /// startReadAloud(startChapterPos) 映射出的待播段落索引（下次 play 消费）
  int? _pendingParagraphIndex;

  /// Notifier 是否已销毁（防御陈旧定时器回调）
  bool _disposed = false;

  /// 当前段落索引（UI 展示：上一段/下一段可用性、段落进度）
  int get currentParagraphIndex => _paragraphIndex;

  /// 当前章段落总数
  int get paragraphCount => _paragraphs.length;

  /// 是否存在上一段
  bool get hasPrevParagraph => _paragraphs.isNotEmpty && _paragraphIndex > 0;

  /// 是否存在下一段
  bool get hasNextParagraph =>
      _paragraphs.isNotEmpty && _paragraphIndex < _paragraphs.length - 1;

  @override
  AudioState build() {
    _audioService = ref.read(audioServiceProvider);
    // 复刻原 AudioProvider.dispose：释放媒体会话资源
    ref.onDispose(() {
      _mediaButtonSub?.cancel();
      _audioFocusSub?.cancel();
      _paragraphTimer?.cancel();
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
    // [UI-fix v2.0.3 | 2026-08-08] 留项4：段落级起播偏移（章节正文字符偏移，
    // 对标原版 ReadAloud 以 chapterPos 定位 nowSpeak 段落）。
    // 分页排版模式下 ParagraphInfo.startIndex 恒为 0，偏移不可用时以
    // [startParagraphText] 段落文本匹配兜底定位 — Qoder
    int? startChapterPos,
    String? startParagraphText,
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
    // [UI-fix v2.0.3 | 2026-08-08] 留项4：字符偏移映射段落索引起播
    // （对标原版 BaseReadAloudService getParagraphs 定位 nowSpeak）；
    // 偏移无效时按段落文本匹配兜底（分页排版 startIndex 恒 0 场景） — Qoder
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

  /// 段落文本 → 段落索引（偏移不可用时的兜底定位）
  ///
  /// 与拆段同口径 trim 后精确匹配；未命中时回退 null（从段首起播）。
  static int? _mapTextToParagraph(String content, String text) {
    final paragraphs = _splitParagraphsWithOffsets(content);
    for (var i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].text == text) return i;
    }
    return null;
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
  ///
  /// [UI-fix v2.0.3 | 2026-08-08] 留项4 段落化：章节正文按段拆分入队，
  /// 逐段送 audioSpeak，段尾自动推进下一段，章末自动下一章 — Qoder
  ///
  /// [paragraphIndex]：指定起播段落（null = 续播当前段落；同章重播默认回段首）
  Future<void> play({int? paragraphIndex}) async {
    if (state.chapters.isEmpty) return;
    state = state.copyWith(state: PlayerState.loading);
    final token = ++_playToken;

    try {
      // 加载章节文本内容
      final content = await _ensureChapterContent(state.currentIndex);
      if (token != _playToken || _disposed) return;

      // 按阅读器排版同口径拆段入队（对标原版 contentList 构建）
      final paragraphs = _splitParagraphsWithOffsets(content)
          .map((p) => p.text)
          .toList();
      if (paragraphs.isEmpty && content.trim().isNotEmpty) {
        // 拆段异常时兜底整章一段，保证朗读不中断
        paragraphs.add(content.trim());
      }
      _paragraphs = paragraphs;

      // 起播段落：显式指定 > startReadAloud 偏移映射 > 续播 > 段首
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

      // 通知媒体会话：请求焦点 + 更新元数据 + 更新播放状态
      await _syncMediaSession();
      if (token != _playToken || _disposed) return;

      // 送播当前段落并排程自动推进
      await _speakCurrentParagraph(token);
    } catch (e) {
      state = state.copyWith(
        errorMessage: e.toString(),
        state: PlayerState.error,
      );
    }
  }

  /// 确保指定章节正文已加载（复用 play 的内容缓存逻辑）
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

  /// 章节正文拆段（含段落起始字符偏移）
  ///
  /// [UI-fix v2.0.3 | 2026-08-08] 分段口径与阅读器排版引擎
  /// ParagraphLayoutEngine._splitParagraphs 完全一致（双换行优先，否则单换行，
  /// 逐段 trim 并过滤空段），保证偏移映射起点与排版段落对齐 — Qoder
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
      // trim 结果必为原片段的连续子串，indexOf 即段落真实起始偏移
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

  /// 章节正文字符偏移 → 段落索引（对标原版 pos → nowSpeak 段落定位）
  ///
  /// 取最后一个 start <= offset 的段落；越界偏移落到末段。
  static int _mapOffsetToParagraph(String content, int offset) {
    final paragraphs = _splitParagraphsWithOffsets(content);
    if (paragraphs.isEmpty) return 0;
    var index = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].start <= offset) index = i;
    }
    return index;
  }

  /// 送播当前段落并排程段尾自动推进
  Future<void> _speakCurrentParagraph(int token) async {
    _paragraphTimer?.cancel();
    if (_paragraphs.isEmpty) return;
    final text = _paragraphs[_paragraphIndex];
    final config = state.config;
    if (config.engineUrl.isNotEmpty) {
      // [UI-fix v2.0.1 | 2026-08-06] 探活级 audioSpeak：失败不阻断状态机 — Qoder
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
        debugPrint('audioSpeak 探活失败（不影响朗读 UI 状态）: $e');
      }
    }
    if (token != _playToken || _disposed) return;

    // 段落时长估算：字数 / (基准语速 × 倍速)，clamp 至合理区间
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

  /// 段落播完：自动下一段，章末自动下一章（保留既有跨章逻辑）
  Future<void> _onParagraphFinished() async {
    if (state.state != PlayerState.playing) return;
    if (_paragraphIndex < _paragraphs.length - 1) {
      _paragraphIndex++;
      notifyListeners();
      await _speakCurrentParagraph(_playToken);
      return;
    }
    // 章末：按播放模式推进（sequential 末章则停止，对齐原版读完即停）
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

  /// 下一段（对标原版 ReadAloud.nextParagraph → IntentAction.nextParagraph）
  ///
  /// 章内末段时跨到下一章段首（对齐原版 nextParagraph 越过 contentList 末尾
  /// 后走下一章朗读的行为）。
  Future<void> nextParagraph() async {
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

  /// 上一段（对标原版 ReadAloud.prevParagraph → IntentAction.prevParagraph）
  ///
  /// 章内首段时跨到上一章段首重播。
  Future<void> prevParagraph() async {
    if (_paragraphs.isEmpty || state.state == PlayerState.idle) return;
    if (_paragraphIndex > 0) {
      _paragraphIndex--;
      notifyListeners();
      final token = _playToken;
      if (state.isPlaying) await _speakCurrentParagraph(token);
      return;
    }
    if (state.hasPrevious) {
      _paragraphIndex = 0; // play() 重载上一章后会重建段落队列并回段首
      await previous();
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
      // [UI-fix v2.0.3 | 2026-08-08] 段落化：暂停同时冻结段落推进定时器 — Qoder
      _paragraphTimer?.cancel();
      _playToken++;
      state = state.copyWith(state: PlayerState.paused);
      // 通知媒体会话暂停状态
      _audioService.notifyPaused();
    }
  }

  /// 停止播放并释放焦点
  void stop() {
    _paragraphTimer?.cancel();
    _playToken++;
    _paragraphs = [];
    _paragraphIndex = 0;
    notifyListeners();
    state = state.copyWith(state: PlayerState.idle);
    _audioService.notifyStopped();
    _audioService.abandonAudioFocus();
  }

  /// 下一章
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

  /// 上一章
  Future<void> previous() async {
    if (!state.hasPrevious) return;
    _paragraphTimer?.cancel();
    _paragraphIndex = 0;
    state = state.copyWith(currentIndex: state.currentIndex - 1);
    await play(paragraphIndex: 0);
  }

  /// 跳转到指定章节
  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.chapters.length) return;
    _paragraphTimer?.cancel();
    _paragraphIndex = 0;
    state = state.copyWith(currentIndex: index);
    await play(paragraphIndex: 0);
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

  @override
  void dispose() {
    _disposed = true;
    _paragraphTimer?.cancel();
    super.dispose();
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
