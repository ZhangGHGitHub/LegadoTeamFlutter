import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../services/cover_aspect_ratio.dart';
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
/// [批39] 新增 [adaptAspectRatio]：跟随「限制封面比例」设置（默认开 = 固定
/// 5:7；关闭 = 按原图比例自适应高度），对齐参考版 `adaptCoverAspectRatio`
/// 与 `cachedCoverAspectRatio` 语义。
///
/// [UI-FIX v2.0.32 | 2026-08-11] 搜索列表封面解密卡顿 — Reasonix + UI
class BookCover extends StatefulWidget {
  final String? coverUrl;
  final double width;
  final double height;
  final double borderRadius;

  /// 书源 origin（用于拉取 coverDecodeJs / header）
  final String? sourceOrigin;

  /// 已序列化的书源 JSON（优先于 [sourceOrigin] 查询）
  final String? sourceJson;

  /// Hero 过渡标签（书架↔详情封面过渡，UI_MD3_PLAN.md Batch 1；
  /// 约定 `cover:<book url>`，空/null 不启用 Hero）
  final String? heroTag;

  /// 跟随「限制封面比例」设置自适应高度（批39）
  ///
  /// true 时读取 `uiSettingsProvider.restrictCoverRatio`：
  /// - 开启（默认）：保持 [height]（固定 5:7）；
  /// - 关闭：按封面原图宽高比换算高度，并夹在
  ///   [adaptiveMinHeight]..[adaptiveMaxHeight]（保持布局稳定）。
  final bool adaptAspectRatio;

  /// 自适应高度下限（null = [height] 的 70%）
  final double? adaptiveMinHeight;

  /// 自适应高度上限（null = [height] 的 160%）
  final double? adaptiveMaxHeight;

  const BookCover({
    super.key,
    this.coverUrl,
    this.width = 80,
    this.height = 110,
    this.borderRadius = 4,
    this.sourceOrigin,
    this.sourceJson,
    this.heroTag,
    this.adaptAspectRatio = false,
    this.adaptiveMinHeight,
    this.adaptiveMaxHeight,
  });

  @override
  State<BookCover> createState() => _BookCoverState();
}

class _BookCoverState extends State<BookCover> {
  /// 已解析的封面宽高比（宽/高；null = 尚未解析，回退固定 5:7）
  double? _ratio;

  @override
  void didUpdateWidget(covariant BookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl) {
      _ratio = CoverAspectRatio.cached(widget.coverUrl);
    }
  }

  /// 当前封面显示高度
  ///
  /// 直接读全局 [uiSettingsListenable]（非 Riverpod）：BookCover 在大量
  /// 列表/测试宿主中渲染，不要求外层存在 ProviderScope。
  double _displayHeight(bool restrict) {
    if (!widget.adaptAspectRatio || restrict) return widget.height;
    final ratio = _ratio ??
        CoverAspectRatio.cached(widget.coverUrl) ??
        CoverAspectRatio.restricted;
    return CoverAspectRatio.heightFor(
      width: widget.width,
      ratio: ratio,
      minHeight: widget.adaptiveMinHeight ?? widget.height * 0.7,
      maxHeight: widget.adaptiveMaxHeight ?? widget.height * 1.6,
    );
  }

  /// 记录已解析比例（图片加载完成回调；对齐参考版 onImageAspectRatio）
  void _reportRatio(double? ratio) {
    if (!mounted || !CoverAspectRatio.isValid(ratio)) return;
    final changed = CoverAspectRatio.remember(widget.coverUrl, ratio);
    final value = CoverAspectRatio.cached(widget.coverUrl);
    if (value != null && _ratio != value) {
      if (widget.adaptAspectRatio) {
        setState(() => _ratio = value);
      } else {
        // 非自适应封面只登记比例（供网格/其他入口复用），不触发自身重建
        _ratio = value;
      }
    }
    if (changed) {
      // 网格行高随新比例重算（书架/发现页监听该修订号）
      coverAspectRatioRevision.value++;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.adaptAspectRatio) {
      return _buildCover(widget.height);
    }
    return ValueListenableBuilder<UiSettingsState>(
      valueListenable: uiSettingsListenable,
      builder: (context, settings, _) =>
          _buildCover(_displayHeight(settings.restrictCoverRatio)),
    );
  }

  Widget _buildCover(double height) {
    Widget cover = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SizedBox(
        width: widget.width,
        height: height,
        child: (widget.coverUrl != null && widget.coverUrl!.isNotEmpty)
            ? _CoverImage(
                coverUrl: widget.coverUrl!,
                width: widget.width,
                sourceOrigin: widget.sourceOrigin,
                sourceJson: widget.sourceJson,
                placeholder: _defaultCover(height),
                onAspectRatio: _reportRatio,
              )
            : _defaultCover(height),
      ),
    );
    final tag = widget.heroTag;
    if (tag != null && tag.isNotEmpty) {
      // [LAYOUT_PLAN P4] 内置 Hero 保持无 flightShuttle（防与外层 Hero 嵌套）。
      cover = Hero(tag: tag, child: cover);
    }
    return cover;
  }

  /// 默认封面（对标原版 image_cover_default.jpg）：无封面 / 加载中 / 加载失败时显示
  Widget _defaultCover(double height) {
    return Image.asset(
      'assets/images/default_book_cover.jpg',
      fit: BoxFit.cover,
      width: widget.width,
      height: height,
    );
  }
}

