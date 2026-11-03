import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../routes.dart';
import '../screens/archive_import_dialog.dart';
import '../screens/association_import_dialog.dart';
import '../utils/legado_deep_link.dart';
import '../utils/shared_text.dart';
import '../widgets/open_url_confirm_dialog.dart';
import '../widgets/passphrase_import.dart';
import 'source_share_passphrase.dart';

/// 监听 Android `legado://` / `yuedu://` 深链并导航到关联导入页；
/// P1-4 起同时消费外部书籍文件 VIEW intent（content:// / file://）
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const _channel = MethodChannel('legado/deep_link');

  /// 落盘路径 → 展示文件名（路径末段；同时兼容 POSIX「/」与 Windows「\」
  /// 分隔符——宿主平台与目标平台可能不一致）
  static String displayNameFromPath(String path) {
    final segments = path
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }

  GlobalKey<NavigatorState>? navigatorKey;

  /// JSON 内容嗅探器（测试注入点；默认走 [LegadoDeepLink.looksLikeJsonFile]
  /// 异步读盘。widget 测试的 fake async 不推进真实 IO，可注入纯内存判定）
  Future<bool> Function(String path)? jsonSniffer;

  /// 冷启动闪屏是否仍在栈顶（由 app.dart 注入；null 视为立即可用）
  ///
  /// 冷启动固定经 `/welcome` 闪屏，`pushReplacementNamed(home)` 替换的是
  /// **当时栈顶路由**——若分享导入框在闪屏之上弹出，会被一并替换掉（与
  /// 崩溃弹窗 P2-13b 同类竞态）。分享文本弹窗前先等闪屏退出。
  bool Function()? isSplashVisible;

  /// 闪屏等待上限（帧）：约 90 帧 ≈ 1.5s，覆盖闪屏最大 800ms 延时；
  /// 超时仍强制尝试展示，避免异常滞留时静默丢弃分享内容。
  static const int _maxSplashWaitFrames = 90;

  /// P1-4：本地书籍导入执行器（由 app.dart 注入 bookshelfNotifier 闭包，
  /// 服务层不依赖 Riverpod；对齐 [attach] 的回调装配模式）
  Future<Book> Function(String filePath)? importLocalBook;

  bool _attached = false;
  String? _lastHandled;

  /// [M3 我的页 | 2026-11-03] 最近一次派发的应用内路由深链（push 存续期
  /// 去重；页面 pop 后清空，允许再次打开）。冷启动 `getInitialLink` 与
  /// `onNewIntent` 双投递同一 URI 时不会叠栈。
  String? _lastRoutedDeepLink;

  /// [M3] 应用内路由深链 → 命名路由映射
  static const Map<LegadoRouteDeepLink, String> _routeDeepLinkTargets = {
    LegadoRouteDeepLink.dict: AppRoutes.dict,
    LegadoRouteDeepLink.dictRule: AppRoutes.dictRule,
  };

  /// P1-4：最近一次处理的文件 URI（弹窗存续期去重，语义同 [_lastHandled]）
  String? _lastHandledFile;

  /// 批25：最近一次处理的分享文本（弹窗存续期去重）
  String? _lastHandledShared;

  StreamSubscription<Uri>? _iosLinkSub;

  /// 在 [LegadoApp] 首帧后调用；重复调用安全
  Future<void> attach(
    GlobalKey<NavigatorState> key, {
    Future<Book> Function(String filePath)? importLocalBook,
  }) async {
    navigatorKey = key;
    if (importLocalBook != null) {
      this.importLocalBook = importLocalBook;
    }
    if (_attached) return;
    _attached = true;
    // [iOS 轨 P2] iOS 走 app_links（Info.plist 已注册 legado/yuedu scheme）；
    // Android 保持 DeepLinkService 通道。P1-4 外部文件 VIEW intent 仅
    // Android manifest 声明（iOS document types 无对应裁决口径），iOS 不消费。
    if (Platform.isIOS) {
      final links = AppLinks();
      try {
        final initial = await links.getInitialLink();
        if (initial != null && initial.toString().isNotEmpty) {
          await handleUrl(initial.toString());
        }
      } catch (e) {
        debugPrint('[DeepLink] 初始链路失败：$e');
      }
      _iosLinkSub = links.uriLinkStream.listen(
        (uri) => handleUrl(uri.toString()),
        onError: (e) => debugPrint('[DeepLink] 链路流错误：$e'),
      );
      return;
    }
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null && initial.isNotEmpty) {
        await handleUrl(initial);
      }
    } catch (e) {
      debugPrint('[DeepLink] getInitialLink 失败：$e');
    }
    // P1-4：冷启动外部书籍文件（文件管理器「用阅读打开」拉起）
    try {
      final fileUri = await _channel.invokeMethod<String>('getInitialFileUri');
      if (fileUri != null && fileUri.isNotEmpty) {
        await handleFileUri(fileUri);
      }
    } catch (e) {
      debugPrint('[DeepLink] getInitialFileUri 失败：$e');
    }
    // 批25：ACTION_SEND / ACTION_PROCESS_TEXT 分享文本（冷启动）
    try {
      final sharedText =
          await _channel.invokeMethod<String>('getInitialSharedText');
      if (sharedText != null && sharedText.isNotEmpty) {
        await handleSharedText(sharedText);
      }
    } catch (e) {
      debugPrint('[DeepLink] getInitialSharedText 失败：$e');
    }
  }

  /// 取消 iOS 链路流订阅（进程级单例一般不调用；保留以备测试与热重载）
  Future<void> detach() async {
    await _iosLinkSub?.cancel();
    _iosLinkSub = null;
    _attached = false;
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'onLink') {
      final url = call.arguments as String?;
      if (url != null && url.isNotEmpty) {
        await handleUrl(url);
      }
    } else if (call.method == 'onFileUri') {
      // P1-4：外部书籍文件热路径（Activity 已存活时经 onNewIntent 转发）
      final uri = call.arguments as String?;
      if (uri != null && uri.isNotEmpty) {
        await handleFileUri(uri);
      }
    } else if (call.method == 'onSharedText') {
      // 批25：ACTION_SEND / PROCESS_TEXT 热路径（Activity 已存活）
      final text = call.arguments as String?;
      if (text != null && text.isNotEmpty) {
        await handleSharedText(text);
      }
    }
  }

  /// 批25：处理外部分享文本（ACTION_SEND / ACTION_PROCESS_TEXT）
  ///
  /// 分流顺序：超限/超深预检 → 分享口令 → legado:// / yuedu:// →
  /// http(s) URL → JSON → 其余提示不支持。
  ///
  /// 批25b P3-4：口令解码出的 URL 与导入深链的 `src` 都可能指向任意外部
  /// 地址，SEND 来源不可信——先复用 [showOpenUrlConfirmDialog] 让用户确认，
  /// 确认前不发起任何网络拉取（关联导入对话框打开即自动拉取）。
  /// HTTP 链接本身也先确认再进应用内浏览器（无确认不联网）。
  Future<void> handleSharedText(String raw) =>
      _handleSharedTextWhenUiReady(raw, 0);

  /// [handleSharedText] 的就绪等待实现：Navigator 未装配或闪屏未退出时
  /// 逐帧重试，避免弹窗被闪屏替换（见 [isSplashVisible]）。
  Future<void> _handleSharedTextWhenUiReady(String raw, int frame) async {
    final text = raw.trim();
    if (text.isEmpty) return;
    if (_lastHandledShared == text) return;
    final nav = navigatorKey?.currentState;
    final splashVisible = isSplashVisible?.call() ?? false;
    if (nav == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleSharedTextWhenUiReady(raw, frame + 1);
      });
      return;
    }
    if (splashVisible && frame < _maxSplashWaitFrames) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleSharedTextWhenUiReady(raw, frame + 1);
      });
      // addPostFrameCallback 本身不排帧：闪屏期若无动画在跑，须显式请求
      // 下一帧，否则等待链会停摆到下一次用户交互才继续
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    _lastHandledShared = text;
    try {
      switch (classifySharedText(text)) {
        case SharedTextKind.passphrase:
          await _confirmPassphraseThenImport(text);
        case SharedTextKind.importScheme:
          await _confirmImportSchemeThenImport(text);
        case SharedTextKind.httpUrl:
          await _confirmOpenSharedUrl(text);
        case SharedTextKind.json:
          await showAssociationImportDialog(nav.context, text: text);
        case SharedTextKind.tooLarge:
          await _showSharedRejected(
            context: nav.context,
            title: '分享内容过大',
            message: '分享内容超过 ${maxSharedTextBytes ~/ (1024 * 1024)} MiB，'
                '无法解析导入，请改用文件导入。',
          );
        case SharedTextKind.tooDeepJson:
          await _showSharedRejected(
            context: nav.context,
            title: 'JSON 层级过深',
            message: '分享的 JSON 嵌套超过 $maxJsonDepth 层，无法安全解析，'
                '请确认来源后重试。',
          );
        case SharedTextKind.unsupported:
          await _showSharedUnsupported(nav.context);
      }
    } finally {
      _lastHandledShared = null;
    }
  }

  /// 分享口令：先确认解码出的目标 URL，再进入关联导入（打开即拉取）
  Future<void> _confirmPassphraseThenImport(String text) async {
    final result = SourceSharePassphrase.decode(text);
    if (result is SourcePassphraseSuccess) {
      final nav = navigatorKey?.currentState;
      if (nav == null) return;
      final ok = await showOpenUrlConfirmDialog(
        nav.context,
        url: result.value.url,
      );
      if (!ok) return;
    }
    // 解码失败分支仍交给 importPassphraseText 给出明确中文提示
    final current = navigatorKey?.currentState;
    if (current == null || !current.mounted) return;
    await importPassphraseText(current.context, text);
  }

  /// 导入深链：先确认 `src` 目标地址，再进入关联导入（打开即拉取）
  Future<void> _confirmImportSchemeThenImport(String url) async {
    final src = LegadoDeepLink.tryParse(url)?.srcUrl ?? '';
    if (src.isNotEmpty) {
      final nav = navigatorKey?.currentState;
      if (nav == null) return;
      final ok = await showOpenUrlConfirmDialog(nav.context, url: src);
      if (!ok) return;
    }
    await handleUrl(url);
  }

  /// 分享的 http(s) 链接：先走既有外跳确认，确认后进入应用内浏览器
  Future<void> _confirmOpenSharedUrl(String url) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    final ok = await showOpenUrlConfirmDialog(nav.context, url: url);
    if (!ok) return;
    final current = navigatorKey?.currentState;
    if (current == null) return;
    unawaited(
      current.pushNamed(
        AppRoutes.browser,
        arguments: <String, String>{'url': url, 'html': ''},
      ),
    );
  }

  /// 分享内容无法识别时的明确提示
  Future<void> _showSharedUnsupported(BuildContext context) {
    return _showSharedRejected(
      context: context,
      title: '不支持的内容',
      message: '分享内容不是分享口令、http(s) 链接、legado:// 导入链接'
          '或可导入的 JSON。',
    );
  }

  /// 分享文本被拒绝（超限 / JSON 超深）时的明确提示
  Future<void> _showSharedRejected({
    required BuildContext context,
    required String title,
    required String message,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 处理深链或平台桥 openUrl 转来的 legado/yuedu URI
  ///
  /// [M3 我的页 | 2026-11-03] 分流顺序：**应用内路由深链优先**
  ///（`legado://dict` / `legado://dict_rule` → 对应页面），其余仍按既有
  /// 导入语义走关联导入确认框（`legado://import/...` 与未知 host 不变）。
  Future<void> handleUrl(String url) async {
    final routeTarget = LegadoDeepLink.tryParseRoute(url);
    if (routeTarget != null) {
      final routeName = _routeDeepLinkTargets[routeTarget];
      if (routeName != null) {
        await _handleRouteDeepLink(url, routeName);
        return;
      }
    }
    if (!LegadoDeepLink.isImportScheme(url)) return;
    if (_lastHandled == url) return;
    _lastHandled = url;

    final parsed = LegadoDeepLink.tryParse(url);
    final nav = navigatorKey?.currentState;
    if (nav == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _lastHandled = null;
        handleUrl(url);
      });
      return;
    }

    final type = parsed?.importType;
    final src = parsed?.srcUrl ?? '';
    // [UI-fix v2.0.174] 同链接去重仅在弹窗存续期生效：弹窗关闭（手动关/
    // 导入完成自动 pop）即清标志，避免同一链接再次点击永远不弹（用户报障
    // 「关联导入无法弹出」根因之一）
    showAssociationImportDialog(
      nav.context,
      url: src.isEmpty ? null : src,
      type: type,
    ).whenComplete(() => _lastHandled = null);
  }

  /// [M3 我的页 | 2026-11-03] 应用内路由深链导航（`legado://dict` 等）
  ///
  /// 冷启动与热路径共用：
  /// - 冷启动时闪屏 `/welcome` 仍可能在栈顶，`pushReplacementNamed(home)`
  ///   会替换当时栈顶路由（与分享文本/崩溃弹窗同类竞态）。此处复用
  ///   [isSplashVisible] 逐帧等待（上限 [_maxSplashWaitFrames]，语义同
  ///   [handleSharedText]），闪屏退出后再 push；
  /// - Navigator 未装配时逐帧重试（与 [handleUrl] 既有行为一致）；
  /// - 去重：同一 URI 在本次 push 存续期（直到页面 pop）只导航一次；
  ///   页面 pop 后清空，用户再次触发可重新打开。
  Future<void> _handleRouteDeepLink(String url, String routeName) =>
      _handleRouteDeepLinkWhenUiReady(url, routeName, 0);

  Future<void> _handleRouteDeepLinkWhenUiReady(
    String url,
    String routeName,
    int frame,
  ) async {
    final normalized = url.trim();
    if (_lastRoutedDeepLink == normalized) return;
    final nav = navigatorKey?.currentState;
    if (nav == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleRouteDeepLinkWhenUiReady(url, routeName, frame + 1);
      });
      return;
    }
    final splashVisible = isSplashVisible?.call() ?? false;
    if (splashVisible && frame < _maxSplashWaitFrames) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleRouteDeepLinkWhenUiReady(url, routeName, frame + 1);
      });
      // addPostFrameCallback 本身不排帧：闪屏期须显式请求下一帧，
      // 否则等待链会停摆到下一次用户交互（同 handleSharedText）
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    _lastRoutedDeepLink = normalized;
    try {
      final pushed = nav.pushNamed(routeName);
      // 页面 pop 后清空去重标记；不 await，避免阻塞深链调用方
      unawaited(
        pushed.whenComplete(() {
          if (_lastRoutedDeepLink == normalized) {
            _lastRoutedDeepLink = null;
          }
        }),
      );
    } catch (e) {
      if (_lastRoutedDeepLink == normalized) _lastRoutedDeepLink = null;
      debugPrint('[DeepLink] 路由深链导航失败（$routeName）：$e');
    }
  }

  /// 测试用：清空深链去重标记（不改变通道订阅/装配状态）
  @visibleForTesting
  void debugResetDedup() {
    _lastHandled = null;
    _lastHandledFile = null;
    _lastHandledShared = null;
    _lastRoutedDeepLink = null;
  }

  /// P1-4 / 批16d：处理外部文件 URI（content:// / file://）
  ///
  /// 对齐原版 FileAssociationActivity 的 ACTION_VIEW 分发：原生拷贝落盘后
  /// 按 [LegadoDeepLink.classifyFile] 分流为 JSON / 压缩包 / 书籍文件 /
  /// 不支持四类。书籍文件沿用批3裁决的「导入前确认框」（原版直接导入，
  /// 该偏离已登记）。
  Future<void> handleFileUri(String uri) async {
    final kind = LegadoDeepLink.classifyIncomingUri(uri);
    if (kind != IncomingUriKind.bookFile) return;
    // 去重语义同 handleUrl：仅弹窗存续期生效
    if (_lastHandledFile == uri) return;
    _lastHandledFile = uri;

    final nav = navigatorKey?.currentState;
    if (nav == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _lastHandledFile = null;
        handleFileUri(uri);
      });
      return;
    }
    final messenger = ScaffoldMessenger.of(nav.context);
    try {
      final path = await _copyExternalFile(uri, messenger);
      if (path == null) return;
      await _dispatchCopiedFile(path, messenger);
    } catch (e) {
      debugPrint('[DeepLink] 外部文件导入失败：$e');
      messenger.showSnackBar(SnackBar(content: Text('导入书籍失败：$e')));
    } finally {
      _lastHandledFile = null;
    }
  }

  /// 按分流类型处理已落盘文件（原版 dispatchIntent → dispatch 的等价实现）
  ///
  /// P2-6：JSON/压缩包/不支持三类只消费一次 → 分支用后删除落盘副本
  /// （书籍文件保留持久副本，导入链以该路径作为 bookUrl）。
  Future<void> _dispatchCopiedFile(
    String path,
    ScaffoldMessengerState messenger,
  ) async {
    final fileKind = await _classifyCopiedFile(path);
    switch (fileKind) {
      case IncomingFileKind.json:
        try {
          await _openAssociationImport(path);
        } finally {
          // P2-6：JSON 只消费一次，用后删除落盘副本
          _deleteCopiedFile(path);
        }
      case IncomingFileKind.archive:
        try {
          await _openArchiveImport(path);
        } finally {
          _deleteCopiedFile(path);
        }
      case IncomingFileKind.bookFile:
        await _confirmAndImport(path, messenger);
      case IncomingFileKind.unsupported:
        try {
          await _confirmUnsupportedImport(path, messenger);
        } finally {
          _deleteCopiedFile(path);
        }
    }
  }

  /// 落盘文件分类：先看压缩包后缀，再嗅探 JSON 内容，最后按后缀
  Future<IncomingFileKind> _classifyCopiedFile(String path) async {
    if (LegadoDeepLink.isArchivePath(path)) {
      return IncomingFileKind.archive;
    }
    return LegadoDeepLink.classifyFile(
      path,
      jsonContent: await _looksLikeJsonFile(path),
    );
  }

  /// 读取文件头部做 JSON 嗅探（对齐原版 looksLikeJson；读失败按非 JSON）
  ///
  /// P2-7：默认走 [LegadoDeepLink.looksLikeJsonFile] 异步读；widget 测试可
  /// 注入 [jsonSniffer] 规避真实 IO（fake async 不推进磁盘回调）。
  Future<bool> _looksLikeJsonFile(String path) {
    final sniffer = jsonSniffer;
    if (sniffer != null) return sniffer(path);
    return LegadoDeepLink.looksLikeJsonFile(path);
  }

  /// 删除一次性落盘副本（P2-6；失败仅记录，不影响导入结果）
  void _deleteCopiedFile(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (e) {
      debugPrint('[DeepLink] 清理外部文件副本失败：$e');
    }
  }

  /// JSON → 关联导入确认框（原版 importJson：类型由内容自动识别）
  Future<void> _openAssociationImport(String path) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    await showAssociationImportDialog(nav.context, filePath: path);
  }

  /// 压缩包 → 解压导入对话框（zip/rar/7z）
  Future<void> _openArchiveImport(String path) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    await showDialog<void>(
      context: nav.context,
      builder: (_) => ArchiveImportDialog(archivePath: path),
    );
  }

  /// 不支持的文件 → 原版式兜底对话框（仍然导入 = 强制按书籍导入）
  Future<void> _confirmUnsupportedImport(
    String path,
    ScaffoldMessengerState messenger,
  ) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    final name = displayNameFromPath(path);
    final confirmed = await showDialog<bool>(
      context: nav.context,
      builder: (ctx) => AlertDialog(
        title: const Text('提醒'),
        content: Text('文件 $name 不受支持，是否继续打开？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('仍然导入'),
          ),
        ],
      ),
    ).then((v) => v ?? false);
    if (!confirmed) return;
    await _importAndOpen(path, messenger);
  }

  /// 原生拷贝外部文件到应用私有目录；返回落盘路径，取消/失败返回 null
  ///（失败已提示）。
  ///
  /// P2-6：书籍后缀（或无后缀的 content URI，可能是书籍）落 `filesDir`
  /// 持久目录；已知非书籍后缀（json/zip/rar/7z/其它）落 `cacheDir`，由调用
  /// 分支用后删除，避免一次性导入文件长期占用持久空间。
  Future<String?> _copyExternalFile(
    String uri,
    ScaffoldMessengerState messenger,
  ) async {
    try {
      final ext = LegadoDeepLink.extensionOf(uri);
      final persistent = ext.isEmpty || LegadoDeepLink.isBookFilePath(uri);
      final path = await _channel.invokeMethod<String>('copyContentUri', {
        'uri': uri,
        'persistent': persistent,
      });
      if (path == null || path.isEmpty) {
        throw StateError('文件拷贝失败：未返回路径');
      }
      return path;
    } catch (e) {
      debugPrint('[DeepLink] 外部文件拷贝失败：$e');
      messenger.showSnackBar(SnackBar(content: Text('导入书籍失败：$e')));
      return null;
    }
  }

  /// 确认框 → 导入 → 打开详情页（原版 importBook → startActivityForBook）
  Future<void> _confirmAndImport(
    String path,
    ScaffoldMessengerState messenger,
  ) async {
    // 方法首段不做 await 前置，Navigator 判定后立即取 context（无跨 await 引用）
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    final confirmed = await _showImportConfirmDialog(nav.context, path);
    if (!confirmed) return;
    await _importAndOpen(path, messenger);
  }

  /// 执行本地书籍导入并导航详情页（确认交互由调用方负责）
  Future<void> _importAndOpen(
    String path,
    ScaffoldMessengerState messenger,
  ) async {
    final importer = importLocalBook;
    if (importer == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('导入功能未就绪，请稍后重试')),
      );
      return;
    }
    final book = await importer(path);
    // 导入后打开详情页（对齐原版 startActivityForBook）
    final currentNav = navigatorKey?.currentState;
    if (currentNav != null) {
      unawaited(
        currentNav.pushNamed(AppRoutes.bookInfo, arguments: book),
      );
    }
  }

  /// 导入确认框（批3裁决：对齐关联导入确认交互；文件名展示 + 取消/导入）
  Future<bool> _showImportConfirmDialog(BuildContext context, String path) {
    final name = displayNameFromPath(path);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入本地书籍'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            const Text('是否导入该书并加入书架？'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('导入'),
          ),
        ],
      ),
    ).then((v) => v ?? false);
  }
}