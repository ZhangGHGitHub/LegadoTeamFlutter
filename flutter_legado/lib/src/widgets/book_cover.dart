import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/cover_settings.dart';
import '../providers/cover_settings/cover_settings_notifier.dart';
import '../providers/providers.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../services/cover_aspect_ratio.dart';
import '../services/cover_decode_loader.dart';
import '../services/cover_disk_cache.dart';
import '../services/network_status_service.dart';
import '../utils/comic_image_utils.dart';
import '../utils/cover_local_path.dart';
import 'cover_text_painter.dart';

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

  /// 书名（设置批6b-1：默认封面 / 加载占位 / 加载失败时绘制文字）
  ///
  /// 网络封面加载成功时不绘制；仅默认封面路径使用（对齐参考版
  /// `CoilBookCover` 的 `CoverTextOverlay`）。
  final String? bookName;

  /// 作者（同一绘制条件；书名关闭时不绘制）
  final String? bookAuthor;

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
    this.bookName,
    this.bookAuthor,
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
  /// [ignoreAspectRatio] 为 true 时（总是默认封面 / 无网络地址）不采用
  /// 网络封面比例，保持调用方声明高度。
  double _displayHeight(bool restrict, {bool ignoreAspectRatio = false}) {
    if (ignoreAspectRatio || !widget.adaptAspectRatio || restrict) {
      return widget.height;
    }
    // [批39 审查回修] 比例未知（尚未解析/缓存未命中）时按调用方声明的
    // 宽高反推自身比例（width/height，等价于保持 height 不变），而不是
    // 固定 5:7——列表形态的封面尺寸（如 45×60）并不等于 5:7，硬套 5:7
    // 会在图未加载完成时先跳一下。
    final fallbackRatio = widget.width > 0 && widget.height > 0
        ? widget.width / widget.height
        : CoverAspectRatio.restricted;
    final ratio =
        _ratio ?? CoverAspectRatio.cached(widget.coverUrl) ?? fallbackRatio;
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
    final result = CoverAspectRatio.rememberDetailed(widget.coverUrl, ratio);
    final value = CoverAspectRatio.cached(widget.coverUrl);
    if (value != null && _ratio != value) {
      if (widget.adaptAspectRatio) {
        setState(() => _ratio = value);
      } else {
        // 非自适应封面只登记比例（供网格/其他入口复用），不触发自身重建
        _ratio = value;
      }
    }
    if (result.changed) {
      // 网格行高随新比例重算（书架/发现页监听该修订号）。[批39 审查回修]
      // 「限制封面比例」开启（默认）时行高固定，逐张封面通知会让整屏
      // 重建；此时只在「首个已知比例」写入时通知一次。
      final restrict = uiSettingsListenable.value.restrictCoverRatio;
      if (shouldNotifyCoverRatioRevision(
        changed: result.changed,
        restrict: restrict,
        firstKnown: result.firstKnown,
      )) {
        coverAspectRatioRevision.value++;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 封面设置（批6b-1）：默认封面文字/日夜/描边阴影/仅 WiFi/比例。
    // 与批39 相同，经全局 ValueListenable 读取，不要求 ProviderScope。
    // [审查 P3] 仅在需要自适应比例时才订阅 UiSettings，避免任意 UI 设置
    // 变化重建全部封面；封面设置订阅始终存在（文字/描边/仅 WiFi）。
    return ValueListenableBuilder<CoverSettings>(
      valueListenable: coverSettingsListenable,
      builder: (context, cover, _) {
        if (!widget.adaptAspectRatio) {
          return _buildCover(context, widget.height, cover);
        }
        return ValueListenableBuilder<UiSettingsState>(
          valueListenable: uiSettingsListenable,
          builder: (context, ui, _) {
            final hasUrl =
                widget.coverUrl != null && widget.coverUrl!.isNotEmpty;
            // 总是默认封面/本地文件时忽略网络封面比例（保持调用方声明尺寸）
            final defaultOnly = !hasUrl ||
                cover.useDefaultCover ||
                isLocalCoverUrl(widget.coverUrl);
            final height = _displayHeight(
              ui.restrictCoverRatio,
              ignoreAspectRatio: defaultOnly,
            );
            return _buildCover(context, height, cover);
          },
        );
      },
    );
  }

  /// 本地封面解码宽度（与网络封面缩略策略一致）
  int _thumbWidth(BuildContext context) {
    final ratio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return (widget.width * ratio).round().clamp(1, 512);
  }

  Widget _buildCover(BuildContext context, double height, CoverSettings cover) {
    final hasUrl = widget.coverUrl != null && widget.coverUrl!.isNotEmpty;
    // [设备回归 P2-1] 本地换封面：识别绝对路径/file://，直接 Image.file；
    // 文件缺失回落默认封面；不查仅 WiFi、不写网络缓存。
    final localPath = localCoverFilePath(widget.coverUrl);
    final localFile = localPath == null ? null : File(localPath);
    final hasLocalFile = localFile != null && localFile.existsSync();
    final showLocal = hasLocalFile && !cover.useDefaultCover;
    final showNetwork =
        localPath == null && hasUrl && !cover.useDefaultCover;
    final isNight = Theme.of(context).brightness == Brightness.dark;
    final defaultCover = _buildDefaultCover(context, height, cover, isNight);

    Widget inner = defaultCover;
    if (showLocal) {
      inner = Image.file(
        localFile,
        fit: BoxFit.cover,
        width: widget.width,
        cacheWidth: _thumbWidth(context),
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => defaultCover,
      );
    } else if (showNetwork) {
      inner = _CoverImage(
        coverUrl: widget.coverUrl!,
        width: widget.width,
        sourceOrigin: widget.sourceOrigin,
        sourceJson: widget.sourceJson,
        placeholder: defaultCover,
        loadOnlyOnWifi: cover.loadOnlyOnWifi,
        onAspectRatio: _reportRatio,
      );
    }

    // [审查 P3] 根节点结构固定，仅 boxShadow 条件变化：避免开关阴影时
    // 重建 _CoverImage（网络封面重新加载/占位闪烁）。
    Widget coverWidget = DecoratedBox(
      key: const ValueKey('bookCoverShadow'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: cover.showShadow
            // 参考版 CoilBookCover：Modifier.shadow(4.dp, shape)
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.32),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: SizedBox(width: widget.width, height: height, child: inner),
      ),
    );
    final tag = widget.heroTag;
    if (tag != null && tag.isNotEmpty) {
      // [LAYOUT_PLAN P4] 内置 Hero 保持无 flightShuttle（防与外层 Hero 嵌套）。
      coverWidget = Hero(tag: tag, child: coverWidget);
    }
    return coverWidget;
  }

  /// 默认封面（对标原版 image_cover_default.jpg）
  ///
  /// 无封面 / 加载中 / 加载失败 / 总是默认封面时显示：
  /// - 日间：内置纸纹封面图；
  /// - 夜间：同一图 + 暗色叠层（参考版独立的日/夜图集素材属 6b-2，
  ///   本期无夜间素材，登记为色调占位）；
  /// - 书名 / 作者：见 [CoverTextPainter]（竖排/横排/描边/阴影/日夜）。
  Widget _buildDefaultCover(
    BuildContext context,
    double height,
    CoverSettings cover,
    bool isNight,
  ) {
    final layout = computeCoverTextLayout(
      size: Size(widget.width, height),
      name: widget.bookName,
      author: widget.bookAuthor,
      settings: cover,
      isNight: isNight,
      defaultColor: Theme.of(context).colorScheme.secondary.toARGB32(),
    );
    return Stack(
      key: const ValueKey('bookCoverDefault'),
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/default_book_cover.jpg',
          fit: BoxFit.cover,
          width: widget.width,
          height: height,
        ),
        if (isNight)
          const Positioned.fill(
            child: ColoredBox(
              key: ValueKey('bookCoverDefaultNight'),
              // 无独立夜间素材（登记）：暗色叠层压低纸面亮度、保留纹理
              color: Color(0xCC15161A),
            ),
          ),
        if (layout.hasText)
          Positioned.fill(
            child: CustomPaint(
              key: const ValueKey('bookCoverText'),
              painter: CoverTextPainter(layout),
            ),
          ),
      ],
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

  /// 仅 WiFi 加载（封面设置批6b-1）：蜂窝网络时跳过加载并显示占位
  ///（不写解密/图片缓存），恢复 WiFi 后定时重试。
  final bool loadOnlyOnWifi;

  /// 图片加载完成后上报原图宽高比（宽/高；解析失败为 null）
  final ValueChanged<double>? onAspectRatio;

  const _CoverImage({
    required this.coverUrl,
    required this.width,
    required this.placeholder,
    this.sourceOrigin,
    this.sourceJson,
    this.loadOnlyOnWifi = false,
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

  /// 蜂窝网络 + 仅 WiFi → 阻塞网络封面（显示占位，不写缓存）
  bool _wifiBlocked = false;
  Timer? _wifiRetryTimer;

  /// 有效磁盘缓存命中（审查 R-P2-1）：直接渲染该文件，跳过网络/FFI
  String? _directCachePath;

  /// 阻塞期间的重试间隔（恢复 WiFi 后自动加载）
  static const Duration _wifiRetryInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    unawaited(_startLoad());
  }

  @override
  void dispose() {
    _loadGen++;
    _wifiRetryTimer?.cancel();
    _wifiRetryTimer = null;
    _ticket?.cancel();
    _ticket = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl ||
        oldWidget.sourceOrigin != widget.sourceOrigin ||
        oldWidget.sourceJson != widget.sourceJson ||
        oldWidget.loadOnlyOnWifi != widget.loadOnlyOnWifi) {
      _ticket?.cancel();
      _ticket = null;
      _wifiRetryTimer?.cancel();
      _wifiRetryTimer = null;
      _wifiBlocked = false;
      _directCachePath = null;
      _decodedBytes = null;
      _decodeFailed = false;
      _useDirect = false;
      unawaited(_startLoad());
    }
  }

  /// 蜂窝网络下延迟重试（forceRefresh 绕过服务端短时缓存）
  void _scheduleWifiRetry() {
    _wifiRetryTimer?.cancel();
    _wifiRetryTimer = Timer(_wifiRetryInterval, () {
      if (!mounted || !_wifiBlocked) return;
      unawaited(_startLoad(forceRefreshNetwork: true));
    });
  }

  Future<void> _startLoad({bool forceRefreshNetwork = false}) async {
    final gen = ++_loadGen;
    final origin = widget.sourceOrigin?.trim() ?? '';
    final url = widget.coverUrl;
    _directCachePath = null;

    // 1) 内存缓存命中：立即显示，不占并发槽（[审查 P2-1] 必须在仅 WiFi
    // 门控之前：蜂窝下已解密/已加载的封面应继续显示，不能因网络状态变空）
    final cached = CoverDecodeLoader.getCached(origin, url);
    if (cached != null) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _decodedBytes = cached;
        _directCachePath = null;
        _loadingDecode = false;
        _useDirect = false;
        _decodeFailed = false;
      });
      unawaited(_reportBytesRatio(cached, url, gen));
      return;
    }

    // 2) 仅 WiFi：直连封面先查「有效」磁盘缓存（validTill 未过期且文件
    // 存在）。命中直接用 Image.file 渲染并 return——不查询 WiFi、不进 FFI，
    // 避免过期/删除缓存绕过后由 CachedNetworkImage 重新下载。
    if (widget.loadOnlyOnWifi) {
      final cachedFile =
          await CoverDiskCache.validFile(stripCompositeImageUrl(url));
      if (!mounted || gen != _loadGen) return;
      if (cachedFile != null) {
        setState(() {
          _directCachePath = cachedFile.path;
          _decodedBytes = null;
          _loadingDecode = false;
          _useDirect = false;
          _decodeFailed = false;
          _wifiBlocked = false;
        });
        return;
      }
      final wifi = await NetworkStatusService.instance.isWifi(
        forceRefresh: forceRefreshNetwork,
      );
      if (!mounted || gen != _loadGen) return;
      if (!wifi) {
        setState(() {
          _wifiBlocked = true;
          _directCachePath = null;
          _loadingDecode = false;
          _useDirect = false;
          _decodeFailed = false;
          _decodedBytes = null;
        });
        _scheduleWifiRetry();
        return;
      }
    }
    if (_wifiBlocked) {
      _wifiBlocked = false;
      _wifiRetryTimer?.cancel();
      _wifiRetryTimer = null;
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

      // [审查 R-P2-1] FFI 解密会发起网络请求：进入前按最新网络状态重查
      // 仅 WiFi（书源解析期间网络可能已从 WiFi 切到蜂窝）。
      if (widget.loadOnlyOnWifi) {
        final wifi = await NetworkStatusService.instance.isWifi(
          forceRefresh: true,
        );
        if (!mounted || gen != _loadGen) return;
        if (!wifi) {
          setState(() {
            _wifiBlocked = true;
            _loadingDecode = false;
            _decodeFailed = false;
          });
          _scheduleWifiRetry();
          return;
        }
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
    listener = ImageStreamListener((info, _) {
      stream.removeListener(listener);
      final height = info.image.height;
      if (height > 0) {
        widget.onAspectRatio?.call(info.image.width / height);
      }
    }, onError: (_, _) => stream.removeListener(listener));
    stream.addListener(listener);
  }

  int _thumbWidth(BuildContext context) {
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    return (widget.width * pixelRatio).round().clamp(1, 512);
  }

  /// 是否需要从已解析的 ImageProvider 读取原图比例
  ///
  /// [批39 审查回修] `imageBuilder` 每次 build 都会重新执行：无条件
  /// post-frame resolve 会反复注册 ImageStream 监听（列表滚动/主题切换
  /// 每次重建都多一次）。缓存里已有比例时直接跳过（BookCover 自身
  /// `_ratio` 与缓存同源，缓存命中即无需再解析）。
  bool get _needsProviderRatio =>
      CoverAspectRatio.cached(widget.coverUrl) == null;

  @override
  Widget build(BuildContext context) {
    final directCachePath = _directCachePath;
    if (directCachePath != null) {
      // [审查 R-P2-1] 有效磁盘缓存直接渲染：不查询 WiFi、不走 FFI/网络
      return Image.file(
        File(directCachePath),
        fit: BoxFit.cover,
        width: widget.width,
        cacheWidth: _thumbWidth(context),
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.placeholder,
      );
    }
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
    if (_wifiBlocked) {
      // 蜂窝 + 仅 WiFi：显示占位（默认封面 + 书名/作者），不发起网络请求
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
      // 图片就绪后（后帧）上报原图比例：关闭「限制封面比例」时据此自适应高度。
      // [批39 审查回修] 仅在比例未知（缓存无命中）时调度，避免每次 build
      // 重复 resolve 注册监听。
      imageBuilder: (context, imageProvider) {
        if (_needsProviderRatio) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _reportProviderRatio(imageProvider);
          });
        }
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
