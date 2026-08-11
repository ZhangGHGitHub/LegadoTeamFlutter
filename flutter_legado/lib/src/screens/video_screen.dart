import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../utils/url_utils.dart';

/// 视频播放页面
///
/// 参考 Kotlin 原版 [VideoPlayerActivity] 的设计思路：
/// - 接收视频 URL 和标题参数
/// - 支持播放/暂停、进度拖拽、时间显示
/// - 支持全屏切换（横屏模式）
/// - 加载中指示器与错误处理
/// - [UI-fix v2.0.12 | 2026-08-10] 视频源（bookSourceType=4）书籍支持：
///   传入 [book] 时按原版 VideoPlayerActivity 语义加载章节列表，取当前章
///   正文（视频链接）播放，支持上一集/下一集切换 — Reasonix
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
  /// 章节列表（book 模式）
  List<BookChapter> _chapters = const [];

  /// 当前章节索引（book 模式）
  int _chapterIndex = 0;

  /// 章节正文加载中
  bool _loadingChapter = false;

  /// 章节加载/切换错误信息（book 模式）
  String? _chapterError;

  /// 书源防盗链 header（Referer/UA 等，对齐原版 VideoPlay player.mapHeadData）
  /// [UI-fix 2026-08-10 | Reasonix] 视频 CDN 常校验 Referer，无 header 时 403
  Map<String, String> _videoHeaders = const {};

  /// 当前实际播放地址（book 模式来自章节正文；直链模式为 widget.videoUrl）
  /// — Reasonix + UI
  String _currentPlayUrl = '';

  @override
  void initState() {
    super.initState();
    if (widget.book != null) {
      // 首帧即 loading，避免访问尚未初始化的 late _controller / Future
      _loadingChapter = true;
      _loadBookVideo();
    } else {
      _currentPlayUrl = widget.videoUrl;
      _initPlayer(widget.videoUrl);
    }
  }

  /// 视频源书籍：加载章节列表并播放当前章（对齐原版 VideoPlayerActivity）
  Future<void> _loadBookVideo() async {
    final book = widget.book!;
    setState(() => _loadingChapter = true);
    try {
      final api = ProviderScope.containerOf(context).read(bookApiProvider);
      // 书源防盗链 header（仅取一次）— Reasonix
      if (_videoHeaders.isEmpty && book.origin.isNotEmpty) {
        try {
          final sources = await api.getBookSources();
          for (final s in sources) {
            if (s.bookSourceUrl == book.origin &&
                s.header != null &&
                s.header!.isNotEmpty) {
              _videoHeaders = _parseHeaderMap(s.header!);
              break;
            }
          }
        } catch (_) {}
      }
      // 对齐文本/漫画阅读器：本地无目录的在线书自动 refreshToc
      // （搜索进详情未落库章节时否则永远「暂无章节」）— Reasonix + UI
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
      var index = book.durChapterIndex;
      if (index >= _chapters.length) index = 0;
      _chapterIndex = index;
      await _playChapter(index);
    } catch (e) {
      setState(() {
        _loadingChapter = false;
        _chapterError = '$e';
      });
    }
  }

  /// 播放指定章节：取章节正文（视频链接）后初始化播放器
  Future<void> _playChapter(int index) async {
    final book = widget.book!;
    final chapter = _chapters[index];
    setState(() {
      _loadingChapter = true;
      _chapterError = null;
    });
    try {
      final api = ProviderScope.containerOf(context).read(bookApiProvider);
      // 视频源章节正文为播放链接（Rust is_media 分支不做 HTML 格式化，
      // 对齐原版 BookContent「音频和视频获取的是链接」语义）
      final content = book.origin.isNotEmpty
          ? await api.fetchChapterContent(
              book.bookUrl, chapter.url, book.origin)
          : await api.getChapterContent(book.bookUrl, index);
      final extracted = _extractVideoUrl(content);
      // 相对路径以章节 URL 为 base 绝对化（对齐原版 NetworkUtils.getAbsoluteURL）
      // — Reasonix + UI
      final url = resolveAbsoluteUrl(chapter.url, extracted);
      if (url.isEmpty) {
        setState(() {
          _loadingChapter = false;
          _chapterError = '章节未解析出视频地址';
        });
        return;
      }
      // [UI-fix v2.0.12] 首次播放前 _controller 可能未初始化（异步加载中），
      // 防御性释放（快速退出/加载失败场景）— Reasonix
      try {
        _controller.dispose();
      } catch (_) {}
      _currentPlayUrl = url;
      _initPlayer(url);
      setState(() {
        _loadingChapter = false;
        _chapterIndex = index;
      });
      // 章节切换后写回进度（durChapterIndex；pos 在播放中/退出再更新）
      unawaited(_saveProgress(chapterPos: 0));
    } catch (e) {
      setState(() {
        _loadingChapter = false;
        _chapterError = '$e';
      });
    }
  }

  /// 从章节正文提取视频链接
  ///
  /// 支持：纯 URL、`<iframe src=...>`、`<video src=...>`、`source src=...`；
  /// 兜底取首个 `https?://` URL（对齐原版 VideoPlay 正文即播放地址语义）
  /// [UI-fix 2026-08-10 | Reasonix] 视频源 ruleContent 常返回播放器页 HTML
  String _extractVideoUrl(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return '';
    // 优先提取 iframe/video/source 标签的 src（播放器页 HTML 场景）
    for (final tag in ['iframe', 'video', 'source', 'embed']) {
      final tagM = RegExp('<$tag[^>]+src=["\']([^"\'>]+)["\']', caseSensitive: false)
          .firstMatch(trimmed);
      if (tagM != null) {
        final tagUrl = tagM.group(1)!.trim();
        if (tagUrl.isNotEmpty) {
          return tagUrl;
        }
      }
    }
    final m = RegExp(r'https?://\S+').firstMatch(trimmed);
    if (m == null) return trimmed;
    return m.group(0)!.trim().replaceAll(RegExp(r'[)\]}>"\x27]+$'), '');
  }

  /// 解析书源 header 字符串（JSON 或 key: value 行）— Reasonix
  Map<String, String> _parseHeaderMap(String header) {
    final trimmed = header.trim();
    if (trimmed.isEmpty) return const {};
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          return decoded.map((k, v) => MapEntry(k, v.toString()));
        }
      } catch (_) {
        // JSON 解析失败走行解析
      }
    }
    final map = <String, String>{};
    for (final line in trimmed.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
      }
    }
    return map;
  }

  /// 切换上一集/下一集
  void _switchChapter(int delta) {
    if (widget.book == null) return;
    final next = _chapterIndex + delta;
    if (next < 0 || next >= _chapters.length) return;
    _playChapter(next);
  }

  /// 写回阅读进度（durChapterIndex / durChapterPos）— Reasonix + UI
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
    } catch (_) {
      // 进度写回失败不阻断播放
    }
  }

  /// 错误态「重试」：book 模式重试当前章（勿用空 widget.videoUrl）；
  /// 尚无章节列表时重新拉目录。直链模式重试当前播放 URL。— Reasonix + UI
  void _retryPlayback() {
    if (widget.book != null) {
      if (_chapters.isEmpty) {
        unawaited(_loadBookVideo());
      } else {
        unawaited(_playChapter(_chapterIndex));
      }
      return;
    }
    try {
      _controller.dispose();
    } catch (_) {}
    _initPlayer(_currentPlayUrl.isNotEmpty ? _currentPlayUrl : widget.videoUrl);
    setState(() {});
  }

  /// 初始化视频播放器
  void _initPlayer([String? url]) {
    final videoUrl = url ??
        (_currentPlayUrl.isNotEmpty ? _currentPlayUrl : widget.videoUrl);
    if (url != null) _currentPlayUrl = url;
    final uri = Uri.tryParse(videoUrl);
    if (uri == null || videoUrl.isEmpty) {
      // URL 无效时创建一个空控制器以触发错误状态
      _controller = VideoPlayerController.networkUrl(Uri.parse(''));
      _initializeVideoPlayerFuture = Future<void>.error(
        Exception('无效的视频地址'),
      );
      return;
    }

    _controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: _videoHeaders, // 防盗链 header（对齐原版 AnalyzeUrl.headerMap）— Reasonix
    );
    _initializeVideoPlayerFuture = _controller.initialize().then((_) {
      // 初始化成功后自动开始播放
      if (mounted) {
        setState(() {});
        _controller.play();
      }
    });
  }

  @override
  void dispose() {
    // 退出全屏时恢复系统 UI
    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    // [UI-fix v2.0.12] book 模式异步加载中退出时 _controller 未初始化，
    // 防御性释放 — Reasonix
    try {
      _controller.dispose();
    } catch (_) {}
    super.dispose();
  }

  /// 切换全屏模式
  ///
  /// 参考 Kotlin 版 [toggleFullScreen]：
  /// - 全屏时隐藏系统栏，切换横屏方向
  /// - 退出全屏时恢复竖屏方向，显示系统栏
  void _toggleFullScreen() {
    setState(() {
      _isFullScreen = !_isFullScreen;
    });

    if (_isFullScreen) {
      // 进入全屏：隐藏系统 UI，锁定横屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // 退出全屏：恢复系统 UI，恢复竖屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 格式化时长为 mm:ss 或 hh:mm:ss
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
    // 退出前写回播放进度（dispose 时 Provider 可能已不可用）— Reasonix + UI
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && widget.book != null) {
          unawaited(_saveProgress());
        }
      },
      child: Scaffold(
      // 全屏模式下隐藏 AppBar
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
                // 视频源书：上一集/下一集切换（对齐原版 VideoPlayerActivity）
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
                // 全屏切换按钮
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
          // 加载中状态
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

          // 错误状态（URL 无效或网络错误）
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
                      style: Theme.of(context).textTheme.titleMedium,
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

          // 正常播放状态
          return _buildPlayerView();
        },
      ),
    ),
    );
  }

  /// 构建播放器视图
  ///
  /// 布局结构：
  /// - 视频画面区域（16:9 比例）
  /// - 控制栏（播放/暂停、进度条、时间、全屏按钮）
  Widget _buildPlayerView() {
    return Column(
      children: [
        // 视频画面区域
        _buildVideoArea(),
        // 控制栏（全屏或竖屏均显示）
        _buildControlBar(),
        // 非全屏时显示视频信息
        if (!_isFullScreen) _buildVideoInfo(),
      ],
    );
  }

  /// 视频画面区域，保持 16:9 比例
  Widget _buildVideoArea() {
    final aspectRatio = _controller.value.isInitialized
        ? _controller.value.aspectRatio
        : 16 / 9;

    return AspectRatio(
      aspectRatio: aspectRatio,
      child: GestureDetector(
        // 单击切换控制栏显示
        onTap: () => setState(() => _showControls = !_showControls),
        // 双击切换播放/暂停
        onDoubleTap: () {
          setState(() {
            _controller.value.isPlaying ? _controller.pause() : _controller.play();
          });
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 视频画面
            VideoPlayer(_controller),
            // 控制覆盖层
            if (_showControls) _buildOverlayControls(),
          ],
        ),
      ),
    );
  }

  /// 覆盖在视频上的控制层
  ///
  /// 包含中央播放/暂停按钮和渐变背景
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
              _controller.value.isPlaying ? _controller.pause() : _controller.play();
            });
          },
        ),
      ),
    );
  }

  /// 底部控制栏：播放/暂停 + 进度条 + 时间 + 全屏
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
              // 进度条
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
                      milliseconds:
                          (duration.inMilliseconds * v).round(),
                    );
                    _controller.seekTo(newPosition);
                  },
                ),
              ),
              // 时间 + 控制按钮
              Row(
                children: [
                  // 播放/暂停按钮
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
                  // 当前时间
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
                  // 总时长
                  Text(
                    _formatDuration(duration),
                    style: TextStyle(
                      fontSize: 12,
                      color: _isFullScreen ? Colors.white70 : null,
                    ),
                  ),
                  const Spacer(),
                  // 全屏切换按钮
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

  /// 视频信息区域（非全屏时显示）
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
