import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/rss/rss_notifier.dart';
import '../providers/rss_history/rss_history_notifier.dart';
import '../providers/rss_read_record_pref_notifier.dart';
import '../services/bridge_http.dart';
import '../services/platform_bridge_service.dart';
import '../services/rss_header.dart';
import '../utils/error_message.dart';
import '../utils/image_data_uri.dart';
import '../utils/rss_read_record.dart';
import '../widgets/custom_refresh_indicator.dart'; // [LAYOUT_PLAN P4] 下拉 M3 化
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import 'rss_article_detail_screen.dart';
import 'rss_source_edit_screen.dart';
import 'source_login_screen.dart';
import 'video_screen.dart';

/// 打开 RSS 文章（按 `type` 分流，对齐 `ReadRss.kt:48-98`）
///
/// - `type == 2`（视频）：打开 [VideoScreen] 播放文章链接；
/// - `type == 1`（图片）：全屏图片查看（缩放/保存）；源配置 `ruleContent`
///   时先抓正文并把结果按文章链接绝对化为图片地址（对齐 `readNoHtml`）；
/// - 其余（0/未知）：进入 [RssArticleDetailScreen]（WebView 阅读链）。
///
/// 类型优先级：文章 `type`（列表规则解析已复制源 `type`）→ 源 `type`。
Future<void> openRssArticle(
  BuildContext context,
  WidgetRef ref, {
  required RssFeedArticle article,
  RssSource? source,
  String sourceName = '',
  String sourceUrl = '',
  void Function(String description)? onContentFetched,
}) async {
  // 空串 / legacy: 伪主键视为无链接：不触发正文抓取、不发起外链
  final article0 = article;
  final readable = hasRssArticleLink(article0.url)
      ? article0
      : RssFeedArticle(
          title: article0.title,
          url: '',
          sort: article0.sort,
          description: article0.description,
          pubDate: article0.pubDate,
          imageUrl: article0.imageUrl,
          content: article0.content,
          type: article0.type,
        );
  final type = resolveRssArticleType(
    articleType: readable.type,
    sourceType: source?.rssType,
  );
  if (type == 2) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoScreen(
          videoUrl: readable.url,
          title: readable.title,
        ),
      ),
    );
    return;
  }
  if (type == 1) {
    final imageUrl =
        await _resolveRssImageUrl(ref, readable, source, sourceUrl);
    if (!context.mounted) return;
    await showRssPhotoViewer(
      context,
      url: imageUrl,
      title: readable.title,
      headers: parseRssHeaderMap(source?.header),
    );
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => RssArticleDetailScreen(
        article: readable,
        source: source,
        sourceName: sourceName,
        sourceUrl: sourceUrl,
        onContentFetched: onContentFetched,
      ),
    ),
  );
}

/// 图片源地址解析（对齐 `ReadRss.readNoHtml`）
///
/// `ruleContent` 非空时先抓正文，正文即图片地址（相对地址按文章链接
/// 绝对化，对齐 `NetworkUtils.getAbsoluteURL(link, body)`）；抓取失败/
/// 正文为空回退文章链接本身。
Future<String> _resolveRssImageUrl(
  WidgetRef ref,
  RssFeedArticle article,
  RssSource? source,
  String sourceUrl,
) async {
  final rule = source?.ruleContent?.trim() ?? '';
  if (rule.isEmpty || sourceUrl.isEmpty || article.url.isEmpty) {
    return article.url;
  }
  try {
    final body = await ref.read(bookApiProvider).rssFetchContent(
          sourceUrl,
          article.url,
          sort: article.sort.isEmpty ? null : article.sort,
        );
    final trimmed = body.trim();
    if (trimmed.isEmpty) return article.url;
    return _absoluteAgainst(article.url, trimmed);
  } catch (e) {
    debugPrint('[RSS] 图片源正文抓取失败，回退文章链接: $e');
    return article.url;
  }
}

/// 相对地址绝对化（对齐 `NetworkUtils.getAbsoluteURL(base, value)` 常用分支）
///
/// data: URI 自带 scheme 且体积可能很大，直接原样返回（不参与 URI 解析）。
String _absoluteAgainst(String baseUrl, String value) {
  if (isDataUri(value)) return value;
  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme) return value;
  final base = Uri.tryParse(baseUrl);
  if (base == null || !base.hasScheme) return value;
  if (value.startsWith('//')) return '${base.scheme}:$value';
  return base.resolve(value).toString();
}

/// 全屏图片查看（对齐原版 `PhotoDialog`：缩放 + 保存）
Future<void> showRssPhotoViewer(
  BuildContext context, {
  required String url,
  String title = '',
  Map<String, String> headers = const {},
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (_) => RssPhotoViewer(url: url, title: title, headers: headers),
  );
}

/// 图片保存动作：返回提示文案；null 表示无需提示（已取消/已关闭）
typedef RssPhotoSaver = Future<String?> Function(
  Uint8List bytes,
  String fileName,
);

