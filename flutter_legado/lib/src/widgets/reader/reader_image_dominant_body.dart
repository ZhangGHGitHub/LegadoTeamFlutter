import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../screens/reader_comic_screen.dart' show ComicImageDecodeCache;
// [批1b-2b] 复用既有全屏图片查看器（PhotoDialog 等价物：缩放 + 保存）
import '../../screens/rss_articles_screen.dart' show showRssPhotoViewer;
import '../../utils/click_img_way.dart';
import '../../utils/comic_image_utils.dart';
import '../../utils/image_paint_utils.dart';
import '../app_progress_indicator.dart';
import 'click_img_tap_detector.dart';

/// 文本阅读器内「图片主导正文」兜底渲染。
///
/// 必应漫画等 type=0 源正文为 `<img src>` HTML；文本排版引擎不认标签会
/// 把 URL 当字刷屏。此处按漫画纵向列表出图（有书源则 FFI，与 comic 对齐）。
///
/// `imageStyle` 对齐原版 `Book.getImageStyle` / `TextChapterLayout`：
/// - `FULL`：铺满宽度纵向列表
/// - `SINGLE`：一图一页（PageView + contain 居中）
/// - `TEXT` / 默认：宽度适配，高度不超过视口（近似行内大图）
/// — Reasonix + UI
class ReaderImageDominantBody extends ConsumerStatefulWidget {
  final String content;
  final Book book;
  final VoidCallback onToggleControls;
  final Future<void> Function()? onNextChapter;
  final Future<void> Function()? onPrevChapter;
  final bool hasNextChapter;
  final bool hasPrevChapter;

  /// 图片样式：FULL / TEXT / SINGLE（大小写不敏感）；空=默认
  final String? imageStyle;

  /// 正文图片点击方式（clickImgWay 五档，默认 "2"=兼容旧版）。
  /// [批1b-2b] 文本排版引擎尚无行内图片渲染，图片只在本兜底页出现，
  /// 故五档点击分流在此消费。
  final String clickImgWay;

  /// 当前章节序号（图片 action 绑定 `chapter`；`-1` 表示无章节上下文）
  final int chapterIndex;

  const ReaderImageDominantBody({
    super.key,
    required this.content,
    required this.book,
    required this.onToggleControls,
    this.onNextChapter,
    this.onPrevChapter,
    this.hasNextChapter = false,
    this.hasPrevChapter = false,
    this.imageStyle,
    this.clickImgWay = kDefaultClickImgWay,
    this.chapterIndex = -1,
  });

  @override
  ConsumerState<ReaderImageDominantBody> createState() =>
      _ReaderImageDominantBodyState();
}

