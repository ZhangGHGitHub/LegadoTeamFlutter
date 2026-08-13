import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../screens/reader_comic_screen.dart' show ComicImageDecodeCache;
import '../../utils/comic_image_utils.dart';

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
  });

  @override
  ConsumerState<ReaderImageDominantBody> createState() =>
      _ReaderImageDominantBodyState();
}

class _ReaderImageDominantBodyState
    extends ConsumerState<ReaderImageDominantBody> {
  BookSource? _bookSource;
  List<String> _urls = [];

  @override
  void initState() {
    super.initState();
    _urls = parseComicImageUrls(widget.content);
    _loadSource();
  }

  @override
  void didUpdateWidget(covariant ReaderImageDominantBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _urls = parseComicImageUrls(widget.content);
    }
    if (oldWidget.book.origin != widget.book.origin) {
      _bookSource = null;
      _loadSource();
    }
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
          child: const Center(child: CircularProgressIndicator()),
        ),
        errorWidget: (context, url, error) => SizedBox(
          height: 160,
          child: Center(
            child: Text('图片加载失败', style: TextStyle(color: Colors.grey[600])),
          ),
        ),
      );
    }

    if (maxH != null && style != 'SINGLE') {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: image,
      );
    }
    if (style == 'SINGLE') {
      return SizedBox(
        height: viewH,
        width: double.infinity,
        child: image,
      );
    }
    return image;
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
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        final bytes = snap.data;
        if (bytes == null || !looksLikeImageBytes(bytes)) {
          return SizedBox(
            height: 160,
            child: Center(
              child:
                  Text('图片加载失败', style: TextStyle(color: Colors.grey[600])),
            ),
          );
        }
        Widget img = Image.memory(
          bytes,
          fit: widget.fit,
          width: double.infinity,
          filterQuality: FilterQuality.medium,
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