/// RSS 图片保存分派（D1 回修 P2-4，可注入测试）
///
/// - Android（[useMediaStore]）：MediaStore Downloads 直写；返回 null
///   （通道不可用/API < 29/写入被拒）时**禁止回退
///   `FilePicker.platform.saveFile(bytes:)`**——该链路会在 onActivityResult
///   内裸写 SAF URI，命中原始崩溃路径且 Future 可能永久挂起；改为写应用
///   文档目录并明确提示完整路径（对齐 reader_comic_screen 既有做法）。
/// - iOS/桌面：file_picker 系统另存（必须传 bytes）；用户取消时写文档目录
///   兜底（保持既有语义）。
///
/// 返回提示文案；保存动作可被页面关闭/取消打断（调用方检查 mounted）。
@visibleForTesting
Future<String?> saveRssImageBytes({
  required Uint8List bytes,
  required String fileName,
  bool? useMediaStore,
  Future<String?> Function(String fileName, Uint8List bytes)? saveToDownloads,
  Future<String?> Function(String fileName, Uint8List bytes)? pickSaveFile,
  Future<Directory> Function()? documentsDirectory,
}) async {
  final mediaStore =
      useMediaStore ?? PlatformBridgeService.instance.useMediaStoreDownloads;
  final docsDir = documentsDirectory ?? getApplicationDocumentsDirectory;

  if (mediaStore) {
    final downloads = saveToDownloads ??
        (name, data) =>
            PlatformBridgeService.instance.saveImageToDownloads(name, data);
    final saved = await downloads(fileName, bytes);
    if (saved != null) return '已保存: $saved';
    // [D1 回修] Android 禁止回退 file_picker：直接写应用文档目录并提示位置
    final dir = await docsDir();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName')
      ..writeAsBytesSync(bytes, flush: true);
    return '已保存到文档目录: ${file.path}';
  }

  final picker = pickSaveFile ??
      (name, data) => FilePicker.platform.saveFile(
            dialogTitle: '保存图片',
            fileName: name,
            bytes: data,
          );
  final path = await picker(fileName, bytes);
  if (path != null) {
    final file = File(path)..writeAsBytesSync(bytes);
    return '已保存: ${file.path}';
  }
  // iOS/桌面取消选择 → 文档目录兜底（既有行为）
  final dir = await docsDir();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName')
    ..writeAsBytesSync(bytes);
  return '已保存到文档目录: ${file.path}';
}

/// 全屏图片查看器（`InteractiveViewer` 缩放 + MediaStore/文件选择器保存）
class RssPhotoViewer extends ConsumerStatefulWidget {
  const RssPhotoViewer({
    super.key,
    required this.url,
    this.title = '',
    this.headers = const {},
    this.fetchBytes,
    this.saver,
  });

  final String url;
  final String title;
  final Map<String, String> headers;

  /// 测试注入：抓取图片字节（默认经 Bridge HTTP）
  @visibleForTesting
  final Future<Uint8List> Function()? fetchBytes;

  /// 测试注入：保存动作（默认走 [saveRssImageBytes] 真实分派）
  @visibleForTesting
  final RssPhotoSaver? saver;

  /// 测试注入：data: URI 解码器（默认在 isolate 中解码，避免阻塞首帧）
  ///
  /// 桌面测试宿主无法稳定等待真实 isolate，用例注入同步实现。
  @visibleForTesting
  static Future<RssDataUriImage?> Function(String url)? debugDataUriDecoderOverride;

  @override
  ConsumerState<RssPhotoViewer> createState() => _RssPhotoViewerState();
}

/// isolate 解码入口（`compute` 要求顶层/静态函数）
RssDataUriImage? _decodeDataUriIsolateEntry(String url) =>
    parseImageDataUri(url);

class _RssPhotoViewerState extends ConsumerState<RssPhotoViewer> {
  bool _saving = false;

  /// 当前地址是否为 data: URI（批19 审查 P2-1：initState 缓存，避免每帧判定）
  bool _isDataUri = false;

  /// data: URI 解码结果（批15g③；非 data: URI 为 null）
  ///
  /// 对齐原版 `ReadRssViewModel.webData2bitmap`（`ReadRssViewModel.kt:248-256`）：
  /// 图片地址不是合法 URL 时按 base64 data URI 处理，不走网络下载。
  RssDataUriImage? _dataImage;

  /// data: URI 解码失败原因（UI 直接展示，不崩溃）
  String? _dataError;

  /// 是否正在异步解码（批19 审查 P2-3：isolate 解码 + loading 态）
  bool _isDecoding = false;

  /// 解码请求序号（[didUpdateWidget] 换 url 时丢弃过期结果）
  int _decodeSeq = 0;

  /// 进行中的解码 Future（保存时若尚未完成则等待）
  Future<RssDataUriImage?>? _decodeFuture;

  @override
  void initState() {
    super.initState();
    _isDataUri = isDataUri(widget.url);
    if (_isDataUri) _startDataDecode();
  }

  @override
  void didUpdateWidget(covariant RssPhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 批19 审查 P3-5：同一 State 复用（同 key 换 url）时重算，避免展示旧图
    if (oldWidget.url == widget.url) return;
    _isDataUri = isDataUri(widget.url);
    _dataImage = null;
    _dataError = null;
    _decodeFuture = null;
    _isDecoding = false;
    _decodeSeq++;
    if (_isDataUri) _startDataDecode();
  }

  /// 异步解码 data: URI（批19 审查 P2-3：不阻塞首帧）
  void _startDataDecode() {
    final seq = ++_decodeSeq;
    _isDecoding = true;
    _dataImage = null;
    _dataError = null;
    final decoder =
        RssPhotoViewer.debugDataUriDecoderOverride ?? _decodeDataUriInIsolate;
    final future = decoder(widget.url);
    _decodeFuture = future;
    unawaited(
      future.then<void>(
        (image) {
          if (!mounted || seq != _decodeSeq) return;
          setState(() {
            _isDecoding = false;
            _dataImage = image;
          });
        },
        onError: (Object e) {
          if (!mounted || seq != _decodeSeq) return;
          setState(() {
            _isDecoding = false;
            _dataError = e is ImageDataUriException ? e.message : '$e';
          });
        },
      ),
    );
  }

  /// 默认解码器：isolate 中执行 base64 解码（结果/异常经 compute 回传）
  static Future<RssDataUriImage?> _decodeDataUriInIsolate(String url) =>
      compute(_decodeDataUriIsolateEntry, url);

