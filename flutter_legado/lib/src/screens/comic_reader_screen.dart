import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 漫画分页模式
enum ComicPageMode {
  /// 单页模式（竖屏默认）
  singlePage,

  /// 双页模式（横屏默认）
  doublePage,
}

/// 漫画翻页动画类型
enum ComicPageAnimation {
  /// 滑动翻页（平滑过渡）
  slide,

  /// 仿真翻页（纸张翻转效果）
  simulate,
}

/// 漫画翻页动画配置
class ComicAnimationConfig {
  /// 动画时长
  final Duration duration;

  /// 动画曲线
  final Curve curve;

  /// 翻页速度阈值（像素/秒）
  final double velocityThreshold;

  const ComicAnimationConfig({
    this.duration = const Duration(milliseconds: 300),
    this.curve = Curves.easeInOut,
    this.velocityThreshold = 300.0,
  });
}

/// 漫画页面视图 Widget
///
/// 支持单页/双页模式切换、翻页动画、双指缩放、长按保存等高级手势。
/// 移植自 Kotlin ComicPageView.kt 的核心功能。
class ComicPageView extends StatefulWidget {
  /// 图片 URL 列表
  final List<String> imageUrls;

  /// 初始页索引
  final int initialPage;

  /// 分页模式
  final ComicPageMode pageMode;

  /// 翻页动画类型
  final ComicPageAnimation animationType;

  /// 动画配置
  final ComicAnimationConfig animationConfig;

  /// 页面切换回调
  final ValueChanged<int>? onPageChanged;

  /// 长按保存图片回调
  final ValueChanged<String>? onLongPressSave;

  /// 模式切换回调
  final ValueChanged<ComicPageMode>? onModeChanged;

  /// 是否自动根据屏幕方向切换模式
  final bool autoSwitchMode;

  const ComicPageView({
    super.key,
    required this.imageUrls,
    this.initialPage = 0,
    this.pageMode = ComicPageMode.singlePage,
    this.animationType = ComicPageAnimation.slide,
    this.animationConfig = const ComicAnimationConfig(),
    this.onPageChanged,
    this.onLongPressSave,
    this.onModeChanged,
    this.autoSwitchMode = true,
  });

  @override
  State<ComicPageView> createState() => ComicPageViewState();
}

