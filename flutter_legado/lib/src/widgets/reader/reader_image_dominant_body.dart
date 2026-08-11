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
/// — Reasonix + UI
class ReaderImageDominantBody extends ConsumerStatefulWidget {
  final String content;
  final Book book;
  final VoidCallback onToggleControls;
  final Future<void> Function()? onNextChapter;
  final Future<void> Function()? onPrevChapter;
  final bool hasNextChapter;
  final bool hasPrevChapter;

  const ReaderImageDominantBody({
    super.key,
    required this.content,
    required this.book,
    required this.onToggleControls,
    this.onNextChapter,
    this.onPrevChapter,
    this.hasNextChapter = false,
    this.hasPrevChapter = false,
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
          return _buildImage(index);
        },
      ),
    );
  }

  Widget _buildImage(int index) {
    final url = _urls[index];
    final source = _bookSource;
    if (source != null) {
      return _FfiComicImage(
        url: url,
        sourceJson: jsonEncode(source.toJson()),
        bookSourceUrl: widget.book.origin,
      );
    }
    return CachedNetworkImage(
      imageUrl: stripCompositeImageUrl(url),
      fit: BoxFit.fitWidth,
      width: double.infinity,
      placeholder: (context, url) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.4,
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

  const _FfiComicImage({
    required this.url,
    required this.sourceJson,
    required this.bookSourceUrl,
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
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.4,
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
        return Image.memory(
          bytes,
          fit: BoxFit.fitWidth,
          width: double.infinity,
          filterQuality: FilterQuality.medium,
        );
      },
    );
  }
}