class _ReaderImageDominantBodyState
    extends ConsumerState<ReaderImageDominantBody> {
  BookSource? _bookSource;
  List<String> _urls = [];

  /// 与 [_urls] 同序的复合 URL 解析结果（click/js/headers）
  List<ClickImgUrlOptions> _options = const [];

  /// 在线文本书（对齐原版 `Book.isOnLineTxt`：非本地且文本类型）——
  /// clickImgWay "2"（兼容旧版）仅对该类书执行动作
  bool get _onlineText =>
      !BookType.isLocalBook(widget.book) &&
      (widget.book.bookType & BookType.text) != 0;

  @override
  void initState() {
    super.initState();
    _applyContent(widget.content);
    _loadSource();
  }

  @override
  void didUpdateWidget(covariant ReaderImageDominantBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _applyContent(widget.content);
    }
    if (oldWidget.book.origin != widget.book.origin) {
      _bookSource = null;
      _loadSource();
    }
  }

  void _applyContent(String content) {
    _urls = parseComicImageUrls(content);
    _options = _urls.map(parseClickImgUrlOptions).toList(growable: false);
  }

  Future<void> _loadSource() async {
    final origin = widget.book.origin;
    if (origin.isEmpty) return;
    try {
      final sources = await ref.read(bookApiProvider).getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == origin) {
          if (mounted) setState(() => _bookSource = s);
          return;
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_urls.isEmpty) {
      return const Center(child: Text('暂无图片'));
    }
    final style = (widget.imageStyle ?? '').trim().toUpperCase();
    if (style == 'SINGLE') {
      return _buildSinglePageView(context);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleControls,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: _urls.length + 1,
        itemBuilder: (context, index) {
          if (index == _urls.length) {
            return _buildChapterNav();
          }
          return _buildImage(index, style: style);
        },
      ),
    );
  }

  /// SINGLE：一图一页，居中 contain（对齐 TextChapterLayout imgStyleSingle）
  Widget _buildSinglePageView(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleControls,
      child: PageView.builder(
        itemCount: _urls.length,
        itemBuilder: (context, index) {
          return Center(
            child: _buildImage(index, style: 'SINGLE', expandHeight: true),
          );
        },
      ),
    );
  }

  Widget _buildImage(
    int index, {
    String style = 'FULL',
    bool expandHeight = false,
  }) {
    final url = _urls[index];
    final source = _bookSource;
    final viewH = MediaQuery.of(context).size.height;
    BoxFit fit;
    double? maxH;
    if (style == 'SINGLE') {
      fit = BoxFit.contain;
      maxH = viewH;
    } else if (style == 'TEXT') {
      // 近似行内：限制高度，宽度仍适配
      fit = BoxFit.fitWidth;
      maxH = viewH * 0.45;
    } else {
      // FULL / 默认
      fit = BoxFit.fitWidth;
      maxH = null;
    }

    Widget image;
    if (source != null) {
      image = _FfiComicImage(
        url: url,
        sourceJson: jsonEncode(source.toJson()),
        bookSourceUrl: widget.book.origin,
        fit: fit,
        maxHeight: maxH,
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: stripCompositeImageUrl(url),
        fit: fit,
        width: double.infinity,
        placeholder: (context, url) => SizedBox(
          height: expandHeight ? viewH * 0.5 : viewH * 0.4,
          // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
          child: const Center(child: AppCircularProgressIndicator()),
        ),
        errorWidget: (context, url, error) => SizedBox(
          height: 160,
          child: Center(
            child: Text('图片加载失败', style: TextStyle(color: Colors.grey[600])),
          ),
        ),
      );
    }

    Widget result;
    if (maxH != null && style != 'SINGLE') {
      result = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: image,
      );
    } else if (style == 'SINGLE') {
      result = SizedBox(height: viewH, width: double.infinity, child: image);
    } else {
      result = image;
    }
    return _wrapImageTap(index, result);
  }

  /// [批1b-2b] 按 clickImgWay 五档包裹图片点击（语义见 utils/click_img_way.dart）
  Widget _wrapImageTap(int index, Widget child) {
    final options = index < _options.length
        ? _options[index]
        : ClickImgUrlOptions(url: _urls[index]);
    return ClickImgTapDetector(
      clickImgWay: widget.clickImgWay,
      onlineText: _onlineText,
      options: options,
      onPreview: () => _previewImage(options),
      onRunAction: _runImageAction,
      child: child,
    );
  }

  /// 打开图片预览（复用既有全屏查看器；复合 URL 的 headers 一并透传）
  Future<void> _previewImage(ClickImgUrlOptions options) {
    return showRssPhotoViewer(
      context,
      url: stripCompositeImageUrl(options.url),
      headers: options.headers,
    );
  }

  /// 执行正文图片的书源 `click`/`js` 动作（契约 §2.21）
  ///
  /// 参考版 `ReadBookController.clickImg` 的 onError 只记录日志、不打断
  /// 阅读；此处同样吞掉执行异常（含无 quickjs 构建的明确错误）。
  Future<void> _runImageAction(String action, String imgSrc) async {
    final bookUrl = widget.book.bookUrl;
    if (bookUrl.isEmpty) return;
    try {
      await ref
          .read(bookApiProvider)
          .evalImageAction(bookUrl, widget.chapterIndex, action, imgSrc);
    } catch (e) {
      // 动作执行失败不打断阅读（无 quickjs 构建等明确错误在此可见）
      debugPrint('[reader] 图片动作执行失败（已忽略）：$e');
    }
  }

  Widget _buildChapterNav() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: widget.hasPrevChapter && widget.onPrevChapter != null
                  ? () => widget.onPrevChapter!()
                  : null,
              child: const Text('上一章'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              onPressed: widget.hasNextChapter && widget.onNextChapter != null
                  ? () => widget.onNextChapter!()
                  : null,
              child: const Text('下一章'),
            ),
          ),
        ],
      ),
    );
  }
}

class _FfiComicImage extends ConsumerStatefulWidget {
  final String url;
  final String sourceJson;
  final String bookSourceUrl;
  final BoxFit fit;
  final double? maxHeight;

  const _FfiComicImage({
    required this.url,
    required this.sourceJson,
    required this.bookSourceUrl,
    this.fit = BoxFit.fitWidth,
    this.maxHeight,
  });

  @override
  ConsumerState<_FfiComicImage> createState() => _FfiComicImageState();
}

class _FfiComicImageState extends ConsumerState<_FfiComicImage> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant _FfiComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = _load();
    }
  }

  Future<Uint8List?> _load() async {
    final hit = ComicImageDecodeCache.get(widget.bookSourceUrl, widget.url);
    if (hit != null) return hit;
    try {
      await ComicImageDecodeCache.preload(
        api: ref.read(bookApiProvider),
        url: widget.url,
        sourceJson: widget.sourceJson,
        bookSourceUrl: widget.bookSourceUrl,
      );
      return ComicImageDecodeCache.get(widget.bookSourceUrl, widget.url);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        final viewH = MediaQuery.of(context).size.height;
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(
            height: widget.maxHeight ?? viewH * 0.4,
            // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
            child: const Center(child: AppCircularProgressIndicator()),
          );
        }
        final bytes = snap.data;
        if (bytes == null || !looksLikeImageBytes(bytes)) {
          return SizedBox(
            height: 160,
            child: Center(
              child: Text('图片加载失败', style: TextStyle(color: Colors.grey[600])),
            ),
          );
        }
        Widget img = Image.memory(
          bytes,
          fit: widget.fit,
          width: double.infinity,
          // 批9a：图片采样质量按 antiAlias 偏好（medium 默认/high 开启）
          filterQuality: ImagePaintPrefs.imageFilterQuality,
        );
        if (widget.maxHeight != null) {
          img = ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight!),
            child: img,
          );
        }
        return img;
      },
    );
  }
}
