import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统另存结果（D1 / 批26）
///
/// [location] 为实际落盘位置：Android 是 `content://` URI，iOS/桌面是文件
/// 路径；[fileName] 为 provider 回传的**实际文件名**——用户在对话框输入
/// 重名时系统可能改名为 `xxx (1).json`（P3-2），提示文案应以它为准；
/// 原生未回传时回落到调用方请求的文件名。
///
/// [viaTree]（批26）表示经 SAF 目录树（`ACTION_OPEN_DOCUMENT_TREE`）写入，
/// 此时 [displayPath] 为原生回传的目录显示名（如 `下载/legado`），提示
/// 文案应回显它，用户才能定位文件。
@immutable
class SaveFileResult {
  const SaveFileResult({
    required this.location,
    this.fileName,
    this.viaMediaStoreFallback = false,
    this.downloadDirectory,
    this.viaTree = false,
    this.displayPath,
  });

  /// 落盘位置（Android: content URI；其他平台: 文件路径）
  final String location;

  /// provider 实际文件名（可能含重名后缀）；null 表示回落到请求文件名
  final String? fileName;

  /// 是否经 MediaStore Downloads 回退写入（原 DownloadsProvider 入口，
  /// 用户所选「下载」目录写流被 ROM 拒绝时）
  final bool viaMediaStoreFallback;

  /// 回退写入的「下载」相对目录（如 `Download/legado/`，带尾斜杠）；
  /// 非回退或原生未回传时为 null
  final String? downloadDirectory;

  /// 是否经 SAF 目录树写入（批26 默认路径）
  final bool viaTree;

  /// 目录树显示路径（如 `下载/legado`）；未回传时为 null
  final String? displayPath;

  @override
  bool operator ==(Object other) =>
      other is SaveFileResult &&
      other.location == location &&
      other.fileName == fileName &&
      other.viaMediaStoreFallback == viaMediaStoreFallback &&
      other.downloadDirectory == downloadDirectory &&
      other.viaTree == viaTree &&
      other.displayPath == displayPath;

  @override
  int get hashCode => Object.hash(
    location,
    fileName,
    viaMediaStoreFallback,
    downloadDirectory,
    viaTree,
    displayPath,
  );

  @override
  String toString() =>
      'SaveFileResult(location: $location, fileName: $fileName, '
      'viaMediaStoreFallback: $viaMediaStoreFallback, '
      'downloadDirectory: $downloadDirectory, viaTree: $viaTree, '
      'displayPath: $displayPath)';
}

/// 已选择的保存文件夹（SAF 目录树，批26）
///
/// [location] 为 `content://…/tree/…` URI；[displayPath] 为原生生成的
/// 中文可读路径（如 `下载/legado`）；[authority] 为 provider authority
/// （排障用，不同 ROM 的实现差异较大）。
@immutable
class SaveTreeSelection {
  const SaveTreeSelection({
    required this.location,
    this.displayPath,
    this.authority,
  });

  /// 目录树 URI
  final String location;

  /// 中文可读目录（如 `下载/legado`）；原生无法解析时为 null
  final String? displayPath;

  /// DocumentsProvider authority
  final String? authority;

  @override
  bool operator ==(Object other) =>
      other is SaveTreeSelection &&
      other.location == location &&
      other.displayPath == displayPath &&
      other.authority == authority;

  @override
  int get hashCode => Object.hash(location, displayPath, authority);

  @override
  String toString() =>
      'SaveTreeSelection(location: $location, displayPath: $displayPath, '
      'authority: $authority)';
}

