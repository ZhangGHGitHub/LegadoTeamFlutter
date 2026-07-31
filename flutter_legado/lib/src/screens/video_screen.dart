import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// 视频播放页面
///
/// 参考 Kotlin 原版 [VideoPlayerActivity] 的设计思路：
/// - 接收视频 URL 和标题参数
/// - 支持播放/暂停、进度拖拽、时间显示
/// - 支持全屏切换（横屏模式）
/// - 加载中指示器与错误处理
class VideoScreen extends StatefulWidget {
  /// 视频播放地址
  final String videoUrl;

  /// 视频标题（显示在 AppBar）
  final String title;

  const VideoScreen({
    super.key,
    required this.videoUrl,
    this.title = '视频播放',
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

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  /// 初始化视频播放器
  void _initPlayer() {
    final uri = Uri.tryParse(widget.videoUrl);
    if (uri == null || widget.videoUrl.isEmpty) {
      // URL 无效时创建一个空控制器以触发错误状态
      _controller = VideoPlayerController.networkUrl(Uri.parse(''));
      _initializeVideoPlayerFuture = Future<void>.error(
        Exception('无效的视频地址'),
      );
      return;
    }

    _controller = VideoPlayerController.networkUrl(uri);
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
    _controller.dispose();
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
    return Scaffold(
      // 全屏模式下隐藏 AppBar
      appBar: _isFullScreen
          ? null
          : AppBar(
              title: Text(widget.title),
              actions: [
                // 全屏切换按钮
                IconButton(
                  icon: const Icon(Icons.fullscreen),
                  tooltip: '全屏',
                  onPressed: _toggleFullScreen,
                ),
              ],
            ),
      body: FutureBuilder<void>(
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
                      onPressed: () {
                        // 重新初始化播放器
                        _controller.dispose();
                        _initPlayer();
                        setState(() {});
                      },
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
            widget.videoUrl,
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