/// [LAYOUT_PLAN P4] 封面 Hero 过渡：圆角 4→12 插值 morph（由详情页外层 Hero 调用，
/// BookCover 内置 Hero 不用，避免嵌套）。
/// [UI-fix v2.0.166] 飞行内容取出发侧已加载封面（push=书架已渲染图 / pop=详情
/// 已渲染图）：目标侧新实例在异步解析期会闪默认占位封面（对齐参考仓
/// sharedBounds「同图飞行」语义）；飞行层不在路由子树内，出发侧内置 Hero 不生效。
Widget coverFlightShuttleBuilder(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection flightDirection,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final fromHero = fromHeroContext.widget as Hero;
  return AnimatedBuilder(
    animation: animation,
    builder: (context, child) {
      final t = flightDirection == HeroFlightDirection.push
          ? animation.value
          : 1.0 - animation.value;
      // [LAYOUT_PLAN P4] 圆角 4→12 过渡
      final radius = 4.0 + (12.0 - 4.0) * t;
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      );
    },
    child: fromHero.child,
  );
}

class _CoverImage extends ConsumerStatefulWidget {
  final String coverUrl;
  final double width;
  final String? sourceOrigin;
  final String? sourceJson;
  final Widget placeholder;

  /// 图片加载完成后上报原图宽高比（宽/高；解析失败为 null）
  final ValueChanged<double>? onAspectRatio;

  const _CoverImage({
    required this.coverUrl,
    required this.width,
    required this.placeholder,
    this.sourceOrigin,
    this.sourceJson,
    this.onAspectRatio,
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
      unawaited(_reportBytesRatio(cached, url, gen));
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
        unawaited(_reportBytesRatio(bytes, url, gen));
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

  /// 从解码字节上报原图比例（仅读文件头，不做完整解码）
  Future<void> _reportBytesRatio(Uint8List bytes, String url, int gen) async {
    final ratio = await decodeImageAspectRatio(bytes);
    if (!mounted || gen != _loadGen || widget.coverUrl != url) return;
    if (ratio != null) widget.onAspectRatio?.call(ratio);
  }

  /// 从已解析的 ImageProvider 上报原图比例（imageBuilder 内调度，
  /// 避免在 build 期间触发 setState）
  void _reportProviderRatio(ImageProvider provider) {
    if (!mounted) return;
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        final height = info.image.height;
        if (height > 0) {
          widget.onAspectRatio?.call(info.image.width / height);
        }
      },
      onError: (_, _) => stream.removeListener(listener),
    );
    stream.addListener(listener);
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
      // 图片就绪后（后帧）上报原图比例：关闭「限制封面比例」时据此自适应高度
      imageBuilder: (context, imageProvider) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _reportProviderRatio(imageProvider);
        });
        return Image(
          image: imageProvider,
          fit: BoxFit.cover,
          width: widget.width,
          gaplessPlayback: true,
        );
      },
    );
  }
}
