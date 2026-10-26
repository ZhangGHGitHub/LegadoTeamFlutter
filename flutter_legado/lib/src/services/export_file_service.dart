// 导出文件落盘/分享服务（批16c）
//
// 对齐参考版 `FilePickerSheet` 的 EXPORT 形态（legado-with-MD3）：
// 「系统另存」由系统文件保存对话框决定位置，不做自带文件夹/手动路径；
// 分享则写临时文件后交给系统分享面板（对齐 Android 原版 share(file)）。
//
// 统一封装两条落盘路径，供通用导出 Sheet 与各导出来源（RSS/词典/16e）
// 复用；方法可被测试子类覆写，避免测试依赖真实文件对话框。
// 批16e 起支持 filePath 模式：既有文件（.js/.zip 等）经 [saveExistingFile]
// 复制到用户选择位置，[writeTempFileBytes] 生成二进制临时文件。
//
// [D1 2026-10-27] Android 系统另存改走自建 `legado/file_save` 通道
// （Kotlin SaveFileBridge）：file_picker 8.3.7 在 onActivityResult 内裸写
// SAF URI，MuMu Android 15 的 DownloadStorageProvider 抛 SecurityException
// 未被插件捕获 → 主线程 FATAL。iOS 保留 file_picker（插件负责写字节），
// 桌面端仍由本服务自行写盘。
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'file_save_channel.dart';

/// 导出文件服务
class ExportFileService {
  const ExportFileService({
    this.fileSaveChannel = const MethodChannelFileSaveChannel(),
  });

  /// Android 系统另存通道（测试注入假实现，默认走 `legado/file_save`）
  final FileSaveChannel fileSaveChannel;