  /// 图片后缀（data: URI 按 MIME；其余按 URL 末段 1-5 位字母数字，否则 jpg）
  String _suffix() {
    if (_isDataUri) {
      return _dataImage?.extension ?? '.jpg';
    }
    final path = Uri.tryParse(widget.url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot >= 0 && dot < path.length - 1) {
      final suffix = path.substring(dot + 1);
      if (RegExp(r'^[A-Za-z0-9]{1,5}$').hasMatch(suffix)) return '.$suffix';
    }
    return '.jpg';
  }

  /// 抓取图片字节（测试可注入，避免依赖真实网络/FFI）
  ///
  /// data: URI 直接返回解码字节（批15g③），不发起网络请求；解码失败
  /// 抛 [ImageDataUriException]，由保存链给出明确错误提示。
  Future<Uint8List> _fetchBytes() async {
    final override = widget.fetchBytes;
    if (override != null) return override();
    if (_isDataUri) {
      var image = _dataImage;
      if (image == null && _decodeFuture != null) {
        try {
          image = await _decodeFuture;
        } on ImageDataUriException {
          rethrow;
        } catch (e) {
          throw ImageDataUriException('$e');
        }
      }
      if (image != null) return image.bytes;
      throw ImageDataUriException(_dataError ?? '图片数据无效');
    }
    final api = ref.read(bookApiProvider);
    final data = await bridgeHttpGetBytes(
      api,
      widget.url,
      headers: widget.headers.isEmpty ? null : widget.headers,
    );
    if (data.statusCode < 200 || data.statusCode >= 300) {
      throw Exception('HTTP ${data.statusCode}');
    }
    if (data.bytes.isEmpty) {
      throw Exception('图片为空');
    }
    return data.bytes;
  }

