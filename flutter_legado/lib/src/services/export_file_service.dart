// 导出文件落盘/分享服务（批16c）
//
// 对齐参考版 `FilePickerSheet` 的 EXPORT 形态（legado-with-MD3）：
// 「系统另存」由系统文件保存对话框决定位置，不做自带文件夹/手动路径；
// 分享则写临时文件后交给系统分享面板（对齐 Android 原版 share(file)）。
//
// 统一封装两条落盘路径，供通用导出 Sheet 与各导出来源（RSS/词典/16e）
// 复用；方法可被测试子类覆写，避免测试依赖真实文件对话框。
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 导出文件服务
class ExportFileService {
  const ExportFileService();

  /// 系统另存：返回实际保存路径；用户在系统对话框取消时返回 null。
  ///
  /// - Android / iOS：file_picker 要求传入 [bytes] 并由插件写入
  ///   （返回的是 Downloads 下的展示路径，不再二次写盘）；
  /// - Windows / macOS / Linux：插件只返回用户选择的路径，内容由本方法写入；
  /// - 写入失败时上抛异常，由调用方展示真实原因。
  Future<String?> saveToLocal({
    required String fileName,
    required String content,
  }) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
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

  /// 取文件后缀（不含点）；无有效后缀返回 null
  String? _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return null;
    final extension = fileName.substring(dot + 1).trim();
    return extension.isEmpty ? null : extension;
  }
}
