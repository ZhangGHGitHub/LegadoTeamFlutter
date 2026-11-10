// 正文行内图片渲染组件（批16）
//
// 负责把排版引擎产出的 [ReaderImageLayout] 画出来：
// - 独立图片行：按显示宽高 + 对齐方式渲染；
// - 行内小图：作为 `Text.rich` 的 WidgetSpan 占位渲染；
// - 点击接既有 [ClickImgTapDetector]（五档语义），action 执行通道仍按
//   现状回退预览（`kClickImgActionSupported=false`）；
// - 字节加载器由阅读页注入（书源 imageDecode 走 FFI，本地/无源走 HTTP），
//   本组件在无加载器时只画占位，保证组件级测试不触发网络；
// - [批16 回修 P1-3/P2-8] 渲染解码按显示宽度上限降采样（ResizeImage），
//   成功拿到帧后把真实尺寸回填 `ReaderImageSizeCache` 并触发一次重排；
//   尺寸测量已失败且无字节缓存时不再重复下载（只显示失败占位）。
// — 全栈工程师 + UI

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../utils/click_img_way.dart';
import '../../utils/reader_inline_image.dart';
import 'click_img_tap_detector.dart';

/// 解码图片字节的固有尺寸（失败返回 null）
///
/// [批16 回修 P1-3] 只读文件头/描述符，不做整图像素解码，避免超大图 OOM；
/// 宽高为图片固有像素尺寸（布局用）。
Future<ReaderImageSize?> decodeReaderImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 || descriptor.height <= 0) return null;
    return ReaderImageSize(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// 图片字节加载器（阅读页注入；返回 null 表示加载失败）
typedef ReaderImageBytesLoader =
    Future<Uint8List?> Function(ReaderInlineImage image);

/// 图片尺寸测量器（测试注入点；生产为 null 走字节解码）
typedef ReaderImageSizeMeasurer =
    Future<ReaderImageSize?> Function(ReaderInlineImage image);

/// 正文图片渲染配置（点击档位 + 在线文本判定 + 预览回调 + 字节加载器）
@immutable
class ReaderImageRenderConfig {
  final ReaderImageBytesLoader? loader;
  final String clickImgWay;
  final bool onlineText;
  final ValueChanged<ReaderInlineImage>? onPreview;

  /// 字节缓存键前缀（书源地址；本地/无源为空串）
  final String cacheOrigin;

  /// 渲染成功拿到真实尺寸后回调（阅读页据此触发合并重排）
  final VoidCallback? onSizeResolved;

  const ReaderImageRenderConfig({
    this.loader,
    this.clickImgWay = kDefaultClickImgWay,
    this.onlineText = false,
    this.onPreview,
    this.cacheOrigin = '',
    this.onSizeResolved,
  });

  ReaderImageRenderConfig copyWith({
    ReaderImageBytesLoader? loader,
    String? clickImgWay,
    bool? onlineText,
    ValueChanged<ReaderInlineImage>? onPreview,
    String? cacheOrigin,
    VoidCallback? onSizeResolved,
  }) {
    return ReaderImageRenderConfig(
      loader: loader ?? this.loader,
      clickImgWay: clickImgWay ?? this.clickImgWay,
      onlineText: onlineText ?? this.onlineText,
      onPreview: onPreview ?? this.onPreview,
      cacheOrigin: cacheOrigin ?? this.cacheOrigin,
      onSizeResolved: onSizeResolved ?? this.onSizeResolved,
    );
  }
}

/// 正文图片组件（独立行与行内 WidgetSpan 共用）
class ReaderInlineImageWidget extends StatefulWidget {
  final ReaderInlineImage image;
  final double width;
  final double height;
  final ReaderImageRenderConfig config;
  final BoxFit fit;

  const ReaderInlineImageWidget({
    super.key,
    required this.image,
    required this.width,
    required this.height,
    required this.config,
    this.fit = BoxFit.contain,
  });

  @override
  State<ReaderInlineImageWidget> createState() =>
      _ReaderInlineImageWidgetState();
}

class _ReaderInlineImageWidgetState extends State<ReaderInlineImageWidget> {
  Uint8List? _bytes;
  bool _failed = false;
  bool _loading = false;
  bool _observeScheduled = false;

  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant ReaderInlineImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.rawSrc != widget.image.rawSrc ||
        oldWidget.config.loader != widget.config.loader ||
        oldWidget.config.cacheOrigin != widget.config.cacheOrigin) {
      _startLoad();
    }
  }

  @override
  void dispose() {
    _detachSizeListener();
    super.dispose();
  }

  void _startLoad() {
    _detachSizeListener();
    _observeScheduled = false;
    _bytes = null;
    _failed = false;
    _loading = false;

    // 已有字节缓存优先：即使尺寸测量曾失败，也允许用缓存渲染并回填尺寸
    final cached = ReaderImageBytesCache.get(
      widget.config.cacheOrigin,
      widget.image.rawSrc,
    );
    if (cached != null) {
      _bytes = cached;
      return;
    }
    // 失败永久化：不再发起下载（避免坏 URL 反复请求），只画失败占位
    final failure =
        ReaderImageSizeCache.lookup(widget.image.rawSrc)?.failed == true;
    final loader = widget.config.loader;
    if (failure || loader == null) {
      _failed = true;
      return;
    }
    _loading = true;
    unawaited(
      loader(widget.image).then(
        (bytes) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _bytes = bytes;
            _failed = bytes == null || bytes.isEmpty;
          });
          if (bytes != null && bytes.isNotEmpty) {
            ReaderImageBytesCache.put(
              widget.config.cacheOrigin,
              widget.image.rawSrc,
              bytes,
            );
          }
        },
        onError: (Object _) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _failed = true;
          });
        },
      ),
    );
  }

  void _detachSizeListener() {
    final stream = _sizeStream;
    final listener = _sizeListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _sizeStream = null;
    _sizeListener = null;
  }

  /// 监听实际解码帧尺寸：渲染成功即回填尺寸缓存并通知重排（P2-8）
  void _observeDecodedSize(Uint8List bytes) {
    if (_sizeListener != null || !mounted) return;
    final provider = _decodeProvider(bytes);
    final stream = provider.resolve(const ImageConfiguration());
    final listener = ImageStreamListener(
      (info, synchronousCall) {
        _detachSizeListener();
        final fallback = ReaderImageSize(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        unawaited(_writeBackSize(bytes, fallback));
      },
      onError: (Object error, StackTrace? stackTrace) {
        _detachSizeListener();
      },
    );
    _sizeStream = stream;
    _sizeListener = listener;
    stream.addListener(listener);
  }

  /// 渲染成功回填固有尺寸（优先读图片头；解码帧尺寸仅兜底）
  Future<void> _writeBackSize(Uint8List bytes, ReaderImageSize fallback) async {
    final intrinsic = await decodeReaderImageSize(bytes);
    final size = intrinsic != null && intrinsic.isValid ? intrinsic : fallback;
    if (!mounted || !size.isValid) return;
    final existing = ReaderImageSizeCache.lookup(widget.image.rawSrc);
    if (existing != null && existing.isValid) return;
    ReaderImageSizeCache.put(widget.image.rawSrc, size);
    widget.config.onSizeResolved?.call();
  }

  ImageProvider _decodeProvider(Uint8List bytes) {
    // [批16 回修 P1-3] 按显示宽 × DPR 限宽解码（超大图不再整图解码）；
    // allowUpscaling=false 保证小图保持固有尺寸。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final target = (widget.width * dpr).round().clamp(1, 4096);
    return ResizeImage(
      MemoryImage(bytes),
      width: target,
      allowUpscaling: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null && !_observeScheduled) {
      _observeScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _bytes != null) {
          _observeDecodedSize(_bytes!);
        }
      });
    }
    final sized = SizedBox(
      width: widget.width,
      height: widget.height,
      child: _buildImage(context, bytes),
    );
    if (widget.config.onPreview == null) return sized;
    return ClickImgTapDetector(
      clickImgWay: widget.config.clickImgWay,
      onlineText: widget.config.onlineText,
      options: widget.image.options,
      onPreview: () => widget.config.onPreview?.call(widget.image),
      child: sized,
    );
  }

  Widget _buildImage(BuildContext context, Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return _buildPlaceholder(context, failed: _failed && !_loading);
    }
    return Image(
      image: _decodeProvider(bytes),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) =>
          _buildPlaceholder(context, failed: true),
    );
  }

  Widget _buildPlaceholder(BuildContext context, {required bool failed}) {
    final scheme = Theme.of(context).colorScheme;
    final size = math.min(widget.width, widget.height);
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: failed && size >= 32
          ? Icon(
              Icons.broken_image_outlined,
              size: math.min(24, size * 0.5),
              color: scheme.onSurface.withValues(alpha: 0.35),
            )
          : null,
    );
  }
}

/// 独立图片行（按对齐方式放置，行高由排版引擎给出）
class ReaderImageLineWidget extends StatelessWidget {
  final ReaderImageLayout layout;
  final ReaderImageRenderConfig config;

  const ReaderImageLineWidget({
    super.key,
    required this.layout,
    required this.config,
  });

  @override
  Widget build(BuildContext context) {
    final alignment = switch (layout.alignment) {
      ReaderImageAlignment.left => Alignment.centerLeft,
      ReaderImageAlignment.right => Alignment.centerRight,
      ReaderImageAlignment.center => Alignment.center,
    };
    return SizedBox(
      width: double.infinity,
      height: layout.height,
      child: Align(
        alignment: alignment,
        child: ReaderInlineImageWidget(
          image: layout.image,
          width: layout.width,
          height: layout.height,
          config: config,
        ),
      ),
    );
  }
}
