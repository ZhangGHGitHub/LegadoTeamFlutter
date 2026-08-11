import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/book_source.dart';
import '../providers/providers.dart';
import '../utils/comic_image_utils.dart';

/// 书籍封面组件 — 支持网络图片 + 占位图 + coverDecodeJs 解密
///
/// 对齐原版 `CoverImageView` + `OkHttpStreamFetcher`：
/// - 无 `coverDecodeJs`：`CachedNetworkImage` 直连（带可选 Referer）
/// - 有 `coverDecodeJs`：走 FFI `fetchImageWithDecode`（将 coverDecodeJs
///   映射为 imageDecode，复用 AES 解密链路；51漫画封面密文直连会
///   FlutterImageDecoder 失败）
///
/// [UI-fix v2.0.29 | 2026-08-11] 封面 coverDecodeJs — Reasonix + UI
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
    final colorScheme = Theme.of(context).colorScheme;
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
                placeholder: _buildPlaceholder(colorScheme),
              )
            : _buildPlaceholder(colorScheme),
      ),
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme) {
    return Container(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.menu_book,
          size: width * 0.4,
          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        ),
      ),
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
  bool _decodeFailed = false;
  String? _resolvedSourceJson;

  @override
  void initState() {
    super.initState();
    _maybeStartDecode();
  }

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl ||
        oldWidget.sourceOrigin != widget.sourceOrigin ||
        oldWidget.sourceJson != widget.sourceJson) {
      _decodedBytes = null;
      _decodeFailed = false;
      _resolvedSourceJson = null;
      _maybeStartDecode();
    }
  }

  Future<void> _maybeStartDecode() async {
    final rawJson = widget.sourceJson;
    if (rawJson != null && rawJson.isNotEmpty) {
      await _tryDecodeWithSource(rawJson);
      return;
    }
    final origin = widget.sourceOrigin;
    if (origin == null || origin.isEmpty) return;
    try {
      final sources = await ref.read(bookApiProvider).getBookSources();
      if (!mounted) return;
      BookSource? source;
      for (final s in sources) {
        if (s.bookSourceUrl == origin) {
          source = s;
          break;
        }
      }
      if (source == null) return;
      final json = jsonEncode(source.toJson());
      await _tryDecodeWithSource(json);
    } catch (e) {
      debugPrint('封面书源加载失败: $e');
    }
  }

  Future<void> _tryDecodeWithSource(String sourceJson) async {
    Map<String, dynamic>? map;
    try {
      map = jsonDecode(sourceJson) as Map<String, dynamic>?;
    } catch (_) {
      return;
    }
    final coverDecode = (map?['coverDecodeJs'] as String?)?.trim();
    if (coverDecode == null || coverDecode.isEmpty) {
      // 无解密规则：若为复合 URL 仍走 FFI 原样下载
      if (!isCompositeImageUrl(widget.coverUrl)) return;
    }
    if (_loadingDecode) return;
    setState(() => _loadingDecode = true);
    try {
      // 将 coverDecodeJs 映射为 imageDecode，复用既有 FFI（避免改 FRB 签名）
      final patched = Map<String, dynamic>.from(map ?? {});
      if (coverDecode != null && coverDecode.isNotEmpty) {
        final ruleContent = Map<String, dynamic>.from(
          (patched['ruleContent'] as Map?)?.cast<String, dynamic>() ?? {},
        );
        ruleContent['imageDecode'] = coverDecode;
        patched['ruleContent'] = ruleContent;
      }
      final patchedJson = jsonEncode(patched);
      _resolvedSourceJson = patchedJson;
      final resp = await ref
          .read(bookApiProvider)
          .fetchImageWithDecode(widget.coverUrl, patchedJson);
      final decoded = jsonDecode(resp) as Map<String, dynamic>;
      final b64 = decoded['base64'] as String?;
      if (b64 == null || b64.isEmpty) {
        throw Exception('封面解码结果为空');
      }
      final bytes = base64Decode(b64);
      if (!mounted) return;
      setState(() {
        _decodedBytes = bytes;
        _loadingDecode = false;
        _decodeFailed = false;
      });
    } catch (e) {
      debugPrint('封面 coverDecodeJs 失败: $e');
      if (!mounted) return;
      setState(() {
        _loadingDecode = false;
        _decodeFailed = true;
      });
    }
  }

  int _decodeWidth(BuildContext context) {
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return (widget.width * pixelRatio).round();
  }

  @override
  Widget build(BuildContext context) {
    if (_decodedBytes != null) {
      return Image.memory(
        _decodedBytes!,
        fit: BoxFit.cover,
        width: widget.width,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.placeholder,
      );
    }
    if (_loadingDecode) {
      return widget.placeholder;
    }
    // 解密失败或无需解密：直连（失败时占位）
    if (_decodeFailed && _resolvedSourceJson != null) {
      return widget.placeholder;
    }
    final url = stripCompositeImageUrl(widget.coverUrl);
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: _decodeWidth(context),
      placeholder: (_, _) => widget.placeholder,
      errorWidget: (_, _, _) => widget.placeholder,
    );
  }
}
