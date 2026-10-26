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
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 导出文件服务
class ExportFileService {
  const ExportFileService();

  /// 系统另存文本内容：返回实际保存路径；用户取消时返回 null。
  ///
  /// - Android / iOS：file_picker 要求传入 [bytes] 并由插件写入
  ///   （返回的是 Downloads 下的展示路径，不再二次写盘）；
  /// - Windows / macOS / Linux：插件只返回用户选择的路径，内容由本方法写入；
  /// - 写入失败时上抛异常，由调用方展示真实原因。
  Future<String?> saveToLocal({
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
  /// 读取 [sourcePath] 后走同一套系统另存流程，移动端由 file_picker 写字节、
  /// 桌面端由本方法写盘。返回保存路径；用户取消返回 null。
  ///
  /// 只读取源文件，不移动/删除它；临时文件清理由调用方决定（见
  /// `showExportFileSheet(deleteTempFileOnClose:)`）。
  Future<String?> saveExistingFile({
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
  Future<String?> _saveBytes({
    required String fileName,
    required Uint8List bytes,
  }) async {
    // 仅移动端插件负责写字节；桌面端（含 macOS，插件不支持 bytes）自行写盘
    final pluginWritesBytes =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final extension = _extensionOf(fileName);

    final path = await FilePicker.platform.saveFile(
      dialogTitle: '保存 $fileName',
      fileName: fileName,
      type: extension == null ? FileType.any : FileType.custom,
      allowedExtensions: extension == null ? null : <String>[extension],
      bytes: pluginWritesBytes ? bytes : null,
    );
    if (path == null) return null;
    if (!pluginWritesBytes) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return path;
  }

  /// 保存成功提示文案
  ///
  /// 移动端（Android/iOS）系统另存返回的路径多为内容 URI/Downloads 展示路径，
  /// 用户难以据此定位文件，只提示文件名；桌面端路径可直接用于查找，提示完整路径。
  String savedMessage({required String path, required String fileName}) {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return mobile ? '已保存：$fileName' : '已保存到：$path';
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
  /// `[\\/:*?"<>|]` 全部替换为 `_`）
  static String normalizeFileName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  /// 取文件后缀（不含点）；无有效后缀返回 null
  String? _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return null;
    final extension = fileName.substring(dot + 1).trim();
    return extension.isEmpty ? null : extension;
  }
}
