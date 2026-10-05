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
import '../services/video_float_window.dart';
import '../utils/video_play_utils.dart';
import '../utils/video_progress.dart';
import '../widgets/app_progress_indicator.dart';
import '../widgets/video_danmaku_layer.dart';
import '../widgets/video_float_window_button.dart';
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

/// [V-B3] 悬浮窗回全屏的路由参数（app.dart 从原生交回状态组装）
class VideoScreenArgs {
  final String videoUrl;
  final String title;
  final Book? book;
  final String? presetUrl;
  final Map<String, String> presetHeaders;
  final String? presetMpdPath;
  final int initialResumeMs;
  final int? initialChapterIndex;
  final double initialSpeed;
  final bool initialPlaying;

  const VideoScreenArgs({
    this.videoUrl = '',
    this.title = '视频播放',
    this.book,
    this.presetUrl,
    this.presetHeaders = const {},
    this.presetMpdPath,
    this.initialResumeMs = 0,
    this.initialChapterIndex,
    this.initialSpeed = 1.0,
    this.initialPlaying = true,
  });
}

class VideoScreen extends StatefulWidget {
  /// 视频播放地址
  final String videoUrl;

  /// 视频标题（显示在 AppBar）
  final String title;

  /// 视频源书籍（非空时启用章节列表与切换）
  final Book? book;

  // ===== [V-B3] 悬浮窗回全屏的续播参数（对齐原版 isNew=false 转移） =====

  /// 已解析的播放地址（悬浮窗原生层交回；null = 按常规流程解析）
  final String? presetUrl;

  /// 与 [presetUrl] 配套的 header
  final Map<String, String> presetHeaders;

  /// 与 [presetUrl] 配套的 MPD 临时文件路径（所有权随回全屏交回本页）
  final String? presetMpdPath;

  /// 续播位置（毫秒）
  final int initialResumeMs;

  /// 书籍模式续播的绝对章节索引
  final int? initialChapterIndex;

  /// 会话倍速（悬浮窗切回后保持，对齐原版 playSpeed 视图级语义）
  final double initialSpeed;

  /// 悬浮窗内的播放态（false = 回到页面后保持暂停）
  final bool initialPlaying;

  const VideoScreen({
    super.key,
    required this.videoUrl,
    this.title = '视频播放',
    this.book,
    this.presetUrl,
    this.presetHeaders = const {},
    this.presetMpdPath,
    this.initialResumeMs = 0,
    this.initialChapterIndex,
    this.initialSpeed = 1.0,
    this.initialPlaying = true,
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

  /// 是否已调度起播引导（原分书籍/直链两个调度标记，V-B3 合并为引导入口；
  /// `ProviderScope.containerOf(context)` 依赖 InheritedWidget，不可在
  /// `initState` 完成前调用（2.0.34 回归：dependOnInheritedWidget… before
  /// initState completed）。— Reasonix
  bool _bootstrapStarted = false;

  // ===== [V-B3] 悬浮窗移交状态 =====

  /// 悬浮窗回全屏/接管后的预置播放目标（不重新解析章节正文）
  VideoPlayTarget? _presetTarget;

  /// 状态已移交悬浮窗（页面正在退出；禁止再 setState/起播）
  bool _handedToFloat = false;

  /// 默认悬浮窗播放：首次解析成功后只判定一次
  /// （对齐原版仅 Activity 创建时转发，VideoPlayerActivity.kt:177-193）
  bool _autoFloatPending = true;

  /// 悬浮窗回全屏的播放态覆写（null = 沿用 autoPlay 设置）
  bool? _resumePlayingOverride;

  /// 悬浮窗回全屏时书籍续播的绝对章节索引
  int? _resumeChapterIndex;

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
    _playSettingsLoaded = _loadPlaySettings();
    // 直链模式起播需先读 video_pos_ 进度（对齐原版 seekOnStart），
    // ProviderScope 依赖 InheritedWidget，统一在 didChangeDependencies 调度
    _loadingChapter = true;
  }

  /// 设置加载 Future：起播引导需在「默认悬浮窗」判定前完成（对齐原版
  /// SharedPreferences 同步读取语义）
  late final Future<void> _playSettingsLoaded;

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
    if (_bootstrapStarted) return;
    _bootstrapStarted = true;
    // [V-B3] 先探测/接管活动悬浮窗，再走书籍/直链既有解析链
    // （对齐原版 Activity 创建即停服务 + VideoPlay 静态状态接管语义）
    unawaited(_bootstrapPlayback());
  }

