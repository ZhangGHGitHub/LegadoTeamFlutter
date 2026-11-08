// 封面相册多选图片导入（设置批6b-2）
//
// 复用 2b-1b-2a 的 SAF 口径：Android 走 `ACTION_OPEN_DOCUMENT` 多选
// （`Saf.pickFiles`）+ fd 读字节，不解析 MediaStore 路径（陈旧缩略图会
// 触发原生 FATAL）；iOS/桌面走 file_picker 多选，allowCompression:false。
// 读取前按元数据拦截超限文件，最终仍由 CoverAlbumStore 做 ≤32MB 与
// 引擎可解码校验（失败项逐张返回可读原因）。
//
// 测试 seam：`CoverAlbumImagePicker.pickOverride` 注入假选择结果，
// `resetForTest` 恢复真实平台实现。
//
// 编写：全栈工程师（设置批6b-2） ｜ 2026-11-09
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:saf/saf.dart';

import 'cover_album_store.dart';

/// 选中图片的字节与显示名
class CoverAlbumImagePick {
  final String name;
  final Uint8List bytes;

  const CoverAlbumImagePick({required this.name, required this.bytes});
}

/// 选择/读取失败（取消返回空列表，不抛）
class CoverAlbumImagePickerException implements Exception {
  final String message;

  const CoverAlbumImagePickerException(this.message);

  @override
  String toString() => message;
}

/// 多选图片入口（平台分支集中于此，UI 只消费字节）
class CoverAlbumImagePicker {
  CoverAlbumImagePicker._();

  /// 测试 seam：返回 null 走真实平台实现
  @visibleForTesting
  static Future<List<CoverAlbumImagePick>> Function(int maxBytes)? pickOverride;

  @visibleForTesting
  static void resetForTest() {
    pickOverride = null;
  }

  /// 选择多张图片；用户取消返回空列表
  ///
  /// 超限/读取失败抛 [CoverAlbumImagePickerException]（中文可读提示）。
  static Future<List<CoverAlbumImagePick>> pickImages({
    int maxBytes = CoverAlbumStore.maxBytes,
  }) async {
    final override = pickOverride;
    if (override != null) return override(maxBytes);
    if (Platform.isAndroid) return _pickAndroid(maxBytes);
    return _pickDesktop(maxBytes);
  }

  static Future<List<CoverAlbumImagePick>> _pickAndroid(int maxBytes) async {
    try {
      final saf = Saf();
      final docs = await saf.pickFiles(mimeTypes: const <String>['image/*']);
      if (docs.isEmpty) return const <CoverAlbumImagePick>[];
      final out = <CoverAlbumImagePick>[];
      for (final doc in docs) {
        if (doc.length > maxBytes) {
          throw CoverAlbumImagePickerException(
            '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）：${doc.name}',
          );
        }
        final bytes = await saf.withFileDescriptor(
          doc.uri,
          'r',
          (fd) => File(fd.path).readAsBytes(),
        );
        out.add(CoverAlbumImagePick(name: doc.name, bytes: bytes));
      }
      return out;
    } on CoverAlbumImagePickerException {
      rethrow;
    } catch (e) {
      debugPrint('[CoverAlbumImagePicker] Android SAF 失败: $e');
      throw const CoverAlbumImagePickerException('无法打开系统图片选择器，请重试');
    }
  }

  static Future<List<CoverAlbumImagePick>> _pickDesktop(int maxBytes) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        allowCompression: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        return const <CoverAlbumImagePick>[];
      }
      final out = <CoverAlbumImagePick>[];
      for (final file in result.files) {
        if (file.size > maxBytes) {
          throw CoverAlbumImagePickerException(
            '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）：${file.name}',
          );
        }
        final bytes =
            file.bytes ??
            (file.path != null ? await File(file.path!).readAsBytes() : null);
        if (bytes == null) {
          throw CoverAlbumImagePickerException('无法读取所选图片：${file.name}');
        }
        if (bytes.length > maxBytes) {
          throw CoverAlbumImagePickerException(
            '图片过大（上限 ${maxBytes ~/ (1024 * 1024)}MB）：${file.name}',
          );
        }
        out.add(CoverAlbumImagePick(name: file.name, bytes: bytes));
      }
      return out;
    } on CoverAlbumImagePickerException {
      rethrow;
    } catch (e) {
      debugPrint('[CoverAlbumImagePicker] file_picker 失败: $e');
      throw const CoverAlbumImagePickerException('选择图片失败，请重试');
    }
  }
}
