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

  /// P1-4：本地书籍导入执行器（由 app.dart 注入 bookshelfNotifier 闭包，
  /// 服务层不依赖 Riverpod；对齐 [attach] 的回调装配模式）
  Future<Book> Function(String filePath)? importLocalBook;

  bool _attached = false;
  String? _lastHandled;

  /// P1-4：最近一次处理的文件 URI（弹窗存续期去重，语义同 [_lastHandled]）
  String? _lastHandledFile;
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
    }
  }

  /// 处理深链或平台桥 openUrl 转来的 legado/yuedu URI
  Future<void> handleUrl(String url) async {
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
  Future<void> _dispatchCopiedFile(
    String path,
    ScaffoldMessengerState messenger,
  ) async {
    final fileKind = _classifyCopiedFile(path);
    switch (fileKind) {
      case IncomingFileKind.json:
        await _openAssociationImport(path);
      case IncomingFileKind.archive:
        await _openArchiveImport(path);
      case IncomingFileKind.bookFile:
        await _confirmAndImport(path, messenger);
      case IncomingFileKind.unsupported:
        await _confirmUnsupportedImport(path, messenger);
    }
  }

  /// 落盘文件分类：先看压缩包后缀，再嗅探 JSON 内容，最后按后缀
  IncomingFileKind _classifyCopiedFile(String path) {
    if (LegadoDeepLink.isArchivePath(path)) {
      return IncomingFileKind.archive;
    }
    return LegadoDeepLink.classifyFile(
      path,
      jsonContent: _looksLikeJsonFile(path),
    );
  }

  /// 读取文件头部做 JSON 嗅探（对齐原版 looksLikeJson；读失败按非 JSON）
  ///
  /// 只读前 64KB 且目标为应用私有目录文件，同步读开销可忽略；同步实现
  /// 同时避免 UI 分流链路多一次异步跳转（原版亦在后台线程做同量级读取）。
  bool _looksLikeJsonFile(String path) {
    RandomAccessFile? handle;
    try {
      handle = File(path).openSync();
      final bytes = handle.readSync(LegadoDeepLink.jsonSniffLimit);
      return LegadoDeepLink.looksLikeJsonBytes(bytes);
    } catch (e) {
      debugPrint('[DeepLink] JSON 嗅探失败：$e');
      return false;
    } finally {
      try {
        handle?.closeSync();
      } catch (_) {
        // 关闭失败不影响分类结果
      }
    }
  }

  /// JSON → 关联导入确认框（原版 importJson：类型由内容自动识别）
  Future<void> _openAssociationImport(String path) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    await showAssociationImportDialog(nav.context, filePath: path);
  }

  /// 压缩包 → 解压导入对话框（zip/rar）；7z 无解析 FFI，给明确提示
  Future<void> _openArchiveImport(String path) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    if (LegadoDeepLink.isSevenZipPath(path)) {
      // 登记项：原版支持 7z 解压，我方 Rust 无 7z 解析能力（待另立依赖批）
      await _showMessageDialog(
        nav.context,
        title: '压缩包导入',
        message: '暂不支持 7z，请解压后导入',
      );
      return;
    }
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

  /// 通用提示对话框（7z 等明确不支持场景）
  Future<void> _showMessageDialog(
    BuildContext context, {
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

  /// 原生拷贝外部文件到应用持久目录；返回落盘路径，取消/失败返回 null
  ///（失败已提示）。
  Future<String?> _copyExternalFile(
    String uri,
    ScaffoldMessengerState messenger,
  ) async {
    try {
      final path = await _channel.invokeMethod<String>('copyContentUri', {
        'uri': uri,
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