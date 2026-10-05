import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/book_api.dart';
import '../utils/video_play_utils.dart';
import '../utils/video_progress.dart';
import '../widgets/app_progress_indicator.dart';
import '../widgets/video_danmaku_layer.dart';
import '../widgets/video_long_press_speed.dart';
import '../widgets/video_settings_dialog.dart';

/// 视频播放页面
///
/// 参考 Kotlin 原版 [VideoPlayerActivity] / [VideoPlay]：
/// - 接收视频 URL 和标题参数
/// - 支持播放/暂停、进度拖拽、时间显示
/// - 支持全屏切换（横屏模式）
/// - 加载中指示器与错误处理
/// - 视频源（bookSourceType=4）：章节列表、正文经 [resolveVideoPlayTarget]
///   （相对 URL / 复合 UrlOption header / MPD）后播放，上一集/下一集跳过卷标题
/// — Reasonix
///
/// [D1 | 2026-10-03] video_player Android 插件的 `mixWithOthers` 存在
/// 插件级 sharedOptions 并作用于其后创建的所有播放器；听书/TTS 链路
/// （StreamAudioPlayer）为消除焦点自抢占会置 true。本页必须显式置 false，
/// 否则同进程听过音频后再进视频页，播放器会继承 true 而不再请求/响应
/// 音频焦点（失去外部抢占暂停语义）——即恢复本页原有默认行为。
@visibleForTesting
final VideoPlayerOptions videoPlaybackOptions =
    VideoPlayerOptions(mixWithOthers: false);

class VideoScreen extends StatefulWidget {
  /// 视频播放地址
  final String videoUrl;

  /// 视频标题（显示在 AppBar）
  final String title;

  /// 视频源书籍（非空时启用章节列表与切换）
  final Book? book;

  const VideoScreen({
    super.key,
    required this.videoUrl,
    this.title = '视频播放',
    this.book,
  });

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  /// 视频控制器
  late VideoPlayerController _controller;

  /// 控制器初始化 Future
  late Future<void> _initializeVideoPlayerFuture;

  /// 是否处于全屏模式
  bool _isFullScreen = false;

  /// 是否显示控制栏（点击视频区域切换）
  bool _showControls = true;

  // ===== 视频源书籍（章节播放）状态 =====
  List<BookChapter> _chapters = const [];
  int _chapterIndex = 0;
  bool _loadingChapter = false;
  String? _chapterError;

  /// 书源原始 header（JSON / 行格式），每集再与 UrlOption 合并
  Map<String, String> _sourceHeaders = const {};

  /// 当前集交给播放器的 header（对齐 AnalyzeUrl.headerMap）
  Map<String, String> _videoHeaders = const {};

  /// 当前实际播放地址（网络 URL 或本地 MPD file URI）
  String _currentPlayUrl = '';

  /// MPD 临时文件（切换章/退出时清理）
  File? _mpdTempFile;

  /// 是否已在 didChangeDependencies 调度过书籍视频加载
  ///
  /// `ProviderScope.containerOf(context)` 依赖 InheritedWidget，不可在
  /// `initState` 完成前调用（2.0.34 回归：dependOnInheritedWidget… before
  /// initState completed）。— Reasonix
  bool _bookVideoLoadScheduled = false;

  VideoPlaySettings _playSettings = VideoPlaySettings();

  // ===== [P4-3 波次1b V3] 选集/倍速（对齐原版 gsyVideo） =====

  /// 当前播放倍速（会话级，对齐原版 VideoPlayer.playSpeed：
  /// 视图级成员、切集保留、不持久化；1.0 = 正常）
  double _playbackSpeed = 1.0;

  // ===== [V-B4] 直链进度（video_pos_）与自然播完连播 =====

  /// 直链进度存取（仅直链模式；经既有 config/caches 通道，20 天 TTL）
  VideoPosStore? _directPosStore;

  /// 本次起播要恢复的位置（毫秒）：直链 = video_pos_ 读值；
  /// 书籍 = 初始章的 durChapterPos（换集 saveRead(0) 后归零，对齐原版）
  int _pendingResumeMs = 0;

