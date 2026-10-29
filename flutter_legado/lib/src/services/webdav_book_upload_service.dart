// 批40：本地书上传至 WebDAV 的共用实现（手动「上传至远程」与「导入后自动上传」）
//
// 对齐原版 `RemoteBookWebDav.upload(book)`：
// - 远端路径 `books/<originName>`（`originName` 为空时取本地文件名）；
// - 上传成功后回写 `book.origin = webDav::<完整远程 URL>` 并刷新
//   `lastCheckTime`（默认服务器无 serverID 后缀）；
// - 失败按阶段区分：`upload`（文件上传失败）/ `record`（上传成功但回写
//   记录失败），供 UI 给出不同提示。
//
// 自动上传（[autoUploadAfterImport]）受 `webDavBookAutoUpload` 开关控制，
// 默认关闭；未配置 WebDAV 直接跳过；任何失败仅日志，不阻断导入。
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/book.dart';
import 'book_api.dart';
import 'settings_service.dart';
import 'webdav_server_service.dart';

/// 上传阶段（失败提示区分依据）
enum WebDavBookUploadStage {
  /// 文件上传失败（网络/权限/路径）
  upload,

  /// 文件已上传，但本地书籍记录回写失败
  record,
}

/// 本地书上传异常（携带失败阶段）
class WebDavBookUploadException implements Exception {
  const WebDavBookUploadException(this.stage, this.cause);

  final WebDavBookUploadStage stage;
  final Object cause;

  @override
  String toString() => 'WebDavBookUploadException($stage): $cause';
}

/// 导入后自动上传结果（便于单测断言与日志）
enum BookAutoUploadOutcome {
  /// 开关关闭
  disabled,

  /// 未配置 WebDAV（url 为空）
  notConfigured,

  /// 上传并回写成功
  uploaded,

  /// 失败（仅日志，不阻断导入）
  failed,
}

/// Book 的远端文件名（对齐原版 `remoteBookUploadFileName`）
///
/// 本地书 `originName` 为导入时的原始文件名；为空时回退 `bookUrl` 的
/// basename（兼容跨平台路径分隔符）。
String webDavBookRemoteFileName(Book book) {
  final origin = book.originName.trim();
  if (origin.isNotEmpty) return origin;
  return book.bookUrl.split(RegExp(r'[\\/]')).last;
}

/// Book 的远端相对路径（相对 remote_dir）：`books/<文件名>`
String webDavBookRemotePath(Book book) =>
    'books/${webDavBookRemoteFileName(book)}';

/// 默认 WebDAV 目标（配置 JSON + 用于回写 origin 的 URL/子目录）
@immutable
class WebDavBookTarget {
  const WebDavBookTarget({
    required this.configJson,
    required this.webDavUrl,
    required this.remoteDir,
  });

  final String configJson;
  final String webDavUrl;
  final String remoteDir;
}

/// 本地书 WebDAV 上传服务
class WebDavBookUploadService {
  WebDavBookUploadService({
    required BookApi api,
    SettingsService? settings,
  })  : _api = api,
        _settings = settings ?? SettingsService();

  final BookApi _api;
  final SettingsService _settings;

  /// 解析默认 WebDAV 目标（DB `servers` 表 `id = -1` + 子目录偏好）
  ///
  /// 返回 null = 未配置；读取异常向上抛。
  Future<WebDavBookTarget?> resolveTarget() async {
    final server = await WebDavServerService(
      api: _api,
      settings: _settings,
    ).loadSyncServer();
    if (server.url.trim().isEmpty) return null;
    final config = BookType.normalizeWebDavConfig(
      server.url,
      await _settings.getWebDavRemoteDir(),
    );
    return WebDavBookTarget(
      configJson: jsonEncode({
        'url': config.url,
        'username': server.username,
        'password': server.password,
        'remote_dir': config.remoteDir,
      }),
      webDavUrl: config.url,
      remoteDir: config.remoteDir,
    );
  }

  /// 上传书籍文件并回写 origin（手动/自动共用）
  ///
  /// 失败抛 [WebDavBookUploadException]（区分 upload/record 阶段）。
  Future<void> uploadBook({
    required Book book,
    required WebDavBookTarget target,
  }) async {
    final remotePath = webDavBookRemotePath(book);
    // 本地书 bookUrl 即本地文件路径（对齐 Rust import_local_book 落库约定）
    try {
      await _api.webdavUploadFile(target.configJson, remotePath, book.bookUrl);
    } catch (e) {
      throw WebDavBookUploadException(WebDavBookUploadStage.upload, e);
    }

    try {
      // 从库中读回完整 Book 再 copyWith，防全行覆盖
      final full = await _api.getBook(book.bookUrl) ?? book;
      final remoteUrl = BookType.joinRemoteUrl(
        BookType.joinRemoteUrl(target.webDavUrl, target.remoteDir),
        remotePath,
      );
      await _api.updateBook(
        full.copyWith(
          origin: BookType.buildWebDavOrigin(remoteUrl),
          // 对齐原版：刷新最后检查时间，使之比远程书籍的时间新
          lastCheckTime: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      throw WebDavBookUploadException(WebDavBookUploadStage.record, e);
    }
  }

  /// 导入成功后自动上传（失败仅日志，绝不向上抛）
  ///
  /// 判定顺序对齐原版 `LocalBook.autoUploadToWebDav`：开关 → 是否配置 →
  /// 仅本地书（调用方保证）→ 逐个上传；任何失败只记日志。
  Future<BookAutoUploadOutcome> autoUploadAfterImport(Book book) async {
    try {
      if (!await _settings.getWebDavBookAutoUpload()) {
        return BookAutoUploadOutcome.disabled;
      }
      final target = await resolveTarget();
      if (target == null) return BookAutoUploadOutcome.notConfigured;
      await uploadBook(book: book, target: target);
      debugPrint('[WebDavBookUploadService] 导入后自动上传成功: ${book.name}');
      return BookAutoUploadOutcome.uploaded;
    } catch (e, stack) {
      debugPrint('[WebDavBookUploadService] 导入后自动上传失败: $e\n$stack');
      return BookAutoUploadOutcome.failed;
    }
  }
}