  /// 起播引导：显式预置（app.dart 经路由参数回全屏）或探测活动悬浮窗
  Future<void> _bootstrapPlayback() async {
    await _playSettingsLoaded;
    if (!mounted || _handedToFloat) return;
    await _applyExplicitOrActiveFloatState();
    if (!mounted || _handedToFloat) return;
    if (widget.book != null) {
      await _loadBookVideo();
    } else {
      await _startDirectPlayback();
    }
  }

  /// 悬浮窗状态接入：
  /// - 路由显式携带 preset（回全屏导航）→ 直接采用；
  /// - 否则探测活动悬浮窗：同源 → 接管（停服 + 取最终位置），
  ///   异源 → 落库旧内容进度并关闭（probeAndTakeOver 内处理）。
  Future<void> _applyExplicitOrActiveFloatState() async {
    if (widget.presetUrl != null) {
      _applyFloatState(VideoFloatWindowState(
        url: widget.presetUrl!,
        headers: widget.presetHeaders,
        positionMs: widget.initialResumeMs,
        playing: widget.initialPlaying,
        speed: widget.initialSpeed,
        bookUrl: widget.book?.bookUrl,
        chapterIndex: widget.initialChapterIndex ?? -1,
        mpdTempPath: widget.presetMpdPath,
      ));
      return;
    }
    final taken = await VideoFloatWindowCoordinator.instance.probeAndTakeOver(
      bookUrl: widget.book?.bookUrl,
      videoUrl: widget.book == null ? widget.videoUrl : null,
      api: _readApi(),
    );
    if (taken != null && mounted) _applyFloatState(taken);
  }

  /// 把悬浮窗状态转为本页续播参数（原版 clonePlayState 语义）
  void _applyFloatState(VideoFloatWindowState state) {
    if (state.positionMs > 0) _pendingResumeMs = state.positionMs;
    _playbackSpeed = state.speed.clamp(0.5, 3.0);
    _resumePlayingOverride = state.playing;
    _videoHeaders = Map<String, String>.from(state.headers);
    if (state.chapterIndex >= 0) _resumeChapterIndex = state.chapterIndex;
    _presetTarget = VideoPlayTarget(
      url: state.url,
      headers: Map<String, String>.from(state.headers),
      mpdFilePath: state.mpdTempPath,
    );
  }

  BookApi _readApi() => ProviderScope.containerOf(context).read(bookApiProvider);

