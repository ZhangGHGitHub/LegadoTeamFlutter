import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;
import '../services/bridge_http.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/book_api.dart';
import '../services/system_brightness.dart';
import '../utils/comic_image_utils.dart';
import '../utils/error_message.dart';
import '../utils/manga_epaper.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/error_view.dart';
import '../widgets/manga/manga_config_sheet.dart';

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

  /// 当前书源（含 imageDecode 规则；解码走 FFI fetchImageWithDecode）
  /// [UI-fix v2.0.19 | Reasonix] 对齐原版 ImageUtils.decodeImageStream：
  /// 漫画/图片站图片 bytes 经书源 imageDecode JS 解密后才可显示
  BookSource? _bookSource;

  /// 预加载缓存（前后各 2 页）
  static const int _preloadRange = 2;

  /// 漫画专用配置（对齐原版 PreferKey manga*）— GapAudit P0-3
  MangaColorFilterConfig _colorFilter = MangaColorFilterConfig();
  MangaFooterConfig _footerConfig = MangaFooterConfig();
  bool _enableEInk = false;
  bool _enableGray = false;
  int _eInkThreshold = 150;

  /// 页脚用「当前可见页」近似索引（滚动估算）
  int _visiblePageIndex = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_loadMangaConfig());
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

  /// 加载漫画配置（config 键对齐原版 PreferKey）
  Future<void> _loadMangaConfig() async {
    try {
      final api = ref.read(bookApiProvider);
      final filterRaw = await api.getConfig(MangaConfigKeys.colorFilter);
      final footerRaw = await api.getConfig(MangaConfigKeys.footerConfig);
      final eInk = await api.getConfig(MangaConfigKeys.enableEInk);
      final gray = await api.getConfig(MangaConfigKeys.enableGray);
      final thr = await api.getConfig(MangaConfigKeys.eInkThreshold);
      if (!mounted) return;
      setState(() {
        _colorFilter = MangaColorFilterConfig.fromStorage(filterRaw);
        _footerConfig = MangaFooterConfig.fromStorage(footerRaw);
        _enableEInk = eInk == 'true';
        _enableGray = gray == 'true';
        _eInkThreshold = int.tryParse(thr ?? '') ?? 150;
      });
      await _applyBrightness(_colorFilter.l);
    } catch (_) {}
  }

  Future<void> _persistColorFilter(MangaColorFilterConfig cfg) async {
    _colorFilter = MangaColorFilterConfig(
      r: cfg.r,
      g: cfg.g,
      b: cfg.b,
      a: cfg.a,
      l: cfg.l,
    );
    setState(() {});
    try {
      await ref.read(bookApiProvider).setConfig(
            MangaConfigKeys.colorFilter,
            _colorFilter.toStorage(),
          );
    } catch (_) {}
    await _applyBrightness(_colorFilter.l);
  }

  Future<void> _persistFooter(MangaFooterConfig cfg) async {
    _footerConfig = MangaFooterConfig.fromJson(cfg.toJson());
    setState(() {});
    try {
      await ref.read(bookApiProvider).setConfig(
            MangaConfigKeys.footerConfig,
            _footerConfig.toStorage(),
          );
    } catch (_) {}
  }

  Future<void> _persistEInk(bool enabled) async {
    setState(() {
      _enableEInk = enabled;
      if (enabled) _enableGray = false;
    });
    try {
      final api = ref.read(bookApiProvider);
      await api.setConfig(MangaConfigKeys.enableEInk, enabled ? 'true' : 'false');
      if (enabled) {
        await api.setConfig(MangaConfigKeys.enableGray, 'false');
      }
    } catch (_) {}
  }

  Future<void> _persistGray(bool enabled) async {
    setState(() {
      _enableGray = enabled;
      if (enabled) _enableEInk = false;
    });
    try {
      final api = ref.read(bookApiProvider);
      await api.setConfig(MangaConfigKeys.enableGray, enabled ? 'true' : 'false');
      if (enabled) {
        await api.setConfig(MangaConfigKeys.enableEInk, 'false');
      }
    } catch (_) {}
  }

  Future<void> _persistThreshold(int value) async {
    setState(() => _eInkThreshold = value.clamp(0, 255));
    try {
      await ref.read(bookApiProvider).setConfig(
            MangaConfigKeys.eInkThreshold,
            '$_eInkThreshold',
          );
    } catch (_) {}
  }

  Future<void> _applyBrightness(int l) async {
    if (l <= 0) return;
    try {
      if (await SystemBrightness.isSupported()) {
        await SystemBrightness.setBrightness((l / 255.0).clamp(0.0, 1.0));
      }
    } catch (_) {}
  }

  void _openMangaConfig() {
    MangaConfigSheet.show(
      context,
      colorFilter: _colorFilter,
      footer: _footerConfig,
      enableEInk: _enableEInk,
      enableGray: _enableGray,
      eInkThreshold: _eInkThreshold,
      onColorFilterChanged: (c) => unawaited(_persistColorFilter(c)),
      onFooterChanged: (c) => unawaited(_persistFooter(c)),
      onEnableEInkChanged: (v) => unawaited(_persistEInk(v)),
      onEnableGrayChanged: (v) => unawaited(_persistGray(v)),
      onEInkThresholdChanged: (v) => unawaited(_persistThreshold(v)),
    );
  }

  /// 图片渲染滤镜：灰度用 ColorFilter；电子纸走真像素二值化（见图片组件）
  ColorFilter? get _imageColorFilter {
    if (_enableEInk) return null;
    if (_enableGray) {
      return const ColorFilter.matrix(kMangaGrayscaleMatrix);
    }
    if (_colorFilter.isIdentity) return null;
    return ColorFilter.matrix(_colorFilter.toColorMatrix());
  }

  Widget _wrapImageFilter(Widget child) {
    final filter = _imageColorFilter;
    if (filter == null) return child;
    return ColorFiltered(colorFilter: filter, child: child);
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

      // 获取章节列表。对齐原版 / reader_notifier / toc_screen：
      // 本地库无目录的在线书（搜索进详情未落库章节、或 notShelf 临时书）
      // 须自动 refreshToc，否则漫画阅读器永远「暂无章节」无法进正文/图片。
      // 设备实测：51漫画 book.type=notShelf|image、chapters=0，Rust 侧
      // refresh_toc 可出 1 章+正文图，缺此回退则整链断裂。— Reasonix + UI
      _chapters = await api.getChapters(widget.bookUrl);
      if (_chapters.isEmpty &&
          _book != null &&
          _book!.origin.isNotEmpty &&
          !_book!.origin.startsWith(BookType.localTag) &&
          !_book!.origin.startsWith(BookType.webDavTag)) {
        _chapters = await api.refreshToc(widget.bookUrl, _book!.origin);
      }
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
        // BridgeError 无自定义 toString()，裸显会显示 "Instance of 'BridgeError'"
        _error = errorMessage(e);
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
      // headerMap 加载漫画图）+ 书源对象（imageDecode 规则判断）— Reasonix
      if ((_imageHeaders.isEmpty || _bookSource == null) &&
          _book != null &&
          _book!.origin.isNotEmpty) {
        final sources = await api.getBookSources();
        for (final s in sources) {
          if (s.bookSourceUrl == _book!.origin) {
            _bookSource = s;
            if (s.header != null && s.header!.isNotEmpty) {
              _imageHeaders = _parseHeaderMap(s.header!);
            }
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
        // BridgeError 无自定义 toString()，裸显会显示 "Instance of 'BridgeError'"
        _error = errorMessage(e);
        _loading = false;
      });
    }
  }

  /// 从章节内容中解析图片 URL 列表（复合 URL 对齐原版 HtmlFormatter）
  /// — Reasonix + UI
  List<String> _parseImageUrls(String content) => parseComicImageUrls(content);

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
    if (_imageUrls.isNotEmpty && _scrollController.hasClients) {
      final max = _scrollController.position.maxScrollExtent;
      if (max > 0) {
        final ratio = (_scrollController.offset / max).clamp(0.0, 1.0);
        final page = (ratio * (_imageUrls.length - 1)).round();
        if (page != _visiblePageIndex) {
          setState(() => _visiblePageIndex = page);
        }
      }
    }
    _preloadVisibleImages();
  }

  /// 预加载当前可见区域前后的图片。
  ///
  /// 有书源 / 复合 URL / imageDecode 时与正式渲染统一走 FFI
  /// `fetchImageWithDecode`（写入 [ComicImageDecodeCache]），禁止
  /// CachedNetworkImageProvider 旁路（会截断复合 URL 或忽略防盗链）。
  /// — Reasonix + UI
  void _preloadVisibleImages() {
    if (_imageUrls.isEmpty || !mounted) return;
    // 防御：loading 态 ListView 尚未构建时 ScrollController 未 attach，
    // 访问 position 抛断言（加载完成 build 后由 _onScroll 再次触发）
    if (!_scrollController.hasClients) return;

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

    final useFfi = _bookSource != null;
    for (var i = preloadStart; i <= preloadEnd; i++) {
      if (!_preloadedIndices.contains(i)) {
        _preloadedIndices.add(i);
        final url = _imageUrls[i];
        if (useFfi) {
          unawaited(_preloadViaFfi(url));
        } else if (isCompositeImageUrl(url)) {
          // 无书源却含复合 URL：无法直连预加载，跳过（正式渲染亦可能失败）
        } else {
          unawaited(
            precacheImage(CachedNetworkImageProvider(url), context)
                .catchError((_) {}),
          );
        }
      }
    }
  }

  /// FFI 预加载：与 [_DecodedComicImage] 共用缓存 — Reasonix + UI
  Future<void> _preloadViaFfi(String url) async {
    final source = _bookSource;
    final book = _book;
    if (source == null || book == null || !mounted) return;
    try {
      final api = ref.read(bookApiProvider);
      await ComicImageDecodeCache.preload(
        api: api,
        url: url,
        sourceJson: jsonEncode(source.toJson()),
        bookSourceUrl: book.origin,
      );
    } catch (_) {
      // 预加载失败静默；正式渲染会再试并展示错误态
    }
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
              // 漫画页脚信息条（对标原版 ReaderInfoBar）
              if (!_footerConfig.hideFooter) _buildMangaFooter(),
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

    // 统一走 FFI 下载：Rust fetchImageWithDecode 支持书源 header 防盗链与
    // `url,{json headers}` 复合格式（favcomic 等漫画站图片 URL 内嵌防盗链
    // header，对齐原版 AnalyzeUrl），且无 imageDecode 规则时原样返回 bytes。
    // CachedNetworkImage 直连无法解析复合 URL / 会把 AES 密文送进
    // FlutterImageDecoder →「图片加载失败」（51漫画设备实测）。
    // 漫画阅读器只要能解析到书源就禁止直连 CDN。— Reasonix
    if (_bookSource != null) {
      return _wrapImageFilter(
        _DecodedComicImage(
          url: url,
          sourceJson: jsonEncode(_bookSource!.toJson()),
          bookSourceUrl: _book!.origin,
          eInkThreshold: _enableEInk ? _eInkThreshold : null,
          onError: () {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_failedIndices.contains(index)) {
                setState(() {
                  _failedIndices.add(index);
                });
              }
            });
          },
        ),
      );
    }
    // 有 origin 却未命中书源：勿直连（密文/防盗链），直接失败可重试
    if (_book != null && _book!.origin.isNotEmpty) {
      return _buildImageErrorPlaceholder(index, url);
    }

    if (_enableEInk) {
      return _EpaperNetworkImage(
        api: ref.read(bookApiProvider),
        url: url,
        headers: _imageHeaders,
        threshold: _eInkThreshold,
        onError: () {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_failedIndices.contains(index)) {
              setState(() => _failedIndices.add(index));
            }
          });
        },
      );
    }

    return _wrapImageFilter(
      CachedNetworkImage(
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
      ),
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
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        _chapters[_currentChapterIndex].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.tune, color: Colors.white),
                  tooltip: '漫画设置',
                  onPressed: _openMangaConfig,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 漫画页脚信息条
  Widget _buildMangaFooter() {
    final chapterName = _currentChapterIndex < _chapters.length
        ? _chapters[_currentChapterIndex].title
        : '';
    final label = _footerConfig.buildLabel(
      chapterName: chapterName,
      chapterIndex: _currentChapterIndex,
      chapterSize: _chapters.length,
      pageIndex: _visiblePageIndex.clamp(
        0,
        _imageUrls.isEmpty ? 0 : _imageUrls.length - 1,
      ),
      imageCount: _imageUrls.length,
    );
    if (label.isEmpty) return const SizedBox.shrink();
    final align = _footerConfig.footerOrientation == MangaFooterConfig.alignCenter
        ? Alignment.center
        : Alignment.centerLeft;
    return Positioned(
      left: 12,
      right: 12,
      bottom: _showControls ? 88 : 12,
      child: IgnorePointer(
        child: Align(
          alignment: align,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0x99000000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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

/// FFI 图片解码结果缓存（预加载与正式渲染共用）— Reasonix + UI
class ComicImageDecodeCache {
  ComicImageDecodeCache._();

  static final Map<String, Uint8List> _cache = {};

  static String keyOf(String bookSourceUrl, String url) =>
      '$bookSourceUrl\u0000$url';

  static Uint8List? get(String bookSourceUrl, String url) =>
      _cache[keyOf(bookSourceUrl, url)];

  static void put(String bookSourceUrl, String url, Uint8List bytes) {
    // 拒绝缓存非图片字节（imageDecode 失败回退密文时勿污染缓存）— Reasonix + UI
    if (!looksLikeImageBytes(bytes)) return;
    _cache[keyOf(bookSourceUrl, url)] = bytes;
  }

  /// 预加载：调用 FFI 并写入缓存（已命中则跳过）
  static Future<void> preload({
    required BookApi api,
    required String url,
    required String sourceJson,
    required String bookSourceUrl,
  }) async {
    if (_cache.containsKey(keyOf(bookSourceUrl, url))) return;
    final json = await api.fetchImageWithDecode(url, sourceJson);
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    final b64 = decoded['base64'] as String? ?? '';
    if (b64.isEmpty) return;
    final bytes = base64Decode(b64);
    if (!looksLikeImageBytes(bytes)) return;
    put(bookSourceUrl, url, bytes);
  }

  /// 测试用：清空缓存
  @visibleForTesting
  static void clearForTest() => _cache.clear();
}

/// 走 imageDecode 解码链路的漫画图片项
///
/// 调用 Rust FFI `fetchImageWithDecode`：下载图片 bytes → 注入书源 jsLib +
/// imageDecode JS 解码（对齐原版 ImageUtils.decodeImageStream）→ 返回
/// base64 → [Image.memory] 显示。请求头（防盗链 Referer/UA）由 Rust 侧
/// 按书源 header 自动构造，Flutter 无需重复传 header。
///
/// [UI-fix v2.0.19 | 2026-08-11] 漫画/图片源图片解密链路落地 — Reasonix
class _DecodedComicImage extends ConsumerStatefulWidget {
  final String url;
  final String sourceJson;
  final String bookSourceUrl;
  final VoidCallback onError;
  /// 非 null 时做真像素电子纸二值化（对齐 EpaperTransformation）
  final int? eInkThreshold;

  const _DecodedComicImage({
    required this.url,
    required this.sourceJson,
    required this.bookSourceUrl,
    required this.onError,
    this.eInkThreshold,
  });

  @override
  ConsumerState<_DecodedComicImage> createState() => _DecodedComicImageState();
}

class _DecodedComicImageState extends ConsumerState<_DecodedComicImage> {
  bool _loading = true;
  Uint8List? _bytes;
  ui.Image? _epaperImage;
  String? _error;

  @override
  void initState() {
    super.initState();
    final hit = ComicImageDecodeCache.get(widget.bookSourceUrl, widget.url);
    if (hit != null) {
      _bytes = hit;
      _loading = false;
      unawaited(_applyEpaperIfNeeded(hit));
    } else {
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(covariant _DecodedComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eInkThreshold != widget.eInkThreshold && _bytes != null) {
      unawaited(_applyEpaperIfNeeded(_bytes!));
    }
  }

  @override
  void dispose() {
    _epaperImage?.dispose();
    super.dispose();
  }

  Future<void> _applyEpaperIfNeeded(Uint8List bytes) async {
    final thr = widget.eInkThreshold;
    if (thr == null) {
      _epaperImage?.dispose();
      if (mounted) setState(() => _epaperImage = null);
      return;
    }
    try {
      final img = await mangaEpaperFromBytes(bytes, threshold: thr);
      if (!mounted) {
        img.dispose();
        return;
      }
      _epaperImage?.dispose();
      setState(() => _epaperImage = img);
    } catch (e) {
      debugPrint('电子纸二值化失败: $e');
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(bookApiProvider);
      final json = await api.fetchImageWithDecode(widget.url, widget.sourceJson);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final b64 = decoded['base64'] as String? ?? '';
      if (b64.isEmpty) {
        throw Exception('解码结果为空（imageDecode 未返回有效图片数据）');
      }
      final bytes = base64Decode(b64);
      if (!looksLikeImageBytes(bytes)) {
        throw Exception(
          '解码结果不是有效图片（可能 imageDecode/createSymmetricCrypto 失败）',
        );
      }
      if (!mounted) return;
      ComicImageDecodeCache.put(widget.bookSourceUrl, widget.url, bytes);
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
      await _applyEpaperIfNeeded(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
      widget.onError();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: MediaQuery.of(context).size.height * 0.6,
        color: const Color(0xFF1A1A1A),
        child: const Center(
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF666666)),
        ),
      );
    }
    final epaper = _epaperImage;
    if (widget.eInkThreshold != null && epaper != null) {
      return RawImage(
        image: epaper,
        fit: BoxFit.fitWidth,
        width: double.infinity,
      );
    }
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.fitWidth,
        width: double.infinity,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => _errorPlaceholder(),
      );
    }
    return _errorPlaceholder();
  }

  Widget _errorPlaceholder() {
    return Container(
      height: MediaQuery.of(context).size.height * 0.4,
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image, size: 64, color: Color(0xFF666666)),
            const SizedBox(height: 12),
            Text(
              _error ?? '图片加载失败',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
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
}

/// 无书源时的网络图电子纸渲染
class _EpaperNetworkImage extends StatefulWidget {
  const _EpaperNetworkImage({
    required this.api,
    required this.url,
    required this.headers,
    required this.threshold,
    required this.onError,
  });

  final BookApi api;
  final String url;
  final Map<String, String>? headers;
  final int threshold;
  final VoidCallback onError;

  @override
  State<_EpaperNetworkImage> createState() => _EpaperNetworkImageState();
}

class _EpaperNetworkImageState extends State<_EpaperNetworkImage> {
  bool _loading = true;
  ui.Image? _image;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _EpaperNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.threshold != widget.threshold) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await bridgeHttpGetBytes(
        widget.api,
        widget.url,
        headers: widget.headers,
        timeout: const Duration(seconds: 30),
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('HTTP ${res.statusCode}');
      }
      final img = await mangaEpaperFromBytes(
        res.bytes,
        threshold: widget.threshold,
      );
      if (!mounted) {
        img.dispose();
        return;
      }
      _image?.dispose();
      setState(() {
        _image = img;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
      widget.onError();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: MediaQuery.of(context).size.height * 0.6,
        color: const Color(0xFF1A1A1A),
        child: const Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF666666),
          ),
        ),
      );
    }
    final img = _image;
    if (img != null) {
      return RawImage(
        image: img,
        fit: BoxFit.fitWidth,
        width: double.infinity,
      );
    }
    return Container(
      height: MediaQuery.of(context).size.height * 0.4,
      color: const Color(0xFF1A1A1A),
      child: Center(
        child: Text(
          _error ?? '图片加载失败',
          style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
        ),
      ),
    );
  }
}