  /// 直链模式是否已在 didChangeDependencies 调度起播（先读进度再起播，
  /// 对齐原版 seekOnStart；不可在 initState 读 ProviderScope）
  bool _directPlayScheduled = false;

  /// 直链进度定期落盘定时器（原版仅 onDestroy/onError 落盘，此处加固；
  /// 进程被杀时减少进度丢失）
  Timer? _directPosTimer;

  /// 上一帧 completed 态：自然播完只在「未完成 → 完成」边沿触发一次连播
  bool _wasCompleted = false;

  // ===== [V-B4] 长按倍速 =====

  /// 是否正处于长按临时提速（对齐原版 isLongPressSpeed）
  bool _isLongPressSpeed = false;

  /// 当前生效倍速：长按期间 = 设置的长按档位，否则 = 会话倍速
  /// （对齐 VideoPlayer.kt:108-133；弹幕层与控制器共用该值）
  double get _effectivePlaybackSpeed => effectiveVideoSpeed(
        sessionSpeed: _playbackSpeed,
        longPressActive: _isLongPressSpeed,
        longPressSpeed: _playSettings.pressSpeedFactor,
      );

  // ===== [V-B2 | 2026-10-05] 视频弹幕（契约 §2.49 数据 + §2.50 解析） =====

  /// 当前章节弹幕项（Rust 解析结果；空 = 无弹幕或解析失败）
  List<VideoDanmakuItem> _danmakuItems = const [];

  /// 当前章节是否有弹幕原文（对齐原版 VideoPlayer.kt:266-272：
  /// 原文为空 → 开关 GONE；原文非空但解析失败 → 开关保留、画面为空）
  bool _danmakuAvailable = false;

  /// 弹幕显隐开关（对齐原版 VideoPlay.danmakuShow，默认 true、会话级保持）
  bool _danmakuShow = true;

  /// 浮层提示文案（对齐原版 tip_view / showOverlayTip）
  String? _tipText;

  /// 提示自动隐藏定时器（原版 showOverlayTip(delay) 2 秒后淡出）
  Timer? _tipTimer;