  /// 直链起播：读 20 天内进度 → 解析播放（对齐 VideoPlay.kt:143 seekOnStart）
  Future<void> _startDirectPlayback() async {
    final api = ProviderScope.containerOf(context).read(bookApiProvider);
    final store = VideoPosStore(api);
    _directPosStore = store;
    // [V-B3] 悬浮窗回全屏：位置/URL 已随状态交回，不再读 video_pos_
    if (_presetTarget == null) {
      try {
        _pendingResumeMs = await store.read(widget.videoUrl);
      } catch (_) {
        _pendingResumeMs = 0;
      }
    }
    if (!mounted || _handedToFloat) return;
    await _playDirectUrl(widget.videoUrl);
    if (!mounted || _handedToFloat) return;
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

  /// 直链模式：同样走复合 URL / header / MPD 解析；
  /// [V-B3] 悬浮窗回全屏时直接用交回的目标，不重复解析正文
  Future<void> _playDirectUrl(String raw) async {
    setState(() {
      _loadingChapter = true;
      _chapterError = null;
    });
    try {
      final target = _presetTarget ??
          resolveVideoPlayTarget(
            content: raw,
            chapterUrl: raw,
            sourceHeaders: _sourceHeaders,
          );
      await _startFromTarget(target);
      if (mounted && !_handedToFloat) setState(() => _loadingChapter = false);
    } catch (e) {
      if (mounted && !_handedToFloat) {
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
      final preset = _presetTarget;
      final presetIndex = _resumeChapterIndex;
      final index = (preset != null &&
              presetIndex != null &&
              presetIndex >= 0 &&
              presetIndex < _chapters.length)
          ? presetIndex
          : findPlayableChapterIndex(
              _chapters.map((c) => c.isVolume).toList(),
              book.durChapterIndex,
            );
      _chapterIndex = index;
      if (preset != null) {
        // [V-B3] 悬浮窗回全屏：URL/位置/header 已交回，仅补弹幕数据后直接续播
        if (!mounted || _handedToFloat) return;
        final api = _readApi();
        await _loadDanmakuForChapter(api, index);
        if (!mounted || _handedToFloat) return;
        await _startFromTarget(preset);
        if (mounted && !_handedToFloat) {
          setState(() => _loadingChapter = false);
        }
        return;
      }
      // 初始章恢复书籍进度（对齐 VideoPlay.startPlay durChapterPos → seekOnStart）
      await _playChapter(index, resumeMs: book.durChapterPos);
    } catch (e) {
      if (!mounted || _handedToFloat) return;
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
      if (!mounted || _handedToFloat) return;
      setState(() {
        _loadingChapter = false;
        _chapterIndex = index;
      });
      unawaited(_saveProgress(chapterPos: 0));
    } catch (e) {
      if (!mounted || _handedToFloat) return;
      setState(() {
        _loadingChapter = false;
        _chapterError = '$e';
      });
    }
  }

  /// 将 [VideoPlayTarget] 落到播放器（含 MPD 落盘）
  Future<void> _startFromTarget(VideoPlayTarget target) async {
    // [V-B3] 默认悬浮窗播放：首次解析成功即移交（不起 Flutter 播放器）
    if (await _maybeAutoEnterFloat(target)) return;
    try {
      _controller.removeListener(_onPlayerValueChanged);
      _controller.dispose();
    } catch (_) {}
    // 换集/重试重建控制器：completed 边沿状态归零
    _wasCompleted = false;
    await _clearMpdTemp();

    _videoHeaders = Map<String, String>.from(target.headers);

    // [V-B3] 悬浮窗回全屏：MPD 临时文件已由原生移交所有权，直接播放
    if (target.mpdFilePath != null && target.mpdFilePath!.isNotEmpty) {
      final file = File(target.mpdFilePath!);
      _mpdTempFile = file;
      _currentPlayUrl = file.uri.toString();
      _initPlayer(filePath: file.path);
      return;
    }

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

  /// 默认悬浮窗播放（对齐原版 VideoPlayerActivity.kt:177-193）：
  /// 仅在首次解析成功后判定一次，成功移交返回 true（页面随即退出）。
  Future<bool> _maybeAutoEnterFloat(VideoPlayTarget target) async {
    if (!_autoFloatPending) return false;
    _autoFloatPending = false;
    if (!_playSettings.defaultFloatWindow ||
        _handedToFloat ||
        widget.presetUrl != null) {
      return false;
    }
    return _handOffToFloatWindow(target);
  }

  /// [V-B3] 移交悬浮窗：Dart 保存 url/header/位置/倍速/播放态 → 原生服务
  /// 新建 Media3 ExoPlayer 续播（对齐原版 `VideoPlay.savePlayState` /
  /// `clonePlayState` 的「状态克隆」语义，VideoPlay.kt:386-398）。
  ///
  /// [positionMs] 省略时取 Flutter 控制器当前位置。
  Future<bool> _handOffToFloatWindow(
    VideoPlayTarget target, {
    int? positionMs,
  }) async {
    if (!mounted || _handedToFloat) return false;
    // [W2] 非 Android 无全局悬浮窗概念：静默降级全屏播放页
    //（对齐 JS 入口 `!kIsWeb && Platform.isAndroid` 的既有降级语义）
    if (!VideoFloatWindowCoordinator.instance.isSupported) return false;
    final book = widget.book;
    var mpdPath = target.mpdFilePath;
    if (target.isMpd && (mpdPath == null || mpdPath.isEmpty)) {
      final dir = await getTemporaryDirectory();
      final name =
          'legado_video_float_${DateTime.now().millisecondsSinceEpoch}.mpd';
      final file = File('${dir.path}/$name');
      await file.writeAsString(target.mpdContent!);
      await _clearMpdTemp();
      _mpdTempFile = file;
      mpdPath = file.path;
    }
    final playUrl = (mpdPath != null && mpdPath.isNotEmpty)
        ? File(mpdPath).uri.toString()
        : target.url;
    if (playUrl.isEmpty) return false;
    final pos = positionMs ??
        (_controller.value.isInitialized
            ? _controller.value.position.inMilliseconds
            : _pendingResumeMs);
    final title = book != null &&
            _chapters.isNotEmpty &&
            _chapterIndex >= 0 &&
            _chapterIndex < _chapters.length
        ? _chapters[_chapterIndex].title
        : widget.title;
    final state = VideoFloatWindowState(
      url: playUrl,
      title: title,
      bookName: book?.name ?? '',
      headers: Map<String, String>.from(target.headers),
      positionMs: pos,
      playing: _resumePlayingOverride ??
          (_controller.value.isInitialized
              ? _controller.value.isPlaying
              : true),
      speed: _playbackSpeed,
      bookUrl: book?.bookUrl,
      chapterIndex: _chapterIndex,
      chapterTitle: title,
      directUrl: book == null ? widget.videoUrl : null,
      hasPrev: book != null && _chapters.isNotEmpty
          ? _chapterHasPlayable(_chapterIndex, -1)
          : false,
      hasNext: book != null && _chapters.isNotEmpty
          ? _chapterHasPlayable(_chapterIndex, 1)
          : false,
      mpdTempPath: mpdPath,
    );
    // 进度先落库（对齐原版 startFloatingWindow → savePlayState 即时保存语义）
    if (pos > 0) {
      if (book != null) {
        await _saveProgress(chapterPos: pos);
      } else {
        final store = _directPosStore;
        if (store != null) {
          try {
            await store.write(widget.videoUrl, pos);
          } catch (_) {}
        }
      }
    }
    // [W1] 移交前确定性暂停本页播放器：原生 ExoPlayer 为异步 prepare，而本页
    // 要等 pop 转场结束才 dispose；不暂停则存在双播放器并行发声窗口（此前
    // 仅靠音频焦点仲裁兜底，非确定性）。播放态/位置已捕获进 state，不受影响。
    try {
      if (_controller.value.isInitialized && _controller.value.isPlaying) {
        await _controller.pause();
      }
    } catch (_) {}
    final coordinator = VideoFloatWindowCoordinator.instance;
    final ok = await coordinator.enterWindow(
      state: state,
      book: book,
      chapters: book != null ? _chapters : null,
      sourceHeaders: _sourceHeaders,
      api: _readApi(),
    );
    if (!ok) {
      // [W2/W4] 失败提示按原因分流：权限缺失 → 引导授权；FGS 后台启动受限
      // → 引导回应用内重试；其他 → 中性失败提示
      final reason = coordinator.lastEnterError;
      if (reason == 'no_overlay_permission') {
        await coordinator.requestOverlayPermission();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请允许「显示在其他应用上层」后重试')),
          );
        }
      } else if (reason == 'background_start_rejected') {
        // 原版此类失败仅日志记录、无用户文案（BaseService
        // tryStartForegroundNotification），此处用中性描述
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请回到应用内后重试')),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('悬浮窗启动失败，请重试')),
        );
      }
      return false;
    }
    _handedToFloat = true;
    _mpdTempFile = null; // 所有权移交原生服务（关闭时按语义删除/交回）
    if (mounted) Navigator.of(context).pop();
    return true;
  }

