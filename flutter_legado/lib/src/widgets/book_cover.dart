import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../services/cover_decode_loader.dart';
import '../utils/comic_image_utils.dart';

/// 书籍封面组件 — 支持网络图片 + 默认封面 + coverDecodeJs 解密
///
/// 无封面 / 加载中 / 加载失败时显示默认封面图（assets/images/default_book_cover.jpg，
/// 对标原版 res/drawable/image_cover_default.jpg）。
///
/// 对齐原版 `CoverImageView` + Glide 列表行为：
/// - 无 `coverDecodeJs`：`CachedNetworkImage` 直连（缩略 memCacheWidth）
/// - 有 `coverDecodeJs`：经 [CoverDecodeLoader] 限流/缓存/取消后走 FFI
///
/// [UI-FIX v2.0.32 | 2026-08-11] 搜索列表封面解密卡顿 — Reasonix + UI
class BookCover extends ConsumerWidget {
  final String? coverUrl;
  final double width;
  final double height;
  final double borderRadius;

  /// 书源 origin（用于拉取 coverDecodeJs / header）
  final String? sourceOrigin;

  /// 已序列化的书源 JSON（优先于 [sourceOrigin] 查询）
  final String? sourceJson;

  const BookCover({
    super.key,
    this.coverUrl,
    this.width = 80,
    this.height = 110,
    this.borderRadius = 4,
    this.sourceOrigin,
    this.sourceJson,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: (coverUrl != null && coverUrl!.isNotEmpty)
            ? _CoverImage(
                coverUrl: coverUrl!,
                width: width,
                sourceOrigin: sourceOrigin,
                sourceJson: sourceJson,
                placeholder: _defaultCover(),
              )
            : _defaultCover(),
      ),
    );
  }

  /// 默认封面（对标原版 image_cover_default.jpg）：无封面 / 加载中 / 加载失败时显示
  Widget _defaultCover() {
    return Image.asset(
      'assets/images/default_book_cover.jpg',
      fit: BoxFit.cover,
      width: width,
      height: height,
    );
  }
}

class _CoverImage extends ConsumerStatefulWidget {
  final String coverUrl;
  final double width;
  final String? sourceOrigin;
  final String? sourceJson;
  final Widget placeholder;

  const _CoverImage({
    required this.coverUrl,
    required this.width,
    required this.placeholder,
    this.sourceOrigin,
    this.sourceJson,
  });

  @override
  ConsumerState<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends ConsumerState<_CoverImage> {
  Uint8List? _decodedBytes;
  bool _loadingDecode = false;
  bool _useDirect = false;
  bool _decodeFailed = false;
  int _loadGen = 0;
  CoverDecodeTicket? _ticket;

  @override
  void initState() {
    super.initState();
    unawaited(_startLoad());
  }

  @override
  void dispose() {
    _loadGen++;
    _ticket?.cancel();
    _ticket = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl ||
        oldWidget.sourceOrigin != widget.sourceOrigin ||
        oldWidget.sourceJson != widget.sourceJson) {
      _ticket?.cancel();
      _ticket = null;
      _decodedBytes = null;
      _decodeFailed = false;
      _useDirect = false;
      unawaited(_startLoad());
    }
  }

  Future<void> _startLoad() async {
    final gen = ++_loadGen;
    final origin = widget.sourceOrigin?.trim() ?? '';
    final url = widget.coverUrl;

    // 1) 内存缓存命中：立即显示，不占并发槽
    final cached = CoverDecodeLoader.getCached(origin, url);
    if (cached != null) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _decodedBytes = cached;
        _loadingDecode = false;
        _useDirect = false;
        _decodeFailed = false;
      });
      return;
    }

    if (!mounted || gen != _loadGen) return;
    setState(() {
      _loadingDecode = true;
      _decodeFailed = false;
    });

    try {
      final api = ref.read(bookApiProvider);
      final patched = await CoverDecodeLoader.resolvePatchedSourceJson(
        api: api,
        sourceJson: widget.sourceJson,
        sourceOrigin: widget.sourceOrigin,
      );
      if (!mounted || gen != _loadGen) return;

      if (patched == null) {
        // 书源解析失败：尝试直连兜底
        setState(() {
          _loadingDecode = false;
          _useDirect = true;
        });
        return;
      }

      final needFfi = CoverDecodeLoader.needsFfiDecode(
        coverUrl: url,
        patchedSourceJson: patched,
      );
      if (!needFfi) {
        setState(() {
          _loadingDecode = false;
          _useDirect = true;
        });
        return;
      }

      final bytes = await CoverDecodeLoader.load(
        api: api,
        coverUrl: url,
        patchedSourceJson: patched,
        originOrEmpty: origin,
        isCancelled: () => gen != _loadGen || !mounted,
        onTicket: (t) {
          if (gen != _loadGen) {
            t?.cancel();
            return;
          }
          _ticket = t;
        },
      );
      if (!mounted || gen != _loadGen) return;
      if (bytes != null) {
        setState(() {
          _decodedBytes = bytes;
          _loadingDecode = false;
          _decodeFailed = false;
        });
      } else {
        setState(() {
          _loadingDecode = false;
          _decodeFailed = true;
        });
      }
    } catch (e) {
      debugPrint('封面加载失败: $e');
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _loadingDecode = false;
        _decodeFailed = true;
      });
    }
  }

  int _thumbWidth(BuildContext context) {
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return (widget.width * pixelRatio).round().clamp(1, 512);
  }

  @override
  Widget build(BuildContext context) {
    if (_decodedBytes != null) {
      final thumb = _thumbWidth(context);
      return Image.memory(
        _decodedBytes!,
        fit: BoxFit.cover,
        width: widget.width,
        cacheWidth: thumb,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.placeholder,
      );
    }
    if (_loadingDecode) {
      return widget.placeholder;
    }
    if (_decodeFailed) {
      return widget.placeholder;
    }
    if (!_useDirect) {
      return widget.placeholder;
    }
    final url = stripCompositeImageUrl(widget.coverUrl);
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: _thumbWidth(context),
      placeholder: (_, _) => widget.placeholder,
      errorWidget: (_, _, _) => widget.placeholder,
    );
  }
}