  /// 保存图片（平台分派见 [saveRssImageBytes]）
  ///
  /// 对话框被关闭（mounted=false）后不再弹提示，避免「关闭后仍提示」。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final bytes = await _fetchBytes();
      if (!mounted) return;
      final fileName =
          'rss-${DateTime.now().millisecondsSinceEpoch}${_suffix()}';
      final saver = widget.saver ??
          (data, name) => saveRssImageBytes(bytes: data, fileName: name);
      final message = await saver(bytes, fileName);
      if (!mounted || message == null) return;
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text('保存图片失败：${errorMessage(e)}')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 图片主体（data: URI 走 [Image.memory]，其余走网络加载）
  ///
  /// 批15g③：data: URI 不发起网络请求；解码失败显示明确错误文案。
  /// 批19 审查 P2-3：解码期间显示 loading，不阻塞首帧。
  Widget _buildImageViewer(BuildContext context) {
    if (_isDataUri) {
      if (_isDecoding) {
        return const Center(child: CircularProgressIndicator());
      }
      final image = _dataImage;
      if (image == null) {
        return Center(
          child: Text(
            _dataError ?? '图片数据无效',
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        );
      }
      // 批19 审查 P3-2：Flutter 的 Image.memory 不能渲染 SVG，明确提示
      // 不支持直接查看，但仍允许右上角保存为 `.svg`（保留原始 MIME 后缀）
      if (image.mimeType == 'image/svg+xml') {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '当前平台不支持直接查看 SVG 图片，可点击右上角保存',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return Image.memory(
        image.bytes,
        fit: BoxFit.contain,
        // 批19 审查 P2-2：按屏幕显示宽度 × dpr 解码，避免大图解码后
        // 占用数百 MB 内存
        // 批19 终版收口 P3-6：查看器可经 InteractiveViewer 放大，按
        // **2× 屏宽** 解码（放大到 2× 仍清晰）；再按 maxScale=5 解码
        // 内存为 2× 口径的 6.25 倍且收益有限，故取 2× 折中。
        cacheWidth: _decodeWidth(context),
        errorBuilder: (_, _, _) => const Center(
          child: Text(
            '图片加载失败',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: widget.url,
      fit: BoxFit.contain,
      // 批19 终版收口 P3-6：网络路径与 data URI 路径统一解码口径
      // （2× 屏宽 × dpr），避免放大后网络图比 data 图更糊。
      memCacheWidth: _decodeWidth(context),
      httpHeaders: widget.headers.isEmpty ? null : widget.headers,
      placeholder: (_, _) => const Center(
        child: CircularProgressIndicator(),
      ),
      errorWidget: (_, _, _) => const Center(
        child: Text(
          '图片加载失败',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  /// 解码目标宽度（屏幕显示宽度 × 设备像素比 × 2）
  ///
  /// 批19 终版收口 P3-6：查看器最大缩放 5×，按 5× 解码内存会涨到 2× 口径
  /// 的 6.25 倍；取 **2× 屏宽** 兼顾放大清晰度与内存（网络/data 两条路径
  /// 同口径）。如后续要求 5× 全清晰，需同步评估大图内存峰值。
  int _decodeWidth(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    final width = media?.size.width ?? 400;
    final ratio = media?.devicePixelRatio ?? 1.0;
    return (width * ratio * 2).round();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Center(child: _buildImageViewer(context)),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: '关闭',
                  ),
                  Flexible(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download, color: Colors.white),
                tooltip: '保存图片',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// RSS 文章列表页面
///
/// 批15d：分类 Tab / 触底加载更多 / 搜索入口收敛（对齐原版
/// `RssSortActivity` + `RssArticlesFragment`，视觉对齐参考版 `RssSortScreen`
/// 的顶栏 TabRow 形态）。本页只渲染 [RssState] 与派发命令，分类解析、
/// 翻页判底、写库等业务全部在 Rust（契约 §2.5）。
class RssArticlesScreen extends ConsumerStatefulWidget {
  final RssSource source;

  /// 初始分类覆盖值（批15f，对应原版
  /// `RssSortActivity.start(context, sortUrl, sourceUrl)`）
  ///
  /// 非空时经 `rssSortUrls(sortUrl:)` 解析（JSON `{name:url}` / 非 JSON
  /// 单条）；当前无 JS `sort` 动作调用方，参数就绪、动作接线随后续。
  final String? initialSortUrl;

  const RssArticlesScreen({
    super.key,
    required this.source,
    this.initialSortUrl,
  });

  @override
  ConsumerState<RssArticlesScreen> createState() => _RssArticlesScreenState();
}

class _RssArticlesScreenState extends ConsumerState<RssArticlesScreen>
    with TickerProviderStateMixin {
  final Set<String> _readArticles = {};

  /// 源静态请求头（批15f：列表/网格封面图防盗链，复用既有 header 解析）
  ///
  /// 动态 `@js:` header 不解析（Dart 无 JS 引擎，登记 15g）。
  late final Map<String, String> _imageHeaders =
      parseRssHeaderMap(widget.source.header);

  /// 详情页规则正文抓取成功后的内存回填（审查 P2-7）
  ///
  /// Rust `rssFetchContent` 已把正文写回 `rssArticles.description`，但列表页
  /// 当前无「只读 DB」FFI（`getRssArticles` 是网络刷新，会用 feed 摘要
  /// REPLACE 覆盖刚抓到的正文），故由详情页回调把正文带回列表内存态；
  /// 返回列表立即可见，DB 仍是真源（列表页 DB-only 查询改挂后续批次，
  /// 批15d 审查 P2-7）。
  final Map<String, String> _fetchedDescriptions = {};

  // [UI-fix v2.0.2 | 2026-08-06] 布局切换本地态（对标原版 articleStyle 0-4
  // 循环；Flutter 端支持两种渲染：0=列表，其他=双列网格） — Qoder
  late int _articleStyle = widget.source.articleStyle;

  /// 分类 Tab 控制器（分类数变化时重建；对齐 bookshelf 分组 Tab 做法）
  TabController? _tabController;
  int _tabControllerLength = 0;

  /// 列表滚动控制器（触底自动加载更多）
  final ScrollController _scrollController = ScrollController();

  /// 已触发首屏自动加载的列表签名（分类|关键词|条数）
  ///
  /// 首屏不足一屏时不会产生滚动事件，需要布局完成后主动做一次阈值判断
  /// （对齐参考版 LoadMoreDetector 的初始发射）；签名避免同一列表状态
  /// 被重复发射，失败时由 [RssState.loadMoreFailed] 门控（审查 P1-2/P2-1）。
  int? _autoLoadSignature;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 加载分类与文章（批15f：透传初始 sortUrl 覆盖值）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssNotifierProvider.notifier).selectSource(
            widget.source,
            sortUrl: widget.initialSortUrl,
          );
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _tabController?.removeListener(_onTabControllerChanged);
    _tabController?.dispose();
    super.dispose();
  }

  // ===== 分类 Tab =====

  /// 按分类数量维护 TabController（分类数变化时重建）
  TabController _ensureTabController(int length) {
    if (_tabController == null || _tabControllerLength != length) {
      _tabController?.removeListener(_onTabControllerChanged);
      _tabController?.dispose();
      _tabController = TabController(length: length, vsync: this);
      _tabController!.addListener(_onTabControllerChanged);
      _tabControllerLength = length;
    }
    return _tabController!;
  }

  /// Tab 切换 → 通知分类选择（对齐原版 ViewPager.onPageSelected）
  void _onTabControllerChanged() {
    final controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    final state = ref.read(rssNotifierProvider);
    if (state.isSearching || state.sorts.length <= 1) return;
    if (controller.index >= state.sorts.length) return;
    final sort = state.sorts[controller.index];
    if (state.currentSort != sort) {
      ref.read(rssNotifierProvider.notifier).selectSort(sort);
    }
  }

  /// 状态选中分类 → 帧后同步到 TabController（避免 build 期间改动）
  void _syncTabControllerIndex(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _tabController;
      if (!mounted || controller == null) return;
      if (controller.index != index && index < controller.length) {
        controller.animateTo(index);
      }
    });
  }

  /// 分类 Tab 行（单分类时隐藏，对齐原版 `upFragmentsView` 的 gone 分支）
  PreferredSizeWidget? _buildSortTabs(RssState state) {
    final sorts = state.sorts;
    if (sorts.length <= 1) return null;
    final controller = _ensureTabController(sorts.length);
    _syncTabControllerIndex(_currentSortIndex(state));
    final colorScheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context)
        .textTheme
        .labelLarge
        ?.copyWith(fontWeight: FontWeight.w500);
    return PreferredSize(
      preferredSize: const Size.fromHeight(48),
      child: SizedBox(
        width: double.infinity,
        child: TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.only(left: 12),
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          dividerColor: Colors.transparent,
          dividerHeight: 0,
          labelColor: colorScheme.primary,
          unselectedLabelColor: colorScheme.onSurfaceVariant,
          labelStyle: labelStyle,
          unselectedLabelStyle: labelStyle,
          tabs: [
            for (final sort in sorts)
              Tab(text: sort.name.isEmpty ? '默认' : sort.name),
          ],
        ),
      ),
    );
  }

  int _currentSortIndex(RssState state) {
    final current = state.currentSort;
    if (current == null) return 0;
    final index = state.sorts.indexOf(current);
    return index < 0 ? 0 : index;
  }

  // ===== 加载更多 =====

  /// 触底触发阈值（像素）
  ///
  /// 普通源距底 240dp 触发；`preload` 源（对齐 `RssArticlesFragment.kt`
  /// `isPreload`）提前到「距底 5 项」——按当前平均项高折算，下限沿用 240dp，
  /// 上限 1200dp 防止超长列表一次预取过多。参考版阈值 3/5。
  double _loadMoreTriggerPixels(RssState state) {
    if (!widget.source.preload) return 240;
    if (!_scrollController.hasClients || state.articles.isEmpty) return 240;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) return 240;
    final averageExtent =
        position.maxScrollExtent / state.articles.length;
    return (averageExtent * 5).clamp(240, 1200).toDouble();
  }

  /// 触底检测：距底部阈值内触发加载下一页（通知器内部幂等防重）
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final threshold = _loadMoreTriggerPixels(ref.read(rssNotifierProvider));
    if (position.pixels >= position.maxScrollExtent - threshold) {
      ref.read(rssNotifierProvider.notifier).loadMore();
    }
  }

  /// 首屏/列表增长后的补一次触底判断（纯滚动触发在不足一屏时失效）
  ///
  /// `maxScrollExtent <= 0` 时视口未填满，同样命中阈值；加载更多失败后
  /// 由 [RssState.loadMoreFailed] 拦住，等待用户点「重试」。
  void _maybeAutoLoadMore() {
    if (!mounted || !_scrollController.hasClients) return;
    final state = ref.read(rssNotifierProvider);
    if (state.articles.isEmpty ||
        state.isLoadingArticles ||
        state.loadingMore ||
        state.loadMoreFailed ||
        !state.hasMore) {
      return;
    }
    final signature = Object.hash(
      state.currentSort?.name,
      state.key,
      state.articles.length,
    );
    if (_autoLoadSignature == signature) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - _loadMoreTriggerPixels(state)) {
      return;
    }
    _autoLoadSignature = signature;
    ref.read(rssNotifierProvider.notifier).loadMore();
  }

  /// 列表底部加载更多指示（对齐原版 LoadMoreView：加载中 / 已经到底了）
  ///
  /// 审查 P2-1/P2-2：刷新中隐藏 footer；加载更多失败显示错误 + 重试；
  /// 刷新失败同样显示错误态，避免误显「已经到底了~」。
  Widget _buildLoadMoreFooter(RssState state) {
    final theme = Theme.of(context);
    final notifier = ref.read(rssNotifierProvider.notifier);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // 刷新中：旧列表保留，下拉指示器已承担反馈
    if (state.isLoadingArticles) return const SizedBox.shrink();

    if (state.loadMoreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                state.error ?? '加载更多失败',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
            TextButton(
              onPressed: notifier.retryLoadMore,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (state.loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              '加载中…',
              style: labelStyle,
            ),
          ],
        ),
      );
    }