/// 系统另存平台通道抽象（D1 / 批26）
///
/// 背景：`file_picker 8.3.7` 在 Android 的 `onActivityResult` 内直接对
/// SAF 返回的 Downloads provider URI 调 `openOutputStream` 写字节，仅捕获
/// `IOException`；MuMu Android 15 上抛出的 `SecurityException` 穿透
/// `Activity.onActivityResult` → 主线程 FATAL（进程被强杀，残留 0 字节文件）。
///
/// 该异常发生在平台 Activity 回调里，Dart 侧无法捕获，因此 Android 改为走
/// 自建 `legado/file_save` 通道（Kotlin `SaveFileBridge`）：
/// - 批26 默认 SAF 目录树：首次 `ACTION_OPEN_DOCUMENT_TREE` 选文件夹并
///   记住（原生 SharedPreferences），之后直接树内建文件写入（对齐原版
///   `HandleFileViewModel.saveToLocal`）；
/// - 旧 `ACTION_CREATE_DOCUMENT` 链路保留为回退（`useTree: false`）。
///
/// 本抽象供 [ExportFileService] 注入测试假实现；生产实现为
/// [MethodChannelFileSaveChannel]。
abstract class FileSaveChannel {
  const FileSaveChannel();

  /// 打开系统另存并写入 [bytes]。
  ///
  /// [useTree] 为 true（默认）时走 SAF 目录树：原生已记住目录则直接写入，
  /// 否则先弹目录选择器；[chooseTree] 为 true 时强制重新选择目录。
  /// [useTree] 为 false 时走旧 `ACTION_CREATE_DOCUMENT` 系统对话框。
  ///
  /// 返回实际保存结果（Android 为 content:// URI + provider 实际文件名）；
  /// 用户取消返回 null；写入失败抛 [FileSaveException]（原生端已捕获异常，
  /// 失败只清理本次创建的文档，不删除用户已有文件）。
  Future<SaveFileResult?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    bool useTree = true,
    bool chooseTree = false,
  });

  /// 主动选择/更换保存文件夹（Android 目录树）
  ///
  /// 成功后原生记住该目录，后续保存直接使用；用户取消返回 null。
  /// 非 Android 平台默认不支持，返回 null。
  Future<SaveTreeSelection?> chooseTree() async => null;

  /// 查询已记住的保存文件夹；未记住或平台不支持返回 null
  Future<SaveTreeSelection?> savedTree() async => null;
}

/// `legado/file_save` MethodChannel 实现（Kotlin `SaveFileBridge`）
class MethodChannelFileSaveChannel extends FileSaveChannel {
  const MethodChannelFileSaveChannel();

  static const MethodChannel _channel = MethodChannel('legado/file_save');