  /// 原版 showOverlayTip(message, 2000)：居中提示，[durationMs] 后自动消失
  void _showTip(String text, {int durationMs = 2000}) {
    setState(() => _tipText = text);
    _tipTimer?.cancel();
    _tipTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) setState(() => _tipText = null);
    });
  }

  /// 原版 showOverlayTip()（无参）：立即隐藏提示（长按松手时调用）
  void _hideTip() {
    _tipTimer?.cancel();
    if (_tipText != null && mounted) setState(() => _tipText = null);
  }

  /// 选集（对齐原版 showEpisodeDialog：选集 → chapterInVolumeIndex=position
  /// → saveRead(0) → startPlay；此侧经 [_playChapter] 解析播放并写回进度）
  Future<void> _openEpisodeDialog() async {
    if (widget.book == null || _chapters.isEmpty) return;
    final index = await showVideoEpisodeDialog(
      context,
      episodes: [
        for (var i = 0; i < _chapters.length; i++)
          VideoEpisodeItem(title: _chapters[i].title, chapterIndex: i),
      ],
      currentChapterIndex: _chapterIndex,
    );
    if (index != null && mounted && index != _chapterIndex) {
      unawaited(_playChapter(index));
    }
  }

  /// 倍速档位选择（对齐原版 showSpeedDialog：playSpeed=value → setSpeed →
  /// 入口文案「X.XX X」+ 提示「X倍播放中」2 秒；1.0 时入口回「倍速」无提示）
  Future<void> _openSpeedDialog() async {
    final value = await showVideoSpeedDialog(
      context,
      currentSpeed: _playbackSpeed,
    );
    if (value == null || !mounted) return;
    setState(() => _playbackSpeed = value);
    _controller.setPlaybackSpeed(value);
    if (value != 1.0) {
      _showTip(speedTipLabel(value));
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadPlaySettings());
    // 直链模式起播需先读 video_pos_ 进度（对齐原版 seekOnStart），
    // ProviderScope 依赖 InheritedWidget，统一在 didChangeDependencies 调度
    _loadingChapter = true;
  }

  Future<void> _loadPlaySettings() async {
    final s = await VideoPlaySettings.load();
    if (!mounted) return;
    setState(() => _playSettings = s);
    if (s.startFull && !_isFullScreen) {
      _toggleFullScreen();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 书籍模式：InheritedWidget 就绪后再读 bookApiProvider
    if (widget.book != null && !_bookVideoLoadScheduled) {
      _bookVideoLoadScheduled = true;
      unawaited(_loadBookVideo());
    }
    // 直链模式：先读 video_pos_ 进度再起播（V-B4）
    if (widget.book == null && !_directPlayScheduled) {
      _directPlayScheduled = true;
      unawaited(_startDirectPlayback());
    }
  }

  /// 直链起播：读 20 天内进度 → 解析播放（对齐 VideoPlay.kt:143 seekOnStart）
  Future<void> _startDirectPlayback() async {
    final api = ProviderScope.containerOf(context).read(bookApiProvider);
    final store = VideoPosStore(api);
    _directPosStore = store;
    try {
      _pendingResumeMs = await store.read(widget.videoUrl);
    } catch (_) {
      _pendingResumeMs = 0;
    }
    if (!mounted) return;
    await _playDirectUrl(widget.videoUrl);
    if (!mounted) return;
    // 定期落盘（原版仅 onDestroy/onError，此处加固防进程被杀丢进度）
    _directPosTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_saveDirectProgress()),
    );
  }

  /// 直链进度落盘（毫秒；未起播/读到 0 时跳过）
  Future<void> _saveDirectProgress() async {
    final store = _directPosStore;
    if (store == null || widget.book != null) return;
    var pos = 0;
    try {
      pos = _controller.value.isInitialized
          ? _controller.value.position.inMilliseconds
          : 0;
    } catch (_) {
      pos = 0;
    }
    if (pos <= 0) return;
    try {
      await store.write(widget.videoUrl, pos);
    } catch (_) {}
  }

  /// 直链模式：同样走复合 URL / header / MPD 解析
  Future<void> _playDirectUrl(String raw) async {
    setState(() {
      _loadingChapter = true;
      _chapterError = null;
    });
    try {
      final target = resolveVideoPlayTarget(
        content: raw,
        chapterUrl: raw,
        sourceHeaders: _sourceHeaders,
      );
      await _startFromTarget(target);
      if (mounted) setState(() => _loadingChapter = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingChapter = false;
          _chapterError = '$e';
        });
      }
    }
  }

  /// 视频源书籍：加载章节列表并播放当前可播章（对齐 VideoPlayerActivity）
  Future<void> _loadBookVideo() async {
    final book = widget.book!;
    setState(() => _loadingChapter = true);
    try {
      final api = ProviderScope.containerOf(context).read(bookApiProvider);
      if (_sourceHeaders.isEmpty && book.origin.isNotEmpty) {
        try {
          final sources = await api.getBookSources();
          for (final s in sources) {
            if (s.bookSourceUrl == book.origin &&
                s.header != null &&
                s.header!.isNotEmpty) {
              _sourceHeaders = parseSourceHeaderMap(s.header!);
              break;
            }
          }
        } catch (_) {}
      }
      _chapters = await api.getChapters(book.bookUrl);
      if (_chapters.isEmpty && book.origin.isNotEmpty) {
        _chapters = await api.refreshToc(book.bookUrl, book.origin);
      }
      if (_chapters.isEmpty) {
        setState(() {
          _loadingChapter = false;
          _chapterError = '暂无章节';
        });
        return;
      }
      final index = findPlayableChapterIndex(
        _chapters.map((c) => c.isVolume).toList(),
        book.durChapterIndex,
      );
      _chapterIndex = index;
      // 初始章恢复书籍进度（对齐 VideoPlay.startPlay durChapterPos → seekOnStart）
      await _playChapter(index, resumeMs: book.durChapterPos);
    } catch (e) {
      setState(() {
        _loadingChapter = false;
        _chapterError = '$e';
      });
    }
  }

  /// 加载当前章弹幕：§2.49 原文 → §2.50 Rust 纯函数解析 → 渲染层数据
  ///
  /// 无记录/读失败/解析失败一律降级为空列表（弹幕是增强层）；[raw] 非空
  /// 即显示开关（对齐原版 VideoPlayer.kt:266-272：原文非空但解析失败时
  /// 开关仍在、画面无弹幕）。
  Future<void> _loadDanmakuForChapter(BookApi api, int index) async {
    final book = widget.book;
    if (book == null) return;
    String? raw;
    try {
      raw = await api.getVideoDanmaku(
        bookUrl: book.bookUrl,
        chapterIndex: index,
      );
    } catch (_) {
      raw = null;
    }
    if (!mounted) return;
    if (raw == null || raw.trim().isEmpty) {
      setState(() {
        _danmakuAvailable = false;
        _danmakuItems = const [];
      });
      return;
    }
    List<VideoDanmakuItem>? items;
    try {
      items = await api.parseVideoDanmaku(raw: raw);
    } catch (_) {
      items = null;
    }
    if (!mounted) return;
    setState(() {
      _danmakuAvailable = true;
      _danmakuItems = items ?? const [];
    });
  }

  /// 播放指定章节：正文 → [resolveVideoPlayTarget] → 播放器
  ///
  /// [resumeMs] 仅初始章携带书籍进度；换集（手动选集/自动连播）对齐原版
  /// `saveRead(0) → startPlay`，从 0 起播。
  Future<void> _playChapter(int index, {int resumeMs = 0}) async {
    final book = widget.book!;
    final chapter = _chapters[index];
    if (chapter.isVolume) {
      final playable = findPlayableChapterIndex(
        _chapters.map((c) => c.isVolume).toList(),
        index,
      );
      if (playable == index && chapter.isVolume) {
        setState(() {
          _loadingChapter = false;
          _chapterError = '当前为卷标题，无播放地址';
        });
        return;
      }
      return _playChapter(playable);
    }
    setState(() {
      _loadingChapter = true;
      _chapterError = null;
    });
    try {
      final api = ProviderScope.containerOf(context).read(bookApiProvider);
      final content = book.origin.isNotEmpty
          ? await api.fetchChapterContent(
              book.bookUrl, chapter.url, book.origin)
          : await api.getChapterContent(book.bookUrl, index);
      // [V-B2] 弹幕与正文同链加载：§2.49 原文 → §2.50 Rust 解析
      await _loadDanmakuForChapter(api, index);
      final target = resolveVideoPlayTarget(
        content: content,
        chapterUrl: chapter.url,
        sourceHeaders: _sourceHeaders,
      );
      if (!target.isMpd && target.url.isEmpty) {
        setState(() {
          _loadingChapter = false;
          _chapterError = '章节未解析出视频地址';
        });
        return;
      }
      debugPrint(
        '[VideoPlay] chapter=${chapter.title} url=${target.url} '
        'mpd=${target.isMpd} headers=${target.headers.keys.toList()}',
      );
      _pendingResumeMs = resumeMs;
      await _startFromTarget(target);
      setState(() {
        _loadingChapter = false;
        _chapterIndex = index;
      });
      unawaited(_saveProgress(chapterPos: 0));
    } catch (e) {
      setState(() {
        _loadingChapter = false;
        _chapterError = '$e';
      });
    }
  }

  /// 将 [VideoPlayTarget] 落到播放器（含 MPD 落盘）
  Future<void> _startFromTarget(VideoPlayTarget target) async {
    try {
      _controller.removeListener(_onPlayerValueChanged);
      _controller.dispose();
    } catch (_) {}
    // 换集/重试重建控制器：completed 边沿状态归零
    _wasCompleted = false;
    await _clearMpdTemp();

    _videoHeaders = Map<String, String>.from(target.headers);

    if (target.isMpd) {
      final dir = await getTemporaryDirectory();
      final name =
          'legado_video_${DateTime.now().millisecondsSinceEpoch}.mpd';
      final file = File('${dir.path}/$name');
      await file.writeAsString(target.mpdContent!);
      _mpdTempFile = file;
      _currentPlayUrl = file.uri.toString();
      _initPlayer(filePath: file.path);
      return;
    }

    _currentPlayUrl = target.url;
    _initPlayer(networkUrl: target.url);
  }

  Future<void> _clearMpdTemp() async {
    final f = _mpdTempFile;
    _mpdTempFile = null;
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 上一集/下一集：跳过卷标题
  void _switchChapter(int delta) {
    if (widget.book == null || _chapters.isEmpty) return;
    var next = _chapterIndex + delta;
    while (next >= 0 && next < _chapters.length && _chapters[next].isVolume) {
      next += delta;
    }
    if (next < 0 || next >= _chapters.length) return;
    unawaited(_playChapter(next));
  }

  /// 写回阅读进度（durChapterIndex / durChapterPos）
  Future<void> _saveProgress({int? chapterPos}) async {
    final book = widget.book;
    if (book == null) return;
    try {
      final api = ProviderScope.containerOf(context).read(bookApiProvider);
      var pos = chapterPos;
      if (pos == null) {
        try {
          pos = _controller.value.isInitialized
              ? _controller.value.position.inMilliseconds
              : 0;
        } catch (_) {
          pos = 0;
        }
      }
      await api.updateReadingProgress(
        bookUrl: book.bookUrl,
        chapterIndex: _chapterIndex,
        chapterPos: pos,
      );
    } catch (_) {}
  }

  /// 错误态「重试」：book 模式重试当前章；直链模式重解析当前 URL
  void _retryPlayback() {
    if (widget.book != null) {
      if (_chapters.isEmpty) {
        unawaited(_loadBookVideo());
      } else {
        unawaited(_playChapter(_chapterIndex));
      }
      return;
    }
    unawaited(_retryDirectPlayback());
  }

  /// 直链错误重试：先落盘当前位置再恢复播放
  /// （对齐原版 onError → saveRead() → mSeekOnStart = durChapterPos）
  Future<void> _retryDirectPlayback() async {
    await _saveDirectProgress();
    final store = _directPosStore;
    if (store != null) {
      try {
        _pendingResumeMs = await store.read(widget.videoUrl);
      } catch (_) {
        _pendingResumeMs = 0;
      }
    }
    if (!mounted) return;
    await _playDirectUrl(widget.videoUrl);
  }

  /// 初始化视频播放器（网络或本地 MPD 文件）
  void _initPlayer({String? networkUrl, String? filePath}) {
    if (filePath != null && filePath.isNotEmpty) {
      _controller = VideoPlayerController.file(
        File(filePath),
        videoPlayerOptions: videoPlaybackOptions,
      );
      _wireControllerInit();
      return;
    }

    final videoUrl = networkUrl ??
        (_currentPlayUrl.isNotEmpty ? _currentPlayUrl : widget.videoUrl);
    if (networkUrl != null) _currentPlayUrl = networkUrl;
    final uri = Uri.tryParse(videoUrl);
    if (uri == null || videoUrl.isEmpty) {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(''),
        videoPlayerOptions: videoPlaybackOptions,
      );
      _initializeVideoPlayerFuture = Future<void>.error(
        Exception('无效的视频地址'),
      );
      return;
    }

    _controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: _videoHeaders,
      videoPlayerOptions: videoPlaybackOptions,
    );
    _wireControllerInit();
  }

  /// 初始化后恢复进度并自动播放（对齐 VideoPlay.seekOnStart）
  void _wireControllerInit() {
    _controller.addListener(_onPlayerValueChanged);
    _initializeVideoPlayerFuture = _controller.initialize().then((_) async {
      if (!mounted) return;
      debugPrint(
        '[VideoPlay] controller ready '
        'size=${_controller.value.size} '
        'duration=${_controller.value.duration} '
        'url=$_currentPlayUrl',
      );
      // 恢复位置：直链 = video_pos_ 读值；书籍 = 初始章 durChapterPos
      if (_pendingResumeMs > 0) {
        try {
          await _controller.seekTo(Duration(milliseconds: _pendingResumeMs));
        } catch (_) {}
      }
      setState(() {});
      if (_playSettings.autoPlay) {
        await _controller.play();
      }
      // [P4-3 波次1b V3] 换集重建控制器后恢复会话级倍速
      // （对齐原版 playSpeed 为视图级成员，跨集保持）
      if (_effectivePlaybackSpeed != 1.0) {
        _controller.setPlaybackSpeed(_effectivePlaybackSpeed);
      }
      if (!mounted) return;
      // 起播后刷新一次：长按倍速手势区的 enabled 依赖 isPlaying
      setState(() {});
      debugPrint(
        '[VideoPlay] after play '
        'isPlaying=${_controller.value.isPlaying} '
        'isBuffering=${_controller.value.isBuffering} '
        'position=${_controller.value.position}',
      );
    }).catchError((Object e, StackTrace st) {
      debugPrint('[VideoPlay] controller init FAILED: $e');
      throw e;
    });
  }

  /// 播放器值变化：仅在自然播完边沿触发连播
  /// （对齐 onAutoCompletion，VideoPlayer.kt:185-188）
  void _onPlayerValueChanged() {
    final completed = _controller.value.isCompleted;
    if (shouldAdvanceOnCompletion(
      wasCompleted: _wasCompleted,
      isCompleted: completed,
    )) {
      _wasCompleted = true;
      unawaited(_onPlaybackCompleted());
    } else if (!completed) {
      _wasCompleted = false;
    }
  }

  /// 自然播完：自动切下一集；无下一集 → 提示「已播放完」
  ///
  /// 对齐 VideoPlay.upDurIndex(1)（VideoPlay.kt:474-490）：越界 toast
  /// 「已播放完」；推进后是否自动开始播放仍由 autoPlay 决定
  /// （原版 startPlay 内 `if (autoPlay) player.startPlayLogic()`）。
  /// 用户主动停止/错误不产生 completed 边沿，自然不连播
  /// （对齐 onCompletion，VideoPlayer.kt:190-193）。
  Future<void> _onPlaybackCompleted() async {
    if (!mounted || widget.book == null || _loadingChapter) return;
    final next = nextPlayableChapterIndex(
      _chapters.map((c) => c.isVolume).toList(),
      _chapterIndex,
    );
    if (next == null) {
      _showTip('已播放完');
      return;
    }
    await _playChapter(next);
  }

  /// 长按倍速：播放中长按 → 临时提速到设置档位
  /// （对齐 VideoPlayer.kt:108-115：setVideoSpeed + tip + isLongPressSpeed）
  void _startLongPressSpeed() {
    if (_isLongPressSpeed || !_controller.value.isPlaying) return;
    final speed = _playSettings.pressSpeedFactor;
    setState(() => _isLongPressSpeed = true);
    _controller.setPlaybackSpeed(speed);
    _showTip(longPressSpeedTipLabel(speed));
    // 弹幕层经 _effectivePlaybackSpeed 联动（对齐 setVideoSpeed 内
    // danmakuSpeed-(speed-1)/6，见 VideoPlayer.kt:135-141）
  }

  /// 松手恢复会话倍速并隐藏提示（对齐 touchSurfaceUp，VideoPlayer.kt:124-133）
  void _endLongPressSpeed() {
    if (!_isLongPressSpeed) return;
    setState(() => _isLongPressSpeed = false);
    _controller.setPlaybackSpeed(_playbackSpeed);
    _hideTip();
    // 原版 resolveDanmakuStart(当前位置)：弹幕层在倍速 prop 变更时
    // 以当前插值位置重锚（video_danmaku_layer.dart didUpdateWidget）
  }

  @override
  void dispose() {
    _tipTimer?.cancel();
    _directPosTimer?.cancel();
    // 直链进度落盘（对齐原版 VideoPlayerActivity.onDestroy → saveRead()）
    unawaited(_saveDirectProgress());
    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    try {
      _controller.removeListener(_onPlayerValueChanged);
      _controller.dispose();
    } catch (_) {}
    unawaited(_clearMpdTemp());
    super.dispose();
  }

  void _toggleFullScreen() {
    setState(() {
      _isFullScreen = !_isFullScreen;
    });

    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        if (widget.book != null) {
          unawaited(_saveProgress());
        } else {
          // 直链退出落盘（对齐原版 onDestroy → saveRead）
          unawaited(_saveDirectProgress());
        }
      },
      child: Scaffold(
        appBar: _isFullScreen
            ? null
            : LegadoAppBar(
                title: Text(
                  widget.book != null && _chapters.isNotEmpty
                      ? _chapters[_chapterIndex].title
                      : widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // [LAYOUT_PLAN P3] 沉浸域仅顶栏动作行规范：动作顺序上一集/下一集/设置/全屏（本体不动）
                actions: [
                  if (widget.book != null && _chapters.isNotEmpty) ...[
                    IconButton(
                      icon: const Icon(Symbols.skip_previous_rounded),
                      tooltip: '上一集',
                      onPressed: _chapterIndex > 0
                          ? () => _switchChapter(-1)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Symbols.skip_next_rounded),
                      tooltip: '下一集',
                      onPressed: _chapterIndex < _chapters.length - 1
                          ? () => _switchChapter(1)
                          : null,
                    ),
                  ],
                  // P2-15：视频设置（对标原版 menu_config_settings → SettingsDialog）
                  IconButton(
                    icon: const Icon(Symbols.settings_rounded),
                    tooltip: '播放设置',
                    onPressed: () async {
                      final updated = await showVideoSettingsDialog(context);
                      if (updated != null && mounted) {
                        setState(() => _playSettings = updated);
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Symbols.fullscreen_rounded),
                    tooltip: '全屏',
                    onPressed: _toggleFullScreen,
                  ),
                ],
              ),
        body: _chapterError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Symbols.error_rounded,
                          size: 64, color: Colors.red),
                      const SizedBox(height: 16),
                      Text('视频加载失败',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(_chapterError!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _retryPlayback,
                        icon: const Icon(Symbols.refresh_rounded),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            : _loadingChapter
                // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
                ? const Center(child: AppCircularProgressIndicator())
                : FutureBuilder<void>(
                    future: _initializeVideoPlayerFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装
                              AppCircularProgressIndicator(),
                              SizedBox(height: 16),
                              Text('正在加载视频...'),
                            ],
                          ),
                        );
                      }

                      if (snapshot.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Symbols.error_rounded,
                                  size: 64,
                                  color: Colors.red,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  '视频加载失败',
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  snapshot.error.toString(),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton.icon(
                                  onPressed: _retryPlayback,
                                  icon: const Icon(Symbols.refresh_rounded),
                                  label: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return _buildPlayerView();
                    },
                  ),
      ),
    );
  }

  /// 播放区布局：视频占剩余高度（Expanded），控件/信息固定在底部，
  /// 避免宽屏片源 AspectRatio 按宽度算出超高画面导致
  /// `BOTTOM OVERFLOWED BY … PIXELS`（量子资源网等）。— Reasonix + UI
  Widget _buildPlayerView() {
    if (_isFullScreen) {
      // 全屏：画面铺满，控件叠在底部（对齐原版沉浸播放）
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black, child: _buildVideoSurface()),
          if (_showControls)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: _buildControlBar()),
            ),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: _buildVideoSurface(),
          ),
        ),
        SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildControlBar(),
              _buildVideoInfo(),
            ],
          ),
        ),
      ],
    );
  }

  /// 在可用约束内居中按比例绘制，绝不撑破父级
  Widget _buildVideoSurface() {
    final raw = _controller.value.isInitialized
        ? _controller.value.aspectRatio
        : 16 / 9;
    // 防御异常 size（宽/高对调或 0）导致比例极端
    final aspectRatio = (raw.isFinite && raw > 0.2 && raw < 5.0) ? raw : 16 / 9;

    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: VideoLongPressSpeedArea(
          enabled: _controller.value.isPlaying,
          onSpeedUp: _startLongPressSpeed,
          onRestore: _endLongPressSpeed,
          onTap: () => setState(() => _showControls = !_showControls),
          onDoubleTap: () {
            setState(() {
              _controller.value.isPlaying
                  ? _controller.pause()
                  : _controller.play();
            });
          },
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              VideoPlayer(_controller),
              // [V-B2] 弹幕层：视频之上、控制层之下（对齐原版
              // video_layout_controller.xml 中 danmaku_view 的层序）
              if (_danmakuAvailable)
                VideoDanmakuLayer(
                  items: _danmakuItems,
                  player: _controller,
                  show: _danmakuShow,
                  // [V-B4] 长按期间随临时倍速联动（VideoPlayer.kt:135-141）
                  playbackSpeed: _effectivePlaybackSpeed,
                ),
              if (_showControls) _buildOverlayControls(),
              // [P4-3 波次1b V3] 原版 tip_view：画面居中提示（如「1.5倍播放中」）
              if (_tipText != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _tipText!,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverlayControls() {
    return Container(
      color: Colors.black26,
      child: Center(
        child: IconButton(
          iconSize: 64,
          color: Colors.white,
          icon: Icon(
            _controller.value.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
          ),
          onPressed: () {
            setState(() {
              _controller.value.isPlaying
                  ? _controller.pause()
                  : _controller.play();
            });
          },
        ),
      ),
    );
  }

  Widget _buildControlBar() {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final position = value.position;
        final duration = value.duration;
        final progress = duration.inMilliseconds > 0
            ? position.inMilliseconds / duration.inMilliseconds
            : 0.0;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: _isFullScreen ? Colors.black : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: progress.clamp(0.0, 1.0),
                  onChanged: (v) {
                    final newPosition = Duration(
                      milliseconds: (duration.inMilliseconds * v).round(),
                    );
                    _controller.seekTo(newPosition);
                  },
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: Icon(
                      value.isPlaying ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                      color: _isFullScreen ? Colors.white : null,
                    ),
                    onPressed: () {
                      setState(() {
                        value.isPlaying
                            ? _controller.pause()
                            : _controller.play();
                      });
                    },
                  ),
                  Text(
                    _formatDuration(position),
                    style: TextStyle(
                      fontSize: 12,
                      color: _isFullScreen ? Colors.white70 : null,
                    ),
                  ),
                  const Text(
                    ' / ',
                    style: TextStyle(fontSize: 12),
                  ),
                  Text(
                    _formatDuration(duration),
                    style: TextStyle(
                      fontSize: 12,
                      color: _isFullScreen ? Colors.white70 : null,
                    ),
                  ),
                  // [V-B2] 弹幕开关（对齐原版控制器条 toggle_danmaku：
                  // 仅一个文本按钮「关弹幕/开弹幕」，无弹幕时 GONE）
                  if (_danmakuAvailable)
                    TextButton(
                      onPressed: () =>
                          setState(() => _danmakuShow = !_danmakuShow),
                      child: Text(
                        _danmakuShow ? '关弹幕' : '开弹幕',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isFullScreen ? Colors.white : null,
                        ),
                      ),
                    ),
                  const Spacer(),
                  // [P4-3 波次1b V3] 选集/倍速入口。原版二者仅存在于全屏控制器
                  // （video_layout_controller_full.xml 的 episode_list /
                  // playback_speed；非全屏 video_layout_controller.xml 无此二项，
                  // findViewById 为 null 安全跳过），故仅全屏渲染。
                  // 原版自右向左顺序：next → 选集 → 倍速；此侧最右为全屏键，
                  // 选集/倍速置于其左侧，顺序：倍速、选集。
                  if (_isFullScreen) ...[
                    TextButton(
                      onPressed: _openSpeedDialog,
                      child: Text(
                        speedEntryLabel(_playbackSpeed),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (widget.book != null && _chapters.isNotEmpty)
                      TextButton(
                        onPressed: _openEpisodeDialog,
                        child: const Text(
                          '选集',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                  ],
                  IconButton(
                    icon: Icon(
                      _isFullScreen
                          ? Symbols.fullscreen_exit_rounded
                          : Symbols.fullscreen_rounded,
                      color: _isFullScreen ? Colors.white : null,
                    ),
                    tooltip: _isFullScreen ? '退出全屏' : '全屏',
                    onPressed: _toggleFullScreen,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildVideoInfo() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            _currentPlayUrl.isNotEmpty ? _currentPlayUrl : widget.videoUrl,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