    // 刷新失败（列表保留旧数据）：错误 + 重试，不误显「已经到底了~」
    if (state.error != null && state.articles.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                state.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
            TextButton(
              onPressed: notifier.refreshArticles,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 有下一页时提供可点击兜底（滚动监听失效/不足一屏时仍可手动加载）
    if (state.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: TextButton(
            onPressed: notifier.loadMore,
            child: const Text('加载更多'),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text('已经到底了~', style: labelStyle),
      ),
    );
  }

  // ===== 页面 =====

  /// 顶栏标题（对齐原版 `upFragmentsView`：搜索态显示关键词；
  /// 单分类且分类名非空时显示分类名；否则显示源名）
  String _screenTitle(RssState state) {
    if (state.isSearching) return state.key!;
    final sorts = state.sorts;
    if (sorts.length == 1 && sorts.first.name.isNotEmpty) {
      return sorts.first.name;
    }
    return widget.source.sourceName;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssNotifierProvider);
    final notifier = ref.read(rssNotifierProvider.notifier);
    final hasSearch = (widget.source.searchUrl ?? '').trim().isNotEmpty;

    // 刷新/加载更多失败：列表已有内容时用 SnackBar 提示（空列表由 ErrorView 呈现）
    ref.listen<String?>(rssNotifierProvider.select((s) => s.error),
        (previous, next) {
      if (!mounted || next == null || next == previous) return;
      if (ref.read(rssNotifierProvider).articles.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(next)),
      );
    });