  @override
  Future<SaveFileResult?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    bool useTree = true,
    bool chooseTree = false,
  }) async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>('saveFile', <String, Object?>{
            'fileName': fileName,
            'bytes': bytes,
            'useTree': useTree,
            'chooseTree': chooseTree,
            if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
          });
      return _parseResult(raw);
    } on MissingPluginException {
      // 通道未注册（非本应用 Android 壳/测试宿主）：给出可读原因，
      // 不回退 file_picker（会重新引入崩溃链路）
      throw const FileSaveException(
        code: 'SAVE_CHANNEL_MISSING',
        message: '系统保存通道不可用，请更新应用版本后重试',
      );
    } on PlatformException catch (e) {
      throw FileSaveException(
        code: e.code,
        message: (e.message ?? '').trim().isEmpty
            ? _friendlyReason(e.code)
            : e.message!,
        detail: _detailOf(e.details),
      );
    }
  }

  @override
  Future<SaveTreeSelection?> chooseTree() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('chooseTree');
      return _parseTree(raw);
    } on MissingPluginException {
      throw const FileSaveException(
        code: 'SAVE_CHANNEL_MISSING',
        message: '系统保存通道不可用，请更新应用版本后重试',
      );
    } on PlatformException catch (e) {
      throw FileSaveException(
        code: e.code,
        message: (e.message ?? '').trim().isEmpty
            ? _friendlyReason(e.code)
            : e.message!,
        detail: _detailOf(e.details),
      );
    }
  }

  @override
  Future<SaveTreeSelection?> savedTree() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('getSavedTree');
      return _parseTree(raw);
    } on MissingPluginException {
      // 查询失败不阻断导出流程：按「未记住」处理，保存时由原生决定是否选目录
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 解析原生回传：`{uri, name, fallback, relativeDir, viaTree, displayPath}`
  /// （新形态）或字符串 URI（兼容）
  static SaveFileResult? _parseResult(Object? raw) {
    if (raw == null) return null;
    if (raw is String) {
      final location = raw.trim();
      return location.isEmpty ? null : SaveFileResult(location: location);
    }
    if (raw is Map) {
      final location = raw['uri']?.toString().trim() ?? '';
      if (location.isEmpty) return null;
      final name = raw['name']?.toString().trim();
      final dir = raw['relativeDir']?.toString().trim();
      final display = raw['displayPath']?.toString().trim();
      return SaveFileResult(
        location: location,
        fileName: (name == null || name.isEmpty) ? null : name,
        viaMediaStoreFallback: raw['fallback']?.toString() == 'mediastore',
        downloadDirectory: (dir == null || dir.isEmpty) ? null : dir,
        viaTree: raw['viaTree'] == true,
        displayPath: (display == null || display.isEmpty) ? null : display,
      );
    }
    return null;
  }

  /// 解析目录树回传：`{uri, displayPath, authority}` 或字符串 URI（兼容）
  static SaveTreeSelection? _parseTree(Object? raw) {
    if (raw == null) return null;
    if (raw is String) {
      final location = raw.trim();
      return location.isEmpty ? null : SaveTreeSelection(location: location);
    }
    if (raw is Map) {
      final location = raw['uri']?.toString().trim() ?? '';
      if (location.isEmpty) return null;
      final display = raw['displayPath']?.toString().trim();
      final authority = raw['authority']?.toString().trim();
      return SaveTreeSelection(
        location: location,
        displayPath: (display == null || display.isEmpty) ? null : display,
        authority: (authority == null || authority.isEmpty) ? null : authority,
      );
    }
    return null;
  }

  /// 原生未回传 message 时的中文兜底（按错误码映射）
  static String _friendlyReason(String code) => switch (code) {
    'INVALID_ARGS' => '文件名或导出内容无效',
    'EMPTY_BYTES' => '导出内容为空，未创建文件',
    'ALREADY_PENDING' => '已有另存请求进行中，请稍候重试',
    'SAVE_START_FAILED' => '无法打开系统保存对话框，请重试',
    'NO_URI' => '系统未返回保存位置，请重试',
    'TIMEOUT' => '等待系统保存对话框超时，请重试',
    'ACTIVITY_DESTROYED' => '页面已销毁，另存请求中断',
    'SAVE_VERIFY_FAILED' => '写入校验失败，文件未保存，请重试或换一个文件夹',
    'TREE_UNAVAILABLE' => '保存文件夹不可用，请重新选择文件夹后重试',
    'TREE_WRITE_FAILED' => '无法写入所选文件夹，请换一个文件夹重试',
    'TREE_UNSUPPORTED' => '当前系统不支持选择文件夹，请改用系统另存对话框',
    'FALLBACK_PATH_UNKNOWN' => '无法确定所选文件夹，请选择内部存储 > Download 或子文件夹后重试',
    'LEGACY_NOT_SUPPORTED' => 'Android 10 以下暂不支持保存到下载目录，请选择其他位置',
    'SAVE_FAILED' => '无法写入所选位置，请换一个文件夹重试',
    _ => '保存失败，请重试',
  };

  /// 提取结构化错误里的技术详情（供失败面板次要行/复制排障）
  static String? _detailOf(Object? details) {
    if (details is Map) {
      final detail = details['detail']?.toString().trim();
      if (detail != null && detail.isNotEmpty) return detail;
    }
    final text = details?.toString().trim();
    return (text == null || text.isEmpty) ? null : text;
  }
}

/// 系统另存失败（原生端已捕获原始异常并清理残留文档）
///
/// [message] 是面向用户的中文短句（可直接经 `errorMessage()` 展示）；
/// [detail] 保留技术详情（如 `Permission Denial: ... requires
/// MANAGE_DOCUMENTS`），供失败面板次要行展示与复制排障。
class FileSaveException implements Exception {
  const FileSaveException({
    required this.code,
    required this.message,
    this.detail,
  });

  /// 原生错误码
  final String code;

  /// 面向用户的中文原因
  final String message;

  /// 可复制的技术详情（排障用，可为空）
  final String? detail;

  @override
  String toString() => message;
}