  bool _chapterHasPlayable(int from, int delta) {
    var i = from + delta;
    while (i >= 0 && i < _chapters.length) {
      if (!_chapters[i].isVolume) return true;
      i += delta;
    }
    return false;
  }

  /// 悬浮窗入口（对齐原版 menu_float_window → startFloatingWindow）：
  /// 在当前播放内容上转全局悬浮窗
  Future<void> _enterFloatWindow() async {
    if (_handedToFloat || _loadingChapter) return;
    final target = _currentFloatTarget();
    if (target == null) return;
    await _handOffToFloatWindow(target);
  }

  VideoPlayTarget? _currentFloatTarget() {
    final mpd = _mpdTempFile;
    if (mpd != null && _currentPlayUrl.isNotEmpty) {
      return VideoPlayTarget(
        url: _currentPlayUrl,
        headers: _videoHeaders,
        mpdFilePath: mpd.path,
      );
    }
    if (_currentPlayUrl.isEmpty) return null;
    return VideoPlayTarget(url: _currentPlayUrl, headers: _videoHeaders);
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
      // [V-B3] 悬浮窗回全屏时保持其播放态；否则沿用 autoPlay 设置
      final shouldPlay = _resumePlayingOverride ?? _playSettings.autoPlay;
      _resumePlayingOverride = null;
      if (shouldPlay) {
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
                  // [V-B3][W2] 悬浮窗入口（对齐原版 menu_float_window：视频页
                  // 菜单第一组 always 动作；解析出播放地址后可用）。
                  // 仅 Android 提供：桌面/Web 无全局悬浮窗概念，与 JS 入口
                  // 一致降级为全屏播放页。
                  if (VideoFloatWindowCoordinator.instance.isSupported)
                    VideoFloatWindowButton(
                      onPressed:
                          (_currentPlayUrl.isNotEmpty && !_loadingChapter)
                              ? () => unawaited(_enterFloatWindow())
                              : null,
                    ),
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