    // 首屏不足一屏时没有滚动事件：布局完成后补一次触底判断
    // （对齐参考版 LoadMoreDetector 初始发射，审查 P1-2）
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoLoadMore());
    // 新一轮刷新开始后允许重新做首屏自动加载判断（列表可能再次不足一屏）
    ref.listen<bool>(
      rssNotifierProvider.select((s) => s.isLoadingArticles),
      (previous, next) {
        if (next) _autoLoadSignature = null;
      },
    );

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    final scaffold = AppScaffold(
      topBar: LegadoAppBar(
        title: Text(_screenTitle(state)),
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios_new_rounded),
          tooltip: state.isSearching ? '退出搜索' : '返回',
          onPressed: () {
            // 对齐原版返回键：搜索态先退出搜索，非搜索态返回列表
            if (state.isSearching) {
              notifier.clearSearch();
              return;
            }
            notifier.clearSelectedSource();
            Navigator.pop(context);
          },
        ),
        // 分类 Tab：单分类隐藏
        bottom: _buildSortTabs(state),
        actions: [
          // 搜索入口：仅源配置 searchUrl 时显示（对齐 RssSortActivity.kt:271-284）
          if (hasSearch)
            IconButton(
              icon: const Icon(Symbols.search_rounded),
              tooltip: '搜索',
              onPressed: _showSearchDialog,
            ),
          IconButton(
            icon: const Icon(Symbols.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => notifier.refreshArticles(),
          ),
          // [UI-fix v2.0.2 | 2026-08-06] 文章列表菜单（对标原版
          // rss_articles.xml：登录/刷新排序/设置源变量/编辑源/切换布局/
          // 阅读记录/清空；搜索入口另位于顶栏） — Qoder
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleMenu,
            itemBuilder: (_) => [
              // 对标原版 onMenuOpened：仅 loginUrl 非空时显示登录
              if ((widget.source.loginUrl ?? '').trim().isNotEmpty)
                const PopupMenuItem(value: 'login', child: Text('登录')),
              const PopupMenuItem(value: 'refreshSort', child: Text('刷新排序')),
              const PopupMenuItem(
                value: 'setVariable',
                child: Text('设置源变量'),
              ),
              const PopupMenuItem(value: 'editSource', child: Text('编辑源')),
              const PopupMenuItem(value: 'switchLayout', child: Text('切换布局')),
              const PopupMenuItem(value: 'readRecord', child: Text('阅读记录')),
              const PopupMenuItem(value: 'clear', child: Text('清空')),
            ],
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (state.isLoadingArticles && state.articles.isEmpty) {
            return const LoadingIndicator(message: '加载文章...');
          }

          if (state.error != null && state.articles.isEmpty) {
            return ErrorView(
              message: state.error!,
              onRetry: () => notifier.refreshArticles(),
            );
          }

          if (state.articles.isEmpty) {
            return const EmptyState(
              icon: Symbols.article_rounded,
              title: '暂无文章',
              subtitle: '下拉刷新获取最新内容',
            );
          }

          // [LAYOUT_PLAN P4] 下拉 M3 化：裸 RefreshIndicator → CustomRefreshIndicator
          return CustomRefreshIndicator(
            onRefresh: () => notifier.refreshArticles(),
            child: _articleStyle == 0
                ? ListView.separated(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    // 末尾附加加载更多指示行（对齐原版 LoadMoreView）
                    itemCount: state.articles.length + 1,
                    // iOS 风格：分隔线从文字列起始处缩进（16 边距 + 80 缩略图 + 12 间距）
                    separatorBuilder: (c, i) => i >= state.articles.length - 1
                        ? const SizedBox.shrink()
                        : const Divider(height: 1, indent: 108, endIndent: 16),
                    itemBuilder: (context, index) {
                      if (index == state.articles.length) {
                        return _buildLoadMoreFooter(state);
                      }
                      final article = state.articles[index];
                      final isRead = _readArticles.contains(article.url);
                      return _buildArticleItem(context, article, isRead);
                    },
                  )
                // [UI-fix v2.0.2 | 2026-08-06] 布局切换：双列网格渲染 — Qoder
                : CustomScrollView(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.all(12),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.72,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final article = state.articles[index];
                              final isRead =
                                  _readArticles.contains(article.url);
                              return _buildGridItem(context, article, isRead);
                            },
                            childCount: state.articles.length,
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: _buildLoadMoreFooter(state),
                      ),
                    ],
                  ),
          );
        },
      ),
    );

    // 对齐原版 `onBackPressedDispatcher`：搜索态系统返回先退出搜索而非退页
    return PopScope(
      canPop: !state.isSearching,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (ref.read(rssNotifierProvider).isSearching) {
          ref.read(rssNotifierProvider.notifier).clearSearch();
        }
      },
      child: scaffold,
    );
  }

  Widget _buildArticleItem(
      BuildContext context, RssFeedArticle article, bool isRead) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 详情页抓取成功后回填的正文优先于列表摘要（审查 P2-7）
    final description =
        _fetchedDescriptions[article.url] ?? article.description;

    // 稳定 ValueKey（文章 url）+ RepaintBoundary 隔离列表项重绘区域
    final item = InkWell(
      key: ValueKey(article.url),
      onTap: () {
        setState(() => _readArticles.add(article.url));
        _openDetail(article);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 缩略图（iOS 风格 10 圆角）
            if (article.imageUrl != null && article.imageUrl!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CachedNetworkImage(
                  imageUrl: article.imageUrl!,
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                  // 限制解码宽度为缩略图实际显示像素宽度（80），避免大图解码
                  memCacheWidth: (80 *
                          (MediaQuery.maybeOf(context)?.devicePixelRatio ??
                              1.0))
                      .round(),
                  // 源静态 header 透传（防盗链；对齐原版带源 header 加载封面）
                  httpHeaders: _imageHeaders.isEmpty ? null : _imageHeaders,
                  placeholder: (_, _) => Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  errorWidget: (_, _, _) => Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Symbols.image_not_supported_rounded,
                        color: colorScheme.onSurfaceVariant.withAlpha(128)),
                  ),
                ),
              )
            else
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Symbols.article_rounded,
                    color: colorScheme.onSurfaceVariant.withAlpha(128)),
              ),
            const SizedBox(width: 12),
            // 文字内容
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isRead
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (description != null && description.isNotEmpty)
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Symbols.schedule_rounded,
                          size: 12, color: colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      // 宽时间戳（ISO-8601）在窄屏下可能溢出：Flexible 收缩 + 省略号
                      Flexible(
                        child: Text(
                          article.pubDate ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (isRead) ...[
                        const SizedBox(width: 8),
                        Icon(Symbols.check_circle_rounded,
                            size: 12, color: colorScheme.primary),
                        const SizedBox(width: 2),
                        Text(
                          '已读',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return RepaintBoundary(child: item);
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 菜单处理（对标 rss_articles.xml）— Qoder =====

  /// 搜索（对齐原版 menu_search 的 SearchView 提交：以源 searchUrl 搜索）
  Future<void> _showSearchDialog() async {
    final notifier = ref.read(rssNotifierProvider.notifier);
    final submitted = await showDialog<String>(
      context: context,
      builder: (_) => _RssSearchDialog(
        initialQuery: ref.read(rssNotifierProvider).key ?? '',
      ),
    );
    if (submitted == null) return;
    await notifier.search(submitted);
  }

  /// 打开文章（批15f：按 type 分流 → WebView 阅读 / 图片查看 / 视频播放）
  void _openDetail(RssFeedArticle article) {
    // [UI-fix v2.0.2 | 2026-08-06] 接通 rssMarkRead FFI（对标原版
    // RssReadViewModel.recordRead），失败不阻断阅读 — Qoder
    // 批20：对齐原版 `RssArticle.toRecord()`，同批写入
    // type/sort/image/pubDate（durPos 文章 DTO 无对应字段，留空）。
    // 批29：全局开关 `enableRssReadRecord` 关闭时不写入（对齐原版
    // `ReadRss.kt:51` 写入前判定），已有记录保留。开关经 `resolved()`
    // 等待持久化值加载完成，避免进程首启首击漏判关闭态。
    unawaited(_recordReadIfEnabled(article));
    openRssArticle(
      context,
      ref,
      article: article,
      source: widget.source,
      sourceName: widget.source.sourceName,
      sourceUrl: widget.source.sourceUrl,
      // 审查 P2-7：详情页抓到规则正文后回填列表内存态
      onContentFetched: (description) {
        if (!mounted) return;
        setState(() => _fetchedDescriptions[article.url] = description);
      },
    ).then((_) {
      // 从详情返回列表时刷新一次：详情在途期间可能已回填正文/标记已读。
      // 注：列表页 DB-only 缓存查询在进入/切分类时进行（批15f），返回
      // 列表时只刷新内存态；DB 真源由 Rust 写回。
      if (mounted) setState(() {});
    });
  }

  /// 按全局开关写入 RSS 已读记录（等待偏好加载完成后再判定）
  ///
  /// 对齐原版 `ReadRss.readRss` 的写入前判定；`resolved()` 保证进程首启时
  /// 持久化的关闭态不会被 `build` 的同步默认值 true 掩盖。
  Future<void> _recordReadIfEnabled(RssFeedArticle article) async {
    // 先取依赖再 await：等待偏好期间页面若被销毁，不得再触碰 ref
    final api = ref.read(bookApiProvider);
    final enabled =
        await ref.read(rssReadRecordPrefProvider.notifier).resolved();
    await rssMarkReadIfEnabled(
      api,
      enabled,
      origin: widget.source.sourceUrl,
      title: article.title,
      link: hasRssArticleLink(article.url) ? article.url : null,
      type: article.type,
      sort: article.sort,
      image: article.imageUrl,
      pubDate: article.pubDate,
    );
  }

  /// 网格布局文章项（布局切换 articleStyle≠0 时使用）
  Widget _buildGridItem(
    BuildContext context,
    RssFeedArticle article,
    bool isRead,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          setState(() => _readArticles.add(article.url));
          _openDetail(article);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: article.imageUrl != null && article.imageUrl!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: article.imageUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: 300,
                      httpHeaders:
                          _imageHeaders.isEmpty ? null : _imageHeaders,
                      placeholder: (_, _) =>
                          Container(color: colorScheme.surfaceContainerHighest),
                      errorWidget: (_, _, _) => Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Symbols.image_not_supported_rounded,
                          color: colorScheme.onSurfaceVariant.withAlpha(128),
                        ),
                      ),
                    )
                  : Container(
                      color: colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Symbols.article_rounded,
                        color: colorScheme.onSurfaceVariant.withAlpha(128),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isRead
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                    ),
                  ),
                  if (article.pubDate != null &&
                      article.pubDate!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      article.pubDate!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 菜单分发（7 项）
  void _handleMenu(String value) {
    switch (value) {
      case 'login':
        // 对标原版 menu_login → SourceLoginActivity(type=rssSource)
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SourceLoginScreen(
              sourceUrl: widget.source.sourceUrl,
              sourceName: widget.source.sourceName,
              loginUrl: widget.source.loginUrl,
            ),
          ),
        );
      case 'refreshSort':
        // 对标原版 menu_refresh_sort：清分类脚本缓存后重新解析分类，
        // 再刷新当前分类列表（批15d 替代旧「重新拉列表」伪实现）
        ref.read(rssNotifierProvider.notifier).refreshSorts();
      case 'setVariable':
        _showSetVariableDialog();
      case 'editSource':
        // 对标原版 menu_edit_source → RssSourceEditActivity
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => RssSourceEditScreen(source: widget.source),
          ),
        );
      case 'switchLayout':
        _switchLayout();
      case 'readRecord':
        // 对标原版 menu_read_record → ReadRecordDialog(sourceUrl)
        showDialog<void>(
          context: context,
          builder: (_) => _RssReadRecordDialog(origin: widget.source.sourceUrl),
        );
      case 'clear':
        _clearArticles();
    }
  }

  /// 设置源变量（对标原版 VariableDialog + BaseSource.setVariable）
  ///
  /// 持久化键对齐 Kotlin CacheManager：`sourceVariable_${getKey()}`，经 config FFI。
  Future<void> _showSetVariableDialog() async {
    final api = ref.read(bookApiProvider);
    final key = 'sourceVariable_${widget.source.sourceUrl}';
    String? initial;
    try {
      initial = await api.getConfig(key);
      if (initial == null || initial.isEmpty) {
        initial = await api.getConfig(
          'rssSourceVariable_${widget.source.sourceUrl}',
        );
      }
    } catch (_) {}
    if (!mounted) return;
    final ctrl = TextEditingController(text: initial ?? '');
    final comment = (widget.source.variableComment ?? '').isEmpty
        ? '源变量可在 JS 中通过 source.getVariable() 获取'
        : widget.source.variableComment!;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置源变量'),
        content: TextField(
          controller: ctrl,
          autofocus: false,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: comment,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    try {
      if (result.isEmpty) {
        await api.deleteConfig(key);
      } else {
        await api.setConfig(key, result);
      }
      try {
        await api.deleteConfig('rssSourceVariable_${widget.source.sourceUrl}');
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('源变量已保存')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存源变量失败：$e')),
        );
      }
    }
  }

  /// 切换布局（对标原版 switchLayout：articleStyle 0-4 循环后持久化）
  Future<void> _switchLayout() async {
    final next = _articleStyle >= 4 ? 0 : _articleStyle + 1;
    setState(() => _articleStyle = next);
    final updated = widget.source.copyWith(articleStyle: next);
    try {
      await ref.read(bookApiProvider).updateRssSource(updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('布局保存失败：$e')),
        );
      }
    }
  }

  /// 清空（对标原版 menu_clear → clearArticles 删本源本地缓存文章）
  Future<void> _clearArticles() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空'),
        content: const Text('将清空本源本地缓存的文章列表，确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(bookApiProvider).rssClearArticles(widget.source.sourceUrl);
      ref.read(rssNotifierProvider.notifier).refreshArticles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('本源文章缓存已清空')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清空失败：$e')),
        );
      }
    }
  }
}