/// ComicPageView 的状态类（公开以便测试访问）
class ComicPageViewState extends State<ComicPageView>
    with TickerProviderStateMixin {
  /// 页面控制器
  late PageController _pageController;

  /// 当前页索引
  late int _currentPage;

  /// 当前分页模式
  late ComicPageMode _pageMode;

  /// 当前缩放比例
  double _scale = 1.0;

  /// 缩放焦点（用于计算平移参考点）
  // ignore: unused_field
  Offset _focalPoint = Offset.zero;

  /// 平移偏移
  Offset _offset = Offset.zero;

  /// 是否正在缩放（用于状态判断）
  // ignore: unused_field
  bool _isScaling = false;

  /// 缩放范围限制
  static const double _minScale = 0.5;
  static const double _maxScale = 3.0;

  /// 双击缩放目标值
  static const double _doubleTapScale = 2.0;

  /// 预加载范围（前后各 2 页）
  static const int _preloadRange = 2;

  /// 已预加载的图片索引集合
  final Set<int> _preloadedIndices = {};

  /// 边缘点击区域宽度比例
  static const double _edgeTapRatio = 0.15;

  /// 动画控制器（仿真翻页用）
  late AnimationController _animController;

  /// 仿真翻页动画值
  double _flipProgress = 0.0;

  /// 翻页方向（+1 下一页, -1 上一页）
  int _flipDirection = 0;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _pageMode = widget.pageMode;
    _pageController = PageController(initialPage: _currentPage);
    _animController = AnimationController(
      vsync: this,
      duration: widget.animationConfig.duration,
    );
    _animController.addListener(() {
      setState(() {
        _flipProgress = _animController.value;
      });
    });
    _animController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _onFlipAnimationComplete();
      }
    });
    // 初始预加载
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadImages();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 根据屏幕方向自动切换模式
    if (widget.autoSwitchMode) {
      final orientation = MediaQuery.of(context).orientation;
      final newMode = orientation == Orientation.landscape
          ? ComicPageMode.doublePage
          : ComicPageMode.singlePage;
      if (newMode != _pageMode) {
        _pageMode = newMode;
        // 使用 addPostFrameCallback 避免在 build 期间调用回调
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onModeChanged?.call(_pageMode);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _animController.dispose();
    super.dispose();
  }

  /// 获取当前页索引
  int get currentPage => _currentPage;

  /// 获取当前分页模式
  ComicPageMode get pageMode => _pageMode;

  /// 获取当前缩放比例
  double get scale => _scale;

  /// 切换分页模式
  void setPageMode(ComicPageMode mode) {
    if (_pageMode != mode) {
      setState(() {
        _pageMode = mode;
      });
      widget.onModeChanged?.call(mode);
    }
  }

  /// 跳转到指定页
  void goToPage(int page, {bool animate = true}) {
    if (page < 0 || page >= widget.imageUrls.length) return;
    if (animate) {
      _pageController.animateToPage(
        page,
        duration: widget.animationConfig.duration,
        curve: widget.animationConfig.curve,
      );
    } else {
      _pageController.jumpToPage(page);
    }
  }

  /// 翻到下一页
  void nextPage() {
    final step = _pageMode == ComicPageMode.doublePage ? 2 : 1;
    final target = _currentPage + step;
    if (target < widget.imageUrls.length) {
      goToPage(target);
    }
  }

  /// 翻到上一页
  void prevPage() {
    final step = _pageMode == ComicPageMode.doublePage ? 2 : 1;
    final target = _currentPage - step;
    if (target >= 0) {
      goToPage(target);
    }
  }

  /// 重置缩放
  void resetZoom() {
    setState(() {
      _scale = 1.0;
      _offset = Offset.zero;
    });
  }

  /// 页面切换处理
  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
    });
    widget.onPageChanged?.call(page);
    _preloadImages();
    // 翻页时重置缩放
    resetZoom();
  }

  /// 预加载前后各 2 页图片
  void _preloadImages() {
    if (widget.imageUrls.isEmpty || !mounted) return;

    final start = (_currentPage - _preloadRange).clamp(0, widget.imageUrls.length - 1);
    final end = (_currentPage + _preloadRange).clamp(0, widget.imageUrls.length - 1);

    for (var i = start; i <= end; i++) {
      if (!_preloadedIndices.contains(i) && mounted) {
        _preloadedIndices.add(i);
        // 使用 try-catch 包裹，避免测试环境中的异常
        try {
          unawaited(
            precacheImage(CachedNetworkImageProvider(widget.imageUrls[i]), context).catchError((_) {
              // 预加载失败静默处理
            }),
          );
        } catch (_) {
          // 忽略预加载异常（如 widget 已销毁）
        }
      }
    }
  }

  /// 仿真翻页动画完成回调
  void _onFlipAnimationComplete() {
    if (_flipDirection != 0) {
      final target = _currentPage + _flipDirection;
      if (target >= 0 && target < widget.imageUrls.length) {
        _pageController.jumpToPage(target);
      }
    }
    setState(() {
      _flipProgress = 0.0;
      _flipDirection = 0;
    });
  }

  /// 触发仿真翻页动画
  void _startFlipAnimation(int direction) {
    if (_animController.isAnimating) return;
    final target = _currentPage + direction;
    if (target < 0 || target >= widget.imageUrls.length) return;

    setState(() {
      _flipDirection = direction;
    });
    _animController.forward(from: 0.0);
  }

  // ===== 手势处理 =====

  /// 处理双指缩放手势
  void _onScaleStart(ScaleStartDetails details) {
    setState(() {
      _isScaling = true;
      _focalPoint = details.localFocalPoint;
    });
  }

  /// 缩放更新
  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      // 更新缩放比例（限制范围 0.5x - 3.0x）
      final newScale = (_scale * details.scale).clamp(_minScale, _maxScale);
      _scale = newScale;
      _focalPoint = details.localFocalPoint;

      // 缩放后支持平移
      if (_scale > 1.0) {
        _offset += details.focalPointDelta;
        _clampOffset();
      }
    });
  }

  /// 缩放结束
  void _onScaleEnd(ScaleEndDetails details) {
    setState(() {
      _isScaling = false;
      // 缩放小于 1 时恢复原始大小
      if (_scale < 1.0) {
        _scale = 1.0;
        _offset = Offset.zero;
      }
    });
  }

  /// 限制平移范围
  void _clampOffset() {
    final size = context.size ?? Size.zero;
    final maxX = (size.width * (_scale - 1)) / 2;
    final maxY = (size.height * (_scale - 1)) / 2;
    _offset = Offset(
      _offset.dx.clamp(-maxX, maxX),
      _offset.dy.clamp(-maxY, maxY),
    );
  }

  /// 处理双击手势（切换缩放 1.0x ↔ 2.0x）
  void _onDoubleTap() {
    setState(() {
      if (_scale == 1.0) {
        _scale = _doubleTapScale;
      } else {
        _scale = 1.0;
        _offset = Offset.zero;
      }
    });
  }

  /// 处理长按手势（保存当前页图片）
  void _onLongPress() {
    if (_currentPage < widget.imageUrls.length) {
      final url = widget.imageUrls[_currentPage];
      widget.onLongPressSave?.call(url);
      // 显示保存提示
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('正在保存图片...'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  /// 处理点击手势（边缘点击翻页）
  void _onTapUp(TapUpDetails details) {
    // 缩放状态下不处理边缘翻页
    if (_scale > 1.0) return;

    final size = context.size ?? Size.zero;
    final x = details.localPosition.dx;
    final edgeWidth = size.width * _edgeTapRatio;

    if (x < edgeWidth) {
      // 左边缘点击 → 上一页
      _handleEdgeTap(-1);
    } else if (x > size.width - edgeWidth) {
      // 右边缘点击 → 下一页
      _handleEdgeTap(1);
    }
  }

  /// 处理边缘点击翻页
  void _handleEdgeTap(int direction) {
    if (widget.animationType == ComicPageAnimation.simulate) {
      _startFlipAnimation(direction);
    } else {
      if (direction > 0) {
        nextPage();
      } else {
        prevPage();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          onDoubleTap: _onDoubleTap,
          onLongPress: _onLongPress,
          onTapUp: _onTapUp,
          child: ClipRect(
            child: Transform(
              transform: Matrix4.identity()
                ..translateByDouble(_offset.dx, _offset.dy, 0.0, 0.0)
                ..scaleByDouble(_scale, _scale, 1.0, 1.0),
              child: _buildPageContent(constraints),
            ),
          ),
        );
      },
    );
  }

  /// 构建页面内容
  Widget _buildPageContent(BoxConstraints constraints) {
    if (widget.animationType == ComicPageAnimation.simulate) {
      return _buildSimulatePageView(constraints);
    }
    return _buildSlidePageView(constraints);
  }

  /// 构建滑动翻页视图
  Widget _buildSlidePageView(BoxConstraints constraints) {
    if (_pageMode == ComicPageMode.doublePage) {
      return _buildDoublePageView(constraints);
    }
    return _buildSinglePageView(constraints);
  }

  /// 构建单页视图
  Widget _buildSinglePageView(BoxConstraints constraints) {
    return PageView.builder(
      controller: _pageController,
      itemCount: widget.imageUrls.length,
      onPageChanged: _onPageChanged,
      physics: const ClampingScrollPhysics(),
      itemBuilder: (context, index) {
        return _buildImagePage(index, constraints);
      },
    );
  }

  /// 构建双页视图（横屏模式）
  Widget _buildDoublePageView(BoxConstraints constraints) {
    // 双页模式：每页显示两张图片
    final pageCount = (widget.imageUrls.length / 2).ceil();
    return PageView.builder(
      controller: _pageController,
      itemCount: pageCount,
      onPageChanged: (page) => _onPageChanged(page * 2),
      physics: const ClampingScrollPhysics(),
      itemBuilder: (context, index) {
        final leftIndex = index * 2;
        final rightIndex = leftIndex + 1;
        return Row(
          children: [
            // 左页
            Expanded(
              child: _buildImagePage(leftIndex, constraints),
            ),
            // 分隔线
            Container(width: 1, color: Colors.white12),
            // 右页
            Expanded(
              child: rightIndex < widget.imageUrls.length
                  ? _buildImagePage(rightIndex, constraints)
                  : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }

  /// 构建仿真翻页视图
  Widget _buildSimulatePageView(BoxConstraints constraints) {
    return Stack(
      children: [
        // 当前页
        _buildImagePage(_currentPage, constraints),
        // 翻页动画层
        if (_flipProgress > 0 && _flipDirection != 0)
          _buildFlipOverlay(constraints),
      ],
    );
  }

  /// 构建翻页动画覆盖层
  Widget _buildFlipOverlay(BoxConstraints constraints) {
    final targetPage = _currentPage + _flipDirection;
    if (targetPage < 0 || targetPage >= widget.imageUrls.length) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        // 计算翻页角度（0 → 90 度）
        final angle = _flipProgress * math.pi / 2;
        // 根据方向确定翻转轴
        final alignment = _flipDirection > 0
            ? Alignment.centerLeft
            : Alignment.centerRight;

        return Transform(
          alignment: alignment,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(_flipDirection > 0 ? -angle : angle),
          child: Opacity(
            opacity: 1.0 - _flipProgress * 0.3,
            child: _buildImagePage(targetPage, constraints),
          ),
        );
      },
    );
  }

  /// 构建单张图片页面
  Widget _buildImagePage(int index, BoxConstraints constraints) {
    if (index < 0 || index >= widget.imageUrls.length) {
      return const SizedBox.shrink();
    }

    final url = widget.imageUrls[index];

    return Container(
      color: Colors.black,
      child: Center(
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.contain,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          // 漫画页需保留全分辨率供缩放，不限制 memCacheWidth（磁盘缓存默认开启）
          progressIndicatorBuilder: (context, _, progress) =>
              _buildLoadingPlaceholder(progress.progress),
          errorWidget: (context, _, _) => _buildErrorPlaceholder(index),
        ),
      ),
    );
  }

  /// 图片加载占位符（[value] 为下载进度 0.0~1.0，null 表示不确定）
  Widget _buildLoadingPlaceholder(double? value) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image, size: 64, color: Color(0xFF444444)),
          const SizedBox(height: 16),
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(
              value: value,
              backgroundColor: const Color(0xFF2A2A2A),
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF666666)),
            ),
          ),
        ],
      ),
    );
  }

  /// 图片加载失败占位符
  Widget _buildErrorPlaceholder(int index) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image, size: 64, color: Color(0xFF666666)),
          const SizedBox(height: 12),
          Text(
            '第 ${index + 1} 页加载失败',
            style: const TextStyle(color: Color(0xFF888888), fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// 漫画阅读器屏幕
///
/// 集成 ComicPageView 和顶部/底部控制栏。
/// 支持单页/双页模式切换按钮。
class ComicReaderScreen extends StatefulWidget {
  /// 书籍 URL 标识
  final String bookUrl;

  /// 图片 URL 列表（外部传入）
  final List<String> imageUrls;

  /// 初始页索引
  final int initialPage;

  /// 书籍标题
  final String title;

  /// 章节标题
  final String chapterTitle;

  const ComicReaderScreen({
    super.key,
    required this.bookUrl,
    required this.imageUrls,
    this.initialPage = 0,
    this.title = '漫画阅读',
    this.chapterTitle = '',
  });

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen> {
  /// 页面视图 Key（用于访问状态）
  final GlobalKey<ComicPageViewState> _pageViewKey = GlobalKey();

  /// 是否显示控制栏
  bool _showControls = false;

  /// 当前分页模式
  ComicPageMode _pageMode = ComicPageMode.singlePage;

  /// 当前页索引
  int _currentPage = 0;

  /// 翻页动画类型
  ComicPageAnimation _animationType = ComicPageAnimation.slide;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
  }

  /// 切换控制栏显示/隐藏
  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  /// 切换分页模式
  void _togglePageMode() {
    final newMode = _pageMode == ComicPageMode.singlePage
        ? ComicPageMode.doublePage
        : ComicPageMode.singlePage;
    setState(() {
      _pageMode = newMode;
    });
    _pageViewKey.currentState?.setPageMode(newMode);
  }

  /// 切换翻页动画类型
  void _toggleAnimationType() {
    setState(() {
      _animationType = _animationType == ComicPageAnimation.slide
          ? ComicPageAnimation.simulate
          : ComicPageAnimation.slide;
    });
  }

  /// 长按保存图片处理
  void _handleLongPressSave(String url) {
    // 实际保存逻辑由外部实现
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 主内容区域
          GestureDetector(
            onTap: _toggleControls,
            child: ComicPageView(
              key: _pageViewKey,
              imageUrls: widget.imageUrls,
              initialPage: widget.initialPage,
              pageMode: _pageMode,
              animationType: _animationType,
              onPageChanged: (page) {
                setState(() {
                  _currentPage = page;
                });
              },
              onLongPressSave: _handleLongPressSave,
              onModeChanged: (mode) {
                setState(() {
                  _pageMode = mode;
                });
              },
            ),
          ),
          // 顶部控制栏
          if (_showControls) _buildTopBar(),
          // 底部进度条
          if (_showControls) _buildBottomBar(),
        ],
      ),
    );
  }

  /// 构建顶部控制栏
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: const Color(0xCC000000),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                // 返回按钮
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                // 标题
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (widget.chapterTitle.isNotEmpty)
                        Text(
                          widget.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                // 模式切换按钮
                IconButton(
                  icon: Icon(
                    _pageMode == ComicPageMode.singlePage
                        ? Icons.view_column
                        : Icons.view_day,
                    color: Colors.white,
                  ),
                  tooltip: _pageMode == ComicPageMode.singlePage
                      ? '切换到双页模式'
                      : '切换到单页模式',
                  onPressed: _togglePageMode,
                ),
                // 动画类型切换按钮
                IconButton(
                  icon: Icon(
                    _animationType == ComicPageAnimation.slide
                        ? Icons.swipe
                        : Icons.auto_stories,
                    color: Colors.white,
                  ),
                  tooltip: _animationType == ComicPageAnimation.slide
                      ? '切换到仿真翻页'
                      : '切换到滑动翻页',
                  onPressed: _toggleAnimationType,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建底部进度条
  Widget _buildBottomBar() {
    final totalPages = widget.imageUrls.length;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        color: const Color(0xCC000000),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 页面进度滑块
                Row(
                  children: [
                    // 上一页按钮
                    IconButton(
                      icon: const Icon(Icons.chevron_left, color: Colors.white),
                      onPressed: _currentPage > 0
                          ? () => _pageViewKey.currentState?.prevPage()
                          : null,
                    ),
                    // 进度滑块
                    Expanded(
                      child: Slider(
                        value: _currentPage.toDouble(),
                        min: 0,
                        max: totalPages > 1 ? (totalPages - 1).toDouble() : 1,
                        divisions: totalPages > 1 ? totalPages - 1 : null,
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                        onChanged: (value) {
                          _pageViewKey.currentState?.goToPage(value.toInt());
                        },
                      ),
                    ),
                    // 下一页按钮
                    IconButton(
                      icon: const Icon(Icons.chevron_right, color: Colors.white),
                      onPressed: _currentPage < totalPages - 1
                          ? () => _pageViewKey.currentState?.nextPage()
                          : null,
                    ),
                  ],
                ),
                // 进度信息
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '第 ${_currentPage + 1} / $totalPages 页',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        _pageMode == ComicPageMode.singlePage ? '单页模式' : '双页模式',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