  /// 系统另存文本内容：返回实际保存结果；用户取消时返回 null。
  ///
  /// - Android：自建 SAF 通道创建文档并写字节，返回 content:// URI 与
  ///   provider 实际文件名（重名时可能为 `xxx (1).json`）；
  /// - iOS：file_picker 要求传入 [bytes] 并由插件写入；
  /// - Windows / macOS / Linux：插件只返回用户选择的路径，内容由本方法写入；
  /// - 写入失败时上抛异常，由调用方展示真实原因（Android 端原生只清理
  ///   本次创建/截断的文档，不误删用户已有文件）。
  Future<SaveFileResult?> saveToLocal({
    required String fileName,
    required String content,
  }) {
    return _saveBytes(
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(content)),
    );
  }

  /// 系统另存既有文件（批16e filePath 模式）
  ///
  /// 用于二进制/已落盘内容（如书源单源 `.js`、底栏皮肤 `.zip`）：
  /// 读取 [sourcePath] 后走同一套系统另存流程（Android 走自建通道、
  /// iOS 由 file_picker 写字节、桌面端由本方法写盘）。返回保存结果；
  /// 用户取消返回 null。
  ///
  /// 只读取源文件，不移动/删除它；临时文件清理由调用方决定（见
  /// `showExportFileSheet(deleteTempFileOnClose:)`）。
  Future<SaveFileResult?> saveExistingFile({
    required String sourcePath,
    required String fileName,
  }) async {
    final bytes = await File(sourcePath).readAsBytes();
    return _saveBytes(fileName: fileName, bytes: bytes);
  }

  /// Sheet 关闭时清理调用方自建的临时文件
  ///
  /// 安全护栏（批16e 回修 P2-2）：仅当 [path] 位于
  /// [getTemporaryDirectory] 之下时才删除——调用方即使误把用户目录文件
  /// 传进来（或路径含 `..` 逃逸），也只会返回 false 而不落删除动作。
  ///
  /// 返回 true 表示实际删除了文件；文件不存在、不在临时目录内、路径
  /// 不可解析或删除失败均返回 false（清理失败不影响导出结果）。
  Future<bool> deleteTemporaryFile(String path) async {
    if (path.trim().isEmpty) return false;
    try {
      final tempDir = await getTemporaryDirectory();
      return deleteTemporaryFileSync(
        tempDirPath: tempDir.path,
        path: path,
      );
    } catch (e) {
      debugPrint('导出临时文件清理失败（$path）：$e');
      return false;
    }
  }

  /// 同步清理临时文件（调用方已持有系统临时目录根路径时使用）
  ///
  /// Sheet 在 initState 预解析临时目录，dispose 中可同步删除，避免
  /// 「关闭后异步清理尚未落定」的时序问题；护栏口径与
  /// [deleteTemporaryFile] 完全一致。
  bool deleteTemporaryFileSync({
    required String tempDirPath,
    required String path,
  }) {
    if (path.trim().isEmpty) return false;
    if (!_isUnderDirectory(tempDirPath, path)) {
      debugPrint('导出临时文件不在系统临时目录内，跳过删除：$path');
      return false;
    }
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      file.deleteSync();
      return true;
    } catch (e) {
      debugPrint('导出临时文件清理失败（$path）：$e');
      return false;
    }
  }

  /// 判断 [target] 是否位于 [root] 目录之下（不含 root 本身）
  ///
  /// 不引入 `path` 依赖：`Uri.normalizePath` 消解 `.`/`..` 相对段；
  /// Windows 文件系统大小写不敏感，统一转小写后再比较。路径不可解析
  /// （含非法 URI 字符）时保守返回 false，绝不误删。
  static bool _isUnderDirectory(String root, String target) {
    try {
      final windows = Platform.isWindows;
      String canonical(String value) {
        final text = Uri.file(value, windows: windows)
            .normalizePath()
            .toFilePath(windows: windows);
        return windows ? text.toLowerCase() : text;
      }

      final rootPath = canonical(root);
      final targetPath = canonical(target);
      final separator = Platform.pathSeparator;
      final prefix = rootPath.endsWith(separator)
          ? rootPath
          : '$rootPath$separator';
      return targetPath.startsWith(prefix);
    } catch (e) {
      debugPrint('导出临时文件路径解析失败（跳过删除）：$e');
      return false;
    }
  }

  /// 系统另存公共实现（文本与既有文件共用）
  ///
  /// [D1] Android 不再经过 file_picker：走 [fileSaveChannel] 自建 SAF 通道，
  /// 原生端负责写字节、捕异常、失败清理；iOS 仍由 file_picker 写字节；
  /// 桌面端插件只选路径，内容由本方法写盘。
  ///
  /// [P3-5] 文件名统一先经 [normalizeFileName] 净化（`[\\/:*?"<>|]` →
  /// `_`），避免桌面端路径解析失败与 Android provider 拒收非法名字。
  Future<SaveFileResult?> _saveBytes({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final safeName = normalizeFileName(fileName);
    final effectiveName = safeName.isEmpty ? 'export' : safeName;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return fileSaveChannel.saveFile(
        fileName: effectiveName,
        bytes: bytes,
        mimeType: _mimeTypeOf(effectiveName),
      );
    }

    // 仅 iOS 插件负责写字节；桌面端（含 macOS，插件不支持 bytes）自行写盘
    final pluginWritesBytes = defaultTargetPlatform == TargetPlatform.iOS;
    final extension = _extensionOf(effectiveName);

    final path = await FilePicker.platform.saveFile(
      dialogTitle: '保存 $effectiveName',
      fileName: effectiveName,
      type: extension == null ? FileType.any : FileType.custom,
      allowedExtensions: extension == null ? null : <String>[extension],
      bytes: pluginWritesBytes ? bytes : null,
    );
    if (path == null) return null;
    if (!pluginWritesBytes) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return SaveFileResult(location: path, fileName: effectiveName);
  }

  /// 保存成功提示文案
  ///
  /// 移动端（Android/iOS）返回的是 content URI / Downloads 展示路径，
  /// 用户难以据此定位文件，只提示实际文件名（P3-2：优先用原生回传的
  /// provider 实际名字，重名 `(1)` 时提示仍与磁盘一致）；桌面端路径可
  /// 直接用于查找，提示完整路径。
  ///
  /// MediaStore 回退（P1-1/P3-3）写入的是用户在系统对话框里选的「下载」
  /// 子目录，只给文件名仍难定位 → 额外回显目录（`Download/…/` 显示为
  /// 「下载/…」）。
  String savedMessage({
    required SaveFileResult saved,
    required String requestedFileName,
  }) {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final name = saved.fileName ?? normalizeFileName(requestedFileName);
    if (saved.viaMediaStoreFallback) {
      final directory = _displayDownloadDirectory(saved.downloadDirectory);
      return directory == null ? '已保存到下载目录：$name' : '已保存到「$directory」：$name';
    }
    return mobile ? '已保存：$name' : '已保存到：${saved.location}';
  }

  /// `Download/legado/` → `下载/legado`（提示文案用，失败返回 null）
  static String? _displayDownloadDirectory(String? relativeDirectory) {
    final raw = relativeDirectory?.trim() ?? '';
    if (raw.isEmpty) return null;
    final text = raw
        .replaceFirst(RegExp(r'^Download/?', caseSensitive: false), '下载/')
        .replaceFirst(RegExp(r'/+$'), '');
    return text.isEmpty ? null : text;
  }

  /// 写入临时目录并返回可分享的文件（对齐原版 share(file)）
  ///
  /// 同名文件直接覆盖；分享面板消费的是临时副本，不污染用户目录。
  Future<XFile> writeTempFile({
    required String fileName,
    required String content,
    String mimeType = 'application/json',
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(content, flush: true);
    return XFile(file.path, mimeType: mimeType);
  }

  /// 写入临时目录并返回文件路径（二进制内容，供 filePath 模式导出）
  ///
  /// 用于 `.zip` 等无法以字符串承载的内容；同名文件直接覆盖。
  /// 返回路径仅供本次导出使用，删除由调用方负责。
  Future<String> writeTempFileBytes({
    required String fileName,
    required List<int> bytes,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 规范化文件名中的非法字符（对齐原版 `normalizeFileName`：
  /// `[\\/:*?"<>|]` 全部替换为 `_`）并去首尾空白（P3-5：与 Kotlin
  /// `SaveFileBridge.normalizeFileName` 的 trim 口径保持一致）
  static String normalizeFileName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  /// 取文件后缀（不含点）；无有效后缀返回 null
  String? _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return null;
    final extension = fileName.substring(dot + 1).trim();
    return extension.isEmpty ? null : extension;
  }

  /// 按扩展名推断 MIME（Android 保存对话框的文档类型提示）
  ///
  /// 与 Kotlin `SaveFileBridge.mimeTypeOf` 保持同口径；未知扩展名回退
  /// `application/octet-stream`。
  String _mimeTypeOf(String fileName) {
    final ext = _extensionOf(fileName)?.toLowerCase();
    return switch (ext) {
      'json' => 'application/json',
      'txt' || 'log' || 'md' => 'text/plain',
      'js' => 'application/javascript',
      'xml' || 'html' || 'htm' => 'text/xml',
      'zip' => 'application/zip',
      'epub' => 'application/epub+zip',
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => 'application/octet-stream',
    };
  }
}
