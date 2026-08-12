import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../utils/video_play_utils.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(_loadPlaySettings());
    // 直链模式不依赖 Riverpod，可在 initState 启动
    if (widget.book == null) {
      unawaited(_playDirectUrl(widget.videoUrl));
    } else {
      _loadingChapter = true;
    }
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
      await _playChapter(index);
    } catch (e) {
      setState(() {
        _loadingChapter = false;
        _chapterError = '$e';
      });
    }
  }

  /// 播放指定章节：正文 → [resolveVideoPlayTarget] → 播放器
  Future<void> _playChapter(int index) async {
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
      _controller.dispose();
    } catch (_) {}
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
    unawaited(_playDirectUrl(widget.videoUrl));
  }

  /// 初始化视频播放器（网络或本地 MPD 文件）
  void _initPlayer({String? networkUrl, String? filePath}) {
    if (filePath != null && filePath.isNotEmpty) {
      _controller = VideoPlayerController.file(File(filePath));
      _wireControllerInit();
      return;
    }

    final videoUrl = networkUrl ??
        (_currentPlayUrl.isNotEmpty ? _currentPlayUrl : widget.videoUrl);
    if (networkUrl != null) _currentPlayUrl = networkUrl;
    final uri = Uri.tryParse(videoUrl);
    if (uri == null || videoUrl.isEmpty) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(''));
      _initializeVideoPlayerFuture = Future<void>.error(
        Exception('无效的视频地址'),
      );
      return;
    }

    _controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: _videoHeaders,
    );
    _wireControllerInit();
  }

  /// 初始化后恢复进度并自动播放（对齐 VideoPlay.seekOnStart）
  void _wireControllerInit() {
    _initializeVideoPlayerFuture = _controller.initialize().then((_) async {
      if (!mounted) return;
      debugPrint(
        '[VideoPlay] controller ready '
        'size=${_controller.value.size} '
        'duration=${_controller.value.duration} '
        'url=$_currentPlayUrl',
      );
      final book = widget.book;
      if (book != null && book.durChapterPos > 0) {
        try {
          await _controller.seekTo(Duration(milliseconds: book.durChapterPos));
        } catch (_) {}
      }
      setState(() {});
      if (_playSettings.autoPlay) {
        await _controller.play();
      }
      if (!mounted) return;
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

  @override
  void dispose() {
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
        if (didPop && widget.book != null) {
          unawaited(_saveProgress());
        }
      },
      child: Scaffold(
        appBar: _isFullScreen
            ? null
            : AppBar(
                title: Text(
                  widget.book != null && _chapters.isNotEmpty
                      ? _chapters[_chapterIndex].title
                      : widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  if (widget.book != null && _chapters.isNotEmpty) ...[
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      tooltip: '上一集',
                      onPressed: _chapterIndex > 0
                          ? () => _switchChapter(-1)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      tooltip: '下一集',
                      onPressed: _chapterIndex < _chapters.length - 1
                          ? () => _switchChapter(1)
                          : null,
                    ),
                  ],
                  // P2-15：视频设置（对标原版 menu_config_settings → SettingsDialog）
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: '播放设置',
                    onPressed: () async {
                      final updated = await showVideoSettingsDialog(context);
                      if (updated != null && mounted) {
                        setState(() => _playSettings = updated);
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.fullscreen),
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
                      const Icon(Icons.error_outline,
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
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            : _loadingChapter
                ? const Center(child: CircularProgressIndicator())
                : FutureBuilder<void>(
                    future: _initializeVideoPlayerFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
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
                                  Icons.error_outline,
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
                                  icon: const Icon(Icons.refresh),
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
        child: GestureDetector(
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
              if (_showControls) _buildOverlayControls(),
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
            _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
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
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
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
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      _isFullScreen
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
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
