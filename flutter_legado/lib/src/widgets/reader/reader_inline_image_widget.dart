// 正文行内图片渲染组件（批16）
//
// 负责把排版引擎产出的 [ReaderImageLayout] 画出来：
// - 独立图片行：按显示宽高 + 对齐方式渲染；
// - 行内小图：作为 `Text.rich` 的 WidgetSpan 占位渲染；
// - 点击接既有 [ClickImgTapDetector]（五档语义），action 执行通道仍按
//   现状回退预览（`kClickImgActionSupported=false`）；
// - 字节加载器由阅读页注入（书源 imageDecode 走 FFI，本地/无源走 HTTP），
//   本组件在无加载器时只画占位，保证组件级测试不触发网络。
// — 全栈工程师 + UI

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../utils/click_img_way.dart';
import '../../utils/reader_inline_image.dart';
import 'click_img_tap_detector.dart';

/// 解码图片字节的固有尺寸（失败返回 null）
Future<ReaderImageSize?> decodeReaderImageSize(Uint8List bytes) async {
  ui.Codec? codec;
  try {
    final opened = await ui.instantiateImageCodec(bytes);
    codec = opened;
    final frame = await opened.getNextFrame();
    final image = frame.image;
    final size = ReaderImageSize(
      image.width.toDouble(),
      image.height.toDouble(),
    );
    image.dispose();
    return size;
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}

/// 图片字节加载器（阅读页注入；返回 null 表示加载失败）
typedef ReaderImageBytesLoader =
    Future<Uint8List?> Function(ReaderInlineImage image);

/// 正文图片渲染配置（点击档位 + 在线文本判定 + 预览回调 + 字节加载器）
@immutable
class ReaderImageRenderConfig {
  final ReaderImageBytesLoader? loader;
  final String clickImgWay;
  final bool onlineText;
  final ValueChanged<ReaderInlineImage>? onPreview;

  const ReaderImageRenderConfig({
    this.loader,
    this.clickImgWay = kDefaultClickImgWay,
    this.onlineText = false,
    this.onPreview,
  });

  ReaderImageRenderConfig copyWith({
    ReaderImageBytesLoader? loader,
    String? clickImgWay,
    bool? onlineText,
    ValueChanged<ReaderInlineImage>? onPreview,
  }) {
    return ReaderImageRenderConfig(
      loader: loader ?? this.loader,
      clickImgWay: clickImgWay ?? this.clickImgWay,
      onlineText: onlineText ?? this.onlineText,
      onPreview: onPreview ?? this.onPreview,
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
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(covariant ReaderInlineImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.rawSrc != widget.image.rawSrc ||
        oldWidget.config.loader != widget.config.loader) {
      _startLoad();
    }
  }

  void _startLoad() {
    final loader = widget.config.loader;
    _future = loader == null ? null : loader(widget.image);
  }

  @override
  Widget build(BuildContext context) {
    final sized = SizedBox(
      width: widget.width,
      height: widget.height,
      child: _buildImage(context),
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

  Widget _buildImage(BuildContext context) {
    final future = _future;
    if (future == null) return _buildPlaceholder(context, failed: false);
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildPlaceholder(context, failed: false);
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return _buildPlaceholder(context, failed: true);
        }
        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, error, stackTrace) =>
              _buildPlaceholder(context, failed: true),
        );
      },
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
