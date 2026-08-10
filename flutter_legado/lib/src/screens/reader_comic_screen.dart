import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/error_view.dart';

/// 漫画阅读页面
///
/// 支持纵向连续滚动、双指缩放、前后图片预加载。
/// 通过 [bookUrl] 参数接收书籍标识，从 BookApi 获取章节与图片列表。
class ReaderComicScreen extends ConsumerStatefulWidget {
  /// 书籍 URL 标识
  final String bookUrl;

  const ReaderComicScreen({super.key, required this.bookUrl});

  @override
  ConsumerState<ReaderComicScreen> createState() => _ReaderComicScreenState();
}

class _ReaderComicScreenState extends ConsumerState<ReaderComicScreen> {
  /// 滚动控制器，用于纵向连续滚动
  final ScrollController _scrollController = ScrollController();

  /// 当前书籍（用于加载章节和图片）
  Book? _book;

  /// 章节列表
  List<BookChapter> _chapters = [];

  /// 当前章节索引
  int _currentChapterIndex = 0;

  /// 当前章节的图片 URL 列表
  List<String> _imageUrls = [];

  /// 加载状态
  bool _loading = true;

  /// 错误信息
  String? _error;

  /// 是否显示控制栏（顶部返回 + 底部进度条）
  bool _showControls = false;

  /// 已预加载的图片索引集合（避免重复预加载）
  final Set<int> _preloadedIndices = {};

  /// 图片加载失败的索引集合（用于显示重试按钮）
  final Set<int> _failedIndices = {};

  /// 书源防盗链 header（Referer/UA 等，对齐原版 glide getGlideUrl 带书源 headerMap）
  /// [UI-fix 2026-08-10 | Reasonix] 漫画 CDN 常校验 Referer，无 header 时 403
  Map<String, String> _imageHeaders = const {};