/// 搜索关键词输入对话框（对齐原版 `SearchView` 提交语义）
///
/// 自持有 [TextEditingController]，随对话框路由销毁而释放（避免在
/// `showDialog` 返回后立即 dispose 导致退出动画期间使用已释放控制器）。
class _RssSearchDialog extends StatefulWidget {
  final String initialQuery;

  const _RssSearchDialog({required this.initialQuery});

  @override
  State<_RssSearchDialog> createState() => _RssSearchDialogState();
}

class _RssSearchDialogState extends State<_RssSearchDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('搜索'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: '输入搜索关键词',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('搜索'),
        ),
      ],
    );
  }
}

/// [UI-fix v2.0.2 | 2026-08-06] 阅读记录对话框（对标原版 ReadRecordDialog：
/// 展示并跳转本源已读记录，经 rssHistoryNotifier 拉取后按 origin 过滤）— Qoder
class _RssReadRecordDialog extends ConsumerStatefulWidget {
  final String origin;

  const _RssReadRecordDialog({required this.origin});

  @override
  ConsumerState<_RssReadRecordDialog> createState() =>
      _RssReadRecordDialogState();
}

class _RssReadRecordDialogState extends ConsumerState<_RssReadRecordDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(rssHistoryNotifierProvider.notifier)
          .load(origin: widget.origin);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(rssHistoryNotifierProvider);
    final records = state.records;
    final recordEnabled = ref.watch(rssReadRecordPrefProvider);
    return AlertDialog(
      title: const Text('阅读记录'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 批29：记录开关（对齐原版 ReadRecordDialog 的
            // menu_enable_record → AppConfig.enableRssReadRecord）。
            // 关闭后不再新增记录；已有记录保留；重新开启恢复写入。
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('记录阅读历史'),
              value: recordEnabled,
              onChanged: (value) {
                ref
                    .read(rssReadRecordPrefProvider.notifier)
                    .setEnabled(value);
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: state.isLoading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : state.error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(state.error!),
                          ),
                        )
                      : records.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('暂无阅读记录'),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: records.length,
                              itemBuilder: (context, index) {
                                final record = records[index];
                                final time =
                                    DateTime.fromMillisecondsSinceEpoch(
                                  record.readTime,
                                );
                                return ListTile(
                                  dense: true,
                                  // 审查 P2-6：条目可点击重读，透传 origin 使
                                  // 详情页规则正文抓取/收藏 origin 生效
                                  onTap: () => _openRecord(record),
                                  title: Text(
                                    record.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
                                    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        // 批29：清空当前源记录（对齐原版 ReadRecordDialog 的 menu_clear →
        // `RssReadRecordDao.deleteAllRecord(origin)`，先弹确认）。
        // 批29b 审查 P3-2：清空中禁用（防重复触发）。
        TextButton(
          onPressed: (records.isEmpty || state.isClearing)
              ? null
              : _confirmClear,
          child: const Text('清空'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 清空当前源记录（对齐原版 `alert` 确认框 + `deleteAllRecord(origin)`）
  ///
  /// 批29b 审查 P2-1：确认框不再显示条数——列表只加载最近 100 条
  /// （`rssListReadRecordsByOrigin` 上限），而按源清空删的是该源**全部**
  /// 记录，条数会低报；改为「全部阅读记录」表述。
  /// 批29b 审查 P3-1：清空与随后的刷新分两段判断文案——清空成功但列表
  /// 刷新失败时不得误报「清空失败」。
  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空阅读记录'),
        content: const Text('确定清空当前源的全部阅读记录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final clearError = await ref
        .read(rssHistoryNotifierProvider.notifier)
        .clear(origin: widget.origin);
    if (!mounted) return;
    if (clearError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清空失败：$clearError')),
      );
      return;
    }
    // 清空已成功，随后刷新失败单独提示（不得复用「清空失败」）
    final loadError = ref.read(rssHistoryNotifierProvider).error;
    if (loadError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清空成功，但刷新记录失败：$loadError')),
      );
    }
  }

  /// 点击记录重读（同列表页：透传 origin，按源 type 分流阅读）
  ///
  /// 批20：记录自带 `type` 优先（0 网页 / 1 图片 / 2 视频），源 `type` 仅兜底；
  /// `sort` / `image` / `pubDate` 一并透传，对齐原版 `record.toRssArticle()`。
  void _openRecord(RssReadRecordRow record) {
    Navigator.of(context).pop(); // 对标原版点击后 dismiss
    final link = record.link ?? '';
    final hasLink = hasRssArticleLink(link);
    final rssState = ref.read(rssNotifierProvider);
    RssSource? source;
    String sourceName = record.origin;
    for (final candidate in rssState.sources) {
      if (candidate.sourceUrl == record.origin) {
        source = candidate;
        sourceName = candidate.sourceName;
        break;
      }
    }
    if (source == null && rssState.selectedSource?.sourceUrl == record.origin) {
      source = rssState.selectedSource;
      sourceName = source!.sourceName;
    }
    openRssArticle(
      context,
      ref,
      article: RssFeedArticle(
        title: record.title,
        url: hasLink ? link : '',
        sort: record.sort,
        pubDate: record.pubDate,
        imageUrl: record.image,
        type: record.type,
      ),
      source: source,
      sourceName: sourceName,
      // 无链接（空串/legacy 伪主键）不传 origin，避免空 link 抓正文
      sourceUrl: hasLink ? record.origin : '',
    );
  }
}