  /// 预加载缓存（前后各 2 页）
  static const int _preloadRange = 2;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_loadBook());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    // 退出前保存阅读进度
    unawaited(_saveProgress());
    super.dispose();
  }

  /// 加载书籍信息和章节列表
  Future<void> _loadBook() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = ref.read(bookApiProvider);
      // 获取书籍信息
      _book = await api.getBook(widget.bookUrl);
      if (_book == null) {
        setState(() {
          _error = '未找到书籍信息';
          _loading = false;
        });
        return;
      }

      // 获取章节列表
      _chapters = await api.getChapters(widget.bookUrl);
      if (_chapters.isEmpty) {
        setState(() {
          _error = '暂无章节';
          _loading = false;
        });
        return;
      }

      // 恢复上次阅读位置
      _currentChapterIndex = _book!.durChapterIndex;
      if (_currentChapterIndex >= _chapters.length) {
        _currentChapterIndex = 0;
      }

      // 加载当前章节的图片
      await _loadChapterImages();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 加载当前章节的图片 URL 列表
  Future<void> _loadChapterImages() async {
    if (_chapters.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _imageUrls = [];
      _preloadedIndices.clear();
      _failedIndices.clear();
    });

    try {
      final api = ref.read(bookApiProvider);
      final chapter = _chapters[_currentChapterIndex];

      // 书源防盗链 header（仅取一次；对齐原版 OkHttpStreamFetcher 带书源
      // headerMap 加载漫画图）— Reasonix
      if (_imageHeaders.isEmpty && _book != null && _book!.origin.isNotEmpty) {
        final sources = await api.getBookSources();
        for (final s in sources) {
          if (s.bookSourceUrl == _book!.origin && s.header != null && s.header!.isNotEmpty) {
            _imageHeaders = _parseHeaderMap(s.header!);
            break;
          }
        }
      }

      // 获取章节内容
      String content;
      if (chapter.url.isNotEmpty && _book != null) {
        // 在线章节：通过 fetchChapterContent 获取
        content = await api.fetchChapterContent(
          widget.bookUrl,
          chapter.url,
          _book!.origin,
        );
      } else {
        // 本地章节：通过 getChapterContent 获取
        content = await api.getChapterContent(
          widget.bookUrl,
          _currentChapterIndex,
        );
      }

      if (!mounted) return;

      // 解析图片 URL（支持多种格式）
      _imageUrls = _parseImageUrls(content);

      // 相对路径转绝对（对齐原版 BookHelp.flowImages：
      // NetworkUtils.getAbsoluteURL(bookChapter.url, src)）— Reasonix
      if (_imageUrls.any((u) => !u.startsWith('http'))) {
        _imageUrls = _imageUrls
            .map((u) => _resolveImageUrl(chapter.url, u))
            .toList();
      }

      // 如果章节有 imgUrl 字段，也作为图片源
      if (chapter.imgUrl != null && chapter.imgUrl!.isNotEmpty) {
        _imageUrls.insert(0, chapter.imgUrl!);
      }

      setState(() {
        _loading = false;
      });

      // 触发初始预加载
      _preloadVisibleImages();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 从章节内容中解析图片 URL 列表
  ///
  /// 支持以下格式：
  /// - 每行一个 URL
  /// - HTML img 标签
  /// - JSON 数组
  List<String> _parseImageUrls(String content) {
    if (content.isEmpty) return [];

    final urls = <String>[];

    // 尝试解析 HTML img 标签
    final imgRegex = RegExp(r'''<img[^>]+src=["']([^"']+)["']''', caseSensitive: false);
    for (final match in imgRegex.allMatches(content)) {
      final url = match.group(1);
      if (url != null && url.isNotEmpty) {
        urls.add(url);
      }
    }

    // 如果没有找到 img 标签，按行分割解析 URL
    if (urls.isEmpty) {
      final lines = content.split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        // 匹配常见的图片 URL 模式
        if (trimmed.startsWith('http') && _isImageUrl(trimmed)) {
          urls.add(trimmed);
        }
      }
    }

    return urls;
  }

  /// 判断 URL 是否为图片链接
  bool _isImageUrl(String url) {
    final lower = url.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.contains('/image') ||
        lower.contains('/img') ||
        lower.contains('/pic');
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

  /// 相对路径转绝对（以章节 URL 为 base，对齐原版 NetworkUtils.getAbsoluteURL）
  String _resolveImageUrl(String chapterUrl, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    final uri = Uri.tryParse(chapterUrl);
    if (uri == null) return url;
    final base = uri.scheme.isNotEmpty && uri.host.isNotEmpty
        ? '${uri.scheme}://${uri.host}'
        : chapterUrl;
    if (url.startsWith('/')) return '$base$url';
    // 相对当前目录：章节 URL 去掉最后一段
    final path = uri.path;
    final dir = path.substring(0, path.lastIndexOf('/') + 1);
    return '$base$dir$url';
  }

  /// 滚动监听，触发预加载
  void _onScroll() {
    _preloadVisibleImages();
  }

  /// 预加载当前可见区域前后的图片
  void _preloadVisibleImages() {
    if (_imageUrls.isEmpty || !mounted) return;

    // 计算当前可见的图片索引范围
    final viewportHeight = _scrollController.position.viewportDimension;
    final scrollOffset = _scrollController.offset;

    // 简单估算：假设每张图高度约为屏幕高度
    final screenHeight = MediaQuery.of(context).size.height;
    final firstVisible = (scrollOffset / screenHeight).floor().clamp(0, _imageUrls.length - 1);
    final lastVisible = ((scrollOffset + viewportHeight) / screenHeight).ceil().clamp(0, _imageUrls.length - 1);

    // 扩展预加载范围（前后各 2 页）
    final preloadStart = (firstVisible - _preloadRange).clamp(0, _imageUrls.length - 1);
    final preloadEnd = (lastVisible + _preloadRange).clamp(0, _imageUrls.length - 1);

    for (var i = preloadStart; i <= preloadEnd; i++) {
      if (!_preloadedIndices.contains(i)) {
        _preloadedIndices.add(i);
        // 使用 Image precache 进行预加载
        unawaited(
          precacheImage(CachedNetworkImageProvider(_imageUrls[i]), context).catchError((_) {
            // 预加载失败静默处理
          }),
        );
      }
    }
  }

  /// 切换到指定章节
  Future<void> _goToChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    await _saveProgress();
    _currentChapterIndex = index;
    // 滚动到顶部
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    await _loadChapterImages();
    await _saveProgress();
  }

  /// 切换到下一章
  Future<void> _nextChapter() async {
    if (_currentChapterIndex < _chapters.length - 1) {
      await _goToChapter(_currentChapterIndex + 1);
    }
  }

  /// 切换到上一章
  Future<void> _prevChapter() async {
    if (_currentChapterIndex > 0) {
      await _goToChapter(_currentChapterIndex - 1);
    }
  }

  /// 保存阅读进度
  Future<void> _saveProgress() async {
    try {
      final api = ref.read(bookApiProvider);
      await api.updateReadingProgress(
        bookUrl: widget.bookUrl,
        chapterIndex: _currentChapterIndex,
        chapterPos: 0,
      );
    } catch (_) {
      // 保存失败不阻断阅读流程
    }
  }

  /// 切换控制栏显示/隐藏
  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  /// 重试加载失败的图片
  void _retryImage(int index) {
    setState(() {
      _failedIndices.remove(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      // 退出时保存进度
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          unawaited(_saveProgress());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _toggleControls,
          child: Stack(
            children: [
              // 主内容区域
              _buildContent(),
              // 顶部控制栏
              if (_showControls) _buildTopBar(),
              // 底部进度条
              if (_showControls) _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建主内容区域
  Widget _buildContent() {
    if (_loading) {
      return const LoadingIndicator(message: '加载漫画中...');
    }

    if (_error != null) {
      return ErrorView(
        message: _error!,
        onRetry: _loadBook,
      );
    }

    if (_imageUrls.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            const Text('暂无图片', style: TextStyle(color: Colors.white54, fontSize: 16)),
            const SizedBox(height: 24),
            // 章节导航按钮
            if (_currentChapterIndex > 0)
              TextButton(
                onPressed: _prevChapter,
                child: const Text('上一章', style: TextStyle(color: Colors.white70)),
              ),
            if (_currentChapterIndex < _chapters.length - 1)
              TextButton(
                onPressed: _nextChapter,
                child: const Text('下一章', style: TextStyle(color: Colors.white70)),
              ),
          ],
        ),
      );
    }

    return _buildImageList();
  }

  /// 构建图片列表（纵向连续滚动 + 双指缩放）
  Widget _buildImageList() {
    return InteractiveViewer(
      minScale: 1.0,
      maxScale: 3.0,
      boundaryMargin: const EdgeInsets.all(0),
      child: ListView.builder(
        controller: _scrollController,
        itemCount: _imageUrls.length + 1, // +1 用于底部章节导航
        padding: EdgeInsets.zero,
        physics: const ClampingScrollPhysics(),
        itemBuilder: (context, index) {
          // 最后一项：章节导航
          if (index == _imageUrls.length) {
            return _buildChapterNavigation();
          }
          return _buildImageItem(index);
        },
      ),
    );
  }

  /// 构建单张图片项
  Widget _buildImageItem(int index) {
    final url = _imageUrls[index];
    final isFailed = _failedIndices.contains(index);

    if (isFailed) {
      // 图片加载失败，显示重试按钮
      return _buildImageErrorPlaceholder(index, url);
    }

    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: _imageHeaders, // 防盗链 header（对齐原版）— Reasonix
      fit: BoxFit.fitWidth,
      width: double.infinity,
      // 漫画页按屏宽全分辨率显示，不限制 memCacheWidth（磁盘缓存默认开启）
      progressIndicatorBuilder: (context, _, progress) =>
          _buildImageLoadingPlaceholder(progress.progress),
      errorWidget: (context, _, _) => _buildImageErrorPlaceholder(index, url),
      errorListener: (_) {
        // 标记为失败状态（供重建时显示重试按钮）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_failedIndices.contains(index)) {
            setState(() {
              _failedIndices.add(index);
            });
          }
        });
      },
    );
  }

  /// 图片加载占位符（骨架屏效果，[progress] 为下载进度 0.0~1.0）
  Widget _buildImageLoadingPlaceholder(double? progress) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 骨架屏动画效果
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.image,
                size: 64,
                color: Color(0xFF444444),
              ),
            ),
            const SizedBox(height: 16),
            // 进度条
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: const Color(0xFF2A2A2A),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF666666)),
              ),
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              Text(
                '${(progress * 100).toInt()}%',
                style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 图片加载失败占位符（显示重试按钮）
  Widget _buildImageErrorPlaceholder(int index, String url) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.4,
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image,
              size: 64,
              color: Color(0xFF666666),
            ),
            const SizedBox(height: 12),
            const Text(
              '图片加载失败',
              style: TextStyle(color: Color(0xFF888888), fontSize: 14),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _retryImage(index),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF444444),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 章节导航区域（显示在图片列表底部）
  Widget _buildChapterNavigation() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          // 当前章节标题
          if (_currentChapterIndex < _chapters.length)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _chapters[_currentChapterIndex].title,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
          // 导航按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 上一章
              if (_currentChapterIndex > 0)
                OutlinedButton.icon(
                  onPressed: _prevChapter,
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('上一章'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                ),
              const SizedBox(width: 24),
              // 下一章
              if (_currentChapterIndex < _chapters.length - 1)
                OutlinedButton.icon(
                  onPressed: _nextChapter,
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: const Text('下一章'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                ),
            ],
          ),
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
                // 书名
                Expanded(
                  child: Text(
                    _book?.name ?? '漫画阅读',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // 章节标题
                if (_currentChapterIndex < _chapters.length)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      _chapters[_currentChapterIndex].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
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
    final hasPrev = _currentChapterIndex > 0;
    final hasNext = _currentChapterIndex < _chapters.length - 1;

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
                // 图片进度（当前页/总页数）
                Row(
                  children: [
                    // 上一章按钮
                    IconButton(
                      icon: const Icon(Icons.skip_previous, color: Colors.white),
                      onPressed: hasPrev ? _prevChapter : null,
                    ),
                    // 章节进度滑块
                    Expanded(
                      child: Slider(
                        value: _chapters.isNotEmpty
                            ? _currentChapterIndex.toDouble()
                            : 0,
                        min: 0,
                        max: _chapters.length > 1
                            ? (_chapters.length - 1).toDouble()
                            : 1,
                        divisions: _chapters.length > 1
                            ? _chapters.length - 1
                            : null,
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                        onChanged: (value) {
                          unawaited(_goToChapter(value.toInt()));
                        },
                      ),
                    ),
                    // 下一章按钮
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      onPressed: hasNext ? _nextChapter : null,
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
                        '第 ${_currentChapterIndex + 1} / ${_chapters.length} 章',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      if (_imageUrls.isNotEmpty) ...[
                        const SizedBox(width: 16),
                        Text(
                          '${_imageUrls.length} 页',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
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
